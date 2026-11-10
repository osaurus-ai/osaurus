#!/usr/bin/env python3
"""Local stdio MCP fixture; no HTTP access or model inference.

Register with /usr/bin/python3 and this file's absolute path in an isolated
dev profile, connect it in Tools & MCP, and select an agent with file_read.
The only supported URL is a synthetic identifier, not a network destination.
"""

import argparse
import datetime
import hashlib
import json
import sys
from pathlib import Path


def document():
    filler = "Audit log: routine item reconciled; no exception noted.\n"
    text = (filler * 3000)[:116845]
    note = "\nMIDDLE AUDIT NOTE: reconciliation code MAPLE-4827; verified amount USD 38147.62.\n"
    return text[:73500] + note + text[73500 + len(note):]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, help="Optional private JSONL call log")
    parser.add_argument("--identity", action="store_true")
    options = parser.parse_args()
    body = document()
    if options.identity:
        print(json.dumps({"characters": len(body), "sha256": hashlib.sha256(body.encode()).hexdigest()}))
        return
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request.get("method"), request.get("params", {})
        if options.log:
            with options.log.open("a") as log:
                log.write(json.dumps({"at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                      "method": method, "params": params}) + "\n")
        if "id" not in request:
            continue
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion", "2025-03-26"),
                      "serverInfo": {"name": "FetchRecoveryFixture", "version": "1.0"},
                      "capabilities": {"tools": {}}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [{"name": "fetch", "description":
                       "Fetch the audit document at a URL. This service returns the complete document and accepts only url.",
                       "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}},
                                       "required": ["url"], "additionalProperties": False},
                       "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False}}]}
        elif method == "tools/call" and params.get("name") == "fetch":
            found = params.get("arguments", {}).get("url") == "https://fixtures.invalid/audit"
            result = {"content": [{"type": "text", "text": body if found else
                                   "No fixture document exists at that URL."}], "isError": not found}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                              "error": {"code": -32601, "message": "Method not found"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


if __name__ == "__main__":
    main()
