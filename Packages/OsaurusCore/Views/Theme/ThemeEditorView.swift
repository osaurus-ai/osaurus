//
//  ThemeEditorView.swift
//  osaurus
//
//  Live theme editor with real-time preview and all customization controls
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Decodes a theme background's base64 image data off the main actor.
/// Decoding a multi-megabyte string and parsing the image inline in a view
/// body blocks the UI on every layout pass, so callers run this once and
/// cache the result in view state.
private func decodeThemeBackgroundImage(_ base64: String?) async -> NSImage? {
    guard let base64 else { return nil }
    return await Task.detached(priority: .userInitiated) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }.value
}

struct ThemeEditorView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var currentTheme: ThemeProtocol { themeManager.currentTheme }

    @State private var editingTheme: CustomTheme
    @State private var showImagePicker = false
    @State private var showSaveConfirmation = false
    @State private var collapsedSections: Set<String> = ["Advanced Colors", "Advanced", "Raw JSON"]
    @State private var animationPreviewTrigger = false
    @State private var showGlassPerformanceWarning = false
    /// Reverts the glass toggle the user just turned on if they cancel the
    /// performance-warning alert. Captured as a closure so the same alert
    /// can serve any of the three independent glass toggles.
    @State private var pendingGlassRevert: (() -> Void)?
    /// Decoded copy of `editingTheme.background.imageData`, refreshed off
    /// the main actor whenever the base64 string changes.
    @State private var backgroundPreviewImage: NSImage?
    @State private var rawThemeJSON: String
    @State private var rawThemeJSONError: String?
    @State private var rawThemeJSONIsDirty = false
    /// Pending debounced re-encode of the Raw JSON text. A color-picker drag
    /// mutates `editingTheme` many times per second, and pretty-printing the
    /// whole theme plus replacing the TextEditor text on every tick made the
    /// picker stutter.
    @State private var rawThemeJSONSyncTask: Task<Void, Never>?
    /// True when the user has edited the Raw JSON text and then changed a
    /// control, so the JSON no longer reflects the theme. Surfaced as a
    /// warning because Apply JSON would silently revert those changes.
    @State private var rawThemeJSONIsStale = false
    /// Error surfaced when a background image fails to import.
    @State private var imageImportError: String?
    @State private var showImageImportError = false
    /// Accent hex set by Apply JSON, so the accent-derivation hook can tell
    /// a JSON apply apart from a color-row edit.
    @State private var accentHexFromRawJSON: String?

    let onDismiss: () -> Void

    private var isSaving: Bool { showSaveConfirmation }

    init(theme: CustomTheme, onDismiss: @escaping () -> Void) {
        _editingTheme = State(initialValue: theme)
        _rawThemeJSON = State(initialValue: (try? ThemeJSONEditorCodec.encodeForEditor(theme)) ?? "{}")
        self.onDismiss = onDismiss
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
        .task(id: editingTheme.background.imageData) {
            backgroundPreviewImage = await decodeThemeBackgroundImage(editingTheme.background.imageData)
        }
        .onChange(of: editingTheme) { _, _ in
            if rawThemeJSONIsDirty {
                rawThemeJSONIsStale = true
            }
            scheduleRawThemeJSONSync()
        }
        .onChange(of: editingTheme.colors.accentColor) { oldHex, newHex in
            rederiveAccentColors(from: oldHex, to: newHex)
        }
        .onDisappear {
            rawThemeJSONSyncTask?.cancel()
        }
        .themedAlert(
            L("Couldn't Import Image"),
            isPresented: $showImageImportError,
            message: imageImportError,
            primaryButton: .primary(L("OK")) {
                imageImportError = nil
            }
        )
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageImport(result)
        }
        .themedAlert(
            L("Enable Glass Background?"),
            isPresented: $showGlassPerformanceWarning,
            message: String(
                localized:
                    "Glass effects use behind-window blur and additional compositing layers. This may impact performance, especially on older Macs or under heavy load.",
                bundle: .module
            ),
            primaryButton: .primary(L("Enable")) {
                pendingGlassRevert = nil
            },
            secondaryButton: .cancel(L("Cancel")) {
                pendingGlassRevert?()
                pendingGlassRevert = nil
            }
        )
        .themedAlertScope(.content)
        .overlay(ThemedAlertHost(scope: .content))
    }

    // MARK: - Editor Panel

    private var editorPanel: some View {
        VStack(spacing: 0) {
            editorHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearanceSection
                    glassSection
                    codeSection
                    colorsSection
                    messagesSection
                    textAndFontsSection
                    bordersAndEffectsSection
                    advancedSection
                    rawJSONSection
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
                Text("Theme Editor", bundle: .module)
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

            themeTextField(L("Theme Name"), text: $editingTheme.metadata.name, fontSize: 14, weight: .medium, radius: 8)
            themeTextField(L("Author Name"), text: $editingTheme.metadata.author, fontSize: 13, radius: 6)
        }
        .padding(16)
    }

    private var editorFooter: some View {
        HStack {
            if editingTheme.isBuiltIn {
                Label {
                    Text("Built-in themes cannot be modified directly", bundle: .module)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: 11))
                .foregroundColor(currentTheme.warningColor)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    dismiss(); onDismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(.bordered)

                Button(action: saveTheme) {
                    HStack(spacing: 4) {
                        if showSaveConfirmation { Image(systemName: "checkmark") }
                        Text(
                            LocalizedStringKey(
                                showSaveConfirmation ? "Saved!" : (editingTheme.isBuiltIn ? "Save as Copy" : "Save")
                            ),
                            bundle: .module
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                // Save stays visible for the "Saved!" confirmation, and a
                // second click in that window used to mint another copy.
                .disabled(isSaving)
            }
        }
        .padding(16)
        .background(currentTheme.secondaryBackground)
    }

    // MARK: - Section 1: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Appearance") {
                toggleRow("Follow System Accent", isOn: $editingTheme.followsSystemAccent)

                // The app substitutes the macOS accent at runtime when the
                // theme follows it, so an edited accent would never show
                // outside the editor. Make that visible instead of silently
                // ignoring the pick.
                colorRow("Accent Color", hex: $editingTheme.colors.accentColor)
                    .disabled(editingTheme.followsSystemAccent)
                    .opacity(editingTheme.followsSystemAccent ? 0.5 : 1)
                if editingTheme.followsSystemAccent {
                    Text("Turn off Follow System Accent to choose a custom accent color.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(currentTheme.tertiaryText)
                }

                HStack {
                    Text("Mode", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(currentTheme.primaryText)
                    Spacer()
                    Picker("", selection: $editingTheme.isDark) {
                        Text("Dark", bundle: .module).tag(true)
                        Text("Light", bundle: .module).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                Picker(selection: $editingTheme.background.type) {
                    Text("Solid", bundle: .module).tag(ThemeBackground.BackgroundType.solid)
                    Text("Gradient", bundle: .module).tag(ThemeBackground.BackgroundType.gradient)
                    Text("Image", bundle: .module).tag(ThemeBackground.BackgroundType.image)
                } label: {
                    Text("Background", bundle: .module)
                }
                .pickerStyle(.segmented)

                if editingTheme.background.type == .image {
                    imageBackgroundControls
                }
            }
        }
    }

    // MARK: - Section: Glass

    private var glassSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Glass") {
                glassToggleRow(
                    label: "Chat Area",
                    isOn: Binding(
                        get: { editingTheme.glass.enabled },
                        set: { editingTheme.glass.enabled = $0 }
                    ),
                    revert: { editingTheme.glass.enabled = false }
                )
                glassToggleRow(
                    label: "Sidebar",
                    isOn: Binding(
                        get: { editingTheme.glass.sidebarEnabled },
                        set: { editingTheme.glass.sidebarEnabled = $0 }
                    ),
                    revert: { editingTheme.glass.sidebarEnabled = false }
                )
                glassToggleRow(
                    label: "Prompt Box",
                    isOn: Binding(
                        get: { editingTheme.glass.inputEnabled },
                        set: { editingTheme.glass.inputEnabled = $0 }
                    ),
                    revert: { editingTheme.glass.inputEnabled = false }
                )

                if editingTheme.background.type == .image {
                    Text("Disabled while using an image background.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(currentTheme.tertiaryText)
                }
            }
        }
        .onChange(of: editingTheme.background.type) { _, newType in
            // Image backgrounds composite poorly with behind-window blur;
            // force all three glass toggles off when the user switches to
            // an image background.
            if newType == .image {
                editingTheme.glass.enabled = false
                editingTheme.glass.sidebarEnabled = false
                editingTheme.glass.inputEnabled = false
            }
        }
    }

    /// One row of the Glass section. Disabled when the theme uses an image
    /// background. Turning a toggle ON triggers the performance-warning
    /// alert; cancelling the alert calls `revert` to undo the change.
    private func glassToggleRow(
        label: LocalizedStringKey,
        isOn: Binding<Bool>,
        revert: @escaping () -> Void
    ) -> some View {
        let isImageBackground = editingTheme.background.type == .image
        return HStack {
            Text(label, bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(isImageBackground ? currentTheme.tertiaryText : currentTheme.primaryText)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn.wrappedValue && !isImageBackground },
                    set: { newValue in
                        isOn.wrappedValue = newValue
                        if newValue {
                            pendingGlassRevert = revert
                            showGlassPerformanceWarning = true
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(currentTheme.accentColor)
            .disabled(isImageBackground)
        }
    }

    // MARK: - Section 2: Code

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Code") {
                codeHighlightThemePicker
                colorRow("Code Block BG", hex: $editingTheme.colors.codeBlockBackground)
                colorRow("Text Selection", hex: $editingTheme.colors.selectionColor)
                colorRow("Cursor", hex: $editingTheme.colors.cursorColor)
                colorRow("Shadow", hex: $editingTheme.colors.shadowColor)
            }
        }
    }

    // MARK: - Section 3: Colors

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Colors") {
                colorRow("Primary Text", hex: $editingTheme.colors.primaryText)
                colorRow("Secondary Text", hex: $editingTheme.colors.secondaryText)
                colorRow("Tertiary Text", hex: $editingTheme.colors.tertiaryText)

                Divider().opacity(0.3)

                colorRow("Primary BG", hex: $editingTheme.colors.primaryBackground)
                colorRow("Secondary BG", hex: $editingTheme.colors.secondaryBackground)
                colorRow("Tertiary BG", hex: $editingTheme.colors.tertiaryBackground)
            }

            editorSection("Advanced Colors", itemCount: 7) {
                colorRowOptional("Placeholder", hex: $editingTheme.colors.placeholderText)

                Text("Status", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                )
                .textCase(.uppercase)
                colorRow("Success", hex: $editingTheme.colors.successColor)
                colorRow("Warning", hex: $editingTheme.colors.warningColor)
                colorRow("Error", hex: $editingTheme.colors.errorColor)

                Text("Components", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                )
                .textCase(.uppercase)
                colorRow("Card BG", hex: $editingTheme.colors.cardBackground)
                colorRow("Card Border", hex: $editingTheme.colors.cardBorder)
                colorRow("Button BG", hex: $editingTheme.colors.buttonBackground)
                colorRow("Button Border", hex: $editingTheme.colors.buttonBorder)
                colorRow("Input BG", hex: $editingTheme.colors.inputBackground)
                colorRow("Input Border", hex: $editingTheme.colors.inputBorder)
            }
        }
    }

    // MARK: - Section 3: Messages

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Messages") {
                Text("User Bubble", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                ).textCase(.uppercase)
                colorRowOptional("Bubble Color", hex: $editingTheme.messages.userBubbleColor)
                sliderRow("Opacity", value: $editingTheme.messages.userBubbleOpacity, range: 0 ... 1)

                Divider().opacity(0.3)

                Text("Assistant Bubble", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                ).textCase(.uppercase)
                colorRowOptional("Bubble Color", hex: $editingTheme.messages.assistantBubbleColor)
                sliderRow("Opacity", value: $editingTheme.messages.assistantBubbleOpacity, range: 0 ... 1)

                Divider().opacity(0.3)

                Text("Agent Avatar", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                ).textCase(.uppercase)
                toggleRow("Show in chat", isOn: $editingTheme.messages.showInlineAvatar)
                sliderRow("Size", value: $editingTheme.messages.inlineAvatarSize, range: 16 ... 108)
                    .disabled(!editingTheme.messages.showInlineAvatar)
                    .opacity(editingTheme.messages.showInlineAvatar ? 1 : 0.5)

                Divider().opacity(0.3)

                Text("Agent Name", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                ).textCase(.uppercase)
                toggleRow("Show in chat", isOn: $editingTheme.messages.showAgentName)
                sliderRow("Name Size", value: $editingTheme.messages.agentNameSize, range: 12.5 ... 18)
                    .disabled(!editingTheme.messages.showAgentName)
                    .opacity(editingTheme.messages.showAgentName ? 1 : 0.5)
            }
        }
    }

    private func toggleRow(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label, bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(currentTheme.accentColor)
        }
    }

    // MARK: - Section 4: Text & Fonts

    private var textAndFontsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Text & Fonts") {
                fontPicker("Primary Font", fontName: $editingTheme.typography.primaryFont, isMono: false)
                fontPicker("Mono Font", fontName: $editingTheme.typography.monoFont, isMono: true)

                Divider().opacity(0.3)

                sliderRow("Body", value: $editingTheme.typography.bodySize, range: 10 ... 20)
                sliderRow("Heading", value: $editingTheme.typography.headingSize, range: 14 ... 28)
                sliderRow("Code", value: $editingTheme.typography.codeSize, range: 10 ... 18)
                sliderRow("Title", value: $editingTheme.typography.titleSize, range: 20 ... 40)
                sliderRow("Caption", value: $editingTheme.typography.captionSize, range: 8 ... 16)
            }
        }
    }

    // MARK: - Section 5: Borders & Effects

    private var bordersAndEffectsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Borders & Effects") {
                Picker("Input Box", selection: $editingTheme.inputStyle) {
                    Text("Gradient", bundle: .module).tag(ThemeInputStyle.gradient)
                    Text("Shadow", bundle: .module).tag(ThemeInputStyle.shadow)
                }
                .pickerStyle(.segmented)

                Divider().opacity(0.3)

                Text("Borders", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                )
                .textCase(.uppercase)
                colorRow("Border Color", hex: $editingTheme.colors.primaryBorder)
                sliderRow("Border Width", value: $editingTheme.borders.defaultWidth, range: 0 ... 4)
                sliderRow("Border Opacity", value: $editingTheme.borders.borderOpacity, range: 0 ... 1)

                Divider().opacity(0.3)

                Text("Corner Radius", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                ).textCase(.uppercase)
                sliderRow("Input Radius", value: $editingTheme.borders.inputCornerRadius, range: 0 ... 20)
            }
        }
    }

    private var imageBackgroundControls: some View {
        VStack(spacing: 12) {
            Text("Background Image", bundle: .module).font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    currentTheme.tertiaryText
                ).textCase(.uppercase)

            if editingTheme.background.imageData != nil {
                if let nsImage = backgroundPreviewImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(currentTheme.primaryBorder, lineWidth: 1)
                        )
                }

                HStack(spacing: 8) {
                    Button {
                        showImagePicker = true
                    } label: {
                        Label {
                            Text("Replace Image", bundle: .module)
                        } icon: {
                            Image(systemName: "photo.badge.plus")
                        }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        editingTheme.background.imageData = nil
                    } label: {
                        Label {
                            Text("Remove Image", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button(action: { showImagePicker = true }) {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 24))
                        Text("Choose Image", bundle: .module).font(.system(size: 13, weight: .medium))
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
                "Image Opacity",
                value: Binding(
                    get: { editingTheme.background.imageOpacity ?? 1.0 },
                    set: { editingTheme.background.imageOpacity = $0 }
                ),
                range: 0 ... 1
            )

            Picker(
                selection: Binding(
                    get: { editingTheme.background.imageFit ?? .fill },
                    set: { editingTheme.background.imageFit = $0 }
                )
            ) {
                Text("Fill", bundle: .module).tag(ThemeBackground.ImageFit.fill)
                Text("Fit", bundle: .module).tag(ThemeBackground.ImageFit.fit)
                Text("Stretch", bundle: .module).tag(ThemeBackground.ImageFit.stretch)
                Text("Tile", bundle: .module).tag(ThemeBackground.ImageFit.tile)
            } label: {
                Text("Fit", bundle: .module)
            }
            .pickerStyle(.segmented)

            Divider().opacity(0.3)

            Text("Overlay", bundle: .module).font(.system(size: 11, weight: .semibold))
                .foregroundColor(currentTheme.tertiaryText)
                .textCase(.uppercase)
            colorRowOptional("Overlay Color", hex: $editingTheme.background.overlayColor)
            if editingTheme.background.overlayColor != nil {
                sliderRow(
                    "Overlay Opacity",
                    value: Binding(
                        get: { editingTheme.background.overlayOpacity ?? 0.5 },
                        set: { editingTheme.background.overlayOpacity = $0 }
                    ),
                    range: 0 ... 1
                )
            }
        }
    }

    // MARK: - Section 6: Advanced (collapsed by default)

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Advanced") {
                Text("Animation", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                    currentTheme.tertiaryText
                )
                .textCase(.uppercase)

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

                    Button {
                        animationPreviewTrigger.toggle()
                    } label: {
                        Text("Test Animation", bundle: .module)
                    }
                    .buttonStyle(.bordered)
                }

                sliderRow("Quick", value: $editingTheme.animationConfig.durationQuick, range: 0.05 ... 0.5)
                sliderRow("Slow", value: $editingTheme.animationConfig.durationSlow, range: 0.2 ... 1.0)
                sliderRow("Response", value: $editingTheme.animationConfig.springResponse, range: 0.1 ... 1.0)
                sliderRow("Damping", value: $editingTheme.animationConfig.springDamping, range: 0.3 ... 1.0)

                if editingTheme.background.type == .solid {
                    Divider().opacity(0.3)

                    Text("Solid Background", bundle: .module).font(.system(size: 11, weight: .semibold))
                        .foregroundColor(
                            currentTheme.tertiaryText
                        ).textCase(.uppercase)
                    colorRow(
                        "Color",
                        hex: Binding(
                            get: { editingTheme.background.solidColor ?? editingTheme.colors.primaryBackground },
                            set: { editingTheme.background.solidColor = $0 }
                        )
                    )
                }

                if editingTheme.background.type == .gradient {
                    Divider().opacity(0.3)

                    Text("Gradient", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(
                        currentTheme.tertiaryText
                    ).textCase(.uppercase)
                    VStack(spacing: 8) {
                        ForEach(
                            Array((editingTheme.background.gradientColors ?? ["#000000", "#333333"]).enumerated()),
                            id: \.offset
                        ) { index, _ in
                            colorRow(
                                L("Color \(index + 1)"),
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
                                Label {
                                    Text("Add Color", bundle: .module)
                                } icon: {
                                    Image(systemName: "plus")
                                }
                            }
                            .buttonStyle(.bordered)

                            if (editingTheme.background.gradientColors?.count ?? 0) > 2 {
                                Button(action: { editingTheme.background.gradientColors?.removeLast() }) {
                                    Label {
                                        Text("Remove", bundle: .module)
                                    } icon: {
                                        Image(systemName: "minus")
                                    }
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
        }
    }

    // MARK: - Section 7: Raw JSON

    private var rawJSONSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection("Raw JSON") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: rawThemeJSONBinding)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(currentTheme.primaryText)
                        .frame(minHeight: 220)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(currentTheme.inputBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(currentTheme.inputBorder, lineWidth: 1)
                        )

                    if let rawThemeJSONError {
                        rawJSONErrorView(rawThemeJSONError)
                    }

                    if rawThemeJSONIsStale {
                        rawJSONStaleView
                    }

                    HStack(spacing: 8) {
                        Button {
                            refreshRawThemeJSON()
                        } label: {
                            Label {
                                Text("Refresh", bundle: .module)
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            applyRawThemeJSON()
                        } label: {
                            Label {
                                Text("Apply JSON", bundle: .module)
                            } icon: {
                                Image(systemName: "checkmark.circle")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(rawThemeJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var rawThemeJSONBinding: Binding<String> {
        Binding(
            get: { rawThemeJSON },
            set: { newValue in
                rawThemeJSON = newValue
                rawThemeJSONIsDirty = true
                rawThemeJSONError = nil
            }
        )
    }

    /// Shown when the JSON text has unapplied edits and a control was changed
    /// afterwards. Without this, Apply JSON would quietly undo the control
    /// change and Refresh would quietly discard the typed edits.
    private var rawJSONStaleView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(currentTheme.warningColor)
            Text(
                "The controls changed after you edited this JSON. Apply JSON will overwrite those control changes, and Refresh will discard your JSON edits.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(currentTheme.warningColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(currentTheme.warningColor.opacity(0.12))
        )
    }

    private func rawJSONErrorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(currentTheme.errorColor)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(currentTheme.errorColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(currentTheme.errorColor.opacity(0.12))
        )
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live Preview", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(currentTheme.primaryText)
                Spacer()
                Text("Changes are reflected in real-time", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(currentTheme.tertiaryText)
            }
            .padding(16)
            .background(currentTheme.secondaryBackground)

            ZStack {
                transparencyBackdrop
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                ThemeChatPreview(theme: previewTheme)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(6)
            }
            .padding(20)
        }
    }

    /// The theme as the app will actually render it. When the theme follows
    /// the system accent the runtime substitutes the macOS accent, so the
    /// preview does the same rather than showing the stored accent.
    private var previewTheme: CustomTheme {
        var theme = editingTheme
        if theme.followsSystemAccent,
            let accentHex = SystemAccentColor.currentAccentHex(isDark: theme.isDark)
        {
            theme.colors = theme.colors.applyingAccent(accentHex, isDark: theme.isDark)
        }
        return theme
    }

    /// gradient backdrop behind the preview card
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

    /// `title` is the English section name. It doubles as the stable key for
    /// `collapsedSections` (so the collapsed-by-default set matches in every
    /// locale) and is localized only for display.
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
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(currentTheme.secondaryText)
                        .textCase(.uppercase)

                    if isCollapsed, let count = itemCount {
                        Text("\(count)", bundle: .module)
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

    private var codeHighlightThemePicker: some View {
        HStack(spacing: 8) {
            Text("Syntax Theme", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)
            Spacer()
            Picker(
                "",
                selection: Binding<String>(
                    get: { editingTheme.codeHighlightTheme ?? "auto" },
                    set: { editingTheme.codeHighlightTheme = $0 == "auto" ? nil : $0 }
                )
            ) {
                Text("Auto", bundle: .module).tag("auto")
                Divider()
                ForEach(availableHighlightrThemes(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .frame(width: 180)
        }
    }

    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)

            Spacer()

            hexTextField(hex: hex)

            colorSwatch(hex: hex.wrappedValue)

            colorPickerButton(hex: hex)
        }
    }

    private func colorRowOptional(_ label: String, hex: Binding<String?>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
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
                    hex: Binding(
                        get: { hex.wrappedValue ?? "#000000" },
                        set: { hex.wrappedValue = $0 }
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
                    Text("Add", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Shared Primitives

    private func hexTextField(hex: Binding<String>) -> some View {
        ThemeHexTextField(hex: hex, textColor: currentTheme.tertiaryText)
    }

    private func colorSwatch(hex: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(themeHex: hex))
            .frame(width: 24, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(currentTheme.primaryBorder, lineWidth: 1))
    }

    private func colorPickerButton(hex: Binding<String>) -> some View {
        ThemeColorPickerButton(hex: hex)
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
        VStack(spacing: 4) {
            HStack {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(currentTheme.primaryText)

                Spacer()

                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(currentTheme.tertiaryText)
            }

            Slider(value: value, in: range)
                .tint(currentTheme.accentColor)
        }
    }

    private func fontPicker(_ label: String, fontName: Binding<String>, isMono: Bool) -> some View {
        HStack {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(currentTheme.primaryText)
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

    private func scheduleRawThemeJSONSync() {
        guard !rawThemeJSONIsDirty else { return }
        rawThemeJSONSyncTask?.cancel()
        rawThemeJSONSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            syncRawThemeJSONIfNeeded(editingTheme)
        }
    }

    private func syncRawThemeJSONIfNeeded(_ theme: CustomTheme) {
        guard !rawThemeJSONIsDirty else { return }
        let encoded = encodedThemeJSON(theme, fallback: rawThemeJSON)
        // Skip no-op updates: replacing the TextEditor text forces a full
        // TextKit relayout even when nothing changed.
        if encoded != rawThemeJSON {
            rawThemeJSON = encoded
        }
    }

    private func refreshRawThemeJSON() {
        rawThemeJSON = encodedThemeJSON(editingTheme, fallback: rawThemeJSON)
        rawThemeJSONError = nil
        rawThemeJSONIsDirty = false
        rawThemeJSONIsStale = false
    }

    private func applyRawThemeJSON() {
        do {
            let decoded = try ThemeJSONEditorCodec.decodePreservingEditorIdentity(
                rawThemeJSON,
                currentTheme: editingTheme
            )
            if decoded.colors.accentColor != editingTheme.colors.accentColor {
                accentHexFromRawJSON = decoded.colors.accentColor
            }
            editingTheme = decoded
            rawThemeJSON = encodedThemeJSON(decoded, fallback: rawThemeJSON)
            rawThemeJSONError = nil
            rawThemeJSONIsDirty = false
            rawThemeJSONIsStale = false
        } catch {
            rawThemeJSONError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func encodedThemeJSON(_ theme: CustomTheme, fallback: String) -> String {
        (try? ThemeJSONEditorCodec.encodeForEditor(theme)) ?? fallback
    }

    /// Re-derives the accent-adjacent colors (light accent, selection,
    /// cursor, focus border, info, selected sidebar row) when the accent row
    /// changes, so they track the new accent instead of staying tied to the
    /// old one. `applyingAccent` is a no-op when the hex matches the stored
    /// accent, so the old value is put back first to force the derivation.
    private func rederiveAccentColors(from oldHex: String, to newHex: String) {
        guard oldHex != newHex else { return }
        // Apply JSON sets every color explicitly; don't overwrite the
        // accent-adjacent values the JSON spelled out.
        if let suppressed = accentHexFromRawJSON, suppressed == newHex {
            accentHexFromRawJSON = nil
            return
        }
        var colors = editingTheme.colors
        colors.accentColor = oldHex
        let derived = colors.applyingAccent(String(newHex.prefix(7)), isDark: editingTheme.isDark)
        guard derived != colors else { return }
        var updated = derived
        // Keep exactly what the user picked, alpha included.
        updated.accentColor = newHex
        editingTheme.colors = updated
    }

    private func saveTheme() {
        guard !isSaving else { return }
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

        themeManager.saveTheme(themeToSave)

        withAnimation { showSaveConfirmation = true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [dismiss, onDismiss] in
            withAnimation { showSaveConfirmation = false }
            dismiss()
            onDismiss()
        }
    }

    nonisolated private static let maxImageDimension: CGFloat = 2048

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Reading, resizing, and PNG-encoding a large image takes long
            // enough to hang the UI, so the whole pipeline runs off the
            // main actor; only the state update hops back.
            Task {
                let encoded = await Task.detached(priority: .userInitiated) { () -> String? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    let resized = Self.resizeImageData(data, maxDimension: Self.maxImageDimension) ?? data
                    return resized.base64EncodedString()
                }.value
                guard let encoded else {
                    presentImageImportError(
                        String(
                            localized: "The file could not be read as an image. Try a PNG or JPEG.",
                            bundle: .module
                        )
                    )
                    return
                }
                editingTheme.background.imageData = encoded
                editingTheme.background.type = .image
            }
        case .failure(let error):
            presentImageImportError(error.localizedDescription)
        }
    }

    private func presentImageImportError(_ message: String) {
        imageImportError = message
        showImageImportError = true
    }

    /// Off-main-actor helper: drawing into an offscreen `NSImage` and
    /// producing the PNG representation are safe on a background thread.
    nonisolated private static func resizeImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
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

// MARK: - Hex Text Field

/// Hex entry that keeps what the user is typing in local state and only
/// commits complete, valid values (#RGB, #RRGGBB, #RRGGBBAA) to the theme.
///
/// Binding the field straight to the theme hex pushed every keystroke into
/// the theme: partial input like "#FF000" parsed as black, so the swatch
/// and live preview flashed black on each key, and saving mid-edit
/// persisted an invalid color. The getter also uppercased on every
/// keystroke, rewriting lowercase input under the cursor.
private struct ThemeHexTextField: View {
    @Binding var hex: String
    let textColor: Color

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(hex: Binding<String>, textColor: Color) {
        _hex = hex
        self.textColor = textColor
        _text = State(initialValue: hex.wrappedValue.uppercased())
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(textColor)
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .focused($isFocused)
            .onChange(of: text) { _, newValue in
                let normalized = Self.normalize(newValue)
                if normalized != newValue {
                    text = normalized
                    return
                }
                if Self.isCompleteHex(normalized), normalized.caseInsensitiveCompare(hex) != .orderedSame {
                    hex = normalized
                }
            }
            .onChange(of: hex) { _, newHex in
                // External change (picker drag, Apply JSON): mirror it unless
                // the field is showing the same value already.
                if newHex.caseInsensitiveCompare(text) != .orderedSame {
                    text = newHex.uppercased()
                }
            }
            .onChange(of: isFocused) { _, focused in
                // Leaving the field with an incomplete value restores the
                // last committed hex instead of leaving junk on screen.
                if !focused, !Self.isCompleteHex(text) {
                    text = hex.uppercased()
                }
            }
            .onSubmit {
                if !Self.isCompleteHex(text) {
                    text = hex.uppercased()
                }
            }
    }

    /// Forces a leading "#", drops non-hex characters, uppercases, and caps
    /// the length at eight digits.
    private static func normalize(_ raw: String) -> String {
        let digits = String(raw.filter(\.isHexDigit).uppercased().prefix(8))
        return "#" + digits
    }

    private static func isCompleteHex(_ value: String) -> Bool {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return [3, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Color Picker Button

/// System color picker that owns its own `Color` state and mirrors it to a
/// hex string, instead of binding the picker straight to the hex.
///
/// Binding the picker to `Color(themeHex:)` / `toHex()` directly meant every
/// drag tick was quantized to 8 bits per channel and handed back to the
/// picker as a brand-new color. NSColorPanel re-derives its wheel and slider
/// positions from that color, so at low saturation or brightness (where the
/// hue is lost in the round-trip) the pointer snapped away from where the
/// user was dragging. Keeping the picker's color local and only pushing the
/// hex outward avoids the feedback loop. The hex is pulled back into the
/// picker only when it changes from elsewhere (the hex text field, Apply
/// JSON).
private struct ThemeColorPickerButton: View {
    @Binding var hex: String

    @State private var color: Color
    /// The last hex this view wrote to the binding, so the echo of our own
    /// write coming back through `onChange(of: hex)` is not re-applied to
    /// the picker.
    @State private var lastEmittedHex: String

    init(hex: Binding<String>) {
        _hex = hex
        _color = State(initialValue: Color(themeHex: hex.wrappedValue))
        _lastEmittedHex = State(initialValue: hex.wrappedValue)
    }

    var body: some View {
        ColorPicker("", selection: $color, supportsOpacity: true)
            .labelsHidden()
            .frame(width: 44)
            .onChange(of: color) { _, newColor in
                let newHex = newColor.toHex(includeAlpha: true)
                guard !Self.isSameHex(newHex, lastEmittedHex) else { return }
                lastEmittedHex = newHex
                if !Self.isSameHex(newHex, hex) {
                    hex = newHex
                }
            }
            .onChange(of: hex) { _, newHex in
                guard !Self.isSameHex(newHex, lastEmittedHex) else { return }
                // Ignore partial input from the hex text field ("#FF000"
                // mid-typing). It would parse as black, and pushing that
                // into the picker would echo "#000000" back over what the
                // user is typing.
                guard Self.isCompleteHex(newHex) else { return }
                let parsed = Color(themeHex: newHex)
                // Record the hex the picker will report for this color so
                // the onChange(of: color) echo is treated as our own write
                // and never rewrites the text field.
                lastEmittedHex = parsed.toHex(includeAlpha: true)
                color = parsed
            }
    }

    private static func isSameHex(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func isCompleteHex(_ value: String) -> Bool {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard [3, 6, 8].contains(digits.count) else { return false }
        return digits.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Theme Chat Preview

struct ThemeChatPreview: View {
    let theme: CustomTheme

    /// Decoded copy of the theme's background image, refreshed off the
    /// main actor whenever the base64 string changes.
    @State private var backgroundImage: NSImage?

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

            VStack(spacing: 0) {
                previewHeader

                ScrollView {
                    VStack(spacing: 0) {
                        previewUserMessage("Hey there! Can you help me with something?")
                        previewAssistantMessage()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }

                Spacer()

                previewInput
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(c(theme.colors.primaryBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(c(theme.colors.primaryBorder).opacity(0.5), lineWidth: 0.5)
        )
        .task(id: theme.background.imageData) {
            backgroundImage = await decodeThemeBackgroundImage(theme.background.imageData)
        }
    }

    // MARK: - Messages

    private var userBubbleColor: Color {
        if let hex = theme.messages.userBubbleColor { return c(hex) }
        return c(theme.colors.accentColor)
    }

    private var assistantBubbleColor: Color? {
        guard let hex = theme.messages.assistantBubbleColor else { return nil }
        return c(hex)
    }

    private func messageHeader(_ name: String, color: Color) -> some View {
        let showAvatar = theme.messages.showInlineAvatar
        let showName = theme.messages.showAgentName
        let avatarSize = CGFloat(max(16, min(108, theme.messages.inlineAvatarSize)))
        let nameSize = CGFloat(max(12.5, min(18, theme.messages.agentNameSize)))

        return HStack(spacing: 8) {
            if showAvatar {
                previewAvatar(size: avatarSize, name: name, tint: color)
            }
            if showName {
                Text(name)
                    .font(primaryFont(size: nameSize, weight: .semibold))
                    .foregroundColor(color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func previewAvatar(size: CGFloat, name: String, tint: Color) -> some View {
        if let mascot = Bundle.module.image(forResource: "osaurus-avatar-green") {
            Image(nsImage: mascot)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(c(theme.colors.secondaryText).opacity(0.35), lineWidth: 1))
        } else {
            let initial = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Text(initial.isEmpty ? "A" : initial)
                    .font(primaryFont(size: size * 0.45, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: size, height: size)
            .overlay(Circle().stroke(c(theme.colors.secondaryText).opacity(0.35), lineWidth: 1))
        }
    }

    private func previewUserMessage(_ content: String) -> some View {
        let radius: CGFloat = 8
        let opacity = theme.messages.userBubbleOpacity

        return VStack(alignment: .trailing, spacing: 0) {
            Text(content)
                .font(bodyFont)
                .foregroundColor(c(theme.colors.primaryText))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(userBubbleColor.opacity(opacity))
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .padding(.horizontal, 10)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func previewAssistantMessage() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            messageHeader("Assistant", color: c(theme.colors.secondaryText))

            VStack(alignment: .leading, spacing: 8) {
                Text("Sure! Here's an example:", bundle: .module)
                    .font(bodyFont)
                    .foregroundColor(c(theme.colors.primaryText))

                previewCodeBlock
                previewButtonTray
                previewToast
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Group {
                    if let bubbleColor = assistantBubbleColor {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(bubbleColor.opacity(theme.messages.assistantBubbleOpacity))
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Code Block Preview

    private var previewCodeBlock: some View {
        let themeProtocol = CustomizableTheme(config: theme)
        let sampleCode = [
            "struct ThemeSample {",
            "    let accent = \"button\"",
            "    func render() { print(accent) }",
            "}",
        ].joined(separator: "\n")
        // Read the code background for the edited theme without switching
        // the shared highlighter during body evaluation. Switching here
        // left the chat window's code blocks on the editor's theme.
        let bgColor = highlightrThemeBackgroundColor(for: themeProtocol)

        return VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text("swift", bundle: .module)
                    .font(monoFont(size: captionSize - 1, weight: .medium))
                    .foregroundColor(c(theme.colors.tertiaryText))
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(c(theme.colors.tertiaryText).opacity(0.45))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(bgColor.opacity(0.6))

            // Syntax-highlighted code via CodeContentView
            GeometryReader { geo in
                CodeContentView(
                    code: sampleCode,
                    language: "swift",
                    baseWidth: geo.size.width - 24,
                    theme: themeProtocol
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 84)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(bgColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var previewButtonTray: some View {
        HStack(spacing: 8) {
            previewControlButton("Primary", foreground: c(theme.colors.primaryText))
            previewControlButton("Success", foreground: c(theme.colors.successColor))
            previewControlButton("Delete", foreground: c(theme.colors.errorColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewControlButton(_ title: LocalizedStringKey, foreground: Color) -> some View {
        Text(title, bundle: .module)
            .font(primaryFont(size: captionSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(c(theme.colors.buttonBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(c(theme.colors.buttonBorder), lineWidth: 1)
            )
    }

    private var previewToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(c(theme.colors.successColor))
            Text("Success action preview", bundle: .module)
                .font(primaryFont(size: captionSize))
                .lineLimit(1)
                .foregroundColor(c(theme.colors.primaryText))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(c(theme.colors.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(c(theme.colors.cardBorder), lineWidth: 1)
        )
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            switch theme.background.type {
            case .solid:
                c(theme.background.solidColor ?? theme.colors.primaryBackground)
            case .gradient:
                let points = theme.background.gradientUnitPoints
                LinearGradient(
                    colors: (theme.background.gradientColors ?? ["#000000", "#333333"]).map { c($0) },
                    startPoint: points.start,
                    endPoint: points.end
                )
            case .image:
                if let nsImage = backgroundImage {
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

    // MARK: - Header

    private var previewHeader: some View {
        Color.clear.frame(height: 20)
    }

    // MARK: - Input

    private var previewInput: some View {
        VStack(spacing: 8) {
            // Selector row — outside the card
            HStack(spacing: 8) {
                selectorChip {
                    Circle().fill(c(theme.colors.successColor)).frame(width: 5, height: 5)
                    Text("claude-4-sonnet", bundle: .module).font(primaryFont(size: captionSize - 1, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold))
                }

                Spacer()

                Text("~2k / 200k", bundle: .module)
                    .font(primaryFont(size: captionSize - 1, weight: .medium))
                    .foregroundColor(c(theme.colors.tertiaryText).opacity(0.6))
            }

            // Input card
            VStack(alignment: .leading, spacing: 0) {
                // Text input placeholder
                Text("Message or attach files...", bundle: .module)
                    .font(bodyFont)
                    .foregroundColor(c(theme.colors.placeholderText ?? theme.colors.tertiaryText))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                // Button bar
                HStack(spacing: 6) {
                    previewActionButton(icon: "paperclip")
                    previewSlashButton

                    Spacer()

                    HStack(spacing: 3) {
                        Text("⏎", bundle: .module).font(primaryFont(size: captionSize - 2, weight: .medium))
                        Text("to send", bundle: .module).font(primaryFont(size: captionSize - 1))
                    }
                    .foregroundColor(c(theme.colors.tertiaryText).opacity(0.5))

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [c(theme.colors.accentColor), c(theme.colors.accentColor).opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(c(theme.colors.primaryBackground).opacity(0.9))
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        theme.inputStyle == .shadow
                            ? AnyShapeStyle(c(theme.colors.primaryBorder).opacity(theme.isDark ? 0.8 : 0.7))
                            : AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(theme.isDark ? 0.2 : 0.3),
                                        c(theme.colors.primaryBorder).opacity(0.12),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            ),
                        lineWidth: theme.inputStyle == .shadow ? 0.75 : 0.5
                    )
            )
            .shadow(
                color: theme.inputStyle == .shadow
                    ? c(theme.isDark ? theme.colors.accentColor : theme.colors.shadowColor).opacity(0.07)
                    : .clear,
                radius: theme.inputStyle == .shadow ? 4 : 0,
                x: 0,
                y: theme.inputStyle == .shadow && !theme.isDark ? 1 : 0
            )
        }
    }

    private func previewActionButton(icon: String) -> some View {
        ZStack {
            Circle()
                .fill(c(theme.colors.tertiaryBackground).opacity(0.8))
            Image(systemName: icon)
                .font(.system(size: CGFloat(theme.typography.bodySize), weight: .medium))
                .foregroundColor(c(theme.colors.secondaryText))
        }
        .frame(width: 32, height: 32)
        .overlay(
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.15),
                            c(theme.colors.primaryBorder).opacity(0.1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private var previewSlashButton: some View {
        ZStack {
            Circle()
                .fill(c(theme.colors.tertiaryBackground).opacity(0.8))
            Text("/")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(c(theme.colors.secondaryText))
        }
        .frame(width: 32, height: 32)
        .overlay(
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.15),
                            c(theme.colors.primaryBorder).opacity(0.1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private func selectorChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .foregroundColor(c(theme.colors.secondaryText))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(c(theme.colors.secondaryBackground).opacity(0.6))
                    .overlay(Capsule().stroke(c(theme.colors.primaryBorder).opacity(0.3), lineWidth: 0.5))
            )
    }
}
