//
//  DinoDirector.swift
//  osaurus
//
//  Drives one on-screen dinosaur: loads its own artboard, state machine,
//  and view-model instance from the shared `dino.riv` file, then exposes
//  costume changes, animation triggers, facing, and speech (mouth shapes
//  timed to text) as plain method calls.
//

import AppKit
import Foundation
import RiveRuntime

/// The parsed `dino.riv`, loaded once per process. Every dino on screen
/// shares one worker and one file and creates its own artboard from it.
@MainActor
enum DinoRuntime {
    private static var loading: Task<File, Error>?

    static func file() async throws -> File {
        if let loading { return try await loading.value }
        let task = Task { @MainActor () throws -> File in
            guard let url = Bundle.module.url(forResource: "dino", withExtension: "riv") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let data = try Data(contentsOf: url)
            let worker = try await Worker()
            return try await File(source: .data(data), worker: worker)
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }
}

@MainActor
final class DinoDirector: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var rive: Rive?
    @Published private(set) var costume: DinoCostume
    @Published private(set) var facingLeft: Bool
    @Published private(set) var current: DinoAction = .idleFront
    /// Paused while the dino is off screen or its window is hidden.
    @Published var isPaused = false

    private var instance: ViewModelInstance?
    private var loadTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var reactionTask: Task<Void, Never>?
    private var lastTurn = Date.distantPast
    /// The last request made before the file finished loading.
    private var pendingAction: DinoAction?

    init(costume: DinoCostume = .guide, facingLeft: Bool = false) {
        self.costume = costume
        self.facingLeft = facingLeft
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Loading

    /// Idempotent; the view calls it when it appears.
    func load() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            do {
                let file = try await DinoRuntime.file()
                let artboard = try await file.createArtboard()
                let stateMachine = try await artboard.createStateMachine()
                let instance = try await file.createViewModelInstance(
                    .viewModelDefault(from: .artboardDefault(artboard)))
                guard let self else { return }
                self.instance = instance
                self.applyCostume(self.costume)
                try await stateMachine.bindViewModelInstances(main: instance)
                let rive = try await Rive(file: file, artboard: artboard, stateMachine: stateMachine)
                if self.facingLeft { instance.fire(trigger: TriggerProperty(path: "flipLeft")) }
                self.rive = rive
                self.phase = .ready
                if let pending = self.pendingAction {
                    self.pendingAction = nil
                    self.fire(pending)
                }
            } catch {
                self?.phase = .failed
            }
        }
    }

    // MARK: Look

    func wear(_ costume: DinoCostume) {
        guard costume != self.costume else { return }
        self.costume = costume
        applyCostume(costume)
    }

    func wear(headwear: DinoHeadwear) {
        var next = costume
        next.headwear = headwear
        wear(next)
    }

    func wear(bodywear: DinoBodywear) {
        var next = costume
        next.bodywear = bodywear
        wear(next)
    }

    func express(_ expression: DinoExpression) {
        var next = costume
        next.expression = expression
        wear(next)
    }

    private func applyCostume(_ costume: DinoCostume) {
        guard let instance else { return }
        instance.setValue(of: NumberProperty(path: "characterSelect"), to: Float(costume.species.rawValue))
        instance.setValue(of: NumberProperty(path: "headwear"), to: Float(costume.headwear.rawValue))
        instance.setValue(of: NumberProperty(path: "bodywear"), to: Float(costume.bodywear.rawValue))
        instance.setValue(of: NumberProperty(path: "expressions"), to: Float(costume.expression.rawValue))
    }

    /// The file's facing triggers are persistent toggles.
    func face(left: Bool) {
        guard left != facingLeft else { return }
        facingLeft = left
        instance?.fire(trigger: TriggerProperty(path: left ? "flipLeft" : "flipRight"))
    }

    /// Turns toward a pointer at `x` when the dino stands at `center`, with
    /// a margin and a pause between turns so it does not flicker.
    func look(toward x: CGFloat, from center: CGFloat) {
        guard Date().timeIntervalSince(lastTurn) > 0.6 else { return }
        let margin: CGFloat = 24
        if x < center - margin, !facingLeft {
            face(left: true)
            lastTurn = Date()
        } else if x > center + margin, facingLeft {
            face(left: false)
            lastTurn = Date()
        }
    }

    // MARK: Animation

    /// Plays an animation. Travel and big moves are skipped under Reduce
    /// Motion; the dino rests instead.
    func play(_ action: DinoAction) {
        stopSpeaking()
        let resolved = reduceMotion && action.isVigorous ? .idleFront : action
        fire(resolved)
    }

    /// A click on the dino: a random reaction. Looping ones wind down on
    /// their own unless something else plays first.
    func poke() {
        let reactions = DinoAction.pokeReactions.filter { !reduceMotion || !$0.isVigorous }
        guard let reaction = reactions.randomElement() else { return }
        play(reaction)
        reactionTask?.cancel()
        guard reaction.isLoop else { return }
        reactionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled, self.current == reaction else { return }
            self.rest()
        }
    }

    /// Back to the standing idle, ending any loop.
    func rest() {
        stopSpeaking()
        fire(.idleFront)
    }

    private func fire(_ action: DinoAction) {
        current = action
        guard let instance else {
            pendingAction = action
            return
        }
        instance.fire(trigger: TriggerProperty(path: action.rawValue))
    }

    // MARK: Speech

    /// Talks through `text`, one mouth shape per sound, then rests.
    /// Returns how long the speech takes.
    @discardableResult
    func speak(_ text: String, shapeDuration: TimeInterval = 0.075) -> TimeInterval {
        stopSpeaking()
        let shapes = DinoViseme.sequence(for: text)
        let duration = Double(shapes.count) * shapeDuration
        fire(.talking)
        speechTask = Task { [weak self] in
            for shape in shapes {
                guard let self, !Task.isCancelled else { return }
                self.instance?.setValue(of: NumberProperty(path: "visemes"), to: Float(shape.rawValue))
                try? await Task.sleep(for: .seconds(shapeDuration))
            }
            guard let self, !Task.isCancelled else { return }
            self.speechTask = nil
            self.fire(.idleFront)
        }
        return duration
    }

    func stopSpeaking() {
        guard let speechTask else { return }
        speechTask.cancel()
        self.speechTask = nil
        instance?.setValue(of: NumberProperty(path: "visemes"), to: Float(DinoViseme.closed.rawValue))
    }
}
