mod commands;
mod terminal;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            // Initialize terminal session manager
            app.manage(terminal::SessionManager::new());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::terminal::create_terminal_session,
            commands::terminal::terminal_write,
            commands::terminal::terminal_resize,
            commands::terminal::close_terminal_session,
            commands::notification::send_notification,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
