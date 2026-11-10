//
//  SearchDebounce.swift
//  osaurus
//
//  Shared pause between the last keystroke and a search that scans a
//  whole list, so typing a word runs the scan once instead of per letter.

import Foundation

enum SearchDebounce {
    static let interval: Duration = .milliseconds(150)
}
