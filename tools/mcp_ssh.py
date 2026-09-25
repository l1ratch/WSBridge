#!/usr/bin/env python3
"""Минимальный MCP stdio-сервер: один инструмент ssh_exec -> `ssh <alias> <cmd>`.
Ноль зависимостей (только stdlib + системный ssh с ~/.ssh config).
Алиас хоста — первый аргумент командной строки (дефолт myvds).
Протокол: newline-delimited JSON-RPC 2.0 по stdin/stdout.
"""
import json
import subprocess
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "myvds"

TOOLS = [{
    "name": "ssh_exec",
    "description": (
        f"Run a shell command on the remote host '{HOST}' over ssh "
        "(uses the caller's ~/.ssh config: keys, port, user). "
        "Returns combined stdout+stderr and the exit code."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "command": {"type": "string", "description": "Shell command to run remotely"},
            "timeout": {"type": "number", "description": "Seconds before kill (default 60)"},
        },
        "required": ["command"],
        "additionalProperties": False,
    },
}]


def respond(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        rid = req.get("id")
        method = req.get("method")
        if rid is None:  # notification (initialized и т.п.)
            continue
        if method == "initialize":
            respond({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": req.get("params", {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": f"ssh-{HOST}", "version": "1.0"},
            }})
        elif method == "tools/list":
            respond({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            args = req.get("params", {}).get("arguments", {}) or {}
            cmd = args.get("command", "")
            timeout = float(args.get("timeout", 60))
            try:
                p = subprocess.run(
                    ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, cmd],
                    capture_output=True, text=True, timeout=timeout,
                )
                text = p.stdout or ""
                if p.stderr:
                    text += "\n[stderr]\n" + p.stderr
                text += f"\n[exit {p.returncode}]"
                err = p.returncode != 0
            except Exception as e:  # timeout, ssh not found и т.п.
                text, err = f"ssh failed: {e}", True
            respond({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": text or "(empty output)"}],
                "isError": err,
            }})
        elif method == "ping":
            respond({"jsonrpc": "2.0", "id": rid, "result": {}})
        else:
            respond({"jsonrpc": "2.0", "id": rid,
                     "error": {"code": -32601, "message": f"unknown method {method}"}})


main()
