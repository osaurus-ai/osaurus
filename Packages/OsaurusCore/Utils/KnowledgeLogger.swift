//
//  KnowledgeLogger.swift
//  osaurus
//
//  Structured logger for the knowledge subsystem using os.Logger.
//  Zero-cost when not collected; filterable in Console.app / Instruments.
//

import Foundation
import os

public enum KnowledgeLogger {
    static let database = Logger(subsystem: "ai.osaurus", category: "knowledge.database")
    static let index = Logger(subsystem: "ai.osaurus", category: "knowledge.index")
    static let search = Logger(subsystem: "ai.osaurus", category: "knowledge.search")
}
