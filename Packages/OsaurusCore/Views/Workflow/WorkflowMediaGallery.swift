//
//  WorkflowMediaGallery.swift
//  osaurus
//
//  The images and videos a run made, as a grid. A tile opens the lightbox:
//  the file large (zoom and pan for images, a player for video), the
//  settings that made it, and Save, Copy, Open, and Show in Finder, with
//  the arrow keys stepping through the run's media. Copy Settings puts the
//  file's settings on the clipboard as a media step, seed fixed, to paste
//  into a draft or hand to the Architect.
//

import AVKit
import AppKit
import ImageIO
import SwiftUI

/// What the gallery shows and does, kept apart from the views for tests.
enum WorkflowMediaGalleryModel {
    /// The run's media files that can be shown, in run order.
    static func items(_ files: [WorkflowArtifact]) -> [WorkflowArtifact] {
        files.filter { $0.isMedia && $0.isAvailable }
    }

    /// Node id → the last image each step made, for the graph.
    static func thumbnails(_ run: WorkflowRun) -> [String: String] {
        var out: [String: String] = [:]
        for file in run.artifacts where file.source == .generated && file.isImage && file.isAvailable {
            if let node = file.nodeID { out[node] = file.path }
        }
        return out
    }

    /// The index `offset` away from `index`, wrapping.
    static func step(_ index: Int, by offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + offset) % count + count) % count
    }

    /// The file's settings as label and value, in reading order.
    static func settingsLines(_ metadata: [String: JSONValue]?) -> [(label: String, value: String)] {
        guard let m = metadata else { return [] }
        func text(_ key: String) -> String? {
            guard let v = m[key] else { return nil }
            if case .number(let n) = v {
                return n.rounded() == n ? String(Int(n)) : String(format: "%.2f", n)
            }
            return v.stringValue ?? v.compactJSONString
        }
        var out: [(String, String)] = []
        if let v = text("prompt") { out.append((L("Prompt"), v)) }
        if let v = text("negative_prompt") { out.append((L("Negative Prompt"), v)) }
        if let v = text("model") { out.append((L("Model"), v)) }
        if let w = text("width"), let h = text("height") { out.append((L("Size"), "\(w) × \(h)")) }
        if let v = text("seed") { out.append((L("Seed"), v)) }
        if let v = text("steps") {
            let asked = text("requested_steps").map { " " + L("(asked for \($0))") } ?? ""
            out.append((L("Steps"), v + asked))
        }
        if let v = text("guidance") { out.append((L("Guidance"), v)) }
        if let v = text("sampler") { out.append((L("Sampler"), v)) }
        if let v = text("scheduler") { out.append((L("Scheduler"), v)) }
        if let v = text("shift") { out.append((L("Shift"), v)) }
        if let v = text("strength") { out.append((L("Strength"), v)) }
        if let v = text("scale") { out.append((L("Scale"), "\(v)×")) }
        if let v = text("frame_count") { out.append((L("Frames"), v)) }
        if let v = text("fps") { out.append((L("Frame Rate"), L("\(v) fps"))) }
        if let v = text("duration") { out.append((L("Duration"), v)) }
        if let v = text("resolution") { out.append((L("Resolution"), v)) }
        return out
    }

    /// A media step that makes this file again: same model, prompt, and
    /// parameters, with its seed fixed.
    static func reusableSpec(_ metadata: [String: JSONValue]?) -> MediaSpec? {
        guard let m = metadata, let action = m["action"]?.stringValue.flatMap(MediaAction.init(rawValue:)) else {
            return nil
        }
        func int(_ key: String) -> MediaValue<Int>? { m[key].flatMap(Int.init(json:)).map { .value($0) } }
        func double(_ key: String) -> MediaValue<Double>? { m[key].flatMap(Double.init(json:)).map { .value($0) } }
        let seed = int("seed")
        return MediaSpec(
            action: action,
            model: MediaModelSelector(
                family: m["family"]?.stringValue, id: m["model_id"]?.stringValue,
                locality: m["backend"]?.stringValue == "remote" ? .remote : .local),
            prompt: m["prompt"]?.stringValue ?? "",
            negativePrompt: m["negative_prompt"]?.stringValue,
            sources: m["sources"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            width: int("width"), height: int("height"), steps: int("steps"), guidance: double("guidance"),
            strength: double("strength"), seed: seed, seedMode: seed == nil ? nil : .fixed,
            format: m["format"]?.stringValue.flatMap(ImageOutputFormat.init(rawValue:)).flatMap { $0 == .png ? nil : $0 },
            scale: int("scale"), duration: m["duration"]?.stringValue, resolution: m["resolution"]?.stringValue,
            aspectRatio: m["aspect_ratio"]?.stringValue,
            sampler: m["sampler"]?.stringValue, scheduler: m["scheduler"]?.stringValue, shift: double("shift"),
            frameCount: int("frame_count"), fps: int("fps"))
    }

    /// `reusableSpec` as the JSON of a media step.
    static func settingsJSON(_ file: WorkflowArtifact) -> String? {
        let metadata = file.metadata ?? (file.isImage ? MediaNodeExecutor.readPNGSettings(URL(fileURLWithPath: file.path)) : nil)
        guard let spec = reusableSpec(metadata) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(spec), let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        else { return nil }
        return JSONValue.object(["kind": .string("media"), "media": json]).prettyJSONString
    }

    /// Where Save All puts `file` inside `folder`, never overwriting.
    static func destination(for file: WorkflowArtifact, in folder: URL, taken: Set<String>) -> URL {
        let base = (file.filename as NSString).deletingPathExtension
        let ext = (file.filename as NSString).pathExtension
        var name = file.filename
        var n = 2
        while taken.contains(name) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return folder.appendingPathComponent(name)
    }
}

struct WorkflowMediaGallery: View {
    let files: [WorkflowArtifact]

    @Environment(\.theme) private var theme
    @State private var openIndex: Int?

    private static let tile: CGFloat = 112

    var body: some View {
        let items = WorkflowMediaGalleryModel.items(files)
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Text(verbatim: items.contains(where: \.isVideo) ? L("Media") : L("Images"))
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.secondary)
                Text(verbatim: "\(items.count)")
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                if items.count > 1 {
                    SettingsButton(.secondary, "Save All…", icon: "square.and.arrow.down.on.square", size: .compact) {
                        WorkflowMediaActions.saveAll(items)
                    }
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tile, maximum: Self.tile * 1.6), spacing: theme.space.s8)],
                alignment: .leading, spacing: theme.space.s8
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, file in
                    WorkflowMediaTile(file: file) { openIndex = index }
                }
            }
        }
        .sheet(
            isPresented: Binding(get: { openIndex != nil }, set: { if !$0 { openIndex = nil } })
        ) {
            WorkflowMediaLightbox(items: items, index: openIndex ?? 0) { openIndex = nil }
                .imageFullScreenSheetPresentation()
        }
    }
}

private struct WorkflowMediaTile: View {
    let file: WorkflowArtifact
    let onOpen: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                WorkflowMediaThumbnail(path: file.path, isVideo: file.isVideo)
                    .aspectRatio(1, contentMode: .fit)
                if file.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(FixedPalette.onMedia)
                        .themeElevation(theme.elevation.overlay)
                        .padding(theme.space.s6)
                } else if let seed = file.metadata?["seed"].flatMap(Int.init(json:)) {
                    Text(verbatim: L("Seed \(seed)"))
                        .font(SettingsFont.footnote)
                        .foregroundColor(FixedPalette.onMedia)
                        .themeElevation(theme.elevation.raised)
                        .padding(theme.space.s6)
                }
            }
            .settingsChrome(.inset)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .strokeBorder(hovering ? theme.border.strong : theme.border.default))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering = $0 }
        .help(Text(verbatim: file.metadata?["prompt"]?.stringValue ?? file.filename))
        .assignedContextMenu { WorkflowMediaActions.menu(file) }
    }
}

/// A file's thumbnail, decoded off the main thread at the size shown.
struct WorkflowMediaThumbnail: View {
    let path: String
    var isVideo = false
    /// A fixed square; nil fills the space it is given.
    var side: CGFloat?

    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        content
            .frame(width: side, height: side)
            .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: side.map { $0 < 40 ? theme.radius.small : theme.radius.medium } ?? theme.radius.medium))
            .task(id: path) {
                failed = false
                image = await WorkflowMediaThumbnailCache.thumbnail(path: path, isVideo: isVideo, maxPixel: 360)
                failed = image == nil
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if failed {
            Image(systemName: isVideo ? "exclamationmark.triangle" : "photo.badge.exclamationmark")
                .foregroundColor(theme.text.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface.subtle)
                .help(L("This file is missing or can't be opened."))
        } else {
            Image(systemName: isVideo ? "film" : "photo")
                .foregroundColor(theme.text.disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface.subtle)
        }
    }
}

enum WorkflowMediaThumbnailCache {
    /// Costs are decoded bytes, so a long sweep of large thumbnails evicts
    /// rather than growing without bound.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    static func removeAll() {
        cache.removeAllObjects()
    }

    static func thumbnail(path: String, isVideo: Bool, maxPixel: Int) async -> NSImage? {
        let key = "\(path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await decode(path: path, isVideo: isVideo, maxPixel: maxPixel)
        if let image {
            let cost = Int(image.size.width * image.size.height) * 4
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// The file decoded at most `maxPixel` on its long side, off the main
    /// thread. Uncached; the lightbox uses it for its one large image.
    static func decode(path: String, isVideo: Bool, maxPixel: Int) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let url = URL(fileURLWithPath: path)
            let cg: CGImage?
            if isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
                cg = try? await generator.image(at: .zero).image
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            return cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }.value
    }
}

/// A running step's progress: a bar when it knows how far along it is,
/// and what it is doing ("Image step 12 of 30 · ~8s left").
struct WorkflowNodeProgressLine: View {
    let progress: WorkflowNodeProgress

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s8) {
            if let png = progress.previewPNG, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: Self.previewSide, maxHeight: Self.previewSide)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.small))
                    .accessibilityLabel(Text("Live preview", bundle: .module))
            }
            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                if let fraction = progress.fraction {
                    SettingsProgressBar(value: fraction)
                }
                if !progress.detail.isEmpty {
                    Text(verbatim: progress.detail)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
    }

    private static let maxWidth: CGFloat = 320
    private static let previewSide: CGFloat = 56
}

// MARK: - Lightbox

struct WorkflowMediaLightbox: View {
    let items: [WorkflowArtifact]
    @State var index: Int
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @FocusState private var focused: Bool

    private var file: WorkflowArtifact? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                FixedPalette.mediaBackdrop
                if let file, file.isVideo {
                    if let player { VideoPlayer(player: player) }
                } else {
                    ImageFullScreenView(image: image, altText: "", onDismiss: onClose)
                        .id(index)
                }
                if items.count > 1 {
                    HStack {
                        arrow("chevron.left", help: L("Previous")) { move(-1) }
                        Spacer()
                        arrow("chevron.right", help: L("Next")) { move(1) }
                    }
                    .padding(theme.space.s16)
                }
            }
            if let file { infoBar(file) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { focused = true }
        .task(id: index) { await load() }
        .onDisappear { player?.pause() }
    }

    /// Twice the largest screen's pixels: sharp when zoomed in a step,
    /// without decoding a whole 4K batch at full size.
    private static var displayMaxPixel: Int {
        let screens = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return Int(min(8192, max(2048, (screens.max() ?? 2048) * 2)))
    }

    private func arrow(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(SettingsFont.cardTitle)
                .foregroundColor(FixedPalette.onMedia.opacity(0.85))
                .frame(width: Self.arrowSide, height: Self.arrowSide)
                .background(Circle().fill(FixedPalette.mediaScrim(0.45)))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: help))
    }

    private static let arrowSide: CGFloat = 36

    private func infoBar(_ file: WorkflowArtifact) -> some View {
        let lines = WorkflowMediaGalleryModel.settingsLines(file.metadata)
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Text(verbatim: file.filename)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if items.count > 1 {
                    Text(verbatim: L("\(index + 1) of \(items.count)"))
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                WorkflowMediaActions.buttons(file, image: image)
                SettingsIconButton("xmark", help: L("Close"), size: .compact, action: onClose)
            }
            if !lines.isEmpty {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: theme.space.s12, verticalSpacing: theme.settingsTitleToDescription) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            GridRow {
                                Text(verbatim: line.label)
                                    .font(SettingsFont.smallLabel)
                                    .foregroundColor(theme.text.tertiary)
                                Text(verbatim: line.value)
                                    .font(SettingsFont.caption)
                                    .foregroundColor(theme.text.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.infoMaxHeight)
            }
        }
        .padding(theme.space.s16)
        .background(theme.surface.canvas)
    }

    private static let infoMaxHeight: CGFloat = 140

    private func move(_ offset: Int) {
        guard items.count > 1 else { return }
        index = WorkflowMediaGalleryModel.step(index, by: offset, count: items.count)
    }

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        guard let file else { return }
        let url = URL(fileURLWithPath: file.path)
        if file.isVideo {
            player = AVPlayer(url: url)
        } else {
            image = await WorkflowMediaThumbnailCache.decode(path: url.path, isVideo: false, maxPixel: Self.displayMaxPixel)
        }
    }
}

// MARK: - Actions

@MainActor
enum WorkflowMediaActions {
    @ViewBuilder
    static func buttons(_ file: WorkflowArtifact, image: NSImage?) -> some View {
        let url = URL(fileURLWithPath: file.path)
        HStack(spacing: ThemeManager.shared.currentTheme.space.s6) {
            SettingsIconButton("arrow.down.to.line", help: L("Save As…"), size: .compact) { saveAs(file) }
            if file.isImage {
                SettingsIconButton("doc.on.doc", help: L("Copy Image"), size: .compact) {
                    ImageActions.copyImageFileToClipboard(at: url)
                }
            }
            if WorkflowMediaGalleryModel.settingsJSON(file) != nil {
                SettingsIconButton("slider.horizontal.3", help: L("Copy Settings as a Media Step"), size: .compact) {
                    copySettings(file)
                }
            }
            SettingsIconButton("arrow.up.forward.app", help: L("Open"), size: .compact) {
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            }
            SettingsIconButton("folder", help: L("Show in Finder"), size: .compact) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    @ViewBuilder
    static func menu(_ file: WorkflowArtifact) -> some View {
        let url = URL(fileURLWithPath: file.path)
        Button(L("Open")) { NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) }
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        if file.isImage {
            Button(L("Copy Image")) { ImageActions.copyImageFileToClipboard(at: url) }
        }
        if WorkflowMediaGalleryModel.settingsJSON(file) != nil {
            Button(L("Copy Settings as a Media Step")) { copySettings(file) }
        }
        Button(L("Save As…")) { saveAs(file) }
    }

    static func copySettings(_ file: WorkflowArtifact) {
        guard let json = WorkflowMediaGalleryModel.settingsJSON(file) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        ToastManager.shared.success(L("Settings Copied"))
    }

    static func saveAs(_ file: WorkflowArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.filename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let source = URL(fileURLWithPath: file.path)
            Task { @MainActor in
                if let problem = await copy(source, to: destination) {
                    ToastManager.shared.error(L("Couldn't save \(file.filename)"), message: problem)
                } else {
                    ToastManager.shared.action(
                        L("Saved"), message: destination.lastPathComponent, action: .revealInFinder(destination),
                        buttonTitle: L("Reveal in Finder"))
                }
            }
        }
    }

    static func saveAll(_ files: [WorkflowArtifact]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Save Here")
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                var taken: Set<String> = []
                var saved = 0
                var firstProblem: String?
                for file in files {
                    let destination = WorkflowMediaGalleryModel.destination(for: file, in: folder, taken: taken)
                    taken.insert(destination.lastPathComponent)
                    if let problem = await copy(URL(fileURLWithPath: file.path), to: destination) {
                        firstProblem = firstProblem ?? "\(file.filename): \(problem)"
                    } else {
                        saved += 1
                    }
                }
                if saved == files.count {
                    ToastManager.shared.action(
                        L("Saved \(saved) files"), message: folder.lastPathComponent,
                        action: .revealInFinder(folder), buttonTitle: L("Reveal in Finder"))
                } else {
                    ToastManager.shared.error(
                        L("Saved \(saved) of \(files.count) files"), message: firstProblem)
                }
            }
        }
    }

    /// Nil when copied, else why not.
    private static func copy(_ source: URL, to destination: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
                return nil
            } catch {
                return WorkflowErrorText.text(error)
            }
        }.value
    }
}

#if OSAURUS_DESIGN_SYSTEM
@MainActor func inspectorWorkflowMediaContext(_ path: String, action: @escaping () -> Void) -> some View {
    WorkflowMediaTile(file: WorkflowArtifact(id: "local-media-menu", source: .generated, filename: "menu-image.png", mimeType: "image/png", path: path, metadata: ["action": .string("generate"), "prompt": .string("Local sample"), "seed": .number(42)]), onOpen: action)
        .frame(width: 180, height: 180)
}
#endif
