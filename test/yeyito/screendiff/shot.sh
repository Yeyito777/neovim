#!/bin/bash
# shot.sh NVIM FILE OUT [keys...]
# Open FILE (relative to the current directory) in NVIM inside a 120x40 tmux
# pane with truecolor and empty config/state dirs, send the keys, and save
# the screen with colors to OUT. NVIM "build" means this checkout's
# build/bin/nvim with its runtime/. Keys are tmux send-keys names
# (Escape, Enter, C-Space, ...); "sleep:N" waits N seconds. WAIT=secs sets
# the startup wait (default 1.5; give language servers ~3).
# Compare two shots with: python3 cells.py A B
set -u
nvim=$1 file=$2 out=$3
shift 3
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
mkdir -p "$tmp/config" "$tmp/state" "$tmp/tmp"
envs="XDG_CONFIG_HOME=$tmp/config XDG_STATE_HOME=$tmp/state TMPDIR=$tmp/tmp TERM=xterm-256color COLORTERM=truecolor NVIM_NOTTYFAST=1"
if [ "$nvim" = build ]; then
  envs="$envs VIMRUNTIME=$repo/runtime"
  nvim=$repo/build/bin/nvim
fi
sock=$tmp/tmux.sock
tmux -S "$sock" -f /dev/null new-session -d -s shot -x 120 -y 40 -c "$PWD" "env $envs $nvim $file"
sleep "${WAIT:-1.5}"
for k in "$@"; do
  if [[ $k == sleep:* ]]; then sleep "${k#sleep:}"; else tmux -S "$sock" send-keys -t shot "$k"; sleep 0.25; fi
done
sleep 0.8
tmux -S "$sock" capture-pane -p -e -t shot > "$out"
tmux -S "$sock" kill-server 2>/dev/null
sleep 0.5 # let nvim finish writing its state before removing the dirs
rm -rf "$tmp" 2>/dev/null
