import { useEffect, useRef, useCallback } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import "@xterm/xterm/css/xterm.css";

interface TerminalViewProps {
  sessionId: string;
  onTerminated?: () => void;
}

export function TerminalView({ sessionId, onTerminated }: TerminalViewProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  const handleResize = useCallback(() => {
    if (fitAddonRef.current && xtermRef.current) {
      fitAddonRef.current.fit();
      invoke("terminal_resize", {
        sessionId,
        cols: xtermRef.current.cols,
        rows: xtermRef.current.rows,
      }).catch(console.error);
    }
  }, [sessionId]);

  useEffect(() => {
    if (!terminalRef.current) return;

    // Create terminal instance
    const terminal = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
      lineHeight: 1.2,
      theme: {
        background: "#0f172a",
        foreground: "#e2e8f0",
        cursor: "#60a5fa",
        cursorAccent: "#0f172a",
        selectionBackground: "#334155",
        black: "#1e293b",
        red: "#f87171",
        green: "#4ade80",
        yellow: "#facc15",
        blue: "#60a5fa",
        magenta: "#c084fc",
        cyan: "#22d3ee",
        white: "#f1f5f9",
        brightBlack: "#475569",
        brightRed: "#fca5a5",
        brightGreen: "#86efac",
        brightYellow: "#fde047",
        brightBlue: "#93c5fd",
        brightMagenta: "#d8b4fe",
        brightCyan: "#67e8f9",
        brightWhite: "#f8fafc",
      },
    });

    // Load addons
    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();
    terminal.loadAddon(fitAddon);
    terminal.loadAddon(webLinksAddon);

    // Open terminal in container
    terminal.open(terminalRef.current);
    fitAddon.fit();

    xtermRef.current = terminal;
    fitAddonRef.current = fitAddon;

    // Handle terminal input -> send to Rust backend
    const dataDisposable = terminal.onData((data) => {
      invoke("terminal_write", { sessionId, data }).catch(console.error);
    });

    // Listen for terminal output from Rust backend
    let outputUnlisten: UnlistenFn | null = null;
    listen<string>(`terminal-output-${sessionId}`, (event) => {
      terminal.write(event.payload);
    }).then((unlisten) => {
      outputUnlisten = unlisten;
    });

    // Listen for terminal close events
    let closeUnlisten: UnlistenFn | null = null;
    listen<void>(`terminal-closed-${sessionId}`, () => {
      onTerminated?.();
    }).then((unlisten) => {
      closeUnlisten = unlisten;
    });

    // Handle window resize
    const resizeObserver = new ResizeObserver(() => {
      handleResize();
    });
    resizeObserver.observe(terminalRef.current);

    // Focus terminal
    terminal.focus();

    return () => {
      dataDisposable.dispose();
      outputUnlisten?.();
      closeUnlisten?.();
      resizeObserver.disconnect();
      terminal.dispose();
    };
  }, [sessionId, handleResize, onTerminated]);

  return (
    <div
      ref={terminalRef}
      style={{
        width: "100%",
        height: "100%",
        backgroundColor: "#0f172a",
        borderRadius: "8px",
        overflow: "hidden",
      }}
    />
  );
}
