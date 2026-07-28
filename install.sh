#!/usr/bin/env zsh
#
# install.sh — symlink kube, logs and ports into ~/.local/bin.
# The shared lib/ is resolved relative to each script, so it stays in the repo.
#
#   ./install.sh              symlink into ~/.local/bin (default)
#   BIN=~/bin ./install.sh    symlink into a different directory
#
emulate -L zsh
set -e

REPO=${0:A:h}
BIN=${BIN:-$HOME/.local/bin}
mkdir -p "$BIN"

for tool in kube logs ports; do
  src="$REPO/$tool"
  dst="$BIN/$tool"
  if [[ -e $dst && ! -L $dst ]]; then
    print -P "%F{yellow}⚠  $dst exists and is not a symlink — skipping (move it aside first)%f"
    continue
  fi
  ln -sfn "$src" "$dst"
  print -P "%F{green}✓%f linked $dst → $src"
done

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) print -P "%F{yellow}note:%f $BIN is not on your \$PATH — add it to use the tools by name" ;;
esac

print
print -P "Dependencies: %F{cyan}fzf%f (required), %F{cyan}kubectl%f (kube/logs), %F{cyan}lsof%f (ports)."
