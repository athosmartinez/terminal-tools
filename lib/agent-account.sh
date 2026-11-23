# lib/agent-account.sh — shared by agent-account and agent-shim (bash 3.2).
#
# Registry: $AGENT_ACCOUNTS_HOME (default $XDG_DATA_HOME/agent-accounts).
#   <root>/<provider>/<id>/     the home of account <id>: CLAUDE_CONFIG_DIR
#                               or CODEX_HOME. Its basename is the id. For
#                               cursor it holds only api-key (mode 600).
#   <root>/<provider>/active    one line, the active account id. Missing,
#                               empty or not a valid id = default.
#   <root>/<provider>/accounts.json  {"<id>": {"label": "...", "tag": "..."}}
# Account "default" is the provider's normal home and has no folder here.
#
# A home path is always built as <root>/<provider>/<name>, never resolved:
# Claude Code names its Keychain item after the CLAUDE_CONFIG_DIR string, so a
# different spelling of the same folder is a different login.

AA_PROVIDERS="claude codex cursor"

aa_root() {
  echo "${AGENT_ACCOUNTS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-accounts}"
}

aa_valid_provider() {
  case ${1:-} in claude | codex | cursor) return 0 ;; esac
  return 1
}

# ^[a-z0-9][a-z0-9._-]{0,31}$, and not "default".
aa_valid_name() {
  local name=${1:-}
  # default is the normal home; active and accounts.json are registry files.
  case $name in default | active | accounts.json) return 1 ;; esac
  [[ ${#name} -ge 1 && ${#name} -le 32 ]] || return 1
  [[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# The provider's normal home. The CLI ignores CLAUDE_CONFIG_DIR / CODEX_HOME
# from its own environment: it often runs inside an agent session. Cursor's
# config dir is not switched per account (see aa_env_var), so its own lookup
# order applies.
aa_default_home() {
  case $1 in
    claude) echo "$HOME/.claude" ;;
    codex) echo "$HOME/.codex" ;;
    cursor)
      if [[ -n ${CURSOR_CONFIG_DIR:-} ]]; then
        echo "$CURSOR_CONFIG_DIR"
      elif [[ -n ${XDG_CONFIG_HOME:-} ]]; then
        echo "$XDG_CONFIG_HOME/cursor"
      else
        echo "$HOME/.cursor"
      fi
      ;;
  esac
}

aa_home() {
  if [[ $2 == default ]]; then
    aa_default_home "$1"
  else
    echo "$(aa_root)/$1/$2"
  fi
}

# The variable the shim sets. On macOS cursor-agent keeps its login in
# Keychain items with fixed names, not per config dir, so a Cursor account is
# an API key (the file api-key in its home) passed as CURSOR_API_KEY.
aa_env_var() {
  case $1 in
    claude) echo CLAUDE_CONFIG_DIR ;;
    codex) echo CODEX_HOME ;;
    cursor) echo CURSOR_API_KEY ;;
  esac
}

aa_meta_file() {
  echo "$(aa_root)/$1/accounts.json"
}

# The label and the tag of an account, empty when not set.
aa_meta() { # provider id field
  local file
  file=$(aa_meta_file "$1")
  [[ -r $file ]] || return 0
  jq -r --arg id "$2" --arg f "$3" '.[$id][$f] // empty | strings' "$file" 2>/dev/null
}

# Set (or, with an empty value, clear) the label or the tag of an account.
aa_meta_set() { # provider id field value
  local file dir tmp
  file=$(aa_meta_file "$1")
  dir=${file%/*}
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.accounts.json.XXXXXX") || return 1
  if { [[ -s $file ]] && cat "$file" || echo '{}'; } |
    jq --arg id "$2" --arg f "$3" --arg v "$4" '
      (if type == "object" then . else {} end)
      | if $v == "" then (if .[$id] then .[$id] |= del(.[$f]) else . end)
        else .[$id][$f] = $v end
      | with_entries(select(.value != {}))' >"$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# The name in the pointer file, or "default".
aa_active() {
  local file name=""
  file="$(aa_root)/$1/active"
  [[ -r $file ]] && IFS= read -r name <"$file"
  if aa_valid_name "$name"; then echo "$name"; else echo default; fi
}

# Entries of the shared home that hold the login or per-account state.
aa_excluded() {
  case $1:$2 in
    claude:.claude.json | claude:.credentials.json) return 0 ;;
    codex:auth.json | codex:auth.json.lock | codex:auth.lock) return 0 ;;
  esac
  return 1
}

# Link every entry of the shared home into the account home, to the path
# $HOME/.<provider>/<entry> (not to that entry's own target, so a change of
# the shared entry reaches every account). An entry that already exists in
# the account home is left alone.
aa_link_entries() {
  local provider=$1 home=$2 shared entry name
  shared=$(aa_default_home "$provider")
  [[ -d $shared ]] || return 0
  for entry in "$shared"/* "$shared"/.[!.]* "$shared"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    aa_excluded "$provider" "$name" && continue
    [[ -e $home/$name || -L $home/$name ]] && continue
    # A missing link would run the agent without that shared entry (hooks, skills).
    ln -s "$shared/$name" "$home/$name" 2>/dev/null || return 1
  done
  return 0
}

# Keys of ~/.claude.json that name the logged-in account.
AA_CLAUDE_IDENTITY_KEYS='["oauthAccount","userID","primaryApiKey","customApiKeyResponses","orgModelDefaultCache","penguinModeOrgEnabled"]'

# The account's .claude.json starts as ~/.claude.json without its identity.
aa_claude_seed() {
  local home=$1 dst="$1/.claude.json" src="$HOME/.claude.json" tmp
  [[ -e $dst ]] && return 0
  tmp=$(mktemp "$home/.claude.json.XXXXXX") || return 1
  chmod 600 "$tmp"
  if [[ -r $src ]]; then
    jq --argjson drop "$AA_CLAUDE_IDENTITY_KEYS" \
      'with_entries(select(.key as $k | $drop | index($k) | not))' "$src" >"$tmp" ||
      { rm -f "$tmp"; return 1; }
  else
    echo '{}' >"$tmp"
  fi
  mv -f "$tmp" "$dst"
}

# Copy the top-level mcpServers of ~/.claude.json (the user-scope MCP servers)
# into the account's .claude.json. A running session of the account also
# writes that file, so it is rewritten only when the value differs.
aa_claude_sync_mcp() {
  local dst="$1/.claude.json" src="$HOME/.claude.json" want have tmp
  [[ -r $src && -r $dst ]] || return 0
  want=$(jq -cS '.mcpServers' "$src" 2>/dev/null) || return 0
  have=$(jq -cS '.mcpServers' "$dst" 2>/dev/null) || return 0
  [[ $want == "$have" ]] && return 0
  tmp=$(mktemp "$1/.claude.json.XXXXXX") || return 0
  chmod 600 "$tmp"
  if jq --argjson m "$want" 'if $m == null then del(.mcpServers) else .mcpServers = $m end' \
    "$dst" >"$tmp"; then
    mv -f "$tmp" "$dst"
  else
    rm -f "$tmp"
  fi
}

# Bring an account home up to date: links, and for Claude its .claude.json.
aa_refresh() {
  local provider=$1 home=$2
  [[ $provider == cursor ]] && return 0
  aa_link_entries "$provider" "$home" || return 1
  if [[ $provider == claude ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "agent-account: jq not found; $home/.claude.json is not updated" >&2
      return 0
    fi
    aa_claude_seed "$home" || return 1
    aa_claude_sync_mcp "$home" || return 1
  fi
  return 0
}

