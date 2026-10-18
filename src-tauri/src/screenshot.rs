use log::info;

#[tauri::command]
pub fn screenshot(x: i32, y: i32) {
    use crate::APP;
    use dirs::cache_dir;
    use std::fs;
    use std::process::Command;
    let _ = (x, y);
    info!("Screenshot screen with position: x={}, y={}", x, y);
    let handle = APP.get().unwrap();
    let mut app_cache_dir_path = cache_dir().expect("Get Cache Dir Failed");
    app_cache_dir_path.push(&handle.config().tauri.bundle.identifier);
    if !app_cache_dir_path.exists() {
        // 创建目录
        fs::create_dir_all(&app_cache_dir_path).expect("Create Cache Dir Failed");
    }
    app_cache_dir_path.push("pot_screenshot.png");

    // 抓屏走 grim（zwlr_screencopy 协议，沙箱内经 relay 直连 niri）。
    // screenshots crate 的 X11 root 抓取在 XWayland 下恒为空图，不可用。
    let output = Command::new("grim")
        .arg("-t")
        .arg("png")
        .arg(app_cache_dir_path.as_os_str())
        .output()
        .expect("Run grim Failed");
    if !output.status.success() {
        panic!("grim failed: {}", String::from_utf8_lossy(&output.stderr));
    }
    info!("Screenshot saved to {:?}", app_cache_dir_path);
}
