#!/bin/bash
# flatpak 起沙箱需要可写 TMPDIR（本机 /run/user 只读），缺失时先建
export TMPDIR="${TMPDIR:-$HOME/scratch/tmp}"
mkdir -p "$TMPDIR"
# flatpak 用户安装目录位于 Rander 环境树
export XDG_DATA_HOME="$HOME/.local/share/rander/environments/niri/dms"
# WAYLAND_DISPLAY 指向宿主 relay（绕开 flatpak security-context 过滤，全协议可见）
exec /usr/bin/flatpak run --branch=stable --arch=x86_64 --command=pot \
  --filesystem="$HOME/.local/state/pot-wayland" \
  --env=WAYLAND_DISPLAY="$HOME/.local/state/pot-wayland/relay.sock" \
  com.pot_app.pot
