//
//  NativeArtifactCardView.swift
//  osaurus
//
//  AppKit port of the SwiftUI ArtifactCardView: image / PDF / video / audio / HTML / text
//  previews with a shared header, preview surface, and action row.
//

import AppKit
import AVFoundation
@preconcurrency import PDFKit
import QuartzCore

// MARK: - NativeArtifactCardView

final class NativeArtifactCardView: NSView {

    /// match `NativeMessageCellView` / table rows — non-flipped + flipped parent breaks vertical constraints
    override var isFlipped: Bool { true }

    var onHeightChanged: (() -> Void)?
    /// taps image thumbnail → full-screen preview (wired from `CellRenderingContext.onUserImagePreview`)
    var onImagePreviewTap: ((String) -> Void)?

    private let inner = NSView()
    private let iconBg = NSView()
    private let iconBadge = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let headerRow = NSStackView()
    private let headerText = NSStackView()
    private let previewHost = NSView()
    private let footerStack = NSStackView()
    private let openInFinderButton = NSButton(title: "", target: nil, action: nil)
    private let openInBrowserButton = NSButton(title: "", target: nil, action: nil)

    private let previewImageView = NSImageView()
    private let pdfPageBadge = NSTextField(labelWithString: "")
    private let pdfBadgeBackdrop = NSView()
    private let videoPlayIcon = NSImageView()
    private let audioPlayButton = NSButton()
    private let audioTitleLabel = NSTextField(labelWithString: "")
    private let audioMetaLabel = NSTextField(labelWithString: "")
    private let htmlIcon = NSImageView()
    private let htmlTitleLabel = NSTextField(labelWithString: "")
    private let htmlSizeLabel = NSTextField(labelWithString: "")
    private let textPreviewField = NSTextField(wrappingLabelWithString: "")

    private let previewStatus = NSTextField(labelWithString: "")
    private var previewTop: NSLayoutConstraint!
    private var footerTop: NSLayoutConstraint!
    private var previewUnavailable = false

    private var borderStrokeLayer: CAShapeLayer?
    private var cardRadius: CGFloat = 0
    private var hoverOverlayLayer: CALayer?

    private var currentArtifactId: String = ""
    private var currentThemeFingerprint: Int?
    private var hostPath: String = ""
    private var isArtifactDirectory = false
    private var previewLoadTask: Task<Void, Never>?
    private var glowAnimationTask: Task<Void, Never>?

    private var boundTheme: (any ThemeProtocol)?
    private var boundArtifact: SharedArtifact?

    private var cachedLayoutHeight: CGFloat = 120
    private var measuredLayoutWidth: CGFloat = 0
    private var isHovered = false
    private var lastGlowArtifactId: String?

    private static let thumbnailHeight: CGFloat = 160
    private static let audioPlaySize: CGFloat = 36
    private static let innerPadding: CGFloat = 12
    private static let previewPadding: CGFloat = 12
    private static let iconSize: CGFloat = 24
    private static let minimumActionHeight: CGFloat = 28

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(1, cachedLayoutHeight))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        previewLoadTask?.cancel()
        glowAnimationTask?.cancel()
    }

    // MARK: - Configure

    func configure(artifact: SharedArtifact, theme: any ThemeProtocol) {
        let theme = theme.catalogFamily(37, authoritative: true)
        let themeFP = theme.renderFingerprint
        // must not skip when hostPath or other fields update for the same id (tool result arrives after first paint)
        if artifact.id == currentArtifactId, themeFP == currentThemeFingerprint, boundArtifact == artifact {
            return
        }

        currentArtifactId = artifact.id
        currentThemeFingerprint = themeFP
        hostPath = artifact.hostPath
        isArtifactDirectory = artifact.isDirectory
        boundTheme = theme
        boundArtifact = artifact

        previewLoadTask?.cancel()
        previewLoadTask = nil
        previewUnavailable = false
        clearPreviewHost()

        nameLabel.stringValue = artifact.filename
        nameLabel.toolTip = artifact.filename
        nameLabel.font = theme.nsFont(.subheading, weight: .semibold)
        nameLabel.textColor = NSColor(theme.text.primary)

        let description = artifact.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        descLabel.stringValue = description
        descLabel.toolTip = description.isEmpty ? nil : description
        descLabel.isHidden = description.isEmpty
        descLabel.font = theme.nsFont(.bodySmall)
        descLabel.textColor = NSColor(theme.text.secondary)

        iconBg.layer?.backgroundColor = NSColor(theme.surface.subtle).cgColor
        iconBg.layer?.cornerRadius = theme.radius.small
        let sym = Self.symbolName(for: artifact)
        iconBadge.image = SymbolImageCache.image(sym, accessibilityDescription: nil)
        iconBadge.contentTintColor = NSColor(theme.text.secondary)
        iconBadge.imageScaling = .scaleProportionallyUpOrDown

        let canOpen = !artifact.hostPath.isEmpty
        openInFinderButton.isHidden = !canOpen
        openInFinderButton.isEnabled = canOpen
        let showBrowser = canOpen && (artifact.isHTML || (artifact.isDirectory && Self.hasIndexHTML(artifact)))
        openInBrowserButton.isHidden = !showBrowser
        openInBrowserButton.isEnabled = showBrowser

        styleFooterButton(openInFinderButton, title: "Open in Finder", symbol: "folder", theme: theme)
        styleFooterButton(openInBrowserButton, title: "Open in Browser", symbol: "safari", theme: theme)

        updateChrome(theme: theme)
        updateFooterAlpha()

        buildPreview(for: artifact, theme: theme)
        applyInspectionStyle(theme)

        scheduleIntroGlowIfNeeded(theme: theme, artifactId: artifact.id)

        // Chat calls configure while laying out table rows. Measure without forcing layout.
        cachedLayoutHeight = cardHeight(for: bounds.width)
        invalidateIntrinsicContentSize()
        scheduleDeferredLayoutMetricsUpdate()
    }

    private func applyInspectionStyle(_ theme: any ThemeProtocol) {
        #if OSAURUS_DESIGN_SYSTEM
        catalogAssignmentTarget(
            ["background", "hover", "border", "borderWidth", "radius", "height"].map { "component.library.37." + $0 }
                + ["paddingX", "paddingTop", "paddingBottom", "headerGap", "descriptionGap", "previewGap", "footerGap", "actionGap"]
                    .map { "component.library.37.elements.layout." + $0 },
            name: "Artifact card", theme: theme
        )
        NativeComponentInspectionStyle.label(nameLabel, family: 37, property: "heading", theme: theme)
        NativeComponentInspectionStyle.label(descLabel, family: 37, property: "text", theme: theme)
        for label in [pdfPageBadge, audioMetaLabel, htmlSizeLabel, previewStatus] {
            NativeComponentInspectionStyle.label(label, family: 37, property: "caption", theme: theme)
        }
        for label in [audioTitleLabel, htmlTitleLabel] {
            NativeComponentInspectionStyle.label(label, family: 37, property: "label", theme: theme)
        }
        NativeComponentInspectionStyle.label(textPreviewField, family: 37, property: "code", theme: theme)
        #endif

        let padding = NativeComponentInspectionStyle.metric(37, "padding", Self.innerPadding, theme)
        let gap = NativeComponentInspectionStyle.metric(37, "gap", 12, theme)
        for constraint in constraints where constraint.firstItem as? NSView === inner {
            switch constraint.firstAttribute {
            case .leading: constraint.constant = layoutMetric("paddingX", padding, theme)
            case .trailing: constraint.constant = -layoutMetric("paddingX", padding, theme)
            case .top: constraint.constant = layoutMetric("paddingTop", padding, theme)
            case .bottom: constraint.constant = -layoutMetric("paddingBottom", padding, theme)
            default: break
            }
        }
        headerRow.spacing = layoutMetric("headerGap", 8, theme)
        headerText.spacing = layoutMetric("descriptionGap", 4, theme)
        footerStack.spacing = layoutMetric("actionGap", 8, theme)
        previewTop.constant = previewHost.isHidden ? 0 : layoutMetric("previewGap", gap, theme)
        footerTop.constant = footerStack.isHidden ? 0 : layoutMetric("footerGap", gap, theme)
    }

    private func layoutMetric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.catalogLayoutMetric("component.library.37.elements.layout." + property, inheriting: fallback)
    }

    private func updateLayoutMeasurements(for proposedWidth: CGFloat) {
        guard let theme = boundTheme else { return }
        let padding = NativeComponentInspectionStyle.metric(37, "padding", Self.innerPadding, theme)
        let cardWidth = proposedWidth > 1 ? proposedWidth : 420
        let contentWidth = max(1, cardWidth - 2 * layoutMetric("paddingX", padding, theme))
        let textWidth = max(1, contentWidth - Self.iconSize - headerRow.spacing)
        let previewTextWidth = max(1, contentWidth - 2 * Self.previewPadding)
        if descLabel.preferredMaxLayoutWidth != textWidth { descLabel.preferredMaxLayoutWidth = textWidth }
        if textPreviewField.preferredMaxLayoutWidth != previewTextWidth {
            textPreviewField.preferredMaxLayoutWidth = previewTextWidth
        }

        let actions = footerStack.arrangedSubviews.filter { !$0.isHidden }
        let actionsWidth = actions.reduce(CGFloat.zero) { $0 + $1.intrinsicContentSize.width }
            + CGFloat(max(0, actions.count - 1)) * footerStack.spacing
        let axis: NSUserInterfaceLayoutOrientation = actionsWidth > contentWidth && actions.count > 1 ? .vertical : .horizontal
        if footerStack.orientation != axis {
            footerStack.orientation = axis
            footerStack.alignment = axis == .vertical ? .trailing : .centerY
        }
    }

    private func cardHeight(for width: CGFloat) -> CGFloat {
        guard let theme = boundTheme else { return 1 }
        updateLayoutMeasurements(for: width)
        let padding = NativeComponentInspectionStyle.metric(37, "padding", Self.innerPadding, theme)
        return ceil(max(
            layoutMetric("paddingTop", padding, theme)
                + headerRow.fittingSize.height
                + previewTop.constant + (previewHost.isHidden ? 0 : previewHost.fittingSize.height)
                + footerTop.constant + (footerStack.isHidden ? 0 : footerStack.fittingSize.height)
                + layoutMetric("paddingBottom", padding, theme),
            NativeComponentInspectionStyle.metric(37, "height", 1, theme)
        ))
    }

    func measuredCardHeight(width: CGFloat? = nil) -> CGFloat {
        cachedLayoutHeight = cardHeight(for: width ?? bounds.width)
        return cachedLayoutHeight
    }

    private func scheduleDeferredLayoutMetricsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oldHeight = self.cachedLayoutHeight
            let height = self.measuredCardHeight()
            if abs(height - oldHeight) > 0.5 {
                self.invalidateIntrinsicContentSize()
                self.onHeightChanged?()
            }
        }
    }

    // MARK: - Chrome

    private func updateChrome(theme: any ThemeProtocol) {
        layer?.backgroundColor = NSColor(isHovered ? theme.surface.hover : theme.surface.raised).cgColor

        ensureBorderLayer()
        borderStrokeLayer?.strokeColor = NSColor(isHovered ? theme.border.default : theme.border.subtle).cgColor
        if borderStrokeLayer?.lineWidth != CGFloat(theme.stroke.default) {
            borderStrokeLayer?.lineWidth = theme.stroke.default
            needsLayout = true
        }
        if cardRadius != theme.radius.medium {
            cardRadius = theme.radius.medium
            layer?.cornerRadius = cardRadius
            needsLayout = true
        }

        hoverOverlayLayer?.backgroundColor = isHovered ? NSColor(theme.surface.hover).cgColor : NSColor.clear.cgColor
    }

    private func ensureBorderLayer() {
        if borderStrokeLayer != nil { return }
        let stroke = CAShapeLayer()
        stroke.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(stroke)
        borderStrokeLayer = stroke

        let hover = CALayer()
        hover.backgroundColor = NSColor.clear.cgColor
        layer?.insertSublayer(hover, at: 0)
        hoverOverlayLayer = hover
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 2, b.height > 2 else { return }
        if measuredLayoutWidth != b.width {
            measuredLayoutWidth = b.width
            scheduleDeferredLayoutMetricsUpdate()
        }
        borderStrokeLayer?.frame = b
        let inset = (borderStrokeLayer?.lineWidth ?? 0) / 2
        let rect = CGRect(x: inset, y: inset, width: b.width - inset * 2, height: b.height - inset * 2)
        let r = max(cardRadius - inset, 0)
        borderStrokeLayer?.path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).cgPath

        hoverOverlayLayer?.frame = b
        let mask = CAShapeLayer()
        mask.path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).cgPath
        hoverOverlayLayer?.mask = mask

    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let t = boundTheme { updateChrome(theme: t) }
        updateFooterAlpha()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if let t = boundTheme { updateChrome(theme: t) }
        updateFooterAlpha()
    }

    private func updateFooterAlpha() {
        // keep footer actions fully visible — low alpha read as "missing" on light cards
        footerStack.alphaValue = 1
    }

    private func scheduleIntroGlowIfNeeded(theme: any ThemeProtocol, artifactId: String) {
        guard lastGlowArtifactId != artifactId else { return }
        lastGlowArtifactId = artifactId
        glowAnimationTask?.cancel()
        layer?.applyThemeElevation(.none)
        glowAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = theme.motion.standardInterval
                self.layer?.applyThemeElevation(theme.elevation.raised)
                self.layer?.shadowColor = NSColor(theme.border.focus).cgColor
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = theme.motion.slowInterval
                self.layer?.applyThemeElevation(.none)
            }
        }
    }

    // MARK: - Preview host

    private func clearPreviewHost() {
        for g in previewImageView.gestureRecognizers {
            previewImageView.removeGestureRecognizer(g)
        }
        for v in previewHost.subviews {
            v.removeFromSuperview()
        }
        previewImageView.image = nil
        pdfPageBadge.isHidden = true
        pdfBadgeBackdrop.isHidden = true
    }

    private func buildPreview(for artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let hasPath = !artifact.hostPath.isEmpty
        previewHost.layer?.cornerRadius = theme.radius.medium
        previewHost.layer?.backgroundColor = NSColor(theme.surface.subtle).cgColor
        previewHost.layer?.borderColor = NSColor(theme.border.subtle).cgColor
        previewHost.layer?.borderWidth = theme.stroke.default

        if artifact.isImage, hasPath {
            buildImagePreview(artifact: artifact)
        } else if artifact.isPDF, hasPath {
            buildPDFPreview(artifact: artifact, theme: theme)
        } else if artifact.isVideo, hasPath {
            buildVideoPreview(artifact: artifact)
        } else if artifact.isAudio, hasPath {
            buildAudioPreview(artifact: artifact, theme: theme)
        } else if hasPath && (artifact.isHTML || (artifact.isDirectory && Self.hasIndexHTML(artifact))) {
            buildHTMLPreview(artifact: artifact, theme: theme)
        } else if artifact.isText, let content = artifact.content, !content.isEmpty {
            buildTextPreview(content: content, theme: theme)
        } else {
            previewHost.isHidden = true
        }
        footerStack.isHidden = openInFinderButton.isHidden && openInBrowserButton.isHidden
    }

    private func showUnavailablePreview() {
        guard let theme = boundTheme, !previewUnavailable else { return }
        previewUnavailable = true
        clearPreviewHost()
        previewStatus.stringValue = "Preview unavailable"
        previewStatus.font = theme.nsFont(.caption)
        previewStatus.textColor = NSColor(theme.text.secondary)
        addPaddedPreview(previewStatus)
        applyInspectionStyle(theme)
        scheduleDeferredLayoutMetricsUpdate()
    }

    private func buildImagePreview(artifact: SharedArtifact) {
        let iv = previewImageView
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        previewHost.addSubview(iv)

        let click = NSClickGestureRecognizer(target: self, action: #selector(artifactImagePreviewTapped))
        iv.addGestureRecognizer(click)

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            iv.topAnchor.constraint(equalTo: previewHost.topAnchor),
            iv.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
            iv.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
        ])

        if let img = ChatImageCache.shared.cachedImage(for: artifact.id) {
            iv.image = img
        } else {
            let fileURL = URL(fileURLWithPath: artifact.hostPath)
            let artId = artifact.id
            previewLoadTask = Task { [weak self] in
                let data = try? await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: fileURL)
                }.value
                guard !Task.isCancelled else { return }
                let decoded = if let data { await ChatImageCache.shared.decode(data, id: artId) } else { nil as NSImage? }
                guard !Task.isCancelled, let self, self.currentArtifactId == artId else { return }
                if let decoded { iv.image = decoded }
                else { self.showUnavailablePreview() }
            }
        }
    }

    private func buildPDFPreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(container)

        let iv = previewImageView
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iv)

        let pdfClick = NSClickGestureRecognizer(target: self, action: #selector(openArtifactWithDefaultApp))
        iv.addGestureRecognizer(pdfClick)

        pdfBadgeBackdrop.wantsLayer = true
        #if OSAURUS_DESIGN_SYSTEM
        pdfBadgeBackdrop.layer?.backgroundColor = NSColor(theme.surface.raised).cgColor
        #else
        pdfBadgeBackdrop.layer?.backgroundColor = FixedPalette.mediaScrimNS(0.6).cgColor
        #endif
        pdfBadgeBackdrop.layer?.cornerRadius = theme.radius.medium
        pdfBadgeBackdrop.translatesAutoresizingMaskIntoConstraints = false
        pdfBadgeBackdrop.isHidden = true
        container.addSubview(pdfBadgeBackdrop)

        pdfPageBadge.translatesAutoresizingMaskIntoConstraints = false
        pdfPageBadge.isEditable = false
        pdfPageBadge.isBordered = false
        pdfPageBadge.drawsBackground = false
        pdfPageBadge.font = theme.nsFont(.micro, weight: .semibold)
        #if OSAURUS_DESIGN_SYSTEM
        pdfPageBadge.textColor = NSColor(theme.text.secondary)
        #else
        pdfPageBadge.textColor = FixedPalette.onMediaNS
        #endif
        pdfPageBadge.stringValue = ""
        container.addSubview(pdfPageBadge)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            container.topAnchor.constraint(equalTo: previewHost.topAnchor),
            container.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            previewHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            iv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            pdfBadgeBackdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            pdfBadgeBackdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            pdfPageBadge.leadingAnchor.constraint(equalTo: pdfBadgeBackdrop.leadingAnchor, constant: 6),
            pdfPageBadge.trailingAnchor.constraint(equalTo: pdfBadgeBackdrop.trailingAnchor, constant: -6),
            pdfPageBadge.topAnchor.constraint(equalTo: pdfBadgeBackdrop.topAnchor, constant: 3),
            pdfPageBadge.bottomAnchor.constraint(equalTo: pdfBadgeBackdrop.bottomAnchor, constant: -3),
        ])

        let url = URL(fileURLWithPath: artifact.hostPath)
        let artId = artifact.id
        previewLoadTask = Task { [weak self] in
            let data: Data? = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            await MainActor.run {
                guard !Task.isCancelled, let self, self.currentArtifactId == artId else { return }
                guard let data, let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
                    self.showUnavailablePreview()
                    return
                }
                let count = doc.pageCount
                let thumb = page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
                iv.image = thumb
                self.pdfPageBadge.stringValue = "\(count) page\(count == 1 ? "" : "s")"
                NativeComponentInspectionStyle.label(self.pdfPageBadge, family: 37, property: "caption", theme: theme)
                self.pdfPageBadge.isHidden = false
                self.pdfBadgeBackdrop.isHidden = false
                self.scheduleDeferredLayoutMetricsUpdate()
            }
        }
    }

    private func buildVideoPreview(artifact: SharedArtifact) {
        previewHost.isHidden = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(container)

        let iv = previewImageView
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iv)

        videoPlayIcon.translatesAutoresizingMaskIntoConstraints = false
        videoPlayIcon.image = SymbolImageCache.image("play.circle.fill", accessibilityDescription: "Play")
        videoPlayIcon.contentTintColor = .white
        videoPlayIcon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(videoPlayIcon)

        let click = NSClickGestureRecognizer(target: self, action: #selector(openArtifactWithDefaultApp))
        container.addGestureRecognizer(click)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            container.topAnchor.constraint(equalTo: previewHost.topAnchor),
            container.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            previewHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            iv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            videoPlayIcon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            videoPlayIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            videoPlayIcon.widthAnchor.constraint(equalToConstant: 44),
            videoPlayIcon.heightAnchor.constraint(equalToConstant: 44),
        ])

        let url = URL(fileURLWithPath: artifact.hostPath)
        let artId = artifact.id
        previewLoadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 800, height: 600)
            do {
                let (cgImage, _) = try await gen.image(at: .zero)
                let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run {
                    guard !Task.isCancelled, let self, self.currentArtifactId == artId else { return }
                    iv.image = img
                }
            } catch {
                guard !Task.isCancelled, let self, self.currentArtifactId == artId else { return }
                self.showUnavailablePreview()
            }
        }
    }

    private func buildAudioPreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        audioPlayButton.translatesAutoresizingMaskIntoConstraints = false
        audioPlayButton.isBordered = false
        audioPlayButton.image = SymbolImageCache.image("play.fill", accessibilityDescription: "Play")
        audioPlayButton.contentTintColor = NSColor(theme.action.primary.default.foreground)
        audioPlayButton.target = self
        audioPlayButton.action = #selector(openArtifactWithDefaultApp)

        let circle = NSView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor(theme.action.primary.default.background).cgColor
        circle.layer?.cornerRadius = Self.audioPlaySize / 2
        circle.addSubview(audioPlayButton)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: Self.audioPlaySize),
            circle.heightAnchor.constraint(equalToConstant: Self.audioPlaySize),
            audioPlayButton.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            audioPlayButton.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            audioPlayButton.widthAnchor.constraint(equalToConstant: 14),
            audioPlayButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        audioTitleLabel.stringValue = "Audio"
        audioTitleLabel.font = theme.nsFont(.label, weight: .medium)
        audioTitleLabel.textColor = NSColor(theme.text.primary)
        audioTitleLabel.maximumNumberOfLines = 1
        audioTitleLabel.lineBreakMode = .byTruncatingTail

        audioMetaLabel.stringValue = Self.formatSize(artifact.fileSize)
        audioMetaLabel.font = theme.nsFont(.caption)
        audioMetaLabel.textColor = NSColor(theme.text.secondary)

        let textCol = NSStackView()
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.addArrangedSubview(audioTitleLabel)
        textCol.addArrangedSubview(audioMetaLabel)

        row.addArrangedSubview(circle)
        row.addArrangedSubview(textCol)
        addPaddedPreview(row)

        let url = URL(fileURLWithPath: artifact.hostPath)
        let artId = artifact.id
        previewLoadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                guard seconds.isFinite, seconds > 0 else { return }
                let mins = Int(seconds) / 60
                let secs = Int(seconds) % 60
                let formatted = String(format: "%d:%02d", mins, secs)
                await MainActor.run {
                    guard !Task.isCancelled, let self, self.currentArtifactId == artId else { return }
                    self.audioMetaLabel.stringValue = "\(formatted) · \(Self.formatSize(artifact.fileSize))"
                    NativeComponentInspectionStyle.label(self.audioMetaLabel, family: 37, property: "caption", theme: theme)
                    self.scheduleDeferredLayoutMetricsUpdate()
                }
            } catch {
                // The file size still identifies the audio when duration is unavailable.
            }
        }
    }

    private func buildHTMLPreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        htmlIcon.image = SymbolImageCache.image("globe", accessibilityDescription: nil)
        htmlIcon.contentTintColor = NSColor(theme.text.secondary)
        htmlIcon.imageScaling = .scaleProportionallyUpOrDown

        htmlTitleLabel.stringValue = "Web page"
        htmlTitleLabel.font = theme.nsFont(.label, weight: .medium)
        htmlTitleLabel.textColor = NSColor(theme.text.primary)

        htmlSizeLabel.stringValue = Self.formatSize(artifact.fileSize)
        htmlSizeLabel.font = theme.nsFont(.caption)
        htmlSizeLabel.textColor = NSColor(theme.text.secondary)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(htmlIcon)
        row.addArrangedSubview(htmlTitleLabel)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(htmlSizeLabel)

        addPaddedPreview(row)
        NSLayoutConstraint.activate([
            htmlIcon.widthAnchor.constraint(equalToConstant: 14),
            htmlIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func buildTextPreview(content: String, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let lines = content.components(separatedBy: "\n").prefix(6)
        textPreviewField.stringValue = lines.joined(separator: "\n")
        textPreviewField.font = theme.nsFont(.footnote, family: .code)
        textPreviewField.textColor = NSColor(theme.text.secondary)
        textPreviewField.maximumNumberOfLines = 6
        textPreviewField.translatesAutoresizingMaskIntoConstraints = false
        textPreviewField.isEditable = false
        textPreviewField.isSelectable = true
        textPreviewField.isBordered = false
        textPreviewField.isBezeled = false
        textPreviewField.drawsBackground = false
        textPreviewField.focusRingType = .none
        textPreviewField.wantsLayer = false
        textPreviewField.lineBreakMode = .byWordWrapping

        addPaddedPreview(textPreviewField)
    }

    private func addPaddedPreview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor, constant: Self.previewPadding),
            view.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor, constant: -Self.previewPadding),
            view.topAnchor.constraint(equalTo: previewHost.topAnchor, constant: Self.previewPadding),
            view.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor, constant: -Self.previewPadding),
        ])
    }

    // MARK: - Actions

    @objc private func openInFinderTapped() {
        guard !hostPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hostPath)])
    }

    @objc private func openInBrowserTapped() {
        guard !hostPath.isEmpty else { return }
        let url: URL
        if isArtifactDirectory {
            url = URL(fileURLWithPath: hostPath).appendingPathComponent("index.html")
        } else {
            url = URL(fileURLWithPath: hostPath)
        }
        // Async variant avoids a synchronous LaunchServices XPC round-trip
        // that can hang the main thread.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openArtifactWithDefaultApp() {
        guard !hostPath.isEmpty else { return }
        NSWorkspace.shared.open(
            URL(fileURLWithPath: hostPath), configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func artifactImagePreviewTapped() {
        guard !currentArtifactId.isEmpty else { return }
        onImagePreviewTap?(currentArtifactId)
    }

    // MARK: - Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)

        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.wantsLayer = true
        iconBg.layer?.masksToBounds = true

        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBg.addSubview(iconBadge)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.isEditable = false
        descLabel.isBordered = false
        descLabel.drawsBackground = false
        descLabel.maximumNumberOfLines = 2
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.addArrangedSubview(nameLabel)
        headerText.addArrangedSubview(descLabel)

        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.setContentHuggingPriority(.required, for: .vertical)
        headerRow.setContentCompressionResistancePriority(.required, for: .vertical)

        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.wantsLayer = true
        previewHost.layer?.masksToBounds = true

        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.orientation = .horizontal
        footerStack.spacing = 8
        footerStack.alignment = .centerY
        footerStack.addArrangedSubview(openInBrowserButton)
        footerStack.addArrangedSubview(openInFinderButton)

        openInFinderButton.target = self
        openInFinderButton.action = #selector(openInFinderTapped)
        openInBrowserButton.target = self
        openInBrowserButton.action = #selector(openInBrowserTapped)

        headerRow.addArrangedSubview(iconBg)
        headerRow.addArrangedSubview(headerText)

        // preview draws first (behind) so header/footer stay visible if frames ever disagree
        inner.addSubview(previewHost)
        inner.addSubview(headerRow)
        inner.addSubview(footerStack)

        previewTop = previewHost.topAnchor.constraint(equalTo: headerRow.bottomAnchor)
        footerTop = footerStack.topAnchor.constraint(equalTo: previewHost.bottomAnchor)

        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.innerPadding),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.innerPadding),
            inner.topAnchor.constraint(equalTo: topAnchor, constant: Self.innerPadding),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.innerPadding),

            headerRow.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: inner.topAnchor),

            iconBg.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconBg.heightAnchor.constraint(equalToConstant: Self.iconSize),

            iconBadge.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconBadge.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 12),
            iconBadge.heightAnchor.constraint(equalToConstant: 12),

            previewHost.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            previewTop,

            footerStack.leadingAnchor.constraint(greaterThanOrEqualTo: inner.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            footerTop,
            inner.bottomAnchor.constraint(equalTo: footerStack.bottomAnchor),

            openInFinderButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumActionHeight),
            openInBrowserButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumActionHeight),
        ])
        let emptyPreview = previewHost.heightAnchor.constraint(equalToConstant: 0)
        emptyPreview.priority = .defaultLow
        emptyPreview.isActive = true
    }

    private func styleFooterButton(_ button: NSButton, title: String, symbol: String, theme: any ThemeProtocol) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.font = theme.nsFont(.footnote, weight: .medium)
        button.contentTintColor = NSColor(theme.text.secondary)
        button.title = title
        button.image = SymbolImageCache.image(symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        NativeComponentInspectionStyle.button(button, family: 37, property: "label", theme: theme)
    }

    // MARK: - Helpers

    private static func hasIndexHTML(_ artifact: SharedArtifact) -> Bool {
        guard artifact.isDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: artifact.hostPath).appendingPathComponent("index.html").path
        )
    }

    private static func symbolName(for artifact: SharedArtifact) -> String {
        if artifact.isDirectory { return "folder.fill" }
        if artifact.isImage { return "photo" }
        if artifact.isPDF { return "doc.richtext.fill" }
        switch artifact.officeDocumentKind {
        case .wordProcessing: return "doc.text.fill"
        case .spreadsheet: return "tablecells.fill"
        case .presentation: return "rectangle.on.rectangle.angled.fill"
        case nil: break
        }
        if artifact.isVideo { return "film" }
        if artifact.isAudio { return "waveform" }
        if artifact.isHTML { return "globe" }
        if artifact.isText { return "doc.text" }
        return "doc"
    }


    private static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
