#!/usr/bin/env python3
"""
osaurus-host — VM shim for Osaurus Host API

CLI that runs inside agent VMs. Translates subcommands into JSON-RPC
calls over vsock to the Osaurus runtime on the host.

Usage:
  osaurus-host secrets get <name>
  osaurus-host config get|set <key> [value]
  osaurus-host log info|warn|error <message>
  osaurus-host inference chat              (reads JSON from stdin)
  osaurus-host agent dispatch <agent> <task>
  osaurus-host agent memory query <query>
  osaurus-host agent memory store <content>
  osaurus-host events emit <type> [payload]
  osaurus-host plugin create               (reads JSON from stdin)
  osaurus-host plugin list
  osaurus-host plugin remove <name>
  osaurus-host identity address
  osaurus-host identity sign <data_hex>
  osaurus-host mcp relay <plugin-name>     (reads JSON-RPC from stdin)
"""

import json
import os
import socket
import struct
import subprocess
import sys

HOST_CID = 2
HOST_PORT = 5001


class VsockClient:
    def __init__(self):
        self._sock = None
        self._next_id = 1

    def connect(self):
        self._sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        self._sock.connect((HOST_CID, HOST_PORT))

    def disconnect(self):
        if self._sock:
            self._sock.close()
            self._sock = None

    def call(self, method, params=None):
        if params is None:
            params = {}
        req_id = self._next_id
        self._next_id += 1
        request = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
        self._send_frame(json.dumps(request).encode())
        data = self._recv_frame()
        resp = json.loads(data)
        if "error" in resp:
            msg = resp["error"].get("message", "Unknown error")
            print(f"RPC error: {msg}", file=sys.stderr)
            sys.exit(1)
        return resp.get("result", {})

    def _send_frame(self, data):
        length = struct.pack(">I", len(data))
        self._sock.sendall(length + data)

    def _recv_frame(self):
        length_bytes = self._recv_exact(4)
        length = struct.unpack(">I", length_bytes)[0]
        return self._recv_exact(length)

    def _recv_exact(self, count):
        buf = b""
        while len(buf) < count:
            chunk = self._sock.recv(count - len(buf))
            if not chunk:
                raise ConnectionError("Connection closed while reading")
            buf += chunk
        return buf


def plugin_name():
    return os.environ.get("OSAURUS_PLUGIN", "unknown")


def handle_secrets(args, client):
    if len(args) < 2 or args[0] != "get":
        die("Usage: osaurus-host secrets get <name>")
    result = client.call("secrets.get", {"name": args[1], "plugin": plugin_name()})
    if result.get("value"):
        print(result["value"])


def handle_config(args, client):
    if not args:
        die("Usage: osaurus-host config get|set <key> [value]")
    pname = plugin_name()
    if args[0] == "get":
        if len(args) < 2:
            die("config get <key>")
        result = client.call("config.get", {"key": args[1], "plugin": pname})
        if result.get("value"):
            print(result["value"])
    elif args[0] == "set":
        if len(args) < 3:
            die("config set <key> <value>")
        client.call("config.set", {"key": args[1], "value": args[2], "plugin": pname})
    else:
        die("config get|set")


def handle_log(args, client):
    if len(args) < 2:
        die("log info|warn|error <message>")
    level = args[0]
    message = " ".join(args[1:])
    client.call("log", {"level": level, "message": message})


def handle_inference(args, client):
    if not args or args[0] != "chat":
        die("inference chat")
    data = sys.stdin.buffer.read()
    params = json.loads(data)
    result = client.call("inference.chat", params)
    print(json.dumps(result, indent=2))


def handle_agent(args, client):
    if not args:
        die("agent dispatch|memory")
    if args[0] == "dispatch":
        if len(args) < 3:
            die("agent dispatch <agent> <task>")
        result = client.call("agent.dispatch", {"agent": args[1], "task": args[2]})
        print(json.dumps(result, indent=2))
    elif args[0] == "memory":
        if len(args) < 2:
            die("agent memory query|store")
        if args[1] == "query":
            if len(args) < 3:
                die("agent memory query <query>")
            result = client.call("memory.query", {"query": args[2]})
            print(json.dumps(result, indent=2))
        elif args[1] == "store":
            if len(args) < 3:
                die("agent memory store <content>")
            result = client.call("memory.store", {"content": args[2]})
            print(json.dumps(result, indent=2))
        else:
            die("agent memory query|store")
    else:
        die("agent dispatch|memory")


def handle_events(args, client):
    if not args:
        die("events emit <type> [payload]")
    if args[0] == "emit":
        if len(args) < 2:
            die("events emit <type> [payload]")
        payload = args[2] if len(args) >= 3 else "{}"
        client.call("events.emit", {"event_type": args[1], "payload": payload})
    else:
        die("events emit")


def handle_plugin(args, client):
    if not args:
        die("plugin create|list|remove")
    if args[0] == "create":
        data = sys.stdin.buffer.read()
        plugin_json = json.loads(data)
        result = client.call("plugin.create", {"plugin": plugin_json})
        print(json.dumps(result, indent=2))
    elif args[0] == "list":
        result = client.call("plugin.list")
        print(json.dumps(result, indent=2))
    elif args[0] == "remove":
        if len(args) < 2:
            die("plugin remove <name>")
        result = client.call("plugin.remove", {"name": args[1]})
        print(json.dumps(result, indent=2))
    else:
        die("plugin create|list|remove")


def handle_identity(args, client):
    if not args:
        die("identity address|sign")
    if args[0] == "address":
        result = client.call("identity.address")
        if result.get("address"):
            print(result["address"])
    elif args[0] == "sign":
        if len(args) < 2:
            die("identity sign <data_hex>")
        result = client.call("identity.sign", {"data": args[1]})
        print(json.dumps(result, indent=2))
    else:
        die("identity address|sign")


def handle_mcp(args):
    if len(args) < 2 or args[0] != "relay":
        die("Usage: osaurus-host mcp relay <plugin-name>")
    plugin = args[1]

    stdin_data = sys.stdin.buffer.read()
    if not stdin_data:
        die("Expected JSON-RPC request on stdin")

    mcp_command = os.environ.get("MCP_COMMAND", "")
    if not mcp_command:
        die(f"MCP_COMMAND env var not set for plugin {plugin}")

    cwd = f"/workspace/plugins/{plugin}"
    result = subprocess.run(
        ["/bin/sh", "-c", mcp_command],
        input=stdin_data,
        capture_output=True,
        cwd=cwd,
    )
    sys.stdout.buffer.write(result.stdout)
    if result.stderr:
        sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)


def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(1)

    command = args[0]
    rest = args[1:]

    if command == "mcp":
        handle_mcp(rest)
        return

    client = VsockClient()
    try:
        client.connect()
    except Exception as e:
        die(f"Failed to connect to host: {e}")

    try:
        handlers = {
            "secrets": handle_secrets,
            "config": handle_config,
            "log": handle_log,
            "inference": handle_inference,
            "agent": handle_agent,
            "events": handle_events,
            "plugin": handle_plugin,
            "identity": handle_identity,
        }
        handler = handlers.get(command)
        if handler is None:
            die(f"Unknown command: {command}")
        handler(rest, client)
    finally:
        client.disconnect()


if __name__ == "__main__":
    main()
