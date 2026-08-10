#!/usr/bin/env node

// Run Osaurus agent-loop JSON fixtures through Pi's non-interactive JSON mode
// and emit an EvalReport-compatible artifact. The regular `osaurus-evals
// matrix` command can then compare same-model Osaurus and Pi columns directly.

import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { arch, cpus, release, totalmem, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";

function parseArgs(argv) {
  const out = { pi: "pi", suite: "Packages/OsaurusEvals/Suites/AgentLoop" };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--") || i + 1 >= argv.length) throw new Error(`invalid argument: ${key}`);
    out[key.slice(2)] = argv[++i];
  }
  if (!out.model || !out.out) {
    throw new Error("usage: pi-harness-runner.mjs --model <report-model-id> --out <report.json> [--api-model <local-api-id>] [--osaurus-base-url http://127.0.0.1:1337/v1] [--context-window <n>] [--max-tokens <n>] [--timeout-seconds <n>] [--pi <path>] [--suite <dir>] [--filter <regex>] [--repeat <n>]");
  }
  out.repeat = Math.max(1, Number.parseInt(out.repeat ?? "1", 10) || 1);
  out.contextWindow = Math.max(1, Number.parseInt(out["context-window"] ?? "32768", 10) || 32768);
  out.maxTokens = Math.max(1, Number.parseInt(out["max-tokens"] ?? "8192", 10) || 8192);
  out.timeoutSeconds = Math.max(1, Number.parseInt(out["timeout-seconds"] ?? "900", 10) || 900);
  out.osaurusBaseUrl = out["osaurus-base-url"];
  out.apiModel = out["api-model"] ?? out.model;
  return out;
}

async function configureIsolatedLocalProvider(args) {
  if (!args.osaurusBaseUrl) {
    return { env: process.env, providerArgs: ["--model", args.model], cleanup: async () => {} };
  }
  const baseUrl = args.osaurusBaseUrl.replace(/\/+$/, "");
  const response = await fetch(`${baseUrl}/models`);
  if (!response.ok) {
    throw new Error(`Osaurus model discovery failed: ${response.status} ${await response.text()}`);
  }
  const catalog = await response.json();
  const ids = new Set((catalog.data ?? []).map((item) => item.id));
  if (!ids.has(args.apiModel)) {
    throw new Error(`Osaurus local API does not advertise model '${args.apiModel}'`);
  }

  const agentDir = await mkdtemp(join(tmpdir(), "osaurus-pi-config-"));
  const provider = "osaurus-local";
  const config = {
    providers: {
      [provider]: {
        baseUrl,
        api: "openai-completions",
        apiKey: "osaurus-local-eval",
        compat: {
          supportsDeveloperRole: false,
          supportsReasoningEffort: false,
          maxTokensField: "max_tokens",
        },
        models: [{
          id: args.apiModel,
          name: args.model,
          reasoning: false,
          input: ["text"],
          contextWindow: args.contextWindow,
          maxTokens: args.maxTokens,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        }],
      },
    },
  };
  await writeFile(join(agentDir, "models.json"), `${JSON.stringify(config, null, 2)}\n`);
  return {
    env: { ...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1", PI_TELEMETRY: "0" },
    providerArgs: ["--provider", provider, "--model", args.apiModel],
    cleanup: () => rm(agentDir, { recursive: true, force: true }),
  };
}

async function jsonFiles(root) {
  const entries = await readdir(root, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return jsonFiles(path);
    return entry.isFile() && entry.name.endsWith(".json") ? [path] : [];
  }));
  return nested.flat();
}

function fnvCatalog(ids) {
  const text = [...new Set(ids)].sort().join("\n");
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text)) {
    hash ^= BigInt(byte);
    hash = BigInt.asUintN(64, hash * 0x100000001b3n);
  }
  return hash.toString(16).padStart(16, "0");
}

function run(command, args, options = {}) {
  return new Promise((resolveRun) => {
    const { timeoutMs, onStdout, ...spawnOptions } = options;
    const child = spawn(command, args, { ...spawnOptions, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let forceKillTimer;
    const timeout = timeoutMs == null ? undefined : setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      forceKillTimer = setTimeout(() => child.kill("SIGKILL"), 5_000);
    }, timeoutMs);
    child.stdout.on("data", (chunk) => { stdout += chunk; onStdout?.(chunk.toString()); });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      clearTimeout(timeout);
      clearTimeout(forceKillTimer);
      resolveRun({ code: -1, stdout, stderr: `${stderr}${error}`, timedOut });
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      clearTimeout(forceKillTimer);
      resolveRun({ code: code ?? -1, stdout, stderr, timedOut });
    });
  });
}

const piToOsaurus = {
  read: "file_read",
  grep: "file_search",
  find: "file_search",
  ls: "file_search",
  write: "file_write",
  edit: "file_edit",
  bash: "shell_run",
};

function expectedPiNames(name) {
  if (name === "file_search") return new Set(["grep", "find", "ls"]);
  const match = Object.entries(piToOsaurus).find(([, normalized]) => normalized === name);
  return new Set(match ? [match[0]] : [name]);
}

function assistantText(messages) {
  const message = [...(messages ?? [])].reverse().find((item) => item?.role === "assistant");
  if (!message) return "";
  if (typeof message.content === "string") return message.content;
  return (message.content ?? [])
    .filter((part) => part?.type === "text")
    .map((part) => part.text ?? "")
    .join("");
}

async function fileCheck(assertion, workspace) {
  const path = join(workspace, assertion.path);
  let exists = true;
  let contents = "";
  try {
    const info = await stat(path);
    if (info.isFile()) contents = await readFile(path, "utf8");
  } catch {
    exists = false;
  }
  if (assertion.exists === false) return !exists;
  if (!exists) return false;
  if (assertion.contains != null && !contents.includes(assertion.contains)) return false;
  if (assertion.notContains != null && contents.includes(assertion.notContains)) return false;
  return true;
}

async function runCase(testCase, args) {
  if (testCase.domain !== "agent_loop"
    || testCase.fixtures?.sandbox
    || testCase.expect?.agentLoop?.cancelAfterToolCalls != null
    || (testCase.expect?.agentLoop?.rubric ?? []).length > 0) {
    return {
      id: testCase.id, label: testCase.label ?? testCase.id, domain: testCase.domain,
      query: testCase.query, outcome: "skipped",
      notes: ["Pi adapter supports host-folder, non-cancellation agent_loop rows only."],
      modelId: args.model,
      blocker: {
        kind: "unsupportedHarness",
        message: "Pi adapter supports host-folder, non-cancellation agent_loop rows only.",
      },
    };
  }

  const caseArgs = {
    ...args,
    maxTokens: testCase.expect?.agentLoop?.maxTokens ?? args.maxTokens,
  };
  const isolatedProvider = await configureIsolatedLocalProvider(caseArgs);
  const root = await mkdtemp(join(tmpdir(), "osaurus-pi-eval-"));
  const workspace = join(root, "workspace");
  await mkdir(workspace);
  const resolvedQuery = testCase.query.replaceAll("{{WORKSPACE_BASENAME}}", "workspace");
  try {
    for (const fixture of testCase.fixtures?.workspaceFiles ?? []) {
      const path = join(workspace, fixture.path);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, fixture.contents ?? "");
    }

    const events = [];
    let buffered = "";
    let firstActionMs;
    const started = performance.now();
    const result = await run(args.pi, [
      "--mode", "json",
      "--no-session",
      "--no-context-files",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--approve",
      "--tools", "read,bash,edit,write,grep,find,ls",
      "--thinking", "off",
      ...isolatedProvider.providerArgs,
      resolvedQuery,
    ], {
      cwd: workspace,
      env: isolatedProvider.env,
      timeoutMs: args.timeoutSeconds * 1_000,
      onStdout(chunk) {
        buffered += chunk;
        const lines = buffered.split("\n");
        buffered = lines.pop() ?? "";
        for (const line of lines) {
          try {
            const event = JSON.parse(line);
            events.push(event);
            if (event.type === "tool_execution_start" && firstActionMs == null) {
              firstActionMs = performance.now() - started;
            }
          } catch {}
        }
      },
    });
    const latencyMs = performance.now() - started;
    if (buffered.trim()) {
      try { events.push(JSON.parse(buffered)); } catch {}
    }

    const starts = events.filter((event) => event.type === "tool_execution_start");
    const ends = events.filter((event) => event.type === "tool_execution_end");
    const endById = new Map(ends.map((event) => [event.toolCallId, event]));
    const normalizedCalls = starts.map((event) => ({
      rawName: event.toolName,
      name: piToOsaurus[event.toolName] ?? event.toolName,
      args: event.args ?? {},
      isError: endById.get(event.toolCallId)?.isError === true,
    }));
    const agentEnd = [...events].reverse().find((event) => event.type === "agent_end");
    const finalText = assistantText(agentEnd?.messages);
    const exp = testCase.expect.agentLoop;
    const failures = [];

    for (const required of exp.mustCallTools ?? []) {
      if (!normalizedCalls.some((call) => expectedPiNames(required).has(call.rawName))) {
        failures.push(`missing required tool ${required}`);
      }
    }
    if ((exp.mustCallAnyTools ?? []).length > 0
      && !normalizedCalls.some((call) => exp.mustCallAnyTools.some((name) => expectedPiNames(name).has(call.rawName)))) {
      failures.push(`missing every alternative tool: ${exp.mustCallAnyTools.join(", ")}`);
    }
    for (const forbidden of exp.mustNotCallTools ?? []) {
      if (normalizedCalls.some((call) => expectedPiNames(forbidden).has(call.rawName))) {
        failures.push(`called forbidden tool ${forbidden}`);
      }
    }
    if (exp.maxToolCalls != null && normalizedCalls.length > exp.maxToolCalls) {
      failures.push(`tool calls ${normalizedCalls.length} > ${exp.maxToolCalls}`);
    }
    const provisionalSteps = events.filter((event) => event.type === "turn_start").length;
    if (exp.maxModelSteps != null && provisionalSteps > exp.maxModelSteps) {
      failures.push(`model steps ${provisionalSteps} > ${exp.maxModelSteps}`);
    }
    const seen = new Set();
    let duplicateCalls = 0;
    for (const call of normalizedCalls) {
      const key = `${call.name}:${JSON.stringify(call.args, Object.keys(call.args).sort())}`;
      if (seen.has(key)) duplicateCalls += 1;
      seen.add(key);
    }
    if (exp.noDuplicateExecutedCalls && duplicateCalls > 0) failures.push(`${duplicateCalls} duplicate call(s)`);
    if (exp.noToolErrors && normalizedCalls.some((call) => call.isError)) failures.push("tool error observed");
    for (const audit of exp.toolUsageAudit ?? []) {
      const calls = normalizedCalls.filter((call) => expectedPiNames(audit.tool).has(call.rawName));
      const errors = calls.filter((call) => call.isError).length;
      if (audit.minCalls != null && calls.length < audit.minCalls) failures.push(`${audit.tool} calls ${calls.length} < ${audit.minCalls}`);
      if (audit.maxCalls != null && calls.length > audit.maxCalls) failures.push(`${audit.tool} calls ${calls.length} > ${audit.maxCalls}`);
      if (audit.minErrors != null && errors < audit.minErrors) failures.push(`${audit.tool} errors ${errors} < ${audit.minErrors}`);
      if (audit.maxErrors != null && errors > audit.maxErrors) failures.push(`${audit.tool} errors ${errors} > ${audit.maxErrors}`);
    }
    for (const assertion of exp.files ?? []) {
      if (!(await fileCheck(assertion, workspace))) failures.push(`file assertion failed: ${assertion.path}`);
    }
    for (const assertion of exp.commands ?? []) {
      const command = await run("/bin/zsh", ["-lc", assertion.command], { cwd: workspace });
      if (command.code !== (assertion.expectExitCode ?? 0)) failures.push(`command failed: ${assertion.command}`);
    }
    for (const needle of exp.finalTextContains ?? []) {
      if (!finalText.toLowerCase().includes(needle.toLowerCase())) failures.push(`final text missing: ${needle}`);
    }
    for (const needle of exp.finalTextMustNotContain ?? []) {
      if (finalText.toLowerCase().includes(needle.toLowerCase())) failures.push(`final text leaked: ${needle}`);
    }
    if (result.timedOut) {
      failures.push(`watchdog timeout: Pi exceeded ${args.timeoutSeconds}s`);
    } else if (result.code !== 0) {
      failures.push(`pi exited ${result.code}: ${result.stderr.trim()}`);
    }

    const usageByTool = new Map();
    for (const call of normalizedCalls) {
      const current = usageByTool.get(call.name) ?? { tool: call.name, calls: 0, errors: 0, deduped: 0 };
      current.calls += 1;
      if (call.isError) current.errors += 1;
      usageByTool.set(call.name, current);
    }
    const assistantMessages = events
      .filter((event) => event.type === "message_end" && event.message?.role === "assistant")
      .map((event) => event.message);
    const inputTokens = assistantMessages.reduce((sum, message) => sum + (message.usage?.input ?? 0), 0);
    const outputTokens = assistantMessages.reduce((sum, message) => sum + (message.usage?.output ?? 0), 0);
    const modelSteps = events.filter((event) => event.type === "turn_start").length;
    const exit = result.timedOut ? "watchdogTimeout" : result.code === 0 ? "finalResponse" : "errored";

    return {
      id: testCase.id,
      label: testCase.label ?? testCase.id,
      domain: testCase.domain,
      query: resolvedQuery,
      outcome: result.timedOut ? "errored" : failures.length === 0 ? "passed" : "failed",
      notes: [
        ...failures,
        `summary: toolCalls=[${normalizedCalls.map((call) => call.name).join(",")}] iters=${modelSteps} exit=${exit}`,
        `final: ${finalText.replaceAll("\n", " ")}`,
      ],
      modelId: args.model,
      latencyMs,
      toolUsage: [...usageByTool.values()].sort((a, b) => a.tool.localeCompare(b.tool)),
      telemetry: {
        firstActionMs,
        completionTokens: outputTokens || undefined,
        promptTokensTotal: inputTokens || undefined,
        totalModelTokens: inputTokens || outputTokens ? inputTokens + outputTokens : undefined,
        modelSteps: modelSteps || undefined,
      },
    };
  } finally {
    await rm(root, { recursive: true, force: true });
    await isolatedProvider.cleanup();
  }
}

function trialSummary(row, args, testCase) {
  return {
    outcome: row.outcome,
    notes: row.notes ?? [],
    latencyMs: row.latencyMs,
    toolUsage: row.toolUsage,
    telemetry: row.telemetry,
    context: row.context,
    blocker: row.blocker,
    contextWindow: args.contextWindow,
    maxOutputTokens: testCase.expect?.agentLoop?.maxTokens ?? args.maxTokens,
  };
}

function mergedTrials(rows, args, testCase) {
  if (rows.length === 1 || rows.every((row) => row.outcome === "skipped")) return rows[0];
  const scored = rows.filter((row) => row.outcome !== "skipped");
  const passed = scored.filter((row) => row.outcome === "passed").length;
  const threshold = testCase.passThreshold;
  const passes = threshold == null
    ? passed * 2 > scored.length
    : passed / scored.length >= Math.max(0, Math.min(1, threshold));
  const outcome = passes
    ? "passed"
    : scored.every((row) => row.outcome === "errored") ? "errored" : "failed";
  const representative = rows.find((row) => row.outcome === outcome) ?? rows[0];
  const latencies = scored.map((row) => row.latencyMs).filter((value) => value != null);
  return {
    ...representative,
    outcome,
    latencyMs: latencies.length > 0
      ? latencies.reduce((sum, value) => sum + value, 0) / latencies.length
      : undefined,
    notes: [
      `trials: ${passed}/${rows.length} passed${passed > 0 && passed < rows.length ? " — FLAKY" : ""}`,
      ...representative.notes,
    ],
    trials: rows.length,
    trialsPassed: passed,
    trialSummaries: rows.map((row) => trialSummary(row, args, testCase)),
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const suite = resolve(args.suite);
  const filter = args.filter ? new RegExp(args.filter) : null;
  const cases = [];
  for (const path of (await jsonFiles(suite)).sort()) {
    const testCase = JSON.parse(await readFile(path, "utf8"));
    if (!filter || filter.test(testCase.id) || filter.test(testCase.label ?? "")) cases.push(testCase);
  }
  if (cases.length === 0) throw new Error("no matching cases");

  const versionResult = await run(args.pi, ["--version"], { env: process.env });
  const piVersion = versionResult.code === 0
    ? versionResult.stdout.trim().split("\n")[0]
    : undefined;
  const rows = [];
  for (const testCase of cases) {
    const trials = [];
    const trialsWanted = Math.max(args.repeat, testCase.trials ?? 1);
    for (let trial = 1; trial <= trialsWanted; trial += 1) {
      process.stderr.write(`[pi] ${testCase.id} trial ${trial}/${trialsWanted}\n`);
      const row = await runCase(testCase, args);
      trials.push(row);
      if (row.outcome === "skipped") break;
    }
    rows.push(mergedTrials(trials, args, testCase));
  }
  const report = {
    modelId: args.model,
    startedAt: new Date().toISOString(),
    cases: rows,
    environment: {
      runModel: args.model,
      harness: "pi",
      harnessVersion: piVersion,
      apiModel: args.apiModel,
      contextWindow: args.contextWindow,
      maxOutputTokens: args.maxTokens,
      chip: `${cpus()[0]?.model ?? "unknown"} (${arch()})`,
      totalRamMb: Math.round(totalmem() / (1024 * 1024)),
      cpuCores: cpus().length,
      osVersion: release(),
      catalogHash: fnvCatalog(cases.map((item) => item.id)),
      caseCount: cases.length,
    },
  };
  await mkdir(dirname(resolve(args.out)), { recursive: true });
  await writeFile(resolve(args.out), `${JSON.stringify(report, null, 2)}\n`);
  const passed = rows.filter((row) => row.outcome === "passed").length;
  process.stderr.write(`[pi] wrote ${args.out}: ${passed}/${rows.length} passed\n`);
}

main().catch((error) => {
  process.stderr.write(`pi harness runner error: ${error.stack ?? error}\n`);
  process.exitCode = 2;
});
