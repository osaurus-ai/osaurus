# Remote MCP Providers

Remote MCP Providers allow you to connect Osaurus to external MCP (Model Context Protocol) servers, aggregating their tools into your Osaurus instance.

---

## Overview

With Remote MCP Providers, you can:

- Connect to any MCP server over HTTP/SSE
- Automatically discover and register remote tools
- Use remote tools alongside local plugins
- Aggregate tools from multiple MCP servers

This is different from Remote Providers (which provide inference endpoints). Remote MCP Providers provide **tools** that models can call.

---

## Adding an MCP Provider

### Via the UI

1. Open the Management window (`⌘ Shift M`)
2. Click **Providers** in the sidebar
3. Scroll to the **MCP Providers** section
4. Click **Add MCP Provider**
5. Enter the MCP server URL
6. Configure authentication if required
7. Click **Save**

---

## Configuration Options

### Basic Settings

| Setting     | Description                         |
| ----------- | ----------------------------------- |
| **Name**    | Display name for the provider       |
| **URL**     | Full URL to the MCP server endpoint |
| **Enabled** | Whether the provider is active      |

### Authentication

| Setting            | Description                                          |
| ------------------ | ---------------------------------------------------- |
| **Token**          | Bearer token for authentication (stored in Keychain) |
| **Custom Headers** | Additional HTTP headers                              |

### Advanced Settings

| Setting               | Description                               | Default |
| --------------------- | ----------------------------------------- | ------- |
| **Auto-connect**      | Connect automatically when Osaurus starts | true    |
| **Streaming Enabled** | Use SSE streaming for tool discovery      | false   |
| **Discovery Timeout** | Timeout for tool discovery (seconds)      | 20      |
| **Tool Call Timeout** | Timeout for tool execution (seconds)      | 45      |

---

## How It Works

### Tool Discovery

When you connect to an MCP provider:

1. Osaurus establishes a connection to the MCP server
2. Sends a `tools/list` request to discover available tools
3. Registers each tool with a namespaced name
4. Tools become available for model inference

### Tool Namespacing

To prevent naming conflicts, tools from remote MCP providers are prefixed with the provider name:

```
provider_toolname
```

For example, if you connect a provider named "myserver" with a tool called "search", the tool will be registered as:

```
myserver_search
```

### Tool Execution

When a model calls a remote MCP tool:

1. Osaurus receives the tool call request
2. Routes it to the correct MCP provider
3. Sends the request to the remote MCP server
4. Returns the result to the model

---

## Using Remote MCP Tools

### In Chat

Remote MCP tools work like any other tool. When a model decides to use a tool, Osaurus handles the routing automatically.

### Via MCP API

List all tools (including remote ones):

```bash
curl http://127.0.0.1:1337/mcp/tools
```

Call a remote tool directly:

```bash
curl http://127.0.0.1:1337/mcp/call \
  -H "Content-Type: application/json" \
  -d '{
    "name": "myserver_search",
    "arguments": {"query": "hello world"}
  }'
```

---

## Connection States

MCP Providers can be in the following states:

| State            | Indicator       | Description                         |
| ---------------- | --------------- | ----------------------------------- |
| **Connected**    | Green           | Active connection, tools discovered |
| **Connecting**   | Blue (animated) | Establishing connection             |
| **Disconnected** | Gray            | Not connected                       |
| **Disabled**     | Gray            | Manually disabled                   |
| **Error**        | Red             | Connection or discovery failed      |

### Connection Info

When connected, the provider card shows:

- Number of tools discovered
- Last connected timestamp
- Any error messages

---

## Testing Connections

Before saving a provider, you can test the connection:

1. Enter the URL and authentication
2. Click **Test Connection**
3. If successful, you'll see the number of tools discovered
4. Click **Save** to persist the provider

---

## Troubleshooting

### Common Issues

**"Connection refused"**

- Verify the MCP server is running
- Check the URL is correct (including protocol and port)
- Ensure no firewall is blocking the connection

**"Authentication failed"**

- Verify your token is correct
- Check if custom headers are required

**"Discovery timeout"**

- The MCP server may be slow to respond
- Try increasing the discovery timeout
- Check server health

**"No tools discovered"**

- The MCP server may not expose any tools
- Check the server's tool configuration

### Debug Mode

Use the **Insights** tab to monitor MCP provider activity:

1. Open Management window (`⌘ Shift M`)
2. Click **Insights** in the sidebar
3. Filter by source or search for your provider name

---

## Security

### Token Storage

Authentication tokens are stored in the macOS Keychain, ensuring they are:

- Encrypted at rest
- Protected by your macOS login
- Never exposed in configuration files

### Secret Headers

Custom headers marked as "secret" are also stored in the Keychain.

### Configuration Files

Non-secret configuration is stored at:

```
~/Library/Application Support/Osaurus/mcp_providers.json
```

---

## Example: Connecting to a Custom MCP Server

Suppose you have an MCP server running at `https://mcp.example.com/sse`:

1. Click **Add MCP Provider**
2. Enter:
   - **Name:** "Example Server"
   - **URL:** `https://mcp.example.com/sse`
   - **Token:** (your auth token)
3. Click **Test Connection** to verify
4. Click **Save**

The server's tools will now be available in Osaurus as:

- `example-server_tool1`
- `example-server_tool2`
- etc.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Osaurus                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   ToolRegistry                           │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │    │
│  │  │ Local Plugin │  │ Local Plugin │  │ MCP Provider │   │    │
│  │  │   (browser)  │  │ (filesystem) │  │    Tools     │   │    │
│  │  └──────────────┘  └──────────────┘  └──────┬───────┘   │    │
│  └─────────────────────────────────────────────│───────────┘    │
│                                                 │                │
│  ┌─────────────────────────────────────────────│───────────┐    │
│  │              MCPProviderManager              │           │    │
│  │  ┌─────────────────────────────────────────┴────────┐   │    │
│  │  │              Remote MCP Client                    │   │    │
│  │  └─────────────────────────────────────────┬────────┘   │    │
│  └─────────────────────────────────────────────│───────────┘    │
└─────────────────────────────────────────────────│────────────────┘
                                                  │
                                                  ▼
                               ┌─────────────────────────────┐
                               │   Remote MCP Server         │
                               │   (external)                │
                               │   ├── tool1                 │
                               │   ├── tool2                 │
                               │   └── tool3                 │
                               └─────────────────────────────┘
```

---

## Related Documentation

- [Remote Providers](REMOTE_PROVIDERS.md) — Connect to inference APIs
- [Plugin Authoring](PLUGIN_AUTHORING.md) — Create local plugins
- [FEATURES.md](FEATURES.md) — Feature inventory
- [README](../README.md) — Quick start guide
