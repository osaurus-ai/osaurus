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
/// A plain `Set` is not enough, because `capabilities` and `sandbox_plugin_register` deliberately
/// make tools callable **mid-run**. The scope therefore grows both the execution grant and the
/// model-visible schema for the next iteration. Keeping only the grant stranded constrained
/// decoders: they could reason about the loaded tool from the result, but could emit only names
/// still present in the request schema and substituted an unrelated hot tool instead.
///
/// Activations live **here**, not in the process-wide `CapabilityLoadBuffer`: that buffer is
/// global, so two concurrent requests can drain each other's activations and authorize a tool the
/// other one loaded.
final class ToolExecutionScope: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Set<String>
    private var specs: [Tool]

    /// Seed from the FINAL model-visible schema — the specs that survived every agent, mode and
    /// composer gate. Not from the registry, not from `builtInToolNames`, not from
    /// `runtimeManagedToolNames`: those are supersets of what this request was allowed to see, and
    /// unioning them back in would re-open the hole this exists to close.
    init(exposed specs: [Tool]) {
        self.allowed = Set(specs.map { $0.function.name })
        self.specs = specs
    }

    /// Is this tool authorized for this request?
    func permits(_ name: String) -> Bool {
        lock.withLock { allowed.contains(name) }
    }

    /// Authorize names when only an execution grant is available.
    func activate(_ names: [String]) {
        guard !names.isEmpty else { return }
        lock.withLock { allowed.formUnion(names) }
    }

    /// Authorize and publish newly loaded schemas for the next model iteration.
    /// Existing names retain their original schema and order; genuinely new
    /// tools append in loader order for deterministic request construction.
    func activate(_ loadedSpecs: [Tool]) {
        guard !loadedSpecs.isEmpty else { return }
        lock.withLock {
            for spec in loadedSpecs {
                let name = spec.function.name
                guard allowed.insert(name).inserted else { continue }
                specs.append(spec)
            }
        }
    }

    /// Current request schema: initial hot tools plus same-run activations.
    var modelVisibleSpecs: [Tool] {
        lock.withLock { specs }
    }

    /// Everything currently authorized. Diagnostics only.
    var authorizedNames: Set<String> {
        lock.withLock { allowed }
    }
}
