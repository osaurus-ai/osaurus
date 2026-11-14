#!/usr/bin/env bash
# Read-only probe of every remote MCP connector template URL.
#
# For each template it sends one unauthenticated `initialize` POST, then
# follows OAuth discovery (RFC 9728 protected-resource metadata, RFC 8414 /
# OIDC authorization-server metadata) and prints how Osaurus can connect:
#
#   NOAUTH   initialize succeeded without credentials and no protected-resource
#            metadata is published (servers that allow anonymous initialize
#            but publish metadata are classified by their OAuth support), and
#            an anonymous tools/call was not rejected with 401/403
#   CALLAUTH initialize and tools/list work anonymously, but tools/call
#            returns 401/403: the template must not be `.open`
#   ONETAP   OAuth with dynamic client registration (RFC 7591)
#   CIMD     OAuth with Client ID Metadata Documents only
#   MANUAL   OAuth discovered, but needs a developer-portal client_id
#   AUTH?    401/403 with no discoverable OAuth metadata (bearer/API key)
#   DEAD     anything else (404, 5xx, redirect, network error)
#
# `initialize` falls back from 2025-11-25 to 2025-06-18 and 2025-03-26 when a
# server rejects the newer version. For anonymous servers the probe opens a
# session and calls the first listed tool with `{}` arguments; argument errors
# are expected and fine, only an auth rejection matters.
#
# Nothing is written anywhere and no credentials are sent. Usage:
#
#   scripts/live-proof/probe-mcp-templates.sh            # all templates
#   scripts/live-proof/probe-mcp-templates.sh <url>...   # specific URLs
#
# Exit status is 1 when any template probes DEAD.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATES="$ROOT/Packages/OsaurusCore/Models/Configuration/MCPProviderTemplate.swift"

exec python3 - "$TEMPLATES" "$@" <<'PY'
import json, re, sys, urllib.error, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

templates_path, *urls = sys.argv[1:]
if urls:
    items = [("-", u) for u in urls]
else:
    source = open(templates_path).read()
    items = re.findall(r'id:\s*"([^"]+)",.*?url:\s*"([^"]*)"', source, re.S)
    items += re.findall(r'\.(?:oauth|manualOAuth|open)\(\s*"([^"]+)",\s*"[^"]*",\s*"([^"]+)"', source)
    items = list(dict.fromkeys((i, u) for i, u in items if u))

VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"]

def rpc(method, params=None, ident=1):
    message = {"jsonrpc": "2.0", "method": method}
    if ident is not None:
        message["id"] = ident
    if params is not None:
        message["params"] = params
    return json.dumps(message).encode()

def init_body(version):
    return rpc("initialize", {"protocolVersion": version, "capabilities": {},
                              "clientInfo": {"name": "osaurus-probe", "version": "1"}})

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

opener = urllib.request.build_opener(NoRedirect)

def request(url, body=None, extra=None):
    headers = {"Accept": "application/json, text/event-stream",
               "User-Agent": "Osaurus-MCP-Probe/1.0 (+https://osaurus.ai)"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    headers.update(extra or {})
    req = urllib.request.Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with opener.open(req, timeout=15) as resp:
            return resp.status, dict(resp.headers), resp.read(262144).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), ""
    except Exception as e:
        return None, {}, str(e)[:60]

def rpc_result(body):
    """JSON-RPC payload from a JSON or SSE response body."""
    for chunk in [body] + [l[5:].strip() for l in body.splitlines() if l.startswith("data:")]:
        try:
            value = json.loads(chunk)
        except ValueError:
            continue
        if isinstance(value, dict) and ("result" in value or "error" in value):
            return value
    return None

def initialize(url):
    """First accepted protocol version, falling back for older servers."""
    for version in VERSIONS:
        status, headers, body = request(url, init_body(version))
        if status == 400 and version != VERSIONS[-1]:
            continue
        payload = rpc_result(body) if status == 200 else None
        negotiated = ((payload or {}).get("result") or {}).get("protocolVersion", version)
        return status, headers, negotiated
    return status, headers, VERSIONS[-1]

def anonymous_call_status(url, headers, version):
    """HTTP status of an anonymous tools/call on the first listed tool, or None."""
    lower = {k.lower(): v for k, v in headers.items()}
    session = {"MCP-Protocol-Version": version}
    if lower.get("mcp-session-id"):
        session["Mcp-Session-Id"] = lower["mcp-session-id"]
    request(url, rpc("notifications/initialized", ident=None), session)
    status, _, body = request(url, rpc("tools/list", {}, 2), session)
    if status in (401, 403):
        return status, "tools/list"
    tools = (((rpc_result(body) or {}).get("result") or {}).get("tools") or [])
    if not tools:
        return None, "no tools"
    name = tools[0].get("name", "")
    status, _, _ = request(url, rpc("tools/call", {"name": name, "arguments": {}}, 3), session)
    return status, name

def get_json(url):
    status, _, body = request(url)
    if status != 200:
        return None
    try:
        value = json.loads(body)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None

def well_known(base, name):
    p = urllib.parse.urlparse(base)
    path = p.path.rstrip("/")
    origin = f"{p.scheme}://{p.netloc}"
    candidates = [f"{origin}/.well-known/{name}{path}", f"{origin}/.well-known/{name}"]
    if name == "openid-configuration" and path:
        candidates.append(f"{origin}{path}/.well-known/{name}")
    return candidates

def probe(item):
    ident, url = item
    status, headers, version = initialize(url)
    www = {k.lower(): v for k, v in headers.items()}.get("www-authenticate", "")
    hinted = re.search(r'resource_metadata="([^"]+)"', www)
    prm = None
    for candidate in ([hinted.group(1)] if hinted else []) + well_known(url, "oauth-protected-resource"):
        prm = get_json(candidate)
        if prm:
            break
    if prm:
        issuer = (prm.get("authorization_servers") or [None])[0]
    elif not hinted:
        # MCP 2025-03-26 servers: no PRM, authorization server is the origin.
        p = urllib.parse.urlparse(url)
        issuer = f"{p.scheme}://{p.netloc}"
    else:
        issuer = None
    asm = None
    if issuer:
        for candidate in well_known(issuer, "oauth-authorization-server") + well_known(issuer, "openid-configuration"):
            asm = get_json(candidate)
            if asm:
                break
    dcr = bool(asm and asm.get("registration_endpoint"))
    cimd = bool(asm and asm.get("client_id_metadata_document_supported"))
    call = ""
    if status == 200 and not prm:
        call_status, tool = anonymous_call_status(url, headers, version)
        call = f" call={call_status}:{tool}"
        kind = "CALLAUTH" if call_status in (401, 403) else "NOAUTH"
    elif status not in (200, 401, 403):
        kind = "DEAD"
    elif dcr:
        kind = "ONETAP"
    elif cimd:
        kind = "CIMD"
    elif asm:
        kind = "MANUAL"
    else:
        kind = "AUTH?"
    detail = (f"prm={'Y' if prm else '-'} asm={'Y' if asm else '-'} dcr={'Y' if dcr else '-'} "
              f"cimd={'Y' if cimd else '-'} v={version}{call}")
    return kind, f"{kind:8} {str(status):5} {detail}  {ident:24} {url}"

with ThreadPoolExecutor(max_workers=12) as pool:
    results = list(pool.map(probe, items))

for _, line in results:
    print(line)
dead = [line for kind, line in results if kind == "DEAD"]
print(f"\n{len(results)} probed, {len(dead)} dead")
sys.exit(1 if dead else 0)
PY
