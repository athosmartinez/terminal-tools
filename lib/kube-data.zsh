#!/usr/bin/env zsh
# kube-data.zsh — resource collectors, metrics join, per-view feeds.
# Sourced by kube. Text in English. Depends on core (kubetui.zsh).

# ── metrics ──────────────────────────────────────────────────────────────────
# MET["ns/pod"] = "cpu mem" (e.g. "12m 80Mi"). Empty when metrics-server is off.
typeset -gA MET
metrics_map() {
  MET=()
  local ns name cpu mem rest
  while read -r ns name cpu mem rest; do
    [[ -z $name ]] && continue
    MET[$ns/$name]="$cpu $mem"
  done < <(kubectl top pods -A --no-headers 2>/dev/null)
}

# POD_IMG["ns/pod"] = short image tag of the pod's first container.
typeset -gA POD_IMG
pod_images() {
  POD_IMG=()
  local ns name img
  while read -r ns name img; do
    [[ -z $name ]] && continue
    POD_IMG[$ns/$name]="${img##*/}"
  done < <(kubectl get pods -A --no-headers \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IMG:.spec.containers[0].image' 2>/dev/null)
}

# ── problem detection ────────────────────────────────────────────────────────
# Emits problem rows: sev \t type \t ns \t kind \t name \t status \t restarts
# sev ∈ crit|warn ; type ∈ pod|wl|job. Sorted crit first, then ns, name.
collect_problems() {
  {
    kubectl get pods -A --no-headers 2>/dev/null | awk '
      {
        ns=$1; name=$2; ready=$3; status=$4; rs=$5+0
        if (status=="Terminating" || status=="Completed" || status=="Succeeded") next
        crit="CrashLoopBackOff ImagePullBackOff ErrImagePull OOMKilled Evicted Error Failed"
        warn="Pending ContainerCreating PodInitializing NotReady"
        if (index(crit, status))      { print "crit\tpod\t" ns "\tpod\t" name "\t" status "\t" rs; next }
        if (status ~ /^Init:/)        { print "warn\tpod\t" ns "\tpod\t" name "\t" status "\t" rs; next }
        if (index(warn, status))      { print "warn\tpod\t" ns "\tpod\t" name "\t" status "\t" rs; next }
        if (status=="Running" && rs>5){ print "warn\tpod\t" ns "\tpod\t" name "\tRunning\t" rs; next }
      }'
    collect_workloads | awk -F'\t' '
      { split($4,r,"/"); ready=r[1]+0; des=r[2]+0
        if (des>0 && ready<des) {
          sev = (ready==0) ? "crit" : "warn"
          st  = (ready==0) ? "Down" : "Degraded"
          print sev "\twl\t" $1 "\t" $3 "\t" $2 "\t" st "\t" $4
        } }'
    kubectl get jobs -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,F:.status.failed,S:.status.succeeded,C:.spec.completions' 2>/dev/null \
      | awk '{ f=($3=="<none>")?0:$3+0; s=($4=="<none>")?0:$4+0; c=($5=="<none>")?1:$5+0
               if (f>0 && s<c) print "crit\tjob\t" $1 "\tjob\t" $2 "\tFailed\t" f }'
  } | sort -t$'\t' -k1,1 -k3,3 -k5,5
}

# ── feed: overview ───────────────────────────────────────────────────────────
# Line: <display>\037type\037ns\037kind\037name. Problems first (● by severity),
# separator, then all workloads with image + aggregated cpu/mem.
# All independent kubectl calls run in parallel (wall time ≈ slowest single call).
feed_overview() {
  local d=$DELIM tmp; tmp=$(mktemp -d) || return
  local kind
  ( kubectl top pods -A --no-headers 2>/dev/null > $tmp/top ) &
  ( kubectl get pods -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,OK:.metadata.ownerReferences[0].kind,ON:.metadata.ownerReferences[0].name' 2>/dev/null > $tmp/own ) &
  ( for kind in deploy sts ds; do kubectl get $kind -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IMG:.spec.template.spec.containers[0].image' 2>/dev/null; done > $tmp/imgraw ) &
  ( collect_problems > $tmp/prob ) &
  ( collect_workloads > $tmp/wl ) &
  wait

  # Problems block (honors namespace scope; alerts always stay on top).
  awk -F'\t' -v d="$d" -v nsflt="$KUBE_NS" '
    { sev=$1; type=$2; ns=$3; kind=$4; name=$5; status=$6; rs=$7
      if (nsflt!="" && ns!=nsflt) next
      col=(sev=="crit")?"31":"33"; rst=(rs>0)?("  ↻" rs):""
      disp=sprintf("\033[%sm●\033[0m %-16.16s  %-28.28s  \033[%sm%-16s\033[0m%s", col, ns, name, col, status, rst)
      printf "%s%s%s%s%s%s%s%s%s\n", disp, d, type, d, ns, d, kind, d, name }' $tmp/prob
  local rule="────────────────────"
  printf "%s%s%s%s%s%s%s%s%s\n" $'\033[38;5;243m'"$rule  all workloads  $rule"$'\033[0m' "$d" "sep" "$d" "" "$d" "" "$d" ""

  # Workloads block: join images + summed metrics (owner mapping) in one awk pass.
  # Honors $KUBE_NS (filter) and $KUBE_SORT (cpu|mem by usage desc, else by name).
  awk -F'\t' -v d="$d" -v nsflt="$KUBE_NS" -v srt="$KUBE_SORT" -v topf="$tmp/top" -v ownf="$tmp/own" -v imgf="$tmp/imgraw" '
    function base(p){ sub(/.*\//,"",p); return p }
    function num(s){ gsub(/[^0-9]/,"",s); return s+0 }
    # Fit "name:tag" into w cols keeping the :tag visible (truncate the name).
    function imgfit(s, w,   t, nm, keep, j, ci) {
      if (length(s) <= w) return s
      ci = 0; for (j = length(s); j > 0; j--) if (substr(s,j,1) == ":") { ci = j; break }
      if (ci == 0) return substr(s, 1, w-1) "~"
      t = substr(s, ci); nm = substr(s, 1, ci-1); keep = w - length(t) - 1
      if (keep < 1) return substr(s, 1, w-1) "~"
      return substr(nm, 1, keep) "~" t
    }
    BEGIN {
      while ((getline l < topf) > 0)  { n=split(l,a," "); MET[a[1]"/"a[2]]=num(a[3])" "num(a[4]) }
      while ((getline l < ownf) > 0)  { n=split(l,a," "); if(a[4]==""||a[4]=="<none>") continue
        wl=a[4]; if(a[3]=="ReplicaSet") sub(/-[^-]*$/,"",wl)
        if((a[1]"/"a[2]) in MET){ split(MET[a[1]"/"a[2]],mm," ")
          k=a[1]"/"wl; split((k in WM)?WM[k]:"0 0",cur," "); WM[k]=(cur[1]+mm[1])" "(cur[2]+mm[2]) } }
      while ((getline l < imgf) > 0)  { n=split(l,a," "); IMGM[a[1]"/"a[2]]=base(a[3]) }
    }
    {
      ns=$1; name=$2; kind=$3; ready=$4; key=ns"/"name
      if (nsflt!="" && ns!=nsflt) next
      img=(key in IMGM)?imgfit(IMGM[key],18):"-"
      if (key in WM) { split(WM[key],mm," "); cpuN=mm[1]; memN=mm[2]; cpu=mm[1]"m"; mem=mm[2]"Mi" } else { cpuN=0; memN=0; cpu="-"; mem="-" }
      split(ready,r,"/"); rd=r[1]+0; de=r[2]+0
      rc=(de==0)?"38;5;243":(rd==de)?"32":(rd==0)?"31":"33"
      if (srt=="cpu") sk=sprintf("%09d", cpuN)
      else if (srt=="mem") sk=sprintf("%09d", memN)
      else sk=ns"/"name
      disp=sprintf("\033[36m%-18.18s\033[0m  \033[1m%-26.26s\033[0m  \033[38;5;243m%-6.6s\033[0m  \033[%sm%-6s\033[0m  \033[35m%-18.18s\033[0m  %6s %8s",
        ns, name, kind, rc, ready, img, cpu, mem)
      printf "%s\t%s%s%s%s%s%s%s%s%s\n", sk, disp, d, "wl", d, ns, d, kind, d, name
    }' $tmp/wl \
  | { if [[ $KUBE_SORT == cpu || $KUBE_SORT == mem ]]; then sort -rn -k1,1; else sort; fi } \
  | cut -f2-
  rm -rf $tmp
}

# ── feed: pods ───────────────────────────────────────────────────────────────
# Columns: ns · pod · ready · status · ↻ · ip · image · cpu · mem · node.
# Honors $KUBE_NS (filter) and $KUBE_SORT (name|cpu|mem|restarts).
feed_pods() {
  local d=$DELIM tmp; tmp=$(mktemp -d) || return
  ( kubectl get pods -A --no-headers 2>/dev/null > $tmp/basic ) &
  ( kubectl get pods -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName,IMG:.spec.containers[0].image' 2>/dev/null > $tmp/wide ) &
  ( kubectl top pods -A --no-headers 2>/dev/null > $tmp/top ) &
  wait
  awk -v d="$d" -v nsflt="$KUBE_NS" -v srt="$KUBE_SORT" -v widef="$tmp/wide" -v topf="$tmp/top" '
    function base(p){ sub(/.*\//,"",p); return p }
    # Fit "name:tag" into w cols keeping the :tag visible (truncate the name).
    function imgfit(s, w,   t, nm, keep, j, ci) {
      if (length(s) <= w) return s
      ci = 0; for (j = length(s); j > 0; j--) if (substr(s,j,1) == ":") { ci = j; break }
      if (ci == 0) return substr(s, 1, w-1) "~"
      t = substr(s, ci); nm = substr(s, 1, ci-1); keep = w - length(t) - 1
      if (keep < 1) return substr(s, 1, w-1) "~"
      return substr(nm, 1, keep) "~" t
    }
    BEGIN {
      while ((getline l < widef)>0){ n=split(l,a," "); k=a[1]"/"a[2]; IP[k]=a[3]; NODE[k]=base(a[4]); IMG[k]=base(a[5]) }
      while ((getline l < topf)>0){ n=split(l,a," "); k=a[1]"/"a[2]; CPU[k]=a[3]; MEM[k]=a[4] }
    }
    { ns=$1; name=$2; ready=$3; st=$4; rs=$5+0
      if (nsflt!="" && ns!=nsflt) next
      k=ns"/"name; ip=(k in IP)?IP[k]:"-"; node=(k in NODE)?NODE[k]:"-"; img=(k in IMG)?imgfit(IMG[k],16):"-"
      cpu=(k in CPU)?CPU[k]:"-"; mem=(k in MEM)?MEM[k]:"-"
      if (srt=="cpu") sk=sprintf("%09d", cpu+0)
      else if (srt=="mem") sk=sprintf("%09d", mem+0)
      else if (srt=="restarts") sk=sprintf("%09d", rs)
      else sk=ns"/"name
      disp=sprintf("%-15.15s  %-32.32s  %-5s  %-13.13s  ↻%-3s  %-15s  \033[35m%-16.16s\033[0m  %6s %8s  \033[38;5;243m%-.20s\033[0m",
        ns,name,ready,st,rs,ip,img,cpu,mem,node)
      printf "%s\t%s%s%s%s%s%s%s%s%s\n", sk, disp, d, "pod", d, ns, d, "pod", d, name }' $tmp/basic \
  | { if [[ $KUBE_SORT == name || -z $KUBE_SORT ]]; then sort; else sort -rn -k1,1; fi } \
  | cut -f2- | color_status
  rm -rf $tmp
}

# ── feed: nodes ──────────────────────────────────────────────────────────────
# Columns: name · status · spot/on-demand · cpu% · mem% · pods.
feed_nodes() {
  local d=$DELIM tmp; tmp=$(mktemp -d) || return
  ( kubectl top nodes --no-headers 2>/dev/null > $tmp/top ) &
  ( kubectl get nodes --no-headers \
      -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,SCHED:.spec.unschedulable,SPOT:.metadata.labels.cloud\.google\.com/gke-spot,PRE:.metadata.labels.cloud\.google\.com/gke-preemptible' 2>/dev/null > $tmp/nodes ) &
  ( kubectl get pods -A --no-headers -o custom-columns='NODE:.spec.nodeName' 2>/dev/null > $tmp/pn ) &
  wait
  awk -v d="$d" -v topf="$tmp/top" -v pnf="$tmp/pn" '
    BEGIN {
      while ((getline l < topf)>0){ n=split(l,a," "); NCPU[a[1]]=a[3]; NMEM[a[1]]=a[5] }
      while ((getline l < pnf)>0){ gsub(/[ \t]+$/,"",l); if(l!="")PODS[l]++ }
    }
    { name=$1; ready=$2; sched=$3; spot=$4; pre=$5
      status=(sched=="true")?"Cordoned":((ready=="True")?"Ready":"NotReady")
      kind=(spot=="true"||pre=="true")?"spot":"on-demand"
      cp=(name in NCPU)?NCPU[name]:"–"; mp=(name in NMEM)?NMEM[name]:"–"
      pc=(name in PODS)?PODS[name]:0
      col=(status=="Ready")?"32":((status=="Cordoned")?"33":"31")
      sc=(kind=="spot")?"33":"38;5;243"
      disp=sprintf("\033[1m%-44.44s\033[0m  \033[%sm%-9s\033[0m  \033[%sm%-9s\033[0m  cpu:%-5s mem:%-5s  pods:%-3s", name, col, status, sc, kind, cp, mp, pc)
      printf "%s%s%s%s%s%s%s%s%s\n", disp, d, "node", d, "", d, "node", d, name }' $tmp/nodes
  rm -rf $tmp
}

do_preview_node() { kubectl describe node $1 2>/dev/null | sed -n '1,45p'; }

# ── feed: events ─────────────────────────────────────────────────────────────
# Cluster Warning events, newest first. type=event; kind/name = involved object.
feed_events() {
  local d=$DELIM; local -a nsflag; [[ -n $KUBE_NS ]] && nsflag=(-n $KUBE_NS) || nsflag=(-A)
  kubectl get events "${nsflag[@]}" --field-selector type=Warning --sort-by=.lastTimestamp \
    -o custom-columns='TIME:.lastTimestamp,NS:.metadata.namespace,REASON:.reason,OK:.involvedObject.kind,ON:.involvedObject.name,MSG:.message' --no-headers 2>/dev/null \
  | tail -r \
  | awk -v d="$d" '
      { ns=$2; reason=$3; okind=$4; oname=$5
        msg=""; for(i=6;i<=NF;i++) msg=msg (i>6?" ":"") $i
        obj=okind"/"oname
        disp=sprintf("\033[33m%-20.20s\033[0m %-14.14s \033[1m%-30.30s\033[0m \033[38;5;243m%-.55s\033[0m", reason, ns, obj, msg)
        printf "%s%s%s%s%s%s%s%s%s\n", disp, d, "event", d, ns, d, okind, d, oname }'
}

# ── feed: ingress ────────────────────────────────────────────────────────────
# Routes host → service; hides cert-manager acme solvers unless $KUBE_ALL=1.
feed_ingress() {
  local d=$DELIM; local -a nsflag; [[ -n $KUBE_NS ]] && nsflag=(-n $KUBE_NS) || nsflag=(-A)
  kubectl get ingress "${nsflag[@]}" --no-headers \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host,TLS:.spec.tls[*].hosts' 2>/dev/null \
  | awk -v d="$d" -v all="$KUBE_ALL" '
      $2 ~ /cm-acme-http-solver/ && all!="1" { next }
      { ns=$1; name=$2; hosts=$3; tls=$4; sec=(tls!="<none>"&&tls!="")?"tls":"—"
        disp=sprintf("\033[36m%-16.16s\033[0m %-30.30s \033[1m%-42.42s\033[0m %s", ns, name, hosts, sec)
        printf "%s%s%s%s%s%s%s%s%s\n", disp, d, "ingress", d, ns, d, "ingress", d, name }'
}

# ── feed: config (secrets + configmaps) ──────────────────────────────────────
feed_config() {
  local d=$DELIM tmp; tmp=$(mktemp -d) || return
  local -a nsflag; [[ -n $KUBE_NS ]] && nsflag=(-n $KUBE_NS) || nsflag=(-A)
  # Listing all secrets is the slow part (seconds on big clusters); run it in
  # parallel with configmaps instead of sequentially.
  ( kubectl get secrets "${nsflag[@]}" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type' 2>/dev/null | awk '{print $1"\tsecret\t"$2"\t"$3}' > $tmp/s ) &
  ( kubectl get configmaps "${nsflag[@]}" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null | awk '{print $1"\tcm\t"$2"\t-"}' > $tmp/c ) &
  wait
  cat $tmp/s $tmp/c | sort | awk -F'\t' -v d="$d" '
      { ns=$1; t=$2; name=$3; typ=$4; col=(t=="secret")?"33":"36"
        disp=sprintf("\033[%sm%-7s\033[0m %-16.16s \033[1m%-40.40s\033[0m \033[38;5;243m%-.28s\033[0m", col, t, ns, name, typ)
        printf "%s%s%s%s%s%s%s%s%s\n", disp, d, t, d, ns, d, t, d, name }'
  rm -rf $tmp
}

# ── feed: ips ────────────────────────────────────────────────────────────────
# Every IP in the cluster in one table: pod IPs, Service ClusterIPs and external
# IPs, node addresses, ingress external IPs. Columns: ip · kind · ns · name ·
# detail. Rows arrive sorted numerically by IP from ip_index, so a subnet reads
# as a block. Honors $KUBE_NS for namespaced rows; nodes are cluster-scoped and
# always show, as in the nodes view.
feed_ips() {
  local d=$DELIM
  ip_index | awk -F'\t' -v d="$d" -v nsflt="$KUBE_NS" '
    { ip=$1; type=$2; ns=$3; kind=$4; name=$5; extra=$6
      if (nsflt != "" && type != "node" && ns != nsflt) next
      kc=(type=="pod")?"36":(type=="svc")?"32":(type=="node")?"35":"34"
      nsout=(type=="node")?"":ns
      disp=sprintf("\033[1m%-15.15s\033[0m  \033[%sm%-7s\033[0m  %-16.16s  %-30.30s  \033[38;5;243m%-.28s\033[0m",
        ip, kc, type, ns, name, extra)
      printf "%s%s%s%s%s%s%s%s%s\n", disp, d, type, d, nsout, d, kind, d, name }'
}
