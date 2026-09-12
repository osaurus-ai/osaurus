//
//  EditableTextViewSpellCheckTests.swift
//  osaurusTests
//
//  Settings ▸ Chat ▸ "Check Spelling While Typing" drives the composer's
//  NSTextView spell checking. Pin the mapping: the flag toggles continuous
//  spell + grammar checking and nothing else (autocorrect and smart
//  substitutions stay off so text is never rewritten under the user).
//

import AppKit
import Testing

@testable import OsaurusCore

@MainActor
struct EditableTextViewSpellCheckTests {
    @Test("enabling turns on continuous spell and grammar checking only")
    func enableFlipsSpellAndGrammar() {
        let textView = CustomNSTextView(usingTextLayoutManager: false)
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false

        EditableTextView.applySpellCheck(true, to: textView)
        #expect(textView.isContinuousSpellCheckingEnabled)
        #expect(textView.isGrammarCheckingEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
    }

    @Test("disabling turns it off and clears any spelling underline already drawn")
    func disableClearsMarks() {
        let textView = CustomNSTextView(usingTextLayoutManager: false)
        textView.string = "teh quick brown fox"
        EditableTextView.applySpellCheck(true, to: textView)
        // Simulate the checker having flagged the first word.
        textView.layoutManager?.addTemporaryAttribute(
            .spellingState,
            value: NSAttributedString.SpellingState.spelling.rawValue,
            forCharacterRange: NSRange(location: 0, length: 3)
        )

        EditableTextView.applySpellCheck(false, to: textView)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
        let remaining = textView.layoutManager?.temporaryAttribute(
            .spellingState,
            atCharacterIndex: 0,
            effectiveRange: nil
        )
        #expect(remaining == nil)
    }

    @Test("the setting defaults to off and reads back what was stored")
    func settingDefaultAndReadBack() {
        let key = ComposerSpellCheckSetting.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(ComposerSpellCheckSetting.isEnabled == false)
        UserDefaults.standard.set(true, forKey: key)
        #expect(ComposerSpellCheckSetting.isEnabled == true)
    }
}
