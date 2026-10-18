use crate::window::text_translate;
use log::{error, info};
use std::sync::Mutex;
use tauri::{ClipboardManager, Manager};

pub struct ClipboardMonitorEnableWrapper(pub Mutex<String>);

// flatpak 沙箱内 WAYLAND_DISPLAY 恒有（--socket=wayland），宿主 X11 会话则无
pub fn is_wayland() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some()
}

// 文本复制：Wayland 侧（data-control）与 X11 侧（arboard）双写，
// 沙箱内 Wayland 接口被过滤时自动落到 XWayland 剪贴板（配合宿主 xwayclip 桥）
pub fn copy_text(text: &str) -> Result<(), String> {
    let mut any_ok = false;
    let mut last_err = String::from("no clipboard backend available");

    if is_wayland() {
        use wl_clipboard_rs::copy::{MimeType, Options, ServeRequests, Source};
        let bytes: Box<[u8]> = text.as_bytes().to_vec().into_boxed_slice();
        let mut options = Options::new();
        // 8 次粘贴请求后自动释放，避免 serve 线程常驻泄漏
        options.serve_requests(ServeRequests::Only(8));
        match options.copy(Source::Bytes(bytes), MimeType::Text) {
            Ok(()) => {
                info!("Wayland clipboard set");
                any_ok = true;
            }
            Err(e) => {
                let msg = format!("wayland copy failed: {e}");
                error!("{}", msg);
                last_err = msg;
            }
        }
    }

    // X11 侧双写：XWayland 会话中保证 X11 应用也能直接粘贴
    match arboard::Clipboard::new().and_then(|mut c| c.set_text(text.to_string())) {
        Ok(()) => {
            info!("X11 clipboard set");
            any_ok = true;
        }
        Err(e) => {
            let msg = format!("x11 copy failed: {e}");
            error!("{}", msg);
            last_err = msg;
        }
    }

    if any_ok {
        Ok(())
    } else {
        Err(last_err)
    }
}

// 读取 primary selection（划词取词兜底：selection crate 依赖 XDG_SESSION_TYPE 分派，
// 沙箱内该变量可能指向 x11 而 XWayland primary 为空，此时直接走 Wayland 协议）
pub fn primary_text() -> Option<String> {
    use std::io::Read;
    use wl_clipboard_rs::paste::{get_contents, ClipboardType, MimeType, Seat};

    if !is_wayland() {
        return None;
    }
    match get_contents(ClipboardType::Primary, Seat::Unspecified, MimeType::Any) {
        Ok((mut reader, _mime)) => {
            let mut buf = String::new();
            match reader.read_to_string(&mut buf) {
                Ok(_) if !buf.trim().is_empty() => Some(buf),
                _ => None,
            }
        }
        Err(e) => {
            error!("wayland primary read failed: {e}");
            None
        }
    }
}

pub fn start_clipboard_monitor(app_handle: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut pre_text = "".to_string();
        loop {
            let handle = app_handle.app_handle();
            let state = handle.state::<ClipboardMonitorEnableWrapper>();
            if let Ok(clipboard_monitor) = state.0.try_lock() {
                if clipboard_monitor.contains("true") {
                    if let Ok(result) = app_handle.clipboard_manager().read_text() {
                        match result {
                            Some(v) => {
                                if v != pre_text {
                                    text_translate(v.clone());
                                    pre_text = v;
                                }
                            }
                            None => {}
                        }
                    }
                } else {
                    break;
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    });
}
