//
//  NativeActivityGroupView.swift
//  osaurus
//
//  Pure AppKit rollup for a run of consecutive thinking / tool-call blocks.
//  Collapsed it is a single disclosure row ("Worked for 12s · 6 steps");
//  expanded it stacks the run's individual NativeThinkingView /
//  NativeToolCallGroupView children, whose own per-item expansion keeps
//  working through the shared expandedIds set.
//
//  Self-sizing: owns a selfHeight constraint (priority 750) like
//  NativeThinkingView so it reports height to the coordinator without a
//  bottomAnchor pin to the cell.
//

import AppKit

final class NativeActivityGroupView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    /// Circular tinted node matching the thinking block / tool timeline nodes.
    private let iconNode = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// Shown in place of `titleLabel` while any child is still streaming.
    private let shimmerLabel = ShimmerLabel()
    private let stepCountLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let separatorView = NSView()
    private let contentContainer = NSView()
    private let childStack = NSStackView()

    // MARK: Self-sizing height constraint

    private var selfHeight: NSLayoutConstraint?

    // MARK: State

    private var isExpanded = false
    private var currentWidth: CGFloat = 0
    /// Same-block guard so the chevron only animates on a real expand-state
    /// change, never on cell recycling (mirrors NativeThinkingView).
    private var configuredBlockId: String?
    /// Child views keyed by their block id, reused across reconfigures so
    /// streaming appends don't rebuild (and re-animate) existing children.
    private var childViews: [String: NSView] = [:]
    private var childOrder: [String] = []

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Relayout resets view-managed layer geometry; reapply the chevron
        // state so it doesn't snap back mid-stream (see NativeThinkingView).
        updateChevron(expanded: isExpanded, animated: false)
    }

    // MARK: Configure

    func configure(
        children: [ContentBlock],
        expandedIds: Set<String>,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool,
        blockId: String,
        sessionRedactions: [String: String],
        onToggleChild: @escaping (String) -> Void,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width

        let tint = NSColor(theme.primaryText)
        let titleFont = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .semibold)
        titleLabel.font = titleFont
        titleLabel.textColor = tint
        iconView.contentTintColor = tint
        iconNode.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        iconNode.layer?.borderColor = tint.withAlphaComponent(0.55).cgColor

        // A group is "live" when its own children say so — a thinking child
        // still streaming, or an unresolved tool call while the table streams.
        // Gating the tool side on `isStreaming` keeps loaded chats (which can
        // carry never-resolved calls) static.
        let live = children.contains { child in
            switch child.kind {
            case let .thinking(_, _, streaming, _): return streaming
            case let .toolCallGroup(calls): return isStreaming && calls.contains { $0.result == nil }
            default: return false
            }
        }

        if live {
            shimmerLabel.configure(
                text: L("Working"),
                font: titleFont,
                baseColor: tint.withAlphaComponent(0.45),
                highlightColor: tint
            )
            titleLabel.isHidden = true
            shimmerLabel.isHidden = false
            shimmerLabel.start()
        } else {
            shimmerLabel.stop()
            shimmerLabel.isHidden = true
            let total = Self.totalDuration(of: children)
            titleLabel.stringValue =
                total > 0
                ? "\(L("Worked for")) \(Self.formatDuration(total))"
                : L("Worked")
            titleLabel.isHidden = false
        }

        let expanded = expandedIds.contains(blockId)

        let steps = ContentBlock.activityStepCount(of: children)
        stepCountLabel.isHidden = expanded || steps == 0
        stepCountLabel.stringValue = steps == 1 ? L("1 step") : "\(steps) \(L("steps"))"
        stepCountLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 2, weight: .medium)
        stepCountLabel.textColor = NSColor(theme.tertiaryText)

        let isSameBlock = configuredBlockId == blockId
        updateChevron(
            expanded: expanded,
            animated: isSameBlock && expanded != self.isExpanded
        )
        self.isExpanded = expanded
        configuredBlockId = blockId

        contentContainer.isHidden = !expanded
        separatorView.isHidden = !expanded

        if expanded {
            configureChildren(
                children,
                expandedIds: expandedIds,
                theme: theme,
                isStreaming: isStreaming,
                sessionRedactions: sessionRedactions,
                onToggleChild: onToggleChild
            )
        } else {
            // Collapsed: drop child views so a huge expanded run doesn't keep
            // its markdown/tool layers alive off-screen.
            tearDownChildren()
        }

        applyHeight()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        let headerH: CGFloat = 44
        let collapsedBottomInset: CGFloat = 4
        guard isExpanded, !childOrder.isEmpty else { return headerH + collapsedBottomInset }
        var contentH: CGFloat = 0
        for id in childOrder {
            guard let v = childViews[id] else { continue }
            if let tv = v as? NativeThinkingView {
                contentH += tv.measuredHeight()
            } else if let gv = v as? NativeToolCallGroupView {
                contentH += gv.measuredHeight()
            }
        }
        contentH += childStack.spacing * CGFloat(max(0, childOrder.count - 1))
        return headerH + 1 + 8 + contentH + 10
    }

    // MARK: - Children

    private func configureChildren(
        _ children: [ContentBlock],
        expandedIds: Set<String>,
        theme: any ThemeProtocol,
        isStreaming: Bool,
        sessionRedactions: [String: String],
        onToggleChild: @escaping (String) -> Void
    ) {
        let childWidth = max(currentWidth - 28, 100)
        let newOrder = children.map(\.id)

        // Rebuild the stack arrangement only when membership/order changed;
        // per-token reconfigures keep the existing arranged views.
        if newOrder != childOrder {
            for v in childStack.arrangedSubviews {
                childStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            var kept: [String: NSView] = [:]
            for child in children {
                let view: NSView
                if let existing = childViews[child.id] {
                    view = existing
                } else {
                    switch child.kind {
                    case .thinking: view = NativeThinkingView()
                    case .toolCallGroup: view = NativeToolCallGroupView()
                    default: continue
                    }
                }
                view.translatesAutoresizingMaskIntoConstraints = false
                childStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: childStack.widthAnchor).isActive = true
                kept[child.id] = view
            }
            childViews = kept
            childOrder = children.filter { childViews[$0.id] != nil }.map(\.id)
        }

        for child in children {
            guard let view = childViews[child.id] else { continue }
            switch child.kind {
            case let .thinking(_, text, streaming, duration):
                (view as? NativeThinkingView)?.configure(
                    thinking: text,
                    thinkingLength: text.count,
                    width: childWidth,
                    isStreaming: streaming,
                    isExpanded: expandedIds.contains(child.id),
                    duration: duration,
                    theme: theme,
                    blockId: child.id,
                    sessionRedactions: sessionRedactions,
                    onToggle: { onToggleChild(child.id) },
                    onHeightChanged: { [weak self] in self?.applyHeight() }
                )
            case let .toolCallGroup(calls):
                (view as? NativeToolCallGroupView)?.configure(
                    calls: calls,
                    expandedIds: expandedIds,
                    width: childWidth,
                    theme: theme,
                    isStreaming: isStreaming,
                    onToggle: { id in onToggleChild(id) },
                    onHeightChanged: { [weak self] in self?.applyHeight() }
                )
            default:
                break
            }
        }
    }

    private func tearDownChildren() {
        for v in childStack.arrangedSubviews {
            childStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        childViews = [:]
        childOrder = []
    }

    // MARK: - Private

    private func applyHeight() {
        selfHeight?.constant = measuredHeight()
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""; headerButton.isBordered = false; headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.focusRingType = .none
        headerButton.target = self; headerButton.action = #selector(headerTapped)
        addSubview(headerButton)

        iconNode.translatesAutoresizingMaskIntoConstraints = false
        iconNode.wantsLayer = true
        iconNode.layer?.cornerRadius = 14
        iconNode.layer?.borderWidth = 1.5
        iconNode.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        iconNode.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        addSubview(iconNode)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = SymbolImageCache.image("sparkles", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.labelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconNode.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        addSubview(titleLabel)

        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false
        shimmerLabel.isHidden = true
        addSubview(shimmerLabel)

        stepCountLabel.translatesAutoresizingMaskIntoConstraints = false
        stepCountLabel.isEditable = false; stepCountLabel.isBordered = false
        stepCountLabel.drawsBackground = false
        addSubview(stepCountLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.wantsLayer = true
        chevronView.image = SymbolImageCache.image(
            "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        childStack.translatesAutoresizingMaskIntoConstraints = false
        childStack.orientation = .vertical
        childStack.spacing = 2
        childStack.alignment = .leading
        contentContainer.addSubview(childStack)

        let headerH: CGFloat = 44

        let h = heightAnchor.constraint(equalToConstant: headerH + 4)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        selfHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: headerH),

            iconNode.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconNode.centerYAnchor.constraint(equalTo: topAnchor, constant: headerH / 2),
            iconNode.widthAnchor.constraint(equalToConstant: 28),
            iconNode.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: iconNode.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconNode.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),

            shimmerLabel.leadingAnchor.constraint(equalTo: iconNode.trailingAnchor, constant: 10),
            shimmerLabel.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevronView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            stepCountLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            stepCountLabel.centerYAnchor.constraint(equalTo: chevronView.centerYAnchor),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: headerH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),

            childStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            // Bottom pin sizes the container to its children — without it the
            // container's frame resolves to zero height and hit testing culls
            // clicks on the (still-drawn) child rows.
            childStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        // Front of Z-order like the tool rows' header overlay, so clicks on
        // the title / step-count text toggle the same as the empty header
        // area. Transparent, and only 44pt tall, so it never paints over or
        // intercepts the expanded children below.
        addSubview(headerButton, positioned: .above, relativeTo: nil)
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        chevronView.image =
            expanded
            ? SymbolImageCache.rotatedDownChevron(pointSize: 10, weight: .semibold)
            : SymbolImageCache.image(
                "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
    }

    @objc private func headerTapped() { onToggle?() }

    // MARK: - Aggregates

    /// Sum of the known child durations (thinking + tool calls). Children
    /// without a recorded duration contribute nothing.
    static func totalDuration(of children: [ContentBlock]) -> TimeInterval {
        children.reduce(0) { acc, child in
            switch child.kind {
            case let .thinking(_, _, _, duration): return acc + (duration ?? 0)
            case let .toolCallGroup(calls):
                return acc + calls.reduce(0) { $0 + ($1.duration ?? 0) }
            default: return acc
            }
        }
    }

    /// Compact duration matching NativeThinkingView's format.
    private static func formatDuration(_ t: TimeInterval) -> String {
        if t < 1 { return "\(Int((t * 1000).rounded()))ms" }
        if t < 10 { return String(format: "%.1fs", t) }
        if t < 60 { return "\(Int(t.rounded()))s" }
        return "\(Int(t) / 60)m \(Int(t) % 60)s"
    }
}
