// Osaurus tools for a Pi harness, loaded with `pi -e <this file>`.
//
// Pi has no MCP client, so this registers each tool the process's agent
// token grants (`GET /mcp/tools`) as a Pi tool that runs through
// `POST /mcp/call`. No imports: the file is loaded from the Osaurus app
// bundle, where no node_modules resolve. Pi accepts plain JSON Schema for
// `parameters`.

const PROPOSE_SAVE = "workflow_propose_save";
const LIST_TIMEOUT_MS = 5_000;

type McpContent = { type?: string; text?: string };
type McpResult = { content?: McpContent[]; isError?: boolean };

function resultText(result: McpResult): string {
  return (result.content ?? [])
    .map((part) => (typeof part.text === "string" ? part.text : ""))
    .join("\n");
}

export default async function (pi: any) {
  const base = (process.env.OSAURUS_API_BASE ?? "").replace(/\/+$/, "");
  const token = process.env.OSAURUS_AGENT_TOKEN ?? "";
  if (!base || !token) return;
  const headers = { "X-Osaurus-Bridge-Grant": token, "Content-Type": "application/json" };

  let tools: Array<{ name: string; description?: string; inputSchema?: unknown }> = [];
  try {
    const response = await fetch(`${base}/mcp/tools`, {
      headers,
      signal: AbortSignal.timeout(LIST_TIMEOUT_MS),
    });
    if (!response.ok) return;
    tools = ((await response.json()) as { tools?: typeof tools }).tools ?? [];
  } catch {
    // Server stopped: the agent's instructions already say the tools are
    // unavailable on this run.
    return;
  }

  for (const tool of tools) {
    pi.registerTool({
      name: tool.name,
      label: tool.name,
      description: tool.description ?? "",
      parameters: tool.inputSchema ?? { type: "object", properties: {} },
      async execute(_toolCallId: string, params: unknown, signal?: AbortSignal) {
        const response = await fetch(`${base}/mcp/call`, {
          method: "POST",
          headers,
          body: JSON.stringify({ name: tool.name, arguments: params ?? {} }),
          signal,
        });
        const result = (await response.json().catch(() => ({}))) as McpResult;
        const text = resultText(result) || `HTTP ${response.status}`;
        if (!response.ok || result.isError) throw new Error(text);
        return {
          content: [{ type: "text", text }],
          details: {},
          // The save card asks the person next; another model call would
          // only talk over it.
          terminate: tool.name === PROPOSE_SAVE,
        };
      },
    });
  }
}
