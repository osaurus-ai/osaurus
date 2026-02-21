//
//  SignalDetector.swift
//  osaurus
//
//  Regex-based pattern matching to detect high-signal user messages
//  that should trigger immediate memory extraction (Path 1).
//  No LLM calls — runs synchronously on every user message.
//

import Foundation

public enum SignalDetector: Sendable {

    private static let patterns: [(SignalType, [String])] = [
        (
            .explicitMemory,
            [
                "remember this", "remember that", "remember me", "remember my",
                "please remember", "don't forget", "do not forget",
                "keep in mind", "make a note", "note that",
            ]
        ),
        (
            .correction,
            [
                "actually,", "actually ", "no i meant", "no, i meant",
                "that's wrong", "that is wrong", "that's not right",
                "i was wrong", "correction:", "to clarify,",
            ]
        ),
        (
            .identity,
            [
                "my name is", "i'm called", "i am called", "call me",
                "i work at", "i work for", "my job is",
                "i'm a ", "i am a ",
                "i live in", "i'm from", "i am from",
                "my email is", "my phone is",
                "i am ", "i'm ",
                "my birthday is", "my birthday's", "i was born", "my age is",
            ]
        ),
        (
            .preference,
            [
                "i prefer", "i always", "i never",
                "i like to", "i like ", "i don't like", "i do not like",
                "i hate when", "i love when", "i love ", "i hate ",
                "my favorite", "my favourite",
            ]
        ),
        (
            .decision,
            [
                "let's go with", "let us go with",
                "i decided", "i've decided", "i have decided",
                "we'll use", "we will use", "the plan is",
            ]
        ),
        (
            .commitment,
            [
                "by friday", "by monday", "by tuesday", "by wednesday",
                "by thursday", "by saturday", "by sunday",
                "deadline is", "due date is", "due by",
                "by end of", "by eod", "by eow",
            ]
        ),
    ]

    /// Scans a user message and returns all detected signal types.
    /// Runs in O(n*p) where n = message length and p = number of patterns.
    public static func detect(in message: String) -> [SignalType] {
        let lower = message.lowercased()
        var found: Set<SignalType> = []

        for (signalType, phrases) in patterns {
            for phrase in phrases {
                if lower.contains(phrase) {
                    found.insert(signalType)
                    break
                }
            }
        }

        return Array(found)
    }

    /// Returns true if the message contains any high-signal pattern.
    public static func hasSignals(in message: String) -> Bool {
        !detect(in: message).isEmpty
    }
}
