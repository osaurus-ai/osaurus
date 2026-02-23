//
//  MemoryLogger.swift
//  osaurus
//
//  Structured logger for the memory subsystem using os.Logger.
//  Zero-cost when not collected; filterable in Console.app / Instruments.
//

import Foundation
import os

public enum MemoryLogger {
    static let service = Logger(subsystem: "ai.osaurus", category: "memory.service")
    static let search = Logger(subsystem: "ai.osaurus", category: "memory.search")
    static let database = Logger(subsystem: "ai.osaurus", category: "memory.database")
    static let config = Logger(subsystem: "ai.osaurus", category: "memory.config")
}
