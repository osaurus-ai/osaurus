//
//  SettingsKitAccessibilityTests.swift
//  osaurusTests
//
//  Source contracts for what VoiceOver gets from the kit. SwiftUI only
//  publishes its accessibility tree to a connected assistive client, so
//  these read the kit's source the way `SettingsKitLintTests` does:
//  label-less controls must be named, icon-only controls must read their
//  tooltip, and movement must respect Reduce Motion.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SettingsKitAccessibilityTests {
    static let kit = SettingsKitLintTests.packageRoot.appendingPathComponent("Views/DesignSystem")

    static func kitSources() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(at: kit, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsKitGallery.swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The text of `struct <name>` up to the next top-level declaration.
    static func structBody(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "struct \(name)") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// `Toggle("", …)` / `Picker("", …)` hide their label from sight; the
    /// row title must reach VoiceOver through `.accessibilityLabel`.
    @Test func labelHiddenControlsAreNamed() throws {
        var unnamed: [String] = []
        for (name, text) in try Self.kitSources() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains(/\b(Toggle|Picker)\("",/) {
                let window = lines[index...min(index + 10, lines.count - 1)].joined(separator: "\n")
                if !window.contains(".accessibilityLabel(") {
                    unnamed.append("\(name):\(index + 1)")
                }
            }
        }
        #expect(unnamed.isEmpty, "Label-hidden control without .accessibilityLabel: \(unnamed)")
    }

    @Test func iconOnlyControlsReadTheirTooltip() throws {
        let buttons = try String(
            contentsOf: Self.kit.appendingPathComponent("SettingsButtons.swift"),
            encoding: .utf8
        )
        let iconButton = try #require(Self.structBody("SettingsIconButton: View", in: buttons))
        #expect(iconButton.contains(".settingsAccessibilityLabel(help)"))
        let overflow = try #require(Self.structBody("SettingsOverflowMenu<", in: buttons))
        #expect(overflow.contains(".accessibilityLabel("))
    }

    @Test func pickerRowNamesBothStyles() throws {
        let rows = try String(contentsOf: Self.kit.appendingPathComponent("SettingsRow.swift"), encoding: .utf8)
        let pickerRow = try #require(Self.structBody("SettingsPickerRow<", in: rows))
        let segmented = try #require(pickerRow.range(of: "case .segmented:"))
        let menu = try #require(pickerRow.range(of: "case .menu:"))
        let segmentedBody = pickerRow[segmented.upperBound..<menu.lowerBound]
        let menuBody = pickerRow[menu.upperBound...]
        func labels(_ text: Substring) -> Int { text.components(separatedBy: ".accessibilityLabel(").count - 1 }
        // One name per build branch of the segmented control.
        #expect(labels(segmentedBody) == segmentedBody.components(separatedBy: "#else").count)
        #expect(labels(menuBody) == 1)
    }

    @Test func findingRowReadsItsSeverity() throws {
        let finding = try String(
            contentsOf: Self.kit.appendingPathComponent("SettingsFindingRow.swift"),
            encoding: .utf8
        )
        #expect(finding.contains(".accessibilityValue("))
        #expect(finding.contains(".accessibilityHidden(true)"))
    }

    /// Movement (offsets, scale, springs, repeating glows) must stay still
    /// under Reduce Motion; hover colour fades are not movement.
    @Test func kitMotionReadsReduceMotion() throws {
        var offenders: [String] = []
        for (name, text) in try Self.kitSources() {
            let moves = text.contains(
                /repeatForever|\.spring\(|\.scaleEffect\(|\.offset\([xy]:|\.transition\(\.(move|scale|slide|offset)/
            )
            if moves && !text.contains("accessibilityReduceMotion") {
                offenders.append(name)
            }
        }
        #expect(offenders.isEmpty, "Kit motion without a Reduce Motion check: \(offenders.sorted())")
    }
}
