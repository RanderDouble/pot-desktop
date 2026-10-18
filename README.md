# pot-desktop 本地修复版

pot-desktop 3.0.7 的个人 fork，修复 niri/Wayland 下翻译弹窗失焦不关闭的问题，
并维护本地 Flatpak 重打包流程。上游说明见 `README.upstream.md`，
上游仓库：https://github.com/pot-app/pot-desktop

## 修复内容

`src/window/Translate/index.jsx`：失焦时启动 100 毫秒关闭定时器，同时监听
`tauri://focus` 与 `tauri://move` 取消定时器。Wayland 下 `tauri://move` 由 GTK
configure-event 直报（tao 0.16 实现），而窗口显示时 pot 调 `set_position`、niri
在失焦时下发带 activated 状态变更的 configure，均落在 100 毫秒窗口内，关闭动作
持续被取消。注释掉 `tauri://move` 监听；`tauri://focus` 监听保留，Linux 下拖动
窗口不丢焦，Windows 下 blur→focus 抖动场景也不受影响。
上游对 Hyprland 有同样处理的补丁（`patches/hyprland.patch`），本仓库采用同样思路覆盖 niri。

## 工具链要求（踩过坑）

- rustc 1.83（独立工具链放 `.work/rust-1.83.0/`）。
  1.98 编不过 `wry 0.24.11`：`gtk::prelude::*` 与 `webkit2gtk::traits::*` 的
  `SettingsExt` 同名，新版 rustc 按确定性规则让先导入的 glob 遮蔽后导入的，
  所有 `settings.set_*` 报 E0599。不加 vendor patch，用旧工具链即可。
- Cargo.lock 保持上游 v3 内容，不要让新版 cargo 重新解析（会引入 edition2024 依赖）。
- 必须 `cargo build --release --features custom-protocol`。不带该 feature 时前端资源
  不内嵌进二进制，webview 加载不到页面，`appWindow.show()` 永不执行，
  窗口对象存在但永不显示（表现为窗口完全不出现，与失焦问题无关，极易误判）。
- pnpm 构建需要 `CI=true` 与 `pnpm_config_verify_deps_before_run=false`。

## 本地 Flatpak 打包

`pack/build.sh` 一键完成：提取已安装 flathub 实例的 webkit2gtk-4.0 运行库（避免从源码
编译 webkit）→ 生成链接 sysroot（pc 文件前缀改写 + icu75/jxl0.10 符号，sqlite/libpsl 的
pc 从 rpm 解出）→ pnpm build + cargo build → 组 flatpak（官方 deb 的 usr/share 骨架 +
替换 bin/pot）→ flatpak-builder 导出到 `.work/repo`。

安装（脚本末尾会打印）：加 potlocal 远程（file:// 指向 `.work/repo`，`--no-gpg-verify`），
`flatpak --user install --reinstall potlocal com.pot_app.pot//stable`，
再 `flatpak --user mask com.pot_app.pot` 防止 flathub 更新覆盖。
上游发新版时：解 mask、升级源码、重跑 build.sh、重新 mask。

## 运行环境注意

本机 shell 环境 /run/user/1000 与 /tmp 上层挂载为只读：flatpak 起沙箱需要可写的
XDG_RUNTIME_DIR，用 `export XDG_RUNTIME_DIR=$WORK/xdgrt TMPDIR=$WORK/tmp` 绕开；
用 systemd transient unit 启动时走真 XDG_RUNTIME_DIR（/run/user/1000）即可，
flatpak 命令需要 `XDG_DATA_HOME=~/.local/share/rander/environments/niri/dms`。

## 仓库布局

- `src/`（仓库根即 pot 源码树）：上游导入提交后跟修复提交。
- `pack/`：flatpak manifest 模板与 build.sh。
- `.work/`（已 gitignore）：sysroot、deb-cache、rust 工具链、target、repo。
