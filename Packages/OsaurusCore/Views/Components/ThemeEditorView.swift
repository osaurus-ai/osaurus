//
//  ThemeEditorView.swift
//  osaurus
//
//  Live theme editor with real-time preview and all customization controls
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemeEditorView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var currentTheme: ThemeProtocol { themeManager.currentTheme }

    @State private var editingTheme: CustomTheme
    @State private var selectedTab: EditorTab = .colors
    @State private var showImagePicker = false
    @State private var showSaveConfirmation = false
    @State private var collapsedSections: Set<String> = []
    @State private var animationPreviewTrigger = false

    let onDismiss: () -> Void

    private let colorSectionNames = [
        "Text Colors", "Background Colors", "Sidebar Colors", "Accent Colors",
        "Status Colors", "Border Colors", "Component Colors", "Code & Glass", "Selection",
    ]

    init(theme: CustomTheme, onDismiss: @escaping () -> Void) {
        _editingTheme = State(initialValue: theme)
        self.onDismiss = onDismiss
    }

    enum EditorTab: String, CaseIterable {
        case colors = "Colors"
        case background = "Background"
        case glass = "Glass"
        case typography = "Typography"
        case animation = "Animation"

        var icon: String {
            switch self {
            case .colors: return "paintpalette"
            case .background: return "photo"
            case .glass: return "square.on.square"
            case .typography: return "textformat"
            case .animation: return "wand.and.rays"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            editorPanel
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 450)
            previewPanel
                .frame(minWidth: 500, idealWidth: 600)
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(currentTheme.primaryBackground)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageImport(result)
        }
    }

    // MARK: - Editor Panel

    private var editorPanel: some View {
        VStack(spacing: 0) {
            editorHeader
            tabSelector

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .colors: colorsEditor
                    case .background: backgroundEditor
                    case .glass: glassEditor
                    case .typography: typographyEditor
                    case .animation: animationEditor
                    }
                }
                .padding(20)
            }

            editorFooter
        }
        .background(currentTheme.secondaryBackground)
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Theme Editor")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(currentTheme.primaryText)

                Spacer()

                Button(action: {
                    dismiss(); onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(currentTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(currentTheme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
            }

            themeTextField("Theme Name", text: $editingTheme.metadata.name, fontSize: 14, weight: .medium, radius: 8)
            themeTextField("Author Name", text: $editingTheme.metadata.author, fontSize: 13, radius: 6)
        }
        .padding(16)
    }

    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EditorTab.allCases, id: \.rawValue) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon).font(.system(size: 13))
                            Text(tab.rawValue).font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTab == tab ? currentTheme.accentColor : Color.clear)
                        )
                        .foregroundColor(selectedTab == tab ? .white : currentTheme.secondaryText)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(currentTheme.tertiaryBackground.opacity(0.5))
    }

    private var editorFooter: some View {
        HStack {
            if editingTheme.isBuiltIn {
                Label("Built-in themes cannot be modified directly", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(currentTheme.warningColor)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss(); onDismiss()
                }
                .buttonStyle(.bordered)

                Button(action: saveTheme) {
                    HStack(spacing: 4) {
                        if showSaveConfirmation { Image(systemName: "checkmark") }
                        Text(showSaveConfirmation ? "Saved!" : (editingTheme.isBuiltIn ? "Save as Copy" : "Save"))
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(currentTheme.secondaryBackground)
    }

    // MARK: - Colors Editor

    private var colorsEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        collapsedSections = collapsedSections.isEmpty ? Set(colorSectionNames) : []
                    }
                }) {
                    Text(collapsedSections.isEmpty ? "Collapse All" : "Expand All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }

            editorSection("Text Colors", itemCount: 4) {
                colorRow("Primary Text", hex: $editingTheme.colors.primaryText)
                colorRow("Secondary Text", hex: $editingTheme.colors.secondaryText)
                colorRow("Tertiary Text", hex: $editingTheme.colors.tertiaryText)
                colorRowOptional("Placeholder Text", hex: $editingTheme.colors.placeholderText)
            }

            editorSection("Background Colors", itemCount: 3) {
                colorRow("Primary", hex: $editingTheme.colors.primaryBackground)
                colorRow("Secondary", hex: $editingTheme.colors.secondaryBackground)
                colorRow("Tertiary", hex: $editingTheme.colors.tertiaryBackground)
            }

            editorSection("Sidebar Colors", itemCount: 2) {
                colorRow("Background", hex: $editingTheme.colors.sidebarBackground)
                colorRow("Selected", hex: $editingTheme.colors.sidebarSelectedBackground)
            }

            editorSection("Accent Colors", itemCount: 2) {
                colorRow("Primary Accent", hex: $editingTheme.colors.accentColor)
                colorRow("Light Accent", hex: $editingTheme.colors.accentColorLight)
            }

            editorSection("Status Colors", itemCount: 4) {
                colorRow("Success", hex: $editingTheme.colors.successColor)
                colorRow("Warning", hex: $editingTheme.colors.warningColor)
                colorRow("Error", hex: $editingTheme.colors.errorColor)
                colorRow("Info", hex: $editingTheme.colors.infoColor)
            }

            editorSection("Border Colors", itemCount: 3) {
                colorRow("Primary", hex: $editingTheme.colors.primaryBorder)
                colorRow("Secondary", hex: $editingTheme.colors.secondaryBorder)
                colorRow("Focus", hex: $editingTheme.colors.focusBorder)
            }

            editorSection("Component Colors", itemCount: 6) {
                colorRow("Card Background", hex: $editingTheme.colors.cardBackground)
                colorRow("Card Border", hex: $editingTheme.colors.cardBorder)
                colorRow("Button Background", hex: $editingTheme.colors.buttonBackground)
                colorRow("Button Border", hex: $editingTheme.colors.buttonBorder)
                colorRow("Input Background", hex: $editingTheme.colors.inputBackground)
                colorRow("Input Border", hex: $editingTheme.colors.inputBorder)
            }

            editorSection("Code & Glass", itemCount: 2) {
                colorRow("Glass Tint", hex: $editingTheme.colors.glassTintOverlay)
                colorRow("Code Block", hex: $editingTheme.colors.codeBlockBackground)
            }

            editorSection("Selection", itemCount: 2) {
                colorRow("Text Selection", hex: $editingTheme.colors.selectionColor)
                colorRow("Cursor Color", hex: $editingTheme.colors.cursorColor)
            }
        }
    }

    // MARK: - Background Editor

    private var backgroundEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Background Type") {
                Picker("Type", selection: $editingTheme.background.type) {
                    Text("Solid Color").tag(ThemeBackground.BackgroundType.solid)
                    Text("Gradient").tag(ThemeBackground.BackgroundType.gradient)
                    Text("Image").tag(ThemeBackground.BackgroundType.image)
                }
                .pickerStyle(.segmented)
            }

            if editingTheme.background.type == .solid {
                editorSection("Solid Color") {
                    colorRow(
                        "Background Color",
                        hex: Binding(
                            get: { editingTheme.background.solidColor ?? editingTheme.colors.primaryBackground },
                            set: { editingTheme.background.solidColor = $0 }
                        )
                    )
                }
            }

            if editingTheme.background.type == .image {
                editorSection("Background Image") {
                    VStack(spacing: 12) {
                        if let imageData = editingTheme.background.imageData,
                            let data = Data(base64Encoded: imageData),
                            let nsImage = NSImage(data: data)
                        {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(currentTheme.primaryBorder, lineWidth: 1)
                                )

                            Button("Remove Image") { editingTheme.background.imageData = nil }
                                .buttonStyle(.bordered)
                        } else {
                            Button(action: { showImagePicker = true }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.badge.plus").font(.system(size: 24))
                                    Text("Choose Image").font(.system(size: 13, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 80)
                                .foregroundColor(currentTheme.secondaryText)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(currentTheme.primaryBorder, style: StrokeStyle(lineWidth: 1, dash: [5]))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        sliderRow(
                            "Opacity",
                            value: Binding(
                                get: { editingTheme.background.imageOpacity ?? 1.0 },
                                set: { editingTheme.background.imageOpacity = $0 }
                            ),
                            range: 0 ... 1
                        )

                        Picker(
                            "Fit",
                            selection: Binding(
                                get: { editingTheme.background.imageFit ?? .fill },
                                set: { editingTheme.background.imageFit = $0 }
                            )
                        ) {
                            Text("Fill").tag(ThemeBackground.ImageFit.fill)
                            Text("Fit").tag(ThemeBackground.ImageFit.fit)
                            Text("Stretch").tag(ThemeBackground.ImageFit.stretch)
                            Text("Tile").tag(ThemeBackground.ImageFit.tile)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            if editingTheme.background.type == .gradient {
                editorSection("Gradient Colors") {
                    VStack(spacing: 8) {
                        ForEach(
                            Array((editingTheme.background.gradientColors ?? ["#000000", "#333333"]).enumerated()),
                            id: \.offset
                        ) { index, _ in
                            colorRow(
                                "Color \(index + 1)",
                                hex: Binding(
                                    get: {
                                        let colors = editingTheme.background.gradientColors ?? ["#000000", "#333333"]
                                        return index < colors.count ? colors[index] : "#000000"
                                    },
                                    set: { newValue in
                                        var colors = editingTheme.background.gradientColors ?? ["#000000", "#333333"]
                                        if index < colors.count {
                                            colors[index] = newValue
                                            editingTheme.background.gradientColors = colors
                                        }
                                    }
                                )
                            )
                        }

                        HStack {
                            Button(action: {
                                var colors = editingTheme.background.gradientColors ?? ["#000000", "#333333"]
                                colors.append("#000000")
                                editingTheme.background.gradientColors = colors
                            }) { Label("Add Color", systemImage: "plus") }
                            .buttonStyle(.bordered)

                            if (editingTheme.background.gradientColors?.count ?? 0) > 2 {
                                Button(action: { editingTheme.background.gradientColors?.removeLast() }) {
                                    Label("Remove", systemImage: "minus")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        sliderRow(
                            "Angle",
                            value: Binding(
                                get: { editingTheme.background.gradientAngle ?? 180 },
                                set: { editingTheme.background.gradientAngle = $0 }
                            ),
                            range: 0 ... 360
                        )
                    }
                }
            }

            editorSection("Overlay") {
                colorRowOptional("Color", hex: $editingTheme.background.overlayColor)
                sliderRow(
                    "Opacity",
                    value: Binding(
                        get: { editingTheme.background.overlayOpacity ?? 0 },
                        set: { editingTheme.background.overlayOpacity = $0 }
                    ),
                    range: 0 ... 1
                )
            }
        }
    }

    // MARK: - Glass Editor

    private var glassEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Glass Effect") {
                Toggle("Enable Glass Effect", isOn: $editingTheme.glass.enabled.animation(.easeInOut(duration: 0.2)))
                    .font(.system(size: 13))

                Text(
                    editingTheme.glass.enabled
                        ? "Background shows through with blur/transparency"
                        : "Background is solid (no transparency)"
                )
                .font(.system(size: 11))
                .foregroundColor(currentTheme.tertiaryText)
            }

            if editingTheme.glass.enabled {
                editorSection("Material") {
                    Picker("Material", selection: $editingTheme.glass.material) {
                        Text("HUD Window").tag(ThemeGlass.GlassMaterial.hudWindow)
                        Text("Popover").tag(ThemeGlass.GlassMaterial.popover)
                        Text("Menu").tag(ThemeGlass.GlassMaterial.menu)
                        Text("Sidebar").tag(ThemeGlass.GlassMaterial.sidebar)
                        Text("Sheet").tag(ThemeGlass.GlassMaterial.sheet)
                        Text("Content Background").tag(ThemeGlass.GlassMaterial.contentBackground)
                        Text("Under Window").tag(ThemeGlass.GlassMaterial.underWindowBackground)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                editorSection("Blur & Opacity") {
                    sliderRow("Blur Radius", value: $editingTheme.glass.blurRadius, range: 0 ... 60)
                    sliderRow("Primary Opacity", value: $editingTheme.glass.opacityPrimary, range: 0 ... 1)
                    sliderRow("Secondary Opacity", value: $editingTheme.glass.opacitySecondary, range: 0 ... 1)
                    sliderRow("Tertiary Opacity", value: $editingTheme.glass.opacityTertiary, range: 0 ... 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                editorSection("Tint") {
                    colorRowOptional("Tint Color", hex: $editingTheme.glass.tintColor)
                    sliderRow(
                        "Tint Opacity",
                        value: Binding(
                            get: { editingTheme.glass.tintOpacity ?? 0 },
                            set: { editingTheme.glass.tintOpacity = $0 }
                        ),
                        range: 0 ... 1
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                editorSection("Edge Light") {
                    colorRow("Color", hex: $editingTheme.glass.edgeLight)
                    sliderRow(
                        "Width",
                        value: Binding(
                            get: { editingTheme.glass.edgeLightWidth ?? 1 },
                            set: { editingTheme.glass.edgeLightWidth = $0 }
                        ),
                        range: 0 ... 4
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Typography Editor

    private var typographyEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Font Families") {
                fontPicker("Primary Font", fontName: $editingTheme.typography.primaryFont, isMono: false)
                fontPicker("Mono Font", fontName: $editingTheme.typography.monoFont, isMono: true)
            }

            editorSection("Font Sizes") {
                sliderRow("Title", value: $editingTheme.typography.titleSize, range: 20 ... 40)
                sliderRow("Heading", value: $editingTheme.typography.headingSize, range: 14 ... 28)
                sliderRow("Body", value: $editingTheme.typography.bodySize, range: 10 ... 20)
                sliderRow("Caption", value: $editingTheme.typography.captionSize, range: 8 ... 16)
                sliderRow("Code", value: $editingTheme.typography.codeSize, range: 10 ... 18)
            }
        }
    }

    // MARK: - Animation Editor

    private var animationEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Preview") {
                VStack(spacing: 12) {
                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(themeHex: editingTheme.colors.accentColor))
                            .frame(width: 40, height: 40)
                            .offset(x: animationPreviewTrigger ? 80 : 0)
                            .animation(
                                .spring(
                                    response: editingTheme.animationConfig.springResponse,
                                    dampingFraction: editingTheme.animationConfig.springDamping
                                ),
                                value: animationPreviewTrigger
                            )
                        Spacer()
                    }
                    .frame(height: 50)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(currentTheme.tertiaryBackground.opacity(0.5)))

                    Button("Test Animation") { animationPreviewTrigger.toggle() }
                        .buttonStyle(.bordered)
                }
            }

            editorSection("Duration") {
                Text("Controls how long animations take")
                    .font(.system(size: 11)).foregroundColor(currentTheme.tertiaryText).padding(.bottom, 4)
                sliderRow("Quick", value: $editingTheme.animationConfig.durationQuick, range: 0.05 ... 0.5)
                sliderRow("Medium", value: $editingTheme.animationConfig.durationMedium, range: 0.1 ... 0.8)
                sliderRow("Slow", value: $editingTheme.animationConfig.durationSlow, range: 0.2 ... 1.0)
            }

            editorSection("Spring Physics") {
                Text("Response: How fast the spring moves\nDamping: How quickly it settles (lower = more bounce)")
                    .font(.system(size: 11)).foregroundColor(currentTheme.tertiaryText).padding(.bottom, 4)
                sliderRow("Response", value: $editingTheme.animationConfig.springResponse, range: 0.1 ... 1.0)
                sliderRow("Damping", value: $editingTheme.animationConfig.springDamping, range: 0.3 ... 1.0)
            }

            editorSection("Shadows") {
                sliderRow("Shadow Opacity", value: $editingTheme.shadows.shadowOpacity, range: 0 ... 1)
                sliderRow("Card Shadow", value: $editingTheme.shadows.cardShadowRadius, range: 0 ... 30)
                sliderRow("Card Shadow Hover", value: $editingTheme.shadows.cardShadowRadiusHover, range: 0 ... 40)
            }
        }
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live Preview")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(currentTheme.primaryText)
                Spacer()
                Text("Changes are reflected in real-time")
                    .font(.system(size: 11))
                    .foregroundColor(currentTheme.tertiaryText)
            }
            .padding(16)
            .background(currentTheme.secondaryBackground)

            ZStack {
                transparencyBackdrop
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                ThemeChatPreview(theme: editingTheme)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(6)
            }
            .padding(20)
        }
    }

    /// Bright gradient backdrop behind the preview to demonstrate glass transparency
    private var transparencyBackdrop: some View {
        let accent = Color(themeHex: editingTheme.colors.accentColor)
        let accentLight = Color(themeHex: editingTheme.colors.accentColorLight)
        let success = Color(themeHex: editingTheme.colors.successColor)

        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: accent, location: 0),
                    .init(color: accentLight.opacity(0.9), location: 0.35),
                    .init(color: accent.opacity(0.8), location: 0.65),
                    .init(color: success.opacity(0.7), location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [.white.opacity(0.15), .clear, .black.opacity(0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Reusable Editor Components

    private func editorSection<Content: View>(
        _ title: String,
        itemCount: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(title)

        return VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed { collapsedSections.remove(title) } else { collapsedSections.insert(title) }
                }
            }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(currentTheme.secondaryText)
                        .textCase(.uppercase)

                    if isCollapsed, let count = itemCount {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(currentTheme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(currentTheme.tertiaryBackground))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(currentTheme.tertiaryText)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(currentTheme.cardBackground))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)

            Spacer()

            hexTextField(hex: hex)

            colorSwatch(hex: hex.wrappedValue)

            colorPickerButton(
                selection: Binding(
                    get: { Color(themeHex: hex.wrappedValue) },
                    set: { hex.wrappedValue = $0.toHex(includeAlpha: true) }
                )
            )
        }
    }

    private func colorRowOptional(_ label: String, hex: Binding<String?>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)

            Spacer()

            if hex.wrappedValue != nil {
                hexTextField(
                    hex: Binding(
                        get: { hex.wrappedValue ?? "#000000" },
                        set: { hex.wrappedValue = $0 }
                    )
                )

                colorSwatch(hex: hex.wrappedValue ?? "#000000")

                colorPickerButton(
                    selection: Binding(
                        get: { Color(themeHex: hex.wrappedValue ?? "#000000") },
                        set: { hex.wrappedValue = $0.toHex(includeAlpha: true) }
                    )
                )

                Button(action: { hex.wrappedValue = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(currentTheme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: { hex.wrappedValue = "#000000" }) {
                    Text("Add")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Shared Primitives

    private func hexTextField(hex: Binding<String>) -> some View {
        TextField(
            "",
            text: Binding(
                get: { hex.wrappedValue.uppercased() },
                set: { newValue in
                    let cleaned = newValue.hasPrefix("#") ? newValue : "#" + newValue
                    if cleaned.count <= 9 { hex.wrappedValue = cleaned }
                }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(currentTheme.tertiaryText)
        .multilineTextAlignment(.trailing)
        .frame(width: 72)
    }

    private func colorSwatch(hex: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(themeHex: hex))
            .frame(width: 24, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(currentTheme.primaryBorder, lineWidth: 1))
    }

    private func colorPickerButton(selection: Binding<Color>) -> some View {
        ColorPicker("", selection: selection, supportsOpacity: true)
            .labelsHidden()
            .frame(width: 44)
    }

    private func themeTextField(
        _ placeholder: String,
        text: Binding<String>,
        fontSize: CGFloat,
        weight: Font.Weight = .regular,
        radius: CGFloat
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: weight))
            .padding(.horizontal, 12)
            .padding(.vertical, fontSize > 13 ? 8 : 6)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(currentTheme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: radius).stroke(currentTheme.inputBorder, lineWidth: 1))
            )
            .foregroundColor(currentTheme.primaryText)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)
                .frame(width: 100, alignment: .leading)

            Slider(value: value, in: range)
                .tint(currentTheme.accentColor)

            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(currentTheme.tertiaryText)
                .frame(width: 40)
        }
    }

    private func fontPicker(_ label: String, fontName: Binding<String>, isMono: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(currentTheme.primaryText)
            Spacer()
            Picker("", selection: fontName) {
                ForEach(isMono ? availableMonoFonts : availablePrimaryFonts, id: \.self) { font in
                    Text(font).font(.custom(font, size: 13)).tag(font)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - System Fonts

    private var availablePrimaryFonts: [String] {
        [
            "SF Pro", "Helvetica Neue", "Avenir", "Avenir Next", "Gill Sans", "Optima",
            "Futura", "Verdana", "Trebuchet MS", "Arial", "Lucida Grande", "Geneva",
            "Charter", "Georgia", "Palatino", "Times New Roman", "Baskerville", "Hoefler Text",
        ]
    }

    private var availableMonoFonts: [String] {
        ["SF Mono", "Menlo", "Monaco", "Courier New", "Courier", "Andale Mono", "PT Mono"]
    }

    // MARK: - Actions

    private func saveTheme() {
        var themeToSave = editingTheme

        if editingTheme.isBuiltIn {
            themeToSave.metadata.id = UUID()
            themeToSave.isBuiltIn = false
            if !themeToSave.metadata.name.contains("Copy") && !themeToSave.metadata.name.contains("Custom") {
                themeToSave.metadata.name += " (Custom)"
            }
            themeToSave.metadata.createdAt = Date()
        }

        themeToSave.metadata.updatedAt = Date()

        print("[Osaurus] ThemeEditor: Saving theme '\(themeToSave.metadata.name)' (id: \(themeToSave.metadata.id))")
        themeManager.saveTheme(themeToSave)
        themeManager.applyCustomTheme(themeToSave)
        themeManager.refreshInstalledThemes()
        print("[Osaurus] ThemeEditor: Theme saved and applied successfully")

        withAnimation { showSaveConfirmation = true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [dismiss, onDismiss] in
            withAnimation { showSaveConfirmation = false }
            dismiss()
            onDismiss()
        }
    }

    private static let maxImageDimension: CGFloat = 2048

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                let resizedData = Self.resizeImageData(data, maxDimension: Self.maxImageDimension) ?? data
                editingTheme.background.imageData = resizedData.base64EncodedString()
                editingTheme.background.type = .image
            } catch {
                print("[Osaurus] Failed to import image: \(error)")
            }
        case .failure(let error):
            print("[Osaurus] Image import failed: \(error)")
        }
    }

    private static func resizeImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return nil }

        let scale = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = NSSize(width: round(size.width * scale), height: round(size.height * scale))

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()

        guard let tiffData = newImage.tiffRepresentation,
            let bitmapRep = NSBitmapImageRep(data: tiffData),
            let pngData = bitmapRep.representation(using: .png, properties: [:])
        else { return nil }
        return pngData
    }
}

// MARK: - Theme Chat Preview

struct ThemeChatPreview: View {
    let theme: CustomTheme

    // MARK: - Font Helpers

    private func primaryFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = theme.typography.primaryFont
        if name.lowercased().contains("sf pro") || name.isEmpty { return .system(size: size, weight: weight) }
        return .custom(name, size: size).weight(weight)
    }

    private func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = theme.typography.monoFont
        if name.lowercased().contains("sf mono") || name.isEmpty {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(name, size: size).weight(weight)
    }

    private var bodyFont: Font { primaryFont(size: CGFloat(theme.typography.bodySize)) }
    private var captionSize: CGFloat { CGFloat(theme.typography.captionSize) }
    private var codeFont: Font { monoFont(size: CGFloat(theme.typography.codeSize)) }

    /// Shorthand for theme hex colors
    private func c(_ hex: String) -> Color { Color(themeHex: hex) }

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundLayer

            if theme.glass.enabled { glassOverlay }

            VStack(spacing: 0) {
                previewHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ScrollView {
                    VStack(spacing: 0) {
                        previewMessageBlock(
                            role: "You",
                            content: "Hey there! Can you help me with something?",
                            isUser: true
                        )
                        previewAssistantMessage()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                Spacer()

                previewInput
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(c(theme.colors.primaryBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(c(theme.glass.edgeLight).opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Messages

    private func previewMessageBlock(role: String, content: String, isUser: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(role)
                    .font(primaryFont(size: captionSize + 1, weight: .semibold))
                    .foregroundColor(isUser ? c(theme.colors.accentColor) : c(theme.colors.secondaryText))
                Spacer()
            }

            Text(content)
                .font(bodyFont)
                .foregroundColor(c(theme.colors.primaryText))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isUser
                ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(c(theme.colors.secondaryBackground).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(c(theme.colors.primaryBorder).opacity(0.3), lineWidth: 1)
                    )
                : nil
        )
    }

    private func previewAssistantMessage() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assistant")
                .font(primaryFont(size: captionSize + 1, weight: .semibold))
                .foregroundColor(c(theme.colors.secondaryText))

            Text("Sure! Here's an example:")
                .font(bodyFont)
                .foregroundColor(c(theme.colors.primaryText))

            VStack(alignment: .leading, spacing: 4) {
                Text("swift")
                    .font(monoFont(size: captionSize, weight: .medium))
                    .foregroundColor(c(theme.colors.tertiaryText))
                    .padding(.horizontal, 10).padding(.top, 8)

                Text("print(\"Hello, World!\")")
                    .font(codeFont)
                    .foregroundColor(c(theme.colors.primaryText))
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(c(theme.colors.codeBlockBackground)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Background & Glass

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            switch theme.background.type {
            case .solid:
                c(theme.background.solidColor ?? theme.colors.primaryBackground)
            case .gradient:
                LinearGradient(
                    colors: (theme.background.gradientColors ?? ["#000000", "#333333"]).map { c($0) },
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .image:
                if let imageData = theme.background.imageData,
                    let data = Data(base64Encoded: imageData),
                    let nsImage = NSImage(data: data)
                {
                    GeometryReader { geo in
                        imageView(nsImage: nsImage, fit: theme.background.imageFit ?? .fill, size: geo.size)
                            .opacity(theme.background.imageOpacity ?? 1.0)
                    }
                }
            }

            if let overlayColor = theme.background.overlayColor {
                c(overlayColor).opacity(theme.background.overlayOpacity ?? 0.5)
            }
        }
    }

    @ViewBuilder
    private func imageView(nsImage: NSImage, fit: ThemeBackground.ImageFit, size: CGSize) -> some View {
        switch fit {
        case .fill:
            Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height).clipped()
        case .fit:
            Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        case .stretch:
            Image(nsImage: nsImage).resizable().frame(width: size.width, height: size.height)
        case .tile:
            tiledImageView(nsImage: nsImage, size: size)
        }
    }

    private func tiledImageView(nsImage: NSImage, size: CGSize) -> some View {
        let imgSize = nsImage.size
        let cols = max(1, Int(ceil(size.width / imgSize.width)))
        let rows = max(1, Int(ceil(size.height / imgSize.height)))

        return VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0 ..< cols, id: \.self) { _ in Image(nsImage: nsImage) }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var glassOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)

            if let tintColor = theme.glass.tintColor {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(c(tintColor).opacity(theme.glass.tintOpacity ?? 0))
            }

            LinearGradient(
                colors: [
                    c(theme.colors.primaryBackground).opacity(theme.glass.opacityPrimary),
                    c(theme.colors.primaryBackground).opacity(theme.glass.opacitySecondary),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Header

    private var previewHeader: some View {
        HStack(spacing: 10) {
            headerButton("sidebar.left")

            // Chat / Work mode toggle
            HStack(spacing: 0) {
                modeSegment("bubble.left.and.bubble.right", "Chat", isActive: true)
                modeSegment("bolt.fill", "Work", isActive: false)
            }
            .padding(3)
            .background(Capsule().fill(c(theme.colors.secondaryBackground).opacity(0.6)))

            // Model badge
            HStack(spacing: 5) {
                Circle().fill(c(theme.colors.successColor)).frame(width: 6, height: 6)
                Text("gpt-4")
                    .font(primaryFont(size: captionSize - 1, weight: .medium))
                    .foregroundColor(c(theme.colors.secondaryText))
            }

            Spacer()

            headerButton("plus")
            headerButton("pin")
        }
    }

    private func headerButton(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(c(theme.colors.secondaryText))
            .frame(width: 28, height: 28)
            .background(Circle().fill(c(theme.colors.secondaryBackground).opacity(0.6)))
    }

    private func modeSegment(_ icon: String, _ label: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(label).font(primaryFont(size: captionSize - 1, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Capsule().fill(c(theme.colors.accentColor).opacity(0.15)) : nil)
        .foregroundColor(isActive ? c(theme.colors.accentColor) : c(theme.colors.tertiaryText))
    }

    // MARK: - Input

    private var previewInput: some View {
        VStack(spacing: 8) {
            // Selector row
            HStack(spacing: 10) {
                selectorChip {
                    Circle().fill(c(theme.colors.successColor)).frame(width: 6, height: 6)
                    Text("gpt-4").font(primaryFont(size: captionSize - 1, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }

                selectorChip {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .medium))
                    Text("3 tools").font(primaryFont(size: captionSize - 1, weight: .medium))
                }

                Spacer()

                HStack(spacing: 3) {
                    Text("⏎").font(primaryFont(size: captionSize - 2, weight: .medium))
                    Text("to send").font(primaryFont(size: captionSize - 1))
                }
                .foregroundColor(c(theme.colors.tertiaryText).opacity(0.6))
            }

            // Input card
            VStack(alignment: .leading, spacing: 0) {
                Text("Message or paste image...")
                    .font(bodyFont)
                    .foregroundColor(c(theme.colors.placeholderText ?? theme.colors.tertiaryText))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 13, weight: .medium))
                        .foregroundColor(c(theme.colors.tertiaryText))
                    Image(systemName: "mic.fill").font(.system(size: 13, weight: .medium))
                        .foregroundColor(c(theme.colors.tertiaryText))

                    Spacer()

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [c(theme.colors.accentColor), c(theme.colors.accentColor).opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        )
                        .shadow(
                            color: c(theme.colors.accentColor).opacity(theme.shadows.shadowOpacity * 0.5),
                            radius: 4,
                            x: 0,
                            y: 2
                        )
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(c(theme.colors.primaryBackground).opacity(0.6))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [c(theme.glass.edgeLight), c(theme.glass.edgeLight).opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(
                color: c(theme.colors.shadowColor).opacity(theme.shadows.shadowOpacity),
                radius: CGFloat(theme.shadows.cardShadowRadius),
                x: 0,
                y: CGFloat(theme.shadows.cardShadowY)
            )
        }
    }

    private func selectorChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .foregroundColor(c(theme.colors.secondaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(c(theme.colors.secondaryBackground).opacity(0.8))
                    .overlay(Capsule().stroke(c(theme.colors.primaryBorder).opacity(0.4), lineWidth: 0.5))
            )
    }
}
