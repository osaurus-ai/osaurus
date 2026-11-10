//
//  main.swift
//  osaurus-js-host
//
//  Runs ONE workflow code node: a JavaScript `run(input, ctx)` function on
//  JavaScriptCore, in a fresh process the app launches under a deny-default
//  Seatbelt profile and kills on timeout or memory breach.
//
//  The script gets no DOM, no Node, no timers, no filesystem, and no
//  network of its own. `ctx.fetch`, `ctx.secrets.get`, and `ctx.files` are
//  reverse calls to the app, which enforces the node's host allowlist, its
//  declared secret keys, and the run workspace. Nothing the script does
//  can reach anything the node did not declare.
//
//  Wire protocol (one JSON object per line):
//    app → host, first line:  {"source": "...", "input": {...}, "run": {...}, "caller": {...}}
//    host → app requests:     {"id":"h-1","method":"fetch"|"secret"|"files.*","params":{...}}
//    app → host responses:    {"id":"h-1","result":{...}} | {"id":"h-1","error":{"message":"..."}}
//    host → app notification: {"method":"log","params":{"message":"..."}}
//    host → app, last line:   {"done":true,"result":<json>} | {"done":true,"error":{"message","stack"}}
//
//  Foundation + JavaScriptCore only, so the binary never links the app.
//

import Foundation
import JavaScriptCore

// MARK: - Line I/O

nonisolated(unsafe) var stdinBuffer = Data()
nonisolated(unsafe) var nextRequestID = 0

func writeLine(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
        return
    }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func readLine() -> Data? {
    while true {
        if let newline = stdinBuffer.firstIndex(of: 0x0A) {
            let line = stdinBuffer[stdinBuffer.startIndex ..< newline]
            stdinBuffer.removeSubrange(stdinBuffer.startIndex ... newline)
            return Data(line)
        }
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { return nil }
        stdinBuffer.append(chunk)
    }
}

func finish(_ object: [String: Any]) -> Never {
    var payload = object
    payload["done"] = true
    writeLine(payload)
    exit(0)
}

/// Blocking reverse call. The script is single-threaded and the app only
/// ever answers, so the next line with this id is the answer.
struct CallError: Error {
    let message: String
}

func call(_ method: String, _ params: [String: Any]) -> Result<Any, CallError> {
    nextRequestID += 1
    let id = "h-\(nextRequestID)"
    writeLine(["id": id, "method": method, "params": params])
    while let line = readLine() {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            obj["id"] as? String == id
        else { continue }
        if let error = obj["error"] as? [String: Any] {
            return .failure(CallError(message: error["message"] as? String ?? "\(method) failed"))
        }
        return .success(obj["result"] ?? NSNull())
    }
    finish(["error": ["message": "The app closed the connection during \(method)."]])
}

// MARK: - Script prelude

/// `ctx` surface. Native hooks return JSON strings so values cross the
/// bridge losslessly; the prelude turns them into the documented shapes.
let prelude = """
    "use strict";
    globalThis.__osaurus_ctx = Object.freeze({
      run: Object.freeze(JSON.parse(__osaurus_run_json)),
      caller: Object.freeze(JSON.parse(__osaurus_caller_json)),
      fetch: async function (url, options) {
        const raw = __osaurus_native_fetch(String(url), JSON.stringify(options || {}));
        const r = JSON.parse(raw);
        if (r.error) { throw new Error(r.error); }
        return Object.freeze({
          status: r.status,
          ok: r.status >= 200 && r.status < 300,
          headers: Object.freeze(r.headers || {}),
          truncated: r.truncated === true,
          text: async function () { return r.body; },
          json: async function () { return JSON.parse(r.body); },
        });
      },
      secrets: Object.freeze({
        get: function (key) {
          const r = JSON.parse(__osaurus_native_call("secret", JSON.stringify({ key: String(key) })));
          if (r.error) { throw new Error(r.error); }
          return r.value;
        },
      }),
      files: Object.freeze({
        list: function () {
          const r = JSON.parse(__osaurus_native_call("files.list", "{}"));
          if (r.error) { throw new Error(r.error); }
          return r.value;
        },
        read: function (handle) {
          const r = JSON.parse(__osaurus_native_call("files.read", JSON.stringify({ handle: String(handle) })));
          if (r.error) { throw new Error(r.error); }
          return r.value;
        },
        write: function (name, text) {
          const r = JSON.parse(__osaurus_native_call(
            "files.write", JSON.stringify({ name: String(name), text: String(text) })));
          if (r.error) { throw new Error(r.error); }
          return r.value;
        },
      }),
      log: function () {
        const parts = Array.prototype.map.call(arguments, function (a) {
          return typeof a === "string" ? a : JSON.stringify(a);
        });
        __osaurus_native_log(parts.join(" "));
      },
    });
    """

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
        return "{\"error\":\"unserializable\"}"
    }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Main

guard let firstLine = readLine(),
    let initMessage = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any],
    let source = initMessage["source"] as? String
else {
    finish(["error": ["message": "Missing or malformed run request."]])
}
let input = initMessage["input"] ?? NSNull()

guard let context = JSContext() else {
    finish(["error": ["message": "JavaScriptCore is unavailable."]])
}
context.name = "osaurus-code-node"

nonisolated(unsafe) var thrown: JSValue?
context.exceptionHandler = { _, exception in thrown = exception }

let nativeFetch: @convention(block) (String, String) -> String = { url, optionsJSON in
    let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
    switch call("fetch", ["url": url, "options": options]) {
    case .success(let result): return jsonString(result)
    case .failure(let error): return jsonString(["error": error.message])
    }
}
let allowedCalls: Set<String> = ["secret", "files.list", "files.read", "files.write"]
let nativeCall: @convention(block) (String, String) -> String = { method, paramsJSON in
    guard allowedCalls.contains(method) else { return jsonString(["error": "Unknown call \(method)"]) }
    let params = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any] ?? [:]
    switch call(method, params) {
    case .success(let value): return jsonString(["value": value])
    case .failure(let error): return jsonString(["error": error.message])
    }
}
let nativeLog: @convention(block) (String) -> Void = { message in
    writeLine(["method": "log", "params": ["message": message]])
}
context.setObject(nativeFetch, forKeyedSubscript: "__osaurus_native_fetch" as NSString)
context.setObject(nativeCall, forKeyedSubscript: "__osaurus_native_call" as NSString)
context.setObject(nativeLog, forKeyedSubscript: "__osaurus_native_log" as NSString)
for key in ["run", "caller"] {
    let value = initMessage[key] as? [String: Any] ?? [String: Any]()
    context.setObject(jsonString(value), forKeyedSubscript: "__osaurus_\(key)_json" as NSString)
}

func failure(from exception: JSValue?) -> [String: Any] {
    let message = exception?.toString() ?? "Unknown error"
    let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
    return ["error": ["message": message, "stack": stack == "undefined" ? "" : stack]]
}

context.evaluateScript(prelude)
context.evaluateScript(source)
if thrown != nil { finish(failure(from: thrown)) }

guard let run = context.objectForKeyedSubscript("run"), run.isObject, !run.isUndefined else {
    finish(["error": ["message": "The code must define `function run(input, ctx)`."]])
}

let inputValue = JSValue(object: input, in: context)!
let ctxValue = context.objectForKeyedSubscript("__osaurus_ctx")!

nonisolated(unsafe) var settled: [String: Any]?
let onResolve: @convention(block) (JSValue) -> Void = { value in
    if value.isUndefined {
        settled = ["result": NSNull()]
        return
    }
    let encoded = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
    guard let text = encoded?.toString(), encoded?.isUndefined == false,
        let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    else {
        settled = ["error": ["message": "run() returned a value that is not JSON-serializable."]]
        return
    }
    settled = ["result": parsed]
}
let onReject: @convention(block) (JSValue) -> Void = { reason in
    settled = failure(from: reason)
}

let returned = run.call(withArguments: [inputValue, ctxValue])
if thrown != nil { finish(failure(from: thrown)) }

// Normalize sync and async results through one promise so both settle
// the same way; JavaScriptCore drains microtasks when this call returns.
let promise = context.objectForKeyedSubscript("Promise")!.invokeMethod("resolve", withArguments: [returned as Any])
_ = promise?.invokeMethod(
    "then",
    withArguments: [
        JSValue(object: onResolve, in: context) as Any,
        JSValue(object: onReject, in: context) as Any,
    ])

if let settled { finish(settled) }
finish(["error": ["message": "run() never settled. Code nodes have no timers; await only ctx.fetch."]])
