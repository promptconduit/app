import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { TerminalView } from "./components/Terminal/TerminalView";

function App() {
  const [workingDirectory, setWorkingDirectory] = useState(
    process.env.HOME || "/Users"
  );
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLaunching, setIsLaunching] = useState(false);

  async function launchTerminal() {
    if (!workingDirectory) return;

    setIsLaunching(true);
    setError(null);

    try {
      const id = await invoke<string>("create_terminal_session", {
        workingDirectory,
        command: "claude",
        args: [] as string[],
      });
      setSessionId(id);
    } catch (err) {
      console.error("Failed to create terminal session:", err);
      setError(String(err));
    } finally {
      setIsLaunching(false);
    }
  }

  function handleTerminated() {
    setSessionId(null);
  }

  async function closeSession() {
    if (sessionId) {
      try {
        await invoke("close_terminal_session", { sessionId });
      } catch (err) {
        console.error("Failed to close session:", err);
      }
      setSessionId(null);
    }
  }

  // If we have a session, show the terminal full screen
  if (sessionId) {
    return (
      <div
        style={{
          width: "100vw",
          height: "100vh",
          display: "flex",
          flexDirection: "column",
          backgroundColor: "#0f172a",
        }}
      >
        {/* Header */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: "8px 16px",
            backgroundColor: "#1e293b",
            borderBottom: "1px solid #334155",
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: "12px" }}>
            <span style={{ color: "#60a5fa", fontWeight: 600 }}>
              Claude Code
            </span>
            <span style={{ color: "#64748b", fontSize: "12px" }}>
              {workingDirectory}
            </span>
          </div>
          <button
            onClick={closeSession}
            style={{
              padding: "4px 12px",
              backgroundColor: "#dc2626",
              color: "white",
              border: "none",
              borderRadius: "4px",
              cursor: "pointer",
              fontSize: "12px",
            }}
          >
            Close
          </button>
        </div>

        {/* Terminal */}
        <div style={{ flex: 1, padding: "8px" }}>
          <TerminalView sessionId={sessionId} onTerminated={handleTerminated} />
        </div>
      </div>
    );
  }

  // Show launcher
  return (
    <main
      style={{
        width: "100vw",
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        backgroundColor: "#0f172a",
        color: "#e2e8f0",
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
      }}
    >
      <h1 style={{ fontSize: "2rem", marginBottom: "0.5rem", color: "#60a5fa" }}>
        PromptConduit
      </h1>
      <p style={{ color: "#94a3b8", marginBottom: "2rem" }}>
        Cross-platform terminal for Claude Code
      </p>

      <div
        style={{
          display: "flex",
          flexDirection: "column",
          gap: "1rem",
          width: "100%",
          maxWidth: "500px",
          padding: "0 1rem",
        }}
      >
        <div>
          <label
            style={{
              display: "block",
              marginBottom: "0.5rem",
              color: "#94a3b8",
              fontSize: "0.875rem",
            }}
          >
            Working Directory
          </label>
          <input
            type="text"
            placeholder="/path/to/project"
            value={workingDirectory}
            onChange={(e) => setWorkingDirectory(e.target.value)}
            style={{
              width: "100%",
              padding: "0.75rem 1rem",
              border: "1px solid #334155",
              borderRadius: "8px",
              backgroundColor: "#1e293b",
              color: "#e2e8f0",
              fontSize: "1rem",
              outline: "none",
            }}
          />
        </div>

        {error && (
          <div
            style={{
              padding: "0.75rem 1rem",
              backgroundColor: "#7f1d1d",
              borderRadius: "8px",
              color: "#fca5a5",
              fontSize: "0.875rem",
            }}
          >
            {error}
          </div>
        )}

        <button
          onClick={launchTerminal}
          disabled={!workingDirectory || isLaunching}
          style={{
            padding: "0.75rem 1.5rem",
            background: "linear-gradient(135deg, #3b82f6, #2563eb)",
            color: "white",
            border: "none",
            borderRadius: "8px",
            cursor: workingDirectory && !isLaunching ? "pointer" : "not-allowed",
            fontSize: "1rem",
            fontWeight: 600,
            opacity: workingDirectory && !isLaunching ? 1 : 0.5,
            transition: "opacity 0.2s",
          }}
        >
          {isLaunching ? "Launching..." : "Launch Claude Code"}
        </button>
      </div>

      <p
        style={{
          marginTop: "2rem",
          color: "#64748b",
          fontSize: "0.75rem",
        }}
      >
        Powered by Tauri + xterm.js
      </p>
    </main>
  );
}

export default App;
