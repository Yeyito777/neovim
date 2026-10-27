#!/bin/sh
# Build this fork and install it as ~/.local/bin/nvim. The editor config is
# part of the runtime (runtime/pack/yeyito/start/yeyito), so nothing goes in
# ~/.config/nvim.
#
#   ./install.sh            build + install
#   PREFIX=... BIN=... ./install.sh
set -eu
cd "$(dirname "$0")"

PREFIX=${PREFIX:-$HOME/.local/opt/nvim}
BIN=${BIN:-$HOME/.local/bin}
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
# Parser sources are huge; keep compiler temp files off a small tmpfs /tmp.
mkdir -p .deps/tmp
export TMPDIR="$PWD/.deps/tmp"

make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX="$PREFIX" \
  CMAKE_BUILD_PARALLEL_LEVEL="$JOBS"

# Install into a fresh directory and swap it in, so files deleted from the
# repo don't linger in the installed runtime.
rm -rf "$PREFIX.new" "$PREFIX.old"
cmake --install build --prefix "$PREFIX.new" >/dev/null
if [ -e "$PREFIX" ]; then mv "$PREFIX" "$PREFIX.old"; fi
mv "$PREFIX.new" "$PREFIX"
rm -rf "$PREFIX.old"

mkdir -p "$BIN"
ln -sfn "$PREFIX/bin/nvim" "$BIN/nvim"
"$BIN/nvim" --headless -c 'lua io.write(vim.fn.has("conceal_compact") == 1 and "ok\n" or "MISSING conceal_compact\n")' -c qa
echo "installed $("$BIN/nvim" --version | head -1) -> $BIN/nvim"
