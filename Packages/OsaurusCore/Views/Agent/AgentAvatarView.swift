//
//  AgentAvatarView.swift
//  osaurus
//
//  Reusable agent avatar that shows a mascot image when one is picked, and
//  falls back to the agent name's first-letter monogram otherwise.
//

import AppKit
import SwiftUI

/// Catalog of mascot avatars shipped with the app. The `id` is what gets
/// persisted on `Agent.avatar`. `assetName` resolves to an imageset in
/// `OsaurusCore/Resources/Assets.xcassets`
public enum AgentMascot: String, CaseIterable, Identifiable, Sendable {
    case blue, green, orange, purple, red, yellow

    public var id: String { rawValue }
    public var assetName: String { "osaurus-avatar-\(rawValue)" }

    /// The dino's signature color, used to theme surfaces around the mascot
    /// (e.g. the onboarding hero glow, avatar tint, and selection ring) so
    /// the UI reacts in the selected dino's actual color rather than a
    /// name-hash approximation.
    public var color: Color {
        switch self {
        case .blue: return Color(red: 0.30, green: 0.56, blue: 0.92)
        case .green: return Color(red: 0.36, green: 0.72, blue: 0.42)
        case .orange: return Color(red: 0.95, green: 0.58, blue: 0.24)
        case .purple: return Color(red: 0.62, green: 0.42, blue: 0.92)
        case .red: return Color(red: 0.91, green: 0.38, blue: 0.36)
        case .yellow: return Color(red: 0.95, green: 0.78, blue: 0.27)
        }
    }

    /// Human-friendly label for accessibility / tooltip surfaces. Avoids
    /// leaking the raw enum case (`"blue"`) into help text — the avatar
    /// strip in onboarding used to read `"Avatar: blue"`.
    public var displayName: String {
        switch self {
        case .blue: return "Blue dino"
        case .green: return "Green dino"
        case .orange: return "Orange dino"
        case .purple: return "Purple dino"
        case .red: return "Red dino"
        case .yellow: return "Yellow dino"
        }
    }

    /// Asset name for the "create-pose" illustration paired with this
    /// mascot color (used by the onboarding Create Agent step).
    ///
    /// NOTE: the yellow asset ships with a typo in the imageset name
    /// (`osuarus-yellow-create` instead of `osaurus-yellow-create`).
    /// We reference the actual filename so the image loads — rename the
    /// imageset upstream if you want to fix it.
    public var createPoseAssetName: String {
        switch self {
        case .yellow: return "osuarus-yellow-create"
        default: return "osaurus-\(rawValue)-create"
        }
    }
}

/// Renders an agent avatar at the given diameter. Uses the mascot image when
/// `mascotId` matches a known `AgentMascot` otherwise draws a tinted circle
/// with the first letter of `name` (or `?` when name is empty)
struct AgentAvatarView: View {
    let mascotId: String?
    let name: String
    let tint: Color
    let diameter: CGFloat
    /// Optional user-supplied custom avatar image. When present, takes
    /// precedence over `mascotId` and the monogram fallback.
    var customImageURL: URL? = nil
    /// Font size for the monogram fallback. Callers tune this so the letter
    /// reads at the same visual weight as before per call site
    var monogramFontSize: CGFloat = 16
    var borderWidth: CGFloat = 2
    /// When true, the mascot illustration fills the circle edge-to-edge
    /// (no inner inset). Use for hero treatments; leave default for small
    /// list/sidebar avatars where the inset reads as more iconic.
    var bleedsToEdge: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.2), tint.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url = customImageURL, let nsImage = AvatarImageCache.shared.image(for: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else if let mascot = mascotId.flatMap(AgentMascot.init(rawValue:)) {
                let mascotImage = Image(mascot.assetName, bundle: .module)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                if bleedsToEdge {
                    mascotImage.scaledToFill()
                } else {
                    mascotImage.scaledToFit().padding(diameter * 0.08)
                }
            } else {
                Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                    .font(.system(size: monogramFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(tint)
            }

            Circle()
                .strokeBorder(tint.opacity(0.5), lineWidth: borderWidth)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

// MARK: - Avatar Image Cache

/// Tiny URL→NSImage cache keyed by (path, modification-date). Custom avatars
/// live on disk and are read by both SwiftUI and AppKit avatar surfaces; we
/// avoid hitting the filesystem on every body re-evaluation.
final class AvatarImageCache: @unchecked Sendable {
    static let shared = AvatarImageCache()

    private struct Entry {
        let mtime: Date
        let image: NSImage
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func image(for url: URL) -> NSImage? {
        let path = url.path
        let mtime =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast

        lock.lock()
        if let hit = entries[path], hit.mtime == mtime {
            lock.unlock()
            return hit.image
        }
        lock.unlock()

        guard let image = NSImage(contentsOf: url) else { return nil }
        lock.lock()
        entries[path] = Entry(mtime: mtime, image: image)
        lock.unlock()
        return image
    }

    func invalidate(url: URL) {
        lock.lock()
        entries.removeValue(forKey: url.path)
        lock.unlock()
    }
}
