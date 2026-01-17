use crate::terminal::SessionManager;
use tauri::{AppHandle, State};

/// Create a new terminal session
#[tauri::command]
pub async fn create_terminal_session(
    app: AppHandle,
    manager: State<'_, SessionManager>,
    working_directory: String,
    command: String,
    args: Vec<String>,
) -> Result<String, String> {
    manager
        .create_session(app, &working_directory, &command, &args)
        .await
}

/// Write data to a terminal session
#[tauri::command]
pub async fn terminal_write(
    manager: State<'_, SessionManager>,
    session_id: String,
    data: String,
) -> Result<(), String> {
    manager.write(&session_id, data.as_bytes()).await
}

/// Resize a terminal session
#[tauri::command]
pub async fn terminal_resize(
    manager: State<'_, SessionManager>,
    session_id: String,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    manager.resize(&session_id, cols, rows).await
}

/// Close a terminal session
#[tauri::command]
pub async fn close_terminal_session(
    manager: State<'_, SessionManager>,
    session_id: String,
) -> Result<(), String> {
    manager.close(&session_id).await
}
