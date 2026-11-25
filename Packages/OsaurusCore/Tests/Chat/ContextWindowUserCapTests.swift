//
//  ContextWindowUserCapTests.swift
//  OsaurusCoreTests
//
//  "If the user changes it in settings it takes effect."
//
//  It did not. `ChatConfiguration.contextLength` is documented as a default
//  "for models with unknown limits" and sits LAST in the resolution chain, so
//  it only applies when neither the bundle nor the provider declares a window.
//  Every local bundle declares one, so lowering that number changed nothing —
//  the setting existed, was editable, was saved, and was inert.
//
//  `contextLengthCap` is the setting that actually constrains. It is separate
//  rather than a reinterpretation of the old field because that field defaults
//  to 128k: treating it as a cap would silently clamp a 222k model to 128k on
//  update, which nobody asked for.
//
//  The parity tests matter as much as the cap itself. The sync twin feeds the
//  send gate and the context chip; the async twin feeds the agent loop and the
//  subagent runner. A cap honoured by only one means the number a user SEES
//  and the number their agents RUN UNDER disagree.
//

import XCTest

@testable import OsaurusCore

final class ContextWindowUserCapTests: XCTestCase {

    private typealias Resolution = AgentLoopBudget.ContextWindowResolution

    private func resolution(_ tokens: Int, _ source: AgentLoopBudget.ContextWindowSource)
        -> Resolution
    {
        Resolution(tokens: tokens, source: source)
    }

    // MARK: - Lowering

    func testSavedContextCapSurvivesDecodingAndStillConstrainsTheModel() throws {
        for cap: Int? in [nil, 8_192, 131_072] {
            let original = ChatConfiguration(
                hotkey: nil, systemPrompt: "", contextLength: 128_000,
                contextLengthCap: cap)
            let decoded = try JSONDecoder().decode(
                ChatConfiguration.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.contextLengthCap, cap)
            XCTAssertEqual(decoded.contextLength, 128_000)
            let effective = AgentLoopBudget.applyingUserCap(
                resolution(222_000, .bundleMetadata), cap: decoded.contextLengthCap)
            XCTAssertEqual(effective.tokens, cap ?? 222_000)
        }
    }

    func testOlderSettingsWithoutACapContinueFollowingTheModel() throws {
        let legacy = Data(#"{"systemPrompt":"","contextLength":128000}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: legacy)
        XCTAssertNil(decoded.contextLengthCap)
        XCTAssertEqual(decoded.contextLength, 128_000)
    }

    func testCapLowersAModelDeclaredWindow() {
        let capped = AgentLoopBudget.applyingUserCap(
            resolution(222_000, .bundleMetadata), cap: 32_000)
        XCTAssertEqual(capped.tokens, 32_000)
        XCTAssertEqual(capped.source, .userCap, "the chip must say the cap decided this")
    }

    func testCapAppliesToProviderWindowsToo() {
        let capped = AgentLoopBudget.applyingUserCap(
            resolution(200_000, .providerMetadata), cap: 8_000)
        XCTAssertEqual(capped.tokens, 8_000)
        XCTAssertEqual(capped.source, .userCap)
    }

    // MARK: - Never raising

    /// A cap above the model's window is ignored. Raising it is not a
    /// preference — the weights cannot honour it, and the result is incoherent
    /// output rather than more context.
    func testCapAboveTheModelWindowIsIgnored() {
        let untouched = AgentLoopBudget.applyingUserCap(
            resolution(8_192, .bundleMetadata), cap: 500_000)
        XCTAssertEqual(untouched.tokens, 8_192)
        XCTAssertEqual(untouched.source, .bundleMetadata, "source must not claim a cap applied")
    }

    func testCapEqualToTheWindowChangesNothing() {
        let untouched = AgentLoopBudget.applyingUserCap(
            resolution(32_768, .bundleMetadata), cap: 32_768)
        XCTAssertEqual(untouched.tokens, 32_768)
        XCTAssertEqual(untouched.source, .bundleMetadata)
    }

    // MARK: - Degenerate values

    /// Nil is the default and must be completely invisible.
    func testNoCapLeavesResolutionUntouched() {
        for source in [
            AgentLoopBudget.ContextWindowSource.foundationFixed,
            .bundleMetadata, .providerMetadata, .metadataFallback,
        ] {
            let r = resolution(65_536, source)
            let out = AgentLoopBudget.applyingUserCap(r, cap: nil)
            XCTAssertEqual(out, r, "a nil cap changed a \(source) resolution")
        }
    }

    /// A zero or negative cap must not produce a zero-token window — that
    /// would be an invented limit that blocks generation entirely.
    func testNonPositiveCapIsIgnoredRatherThanZeroingTheWindow() {
        for bad in [0, -1, -100_000] {
            let out = AgentLoopBudget.applyingUserCap(
                resolution(32_768, .bundleMetadata), cap: bad)
            XCTAssertEqual(out.tokens, 32_768, "cap \(bad) collapsed the window")
        }
    }

    // MARK: - Both twins, one answer

    /// The regression guard: both resolvers must route through the same
    /// helper. If one stops applying the cap, the send gate and the agent loop
    /// silently disagree about how much context exists.
    func testBothResolverTwinsApplyTheCap() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Services/Chat/AgentToolLoop.swift"),
            encoding: .utf8)

        func body(of name: String) throws -> String {
            let start = try XCTUnwrap(src.range(of: "static func \(name)("))
            return String(src[start.lowerBound...].prefix(2400))
        }

        for twin in ["resolveContextWindowResolution", "resolveContextWindowResolutionSync"] {
            let b = try body(of: twin)
            XCTAssertTrue(
                b.contains("applyingContextCaps("),
                "\(twin) does not apply the user cap — the twins disagree")
            XCTAssertTrue(
                b.contains("contextLengthCap"),
                "\(twin) never reads the cap setting")
            XCTAssertTrue(
                b.contains("agentContextLengthCap"),
                "\(twin) never receives the per-agent cap")
        }
    }

    /// The cap must reach the surfaces the user actually experiences: the
    /// agent loop's budget, the subagent runner, and the plugin host all take
    /// their window from `resolveContextWindow`, so covering that one entry
    /// point covers all three.
    func testAgentSurfacesTakeTheirWindowFromTheCappedResolver() throws {
        for (path, symbol) in [
            ("Services/AgentDelegation/AgentSubagentRunner.swift", "resolveContextWindow("),
            ("Services/Plugin/PluginHostAPI.swift", "resolveContextWindow("),
            ("Services/Context/AgentLoopEvaluator.swift", "resolveContextWindow("),
        ] {
            let src = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(path),
                encoding: .utf8)
            XCTAssertTrue(
                src.contains(symbol),
                "\(path) resolves its context window some other way — it would miss the cap")
        }
    }

    // MARK: - The old field stays a fallback

    /// The effective window is the tightest of the agent cap, the global cap,
    /// and the model window. The chip's source names whichever cap decided.
    func testAgentCapAndGlobalCapTakeTheMinimum() {
        let model = resolution(262_144, .bundleMetadata)

        let agentOnly = AgentLoopBudget.applyingContextCaps(
            model, globalCap: nil, agentCap: 32_768)
        XCTAssertEqual(agentOnly.tokens, 32_768)
        XCTAssertEqual(agentOnly.source, .agentCap)

        let globalTighter = AgentLoopBudget.applyingContextCaps(
            model, globalCap: 16_384, agentCap: 32_768)
        XCTAssertEqual(globalTighter.tokens, 16_384)
        XCTAssertEqual(globalTighter.source, .userCap)

        let agentTighter = AgentLoopBudget.applyingContextCaps(
            model, globalCap: 65_536, agentCap: 32_768)
        XCTAssertEqual(agentTighter.tokens, 32_768)
        XCTAssertEqual(agentTighter.source, .agentCap)

        let anotherAgent = AgentLoopBudget.applyingContextCaps(
            model, globalCap: nil, agentCap: nil)
        XCTAssertEqual(anotherAgent.tokens, 262_144)
        XCTAssertEqual(anotherAgent.source, .bundleMetadata)

        let equal = AgentLoopBudget.applyingContextCaps(
            model, globalCap: 32_768, agentCap: 32_768)
        XCTAssertEqual(equal.tokens, 32_768)
        XCTAssertEqual(equal.source, .agentCap, "an equal agent cap is the one the chip names")
    }

    func testAgentCapAboveTheModelWindowIsIgnored() {
        let untouched = AgentLoopBudget.applyingContextCaps(
            resolution(8_192, .bundleMetadata), globalCap: nil, agentCap: 32_768)
        XCTAssertEqual(untouched.tokens, 8_192)
        XCTAssertEqual(untouched.source, .bundleMetadata)
    }

    func testNonPositiveAgentCapInherits() {
        for bad in [0, -1] {
            let out = AgentLoopBudget.applyingContextCaps(
                resolution(32_768, .bundleMetadata), globalCap: 8_192, agentCap: bad)
            XCTAssertEqual(out.tokens, 8_192)
            XCTAssertEqual(out.source, .userCap)
        }
    }

    func testOverBudgetMessageNamesTheCapThatDecided() {
        let agent = AgentToolLoop.overBudgetMessage(windowSource: .agentCap)
        XCTAssertTrue(agent.contains("generation_settings.context_length_cap"))
        let global = AgentToolLoop.overBudgetMessage(windowSource: .userCap)
        XCTAssertTrue(global.contains("Context Window Cap"))
        XCTAssertFalse(global.contains("generation_settings"))
        XCTAssertEqual(
            AgentToolLoop.overBudgetMessage(windowSource: .bundleMetadata),
            AgentToolLoop.overBudgetMessage)
    }

    /// The surfaces that show or run a window must pass the agent cap into
    /// the shared resolver. A call that only passes the model id would keep
    /// that surface on the full window while the others honor the agent.
    func testNamedSurfacesPassTheAgentCap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Views/Chat/ChatView.swift",
            "Views/Chat/FloatingInputCard.swift",
            "Services/AgentDelegation/AgentSubagentRunner.swift",
            "Subagent/Kinds/TextSubagentKind.swift",
            "Networking/HTTPHandler.swift",
            "Services/Plugin/PluginHostAPI.swift",
            "Services/MobileConnect/PhoneContextUsage.swift",
            "ComputerUse/Loop/ComputerUseLoop.swift",
            "AppleScript/Loop/AppleScriptLoop.swift",
            "Services/Context/AgentLoopEvaluator.swift",
            "Tools/Handoff/HiddenAgentHandoffRunner.swift",
            "Services/Context/CapabilityClaimsEvaluator.swift",
        ]
        for path in paths {
            let src = try String(
                contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(
                src.contains("agentContextLengthCap"),
                "\(path) resolves a context window without the agent cap")
        }
        let browser = try String(
            contentsOf: root.appendingPathComponent("Subagent/Kinds/BrowserUseKind.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            browser.contains("generationSettings:"),
            "browser use runs without the target agent's generation settings")
    }

    /// `contextLength` must NOT become a cap. It defaults to 128k, so treating
    /// it as one would clamp every longer-context model on update.
    func testTheFallbackFieldIsNotTreatedAsACap() {
        var config = ChatConfiguration.default
        config.contextLength = 8_000
        config.contextLengthCap = nil

        let out = AgentLoopBudget.applyingUserCap(
            resolution(222_000, .bundleMetadata), cap: config.contextLengthCap)
        XCTAssertEqual(
            out.tokens, 222_000,
            "the fallback field constrained a model that declares its own window")
    }
}
