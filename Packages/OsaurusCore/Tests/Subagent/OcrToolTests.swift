//
//  OcrToolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free guardrail tests for the `ocr` sub-agent tool + its registry
//  descriptor, mirroring `SpawnToolTests` / `SubagentCapabilityRegistryTests`.
//  The full nested OCR run needs a live VLM (covered by the eval suite); these
//  pin everything that must hold without one: the unified recursion guard,
//  argument validation, the registry-timeout opt-out, the registry SSOT, the
//  per-agent visibility/model resolvers, and the OCR config round-trips.
//

import Foundation
import Testing

@testable import OsaurusCore

struct OcrToolTests {

    // MARK: - Tool entry contract

    @Test func refusesRecursion() async throws {
        // A running sub-agent of ANY kind blocks a nested `ocr` (the unified
        // host guard, shared across the family).
        let result = try await SubagentSession.$activeKindId.withValue("image") {
            try await OcrTool().execute(argumentsJSON: #"{"images":["/tmp/a.png"]}"#)
        }
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("cannot be called from inside"))
    }

    @Test func rejectsMissingImages() async throws {
        let result = try await OcrTool().execute(argumentsJSON: #"{}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("images"))
    }

    @Test func rejectsMalformedArguments() async throws {
        let result = try await OcrTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(result))
    }

    @Test func bypassesRegistryTimeout() {
        #expect(OcrTool().bypassRegistryTimeout)
    }

    @Test func toolSchema() {
        let tool = OcrTool()
        #expect(tool.name == "ocr")
        // `images` is the one required argument.
        guard case .object(let root)? = tool.parameters,
            case .array(let required)? = root["required"]
        else {
            Issue.record("ocr tool parameters missing required array")
            return
        }
        #expect(required.contains(.string("images")))
    }

    // MARK: - Kind shape

    @Test func kindShape() {
        let kind = OcrSubagentKind(
            params: OcrJobParams(imagePaths: ["/tmp/a.png"], model: nil, prompt: nil),
            argumentsJSON: #"{"images":["/tmp/a.png"]}"#
        )
        #expect(kind.capability.id == "ocr")
        #expect(kind.capability.toolNames == ["ocr"])
        // OCR has its own configured model (like image), not the parent's.
        #expect(kind.capability.modelSource == .dedicatedConfigured)
        #expect(kind.feedTitle.contains("ocr"))
    }

    @Test func loadImagesRejectsTooMany() {
        let many = (0..<(OcrSubagentKind.maxImages + 1)).map { "/tmp/\($0).png" }
        #expect(throws: OcrInputError.self) {
            _ = try OcrSubagentKind.loadImages(paths: many)
        }
    }

    // MARK: - Registry SSOT

    @Test func registryDescriptor() {
        let ocr = SubagentCapabilityRegistry.ocr
        #expect(ocr.id == "ocr")
        #expect(ocr.toolNames == ["ocr"])
        #expect(ocr.perAgentFlag == .ocr)
        #expect(ocr.modelSource == .dedicatedConfigured)
        #expect(ocr.displayLabel == "OCR")
        #expect(!ocr.iconName.isEmpty)
        #expect(ocr.guidance?.isEmpty == false)
    }

    @Test func registryLookupsResolveOcr() {
        #expect(SubagentCapabilityRegistry.capability(forToolName: "ocr")?.id == "ocr")
        #expect(SubagentCapabilityRegistry.capability(forKindId: "ocr")?.id == "ocr")
        #expect(SubagentToolVisibility.delegationToolNames.contains("ocr"))
        #expect(SubagentCapabilityRegistry.delegationFamily.contains { $0.id == "ocr" })
    }

    // MARK: - Per-agent visibility + model resolution

    @Test func ocrAvailableDefaultVsCustom() {
        let on = SubagentConfiguration(ocrDelegationEnabled: true)
        let off = SubagentConfiguration(ocrDelegationEnabled: false)
        // Default / main chat → its own OCR switch.
        #expect(SubagentToolVisibility.ocrAvailable(isDefault: true, config: on, perAgentEnabled: false))
        #expect(!SubagentToolVisibility.ocrAvailable(isDefault: true, config: off, perAgentEnabled: true))
        // Custom agent → its own per-agent toggle (config switch is irrelevant).
        #expect(SubagentToolVisibility.ocrAvailable(isDefault: false, config: off, perAgentEnabled: true))
        #expect(!SubagentToolVisibility.ocrAvailable(isDefault: false, config: on, perAgentEnabled: false))
    }

    @Test func effectiveOcrModelDefaultVsCustom() {
        let config = SubagentConfiguration(ocrDelegationEnabled: true, defaultOcrModelId: "global-ocr")
        // Default / main chat → global configured default.
        #expect(
            SubagentToolVisibility.effectiveOcrModel(isDefault: true, config: config, settings: nil)
                == "global-ocr"
        )
        // Custom agent → its own per-agent model.
        var settings = AgentSettings.defaultDisabled
        settings.ocrModelId = "agent-ocr"
        #expect(
            SubagentToolVisibility.effectiveOcrModel(isDefault: false, config: config, settings: settings)
                == "agent-ocr"
        )
    }

    // MARK: - Config round-trips

    @Test func agentSettingsOcrRoundTrip() throws {
        var settings = AgentSettings.defaultDisabled
        settings.ocrEnabled = true
        settings.ocrModelId = "deepseek-ocr"
        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.ocrEnabled)
        #expect(decoded.ocrModelId == "deepseek-ocr")
    }

    @Test func subagentConfigurationOcrRoundTrip() throws {
        let config = SubagentConfiguration(ocrDelegationEnabled: true, defaultOcrModelId: "unlimited-ocr")
        let decoded = try JSONDecoder().decode(
            SubagentConfiguration.self,
            from: JSONEncoder().encode(config)
        )
        #expect(decoded.ocrDelegationEnabled)
        #expect(decoded.defaultOcrModelId == "unlimited-ocr")
        #expect(decoded.ocrDelegationActive)
    }
}
