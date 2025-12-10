# Developer Tools

Osaurus includes built-in developer tools for debugging, monitoring, and testing your integration. Access them via the Management window (`⌘ Shift M`).

---

## Insights

The **Insights** tab provides real-time monitoring of all API requests flowing through Osaurus.

### Accessing Insights

1. Open the Management window (`⌘ Shift M`)
2. Click **Insights** in the sidebar

### Features

#### Request Logging

Every API request is logged with:

| Field        | Description                 |
| ------------ | --------------------------- |
| **Time**     | Request timestamp           |
| **Source**   | Origin: Chat UI or HTTP API |
| **Method**   | HTTP method (GET/POST)      |
| **Path**     | Request endpoint            |
| **Status**   | HTTP status code            |
| **Duration** | Total response time         |

Click any row to expand and see full request/response details.

#### Filtering

Filter requests to find what you need:

| Filter     | Options                      |
| ---------- | ---------------------------- |
| **Search** | Filter by path or model name |
| **Method** | All, GET only, POST only     |
| **Source** | All, Chat UI, HTTP API       |

#### Aggregate Stats

The stats bar shows real-time metrics:

| Stat           | Description                           |
| -------------- | ------------------------------------- |
| **Requests**   | Total request count                   |
| **Success**    | Success rate percentage               |
| **Avg Time**   | Average response duration             |
| **Errors**     | Total error count                     |
| **Inferences** | Chat completion requests (if any)     |
| **Avg Speed**  | Average tokens/second (for inference) |

#### Request Details

Expand a request row to see:

**Request Panel:**

- Full request body (formatted JSON)
- Copy to clipboard

**Response Panel:**

- Full response body (formatted JSON)
- Status indicator (green for success, red for error)
- Response duration
- Copy to clipboard

**Inference Details** (for chat completions):

- Model used
- Token counts (input → output)
- Generation speed (tok/s)
- Temperature
- Max tokens
- Finish reason

**Tool Calls** (if applicable):

- Tool name
- Arguments
- Duration
- Success/error status

### Use Cases

- **Debugging API integration** — See exactly what's being sent and received
- **Performance monitoring** — Track latency and throughput
- **Tool call inspection** — Debug tool calling behavior
- **Error investigation** — Understand why requests fail

---

## Server Explorer

The **Server** tab provides an interactive API reference and testing interface.

### Accessing Server Explorer

1. Open the Management window (`⌘ Shift M`)
2. Click **Server** in the sidebar

### Features

#### Server Status

View current server state:

| Info           | Description                      |
| -------------- | -------------------------------- |
| **Server URL** | Base URL for API requests        |
| **Status**     | Running, Stopped, Starting, etc. |

Copy the server URL with one click for use in your applications.

#### API Endpoint Catalog

Browse all available endpoints, organized by category:

| Category | Endpoints                                |
| -------- | ---------------------------------------- |
| **Core** | `/`, `/health`, `/models`, `/tags`       |
| **Chat** | `/chat/completions`, `/chat`             |
| **MCP**  | `/mcp/health`, `/mcp/tools`, `/mcp/call` |

Each endpoint shows:

- HTTP method (GET/POST)
- Path
- Compatibility badge (OpenAI, Ollama, MCP)
- Description

#### Interactive Testing

Test any endpoint directly:

1. Click an endpoint row to expand it
2. For POST requests, edit the JSON payload
3. Click **Send Request**
4. View the formatted response

**Request Panel (left):**

- Editable JSON payload for POST requests
- Request preview for GET requests
- Reset button to restore default payload
- Send Request button

**Response Panel (right):**

- Formatted response body
- Status code badge
- Response duration
- Copy button
- Clear button

#### Documentation Link

Quick access to the full documentation at docs.osaurus.ai.

### Use Cases

- **API exploration** — Discover available endpoints
- **Quick testing** — Test endpoints without external tools
- **Payload experimentation** — Try different request formats
- **Response inspection** — See formatted API responses

---

## Workflow Examples

### Debugging a Chat Integration

1. Open **Insights**
2. Send a request from your application
3. Find the request in the log (filter by path if needed)
4. Expand to see request/response details
5. Check for errors in the response
6. If using tools, inspect tool call details

### Testing Tool Calling

1. Open **Server Explorer**
2. Expand `/chat/completions`
3. Modify the payload to include tools:

```json
{
  "model": "foundation",
  "messages": [{ "role": "user", "content": "What time is it?" }],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "current_time",
        "description": "Get the current time"
      }
    }
  ]
}
```

4. Click **Send Request**
5. Observe the tool call in the response
6. Check **Insights** for the full request flow

### Monitoring Performance

1. Open **Insights**
2. Run your test workload
3. Observe:
   - Avg Time (should be consistent)
   - Success rate (should be high)
   - Avg Speed for inference (tok/s)
4. Expand slow requests to investigate

### Verifying MCP Tools

1. Open **Server Explorer**
2. Expand `GET /mcp/tools`
3. Click **Send Request**
4. Verify your expected tools are listed
5. Test a specific tool with `POST /mcp/call`

---

## Tips

### Clear Logs Regularly

The Insights log grows over time. Use the **Clear** button to reset when debugging a specific issue.

### Use Source Filters

Filter by source to distinguish between:

- **Chat** — Requests from the built-in chat UI
- **HTTP** — Requests from external applications

### Copy Responses

Use the copy button to quickly grab response payloads for debugging in other tools.

### Keep Server Running

The Server Explorer requires the server to be running. If endpoints show as disabled, start the server first.

---

## Related Documentation

- [OpenAI API Guide](OpenAI_API_GUIDE.md) — API usage and examples
- [FEATURES.md](FEATURES.md) — Feature inventory
- [README](../README.md) — Quick start guide
