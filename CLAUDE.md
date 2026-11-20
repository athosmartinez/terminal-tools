# CLAUDE.md — working notes for this repo

Guidance for AI-assisted work on **terminal-tools** (`kube`, `logs`, `ports` —
three zsh + fzf terminal TUIs — plus `monitor`, a macOS Swift CLI and menu bar
app, with a separate Linux/Hyprland version in bash, `vox`, a Voxtype
companion: transcription history plus a menu bar app with the daemon state,
and `battery`, a macOS Swift CLI and menu bar app with the battery of the
connected Bluetooth devices). Conventions and gotchas live here; user-facing
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

- `gh-shim` — bash, installed as `gh` in `~/.local/share/terminal-tools/shims`
  (its own directory, which must be first on PATH). It picks the GitHub
  account per command (GH_ACCOUNT, `--repo` owner via
  `~/.config/terminal-tools/gh-shim.conf`, or the repo's
  `credential.https://github.com.username`) and execs the next real `gh` on
  PATH with `GH_TOKEN`. `gh auth …` and a preset token pass through. It must
  stay bash 3.2 compatible (macOS `/bin/bash`). Test:
  `bash tests/gh-shim.test.sh` (fake `gh`, temp git repos, no network).
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
  Virtual display (`VirtualDisplay.swift`, menu items *Turn On/Off Virtual
  Display* and *Open Moonlight on Virtual Display*): a display with no screen,
  so a borderless Moonlight stream on it turns "pointer past the monitor's
  edge" into control of the remote machine. Gotchas:
  - `CGVirtualDisplay*` are private classes with no header. Classes come from
    `NSClassFromString`; properties are set with key-value coding (it converts
    to the property's integer width) after `responds(to:)`, because an unknown
    key raises an exception that Swift cannot catch; the two inits with
    arguments and `applySettings:` go through the method IMP, after a check of
    the type encoding. `alloc`/`init` use raw pointers: an init consumes self
    and can return nil, which ARC gets wrong for a C function pointer.
  - The display lives while the `CGVirtualDisplay` object lives, so the app
    owns it; the CLI compiles the file but never makes one.
    `applicationWillTerminate` releases it (`pkill` skips that, and the display
    still dies with the process).
  - `DisplayInfo.isExternal` is "not built in and not virtual" (the fixed
    `vendorID`/`productID`, read with `CGDisplayVendorNumber` /
    `CGDisplayModelNumber`). `state`, `turnOff`, `turnOn` and the cable restore
    all use it; without it the virtual display reads as an external monitor
    that is on. The vendor is not a valid EDID code, so no monitor has it.
  - Placement is not done in `turnOn`: WindowServer lists the new display a
    moment later. The app runs `place` 1 s after the toggle, after every
    reconfiguration with an add/remove/enable/disable flag, and after wake.
    `place` is idempotent and its own move raises only "moved" flags, so it
    cannot loop. Anchor = the external monitor, else the built-in panel; it
    gives y, and x is past every real display on that side, so the virtual
    display never lands on one. With no real display active `place` turns the
    virtual display off; the app keeps `virtualWanted` and turns it on again
    when a placement finds a real display (lid opened, wake). While a monitor
    is plugged in or out, WindowServer leaves the virtual display out of the
    active list for a moment: `place` returns false and the app tries again,
    up to 8 times 1 s apart (one try gave "not active" and left it there); a
    thrown error is retried the same way. `place` checks for a real display
    before it checks the list, because both can be missing at once. After the
    last failed try the app releases the object and makes a new display
    (`recreatedVirtual`): WindowServer can drop the display, keep the object,
    and send no event when it returns. Only once until a placement succeeds,
    a Turn On or a wake: a display event cannot reset it, because the new
    display's own add event would start a cycle of about 9 s.
  - After a placement the app checks the Moonlight windows that the user sent
    to the virtual display (`moonlightOnVirtual`): macOS moves them off a
    display that leaves the list and never back. It does not move them (the
    owner's choice): the icon gets a warning badge and the menu says
    "Moonlight left the virtual display" above the *Move* items. A window that
    AX cannot find counts as left (`Moonlight.leftVirtual`). The check runs 2 s
    after a placement (the AX frame comes late), 5 s after Open Moonlight,
    at menu open and when a Moonlight quits. Without the Accessibility grant
    the badge shows too, with the item *Allow Accessibility to Check
    Moonlight*. The check's AX calls have a 1 s timeout
    (`AppWindow.checkTimeout`, `AXUIElementSetMessagingTimeout`): it runs on
    the main thread at every menu open. A move keeps the default wait: a
    window in a full screen transition can answer late.
  - Moonlight starts through `NSWorkspace.openApplication` with arguments and
    `createsNewApplicationInstance` (a child `Process` would run under
    MonitorBar's privacy permissions). Qt's `-qwindowgeometry +x+y` moves the
    first window; the stream window opens on that window's display. The Qt
    syntax has no negative coordinates, so `virtual_side=left` gets no
    geometry.
  - A Moonlight that already runs is not started again: the menu shows *Move
    Moonlight to Virtual Display* / *to Main Display*, which move its main
    window with the Accessibility API (`AppWindow`: `kAXPosition`/`kAXSize`,
    size-position-size). Moonlight's borderless stream is a native full
    screen window (`AXFullScreen` = 1), which refuses a position (AXError
    -25200): `setFrame` sets `AXFullScreen` to false, waits until the position
    is settable, moves, and sets it to true again on the new display. A window
    that still ends a transition (out of full screen, out of a zoom) ignores
    a frame request and reports success — this made the move work "sometimes".
    So `setFrame` reads the frame back (`settledFrame`: two equal reads 150 ms
    apart) and sends the request again, up to 6 times 0.5 s apart, also for
    the way back into full screen; the app checks that the result is on the
    wanted display and shows an error if not. Each step goes to the log
    (`moonlight <pid>: …`, subsystem `…monitorbar`). On the virtual display
    the window always ends in full screen: only then the video covers the
    display and the pointer maps 1:1 (a titled window gave 1920x1050 at y=30
    and a letterboxed video). The frame and the full screen state from before
    the move are kept per pid in the app (`moonlightHome`) for the way back,
    and dropped only after the window took them. A window on a real display
    is left as it is. Verified on Moonlight 6.2.0 with a live stream, both
    ways, from a window and from full screen. The target frames are pure
    (`Moonlight.frame(onVirtual:…)`, `frame(onReal:…)`); AppKit rectangles go
    through `Moonlight.global(cocoa:…)` because AX and displays count y down.
    Accessibility is tied to the cdhash like BatteryBar's Bluetooth: after
    `monitor app` the entry stays in the list but is ignored — remove and add
    it, or `tccutil reset Accessibility
    com.athosmartinez.terminal-tools.monitorbar`. Moving the window acts on
    the owner's live stream — let the owner run it.
  - Config keys in `monitor.conf` (`MonitorConfig` in `DisplayToggle.swift`):
    `virtual_size=`, `virtual_side=`, `virtual_y=`, `moonlight_host=` (no
    default: it names a machine, so it never goes in the repo),
    `moonlight_app=`.
  - Turning the virtual display on moves windows and changes the owner's
    arrangement — let the owner run it, like `off`.
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

- `battery` — macOS only. Reads the GATT Battery Service (0x180F, Battery
  Level 0x2A19, first byte = percent) of every peripheral that is already
  connected: `retrieveConnectedPeripherals(withServices: [180F])`, then
  `connect` (an app-level link over the system's connection, no scan),
  discover, read, and `setNotifyValue` when the characteristic has `notify`.
  This is the only way to see many BLE keyboards: `system_profiler` and
  `ioreg BatteryPercent` show no battery for them. Same layout as `monitor`:
  `lib/battery/Battery.swift` is pure Foundation (config, labels, order,
  title) and is the only file the tests compile; `BLE.swift` is the
  CoreBluetooth `BatterySource`; the wrapper rebuilds the CLI by `-nt`;
  `battery app` builds `~/Applications/BatteryBar.app` (app icon from
  `lib/battery/app/AppIcon.png`, drawn by `swift lib/battery/app/AppIcon.swift
  <png>`; the Info.plist has `NSBluetoothAlwaysUsageDescription`). Not live — rerun
  `battery app`. Gotchas:
  - `retrieveConnectedPeripherals` is empty before `.poweredOn`; rescan only
    from `centralManagerDidUpdateState`. `.unauthorized` must not look like
    "no device": the CLI exits 2, the app shows a menu line.
  - Keep a strong reference to every connected `CBPeripheral`, or the link
    drops silently.
  - The CLI binary embeds an Info.plist (`-sectcreate __TEXT __info_plist`)
    with the usage text, for a run outside a terminal. From a terminal, the
    permission (and its text) is the terminal app's: a build with no plist
    worked there too.
  - Ad-hoc signing: every `battery app` rebuild changes the cdhash, so the
    Bluetooth grant can turn into `.unauthorized` silently. Fix:
    `tccutil reset BluetoothAlways com.athosmartinez.terminal-tools.batterybar`,
    relaunch, allow again.
  - macOS CoreBluetooth has no system "device connected" event
    (`registerForConnectionEvents` is iOS only). The app watches IOKit for an
    `IOHIDDevice` with `Transport = "Bluetooth Low Energy"` (first match +
    terminated; drain the iterator to arm it; nothing is opened, so no Input
    Monitoring) and rescans 2 s later, because GATT is not ready at the match.
    Non-HID devices show on the `interval=` timer (default 1800 s), on wake
    (+5 s), or on Refresh Now. The timer reads every device again, also the
    ones with notifications, so the "last" time on Refresh Now (`lastUpdate`,
    the last value that arrived) is never older than the interval.
  - Config `~/.config/terminal-tools/battery.conf` (`BATTERY_CONFIG`
    overrides it): `<name>=<label>` (label after the last `=`), `show=`,
    `low=`, `interval=`, `layout=stacked|inline`. Order is the `show=` order, else by name — never
    discovery order, which changes per run. No device names in code or tests:
    the tests use fakes (`Keyboard K1`); real names only in the README example.
  - The stacked title (default, 2+ devices) is an `NSImage` drawn by
    `stackedImage`: 10 pt monospaced digits, two lines in
    `NSStatusBar.system.thickness`, columns split by `titleColumns`. With no
    low value it is a template (the bar tints it); with one it is in color,
    drawn under the button's `effectiveAppearance`, which is observed (KVO) to
    redraw when the bar turns light or dark.

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

- Syntax: `zsh -n kube logs ports vox battery lib/*.zsh` (run per file).
- `battery`: `bash tests/battery.test.sh` compiles `lib/battery/Battery.swift`
  with `tests/battery/main.swift` (no Bluetooth, fake devices). The real check
  is `./battery` on a Mac with devices connected.
- `monitor` (macOS): `bash tests/monitor.test.sh` compiles `lib/monitor/*.swift`
  with `tests/monitor/main.swift` and runs the pure rules on fake `DisplayInfo`
  values: config, external filter, placement, Moonlight arguments. It also
  builds the `CGVirtualDisplay` descriptor and settings (plain objects), which
  shows a macOS update that changed the private classes. It never makes a
  `CGVirtualDisplay`, so no display appears — keep it that way.
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
lib/monitor/DisplayToggle.swift  display off/on core (private CoreGraphics call) + monitor.conf
lib/monitor/DDC.swift            input switch over DDC/CI (private IOAVService)
lib/monitor/VirtualDisplay.swift virtual display (private CGVirtualDisplay) + Moonlight command
lib/monitor/cli/main.swift       `monitor on|off|status`
lib/monitor/app/main.swift       MonitorBar menu bar app (`monitor app`)
lib/monitor/app/AppIcon.png      app icon, 1024 px; `monitor app` makes the .icns
monitor-linux              Linux `monitor` (bash, Hyprland)
lib/monitor/omarchy/       Omarchy bar widget (`monitor bar`)
vox                        Voxtype companion: post-process hook, list/copy, status (zsh)
lib/vox/app/main.swift     VoxBar menu bar app (`vox app`)
lib/vox/app/AppIcon.png    app icon, 1024 px; `vox app` makes the .icns
battery                    entry point (zsh wrapper, macOS) → lib/battery/
lib/battery/Battery.swift  config, labels, order, title (pure, tested)
lib/battery/BLE.swift      CoreBluetooth reader (GATT Battery Service)
lib/battery/cli/main.swift `battery [status] [-a]`
lib/battery/app/main.swift BatteryBar menu bar app (`battery app`)
lib/battery/app/AppIcon.png  app icon, 1024 px; AppIcon.swift draws it
tests/monitor-linux.test.sh
tests/monitor.test.sh      + tests/monitor/main.swift (macOS rules, fake displays)
tests/battery.test.sh      + tests/battery/main.swift
install.sh                 symlinks the 6 entry points into ~/.local/bin (bash)
```

Requires: `fzf` ≥ 0.30 (features here assume 0.74), `zsh`; `kubectl` (kube/logs),
`lsof` (ports), `swiftc` (monitor, vox and battery, macOS), `jq` + `hyprctl` (monitor,
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
