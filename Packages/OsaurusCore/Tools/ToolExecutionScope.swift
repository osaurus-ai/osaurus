//
//  ToolExecutionScope.swift
//  osaurus
//
//  Binds what a request EXPOSED to the model to what it is allowed to EXECUTE.
//

import Foundation

/// The set of tools one request is allowed to run.
///
/// Exposure and execution were never bound to each other. The prompt decided which tools the
/// model was *told* about, but nothing stopped it from naming one it had never been shown: the
/// parser records any name once at least one schema is present, and `ToolRegistry` then executed
/// it, because the registry believed access control had already happened upstream. It had not. A
/// sandbox / plugin / MCP tool deliberately withheld from an agent would run if the model simply
/// guessed its name — and tools fired in the app with the tools toggle visibly **off**.
///
/// A plain `Set` is not enough, because it would break a feature that works today.
/// `capabilities_load` and `sandbox_plugin_register` deliberately make tools callable **mid-run**
/// while the rendered `<tools>` block stays frozen (rewriting it would bust the paged-KV prefix for
/// the whole conversation). So authorization has to be able to *grow* during the run — hence a
/// mutable scope that owns both the initial grant and any same-run activations, rather than an
/// immutable snapshot that would silently kill capability loading.
///
/// Activations live **here**, not in the process-wide `CapabilityLoadBuffer`: that buffer is
/// global, so two concurrent requests can drain each other's activations and authorize a tool the
/// other one loaded.
final class ToolExecutionScope: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Set<String>

    /// Seed from the FINAL model-visible schema — the specs that survived every agent, mode and
    /// composer gate. Not from the registry, not from `builtInToolNames`, not from
    /// `runtimeManagedToolNames`: those are supersets of what this request was allowed to see, and
    /// unioning them back in would re-open the hole this exists to close.
    init(exposed specs: [Tool]) {
        self.allowed = Set(specs.map { $0.function.name })
    }

    /// Is this tool authorized for this request?
    func permits(_ name: String) -> Bool {
        lock.withLock { allowed.contains(name) }
    }

    /// Authorize a tool that this run activated after the schema was frozen
    /// (`capabilities_load`, `sandbox_plugin_register`). The model was told about it in the tool
    /// result, so it is legitimately callable — it simply is not in the frozen `<tools>` block.
    func activate(_ names: [String]) {
        guard !names.isEmpty else { return }
        lock.withLock { allowed.formUnion(names) }
    }

    /// Everything currently authorized. Diagnostics only.
    var authorizedNames: Set<String> {
        lock.withLock { allowed }
    }
}
