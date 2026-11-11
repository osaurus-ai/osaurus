//
//  Teammate.swift
//  osaurus
//
//  The day-one team's fixed identities. A teammate is an ordinary agent the
//  person owns; what makes it a teammate is `Agent.sourceTemplateID` equal
//  to one of these ids. Workflow steps, worker superseding, and the
//  never-recreate check key on the id, so a renamed teammate keeps working.
//

import Foundation

public enum Teammate: String, CaseIterable, Sendable {
    case planner
    case courier
    case keeper
    case scout
    case builder

    public var templateID: UUID {
        switch self {
        case .planner: return UUID(uuidString: "EE32D938-0336-4E73-8B5E-41DBEE2ECC72")!
        case .courier: return UUID(uuidString: "8CF2099B-10C7-48EB-BB04-390CAD06273A")!
        case .keeper: return UUID(uuidString: "9D56D742-0AD5-4118-9BB8-E13D4F2A9745")!
        case .scout: return UUID(uuidString: "793CABDD-863B-4D89-9010-BA873C39CA45")!
        case .builder: return UUID(uuidString: "FE140E6C-D9EF-45A8-9963-F9C0A7115466")!
        }
    }

    public static func teammate(forTemplateID id: UUID?) -> Teammate? {
        guard let id else { return nil }
        return allCases.first { $0.templateID == id }
    }

    /// The stock dino this teammate's agent wears as its avatar. Green is
    /// the default agent's, so the five teammates split the other five.
    public var avatar: AgentMascot {
        switch self {
        case .planner: return .orange
        case .courier: return .purple
        case .keeper: return .yellow
        case .scout: return .red
        case .builder: return .blue
        }
    }

    /// The bundled template resource, `teammate-<name>.json`.
    var resourceName: String { "teammate-\(rawValue)" }

    /// The built-in worker this teammate takes the asks of while it exists.
    /// Keeper is read-only, so the Files worker stays the team's file writer.
    public var supersededWorker: BuiltInWorker? {
        switch self {
        case .scout: return .research
        case .builder: return .code
        case .planner, .courier, .keeper: return nil
        }
    }
}

extension Agent {
    /// The teammate this agent was created as, if any.
    public var teammate: Teammate? { Teammate.teammate(forTemplateID: sourceTemplateID) }

    /// The worker this agent takes the asks of: its teammate's, while it
    /// can do that worker's job. Scout with tools or web search off cannot
    /// research, so Research stays.
    public var supersededWorker: BuiltInWorker? {
        guard let worker = teammate?.supersededWorker else { return nil }
        if worker == .research, !(toolsEnabled && settings.webSearchEnabled) { return nil }
        return worker
    }
}
