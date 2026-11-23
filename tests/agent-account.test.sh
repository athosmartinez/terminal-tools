#!/usr/bin/env bash
# Tests for agent-account and agent-shim. Fake homes in a temp dir and fake
# claude / codex binaries that print the env they got: no test touches a real
# ~/.claude, ~/.codex, Keychain or network.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unset CLAUDE_CONFIG_DIR CODEX_HOME CURSOR_API_KEY CURSOR_CONFIG_DIR AGENT_ACCOUNT
unset AGENT_ACCOUNT_REAL_CLAUDE AGENT_ACCOUNT_REAL_CODEX AGENT_ACCOUNT_REAL_CURSOR
export HOME=$WORK/home
export XDG_DATA_HOME=$HOME/.local/share XDG_CONFIG_HOME=$HOME/.config
export XDG_CACHE_HOME=$HOME/.cache XDG_STATE_HOME=$HOME/.local/state
export AGENT_ACCOUNTS_HOME=$WORK/accounts
A=$AGENT_ACCOUNTS_HOME
AA=$REPO/agent-account

mkdir -p "$WORK/real" "$WORK/other" "$WORK/shims" "$WORK/shims2" "$WORK/elsewhere" "$HOME"
for p in claude codex cursor-agent agent; do
  ln -s "$REPO/agent-shim" "$WORK/shims/$p"
  ln -s "$REPO/agent-shim" "$WORK/shims2/$p"
done
cat >"$WORK/real/claude" <<'EOF'
#!/usr/bin/env bash
echo "real-claude CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>} args=$*"
EOF
cat >"$WORK/real/codex" <<'EOF'
#!/usr/bin/env bash
echo "real-codex CODEX_HOME=${CODEX_HOME-<unset>} args=$*"
EOF
for p in cursor-agent agent; do
  printf '#!/usr/bin/env bash\necho "real-%s CURSOR_API_KEY=${CURSOR_API_KEY-<unset>} args=$*"\n' "$p" >"$WORK/real/$p"
done
printf '#!/usr/bin/env bash\necho other-claude\n' >"$WORK/other/claude"
chmod +x "$WORK/real/"* "$WORK/other/claude"
export PATH=$WORK/shims:$WORK/real:$PATH

# A shared ~/.claude: a file, a folder, a dotfile, an entry that is itself a
# link to somewhere else, and the login file that must stay apart.
mkdir -p "$HOME/.claude/skills"
echo '{}' >"$HOME/.claude/settings.json"
echo x >"$HOME/.claude/.hidden"
echo x >"$HOME/.claude/.credentials.json"
echo '# shared' >"$WORK/elsewhere/CLAUDE.md"
ln -s "$WORK/elsewhere/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
cat >"$HOME/.claude.json" <<'EOF'
{"oauthAccount": {"emailAddress": "a@example.com"}, "userID": "u-1", "penguinModeOrgEnabled": true,
 "theme": "light", "mcpServers": {"one": {"command": "one"}}}
EOF

# A fake id_token: base64url payload without padding; the "n" value makes
# the encoding use "-" and "_".
id_token() {
  local payload
  payload=$(printf '{"email":"%s","n":"~~~???>>>","https://api.openai.com/auth":{"chatgpt_account_id":"%s","chatgpt_plan_type":"%s"}}' "$1" "$2" "$3" |
    base64 | tr -d '\n=' | tr '+/' '-_')
  echo "eyJhbGciOiJub25lIn0.$payload.c2ln"
}
auth_json() {
  printf '{"tokens": {"id_token": "%s", "access_token": "secret-a", "refresh_token": "secret-r"}}\n' "$(id_token "$@")"
}
mkdir -p "$HOME/.codex/sessions"
echo 'model = "x"' >"$HOME/.codex/config.toml"
auth_json c@example.com acct-1 prolite >"$HOME/.codex/auth.json"
touch "$HOME/.codex/auth.json.lock" "$HOME/.codex/auth.lock"

passed=0
failed=0
ok() {
  echo "ok   $1"
  passed=$((passed + 1))
}
fail() {
  echo "FAIL $1: $2"
  failed=$((failed + 1))
}
check() { # name expected-substring actual
  if [[ $3 == *"$2"* ]]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
check_eq() { # name expected actual
  if [[ $3 == "$2" ]]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
check_true() { # name command...
  local name=$1
  shift
  if "$@"; then ok "$name"; else fail "$name" "false: $*"; fi
}
inode() { ls -i "$1" | awk '{print $1}'; }
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# --- list with only the default accounts --------------------------------------

json=$("$AA" list --json)
check_eq "list: default only, claude" \
  '{"active":"default","accounts":[{"name":"default","id":"default","label":"default","tag":null,"home":"'"$HOME"'/.claude","email":"a@example.com","logged_in":true,"account_id":null}]}' \
  "$(jq -c .claude <<<"$json")"
check_eq "list: default only, codex (fields from the id_token)" \
  '{"active":"default","accounts":[{"name":"default","id":"default","label":"default","tag":null,"home":"'"$HOME"'/.codex","email":"c@example.com","logged_in":true,"account_id":"acct-1","plan":"prolite"}]}' \
  "$(jq -c .codex <<<"$json")"
check_true "list --json never prints a token" test -z "$(grep -E 'secret-|eyJ' <<<"$json")"

# --- add ----------------------------------------------------------------------

out=$("$AA" add claude work)
check "add claude prints the login command" "CLAUDE_CONFIG_DIR='$A/claude/work' claude auth login" "$out"
out=$("$AA" add codex work)
check "add codex prints the login command" "CODEX_HOME='$A/codex/work' codex login" "$out"
check "add is idempotent" "exists" "$("$AA" add claude work)"
"$AA" add claude Bad >/dev/null 2>&1
check_eq "add rejects an upper-case name" 1 $?
"$AA" add claude ../x >/dev/null 2>&1
check_eq "add rejects a path" 1 $?
"$AA" add claude default >/dev/null 2>&1
check_eq "add rejects default" 1 $?
"$AA" add other work >/dev/null 2>&1
check_eq "add rejects an unknown provider" 1 $?

H=$A/claude/work
check_eq "claude: a file is linked to \$HOME/.claude/<entry>" "$HOME/.claude/settings.json" "$(readlink "$H/settings.json")"
check_eq "claude: a folder is linked" "$HOME/.claude/skills" "$(readlink "$H/skills")"
check_eq "claude: a dotfile is linked" "$HOME/.claude/.hidden" "$(readlink "$H/.hidden")"
check_eq "claude: a linked entry points to \$HOME/.claude, not to its target" \
  "$HOME/.claude/CLAUDE.md" "$(readlink "$H/CLAUDE.md")"
check_true "claude: .credentials.json is not linked" test ! -e "$H/.credentials.json" -a ! -L "$H/.credentials.json"
check_true "claude: .claude.json is the account's own file" test -f "$H/.claude.json" -a ! -L "$H/.claude.json"
check_eq "claude: .claude.json has mode 600" 600 "$(mode "$H/.claude.json")"
check_eq "claude: .claude.json drops the identity, keeps the rest" \
  '{"mcpServers":{"one":{"command":"one"}},"theme":"light"}' "$(jq -cS . "$H/.claude.json")"
C=$A/codex/work
check_eq "codex: config.toml is linked" "$HOME/.codex/config.toml" "$(readlink "$C/config.toml")"
check_eq "codex: sessions are linked (shared)" "$HOME/.codex/sessions" "$(readlink "$C/sessions")"
for f in auth.json auth.json.lock auth.lock; do
  check_true "codex: $f is not linked" test ! -e "$C/$f" -a ! -L "$C/$f"
done

# --- list with one added account per provider ----------------------------------

json=$("$AA" list --json)
check_eq "list: default first, then the added account" '["default","work"]' "$(jq -c '[.claude.accounts[].name]' <<<"$json")"
check_eq "list: a new claude account is not logged in" \
  '{"name":"work","id":"work","label":"work","tag":null,"home":"'"$H"'","email":null,"logged_in":false,"account_id":null}' \
  "$(jq -c '.claude.accounts[1]' <<<"$json")"
check_eq "list: a new codex account is not logged in" \
  '{"name":"work","id":"work","label":"work","tag":null,"home":"'"$C"'","email":null,"logged_in":false,"account_id":null,"plan":null}' \
  "$(jq -c '.codex.accounts[1]' <<<"$json")"

# The logins the user does: Claude writes oauthAccount into the account's
# .claude.json; for Codex an auth.json is copied in.
jq '.oauthAccount = {"emailAddress": "b@example.com"}' "$H/.claude.json" >"$WORK/t" && cat "$WORK/t" >"$H/.claude.json"
auth_json d@example.com acct-2 plus >"$C/auth.json"
json=$("$AA" list --json)
check_eq "list: claude account after login" \
  '{"name":"work","id":"work","label":"work","tag":null,"home":"'"$H"'","email":"b@example.com","logged_in":true,"account_id":null}' \
  "$(jq -c '.claude.accounts[1]' <<<"$json")"
check_eq "list: codex account after login" \
  '{"name":"work","id":"work","label":"work","tag":null,"home":"'"$C"'","email":"d@example.com","logged_in":true,"account_id":"acct-2","plan":"plus"}' \
  "$(jq -c '.codex.accounts[1]' <<<"$json")"
check "list: the human table marks the active account" "* default" "$("$AA" list)"
check "list ignores CLAUDE_CONFIG_DIR of its own environment" '"home":"'"$HOME"'/.claude"' \
  "$(CLAUDE_CONFIG_DIR=$H "$AA" list --json | jq -c '.claude.accounts[0]')"

# --- the shim with no pointer or the default account ---------------------------

check_eq "shim: no pointer runs the real claude unchanged" \
  "real-claude CLAUDE_CONFIG_DIR=<unset> args=-p hi" "$(claude -p hi)"
check_eq "shim: no pointer runs the real codex unchanged" \
  "real-codex CODEX_HOME=<unset> args=exec" "$(codex exec)"

# --- use ------------------------------------------------------------------------

"$AA" use claude default >/dev/null
before=$(inode "$A/claude/active")
out=$("$AA" use claude work)
check_eq "use prints the new account" \
  "claude: new sessions use work (b@example.com); running sessions keep their account" "$out"
check_eq "use writes the pointer" work "$(cat "$A/claude/active")"
check_true "use replaces the pointer with a rename (atomic)" test "$before" != "$(inode "$A/claude/active")"
check_eq "use leaves no temp file" "" "$(ls -A "$A/claude" | grep '^\.active')"
"$AA" use claude nobody >/dev/null 2>&1
check_eq "use rejects an unknown name" 1 $?
check_eq "a rejected use keeps the pointer" work "$(cat "$A/claude/active")"
"$AA" use other work >/dev/null 2>&1
check_eq "use rejects an unknown provider" 1 $?
"$AA" use codex work >/dev/null

check_eq "env prints the account home" "CLAUDE_CONFIG_DIR=$H" "$("$AA" env claude)"
check_eq "env of default is empty" "CODEX_HOME=" "$("$AA" env codex default)"

# --- the shim with another account active ---------------------------------------

check_eq "shim: claude gets the active account's home" \
  "real-claude CLAUDE_CONFIG_DIR=$H args=--resume a b" "$(claude --resume "a b")"
check_eq "shim: the home is exactly what env prints" \
  "$("$AA" env claude)" "$(claude | sed 's/^real-claude //; s/ args=.*//')"
check_eq "shim: codex gets the active account's home" \
  "real-codex CODEX_HOME=$C args=" "$(codex)"
check_eq "shim: a preset CLAUDE_CONFIG_DIR passes through" \
  "real-claude CLAUDE_CONFIG_DIR=/preset args=" "$(CLAUDE_CONFIG_DIR=/preset claude)"
check_eq "shim: a preset CODEX_HOME passes through" \
  "real-codex CODEX_HOME=/preset args=" "$(CODEX_HOME=/preset codex)"
check_eq "shim: AGENT_ACCOUNT= (empty) runs unchanged" \
  "real-claude CLAUDE_CONFIG_DIR=<unset> args=" "$(AGENT_ACCOUNT= claude)"
check_eq "shim: AGENT_ACCOUNT=default runs unchanged" \
  "real-codex CODEX_HOME=<unset> args=" "$(AGENT_ACCOUNT=default codex)"
"$AA" use claude default >/dev/null
check_eq "shim: pointer default runs unchanged" \
  "real-claude CLAUDE_CONFIG_DIR=<unset> args=" "$(claude)"
check_eq "shim: AGENT_ACCOUNT=<name> wins over the pointer" \
  "real-claude CLAUDE_CONFIG_DIR=$H args=" "$(AGENT_ACCOUNT=work claude)"
"$AA" use claude work >/dev/null

out=$(AGENT_ACCOUNT=ghost claude 2>&1)
check_eq "shim: a missing home exits 1" 1 "$(AGENT_ACCOUNT=ghost claude >/dev/null 2>&1; echo $?)"
check "shim: a missing home says how to fix it" "agent-account add claude ghost" "$out"
check_true "shim: a missing home never runs the real binary" test "${out#*real-claude}" == "$out"
echo ghost >"$A/codex/active"
check_eq "shim: an active account without a home exits 1" 1 "$(codex >/dev/null 2>&1; echo $?)"
echo 'Not/Valid' >"$A/codex/active"
check_eq "shim: an invalid pointer means default" "real-codex CODEX_HOME=<unset> args=" "$(codex)"
"$AA" use codex work >/dev/null
check_eq "shim: AGENT_ACCOUNT with a path exits 1" 1 "$(AGENT_ACCOUNT=../x claude >/dev/null 2>&1; echo $?)"

check_eq "shim: skips itself when linked from another directory" \
  "real-claude CLAUDE_CONFIG_DIR=$H args=" "$(PATH=$WORK/shims2:$PATH claude)"
check_eq "shim: run by its full path, skips itself" \
  "real-claude CLAUDE_CONFIG_DIR=$H args=" "$("$WORK/shims/claude")"
check_eq "shim: AGENT_ACCOUNT_REAL_CLAUDE sets the real binary" \
  "other-claude" "$(AGENT_ACCOUNT_REAL_CLAUDE=$WORK/other/claude claude)"
check_eq "shim: no real binary exits 127" 127 \
  "$(PATH=$WORK/shims:/usr/bin:/bin "$WORK/shims/codex" >/dev/null 2>&1; echo $?)"

# New shared entries get linked on the next launch; the account's own files
# are left alone; mcpServers follows ~/.claude.json, oauthAccount does not.
touch "$HOME/.claude/new-entry" "$HOME/.claude/own.json" "$HOME/.codex/new-entry"
echo '{"mine":true}' >"$H/own.json"
jq '.mcpServers.two = {"command": "two"} | .oauthAccount.emailAddress = "z@example.com"' \
  "$HOME/.claude.json" >"$WORK/t" && cat "$WORK/t" >"$HOME/.claude.json"
claude >/dev/null
codex >/dev/null
check_eq "launch: a new claude entry is linked" "$HOME/.claude/new-entry" "$(readlink "$H/new-entry")"
check_eq "launch: a new codex entry is linked" "$HOME/.codex/new-entry" "$(readlink "$C/new-entry")"
check_eq "launch: the account's own file stays" '{"mine":true}' "$(cat "$H/own.json")"
check_eq "launch: mcpServers reaches the account" '{"one":{"command":"one"},"two":{"command":"two"}}' \
  "$(jq -cS .mcpServers "$H/.claude.json")"
check_eq "launch: oauthAccount is not copied" b@example.com "$(jq -r .oauthAccount.emailAddress "$H/.claude.json")"
check_eq "launch: .claude.json keeps mode 600" 600 "$(mode "$H/.claude.json")"
check_true "launch: no .claude.json temp file is left" test -z "$(ls -A "$H" | grep '^\.claude\.json\.')"

# --- labels and tags --------------------------------------------------------------

"$AA" add claude admin --label adm --tag work >/dev/null
check_eq "add --label/--tag writes accounts.json" '{"admin":{"label":"adm","tag":"work"}}' \
  "$(jq -cS . "$A/claude/accounts.json")"
"$AA" set claude default --label main --tag personal >/dev/null
json=$("$AA" list --json)
check_eq "list: default carries its label and tag; name stays the id" \
  '{"name":"default","id":"default","label":"main","tag":"personal"}' \
  "$(jq -c '.claude.accounts[0] | {name, id, label, tag}' <<<"$json")"
check_eq "list: an account with a label and a tag" '{"id":"admin","label":"adm","tag":"work"}' \
  "$(jq -c '.claude.accounts[] | select(.id == "admin") | {id, label, tag}' <<<"$json")"
check_eq "list: no label falls back to the id, no tag is null" '{"label":"work","tag":null}' \
  "$(jq -c '.claude.accounts[] | select(.id == "work") | {label, tag}' <<<"$json")"
check "list: the table shows the label and the tag" "main" "$("$AA" list | grep 'id: default' | grep personal)"
"$AA" set claude admin --tag "" >/dev/null
check_eq "set with an empty value clears it" '{"label":"adm"}' "$(jq -c .admin "$A/claude/accounts.json")"
"$AA" set claude ghost --label x >/dev/null 2>&1
check_eq "set rejects an unknown account" 1 $?
"$AA" set claude admin >/dev/null 2>&1
check_eq "set with nothing to set exits 1" 1 $?
out=$("$AA" use claude adm)
check_eq "use accepts a unique label" admin "$(cat "$A/claude/active")"
check "use by label prints the id" "new sessions use admin" "$out"
"$AA" set claude work --label adm >/dev/null
"$AA" use claude adm >/dev/null 2>&1
check_eq "use rejects a label shared by two accounts" 1 $?
check_eq "a rejected label keeps the pointer" admin "$(cat "$A/claude/active")"
"$AA" use claude work >/dev/null
check_eq "an id wins over a label" work "$(cat "$A/claude/active")"
check_true "accounts.json is written with a rename and leaves no temp file" \
  test -z "$(ls -A "$A/claude" | grep '^\.accounts')"

# add on an existing folder keeps its .claude.json and files.
echo '{"mine":2}' >"$H/kept.txt"
cp "$H/.claude.json" "$WORK/before.json"
"$AA" add claude work >/dev/null
check_eq "add on an existing home keeps its .claude.json" "$(cat "$WORK/before.json")" "$(cat "$H/.claude.json")"
check_eq "add on an existing home keeps its files" '{"mine":2}' "$(cat "$H/kept.txt")"

# --- cursor -------------------------------------------------------------------------

K=$A/cursor/team
out=$("$AA" add cursor team --label team-a --tag work)
check "add cursor prints the silent key command" "( umask 077; read -rs k; printf '%s\n' \"\$k\" > '$K/api-key' )" "$out"
check_eq "a cursor home holds nothing but the key" "" "$(ls -A "$K")"
json=$("$AA" list --json)
check_eq "list: cursor default" \
  '{"name":"default","id":"default","label":"default","tag":null,"home":"'"$HOME"'/.config/cursor","email":null,"logged_in":null,"account_id":null}' \
  "$(jq -c '.cursor.accounts[0]' <<<"$json")"
check_eq "list: a cursor account without a key" \
  '{"name":"team","id":"team","label":"team-a","tag":"work","home":"'"$K"'","email":"team-a","logged_in":false,"account_id":null}' \
  "$(jq -c '.cursor.accounts[1]' <<<"$json")"
"$AA" use cursor team >/dev/null
check_eq "shim: a cursor account without a key exits 1" 1 "$(cursor-agent >/dev/null 2>&1; echo $?)"
(umask 077 && printf 'key-123\n' >"$K/api-key")
check_eq "list: a cursor account with a key is logged in" true \
  "$("$AA" list --json | jq '.cursor.accounts[1].logged_in')"
check_true "list never prints the cursor key" test -z "$("$AA" list --json | grep key-123)"
check_eq "env gives the key file, not the key" "CURSOR_API_KEY_FILE=$K/api-key" "$("$AA" env cursor)"
check_eq "shim: cursor-agent gets the key of the active account" \
  "real-cursor-agent CURSOR_API_KEY=key-123 args=-p hi" "$(cursor-agent -p hi)"
check_eq "shim: agent is the same shim, and runs the real agent" \
  "real-agent CURSOR_API_KEY=key-123 args=" "$(agent)"
check_eq "shim: a preset CURSOR_API_KEY passes through" \
  "real-agent CURSOR_API_KEY=mine args=" "$(CURSOR_API_KEY=mine agent)"
check_eq "shim: AGENT_ACCOUNT= runs cursor unchanged" \
  "real-cursor-agent CURSOR_API_KEY=<unset> args=" "$(AGENT_ACCOUNT= cursor-agent)"
check_eq "shim: AGENT_ACCOUNT_REAL_CURSOR sets the real binary" \
  "other-claude" "$(AGENT_ACCOUNT_REAL_CURSOR=$WORK/other/claude agent)"
"$AA" use cursor default >/dev/null
check_eq "shim: cursor default runs unchanged" \
  "real-cursor-agent CURSOR_API_KEY=<unset> args=" "$(cursor-agent)"
check_eq "shim: skips itself for agent too" \
  "real-agent CURSOR_API_KEY=key-123 args=" "$(PATH=$WORK/shims2:$PATH AGENT_ACCOUNT=team agent)"
out=$("$AA" remove cursor team --yes)
check_true "remove cursor deletes the key file" test ! -e "$K"
check_eq "remove clears the label and the tag" null "$(jq -c '.team' "$A/cursor/accounts.json")"

# --- remove ---------------------------------------------------------------------

"$AA" remove claude default --yes >/dev/null 2>&1
check_eq "remove refuses default" 1 $?
"$AA" remove claude work --yes >/dev/null 2>&1
check_eq "remove refuses the active account" 1 $?
check_true "a refused remove keeps the home" test -d "$H"
"$AA" use claude default >/dev/null
out=$("$AA" remove claude work --yes)
check_true "remove deletes the home" test ! -e "$H"
check_true "remove keeps the shared entries" test -f "$HOME/.claude/settings.json" -a -d "$HOME/.claude/skills"
check_true "remove keeps a linked entry's target" test -f "$WORK/elsewhere/CLAUDE.md"
if [[ $(uname -s) == Darwin ]]; then
  check "remove names the Keychain item it leaves" "Claude Code-credentials-" "$out"
fi
"$AA" remove claude work --yes >/dev/null 2>&1
check_eq "remove of a missing account exits 1" 1 $?

# --- install.sh ------------------------------------------------------------------

BIN=$WORK/bin SHIMS=$WORK/inst-shims "$REPO/install.sh" >/dev/null 2>&1
check_eq "install links agent-account into the bin dir" "$REPO/agent-account" "$(readlink "$WORK/bin/agent-account")"
check_eq "install links the shim as claude" "$REPO/agent-shim" "$(readlink "$WORK/inst-shims/claude")"
check_eq "install links the shim as codex" "$REPO/agent-shim" "$(readlink "$WORK/inst-shims/codex")"
check_eq "install links the shim as cursor-agent" "$REPO/agent-shim" "$(readlink "$WORK/inst-shims/cursor-agent")"
check_eq "install links the shim as agent" "$REPO/agent-shim" "$(readlink "$WORK/inst-shims/agent")"

echo
echo "$passed passed, $failed failed"
((failed == 0))
