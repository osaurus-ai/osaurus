//
//  StatsPack.swift
//  OsaurusStatsPack
//
//  First-party statistics/data-science format pack for the v1 in-process
//  plugin adapter ABI.
//

import Foundation
import OsaurusCore

/// The pack keeps registration explicit so hosts can choose when plugin
/// startup happens and duplicate format claims still fail during boot.
public enum StatsPack {
    public static let name = "OsaurusStatsPack"

    public static func registerAdapters(into registry: FormatAdapterRegistry = .shared) throws {
        try registry.register(CSVWithSchemaAdapter.self) { CSVWithSchemaAdapter() }
        try registry.register(TSVStatsAdapter.self) { TSVStatsAdapter() }
        try registry.register(JSONLAdapter.self) { JSONLAdapter() }
        try registry.register(SQLiteReadOnlyAdapter.self) { SQLiteReadOnlyAdapter() }
    }
}
