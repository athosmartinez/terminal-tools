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

# ── IP index ─────────────────────────────────────────────────────────────────
# Turns the four raw kubectl dumps in <dir> into one TSV row per IP:
#   ip \t type \t ns \t kind \t name \t extra
# Sorted numerically by IP, so subnets group together instead of sorting as
# text  10.9 before 10.42 . Split from ip_index so it can be exercised with
# fixture files, with no cluster in reach.
_ip_rows() {
  local d=$1
  awk -v OFS='\t' -v podf="$d/pods" -v svcf="$d/svc" -v nodef="$d/nodes" -v ingf="$d/ing" '
    function key(ip,   a, n) {
      n = split(ip, a, ".")
      if (n != 4) return "0000000000"
      return sprintf("%010d", ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4])
    }
    function emit(ip, type, ns, kind, name, extra) {
      if (ip == "" || ip == "<none>" || ip == "None") return
      print key(ip), ip, type, ns, kind, name, extra
    }
    function emit_list(list, type, ns, kind, name, extra,   parts, m, i) {
      m = split(list, parts, ",")
      for (i = 1; i <= m; i++) emit(parts[i], type, ns, kind, name, extra)
    }
    BEGIN {
      while ((getline l < podf) > 0) {
        n = split(l, a, " "); if (n < 5) continue
        emit(a[3], "pod", a[1], "pod", a[2], a[4] " · " a[5])
      }
      while ((getline l < svcf) > 0) {
        n = split(l, a, " "); if (n < 6) continue
        emit(a[3], "svc", a[1], "svc", a[2], "ClusterIP · " a[6])
        emit_list(a[5], "svc", a[1], "svc", a[2], "ExternalIP · " a[4])
      }
      while ((getline l < nodef) > 0) {
        n = split(l, a, " "); if (n < 4) continue
        st = (a[4] == "True") ? "Ready" : "NotReady"
        emit_list(a[2], "node", "-", "node", a[1], "InternalIP · " st)
        emit_list(a[3], "node", "-", "node", a[1], "ExternalIP · " st)
      }
      while ((getline l < ingf) > 0) {
        n = split(l, a, " "); if (n < 4) continue
        emit_list(a[3], "ingress", a[1], "ingress", a[2], "ExternalIP · " a[4])
      }
      exit
    }' | sort -t$'\t' -k1,1 | cut -f2-
}

# Every IP in the cluster: pod IPs, Service ClusterIPs and external LoadBalancer
# IPs, node internal/external addresses, ingress external IPs. The four kubectl
# calls are independent and run in parallel  wall time ≈ slowest single call .
ip_index() {
  local tmp; tmp=$(mktemp -d) || die "mktemp failed"
  ( kubectl get pods -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName,PHASE:.status.phase' 2>/dev/null > $tmp/pods ) &
  ( kubectl get svc -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CIP:.spec.clusterIP,TYPE:.spec.type,EIP:.status.loadBalancer.ingress[*].ip,PORTS:.spec.ports[*].port' 2>/dev/null > $tmp/svc ) &
  ( kubectl get nodes --no-headers \
      -o custom-columns='NAME:.metadata.name,INT:.status.addresses[?(@.type=="InternalIP")].address,EXT:.status.addresses[?(@.type=="ExternalIP")].address,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null > $tmp/nodes ) &
  ( kubectl get ingress -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.loadBalancer.ingress[*].ip,HOST:.spec.rules[*].host' 2>/dev/null > $tmp/ing ) &
  wait
  _ip_rows $tmp
  rm -rf $tmp
}

# Filters the TSV index on stdin down to <ip>, most relevant row first.
# Priority node > pod > svc > ingress. A hostNetwork pod does not have an
# address of its own — it borrows its node's, and a managed cluster runs several
# such DaemonSets per node, so a node address matches the node plus a handful of
# borrowers whose order is an alphabetical accident. The address is the node's;
# the pods are the borrowers. Returns 1 on no match.
ip_lookup() {
  local ip=$1 out
  out=$(awk -F'\t' -v ip="$ip" '
    function rank(t) { return (t == "node") ? 1 : (t == "pod") ? 2 : (t == "svc") ? 3 : 4 }
    $1 == ip { print rank($2) "\t" $0 }' | sort -t$'\t' -k1,1 | cut -f2-)
  [[ -z $out ]] && return 1
  print -r -- "$out"
}

# True when the string is a complete IPv4 address. Deliberately IPv4-only:
# partial addresses are what the kube ips view filters interactively.
is_ipv4() { [[ $1 == <0-255>.<0-255>.<0-255>.<0-255> ]] }

# Label selector of a Service as k=v,k=v. Empty for headless or ExternalName
# services, which select nothing.
svc_selector() {
  local ns=$1 name=$2 sel
  sel=$(kubectl get svc $name -n $ns \
        -o go-template='{{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}' 2>/dev/null)
  print -- ${sel%,}
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
