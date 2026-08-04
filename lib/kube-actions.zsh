#!/usr/bin/env zsh
# kube-actions.zsh — action registry, command builders, menu, execution.
# Sourced by kube. Text in English.

typeset -gA A_LABEL A_KEY A_APPLIES A_CONFIRM A_DESC
typeset -ga A_ORDER
_reg() { A_ORDER+=($1); A_LABEL[$1]=$2; A_KEY[$1]=$3; A_APPLIES[$1]=$4; A_CONFIRM[$1]=$5; A_DESC[$1]=$6 }

#     id           label                 key      applies                                    conf  desc
_reg logs        "Follow logs"          enter  "wl pod job"                                 0 "Stream logs of all pods, auto-reconnecting."
_reg logs-prev   "Previous logs"        ""     "pod"                                        0 "Logs of the previous (crashed) container."
_reg describe    "Describe + events"    ctrl-d "wl pod node ingress secret cm job cronjob svc"  0 "Describe the object and its recent events."
_reg yaml        "View YAML"            ctrl-y "wl pod node ingress secret cm job cronjob svc"  0 "Full manifest as YAML."
_reg restart     "Rollout restart"      ctrl-r "wl"                                         1 "Rolling restart of the workload."
_reg scale       "Scale"                ctrl-s "deploy sts"                                 1 "Set the replica count."
_reg scale-zero  "Scale to zero"        ""     "deploy sts"                                 1 "Scale down to 0 replicas."
_reg rollback    "Rollback (undo)"      ""     "wl"                                         1 "Undo the last rollout."
_reg watch-roll  "Watch rollout"        ""     "wl"                                         0 "Follow rollout status until complete."
_reg set-image   "Set image / tag"      ""     "wl"                                         1 "Update a container image."
_reg delete-pod  "Delete pod"           ctrl-x "pod"                                        1 "Delete the pod (controller recreates it)."
_reg del-res     "Delete"               ""     "secret cm ingress job"                      1 "Delete the resource."
_reg exec        "Exec / shell"         ""     "pod"                                        0 "Open an interactive shell in the pod."
_reg pf          "Port-forward"         ""     "pod svc deploy sts"                         0 "Forward a local port to the resource."
_reg cordon      "Cordon"               ""     "node"                                       1 "Mark node unschedulable."
_reg uncordon    "Uncordon"             ""     "node"                                       1 "Mark node schedulable again."
_reg drain       "Drain"                ""     "node"                                       2 "Evict pods and cordon the node."
_reg cp          "Copy file (cp)"       ""     "pod"                                        1 "Copy a file out of the pod."
_reg trigger     "Trigger now"          ""     "cronjob"                                    1 "Create a Job from the CronJob now."
_reg reveal      "Reveal (decode)"      enter  "secret"                                     2 "Show decoded secret values."
_reg view-cm     "View data"            enter  "cm"                                         0 "Show configmap data."
_reg open-url    "Open URL"             enter  "ingress"                                    0 "Open/copy the ingress URL."
_reg pods-on     "Pods on node"         enter  "node"                                       0 "List pods scheduled on this node."

# True (0) if action <id> applies to a row of <type>/<kind>.
applies() {
  local id=$1 type=$2 kind=$3 tok
  for tok in ${(s: :)A_APPLIES[$id]}; do
    [[ $tok == $type || $tok == $kind ]] && return 0
  done
  return 1
}

desc_for() { print -r -- "${A_DESC[$1]}" }

# Builds the real command into global array CMD. Interactive extras (replicas,
# image, ports, paths) come as positional args; when absent, placeholders show
# the command shape for the menu preview.
cmd_argv() {
  local id=$1 type=$2 ns=$3 kind=$4 name=$5; shift $(( $# < 5 ? $# : 5 ))
  local sel
  case $id in
    logs)
      if [[ $type == pod ]]; then CMD=(kubectl logs -f -n $ns $name --tail=100 --prefix --all-containers)
      elif [[ $type == job ]]; then CMD=(kubectl logs -f -n $ns job/$name --tail=100)
      else sel=$(resolve_selector $ns $kind $name); CMD=(kubectl logs -f -n $ns -l ${sel:-'<selector>'} --tail=100 --prefix --all-containers --max-log-requests=20); fi ;;
    logs-prev)  CMD=(kubectl logs -n $ns $name -p --prefix --all-containers --tail=100) ;;
    describe)   CMD=(kubectl describe ${kind:-$type} $name -n $ns) ;;
    yaml)       CMD=(kubectl get ${kind:-$type} $name -n $ns -o yaml) ;;
    restart)    CMD=(kubectl rollout restart $kind $name -n $ns) ;;
    scale)      CMD=(kubectl scale $kind $name -n $ns --replicas=${1:-'<N>'}) ;;
    scale-zero) CMD=(kubectl scale $kind $name -n $ns --replicas=0) ;;
    rollback)   CMD=(kubectl rollout undo $kind $name -n $ns) ;;
    watch-roll) CMD=(kubectl rollout status $kind $name -n $ns -w) ;;
    set-image)  CMD=(kubectl set image $kind $name ${1:-'<container>'}=${2:-'<image>'} -n $ns) ;;
    delete-pod) CMD=(kubectl delete pod $name -n $ns) ;;
    del-res)    CMD=(kubectl delete ${kind:-$type} $name -n $ns) ;;
    exec)       CMD=(kubectl exec -it -n $ns $name -- sh -c 'bash || sh') ;;
    pf)         CMD=(kubectl port-forward -n $ns ${kind:-pod}/$name ${1:-'<Lport>'}:${2:-'<Rport>'}) ;;
    cordon)     CMD=(kubectl cordon $name) ;;
    uncordon)   CMD=(kubectl uncordon $name) ;;
    drain)      CMD=(kubectl drain $name --ignore-daemonsets --delete-emptydir-data) ;;
    cp)         CMD=(kubectl cp $ns/$name:${1:-'<src>'} ${2:-'<dst>'}) ;;
    trigger)    CMD=(kubectl create job --from=cronjob/$name $name-manual-${1:-'<ts>'} -n $ns) ;;
    reveal)     CMD=(kubectl get secret $name -n $ns -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}') ;;
    view-cm)    CMD=(kubectl get configmap $name -n $ns -o go-template='{{range $k,$v := .data}}{{$k}}:{{"\n"}}{{$v}}{{"\n\n"}}{{end}}') ;;
    open-url)   CMD=(open '<url>') ;;
    pods-on)    CMD=(kubectl get pods -A -o wide --field-selector spec.nodeName=$name) ;;
    *)          CMD=(true) ;;
  esac
}

# ── menu + execution ─────────────────────────────────────────────────────────
# Actions menu for the selected item. Preview shows the resolved command; Enter
# runs it; Ctrl-Y copies the command to the clipboard.
actions_menu() {
  local type=$1 ns=$2 kind=$3 name=$4 d=$DELIM
  local lines="" id
  for id in $A_ORDER; do
    applies $id $type $kind || continue
    local keyhint=${A_KEY[$id]:+"  [${A_KEY[$id]}]"}
    lines+="$(printf '%-22s\033[38;5;243m%s\033[0m' "${A_LABEL[$id]}" "$keyhint")$d$id"$'\n'
  done
  [[ -z $lines ]] && { print -P "%F{yellow}no actions for $type%f"; sleep 1; return }
  local out key sel
  out=$(print -rn -- "$lines" | fzf --ansi --delimiter="$d" --with-nth=1 \
    --prompt='action> ' --layout=reverse --info=inline --pointer='▸' \
    --header=$'\033[38;5;243mEnter run · ^Y copy command · Esc back\033[0m' \
    --expect=enter,ctrl-y \
    --preview="$SELF --cmd {2} '$type' '$ns' '$kind' '$name'; echo; echo; $SELF --desc {2}" \
    --preview-window='right,58%,wrap')
  key=$(head -1 <<< $out); sel=$(sed -n 2p <<< $out)
  local aid=${sel##*$d}
  [[ -z $aid ]] && return
  if [[ $key == ctrl-y ]]; then
    cmd_argv $aid "$type" "$ns" "$kind" "$name"; clip "${CMD[*]}"; sleep 1
  else
    run_action $aid "$type" "$ns" "$kind" "$name"
  fi
}

# Follows logs for the selected item, dispatching by type.
follow_dispatch() {
  local type=$1 ns=$2 kind=$3 name=$4
  if [[ $type == pod ]]; then follow_pod $ns $name $TAIL
  elif [[ $type == job ]]; then
    show_cmd kubectl logs -f -n $ns job/$name; kubectl logs -f -n $ns job/$name --tail=$TAIL | colorize
  else follow_workload $ns $kind $name $TAIL; fi
}

# Opens (or copies) the ingress URL derived from its host + tls.
open_ingress_url() {
  local ns=$1 name=$2 host tls scheme=http url
  host=$(kubectl get ingress $name -n $ns -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
  tls=$(kubectl get ingress $name -n $ns -o jsonpath='{.spec.tls[0].hosts[0]}' 2>/dev/null)
  [[ -z $host ]] && { print -P "%F{yellow}no host on this ingress%f"; sleep 1; return }
  [[ -n $tls ]] && scheme=https
  url="$scheme://$host"
  show_cmd open "$url"
  if command -v open >/dev/null 2>&1; then open "$url"; else clip "$url"; fi
  sleep 0.6
}

# The Ctrl-P "pod view" for the selected item. Each type narrows the list the
# way that type can be narrowed: a workload and a Service by their selector, a
# node by its name in the query since the pod list carries a NODE column.
# Anything else can only be pre-filtered by namespace.
pods_view() {
  local type=$1 ns=$2 kind=$3 name=$4 sel
  case $type in
    wl)   sel=$(resolve_selector $ns $kind $name)
          pods_picker "" follow $ns $sel ;;
    svc)  sel=$(svc_selector $ns $name)
          [[ -z $sel ]] && { print -P "%F{yellow}service $ns/$name has no selector — no pods behind it%f"; sleep 1; return }
          pods_picker "" follow $ns $sel ;;
    node) pods_picker "$name" follow ;;
    *)    pods_picker "${ns:+$ns }" follow ;;
  esac
}

# Runs an action by id: gathers interactive extras, echoes the real command,
# confirms mutations, then executes. Honors KUBETUI_DRYRUN for mutations.
run_action() {
  local id=$1 type=$2 ns=$3 kind=$4 name=$5
  local -a extra
  case $id in
    scale)     local cur; cur=$(kubectl get $kind $name -n $ns -o jsonpath='{.spec.replicas}' 2>/dev/null)
               local r; print -n "replicas (current ${cur:-?}) > "; read r </dev/tty
               [[ $r == <-> ]] || { print -- "cancelled."; sleep .6; return }; extra=($r) ;;
    set-image) local c i; print -n "container > "; read c </dev/tty; print -n "image > "; read i </dev/tty
               [[ -n $c && -n $i ]] || { print -- "cancelled."; sleep .6; return }; extra=($c $i) ;;
    pf)        local rport lport; print -n "remote port > "; read rport </dev/tty
               [[ $rport == <-> ]] || { print -- "cancelled."; sleep .6; return }
               lport=$(free_port $rport); print -P "local port: %F{cyan}$lport%f"; extra=($lport $rport) ;;
    cp)        local s dd; print -n "source path (in pod) > "; read s </dev/tty; print -n "dest (local) > "; read dd </dev/tty
               [[ -n $s && -n $dd ]] || { print -- "cancelled."; sleep .6; return }; extra=($s $dd) ;;
    trigger)   extra=($(date +%s)) ;;
  esac
  cmd_argv $id "$type" "$ns" "$kind" "$name" "${extra[@]}"

  case $id in
    logs)       guarded follow_dispatch $type $ns $kind $name ;;
    logs-prev)  show_cmd "${CMD[@]}"; kubectl logs -n $ns $name -p --prefix --all-containers --tail=$TAIL 2>&1 | colorize ;;
    describe)   show_cmd "${CMD[@]}"
                { kubectl describe ${kind:-$type} $name -n $ns 2>&1
                  print; print -P "%B%F{cyan}── events ──%f%b"
                  kubectl get events -n $ns --field-selector involvedObject.name=$name --sort-by=.lastTimestamp 2>/dev/null | tail -15
                } | page ;;
    yaml|view-cm) show_cmd "${CMD[@]}"; "${CMD[@]}" 2>&1 | page ;;
    exec|pf|watch-roll) show_cmd "${CMD[@]}"; guarded "${CMD[@]}" ;;
    open-url)   open_ingress_url $ns $name ;;
    pods-on)    show_cmd "${CMD[@]}"; "${CMD[@]}" 2>&1 | color_status | page ;;
    reveal)     show_cmd "${CMD[@]}"
                confirm_strong "$name" "Reveals decoded secret values." || { print -- "cancelled."; sleep .6; return }
                "${CMD[@]}" 2>&1 | page ;;
    *)          # mutations
                show_cmd "${CMD[@]}"
                case ${A_CONFIRM[$id]} in
                  1) confirm "Proceed?" || { print -- "cancelled."; sleep .6; return } ;;
                  2) confirm_strong "$name" "This is destructive." || { print -- "cancelled."; sleep .6; return } ;;
                esac
                run_or_dry "${CMD[@]}"; sleep 1 ;;
  esac
}
