//
//  NativeArtifactCardView.swift
//  osaurus
//
//  AppKit port of the SwiftUI ArtifactCardView: image / PDF / video / audio / HTML / text
//  previews, gradient icon, capsule type pill, hover border + footer fade, intro glow.
//

import AppKit
import AVFoundation
@preconcurrency import PDFKit
import QuartzCore

// MARK: - NativeArtifactCardView

final class NativeArtifactCardView: NSView {

    var onHeightChanged: (() -> Void)?

    private let accentStrip = NSView()
    private let iconBg = NSView()
    private let iconGradient = CAGradientLayer()
    private let iconBadge = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let typePillContainer = NSView()
    private let typePillLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
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

    private var previewTopToDesc: NSLayoutConstraint?
    private var previewTopToName: NSLayoutConstraint?
    private var previewEmptyHeightConstraint: NSLayoutConstraint?

    private var borderStrokeLayer: CAShapeLayer?
    private var hoverOverlayLayer: CALayer?

    private var currentArtifactId: String = ""
    private var currentThemeFingerprint: String = ""
    private var hostPath: String = ""
    private var isArtifactDirectory = false
    private var previewLoadTask: Task<Void, Never>?
    private var glowAnimationTask: Task<Void, Never>?

    private var boundTheme: (any ThemeProtocol)?
    private var boundArtifact: SharedArtifact?

    private var cachedLayoutHeight: CGFloat = 120
    private var isHovered = false
    private var lastGlowArtifactId: String?

    private static let thumbnailHeight: CGFloat = 160
    private static let innerPadding: CGFloat = 12

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
        let themeFP = Self.themeFingerprint(theme)
        guard artifact.id != currentArtifactId || themeFP != currentThemeFingerprint else { return }

        currentArtifactId = artifact.id
        currentThemeFingerprint = themeFP
        hostPath = artifact.hostPath
        isArtifactDirectory = artifact.isDirectory
        boundTheme = theme
        boundArtifact = artifact

        previewLoadTask?.cancel()
        previewLoadTask = nil
        previewEmptyHeightConstraint?.isActive = false
        previewEmptyHeightConstraint = nil
        clearPreviewHost()

        nameLabel.stringValue = artifact.filename
        nameLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.bodySize), weight: .semibold)
        nameLabel.textColor = NSColor(theme.primaryText)

        typePillLabel.stringValue = artifact.categoryLabel
        typePillLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        typePillLabel.textColor = NSColor(theme.tertiaryText)
        typePillContainer.layer?.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.6).cgColor

        if let desc = artifact.description, !desc.isEmpty {
            descLabel.stringValue = desc
            descLabel.isHidden = false
        } else {
            descLabel.isHidden = true
        }
        descLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .regular)
        descLabel.textColor = NSColor(theme.tertiaryText)

        applyIconGradient(for: artifact)
        let sym = Self.symbolName(for: artifact)
        iconBadge.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        iconBadge.contentTintColor = .white
        iconBadge.imageScaling = .scaleProportionallyUpOrDown

        accentStrip.layer?.backgroundColor = NSColor(theme.accentColor).cgColor

        layoutNameTypeRow(theme: theme)

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

        previewTopConstraint(isDescVisible: !descLabel.isHidden)

        buildPreview(for: artifact, theme: theme)

        scheduleIntroGlowIfNeeded(theme: theme, artifactId: artifact.id)

        // do not call layoutSubtreeIfNeeded() here — configure runs from table/cell paths during layout
        cachedLayoutHeight = max(fittingSize.height, 120)
        invalidateIntrinsicContentSize()
        scheduleDeferredLayoutMetricsUpdate()
    }

    func measuredCardHeight() -> CGFloat {
        let h = fittingSize.height
        cachedLayoutHeight = max(max(h, cachedLayoutHeight), 1)
        return cachedLayoutHeight
    }

    /// commits real fitting height on the next turn — safe when AppKit is already in -layout
    private func scheduleDeferredLayoutMetricsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.cachedLayoutHeight = max(self.fittingSize.height, 1)
            self.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Chrome

    private func updateChrome(theme: any ThemeProtocol) {
        if theme.glassEnabled {
            layer?.backgroundColor = NSColor(theme.secondaryBackground).withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor(theme.secondaryBackground).cgColor
        }

        let borderAlpha: CGFloat = isHovered ? 0.25 : 0.15
        ensureBorderLayer()
        borderStrokeLayer?.strokeColor = NSColor(theme.primaryBorder).withAlphaComponent(borderAlpha).cgColor
        borderStrokeLayer?.lineWidth = 1

        if isHovered {
            hoverOverlayLayer?.backgroundColor = NSColor(theme.accentColor).withAlphaComponent(0.04).cgColor
        } else {
            hoverOverlayLayer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func ensureBorderLayer() {
        if borderStrokeLayer != nil { return }
        let stroke = CAShapeLayer()
        stroke.fillColor = NSColor.clear.cgColor
        stroke.lineWidth = 1
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
        borderStrokeLayer?.frame = b
        let inset: CGFloat = 0.5
        let rect = CGRect(x: inset, y: inset, width: b.width - inset * 2, height: b.height - inset * 2)
        let r = max(10 - inset, 0)
        borderStrokeLayer?.path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).cgPath

        hoverOverlayLayer?.frame = b
        let mask = CAShapeLayer()
        mask.path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).cgPath
        hoverOverlayLayer?.mask = mask

        let ib = iconBg.bounds
        iconGradient.frame = CGRect(x: 0, y: 0, width: ib.width, height: ib.height)

        let pillH = typePillContainer.bounds.height
        if pillH > 2 {
            typePillContainer.layer?.cornerRadius = pillH / 2
        }
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
        footerStack.alphaValue = isHovered ? 1 : 0.6
    }

    private func scheduleIntroGlowIfNeeded(theme: any ThemeProtocol, artifactId: String) {
        guard lastGlowArtifactId != artifactId else { return }
        lastGlowArtifactId = artifactId
        glowAnimationTask?.cancel()
        layer?.shadowOpacity = 0
        glowAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self.layer?.shadowColor = NSColor(theme.accentColor).cgColor
                self.layer?.shadowOpacity = 0.12
                self.layer?.shadowRadius = 6
                self.layer?.shadowOffset = NSSize(width: 0, height: -2)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self.layer?.shadowOpacity = 0
            }
        }
    }

    // MARK: - Preview host

    private func clearPreviewHost() {
        for v in previewHost.subviews {
            v.removeFromSuperview()
        }
        previewImageView.image = nil
        pdfPageBadge.isHidden = true
        pdfBadgeBackdrop.isHidden = true
    }

    private func previewTopConstraint(isDescVisible: Bool) {
        previewTopToDesc?.isActive = false
        previewTopToName?.isActive = false
        if isDescVisible {
            previewTopToDesc = previewHost.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 8)
            previewTopToDesc?.isActive = true
        } else {
            previewTopToName = previewHost.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8)
            previewTopToName?.isActive = true
        }
    }

    private func buildPreview(for artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        previewEmptyHeightConstraint?.isActive = false
        previewEmptyHeightConstraint = nil

        let path = artifact.hostPath
        let emptyPath = path.isEmpty

        if artifact.isImage, !emptyPath {
            buildImagePreview(artifact: artifact, theme: theme)
        } else if artifact.isPDF, !emptyPath {
            buildPDFPreview(artifact: artifact, theme: theme)
        } else if artifact.isVideo, !emptyPath {
            buildVideoPreview(artifact: artifact, theme: theme)
        } else if artifact.isAudio, !emptyPath {
            buildAudioPreview(artifact: artifact, theme: theme)
        } else if artifact.isHTML || (artifact.isDirectory && Self.hasIndexHTML(artifact)) {
            buildHTMLPreview(artifact: artifact, theme: theme)
        } else if artifact.isText, let content = artifact.content, !content.isEmpty {
            buildTextPreview(content: content, theme: theme)
        } else {
            previewHost.isHidden = true
            let z = previewHost.heightAnchor.constraint(equalToConstant: 0)
            z.isActive = true
            previewEmptyHeightConstraint = z
        }
    }

    private func buildImagePreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.3).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(bg)

        let iv = previewImageView
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 0.5
        iv.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(0.1).cgColor
        previewHost.addSubview(iv)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            bg.topAnchor.constraint(equalTo: previewHost.topAnchor),
            bg.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),

            iv.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            iv.topAnchor.constraint(equalTo: previewHost.topAnchor),
            iv.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            previewHost.bottomAnchor.constraint(equalTo: iv.bottomAnchor),
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
                guard let data else { return }
                let decoded = await ChatImageCache.shared.decode(data, id: artId)
                await MainActor.run {
                    guard let self else { return }
                    guard self.currentArtifactId == artId else { return }
                    iv.image = decoded
                    self.notifyHeightChanged()
                }
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
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        container.addSubview(iv)

        pdfBadgeBackdrop.wantsLayer = true
        pdfBadgeBackdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pdfBadgeBackdrop.layer?.cornerRadius = 10
        pdfBadgeBackdrop.translatesAutoresizingMaskIntoConstraints = false
        pdfBadgeBackdrop.isHidden = true
        container.addSubview(pdfBadgeBackdrop)

        pdfPageBadge.translatesAutoresizingMaskIntoConstraints = false
        pdfPageBadge.isEditable = false
        pdfPageBadge.isBordered = false
        pdfPageBadge.drawsBackground = false
        pdfPageBadge.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        pdfPageBadge.textColor = .white
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
                guard let self else { return }
                guard self.currentArtifactId == artId else { return }
                guard let data, let doc = PDFDocument(data: data) else { return }
                let count = doc.pageCount
                guard let page = doc.page(at: 0) else { return }
                let thumb = page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
                iv.image = thumb
                self.pdfPageBadge.stringValue = "\(count) page\(count == 1 ? "" : "s")"
                self.pdfPageBadge.isHidden = false
                self.pdfBadgeBackdrop.isHidden = false
                self.notifyHeightChanged()
            }
        }
    }

    private func buildVideoPreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(container)

        let iv = previewImageView
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        container.addSubview(iv)

        videoPlayIcon.translatesAutoresizingMaskIntoConstraints = false
        videoPlayIcon.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")
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
                    guard let self else { return }
                    guard self.currentArtifactId == artId else { return }
                    iv.image = img
                    self.notifyHeightChanged()
                }
            } catch {
                await MainActor.run { self?.notifyHeightChanged() }
            }
        }
    }

    private func buildAudioPreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.4).cgColor

        audioPlayButton.translatesAutoresizingMaskIntoConstraints = false
        audioPlayButton.isBordered = false
        audioPlayButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        audioPlayButton.contentTintColor = NSColor(theme.accentColor)
        audioPlayButton.target = self
        audioPlayButton.action = #selector(openArtifactWithDefaultApp)

        let circle = NSView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor(theme.accentColor).withAlphaComponent(0.12).cgColor
        circle.layer?.cornerRadius = 18
        circle.addSubview(audioPlayButton)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 36),
            circle.heightAnchor.constraint(equalToConstant: 36),
            audioPlayButton.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            audioPlayButton.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            audioPlayButton.widthAnchor.constraint(equalToConstant: 14),
            audioPlayButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        audioTitleLabel.stringValue = artifact.filename
        audioTitleLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .medium)
        audioTitleLabel.textColor = NSColor(theme.primaryText)
        audioTitleLabel.maximumNumberOfLines = 1
        audioTitleLabel.lineBreakMode = .byTruncatingTail

        audioMetaLabel.stringValue = Self.formatSize(artifact.fileSize)
        audioMetaLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        audioMetaLabel.textColor = NSColor(theme.tertiaryText)

        let textCol = NSStackView()
        textCol.orientation = .vertical
        textCol.spacing = 2
        textCol.addArrangedSubview(audioTitleLabel)
        textCol.addArrangedSubview(audioMetaLabel)

        row.addArrangedSubview(circle)
        row.addArrangedSubview(textCol)

        previewHost.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            row.topAnchor.constraint(equalTo: previewHost.topAnchor),
            previewHost.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

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
                    guard let self else { return }
                    guard self.currentArtifactId == artId else { return }
                    self.audioMetaLabel.stringValue = "\(formatted) · \(Self.formatSize(artifact.fileSize))"
                    self.notifyHeightChanged()
                }
            } catch {
                await MainActor.run { self?.notifyHeightChanged() }
            }
        }
    }

    private func buildHTMLPreview(artifact: SharedArtifact, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.4).cgColor

        htmlIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        htmlIcon.contentTintColor = NSColor(theme.secondaryText)
        htmlIcon.imageScaling = .scaleProportionallyUpOrDown

        htmlTitleLabel.stringValue = "Web Page"
        htmlTitleLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .medium)
        htmlTitleLabel.textColor = NSColor(theme.secondaryText)

        htmlSizeLabel.stringValue = Self.formatSize(artifact.fileSize)
        htmlSizeLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        htmlSizeLabel.textColor = NSColor(theme.tertiaryText)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(htmlIcon)
        row.addArrangedSubview(htmlTitleLabel)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(htmlSizeLabel)

        previewHost.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            row.topAnchor.constraint(equalTo: previewHost.topAnchor),
            previewHost.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            htmlIcon.widthAnchor.constraint(equalToConstant: 14),
            htmlIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func buildTextPreview(content: String, theme: any ThemeProtocol) {
        previewHost.isHidden = false
        let lines = content.components(separatedBy: "\n").prefix(6)
        textPreviewField.stringValue = lines.joined(separator: "\n")
        textPreviewField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textPreviewField.textColor = NSColor(theme.secondaryText)
        textPreviewField.maximumNumberOfLines = 6
        textPreviewField.translatesAutoresizingMaskIntoConstraints = false
        textPreviewField.wantsLayer = true
        textPreviewField.layer?.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.5).cgColor
        textPreviewField.layer?.cornerRadius = 6

        previewHost.addSubview(textPreviewField)
        NSLayoutConstraint.activate([
            textPreviewField.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            textPreviewField.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            textPreviewField.topAnchor.constraint(equalTo: previewHost.topAnchor),
            previewHost.bottomAnchor.constraint(equalTo: textPreviewField.bottomAnchor),
        ])
    }

    private func notifyHeightChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.cachedLayoutHeight = max(self.fittingSize.height, 1)
            self.invalidateIntrinsicContentSize()
            self.onHeightChanged?()
        }
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
        NSWorkspace.shared.open(url)
    }

    @objc private func openArtifactWithDefaultApp() {
        guard !hostPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: hostPath))
    }

    // MARK: - Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false

        accentStrip.translatesAutoresizingMaskIntoConstraints = false
        accentStrip.wantsLayer = true
        addSubview(accentStrip)

        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)

        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.wantsLayer = true
        iconBg.layer?.cornerRadius = 5.5
        iconBg.layer?.masksToBounds = true
        iconBg.layer?.addSublayer(iconGradient)

        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBg.addSubview(iconBadge)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.maximumNumberOfLines = 1

        typePillContainer.translatesAutoresizingMaskIntoConstraints = false
        typePillContainer.wantsLayer = true
        typePillLabel.translatesAutoresizingMaskIntoConstraints = false
        typePillLabel.isEditable = false
        typePillLabel.isBordered = false
        typePillLabel.drawsBackground = false
        typePillLabel.maximumNumberOfLines = 1
        typePillContainer.addSubview(typePillLabel)

        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.isEditable = false
        descLabel.isBordered = false
        descLabel.drawsBackground = false
        descLabel.maximumNumberOfLines = 1

        previewHost.translatesAutoresizingMaskIntoConstraints = false

        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.orientation = .horizontal
        footerStack.spacing = 8
        footerStack.alignment = .centerY
        let fs = NSView()
        fs.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerStack.addArrangedSubview(fs)
        footerStack.addArrangedSubview(openInBrowserButton)
        footerStack.addArrangedSubview(openInFinderButton)

        openInFinderButton.target = self
        openInFinderButton.action = #selector(openInFinderTapped)
        openInBrowserButton.target = self
        openInBrowserButton.action = #selector(openInBrowserTapped)

        inner.addSubview(iconBg)
        inner.addSubview(nameLabel)
        inner.addSubview(typePillContainer)
        inner.addSubview(descLabel)
        inner.addSubview(previewHost)
        inner.addSubview(footerStack)

        NSLayoutConstraint.activate([
            accentStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentStrip.topAnchor.constraint(equalTo: topAnchor),
            accentStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentStrip.widthAnchor.constraint(equalToConstant: 4),

            inner.leadingAnchor.constraint(equalTo: accentStrip.trailingAnchor, constant: Self.innerPadding),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.innerPadding),
            inner.topAnchor.constraint(equalTo: topAnchor, constant: Self.innerPadding),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.innerPadding),

            iconBg.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            iconBg.topAnchor.constraint(equalTo: inner.topAnchor),
            iconBg.widthAnchor.constraint(equalToConstant: 24),
            iconBg.heightAnchor.constraint(equalToConstant: 24),

            iconBadge.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconBadge.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 12),
            iconBadge.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: iconBg.topAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: typePillContainer.leadingAnchor, constant: -6),

            typePillContainer.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            typePillContainer.trailingAnchor.constraint(lessThanOrEqualTo: inner.trailingAnchor),

            descLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            descLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: inner.trailingAnchor),

            previewHost.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: inner.trailingAnchor),

            footerStack.leadingAnchor.constraint(greaterThanOrEqualTo: inner.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            footerStack.topAnchor.constraint(greaterThanOrEqualTo: previewHost.bottomAnchor, constant: 8),
            footerStack.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
        ])

        previewTopToDesc = previewHost.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 8)
        previewTopToName = previewHost.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8)
        previewTopToDesc?.isActive = true

        NSLayoutConstraint.activate([
            typePillLabel.leadingAnchor.constraint(equalTo: typePillContainer.leadingAnchor, constant: 6),
            typePillLabel.trailingAnchor.constraint(equalTo: typePillContainer.trailingAnchor, constant: -6),
            typePillLabel.topAnchor.constraint(equalTo: typePillContainer.topAnchor, constant: 2),
            typePillLabel.bottomAnchor.constraint(equalTo: typePillContainer.bottomAnchor, constant: -2),
        ])
    }

    private func layoutNameTypeRow(theme: any ThemeProtocol) {
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        typePillContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func styleFooterButton(_ button: NSButton, title: String, symbol: String, theme: any ThemeProtocol) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        button.contentTintColor = NSColor(theme.accentColor)
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    private func applyIconGradient(for artifact: SharedArtifact) {
        let colors = Self.iconGradientNSColors(for: artifact)
        iconGradient.colors = colors.map { $0.cgColor }
        iconGradient.locations = [0, 1]
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
        if artifact.isVideo { return "film" }
        if artifact.isAudio { return "waveform" }
        if artifact.isHTML { return "globe" }
        if artifact.isText { return "doc.text" }
        return "doc"
    }

    private static func iconGradientNSColors(for artifact: SharedArtifact) -> [NSColor] {
        func c(_ hex: String) -> NSColor {
            let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var int: UInt64 = 0
            Scanner(string: h).scanHexInt64(&int)
            let r = CGFloat((int >> 16) & 0xFF) / 255
            let g = CGFloat((int >> 8) & 0xFF) / 255
            let b = CGFloat(int & 0xFF) / 255
            return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }
        if artifact.isImage { return [c("8b5cf6"), c("7c3aed")] }
        if artifact.isPDF { return [c("ef4444"), c("dc2626")] }
        if artifact.isVideo { return [c("ec4899"), c("db2777")] }
        if artifact.isAudio { return [c("f59e0b"), c("d97706")] }
        if artifact.isHTML { return [c("3b82f6"), c("2563eb")] }
        if artifact.isDirectory { return [c("f59e0b"), c("d97706")] }
        return [c("6b7280"), c("4b5563")]
    }

    private static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private static func themeFingerprint(_ theme: any ThemeProtocol) -> String {
        "\(theme.bodySize)|\(theme.captionSize)|\(theme.glassEnabled)|\(NSColor(theme.accentColor).description)|\(NSColor(theme.secondaryBackground).description)|\(NSColor(theme.primaryBorder).description)|\(NSColor(theme.primaryText).description)|\(NSColor(theme.tertiaryText).description)|\(NSColor(theme.tertiaryBackground).description)"
    }
}
