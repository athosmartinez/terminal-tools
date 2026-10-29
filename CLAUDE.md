# CLAUDE.md — working notes for this repo

Guidance for AI-assisted work on **terminal-tools** (`kube`, `logs`, `ports` —
three zsh + fzf terminal TUIs). Conventions and gotchas live here; user-facing
docs live in `README.md`.

## Workflow (important)

- **These files are symlinked into `~/.local/bin`.** Editing a repo file here is
  live immediately (the installed command runs it). Always edit the **repo**
  path — tooling that refuses to write through symlinks forces this anyway.
- **Commit + push every change.** This is the canonical source; keep the working
  tree clean and `origin/main` in sync. Solo repo → commit straight to `main`
  and push (no PR flow unless asked).
- **Do NOT put a `Claude-Session:` trailer (or any Claude reference) in commit
  messages.** This is a public repo; the owner asked to keep it out.
- All script text (messages, help, comments) is **English**. Conversation with
  the owner is Portuguese.

## What each tool is

- `kube` — a keyboard-first Kubernetes cockpit (single persistent fzf).
- `logs` — follow workload logs across namespaces (one color per pod).
- `ports` — view/kill processes on TCP ports (`lsof`). Self-contained on purpose:
  it sources no `lib/`, so it can be copied to a machine on its own.
- `monitor` — macOS only, not a TUI: `monitor off|on|status` disables/enables
  the external display via the private `CGSConfigureDisplayEnabled` (resolved
  with `dlsym`), so a USB-C monitor keeps charging with no video. Core logic is
  `lib/monitor/DisplayToggle.swift`, shared by the CLI (`cli/main.swift`) and
  the MonitorBar menu bar app (`app/main.swift`). The zsh wrapper compiles the
  CLI into `~/.cache/terminal-tools/monitor` when the binary is missing or
  older than a source (`-nt`), so repo edits stay live; the app is NOT live —
  `monitor app` rebuilds `~/Applications/MonitorBar.app` (Info.plist with
  `LSUIElement`, ad-hoc `codesign` required by `SMAppService`) and relaunches
  it. Both compile with `-swift-version 5`. The app refreshes its icon from
  `CGDisplayRegisterReconfigurationCallback`, never by polling. Disabled ids persist in `~/.config/terminal-tools/monitor-disabled`
  because a disabled display leaves the active list. No confirm on purpose: it
  is instantly reversible, and `off` refuses when the built-in panel is
  inactive. Testing `off` blanks the owner's monitor — let the owner run it.

`kube` and `logs` source `lib/kubetui.zsh`; `kube` also sources
`lib/kube-actions.zsh` (action registry) and `lib/kube-data.zsh` (feeds). Each
entry point sets `SELF=${0:A}` and sources `${0:A:h}/lib/...` (so `lib/` travels
with the repo via the symlink; `:A` resolves the symlink to the repo path).

The `ips` view (kube) and `logs <ip>` / `^F` share one index: `ip_index` in
`lib/kubetui.zsh` emits `ip \t type \t ns \t kind \t name \t extra` for every
pod / Service / node / ingress address, and `ip_lookup` filters it by exact IP
with priority pod > svc > node > ingress. `_ip_rows` is split out from the
kubectl calls so it can be tested against fixture files with no cluster.

## Architecture: the single-fzf pattern (kube, and mirrored in logs/ports)

There is **one persistent fzf per session** — it never relaunches per keypress
(the old per-key relaunch caused a raw-escape "flood" + lag). All interaction is
fzf bindings that read/write **file-based state** and update the UI in place:

- State dir: `mktemp -d`, `export`ed as `$KUBE_STATE` / `$LOGS_STATE` /
  `$PORTS_STATE`, removed in an `EXIT` trap. Holds `view`/`ns`/`sort`/`live` and
  the caches `feed.<view>` / `pv.*`.
- fzf bindings call the script back as child dispatches: `transform(<cmd>)` runs
  `<cmd>` whose **stdout is a `+`-joined list of fzf actions** (e.g.
  `change-header(...)+reload(...)`); `execute(<cmd>)` runs an action with the
  terminal (confirmations, pagers, nested fzf); `reload`/`load:reload:sleep N`
  drive the list + auto-refresh.
- kube dispatches: `--feed [view]` (fresh; also warms `feed.<view>`),
  `--auto-feed` (timer only — serves the feed cache within a longer TTL for
  heavy views overview=20s/ips=20s/config=45s so the 5s timer doesn't hammer
  them; light views fetch fresh), `--nav`, `--cycle-sort`, `--toggle-live` (unbind/rebind
  `load`), `--sync` (after an action: clears `pv.*`, re-emits header + reload),
  `--act <key> <type> <ns> <kind> <name>` (runs the action via `run_action`),
  `--pick-ns`, `--preview` (caches `pv.*`, default TTL 20s).
- Header is 3 lines built by `full_header` = `tab_bar` + `keybar(view)` +
  `col_header(view)`, re-emitted via `change-header` on every state change. It is
  **contextual**: `keybar` shows only the keys that apply to the current view;
  `col_header` labels align to each feed's exact column widths.

## Conventions & gotchas (these bit us — respect them)

- **fzf action arguments must be paren-free.** A `(` or `)` inside a
  `change-header(...)` / `change-prompt(...)` / `transform` output breaks fzf's
  action parser. Keep header/keybar/label text free of parentheses.
- **Multi-line `change-header` works** (fzf ≥ 0.74) — the 3-line header relies on
  it.
- **Colors must survive light AND dark backgrounds** (owner uses Ghostty, often
  light). The terminal theme only remaps the *normal* ANSI colors, not the *dim*
  attribute or the *bright* (9x) colors — those break on light. So:
  - "dim/secondary" text = fixed gray `\033[38;5;243m` (NOT the `\033[2m` dim
    attribute).
  - Identity palette = `36 32 35 34 31` (normal colors, no bright 9x, no yellow
    33 — yellow is weak on white). `KUBETUI_PALETTE` in `lib/kubetui.zsh`; `ports`
    has its own copy.
  - Status green/red/cyan stay as normal codes (theme-mapped by the terminal).
- **Command transparency**: every mutating action prints the real command
  (`$ kubectl ...`, `$ kill ...`) before running — keep this. `show_cmd`/`run_cmd`
  in `lib/kubetui.zsh`.
- **Every mutation confirms first** (`confirm` / `confirm_strong`), reading from
  `/dev/tty`. `KUBETUI_DRYRUN=1` makes `run_or_dry` print instead of execute.
- `local` is used in the top-level dispatch `case` body (zsh allows it outside a
  function). Fine — follow the existing pattern.
- `page()` = `less -R` if present else `cat`; never `$PAGER -R`.
- Image display: `imgfit(s,w)` (awk) truncates keeping the `:tag` visible (marks
  the cut with `~`, ASCII so byte-width math holds); the full image (with
  registry) shows in the preview's `Image(s)` section.
- All actions run against the **current** kubectl context. There is no config;
  everything reads live. **Never mutate a real cluster while testing** — use
  `KUBETUI_DRYRUN=1` and/or decline confirmations.

## Testing

- Syntax: `zsh -n kube logs ports lib/*.zsh` (run per file).
- Dispatch/logic: call child dispatches directly with a seeded state dir, e.g.
  `ST=$(mktemp -d); print overview>$ST/view; KUBE_STATE=$ST ./kube --nav next`.
- Mutations: `KUBETUI_DRYRUN=1 ./kube --act ctrl-r wl <ns> deploy <name>` and
  decline the confirm — verifies the command builder without touching anything.
- **Interactive fzf is flaky under `expect`/pty** (alt-screen + synchronized
  output). Don't scrape fzf's screen. Instead assert on **side effects**: state
  files changing, or **count `\037` (0x1F) bytes that reached the terminal**
  (`tr -cd '\037' < pty.log | wc -c`) — fzf never emits `\037`, so any leak means
  raw feed output escaped fzf. The real *visual* validation is the owner running
  it on their terminal.

## Structure & deps

```
kube  logs  ports          entry points (zsh)
lib/kubetui.zsh            shared core (feeds helpers, follow engine, previews)
lib/kube-actions.zsh       kube action registry + menu + run_action
lib/kube-data.zsh          kube per-view feeds + metrics join
monitor                    entry point (zsh wrapper, macOS) → lib/monitor/
lib/monitor/DisplayToggle.swift  display off/on core (private CoreGraphics call)
lib/monitor/cli/main.swift       `monitor on|off|status`
lib/monitor/app/main.swift       MonitorBar menu bar app (`monitor app`)
install.sh                 symlinks the 4 entry points into ~/.local/bin
```

Requires: `fzf` ≥ 0.30 (features here assume 0.74), `zsh`; `kubectl` (kube/logs),
`lsof` (ports), `swiftc` (monitor).

## Platform (macOS / Linux / WSL2)

Never call a platform-dependent command directly — the four that differ live in
`lib/kubetui.zsh` and are the single place to extend:

- `mtime <file>` — epoch mtime; `stat -f %m` (BSD) vs `stat -c %Y` (GNU). The
  feed and preview caches read it; a wrong value only costs a refetch, which is
  why the BSD-only form went unnoticed on Linux for so long.
- `clip <text>` — `pbcopy` / `wl-copy` / `xclip` / `xsel` / `clip.exe`.
- `url_opener` — prints the opener's name (`open` / `xdg-open` / `wslview` /
  `explorer.exe`) or fails; kept separate from running it so `show_cmd` prints
  the real command.
- `port_busy <port>` — `lsof` or `ss`; unknown means "free".

`ports` is standalone, so it re-checks `lsof` itself at startup. Under WSL2 it
only sees the WSL network namespace, never the Windows one.
