#!/usr/bin/env zsh
#
# kubetui.zsh — shared library for the kube TUI tools (logs, kube).
# Sourced by each entry point. Never executed directly.
# Text in English. Depends on: kubectl, fzf.

DELIM=$'\037'
typeset -gi TAIL=100
KUBETUI_PALETTE="36 32 35 34 31"

die()  { print -P "%F{red}✗  $1%f" >&2; exit 1 }
need() { command -v $1 >/dev/null 2>&1 || die "$1 not found — $2" }

# Reads a y/N answer from the terminal (never from a pipe).
confirm() {
  local prompt=$1 reply
  read -q "reply?$prompt [y/N] " </dev/tty 2>/dev/null
  print
  [[ $reply == [yY] ]]
}

# ── data collection ──────────────────────────────────────────────────────────
collect_workloads() {
  local tmp; tmp=$(mktemp -d) || die "mktemp failed"
  local cols='NS:.metadata.namespace,NAME:.metadata.name,R:.status.readyReplicas,D:.spec.replicas,DR:.status.numberReady,DD:.status.desiredNumberScheduled'
  local kind
  for kind in deploy sts ds; do
    kubectl get $kind -A --no-headers -o custom-columns=$cols 2>/dev/null \
      | awk -v k=$kind '
          {
            ready = ($3=="<none>") ? $5 : $3
            des   = ($4=="<none>") ? $6 : $4
            if (ready=="<none>") ready = 0
            if (des=="<none>")   des   = 0
            print $1 "\t" $2 "\t" k "\t" ready "/" des
          }' > $tmp/$kind &
  done
  wait
  cat $tmp/deploy $tmp/sts $tmp/ds 2>/dev/null | sort -t$'\t' -k1,1 -k2,2
  rm -rf $tmp
}

to_fzf_lines() {
  awk -F'\t' -v d="$DELIM" -v pal_s="$KUBETUI_PALETTE" '
    BEGIN { n = split(pal_s, pal, " ") }
    {
      if (!($1 in c)) c[$1] = pal[(i++ % n) + 1]
      split($4, r, "/"); ready = r[1] + 0; des = r[2] + 0
      rc = (des == 0) ? "38;5;243" : (ready == des) ? "32" : (ready == 0) ? "31" : "33"
      printf "\033[%sm%-20.20s\033[0m  \033[1m%-36.36s\033[0m  \033[38;5;243m%-7s\033[0m  \033[%sm%-7s\033[0m%s%s%s%s%s%s\n",
        c[$1], $1, $2, $3, rc, $4,  d, $1, d, $3, d, $2 }
  '
}

# Colors the "[pod/.../...]" prefix added by kubectl --prefix — one color per
# pod/container, cycling a fixed palette — and drops the constant "pod/" part.
# Log content itself is left untouched. Colors are skipped when stdout is not
# a terminal (pipes, files) unless forced with -f (used by fzf previews).
colorize() {
  [[ $1 != -f && ! -t 1 ]] && { cat; return }
  awk -v pal_s="$KUBETUI_PALETTE" '
    BEGIN { n = split(pal_s, pal, " ") }
    {
      if (match($0, /^\[[^]]*\] /)) {
        p = substr($0, 1, RLENGTH - 1)
        rest = substr($0, RLENGTH)
        sub(/^\[pod\//, "[", p)
        if (!(p in c)) c[p] = pal[(i++ % n) + 1]
        printf "\033[%sm%s\033[0m%s\n", c[p], p, rest
      } else print
      fflush()
    }
  '
}

# Colors pod STATUS words in place (Running green, failures red, transitions
# yellow, finished dim) without touching column alignment. Only ever feeds fzf
# lists and previews, so it always emits color.
color_status() {
  awk '
    {
      gsub(/CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|Evicted|Error|Failed/, "\033[31m&\033[0m")
      gsub(/Running/, "\033[32m&\033[0m")
      gsub(/Pending|ContainerCreating|PodInitializing|Terminating|NotReady|Init:[0-9]+\/[0-9]+/, "\033[33m&\033[0m")
      gsub(/Completed|Succeeded/, "\033[38;5;243m&\033[0m")
      print
    }
  '
}

# ── follow engine ────────────────────────────────────────────────────────────
resolve_selector() {
  local ns=$1 kind=$2 name=$3 sel
  sel=$(kubectl get $kind $name -n $ns \
        -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)
  print -- ${sel%,}
}

follow_workload() {
  local ns=$1 kind=$2 name=$3
  local -i tail=$4 npods
  local sel; sel=$(resolve_selector $ns $kind $name)
  [[ -z $sel ]] && { print -P "%F{red}✗  could not resolve selector of $kind/$name in $ns%f"; return 1 }

  while true; do
    npods=$(kubectl get pods -n $ns -l $sel --no-headers 2>/dev/null | grep -c '')
    if (( npods == 0 )); then
      print -P "%F{yellow}⏳ $ns/$name: waiting for pods... (Ctrl-C to quit)%f"
      sleep 3
      continue
    fi
    print -P "%B%F{cyan}▶ following $ns/$name ($npods pod(s)) — Ctrl-C to quit%f%b"
    print -P "%F{cyan}\$%f kubectl logs -f -n $ns -l $sel --tail=$tail --prefix --all-containers --max-log-requests=20"
    kubectl logs -f -n $ns -l $sel --tail=$tail --prefix --all-containers --max-log-requests=20 | colorize
    (( $pipestatus[1] == 130 )) && return 130
    tail=10
    print -P "%F{yellow}↻ stream ended — reconnecting...%f"
    sleep 2
  done
}

follow_pod() {
  local ns=$1 pod=$2
  local -i tail=$3
  while true; do
    print -P "%B%F{cyan}▶ following pod $ns/$pod — Ctrl-C to quit%f%b"
    print -P "%F{cyan}\$%f kubectl logs -f -n $ns $pod --tail=$tail --prefix --all-containers"
    kubectl logs -f -n $ns $pod --tail=$tail --prefix --all-containers | colorize
    (( $pipestatus[1] == 130 )) && return 130
    kubectl get pod -n $ns $pod >/dev/null 2>&1 || { print -P "%F{red}✗  pod $pod no longer exists%f"; return 1 }
    tail=10
    print -P "%F{yellow}↻ stream ended — reconnecting...%f"
    sleep 2
  done
}

# ── preview panes (called by each entry point via $SELF) ─────────────────────
do_preview() {
  local ns=$1 kind=$2 name=$3
  local sel; sel=$(resolve_selector $ns $kind $name)
  [[ -z $sel ]] && { print -- "no selector for $kind/$name"; return }
  # Full container images (with registry) — the table view abbreviates them.
  print -P "%B%F{cyan}Image(s)%f%b"
  kubectl get $kind $name -n $ns \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}  {.image}{"\n"}{end}' 2>/dev/null | sed 's/^/  /'
  print
  # -o wide adds the pod IP (and node) columns.
  print -P "%B%F{cyan}Pods ($ns)%f%b"
  kubectl get pods -n $ns -l $sel -o wide 2>/dev/null | color_status
  print
  # Services fronting this workload — their ClusterIP is the stable virtual IP
  # for the deployment (a Deployment itself has no IP of its own).
  print -P "%B%F{cyan}Services (ClusterIP)%f%b"
  local first=${sel%%,*}
  local svcs; svcs=$(kubectl get svc -n $ns -o wide 2>/dev/null | awk -v f="$first" 'NR==1 || (f!="" && index($0, f))')
  if [[ $(print -r -- "$svcs" | grep -c '') -le 1 ]]; then
    print -- "(no service selecting $first)"
  else
    print -r -- "$svcs"
  fi
  print
  print -P "%B%F{cyan}── last lines ──%f%b"
  kubectl logs -n $ns -l $sel --tail=6 --prefix --all-containers 2>/dev/null | tail -20 | colorize -f
}

do_preview_pod() {
  local ns=$1 pod=$2
  # Pod IP shown by the leading line; also called out explicitly for quick copy.
  local ip; ip=$(kubectl get pod -n $ns $pod -o jsonpath='{.status.podIP}' 2>/dev/null)
  print -P "%B%F{cyan}IP:%f%b ${ip:-<none>}"
  print
  # Full container images (with registry) — the table view abbreviates them.
  print -P "%B%F{cyan}Image(s)%f%b"
  kubectl get pod -n $ns $pod \
    -o jsonpath='{range .spec.containers[*]}{.name}  {.image}{"\n"}{end}' 2>/dev/null | sed 's/^/  /'
  print
  kubectl get pod -n $ns $pod -o wide 2>/dev/null | color_status
  print
  print -P "%B%F{cyan}── last lines ──%f%b"
  kubectl logs -n $ns $pod --tail=15 --prefix --all-containers 2>/dev/null | colorize -f
}

# ── pod view (follow / previous / delete) ────────────────────────────────────
# pods_picker <query> <mode> [<ns> <selector>]
pods_picker() {
  local query=$1 mode=$2 ns=$3 selector=$4
  # -o wide surfaces the pod IP (and node) columns in the list itself.
  local input
  if [[ -n $ns && -n $selector ]]; then
    input=$(kubectl get pods -n $ns -l $selector -o wide 2>/dev/null | color_status)
  else
    input=$(kubectl get pods -A -o wide 2>/dev/null | color_status)
  fi
  [[ $(print -r -- "$input" | grep -c '') -le 1 ]] && { print -P "%F{yellow}no pods found%f"; return 1 }

  local hdr
  case $mode in
    previous) hdr=$'\033[38;5;243mEnter show PREVIOUS container logs · Esc quit\033[0m' ;;
    delete)   hdr=$'\033[38;5;243mEnter DELETE pod (confirm) · Esc quit\033[0m' ;;
    *)        hdr=$'\033[38;5;243mEnter follow · Esc quit\033[0m' ;;
  esac

  # With ns+selector the namespace column is absent, so pod name shifts to col 1.
  local pcol='{1} {2}'
  [[ -n $ns ]] && pcol="$ns {1}"

  local out
  out=$(print -r -- "$input" | fzf --ansi --header-lines=1 --query="$query" \
    --prompt='pods> ' --header=$hdr \
    --layout=reverse --info=inline --pointer='▸' \
    --preview="$SELF --preview-pod $pcol" \
    --preview-window='right,55%,wrap') || return 0
  [[ -z $out ]] && return 0

  local f1=${${(z)out}[1]} f2=${${(z)out}[2]}
  local pns pod
  if [[ -n $ns ]]; then pns=$ns; pod=$f1; else pns=$f1; pod=$f2; fi

  case $mode in
    previous)
      kubectl logs -n $pns $pod -p --prefix --all-containers --tail=$TAIL 2>&1 | colorize
      (( $pipestatus[1] != 0 )) && print -P "%F{yellow}(no previous container — pod never restarted?)%f"
      ;;
    delete)
      confirm "delete pod $pod -n $pns —" || { print -- "cancelled."; return }
      run_or_dry kubectl delete pod $pod -n $pns
      ;;
    *)
      follow_pod $pns $pod $TAIL
      ;;
  esac
}

# Executes a mutating command, or prints it when KUBETUI_DRYRUN=1.
run_or_dry() {
  if [[ -n $KUBETUI_DRYRUN ]]; then
    print -P "%F{yellow}[dry-run]%f $*"
  else
    "$@"
  fi
}

# Pages colored text: less -R (keeps ANSI) when available, else plain cat.
# Deliberately does not honor $PAGER, since -R is a less-only flag.
page() {
  if command -v less >/dev/null 2>&1; then
    less -R
  else
    cat
  fi
}

# ── command transparency & maintenance helpers ───────────────────────────────
# Prints a command in a teaching style: "$ kubectl ..." (dim $, normal cmd), so
# the user learns the real command behind every action.
show_cmd() { print -P "%F{cyan}\$%f ${(j: :)@}" }

# Echoes the command, then runs it (or dry-runs it). Use for mutations.
run_cmd() {
  show_cmd "$@"
  run_or_dry "$@"
}

# Copies text to the clipboard (macOS pbcopy); warns if unavailable.
clip() {
  if command -v pbcopy >/dev/null 2>&1; then
    print -rn -- "$1" | pbcopy
    print -P "%F{green}✓ copied to clipboard%f"
  else
    print -P "%F{yellow}pbcopy not available%f"
  fi
}

# Smallest free TCP port >= base (default 8080). Uses lsof; falls back to base.
free_port() {
  local -i p=${1:-8080}
  while (( p < 65535 )); do
    lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 || { print -- $p; return }
    (( p++ ))
  done
  print -- ${1:-8080}
}

# Strong confirmation: the user must type an exact word (e.g. the node name).
confirm_strong() {
  local word=$1 prompt=$2 reply
  print -n -- "$prompt (type '$word' to confirm) > "
  read reply </dev/tty
  [[ $reply == $word ]]
}
