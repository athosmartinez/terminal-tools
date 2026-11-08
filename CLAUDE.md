# CLAUDE.md — working notes for this repo

Guidance for AI-assisted work on **terminal-tools** (`kube`, `logs`, `ports` —
three zsh + fzf terminal TUIs — plus `monitor`, a macOS Swift CLI and menu bar
app, with a separate Linux/Hyprland version in bash, and `vox`, a Voxtype
companion: transcription history plus a menu bar app with the daemon state). Conventions and gotchas live here; user-facing
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

## Scope: what belongs here

This repo is **public**. The owner's machine configs live in a private
`dotfiles` repo. A file belongs here only when it is useful to
other people and holds nothing private:

- **Here:** a generic tool (command, TUI, menu bar app, bar widget) with docs.
- **Not here:** emails, hostnames, IPs, tokens, employer or client names,
  absolute home paths, the owner's keybindings or theme, or a script that only
  makes sense with the owner's hardware or services. Those stay in `dotfiles`.
- **A tool that needs a machine value** reads it from
  `~/.config/terminal-tools/<tool>.conf` (or an env var) with a sane default —
  see `hdmi_input=` in `monitor.conf`. The value never goes in the repo.
- **Moving a script from `dotfiles` to here:** strip the machine values first,
  add a usage text, a test when it has logic, a README entry and a line in
  `install.sh`; then delete it from `dotfiles` so there is one owner.
- **Generated copies:** `monitor bar` copies `lib/monitor/omarchy/` into
  `~/.config/omarchy/plugins/terminal-tools.monitor/`, and `dotfiles` syncs
  that folder. This repo owns the files: edit them here and rerun
  `monitor bar`, never edit the copy in `dotfiles`.

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
  `CGDisplayRegisterReconfigurationCallback`, never by polling. The app also
  restores an off display when a cable connects: the trigger is a new
  `IOPortTransportStateDisplayPort` (IOKit match). `.addFlag` cannot do it: a
  disabled display drops out of the online list too and sends no add event on
  replug, only after the app re-enables it (seen in the app log, two replugs).
  The restore is one silent attempt after 2 s, skipped for 10 s after the
  state file changes, because an HDMI handoff can look like a plug, and for 15 s
  after a wake, because displays are detected again then. Disabled ids persist in `~/.config/terminal-tools/monitor-disabled`
  because a disabled display leaves the active list. No confirm on purpose: it
  is instantly reversible, and `off` refuses when the built-in panel is
  inactive. Testing `off` blanks the owner's monitor — let the owner run it.
  `monitor hdmi` / *Turn Off & Switch to HDMI* writes VCP 0x60 over DDC
  (`DDC.swift`, the m1ddc technique) before disabling, because disabling does
  not drop the link and the monitor's auto source switch never fires. The value
  comes from `hdmi_input=` in `~/.config/terminal-tools/monitor.conf` (default
  17; the owner's Samsung S27A600U uses 5, and has no DDC value for USB-C, so
  switching back is manual). Every `lib/monitor/*.swift` is core; the wrapper
  compiles all of them with the CLI or app `main.swift`. DDC reads from this
  monitor are unreliable — verify writes by looking at the screen.
- `monitor-linux` — the Linux (Hyprland) `monitor`, plain bash + `jq`; shares
  no code with the macOS one. `install.sh` links `~/.local/bin/monitor` to it on
  Linux. Hyprland here uses the Lua config, so `hyprctl keyword` is rejected:
  `off` runs `hyprctl eval 'hl.monitor({ output = …, disabled = true })'` on
  every external output (name not `eDP|LVDS|DSI`) and refuses when the lid is
  closed (`/proc/acpi/button/lid/*/state`; the built-in output can stay
  enabled in Hyprland with the lid closed) or no built-in output stays enabled; `on` runs `hyprctl reload` so the user's
  monitor rules (mode/position in `~/.config/hypr/monitors.lua`) come back —
  an enable with `mode = "preferred"` would lose them; it only uses DPMS
  enable for an output that is enabled but asleep. `pause [s]` = disable,
  sleep, reload, and is allowed with the lid closed (owner's choice); it
  writes its PID to `$XDG_RUNTIME_DIR/terminal-tools-monitor.pause` while it
  runs. `auto` reloads when the lid is closed and an external output is
  disabled, unless that PID is alive; it never touches a DPMS-asleep output
  (idle/screensaver). An output with empty `make` and `model` is virtual
  (a headless stream display, e.g. Sunshine's): never external, never
  disabled. External off + virtual on = `streaming`, and `auto` skips it —
  otherwise a monitor rule that disables the display during a stream, plus the
  widget refreshing on `configreloaded`, made a reload loop (13 in 10 s).
  `monitor outputs` prints one JSON array (`name`, `kind`, `label`, `state`,
  `mode`, `reason`) for the widget menu. `label` is a jq keyword: the jq
  helper is `title`. Omarchy has no lid or monitor hook, so the bar widget
  runs `monitor auto` before every `monitor status`. State
  comes from `hyprctl monitors all -j` (`.disabled`, `.dpmsStatus`), so there
  is no state file. `monitor bar` copies `lib/monitor/omarchy/` (manifest +
  `BarWidget.qml`) into `~/.config/omarchy/plugins/terminal-tools.monitor/`
  (a copy: Omarchy rejects symlinked plugins), then validate → `omarchy-shell
  shell rescanPlugins` → `omarchy plugin enable`. The widget is NOT live —
  rerun `monitor bar` after editing it. It polls `monitor status` every 5 s
  and on Hyprland monitor events, runs actions detached via
  `Quickshell.execDetached`, and turns a failure into `notify-send`. The shell's
  plugin hot reload can keep the old QML from its component cache: if the bar
  still shows the old widget after `monitor bar`, run `omarchy restart shell`.

- `vox` — Voxtype (third-party, compiled Rust in `/Applications/Voxtype.app`,
  not in this repo) keeps no history and its log restarts with the daemon. So
  `vox record` is the `[output.post_process] command` in the Voxtype
  `config.toml`: stdin → stdout **unchanged** (Voxtype types what the hook
  prints; on failure it types the original), then saved. The command path is
  absolute: the daemon's launchd PATH has no `~/.local/bin`. File:
  `~/.local/share/terminal-tools/vox-history`, mode 600, records
  `<epoch>\t<text>` joined by U+001E (a dictation can hold newlines and tabs),
  oldest first, last `VOX_HISTORY_MAX`=15, written via tmp + `mv`. `copy` sources
  `lib/kubetui.zsh` only for `clip`; `record` sources nothing, to stay fast.
  `vox app` builds `~/Applications/VoxBar.app` from `lib/vox/app/main.swift`
  (same bundle steps as MonitorBar, app icon from `lib/vox/app/AppIcon.png`). VoxBar replaced a loose
  SwiftBar plugin: the icon is the daemon state, read from `/tmp/voxtype/pid`
  (dead pid = not running) and `/tmp/voxtype/state` (`idle`/`recording`/
  `transcribing`; its mtime is the age, 90 s transcribing = stuck). A 1 s timer
  in `.common` mode, on purpose: the daemon sends no event when it dies.
  History is re-read in `menuNeedsUpdate`. Not live — rerun `vox app`.
  Test with `VOX_HISTORY_FILE` / `VOX_STATE_DIR` at scratch paths, never the
  real ones.

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

- Syntax: `zsh -n kube logs ports vox lib/*.zsh` (run per file).
- `monitor-linux`: `bash tests/monitor-linux.test.sh` — a fake `hyprctl` on
  `PATH` serves fixture JSON and logs the calls, so no test touches a display;
  `MONITOR_LID_DIR` points at a fake lid (open by default) — never let a test
  read the real one.
  `omarchy plugin validate ~/.config/omarchy/plugins/terminal-tools.monitor`
  checks the widget manifest; QML errors only show in `quickshell log -p
  /usr/share/omarchy/shell`.
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
lib/monitor/DDC.swift            input switch over DDC/CI (private IOAVService)
lib/monitor/cli/main.swift       `monitor on|off|status`
lib/monitor/app/main.swift       MonitorBar menu bar app (`monitor app`)
lib/monitor/app/AppIcon.png      app icon, 1024 px; `monitor app` makes the .icns
monitor-linux              Linux `monitor` (bash, Hyprland)
lib/monitor/omarchy/       Omarchy bar widget (`monitor bar`)
vox                        Voxtype companion: post-process hook, list/copy, status (zsh)
lib/vox/app/main.swift     VoxBar menu bar app (`vox app`)
lib/vox/app/AppIcon.png    app icon, 1024 px; `vox app` makes the .icns
tests/monitor-linux.test.sh
install.sh                 symlinks the 5 entry points into ~/.local/bin (bash)
```

Requires: `fzf` ≥ 0.30 (features here assume 0.74), `zsh`; `kubectl` (kube/logs),
`lsof` (ports), `swiftc` (monitor and vox, macOS), `jq` + `hyprctl` (monitor,
Linux), Voxtype (vox).

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
