#!/usr/bin/env bash
# 构建修复版 pot 并安装到本地 flatpak 仓库（potlocal）。
# 前置：Fedora + flatpak + org.gnome.Platform/Sdk 48 + org.flatpak.Builder +
#       flathub 原版 com.pot_app.pot（提供 webkit2gtk-4.0 运行库与 share 资源）+ node/pnpm。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RANDER_POT_WORK:-$ROOT/.work}"
STABLE_FILES="$HOME/.local/share/rander/environments/niri/dms/flatpak/app/com.pot_app.pot/x86_64/stable/active/files"
# 无 rander 隔离时用默认路径
[[ -d $STABLE_FILES ]] || STABLE_FILES="$HOME/.local/share/flatpak/app/com.pot_app.pot/x86_64/stable/active/files"
[[ -d $STABLE_FILES ]] || { echo "找不到已安装的 flathub pot 运行库目录"; exit 1; }

RUNTIME_LIB="/var/lib/flatpak/runtime/org.gnome.Platform/x86_64/48/active/files/lib/x86_64-linux-gnu"
RUSTC_DIR="$WORK/rust-1.83.0"   # rustc 1.83/1.84 均可；1.85+ 会触发 wry 编译问题
export PATH="$RUSTC_DIR/bin:$PATH"

mkdir -p "$WORK/sysroot/lib"

# 1) 从已安装实例提取运行库 tar（flatpak-builder 的 app-libs 模块输入）
if [[ ! -f $WORK/app-libs.tar ]]; then
  tar -cf "$WORK/app-libs.tar" -C "$STABLE_FILES" lib libexec
fi

# 2) 生成链接用 sysroot：pc 文件 + .so 符号
for pc in webkit2gtk-4.0 javascriptcoregtk-4.0 libsoup-2.4 libsoup-gnome-2.4; do
  sed "s|prefix=.*|prefix=$STABLE_FILES|; s|-L\${libdir}|-L$STABLE_FILES/lib|" \
    "$STABLE_FILES/lib/pkgconfig/$pc.pc" > "$WORK/sysroot/lib/$pc.pc" 2>/dev/null || true
done
for f in libwebkit2gtk-4.0.so libjavascriptcoregtk-4.0.so libsoup-2.4.so libsoup-gnome-2.4.so; do
  ln -sf "$STABLE_FILES/lib/$f" "$WORK/sysroot/lib/$f"
done
for f in libicuuc.so.75 libicui18n.so.75 libicudata.so.75 libjxl.so.0.10 libjxl_cms.so.0.10 libjxl_threads.so.0.10; do
  [[ -e $WORK/sysroot/lib/$f ]] || ln -sf "$RUNTIME_LIB/$f" "$WORK/sysroot/lib/$f"
done

export PKG_CONFIG_PATH="$WORK/sysroot/lib"
export RUSTFLAGS="-L$WORK/sysroot/lib -Clink-arg=-Wl,-rpath-link,$WORK/sysroot/lib"

# 3) 前端 + Rust（必须带 custom-protocol feature，否则资源不内嵌、窗口永不显示）
cd "$ROOT"
[[ -d node_modules ]] || pnpm install --frozen-lockfile
pnpm build
cd src-tauri
CARGO_TARGET_DIR="$WORK/target" cargo build --release --features custom-protocol

# 4) 组装 flatpak：官方 deb 的 usr 骨架 + 替换二进制
DEB_CACHE="$WORK/deb-cache"
if [[ ! -f $DEB_CACHE/data.tar.gz ]]; then
  mkdir -p "$DEB_CACHE"
  curl -fsSL -o "$DEB_CACHE/pot.deb" \
    https://github.com/pot-app/pot-desktop/releases/download/3.0.7/pot_3.0.7_amd64.deb
  echo "6e9ed622a079efcd113c0e28f3f55e5c43b18587acc3fb8f1a6cd076a911b2b7  $DEB_CACHE/pot.deb" | sha256sum -c -
  (cd "$DEB_CACHE" && ar x pot.deb && tar -xzf data.tar.gz)
fi
cp "$WORK/target/release/pot" "$DEB_CACHE/usr/bin/pot"
tar -czf "$WORK/data.tar.gz" -C "$DEB_CACHE" usr

# 5) 构建并导出到本地仓库
cp "$ROOT/pack/com.pot_app.pot.local.yml" "$WORK/"
export TMPDIR="$WORK/tmp" XDG_RUNTIME_DIR="$WORK/xdgrt"
mkdir -p "$TMPDIR" "$XDG_RUNTIME_DIR"
flatpak run org.flatpak.Builder --force-clean --disable-rofiles-fuse \
  --repo="$WORK/repo" "$WORK/build-dir" "$WORK/com.pot_app.pot.local.yml"

echo
echo "构建完成。安装（覆盖 flathub stable）："
echo "  flatpak --user remote-add --if-not-exists potlocal file://$WORK/repo"
echo "  flatpak --user remote-modify --no-gpg-verify potlocal"
echo "  flatpak --user install --reinstall --noninteractive potlocal com.pot_app.pot//stable"
echo "  flatpak --user mask com.pot_app.pot   # 防止 flathub 更新覆盖"
