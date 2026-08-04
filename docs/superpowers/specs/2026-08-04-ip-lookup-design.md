# IP lookup in `kube` and `logs` — design

Status: approved, ready for implementation plan.

## Problem

An IP shows up somewhere — an app log line, a network alert, a denied
NetworkPolicy, a WAF entry, a database connection list — and answering "who is
this?" today means leaving the tools: `kubectl get pods -A -o wide | grep <ip>`,
then another command for Services, another for nodes.

Inside the tools the coverage is partial and undiscoverable:

- `kube` → view `pods` renders an `IP` column (`lib/kube-data.zsh`, `feed_pods`),
  so typing an IP there already filters — but only pod IPs, only in that view.
- `logs` has no IP anywhere: the picker lists workloads (ns/name/kind/ready) and
  the positional query matches namespace and name only (`logs`, `direct()`).
- IPs otherwise appear only inside previews (`do_preview_pod`).

## Goal

Two capabilities, both driven by the same index:

1. **Reverse lookup** — given an IP, identify the owning resource and jump
   straight to its logs / describe / actions.
2. **Filtering** — the IP is a searchable column in a list, so partial IPs
   (`10.42.`) narrow the view through the normal fzf fuzzy filter.

Covered IP kinds: pod IP, Service ClusterIP, node IP (internal/external),
external LoadBalancer IP (Services and Ingresses).

## Architecture

### 1. `ip_index()` — shared core, `lib/kubetui.zsh`

Lives in the shared core because `logs` sources only `lib/kubetui.zsh`, while
`kube` also gets `lib/kube-data.zsh`. Emits one TSV line per IP:

```
ip \t type \t ns \t kind \t name \t extra
```

Example rows:

```
10.42.3.17    pod      checkout      pod       checkout-7d9-x2k   node-a · Running
10.96.0.31    svc      checkout      svc       checkout           ClusterIP · 8080/TCP
34.12.88.7    svc      traefik       svc       traefik            ExternalIP · LoadBalancer
192.168.4.11  node     -             node      node-a             InternalIP · Ready
34.12.90.2    ingress  shop          ingress   shop-web           ExternalIP
```

Rules:

- Four `kubectl get` calls run **in parallel** (pods, svc, nodes, ingress),
  following the pattern already used by `feed_overview` / `feed_pods` /
  `feed_nodes` (background subshells into a `mktemp -d`, then `wait`).
- **One line per IP.** A Service holding a ClusterIP *and* an external IP
  produces two rows — the lookup key is the IP, so every IP needs its own row.
- Headless Services (ClusterIP `None`) and empty/`<none>` addresses are skipped.
- `type` is the resource's real type (`pod` / `svc` / `node` / `ingress`), never
  a synthetic `lb` type. That keeps the existing action registry, `--act`
  dispatch and preview routing working unchanged.
- `extra` is free-form context for the row (node + status, port list, address
  type). It is display-only.

Field sources:

| type | command | ip field |
| --- | --- | --- |
| pod | `kubectl get pods -A -o custom-columns=...` | `.status.podIP` |
| svc | `kubectl get svc -A -o custom-columns=...` | `.spec.clusterIP` and `.status.loadBalancer.ingress[*].ip` |
| node | `kubectl get nodes -o custom-columns=...` | `.status.addresses[?(@.type=="InternalIP")].address` and `ExternalIP` |
| ingress | `kubectl get ingress -A -o custom-columns=...` | `.status.loadBalancer.ingress[*].ip` |

### 2. `kube` — new `ips` view

A seventh entry in `VIEWS`, reached by Tab like every other view.

- **Columns:** `IP · KIND · NAMESPACE · NAME · EXTRA`, via a new `col_header`
  case aligned to `feed_ips`'s exact widths.
- **Order:** numeric by IP (octet-aware), fixed. `^T` (cycle sort) does not
  apply to this view — sorting by cpu/mem/restarts is meaningless here, and
  numeric IP order already groups by subnet, which in practice separates pods
  from Services from nodes.
- **Namespace scope (`^N`):** filters pod/svc/ingress rows. **Nodes always
  show** — they are cluster-scoped, same as in the `nodes` view.
- **Auto-refresh:** joins the `--auto-feed` throttle with a **20s TTL** (same as
  `overview`). Four kubectl calls whose data barely changes should not re-run on
  the 5s timer. Manual reloads (view switch, F5, `--sync`) always fetch fresh.
- **Keybar:** `Enter logs · ^D describe · ^Y yaml · ^X delete · ^P pods · ^A more`.
  The keybar is per-view, so `^X` is listed even though it only applies to pod
  and ingress rows; on a svc or node row `act_dispatch` already answers
  "delete not available here" through the existing `applies` guard.
- **`Enter` routing** stays in `act_dispatch`, which already maps per type:
  pod → logs, node → `pods-on`, ingress → `open-url`. New: **svc → port-forward
  (`pf`)** — the thing you actually want to do with a Service you just found.

Registry changes in `lib/kube-actions.zsh`:

- add `svc` to the `applies` list of `describe` and `yaml` (`pf` already has it);
- `cmd_argv` needs no change: `describe`/`yaml` already build from
  `${kind:-$type}`, which is `svc` for these rows.

`kube_preview` gets an `svc` case (`kubectl describe svc` + its endpoints).

### 3. `logs` — IP as an entry point

**CLI:** `logs 10.42.3.17`. The positional query is checked against a full IPv4
pattern; anything else keeps today's behavior (substring match on namespace and
name). Works together with `-n <N>` (tail) and `-p` (previous container logs of
the resolved pod).

Before acting, print the resolution so the answer to "who is this?" is visible
even when the follow scrolls past:

```
→ 10.42.3.17 = pod checkout/checkout-7d9-x2k
```

Routing by resolved type:

| resolved type | action |
| --- | --- |
| pod | follow that pod (`follow_pod`) — not the owning workload |
| svc | resolve `.spec.selector` → `pods_picker "" follow <ns> <selector>`; no selector (headless / ExternalName) → clear error |
| node | `pods_picker <node-name> follow` — the node name is the initial fzf query, and `-o wide` already carries a NODE column |
| ingress | identify it and state that there are no app logs behind it; do not invent a target |

Following the pod (not the workload) is deliberate: an IP lookup is about *that*
replica — the one that made the connection, the one in the alert. Following the
whole workload would bury the line being hunted under the other replicas.

**Picker:** a new key opens an `ip> ` prompt; the pasted IP goes through the
same routing. The key is **`^F`** ("find"). `^I` is impossible — in a terminal
Ctrl-I *is* Tab (0x09) and fzf cannot tell them apart. `^F` costs only fzf's
default `forward-char` inside the prompt line.

Note for the README: `^P` in the `logs` picker **already** filters by pod IP
today (it runs `kubectl get pods -A -o wide`, which has an IP column) — it is
just not documented. `^F` adds what `^P` cannot do: resolving Service, node and
Ingress IPs.

**No IP match:** `✗ no resource with IP 10.42.3.17`.

### 4. Ambiguity

One IP can match several rows — a `hostNetwork` pod carries its node's IP, for
example. Resolution order is **pod > svc > node > ingress**, and the other
matches are printed as a note rather than opening a disambiguation UI:

```
→ 10.42.3.17 = pod kube-system/node-exporter-abc  (also: node node-a)
```

In `kube`'s `ips` view no such choice exists: every match is its own row.

## Constraints carried from the repo

These are established conventions (see `CLAUDE.md`), not new decisions:

- fzf action arguments are **paren-free** — the new `col_header`/keybar text for
  `ips` must contain no `(` or `)`.
- Dim text is the fixed gray `\033[38;5;243m`, never the `\033[2m` attribute;
  no bright (9x) colors, no yellow 33 for identity — the owner's terminal is
  often light.
- Every mutating action prints the real command first and confirms. Nothing in
  this feature mutates: it is all read + navigation, except the actions it hands
  off to, which already confirm on their own.
- All script text in English; `logs`/`kube` help and README updated to match.

## Testing

- `zsh -n kube logs ports lib/*.zsh` (per file) after every edit.
- `ip_index` in isolation: run it against the current context and check the
  shape — one line per IP, tab-separated, no `<none>` rows, no headless
  Services.
- `feed_ips` via the child dispatch with a seeded state dir:
  `ST=$(mktemp -d); print ips >$ST/view; KUBE_STATE=$ST ./kube --feed` — assert
  rows come out `\037`-delimited with 5 fields.
- Namespace scope: seed `$ST/ns` and confirm pod/svc/ingress rows are filtered
  while node rows survive.
- `logs` resolution without following: exercise the resolver dispatch directly
  with a known pod IP, a ClusterIP and a node IP, checking the printed
  identification line.
- Ambiguity: a `hostNetwork` pod IP must resolve to the pod and mention the node.
- Interactive fzf is not scraped (flaky under pty). Visual validation is the
  owner running it.

## Out of scope

- IPv6. The pattern matched is IPv4 only; clusters here are IPv4.
- Partial-IP resolution on the CLI (`logs 10.42.`). Partial filtering is what
  `kube`'s `ips` view is for.
- Endpoint/EndpointSlice-level lookup, CIDR range queries, and reverse DNS.
- Deleting a Service from the `ips` view (`del-res` keeps its current scope).
