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
#
# Several starts of one account can run at the same time. `ln -sn` never
# follows an existing link (`ln -s` onto a link to a folder writes a link into
# the shared folder), and a link that another start made first is accepted.
aa_link_to() { # target dst
  ln -sn "$1" "$2" 2>/dev/null && return 0
  [[ -L $2 && $(readlink "$2") == "$1" ]]
}

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
    aa_link_to "$shared/$name" "$home/$name" || [[ -e $home/$name || -L $home/$name ]] || return 1
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

aa_say() { echo "agent-account: $*" >&2; }

# The user-scope MCP servers of ~/.claude.json (its top-level mcpServers), as
# a JSON object; {} when there are none.
aa_claude_shared_mcp() {
  [[ -r $HOME/.claude.json ]] || { echo '{}'; return 0; }
  jq -c '.mcpServers | if type == "object" then . else {} end' "$HOME/.claude.json" 2>/dev/null ||
    echo '{}'
}

# The names of the shared MCP servers ($2, a JSON object) that the
# .claude.json $1 lacks or defines another way, joined by ", ". Fails when $1
# is not a JSON object or its mcpServers is not an object.
aa_claude_mcp_missing() {
  jq -er --argjson m "$2" '
    if type != "object" then error("not an object") else . end
    | (.mcpServers // {}) as $h
    | if ($h | type) != "object" then error("mcpServers is not an object") else . end
    | [$m | to_entries[] | select($h[.key] != .value) | .key] | join(", ")' "$1" 2>/dev/null
}

# Merge the user-scope MCP servers of ~/.claude.json into the account's
# .claude.json: a server of ~/.claude.json is added, or replaced when its
# definition differs; a server that only the account has is kept (a server
# removed from ~/.claude.json stays in the account: `check` lists it).
# A running session of the account also writes that file, so it is rewritten
# only when a server is missing or different, from a copy, and only when the
# file still equals that copy just before the rename (else it tries again).
# Exit 1, with a message, when the file cannot be read or written.
aa_claude_sync_mcp() {
  local home=$1 dst="$1/.claude.json" want names snap tmp try
  [[ -e $dst ]] || return 0
  want=$(aa_claude_shared_mcp)
  [[ $want == "{}" ]] && return 0
  for try in 1 2 3; do
    snap=$(mktemp "$home/.claude.json.XXXXXX") || { aa_say "cannot write in $home"; return 1; }
    tmp=$(mktemp "$home/.claude.json.XXXXXX") || { rm -f "$snap"; aa_say "cannot write in $home"; return 1; }
    chmod 600 "$snap" "$tmp"
    if ! cp "$dst" "$snap" || ! names=$(aa_claude_mcp_missing "$snap" "$want"); then
      rm -f "$snap" "$tmp"
      aa_say "$dst is not valid JSON or its mcpServers is not an object; MCP servers not synced"
      return 1
    fi
    if [[ -z $names ]]; then
      rm -f "$snap" "$tmp"
      return 0
    fi
    if ! jq --argjson m "$want" '.mcpServers = ((.mcpServers // {}) + $m)' "$snap" >"$tmp" 2>/dev/null; then
      rm -f "$snap" "$tmp"
      aa_say "cannot update $dst; MCP servers not synced"
      return 1
    fi
    if cmp -s "$snap" "$dst"; then
      rm -f "$snap"
      mv -f "$tmp" "$dst" || { rm -f "$tmp"; aa_say "cannot replace $dst"; return 1; }
      aa_say "$dst: MCP servers added or updated: $names"
      return 0
    fi
    rm -f "$snap" "$tmp"
  done
  aa_say "$dst kept changing (a running session writes it); MCP servers not synced, try again"
  return 1
}

# Entries of ~/.claude that every Claude account must link. Claude Code can
# write them into a new home before its links exist (a login, /config), and
# aa_link_entries leaves an existing entry alone: the account then runs with
# its own settings (no hooks, no env, no enabled plugins) and an empty plugin
# folder.
AA_CLAUDE_SHARED="settings.json plugins"

# <path>.bak.<date-time>.<pid>: two starts at the same second never pick the
# same name. A number is added when that name exists.
aa_backup_path() {
  local base path n=1
  base="$1.bak.$(date +%Y%m%d-%H%M%S).$$"
  path=$base
  while [[ -e $path || -L $path ]]; do
    path="$base.$n"
    n=$((n + 1))
  done
  echo "$path"
}

# Make each AA_CLAUDE_SHARED entry of the account a link to
# $HOME/.claude/<entry>. What is there instead (a file, a folder, a link to
# somewhere else) is moved to a backup first, never deleted. When another
# start of the same account did it first, its link is accepted.
aa_claude_link_shared() {
  local home=$1 shared name target dst bak
  shared=$(aa_default_home claude)
  for name in $AA_CLAUDE_SHARED; do
    target="$shared/$name"
    dst="$home/$name"
    [[ -e $target || -L $target ]] || continue
    [[ -L $dst && $(readlink "$dst") == "$target" ]] && continue
    if [[ -e $dst || -L $dst ]]; then
      bak=$(aa_backup_path "$dst")
      if ! mv "$dst" "$bak" 2>/dev/null; then
        aa_link_to "$target" "$dst" || return 1
        continue
      fi
      # Another start can have put its link in place between the check and
      # the mv: that link is in $bak now, and it is not a backup.
      if [[ -L $bak && $(readlink "$bak") == "$target" ]]; then
        rm -f "$bak"
        aa_link_to "$target" "$dst" || return 1
        continue
      fi
      if ! aa_link_to "$target" "$dst"; then
        [[ -e $dst || -L $dst ]] || mv "$bak" "$dst"
        return 1
      fi
      aa_say "$dst was the account's own; moved it to $bak and linked $target"
    else
      aa_link_to "$target" "$dst" || return 1
    fi
  done
  return 0
}

# One refresh of a home at a time: several agents of one account often start
# together, and two backups of one settings.json must not cross. The lock is
# a folder (mkdir is atomic, and bash 3.2 on macOS has no flock) with the pid
# of its owner. A lock whose owner is gone is taken over. Waits up to 10 s.
aa_lock() { # home
  local lock="$1/.agent-account.lock" pid="" tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    # No lock there: its owner just removed it (try again), or the home is
    # not writable (fail now).
    if [[ ! -d $lock ]]; then
      [[ -w $1 ]] || return 1
      continue
    fi
    pid=""
    [[ -r $lock/pid ]] && IFS= read -r pid <"$lock/pid"
    # No pid yet: the owner is between its mkdir and its write; wait 2 s.
    if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null || { [[ -z $pid ]] && ((tries >= 20)); }; then
      rm -rf "$lock"
      continue
    fi
    tries=$((tries + 1))
    if ((tries > 100)); then
      aa_say "$lock is held by pid ${pid:-unknown}; if no agent-account or agent start runs, remove it"
      return 1
    fi
    sleep 0.1
  done
  echo $$ >"$lock/pid"
}

aa_unlock() { rm -rf "$1/.agent-account.lock"; }

# Bring an account home up to date: links, and for Claude its .claude.json.
# Exit 1: the home cannot be prepared. Exit 2: the home is ready, but its MCP
# servers are not synced (the message says why); the shim still starts.
aa_refresh() {
  local rc
  [[ $1 == cursor ]] && return 0
  aa_lock "$2" || return 1
  aa_refresh_locked "$@"
  rc=$?
  aa_unlock "$2"
  return $rc
}

aa_refresh_locked() {
  local provider=$1 home=$2
  aa_link_entries "$provider" "$home" || return 1
  if [[ $provider == claude ]]; then
    aa_claude_link_shared "$home" || return 1
    if ! command -v jq >/dev/null 2>&1; then
      echo "agent-account: jq not found; $home/.claude.json is not updated" >&2
      return 0
    fi
    aa_claude_seed "$home" || return 1
    aa_claude_sync_mcp "$home" || return 2
  fi
  return 0
}

