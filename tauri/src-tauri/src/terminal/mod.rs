//! Terminal session management using portable-pty for cross-platform PTY support.

use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use tauri::{AppHandle, Emitter};
use tokio::sync::RwLock;

/// A single terminal session wrapping a PTY
pub struct TerminalSession {
    pub id: String,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
}

impl TerminalSession {
    /// Write data to the terminal
    pub fn write(&self, data: &[u8]) -> Result<(), String> {
        let mut writer = self.writer.lock().map_err(|e| e.to_string())?;
        writer
            .write_all(data)
            .map_err(|e| format!("Failed to write: {}", e))?;
        writer.flush().map_err(|e| format!("Failed to flush: {}", e))
    }

    /// Resize the terminal
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), String> {
        let master = self.master.lock().map_err(|e| e.to_string())?;
        master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("Failed to resize: {}", e))
    }
}

/// Manages multiple terminal sessions
pub struct SessionManager {
    sessions: RwLock<HashMap<String, Arc<TerminalSession>>>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            sessions: RwLock::new(HashMap::new()),
        }
    }

    /// Create a new terminal session and start streaming output
    pub async fn create_session(
        &self,
        app: AppHandle,
        working_directory: &str,
        command: &str,
        args: &[String],
    ) -> Result<String, String> {
        let pty_system = native_pty_system();

        let pair = pty_system
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("Failed to open PTY: {}", e))?;

        let mut cmd = CommandBuilder::new(command);
        for arg in args {
            cmd.arg(arg);
        }
        cmd.cwd(working_directory);

        // Set terminal environment variables
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("LANG", "en_US.UTF-8");

        let _child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("Failed to spawn command: {}", e))?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("Failed to get writer: {}", e))?;

        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("Failed to get reader: {}", e))?;

        let id = uuid::Uuid::new_v4().to_string();

        let session = Arc::new(TerminalSession {
            id: id.clone(),
            writer: Arc::new(Mutex::new(writer)),
            master: Arc::new(Mutex::new(pair.master)),
        });

        // Store session
        {
            let mut sessions = self.sessions.write().await;
            sessions.insert(id.clone(), session);
        }

        // Start output streaming thread
        let session_id = id.clone();
        let app_handle = app.clone();
        thread::spawn(move || {
            Self::stream_output(reader, session_id, app_handle);
        });

        Ok(id)
    }

    /// Stream PTY output to the frontend
    fn stream_output(
        mut reader: Box<dyn Read + Send>,
        session_id: String,
        app: AppHandle,
    ) {
        let mut buffer = [0u8; 4096];
        let event_name = format!("terminal-output-{}", session_id);

        loop {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    // EOF - process terminated
                    let _ = app.emit(&format!("terminal-closed-{}", session_id), ());
                    break;
                }
                Ok(n) => {
                    // Convert to string (lossy for invalid UTF-8)
                    let output = String::from_utf8_lossy(&buffer[..n]).to_string();
                    let _ = app.emit(&event_name, output);
                }
                Err(e) => {
                    eprintln!("Error reading PTY: {}", e);
                    let _ = app.emit(&format!("terminal-closed-{}", session_id), ());
                    break;
                }
            }
        }
    }

    /// Write to a terminal session
    pub async fn write(&self, session_id: &str, data: &[u8]) -> Result<(), String> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| "Session not found".to_string())?;
        session.write(data)
    }

    /// Resize a terminal session
    pub async fn resize(&self, session_id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| "Session not found".to_string())?;
        session.resize(cols, rows)
    }

    /// Close a terminal session
    pub async fn close(&self, session_id: &str) -> Result<(), String> {
        let mut sessions = self.sessions.write().await;
        sessions
            .remove(session_id)
            .ok_or_else(|| "Session not found".to_string())?;
        Ok(())
    }
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}
