# OsaurusPluginTestKit

Test harness for Osaurus native-plugin authors. Lets you unit-test your
plugin's `osaurus_plugin_entry_v2`, `init`, `invoke`, `handle_route`,
`on_config_changed`, and `on_task_event` callbacks against a mock host
that records every host-API call your plugin made — without booting the
Osaurus app or depending on `OsaurusCore`.

The kit ships:

- `OsrHostAPI` — Swift mirror of the v4 `osr_host_api` C struct, with
  function-pointer typealiases (`OsrConfigGet`, `OsrDispatch`, …).
- `MockHost` — builds a `OsrHostAPI*` whose callbacks route through
  Swift overrides + recorders. One per test.
- `ConfigWriteRecorder` — captures every `config_set` / `config_delete`
  the plugin emitted, with `lastValue(forKey:)` lookups for ordered
  assertions.
- `LogRecorder` — captures every `host->log(level, message)` call.

## Add to your plugin's tests

In your plugin's `Package.swift`:

```swift
.package(url: "https://github.com/osaurus-ai/osaurus", from: "0.18.0"),

.testTarget(
    name: "MyPluginTests",
    dependencies: [
        "MyPlugin",
        .product(name: "OsaurusPluginTestKit", package: "osaurus"),
    ]
)
```

## Recipe: drive your plugin against a mock host

The basic shape is "build a `MockHost`, install it, run plugin code,
assert against the recorders":

```swift
import OsaurusPluginTestKit
import Testing

@testable import MyPlugin  // the Swift module in your plugin's main target

struct MyPluginConfigTests {

    @Test func setupWebhookOnTunnelChange() {
        let host = MockHost()
        let agentId = UUID().uuidString
        host.activeAgentId = agentId
        host.onConfigGet = { key in
            switch key {
            case "bot_token": return "TEST_TOKEN"
            default: return nil
            }
        }
        // Stub the plugin's outbound HTTP so it doesn't hit Telegram
        // for real during the test.
        host.onHttpRequest = { _ in
            #"{"status":200,"body":"{\"ok\":true}","body_encoding":"utf8"}"#
        }

        host.withInstalled { hostAPI in
            // 1. Initialize the plugin against the mock host. Wire-
            //    up shape mirrors what the real loader does.
            let ctx = MyPlugin.osaurus_init(hostAPI: hostAPI)

            // 2. Drive the lifecycle event you care about.
            "https://0xagentX.agent.osaurus.ai".withCString { val in
                "tunnel_url".withCString { key in
                    MyPlugin.on_config_changed(ctx, key, val)
                }
            }

            // 3. Assert.
            #expect(host.configWrites.lastValue(forKey: "webhook_secret") != nil)
            #expect(host.logs.contains("Webhook registered"))
            MyPlugin.osaurus_destroy(ctx)
        }
    }
}
```

## Recorders

### `ConfigWriteRecorder`

```swift
host.configWrites.writes        // [.set(key:value:), .delete(key:), …]
host.configWrites.setCount      // total `config_set` calls
host.configWrites.deleteCount   // total `config_delete` calls
host.configWrites.lastValue(forKey: "bot_token")  // most recent set
```

### `LogRecorder`

```swift
host.logs.entries               // [(level, message)]
host.logs.messages              // [String]
host.logs.contains("substring") // any message contains?
```

## Override hooks

Set these closures BEFORE calling into the plugin. Defaults:

| Hook | Default |
|------|---------|
| `onConfigGet` | returns `nil` for every key |
| `onHttpRequest` | returns a `network_error` envelope (so unstubbed HTTP fails loud) |
| `onDispatch` | returns `{"id":"<uuid>","status":"running"}` so smoke tests parse |
| `activeAgentId` | `nil` (mimics init / background-thread frames where `get_active_agent_id` returns NULL) |

Override only what the test exercises. The rest of the host API surface
(db_exec, file_read, complete, embed, etc.) is left as `nil` slots —
plugins that call them under test will see a NULL function-pointer
and should defensively check before dereferencing (which the v4 ABI
contract recommends regardless).

## Threading

Each `MockHost.hostAPIPointer()` installs the mock in a thread-local
slot. Two `MockHost` instances on the *same* thread will trap on
install. For nested or concurrent tests use `withInstalled { ... }`,
which auto-uninstalls on scope exit.

## What this kit deliberately does NOT do

- Spawn a real Osaurus app or background tasks.
- Implement the real `dispatch` / `complete` / `embed` against an LLM.
- Verify Apple code signature, receipt, or consent — production load
  gates are host-side concerns.

For end-to-end tests against a live host, run the Osaurus app and use
`osaurus tools dev` for hot-reload iteration.
