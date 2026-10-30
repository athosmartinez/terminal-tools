#!/usr/bin/env bash
set -uo pipefail

MONITOR=$(dirname "$(readlink -f "$0")")/../monitor-linux
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat >"$WORK/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$HYPRCTL_LOG"
[[ $1 == monitors ]] && cat "$HYPRCTL_FIXTURE"
exit 0
EOF
chmod +x "$WORK/bin/hyprctl"

export PATH=$WORK/bin:$PATH
export HYPRCTL_LOG=$WORK/calls
export HYPRCTL_FIXTURE=$WORK/monitors.json
export MONITOR_LID_DIR=$WORK/lid
export XDG_RUNTIME_DIR=$WORK
PAUSE_MARK=$WORK/terminal-tools-monitor.pause
mkdir -p "$WORK/lid/LID"

passed=0
failed=0

mon() { printf '{"name":"%s","disabled":%s,"dpmsStatus":%s}' "$1" "$2" "$3"; }

lid() { echo "state:      $1" >"$WORK/lid/LID/state"; }

given() {
  local IFS=,
  echo "[$*]" >"$HYPRCTL_FIXTURE"
  : >"$HYPRCTL_LOG"
  lid open
  rm -f "$PAUSE_MARK"
}

monitor() {
  OUT=$("$MONITOR" "$@" 2>/dev/null)
  CODE=$?
  CALLS=$(grep -v '^monitors' "$HYPRCTL_LOG")
}

check() {
  if eval "$2"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1"
    echo "  out=$OUT code=$CODE"
    echo "  calls=$CALLS"
  fi
}

given "$(mon eDP-1 false true)"
monitor status
check "status is absent with no external display" '[[ $OUT == absent ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor status
check "status is on when the external display is lit" '[[ $OUT == on ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 true true)"
monitor status
check "status is off when the external display is disabled" '[[ $OUT == off ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false false)"
monitor status
check "status is off when the external display is asleep" '[[ $OUT == off ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor
check "status is the default command" '[[ $OUT == on ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor off
check "off disables only the external display" \
  '[[ $CODE == 0 && $CALLS == "eval hl.monitor({ output = \"HDMI-A-1\", disabled = true })" ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 false true)"
monitor off
check "off refuses when the built-in display is inactive" '[[ $CODE != 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)"
monitor off
check "off fails with no external display" '[[ $CODE != 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 true true)"
monitor on
check "on reloads Hyprland to restore a disabled display" '[[ $CODE == 0 && $CALLS == reload ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false false)"
monitor on
check "on wakes an asleep display without a reload" \
  '[[ $CODE == 0 && $CALLS == "dispatch hl.dsp.dpms({ action = \"enable\", monitor = \"HDMI-A-1\" })" ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor on
check "on fails when the external display is already on" '[[ $CODE != 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor pause 0
check "pause disables the external display and then reloads Hyprland" \
  '[[ $CODE == 0 && $CALLS == "eval hl.monitor({ output = \"HDMI-A-1\", disabled = true })"$'"'\n'"'"reload" ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 false true)"
monitor pause 0
check "pause works with the lid closed" '[[ $CODE == 0 && -n $CALLS ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor pause abc
check "pause rejects a non-numeric duration" '[[ $CODE != 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 true true)"
monitor pause 0
check "pause fails when the external display is already off" '[[ $CODE != 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
lid closed
monitor off
check "off refuses when the lid is closed even with the built-in display enabled" '[[ $CODE != 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 false true)"
monitor pause 0
check "pause removes its marker when it ends" '[[ $CODE == 0 && ! -e $PAUSE_MARK ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 true true)"
lid closed
monitor auto
check "auto turns a disabled external display on when the lid is closed" '[[ $CODE == 0 && $CALLS == reload ]]'

given "$(mon eDP-1 false true)" "$(mon HDMI-A-1 true true)"
monitor auto
check "auto does nothing when the lid is open" '[[ $CODE == 0 && -z $CALLS ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 false false)"
lid closed
monitor auto
check "auto leaves an asleep display alone" '[[ $CODE == 0 && -z $CALLS ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 true true)"
lid closed
echo $$ >"$PAUSE_MARK"
monitor auto
check "auto leaves a running pause alone" '[[ $CODE == 0 && -z $CALLS ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 true true)"
lid closed
echo 999999 >"$PAUSE_MARK"
monitor auto
check "auto ignores a marker left by a dead pause" '[[ $CODE == 0 && $CALLS == reload ]]'

given "$(mon eDP-1 true true)" "$(mon HDMI-A-1 true true)"
rm -rf "$WORK/lid/LID"
monitor auto
mkdir -p "$WORK/lid/LID"
check "auto treats a machine without a lid as open" '[[ $CODE == 0 && -z $CALLS ]]'

given "$(mon eDP-1 false true)"
monitor bogus
check "an unknown command fails" '[[ $CODE != 0 ]]'

echo "$passed passed, $failed failed"
((failed == 0))
