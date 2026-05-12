# Testing Plugins

How to validate your plugin without installing it into Osaurus.

## What you can test in isolation

- **Manifest decode** — make sure the JSON your `get_manifest` returns parses against `PluginManifest`
- **Tool argument parsing** — feed canned JSON into your tool's argument decoder
- **Route matching** — verify your route patterns against expected paths
- **Tool result envelope** — assert the shape against `ToolEnvelope`

## What requires an integration setup

- The full `dlopen` + `init` + `get_manifest` lifecycle
- Live host API calls (inference, dispatch, file_read)
- The `osaurus tools dev` reload loop
- Web UI rendering against `window.__osaurus`

## Unit testing the plugin in Swift

Spin up a Swift test target alongside your plugin. Assertions should be against the canonical [TOOL_CONTRACT](../TOOL_CONTRACT.md) shape — `result` for success, `kind` + `message` for failure:

```swift
// Tests/MyPluginTests/HelloToolTests.swift
import Testing
@testable import MyPlugin

@Test func helloWorldGreetsByName() throws {
    let tool = HelloTool()
    let json = tool.run(args: #"{"name":"World"}"#)
    let dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    #expect(dict["ok"] as? Bool == true)
    let result = dict["result"] as? [String: Any]
    #expect(result?["text"] as? String == "Hello, World!")
}

@Test func invalidArgsReturnsError() throws {
    let tool = HelloTool()
    let json = tool.run(args: "not json")
    let dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    #expect(dict["ok"] as? Bool == false)
    #expect(dict["kind"] as? String == "invalid_args")
    #expect((dict["message"] as? String)?.isEmpty == false)
}
```

Run with `swift test`.

For tests that drive the plugin's host-API callbacks (`init`, `invoke`, `on_config_changed`), use the [`OsaurusPluginTestKit`](../../Packages/OsaurusPluginTestKit/README.md) package — it provides a `MockHost` that records every host call your plugin made.

## Unit testing in Rust

```rust
// src/lib.rs
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_world_greets_by_name() {
        let result = hello_world(r#"{"name":"World"}"#);
        assert!(result.contains("Hello, World!"));
    }
}
```

Run with `cargo test`.

## Validating the manifest

The host parses your manifest with `JSONDecoder().decode(PluginManifest.self, ...)`. Two CLI commands let you catch decode errors before shipping:

```bash
# Extract the manifest from a built dylib (loads it in a stub host):
osaurus manifest extract ./.build/release/libmy-plugin.dylib > manifest.json

# Validate the JSON against PluginManifest. Reports decode errors with the
# field path so you can fix typos before install time.
osaurus manifest validate manifest.json
```

`osaurus manifest extract` loads your dylib in a stub host and prints what `get_manifest()` returned. `osaurus manifest validate` runs the same `JSONDecoder` Osaurus uses at install time, but on a file you control — so you can iterate without rebuilding.

## Mocking the host API in unit tests

For tools that call host APIs, build a mock `osr_host_api` struct in tests:

```swift
// In test code:
private var capturedLogs: [(Int32, String)] = []

private static let mockHost = osr_host_api(
    version: 3,
    config_get: nil,
    // ...
    log: { level, msgPtr in
        if let p = msgPtr {
            capturedLogs.append((level, String(cString: p)))
        }
    },
    // ... rest of fields
)
```

Inject the mock pointer into your plugin's `hostAPI` global, then run the tool and assert against `capturedLogs`.

For Rust, do the same with a `static mut` mock.

## Integration testing

Two approaches:

### A. Manual smoke test against a dev-loaded plugin

```bash
osaurus tools dev   # builds + reloads on save
```

While `osaurus tools dev` is running, the simplest way to invoke your plugin is from chat — open Osaurus and ask the model to use the tool by name.

For HTTP route testing you'll need an access key and an agent UUID. Both are visible in **Settings → Network** inside the app:

- Copy a Bearer access key (`osk-v1-...`) from the Access Keys section.
- Copy the active agent's UUID from the Agent picker.

Then:

```bash
curl -H "X-Osaurus-Agent-Id: <agent-uuid>" \
     -H "Authorization: Bearer <osk-v1-key>" \
     http://127.0.0.1:1338/plugins/dev.example.MyPlugin/health

curl -X POST http://127.0.0.1:1338/v1/chat/completions \
     -H "Authorization: Bearer <osk-v1-key>" \
     -d '{"model":"local","messages":[{"role":"user","content":"Use hello_world with name Test"}]}'
```

### B. CI integration

The release workflow scaffolded by `osaurus tools create` sets up a CI job. Extend it with a test step that boots Osaurus headless, installs your plugin, and runs the smoke tests above.

## What to test before publishing

A pre-flight checklist:

- [ ] Plugin loads cleanly: `osaurus tools list` shows it without an error column
- [ ] Manifest is valid: `osaurus manifest validate <manifest.json>` passes
- [ ] All declared tools are reachable from chat
- [ ] Tool returns conform to `ToolEnvelope`
- [ ] Routes return expected status codes for `none`/`verify`/`owner` auth scenarios
- [ ] Web UI loads via the **Open Web App** button (not by typing the URL)
- [ ] `osaurus tools doctor MyPlugin` reports no warnings
- [ ] No host API calls log `context_unavailable` in Insights
- [ ] Plugin survives `osaurus tools reload` without leaking memory or losing state

## Existing test suites for reference

The Osaurus codebase ships test patterns you can adapt:

- `Packages/OsaurusCore/Tests/Plugin/PluginTests.swift` — manifest decode, route matching, MIME, rate limiter
- `Packages/OsaurusCore/Tests/Plugin/PluginRoutingTests.swift` — path-parameter encoding, web mount config
- `Packages/OsaurusCore/Tests/Plugin/PluginHostAPITests.swift` — host API helpers, SSRF, dispatch shapes

These are the canonical examples of how to construct manifests, decode JSON, and assert on plugin behavior in tests.

## See also

- [DEBUGGING.md](DEBUGGING.md) — when the manual smoke test fails
- [PACKAGING.md](PACKAGING.md) — what to ship after testing
- [../TOOL_CONTRACT.md](../TOOL_CONTRACT.md) — the tool result envelope shape
