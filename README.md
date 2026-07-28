# terminal-tools

A small set of personal terminal TUIs — fast, keyboard-driven, and built on
[`fzf`](https://github.com/junegunn/fzf). Three tools:

| Tool | What it does |
|------|--------------|
| **`kube`** | A Kubernetes cockpit: problems on top, then every workload/pod/node/ingress/secret, with live metrics, contextual actions (restart, scale, exec, port-forward, logs…) and auto-refresh. Think a lightweight, keyboard-first `k9s`. |
| **`logs`** | Follow logs of any workload across all namespaces — one color per pod, auto-reconnect on restarts. |
| **`ports`** | View and kill processes listening on TCP ports (macOS), with a confirm step. |

Every mutating action **prints the real command it runs** (`$ kubectl rollout restart …`,
`$ kill -TERM …`) before executing — so the TUI doubles as a way to learn the
underlying commands.

## Highlights

- **One persistent `fzf` instance** per session — views, sorting, namespace
  scoping, actions and refresh all happen *in place*, no flicker.
- **Contextual keybar** — the header always shows the keys that apply to the
  current view (nodes shows `cordon/drain`, pods hides `restart/scale`, …).
- **Auto-refresh** with a cached preview pane, so live data never hammers the
  cluster or repaints noisily.
- **Command transparency** — learn `kubectl`/`kill` by seeing every command.
- **Light- and dark-theme friendly** colors (no hard-coded assumptions).

## Requirements

- [`fzf`](https://github.com/junegunn/fzf) `≥ 0.30` (`brew install fzf`)
- `zsh`
- `kube` / `logs`: [`kubectl`](https://kubernetes.io/docs/tasks/tools/) with a
  configured context (uses the **current** context; metrics need
  `metrics-server`)
- `ports`: `lsof` (ships with macOS)

## Install

```sh
git clone https://github.com/athosmartinez/terminal-tools.git
cd terminal-tools
./install.sh            # symlinks kube, logs, ports into ~/.local/bin
```

`install.sh` symlinks the three entry points into `~/.local/bin` (make sure it's
on your `$PATH`). Because they're symlinks, editing files in the repo updates
the installed tools instantly. The shared `lib/` is resolved relative to each
script, so it travels with the repo.

## Usage

```sh
kube                 # open the cockpit
logs                 # pick a workload and follow its logs
logs <query>         # 1 match → follow immediately
ports                # pick a listening process to kill
ports <port|name>    # filter; `ports kill <q>` to kill directly
<tool> -h            # help
```

### `kube` keys

```
Tab / Shift-Tab  switch view        ^N  namespace scope    ^T  cycle sort
Enter            primary action     ^D  describe+events     ^Y  view YAML
^R restart  ^S scale  ^X delete  ^P pods    ^A  actions menu (the long tail)
^L  toggle auto-refresh   F5  reload now    ?  help          Esc quit
```

The **actions menu** (`^A`) carries everything else — rollback, set-image,
exec/shell, port-forward, cordon/uncordon/drain, cronjob trigger, secret
reveal, `kubectl cp`, and more. Mutations always confirm first; `^Y` in the
menu copies the resolved command to the clipboard.

### Environment knobs

| Variable | Default | Effect |
|----------|---------|--------|
| `KUBE_REFRESH` | `5` | auto-refresh interval (seconds); `0` starts paused |
| `KUBE_PREVIEW_TTL` | `20` | preview cache TTL (seconds) |
| `LOGS_REFRESH` / `PORTS_REFRESH` | `5` / `4` | picker auto-refresh; `0` disables |
| `KUBE_ALL` | — | `1` shows cert-manager ACME solver ingresses too |

## Notes

- `ports` is macOS-specific (`lsof` flags). `kube`/`logs` are cross-platform
  wherever `kubectl` + `fzf` run.
- All actions run against your **current** `kubectl` context. There is no
  hidden state or config — the tools read live from the cluster.

## License

MIT — see [LICENSE](LICENSE).
