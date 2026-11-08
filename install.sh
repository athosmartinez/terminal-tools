#!/usr/bin/env bash
#
# install.sh — symlink kube, logs, ports, monitor and vox into ~/.local/bin,
# and gh-shim as "gh" into ~/.local/share/terminal-tools/shims.
# The shared lib/ is resolved relative to each script, so it stays in the repo.
#
#   ./install.sh              symlink into ~/.local/bin (default)
#   BIN=~/bin ./install.sh    symlink into a different directory
#
set -e

REPO=$(cd "$(dirname "$0")" && pwd -P)
BIN=${BIN:-$HOME/.local/bin}
mkdir -p "$BIN"

for tool in kube logs ports monitor vox; do
  src="$REPO/$tool"
  if [[ $tool == monitor && $(uname -s) == Linux ]]; then
    src="$REPO/monitor-linux"
  fi
  dst="$BIN/$tool"
  if [[ -e $dst && ! -L $dst ]]; then
    printf '\033[33m⚠  %s exists and is not a symlink — skipping (move it aside first)\033[0m\n' "$dst"
    continue
  fi
  ln -sfn "$src" "$dst"
  printf '\033[32m✓\033[0m linked %s → %s\n' "$dst" "$src"
done

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf '\033[33mnote:\033[0m %s is not on your $PATH — add it to use the tools by name\n' "$BIN" ;;
esac

# gh-shim replaces "gh" on PATH, so it gets its own directory: putting that
# directory first must not move the other tools ahead of system commands.
SHIMS=${SHIMS:-$HOME/.local/share/terminal-tools/shims}
mkdir -p "$SHIMS"
if [[ -e $SHIMS/gh && ! -L $SHIMS/gh ]]; then
  printf '\033[33m⚠  %s exists and is not a symlink — skipping\033[0m\n' "$SHIMS/gh"
else
  ln -sfn "$REPO/gh-shim" "$SHIMS/gh"
  printf '\033[32m✓\033[0m linked %s → %s\n' "$SHIMS/gh" "$REPO/gh-shim"
fi
case ":$PATH:" in
  "$SHIMS:"*) ;;
  *) printf '\033[33mnote:\033[0m to use gh-shim, put %s FIRST on $PATH\n' "$SHIMS" ;;
esac

echo
printf 'Dependencies: \033[36mfzf\033[0m (required), \033[36mkubectl\033[0m (kube/logs), \033[36mlsof\033[0m (ports), \033[36mswiftc\033[0m (monitor, macOS), \033[36mjq\033[0m + \033[36mhyprctl\033[0m (monitor, Linux), \033[36mvoxtype\033[0m (vox).\n'
