import Foundation
import Testing

@testable import OsaurusCore

/// These tests boot an Apple Containerization Linux VM and run real
/// `pip install`, `npm`, and `go test` workloads inside the sandbox. They
/// take minutes and require Containerization tooling, so they are gated by
/// `OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS=1` and reported as `Disabled`
/// in CI rather than silently passing.
private let isSandboxIntegrationEnabled =
    ProcessInfo.processInfo.environment["OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS"] == "1"

@Suite(
    .serialized,
    .disabled(
        if: !isSandboxIntegrationEnabled,
        "Set OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS=1 to run; requires Apple Containerization."
    )
)
struct SandboxIntegrationTests {
    @Test
    func provisionedAgent_canExecAsSandboxUser() async throws {
        // Even with the env var set, the host may not actually have Apple
        // Containerization available (e.g., dev workstation without the
        // toolchain). Skip the body in that case to keep `make ci-test` runs
        // green for everyone who opts in.
        guard await sandboxAvailable() else { return }

        let agentId = UUID()
        defer {
            Task {
                _ = await SandboxAgentProvisioner.shared.unprovision(agentId: agentId)
            }
        }

        try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)

        let agentName = await MainActor.run {
            SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
        }
        let result = try await SandboxManager.shared.execAsAgent(agentName, command: "echo hello")

        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(SandboxAgentMap.resolve(linuxName: "agent-\(agentName)") == agentId)
    }

    @Test @MainActor
    func sandboxExecTool_runsThroughRegistryForProvisionedAgent() async throws {
        guard await sandboxAvailable() else { return }

        try await SandboxTestLock.shared.run {
            let agentId = UUID()
            let agentName = SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
            defer {
                ToolRegistry.shared.unregisterAllSandboxTools()
                Task {
                    _ = await SandboxAgentProvisioner.shared.unprovision(agentId: agentId)
                }
            }

            try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
            BuiltinSandboxTools.register(
                agentId: agentId.uuidString,
                agentName: agentName,
                config: AutonomousExecConfig(
                    enabled: true,
                    maxCommandsPerTurn: 10,
                    commandTimeout: 30,
                    pluginCreate: true
                )
            )

            let output = try await ToolRegistry.shared.execute(
                name: "sandbox_exec",
                argumentsJSON: #"{"command":"echo hello-from-tool"}"#
            )
            let payload = try #require(try parseIntegrationJSON(output))

            #expect(payload["exit_code"] as? Int == 0)
            #expect((payload["stdout"] as? String)?.contains("hello-from-tool") == true)
        }
    }

    @Test @MainActor
    func pythonFlaskScenario_installsWritesAndPassesTests() async throws {
        guard await sandboxAvailable() else { return }

        try await withProvisionedSandboxTools {
            let pipPayload = try await executeSandboxTool(
                "sandbox_pip_install",
                arguments: ["packages": ["flask", "pytest"]]
            )
            #expect(pipPayload["exit_code"] as? Int == 0)

            let script = pythonFlaskScenarioScript()

            let scriptPayload = try await executeSandboxTool(
                "sandbox_run_script",
                arguments: ["language": "python", "script": script]
            )
            #expect(scriptPayload["exit_code"] as? Int == 0)

            let testPayload = try await executeSandboxTool(
                "sandbox_exec",
                arguments: ["command": "pytest test_app.py -q"]
            )
            #expect(testPayload["exit_code"] as? Int == 0)
            #expect((testPayload["stdout"] as? String)?.contains("1 passed") == true)
        }
    }

    @Test @MainActor
    func nodeScenario_installsToolchainWritesAndPassesTests() async throws {
        guard await sandboxAvailable() else { return }

        try await withProvisionedSandboxTools {
            let installPayload = try await executeSandboxTool(
                "sandbox_install",
                arguments: ["packages": ["nodejs", "npm"]]
            )
            #expect(installPayload["exit_code"] as? Int == 0)

            let script = nodeScenarioScript()

            let scriptPayload = try await executeSandboxTool(
                "sandbox_run_script",
                arguments: ["language": "node", "script": script]
            )
            #expect(scriptPayload["exit_code"] as? Int == 0)

            let testPayload = try await executeSandboxTool(
                "sandbox_exec",
                arguments: ["command": "node --test server.test.js"]
            )
            #expect(testPayload["exit_code"] as? Int == 0)
            #expect((testPayload["stdout"] as? String)?.contains("# pass 1") == true)
        }
    }

    @Test @MainActor
    func goScenario_installsToolchainWritesAndPassesTests() async throws {
        guard await sandboxAvailable() else { return }

        try await withProvisionedSandboxTools {
            let installPayload = try await executeSandboxTool(
                "sandbox_install",
                arguments: ["packages": ["go"]]
            )
            #expect(installPayload["exit_code"] as? Int == 0)

            let script = goScenarioScript()

            let scriptPayload = try await executeSandboxTool(
                "sandbox_run_script",
                arguments: ["language": "bash", "script": script]
            )
            #expect(scriptPayload["exit_code"] as? Int == 0)

            let testPayload = try await executeSandboxTool(
                "sandbox_exec",
                arguments: ["command": "go test ./..."]
            )
            #expect(testPayload["exit_code"] as? Int == 0)
            #expect((testPayload["stdout"] as? String)?.contains("ok") == true)
        }
    }

    private func sandboxAvailable() async -> Bool {
        (await SandboxManager.shared.refreshAvailability()).isAvailable
    }
}

private func parseIntegrationJSON(_ string: String) throws -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@MainActor
private func withProvisionedSandboxTools<T: Sendable>(
    _ body: () async throws -> T
) async throws -> T {
    try await SandboxTestLock.shared.run {
        let agentId = UUID()
        let agentName = SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
        defer {
            ToolRegistry.shared.unregisterAllSandboxTools()
            Task {
                _ = await SandboxAgentProvisioner.shared.unprovision(agentId: agentId)
            }
        }

        try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
        BuiltinSandboxTools.register(
            agentId: agentId.uuidString,
            agentName: agentName,
            config: AutonomousExecConfig(enabled: true, maxCommandsPerTurn: 50, commandTimeout: 120, pluginCreate: true)
        )

        return try await body()
    }
}

@MainActor
private func executeSandboxTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    guard let argumentsJSON = String(data: data, encoding: .utf8) else {
        throw NSError(
            domain: "SandboxIntegrationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to encode arguments"]
        )
    }
    let output = try await ToolRegistry.shared.execute(name: name, argumentsJSON: argumentsJSON)
    guard let parsed = try parseIntegrationJSON(output) else {
        throw NSError(
            domain: "SandboxIntegrationTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse tool output"]
        )
    }
    return parsed
}

private func pythonFlaskScenarioScript() -> String {
    [
        "from pathlib import Path",
        "",
        "Path(\"app.py\").write_text('''from flask import Flask, jsonify, request",
        "",
        "app = Flask(__name__)",
        "users = {}",
        "",
        "@app.get(\"/health\")",
        "def health():",
        "    return jsonify({\"status\": \"ok\"})",
        "",
        "@app.post(\"/users\")",
        "def create_user():",
        "    data = request.get_json(force=True)",
        "    user_id = str(len(users) + 1)",
        "    user = {\"id\": user_id, \"name\": data[\"name\"]}",
        "    users[user_id] = user",
        "    return jsonify(user), 201",
        "",
        "@app.get(\"/users/<user_id>\")",
        "def get_user(user_id):",
        "    user = users.get(user_id)",
        "    if user is None:",
        "        return jsonify({\"error\": \"not found\"}), 404",
        "    return jsonify(user)",
        "''')",
        "",
        "Path(\"test_app.py\").write_text('''from app import app",
        "",
        "def test_api_flow():",
        "    client = app.test_client()",
        "",
        "    health = client.get(\"/health\")",
        "    assert health.status_code == 200",
        "    assert health.get_json() == {\"status\": \"ok\"}",
        "",
        "    created = client.post(\"/users\", json={\"name\": \"Ada\"})",
        "    assert created.status_code == 201",
        "    created_user = created.get_json()",
        "    assert created_user[\"name\"] == \"Ada\"",
        "",
        "    fetched = client.get(f\"/users/{created_user['id']}\")",
        "    assert fetched.status_code == 200",
        "    assert fetched.get_json() == created_user",
        "''')",
    ].joined(separator: "\n")
}

private func nodeScenarioScript() -> String {
    [
        "const fs = require(\"node:fs\");",
        "",
        "fs.writeFileSync(\"server.js\", `const http = require(\"node:http\");",
        "",
        "function createServer() {",
        "  const users = new Map();",
        "",
        "  return http.createServer((req, res) => {",
        "    const url = new URL(req.url, \"http://127.0.0.1\");",
        "",
        "    if (req.method === \"GET\" && url.pathname === \"/health\") {",
        "      res.writeHead(200, { \"Content-Type\": \"application/json\" });",
        "      res.end(JSON.stringify({ status: \"ok\" }));",
        "      return;",
        "    }",
        "",
        "    if (req.method === \"POST\" && url.pathname === \"/users\") {",
        "      let body = \"\";",
        "      req.on(\"data\", chunk => { body += chunk; });",
        "      req.on(\"end\", () => {",
        "        const payload = JSON.parse(body || \"{}\");",
        "        const id = String(users.size + 1);",
        "        const user = { id, name: payload.name };",
        "        users.set(id, user);",
        "        res.writeHead(201, { \"Content-Type\": \"application/json\" });",
        "        res.end(JSON.stringify(user));",
        "      });",
        "      return;",
        "    }",
        "",
        "    const match = url.pathname.match(/^\\\\/users\\\\/(.+)$/);",
        "    if (req.method === \"GET\" && match) {",
        "      const user = users.get(match[1]);",
        "      if (!user) {",
        "        res.writeHead(404, { \"Content-Type\": \"application/json\" });",
        "        res.end(JSON.stringify({ error: \"not found\" }));",
        "        return;",
        "      }",
        "      res.writeHead(200, { \"Content-Type\": \"application/json\" });",
        "      res.end(JSON.stringify(user));",
        "      return;",
        "    }",
        "",
        "    res.writeHead(404, { \"Content-Type\": \"application/json\" });",
        "    res.end(JSON.stringify({ error: \"not found\" }));",
        "  });",
        "}",
        "",
        "module.exports = { createServer };",
        "`);",
        "",
        "fs.writeFileSync(\"server.test.js\", `const test = require(\"node:test\");",
        "const assert = require(\"node:assert/strict\");",
        "const http = require(\"node:http\");",
        "const { createServer } = require(\"./server\");",
        "",
        "function request(server, method, path, body) {",
        "  return new Promise((resolve, reject) => {",
        "    const address = server.address();",
        "    const payload = body ? JSON.stringify(body) : null;",
        "    const req = http.request({",
        "      host: \"127.0.0.1\",",
        "      port: address.port,",
        "      path,",
        "      method,",
        "      headers: payload ? {",
        "        \"Content-Type\": \"application/json\",",
        "        \"Content-Length\": Buffer.byteLength(payload),",
        "      } : undefined,",
        "    }, res => {",
        "      let data = \"\";",
        "      res.on(\"data\", chunk => { data += chunk; });",
        "      res.on(\"end\", () => resolve({ statusCode: res.statusCode, json: JSON.parse(data) }));",
        "    });",
        "    req.on(\"error\", reject);",
        "    if (payload) req.write(payload);",
        "    req.end();",
        "  });",
        "}",
        "",
        "test(\"api flow\", async () => {",
        "  const server = createServer();",
        "  await new Promise(resolve => server.listen(0, resolve));",
        "",
        "  try {",
        "    const health = await request(server, \"GET\", \"/health\");",
        "    assert.equal(health.statusCode, 200);",
        "    assert.deepEqual(health.json, { status: \"ok\" });",
        "",
        "    const created = await request(server, \"POST\", \"/users\", { name: \"Ada\" });",
        "    assert.equal(created.statusCode, 201);",
        "    assert.equal(created.json.name, \"Ada\");",
        "",
        "    const fetched = await request(server, \"GET\", \"/users/\" + created.json.id);",
        "    assert.equal(fetched.statusCode, 200);",
        "    assert.deepEqual(fetched.json, created.json);",
        "  } finally {",
        "    server.close();",
        "  }",
        "});",
        "`);",
    ].joined(separator: "\n")
}

private func goScenarioScript() -> String {
    [
        "cat > go.mod <<'EOF'",
        "module example.com/sandboxapp",
        "",
        "go 1.22",
        "EOF",
        "",
        "cat > server.go <<'EOF'",
        "package sandboxapp",
        "",
        "import (",
        "  \"encoding/json\"",
        "  \"net/http\"",
        ")",
        "",
        "func NewHandler() http.Handler {",
        "  users := map[string]map[string]string{}",
        "",
        "  return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {",
        "    switch {",
        "    case r.Method == http.MethodGet && r.URL.Path == \"/health\":",
        "      _ = json.NewEncoder(w).Encode(map[string]string{\"status\": \"ok\"})",
        "    case r.Method == http.MethodPost && r.URL.Path == \"/users\":",
        "      var payload struct{ Name string `json:\"name\"` }",
        "      _ = json.NewDecoder(r.Body).Decode(&payload)",
        "      user := map[string]string{\"id\": \"1\", \"name\": payload.Name}",
        "      users[\"1\"] = user",
        "      w.WriteHeader(http.StatusCreated)",
        "      _ = json.NewEncoder(w).Encode(user)",
        "    case r.Method == http.MethodGet && r.URL.Path == \"/users/1\":",
        "      if user, ok := users[\"1\"]; ok {",
        "        _ = json.NewEncoder(w).Encode(user)",
        "        return",
        "      }",
        "      w.WriteHeader(http.StatusNotFound)",
        "      _ = json.NewEncoder(w).Encode(map[string]string{\"error\": \"not found\"})",
        "    default:",
        "      w.WriteHeader(http.StatusNotFound)",
        "      _ = json.NewEncoder(w).Encode(map[string]string{\"error\": \"not found\"})",
        "    }",
        "  })",
        "}",
        "EOF",
        "",
        "cat > server_test.go <<'EOF'",
        "package sandboxapp",
        "",
        "import (",
        "  \"bytes\"",
        "  \"encoding/json\"",
        "  \"net/http\"",
        "  \"net/http/httptest\"",
        "  \"testing\"",
        ")",
        "",
        "func TestAPIFlow(t *testing.T) {",
        "  handler := NewHandler()",
        "",
        "  healthReq := httptest.NewRequest(http.MethodGet, \"/health\", nil)",
        "  healthRes := httptest.NewRecorder()",
        "  handler.ServeHTTP(healthRes, healthReq)",
        "  if healthRes.Code != http.StatusOK {",
        "    t.Fatalf(\"health status = %d\", healthRes.Code)",
        "  }",
        "",
        "  body, _ := json.Marshal(map[string]string{\"name\": \"Ada\"})",
        "  createReq := httptest.NewRequest(http.MethodPost, \"/users\", bytes.NewReader(body))",
        "  createReq.Header.Set(\"Content-Type\", \"application/json\")",
        "  createRes := httptest.NewRecorder()",
        "  handler.ServeHTTP(createRes, createReq)",
        "  if createRes.Code != http.StatusCreated {",
        "    t.Fatalf(\"create status = %d\", createRes.Code)",
        "  }",
        "",
        "  fetchReq := httptest.NewRequest(http.MethodGet, \"/users/1\", nil)",
        "  fetchRes := httptest.NewRecorder()",
        "  handler.ServeHTTP(fetchRes, fetchReq)",
        "  if fetchRes.Code != http.StatusOK {",
        "    t.Fatalf(\"fetch status = %d\", fetchRes.Code)",
        "  }",
        "}",
        "EOF",
    ].joined(separator: "\n")
}
