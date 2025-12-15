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
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Use computed property to always get the current theme from ThemeManager
    private var currentTheme: ThemeProtocol { themeManager.currentTheme }

    @State private var editingTheme: CustomTheme
    let onDismiss: () -> Void

    @State private var selectedTab: EditorTab = .colors
    @State private var showImagePicker = false
    @State private var showSaveConfirmation = false

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

    var body: some View {
        HSplitView {
            // Editor panel
            editorPanel
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 450)

            // Live preview
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
            // Header
            editorHeader

            // Tab selector
            tabSelector

            // Tab content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .colors:
                        colorsEditor
                    case .background:
                        backgroundEditor
                    case .glass:
                        glassEditor
                    case .typography:
                        typographyEditor
                    case .animation:
                        animationEditor
                    }
                }
                .padding(20)
            }

            // Footer actions
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

            // Theme name field
            TextField("Theme Name", text: $editingTheme.metadata.name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(currentTheme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(currentTheme.inputBorder, lineWidth: 1)
                        )
                )
                .foregroundColor(currentTheme.primaryText)

            // Author name field
            TextField("Author Name", text: $editingTheme.metadata.author)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(currentTheme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(currentTheme.inputBorder, lineWidth: 1)
                        )
                )
                .foregroundColor(currentTheme.primaryText)
        }
        .padding(16)
    }

    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EditorTab.allCases, id: \.rawValue) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: .medium))
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
                    dismiss()
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button(action: saveTheme) {
                    HStack(spacing: 4) {
                        if showSaveConfirmation {
                            Image(systemName: "checkmark")
                        }
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
            editorSection("Text Colors") {
                colorRow("Primary Text", hex: $editingTheme.colors.primaryText)
                colorRow("Secondary Text", hex: $editingTheme.colors.secondaryText)
                colorRow("Tertiary Text", hex: $editingTheme.colors.tertiaryText)
            }

            editorSection("Background Colors") {
                colorRow("Primary", hex: $editingTheme.colors.primaryBackground)
                colorRow("Secondary", hex: $editingTheme.colors.secondaryBackground)
                colorRow("Tertiary", hex: $editingTheme.colors.tertiaryBackground)
            }

            editorSection("Sidebar Colors") {
                colorRow("Background", hex: $editingTheme.colors.sidebarBackground)
                colorRow("Selected", hex: $editingTheme.colors.sidebarSelectedBackground)
            }

            editorSection("Accent Colors") {
                colorRow("Primary Accent", hex: $editingTheme.colors.accentColor)
                colorRow("Light Accent", hex: $editingTheme.colors.accentColorLight)
            }

            editorSection("Status Colors") {
                colorRow("Success", hex: $editingTheme.colors.successColor)
                colorRow("Warning", hex: $editingTheme.colors.warningColor)
                colorRow("Error", hex: $editingTheme.colors.errorColor)
                colorRow("Info", hex: $editingTheme.colors.infoColor)
            }

            editorSection("Border Colors") {
                colorRow("Primary", hex: $editingTheme.colors.primaryBorder)
                colorRow("Secondary", hex: $editingTheme.colors.secondaryBorder)
                colorRow("Focus", hex: $editingTheme.colors.focusBorder)
            }

            editorSection("Component Colors") {
                colorRow("Card Background", hex: $editingTheme.colors.cardBackground)
                colorRow("Card Border", hex: $editingTheme.colors.cardBorder)
                colorRow("Button Background", hex: $editingTheme.colors.buttonBackground)
                colorRow("Button Border", hex: $editingTheme.colors.buttonBorder)
                colorRow("Input Background", hex: $editingTheme.colors.inputBackground)
                colorRow("Input Border", hex: $editingTheme.colors.inputBorder)
            }

            editorSection("Code & Glass") {
                colorRow("Glass Tint", hex: $editingTheme.colors.glassTintOverlay)
                colorRow("Code Block", hex: $editingTheme.colors.codeBlockBackground)
            }

            editorSection("Selection") {
                colorRow("Text Selection", hex: $editingTheme.colors.selectionColor)
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

            // Solid color picker
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

                            Button("Remove Image") {
                                editingTheme.background.imageData = nil
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(action: { showImagePicker = true }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 24))
                                    Text("Choose Image")
                                        .font(.system(size: 13, weight: .medium))
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
                        // Use indices with direct binding to avoid stale captures
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
                            }) {
                                Label("Add Color", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)

                            if (editingTheme.background.gradientColors?.count ?? 0) > 2 {
                                Button(action: {
                                    editingTheme.background.gradientColors?.removeLast()
                                }) {
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

    @State private var animationPreviewTrigger = false

    private var animationEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Animation Preview
            editorSection("Preview") {
                VStack(spacing: 12) {
                    HStack {
                        // Spring animation preview
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
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(currentTheme.tertiaryBackground.opacity(0.5))
                    )

                    Button("Test Animation") {
                        animationPreviewTrigger.toggle()
                    }
                    .buttonStyle(.bordered)
                }
            }

            editorSection("Duration") {
                Text("Controls how long animations take")
                    .font(.system(size: 11))
                    .foregroundColor(currentTheme.tertiaryText)
                    .padding(.bottom, 4)

                sliderRow("Quick", value: $editingTheme.animationConfig.durationQuick, range: 0.05 ... 0.5)
                sliderRow("Medium", value: $editingTheme.animationConfig.durationMedium, range: 0.1 ... 0.8)
                sliderRow("Slow", value: $editingTheme.animationConfig.durationSlow, range: 0.2 ... 1.0)
            }

            editorSection("Spring Physics") {
                Text("Response: How fast the spring moves\nDamping: How quickly it settles (lower = more bounce)")
                    .font(.system(size: 11))
                    .foregroundColor(currentTheme.tertiaryText)
                    .padding(.bottom, 4)

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
            // Preview header
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

            // Chat preview
            ThemeChatPreview(theme: editingTheme)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(20)
        }
    }

    // MARK: - Helper Views

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(currentTheme.secondaryText)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(currentTheme.cardBackground)
            )
        }
    }

    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)

            Spacer()

            // Color swatch preview
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(themeHex: hex.wrappedValue))
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(currentTheme.primaryBorder, lineWidth: 1)
                )

            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(themeHex: hex.wrappedValue) },
                    set: { newColor in
                        hex.wrappedValue = newColor.toHex(includeAlpha: true)
                    }
                ),
                supportsOpacity: true
            )
            .labelsHidden()
            .frame(width: 44)
        }
    }

    private func colorRowOptional(_ label: String, hex: Binding<String?>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)

            Spacer()

            HStack(spacing: 8) {
                if hex.wrappedValue != nil {
                    // Color swatch preview
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(themeHex: hex.wrappedValue ?? "#000000"))
                        .frame(width: 24, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(currentTheme.primaryBorder, lineWidth: 1)
                        )

                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Color(themeHex: hex.wrappedValue ?? "#000000") },
                            set: { newColor in
                                hex.wrappedValue = newColor.toHex(includeAlpha: true)
                            }
                        ),
                        supportsOpacity: true
                    )
                    .labelsHidden()
                    .frame(width: 44)

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

    private func fontPicker(_ label: String, fontName: Binding<String>, isMono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)

            Spacer()

            Picker("", selection: fontName) {
                ForEach(isMono ? availableMonoFonts : availablePrimaryFonts, id: \.self) { font in
                    Text(font)
                        .font(.custom(font, size: 13))
                        .tag(font)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - Available System Fonts (macOS built-in)

    /// Primary fonts - readable sans-serif fonts included with macOS
    private var availablePrimaryFonts: [String] {
        [
            "SF Pro",  // System default
            "Helvetica Neue",  // Classic Apple font
            "Avenir",  // Modern humanist sans
            "Avenir Next",  // Refined Avenir
            "Gill Sans",  // British humanist sans
            "Optima",  // Elegant sans
            "Futura",  // Geometric sans
            "Verdana",  // Screen-optimized
            "Trebuchet MS",  // Friendly sans
            "Arial",  // Universal sans
            "Lucida Grande",  // Former macOS system font
            "Geneva",  // Classic Mac font
            "Charter",  // Readable serif
            "Georgia",  // Screen serif
            "Palatino",  // Elegant serif
            "Times New Roman",  // Classic serif
            "Baskerville",  // Traditional serif
            "Hoefler Text",  // Apple's premium serif
        ]
    }

    /// Monospace fonts - code-friendly fonts included with macOS
    private var availableMonoFonts: [String] {
        [
            "SF Mono",  // System mono
            "Menlo",  // Apple's code font
            "Monaco",  // Classic Mac mono
            "Courier New",  // Universal mono
            "Courier",  // Original mono
            "Andale Mono",  // Clean mono
            "PT Mono",  // Pleasant mono
        ]
    }

    // MARK: - Actions

    private func saveTheme() {
        var themeToSave = editingTheme

        // If it's a built-in theme, create a copy
        if editingTheme.isBuiltIn {
            themeToSave.metadata.id = UUID()
            themeToSave.isBuiltIn = false
            if !themeToSave.metadata.name.contains("Copy") && !themeToSave.metadata.name.contains("Custom") {
                themeToSave.metadata.name += " (Custom)"
            }
            // Set creation date for new themes
            themeToSave.metadata.createdAt = Date()
        }

        themeToSave.metadata.updatedAt = Date()

        // Save the theme to disk
        print("[Osaurus] ThemeEditor: Saving theme '\(themeToSave.metadata.name)' (id: \(themeToSave.metadata.id))")
        themeManager.saveTheme(themeToSave)

        // Apply the theme
        themeManager.applyCustomTheme(themeToSave)

        // Refresh themes list to ensure UI is up to date
        themeManager.refreshInstalledThemes()

        print("[Osaurus] ThemeEditor: Theme saved and applied successfully")

        withAnimation {
            showSaveConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [dismiss, onDismiss] in
            withAnimation {
                showSaveConfirmation = false
            }
            dismiss()
            onDismiss()
        }
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                editingTheme.background.imageData = data.base64EncodedString()
                editingTheme.background.type = .image
            } catch {
                print("[Osaurus] Failed to import image: \(error)")
            }
        case .failure(let error):
            print("[Osaurus] Image import failed: \(error)")
        }
    }
}

// MARK: - Theme Chat Preview

struct ThemeChatPreview: View {
    let theme: CustomTheme

    // MARK: - Font Helpers using theme font families

    private func primaryFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = theme.typography.primaryFont
        if fontName.lowercased().contains("sf pro") || fontName.isEmpty {
            return .system(size: size, weight: weight)
        }
        // Use Font.custom with family name - SwiftUI handles weight variants
        return .custom(fontName, size: size).weight(weight)
    }

    private func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = theme.typography.monoFont
        if fontName.lowercased().contains("sf mono") || fontName.isEmpty {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        // Use Font.custom with family name - SwiftUI handles weight variants
        return .custom(fontName, size: size).weight(weight)
    }

    // Convenience computed properties
    private var bodyFont: Font {
        primaryFont(size: CGFloat(theme.typography.bodySize))
    }

    private var captionFont: Font {
        primaryFont(size: CGFloat(theme.typography.captionSize))
    }

    private var headingFont: Font {
        primaryFont(size: CGFloat(theme.typography.headingSize), weight: .semibold)
    }

    private var codeFont: Font {
        monoFont(size: CGFloat(theme.typography.codeSize))
    }

    var body: some View {
        ZStack {
            // Background layer with glass effect
            backgroundLayer

            // Glass overlay effect (only if enabled)
            if theme.glass.enabled {
                glassOverlay
            }

            // Content
            VStack(spacing: 0) {
                // Mock header
                previewHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                // Mock messages - using actual MessageRow style
                ScrollView {
                    VStack(spacing: 8) {
                        // User message
                        previewMessageRow(
                            role: "You",
                            content: "Hey there! Can you help me with something?",
                            isUser: true
                        )

                        // Assistant message with code block
                        previewAssistantMessage()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Spacer()

                // Mock input - matches FloatingInputCard styling
                previewInput
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .background(Color(themeHex: theme.colors.primaryBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(themeHex: theme.glass.edgeLight).opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Message Row (matches actual MessageRow.swift)

    private func previewMessageRow(role: String, content: String, isUser: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent bar indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    isUser
                        ? Color(themeHex: theme.colors.accentColor)
                        : Color(themeHex: theme.colors.tertiaryText).opacity(0.4)
                )
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 12)

            // Message content
            VStack(alignment: .leading, spacing: 8) {
                // Role label - uses caption size with theme font
                Text(role)
                    .font(primaryFont(size: CGFloat(theme.typography.captionSize) + 1, weight: .semibold))
                    .foregroundColor(
                        isUser ? Color(themeHex: theme.colors.accentColor) : Color(themeHex: theme.colors.secondaryText)
                    )

                // Content - uses body size with theme font
                Text(content)
                    .font(bodyFont)
                    .foregroundColor(Color(themeHex: theme.colors.primaryText))
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 16)

            Spacer(minLength: 0)
        }
        .background(
            isUser
                ? Color(themeHex: theme.colors.secondaryBackground).opacity(0.5)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // Assistant message with code block to showcase more typography
    private func previewAssistantMessage() -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(themeHex: theme.colors.tertiaryText).opacity(0.4))
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 12)

            // Message content with code
            VStack(alignment: .leading, spacing: 8) {
                // Role label - uses theme font
                Text("Assistant")
                    .font(primaryFont(size: CGFloat(theme.typography.captionSize) + 1, weight: .semibold))
                    .foregroundColor(Color(themeHex: theme.colors.secondaryText))

                // Text content - uses theme font
                Text("Sure! Here's an example:")
                    .font(bodyFont)
                    .foregroundColor(Color(themeHex: theme.colors.primaryText))

                // Code block - uses mono theme font
                VStack(alignment: .leading, spacing: 4) {
                    Text("swift")
                        .font(monoFont(size: CGFloat(theme.typography.captionSize), weight: .medium))
                        .foregroundColor(Color(themeHex: theme.colors.tertiaryText))
                        .padding(.horizontal, 8)
                        .padding(.top, 6)

                    Text("print(\"Hello, World!\")")
                        .font(codeFont)
                        .foregroundColor(Color(themeHex: theme.colors.primaryText))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(themeHex: theme.colors.codeBlockBackground))
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 16)

            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            switch theme.background.type {
            case .solid:
                Color(themeHex: theme.background.solidColor ?? theme.colors.primaryBackground)

            case .gradient:
                let colors = (theme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                LinearGradient(
                    colors: colors,
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

            // Overlay (applies to all background types)
            if let overlayColor = theme.background.overlayColor {
                Color(themeHex: overlayColor)
                    .opacity(theme.background.overlayOpacity ?? 0.5)
            }
        }
    }

    @ViewBuilder
    private func imageView(nsImage: NSImage, fit: ThemeBackground.ImageFit, size: CGSize) -> some View {
        switch fit {
        case .fill:
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        case .fit:
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        case .stretch:
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size.width, height: size.height)
        case .tile:
            tiledImageView(nsImage: nsImage, size: size)
        }
    }

    private func tiledImageView(nsImage: NSImage, size: CGSize) -> some View {
        let imageSize = nsImage.size
        let cols = max(1, Int(ceil(size.width / imageSize.width)))
        let rows = max(1, Int(ceil(size.height / imageSize.height)))

        return VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0 ..< cols, id: \.self) { _ in
                        Image(nsImage: nsImage)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var glassOverlay: some View {
        ZStack {
            // Glass effect simulation
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)

            // Tint overlay if configured
            if let tintColor = theme.glass.tintColor {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(themeHex: tintColor).opacity(theme.glass.tintOpacity ?? 0))
            }

            // Gradient depth overlay using glass opacity
            LinearGradient(
                colors: [
                    Color(themeHex: theme.colors.primaryBackground).opacity(theme.glass.opacityPrimary),
                    Color(themeHex: theme.colors.primaryBackground).opacity(theme.glass.opacitySecondary),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var previewHeader: some View {
        HStack {
            // Sidebar toggle mock
            Circle()
                .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.8))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "sidebar.left")
                        .font(primaryFont(size: CGFloat(theme.typography.captionSize), weight: .medium))
                        .foregroundColor(Color(themeHex: theme.colors.secondaryText))
                )

            Spacer()

            // Actions mock
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.8))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "plus")
                            .font(primaryFont(size: CGFloat(theme.typography.captionSize), weight: .medium))
                            .foregroundColor(Color(themeHex: theme.colors.secondaryText))
                    )

                Circle()
                    .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.8))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(primaryFont(size: CGFloat(theme.typography.captionSize) - 2, weight: .semibold))
                            .foregroundColor(Color(themeHex: theme.colors.secondaryText))
                    )
            }
        }
    }

    private var previewInput: some View {
        VStack(spacing: 12) {
            // Model selector chip
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(themeHex: theme.colors.successColor))
                        .frame(width: 6, height: 6)
                    Text("gpt-4")
                        .font(captionFont)
                        .foregroundColor(Color(themeHex: theme.colors.secondaryText))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(primaryFont(size: CGFloat(theme.typography.captionSize) - 3, weight: .semibold))
                        .foregroundColor(Color(themeHex: theme.colors.tertiaryText))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.8))
                        .overlay(
                            Capsule()
                                .stroke(Color(themeHex: theme.colors.primaryBorder).opacity(0.5), lineWidth: 0.5)
                        )
                )

                Spacer()

                // Keyboard hint
                HStack(spacing: 4) {
                    Text("⏎")
                        .font(primaryFont(size: CGFloat(theme.typography.captionSize) - 2, weight: .medium))
                    Text("to send")
                        .font(primaryFont(size: CGFloat(theme.typography.captionSize) - 1))
                }
                .foregroundColor(Color(themeHex: theme.colors.tertiaryText).opacity(0.7))
            }

            // Input card
            HStack(alignment: .bottom, spacing: 12) {
                Text("Message or paste image...")
                    .font(bodyFont)
                    .foregroundColor(Color(themeHex: theme.colors.tertiaryText))

                Spacer()

                // Send button with gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(themeHex: theme.colors.accentColor),
                                Color(themeHex: theme.colors.accentColor).opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(primaryFont(size: CGFloat(theme.typography.bodySize), weight: .semibold))
                            .foregroundColor(.white)
                    )
                    .shadow(
                        color: Color(themeHex: theme.colors.accentColor).opacity(theme.shadows.shadowOpacity),
                        radius: CGFloat(theme.shadows.cardShadowRadius),
                        x: 0,
                        y: CGFloat(theme.shadows.cardShadowY)
                    )
            }
            .padding(12)
            .background(
                ZStack {
                    // Glass background
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // Tint overlay
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(themeHex: theme.colors.primaryBackground).opacity(0.6))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(themeHex: theme.glass.edgeLight),
                                Color(themeHex: theme.glass.edgeLight).opacity(0.3),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(
                color: Color(themeHex: theme.colors.shadowColor).opacity(theme.shadows.shadowOpacity),
                radius: CGFloat(theme.shadows.cardShadowRadius),
                x: 0,
                y: CGFloat(theme.shadows.cardShadowY)
            )
        }
    }
}
