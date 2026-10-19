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

## Wayland 剪贴板与取词（copy_text 与 relay）

新功能层：

- `src-tauri/src/clipboard.rs`：`copy_text()` 在 Wayland 下用 wl-clipboard-rs 写
  data-control（`serve_requests Only(8)` 防止复制进程常驻），同时 arboard 双写 X11，
  任一成功即返回；`primary_text()` 读 primary selection。`cmd.rs` 暴露为
  `copy_text` 命令，前端所有 `writeText` 调用点（TargetArea/SourceArea/Recognize
  的 TextArea）统一改走该命令。`window.rs` 的 `selection_translate` 在选区为空时
  回退读取 primary，仍为空直接返回不开窗。
- flatpak 沙箱的 wayland socket 挂的是 flatpak 内置 proxy，带 security-context
  元数据；niri 对 security-context 客户端隐藏 data-control、primary-selection、
  screencopy 等 global，沙箱内取词与剪贴板全部失效。`pack/wayland-relay.py`
  在宿主侧以普通文件名的 unix socket 透传 niri socket（含 SCM_RIGHTS fd 传递），
  pot 沙箱内 `WAYLAND_DISPLAY` 指向该 relay 即可拿到全部协议。
- `src-tauri/src/screenshot.rs`：抓屏从 screenshots crate（X11 root 抓取，XWayland
  下恒为空图）换成调用包内 grim 走 zwlr_screencopy，沙箱内经 relay 直连 niri；
  grim 由 `pack/build.sh` 从宿主拷入、manifest 安装到 /app/bin。
- OCR 识别链已端到端实测：识别服务列表首位是 rapid 插件（RapidOcrOnnx，info.json
  把 auto 映射到 ch 模型），`recognize_auto_copy` 打开后识别结果经 `copy_text`
  自动写入剪贴板。niri 侧 Alt+W 保留宿主脚本（slurp 选区 + grim 裁图 +
  `?screenshot=false`），负责替代 pot 自带截图流程的框选交互。

### systemd 服务（写法与作用）

修复版 flatpak 依赖两个 systemd user 服务，单元定义收录在 `pack/deploy/`，
路径全部用 `%h`（家目录）、`%t`（`/run/user/$UID`）、`$HOME` 书写，换机器直接可用。

**pot-wayland-relay.service**：Wayland 协议透传桥。flatpak 给沙箱挂的 socket 带
security-context 标记，niri 对这类客户端隐藏 data-control、primary-selection、
screencopy 等协议，沙箱内取词、剪贴板、截图全部失效。本服务运行
`pack/wayland-relay.py`，在宿主侧用普通文件名 socket 双向透传宿主真实 socket
（字节流与 SCM_RIGHTS fd 均转发）：

```ini
[Unit]
Description=Wayland fd relay for pot (bypass flatpak security-context filter)
[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/wayland-relay.py %h/.local/state/pot-wayland/relay.sock %t/wayland-1
Restart=on-failure
RestartSec=2
[Install]
WantedBy=default.target
```

**pot.service**：pot 守护启动器，随登录自启、崩溃自动拉起。经 `pack/deploy/run-pot.sh`
以 flatpak 启动修复版：挂载 relay 状态目录、把 `WAYLAND_DISPLAY` 指向 relay socket、
导出可写 TMPDIR（`/run/user` 只读时 flatpak 起沙箱需要可写临时目录）：

```ini
[Unit]
Description=Pot translate daemon (patched fork)
After=pot-wayland-relay.service
Requires=pot-wayland-relay.service
[Service]
ExecStart=%h/.local/bin/run-pot.sh
Restart=on-failure
RestartSec=3
[Install]
WantedBy=default.target
```

```bash
#!/bin/bash
# run-pot.sh；flatpak 起沙箱需要可写 TMPDIR（/run/user 只读），缺失时先建
export TMPDIR="${TMPDIR:-$HOME/scratch/tmp}"
mkdir -p "$TMPDIR"
# flatpak 用户安装目录位于 Rander 环境树
export XDG_DATA_HOME="$HOME/.local/share/rander/environments/niri/dms"
exec /usr/bin/flatpak run --branch=stable --arch=x86_64 --command=pot \
  --filesystem="$HOME/.local/state/pot-wayland" \
  --env=WAYLAND_DISPLAY="$HOME/.local/state/pot-wayland/relay.sock" \
  com.pot_app.pot
```

**下个系统部署顺序**：

1. `pack/build.sh` 构建并按脚本末尾提示安装（加 potlocal 远程、install、mask）。
2. `install -Dm755 pack/wayland-relay.py ~/.local/bin/wayland-relay.py`、
   `install -Dm755 pack/deploy/run-pot.sh ~/.local/bin/run-pot.sh` 与
   `install -Dm755 pack/deploy/pot-grim-ocr.sh ~/.config/niri/scripts/pot-grim-ocr.sh`。
3. `install -Dm644 pack/deploy/pot-wayland-relay.service pack/deploy/pot.service -t ~/.config/systemd/user/`，
   `systemctl --user daemon-reload`，
   `systemctl --user enable --now pot-wayland-relay.service pot.service`。
4. `~/.config/autostart/com.pot_app.pot.desktop` 标 `Hidden=true` 防双实例；
   niri 浮动规则 `match app-id=r"^pot$" open-floating true`。
5. niri 快捷键：Alt+Q → `curl --silent --fail -X POST --data-binary '' http://127.0.0.1:60828/selection_translate`；
   Alt+Shift+T → `curl --silent --fail http://127.0.0.1:60828/input_translate`；
   Alt+W → 宿主脚本（slurp + grim + `?screenshot=false`）。

## 运行环境注意

本机 shell 环境 /run/user/1000 与 /tmp 上层挂载为只读：flatpak 起沙箱需要可写的
XDG_RUNTIME_DIR，用 `export XDG_RUNTIME_DIR=$WORK/xdgrt TMPDIR=$WORK/tmp` 绕开；
用 systemd transient unit 启动时走真 XDG_RUNTIME_DIR（/run/user/1000）即可，
flatpak 命令需要 `XDG_DATA_HOME=~/.local/share/rander/environments/niri/dms`。

## 仓库布局

- `src/`（仓库根即 pot 源码树）：上游导入提交后跟修复提交。
- `pack/`：flatpak manifest 模板与 build.sh；`pack/deploy/` 收录 systemd user
  单元与全部宿主侧脚本（run-pot.sh、pot-grim-ocr.sh，路径按 `%h`/`%t`/`$HOME`
  归一，可直接部署到新机器）。
- `.work/`（已 gitignore）：sysroot、deb-cache、rust 工具链、target、repo。
