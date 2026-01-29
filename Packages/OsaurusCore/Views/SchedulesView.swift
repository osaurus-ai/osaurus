//
//  SchedulesView.swift
//  osaurus
//
//  Management view for creating, editing, and viewing scheduled AI tasks.
//

import SwiftUI

// MARK: - Schedules View

struct SchedulesView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var isCreating = false
    @State private var editingSchedule: Schedule?
    @State private var hasAppeared = false
    @State private var successMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            ZStack {
                if scheduleManager.schedules.isEmpty {
                    ScheduleEmptyState(
                        hasAppeared: hasAppeared,
                        onCreate: { isCreating = true }
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 300), spacing: 20),
                                GridItem(.flexible(minimum: 300), spacing: 20),
                            ],
                            spacing: 20
                        ) {
                            ForEach(Array(scheduleManager.schedules.enumerated()), id: \.element.id) {
                                index,
                                schedule in
                                ScheduleCard(
                                    schedule: schedule,
                                    isRunning: scheduleManager.isRunning(schedule.id),
                                    animationDelay: Double(index) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onToggle: { enabled in
                                        scheduleManager.setEnabled(schedule.id, enabled: enabled)
                                    },
                                    onRunNow: {
                                        scheduleManager.runNow(schedule.id)
                                        showSuccess("Started \"\(schedule.name)\"")
                                    },
                                    onEdit: {
                                        editingSchedule = schedule
                                    },
                                    onDelete: {
                                        scheduleManager.delete(id: schedule.id)
                                        showSuccess("Deleted \"\(schedule.name)\"")
                                    }
                                )
                            }
                        }
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                // Success toast
                if let message = successMessage {
                    VStack {
                        Spacer()
                        successToast(message)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .sheet(isPresented: $isCreating) {
            ScheduleEditorSheet(
                mode: .create,
                onSave: { schedule in
                    scheduleManager.create(
                        name: schedule.name,
                        instructions: schedule.instructions,
                        personaId: schedule.personaId,
                        frequency: schedule.frequency,
                        isEnabled: schedule.isEnabled
                    )
                    isCreating = false
                    showSuccess("Created \"\(schedule.name)\"")
                },
                onCancel: {
                    isCreating = false
                }
            )
        }
        .sheet(item: $editingSchedule) { schedule in
            ScheduleEditorSheet(
                mode: .edit(schedule),
                onSave: { updated in
                    scheduleManager.update(updated)
                    editingSchedule = nil
                    showSuccess("Updated \"\(updated.name)\"")
                },
                onCancel: {
                    editingSchedule = nil
                }
            )
        }
        .onAppear {
            scheduleManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Schedules",
            subtitle: "Automate recurring AI tasks with custom schedules",
            count: scheduleManager.schedules.isEmpty ? nil : scheduleManager.schedules.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh schedules") {
                scheduleManager.refresh()
            }
            HeaderPrimaryButton("Create Schedule", icon: "plus") {
                isCreating = true
            }
        }
    }

    // MARK: - Success Toast

    private func successToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.successColor)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(theme.cardBackground)
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(theme.successColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func showSuccess(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                successMessage = nil
            }
        }
    }
}

// MARK: - Empty State

private struct ScheduleEmptyState: View {
    @Environment(\.theme) private var theme

    let hasAppeared: Bool
    let onCreate: () -> Void

    @State private var glowIntensity: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glowing icon
            ZStack {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 25)
                    .opacity(glowIntensity * 0.25)

                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 12)
                    .opacity(glowIntensity * 0.15)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.15),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            // Text content
            VStack(spacing: 8) {
                Text("Create Your First Schedule")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Set up automated AI tasks that run on your schedule.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            // Example use cases
            VStack(spacing: 8) {
                ScheduleUseCaseRow(
                    icon: "sun.max",
                    title: "Morning Briefing",
                    description: "Get a daily summary every morning"
                )
                ScheduleUseCaseRow(
                    icon: "chart.bar",
                    title: "Weekly Report",
                    description: "Generate insights on a schedule"
                )
                ScheduleUseCaseRow(
                    icon: "bell",
                    title: "Reminders",
                    description: "Automated notifications at set times"
                )
            }
            .frame(maxWidth: 320)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 20)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            // Action button
            Button(action: onCreate) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Create Schedule")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
    }
}

// MARK: - Use Case Row (matching PersonaUseCaseRow horizontal pattern)

private struct ScheduleUseCaseRow: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor.opacity(0.1))
                )

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
    }
}

// MARK: - Schedule Card

private struct ScheduleCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var personaManager = PersonaManager.shared

    let schedule: Schedule
    let isRunning: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var persona: Persona? {
        guard let personaId = schedule.personaId else { return nil }
        return personaManager.persona(for: personaId)
    }

    /// Generate a consistent color based on schedule name (matching PersonaCard pattern)
    private var scheduleColor: Color {
        let hash = abs(schedule.name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row - matching PersonaCard pattern
            HStack(alignment: .center, spacing: 12) {
                // Avatar with letter (matching PersonaCard)
                ZStack {
                    if isRunning {
                        Circle()
                            .fill(theme.accentColor.opacity(0.2))
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [scheduleColor.opacity(0.15), scheduleColor.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Circle()
                            .strokeBorder(scheduleColor.opacity(0.4), lineWidth: 2)

                        Text(schedule.name.prefix(1).uppercased())
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(scheduleColor)
                    }
                }
                .frame(width: 36, height: 36)

                // Name with enabled indicator (matching PersonaCard active state)
                HStack(spacing: 8) {
                    Text(schedule.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    if schedule.isEnabled && !isRunning {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(theme.successColor)
                    }

                    if isRunning {
                        Text("Running")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                    }
                }

                Spacer(minLength: 8)

                // Quick actions (visible on hover) - matching PersonaCard
                HStack(spacing: 4) {
                    ScheduleQuickActionButton(icon: "pencil", help: "Edit") {
                        onEdit()
                    }
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isHovered)

                    // More menu (always visible)
                    Menu {
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(action: onRunNow) {
                            Label("Run Now", systemImage: "play.fill")
                        }
                        .disabled(isRunning)
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                }
            }

            // Instructions section - matching PersonaCard's "SYSTEM PROMPT" styling
            VStack(alignment: .leading, spacing: 6) {
                Text("INSTRUCTIONS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)

                if schedule.instructions.isEmpty {
                    Text("No instructions defined")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .italic()
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                } else {
                    Text(schedule.instructions)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(4)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground.opacity(0.5))
            )

            // Configuration badges - matching PersonaCard pattern
            configurationBadges
                .frame(minHeight: 26)

            // Action button row
            HStack(spacing: 8) {
                Button(action: onRunNow) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text("Run Now")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accentColor.opacity(0.1))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isRunning)
                .opacity(isRunning ? 0.5 : 1)

                Spacer()

                // Enable toggle
                Toggle(
                    "",
                    isOn: Binding(
                        get: { schedule.isEnabled },
                        set: { onToggle($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isRunning ? theme.accentColor.opacity(0.4) : theme.cardBorder,
                            lineWidth: isRunning ? 1.5 : 1
                        )
                )
                .shadow(
                    color: isRunning ? theme.accentColor.opacity(0.15) : Color.black.opacity(isHovered ? 0.08 : 0.04),
                    radius: isHovered ? 10 : 5,
                    x: 0,
                    y: isHovered ? 3 : 2
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .contentShape(Rectangle())
        .onTapGesture {
            // Toggle enabled state on click (matching PersonaCard's activate behavior)
            onToggle(!schedule.isEnabled)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .alert("Delete Schedule", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(schedule.name)\"? This action cannot be undone.")
        }
    }

    // MARK: - Configuration Badges

    @ViewBuilder
    private var configurationBadges: some View {
        let hasBadges = persona != nil || !schedule.isEnabled

        if hasBadges {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Frequency badge
                    ScheduleConfigBadge(
                        icon: schedule.frequency.frequencyType.icon,
                        text: schedule.frequency.frequencyType.rawValue,
                        color: .blue
                    )

                    // Next run badge
                    if let nextRun = schedule.nextRunDescription {
                        ScheduleConfigBadge(
                            icon: "clock",
                            text: nextRun,
                            color: .green
                        )
                    }

                    // Persona badge (if assigned)
                    if let personaName = persona?.name, persona?.isBuiltIn == false {
                        ScheduleConfigBadge(
                            icon: "person.fill",
                            text: personaName,
                            color: .purple
                        )
                    }

                    // Paused badge (if disabled)
                    if !schedule.isEnabled {
                        ScheduleConfigBadge(
                            icon: "pause.circle",
                            text: "Paused",
                            color: .orange
                        )
                    }
                }
            }
        } else {
            // Default state - show frequency info
            HStack(spacing: 6) {
                ScheduleConfigBadge(
                    icon: schedule.frequency.frequencyType.icon,
                    text: schedule.frequency.frequencyType.rawValue,
                    color: .blue
                )

                if let nextRun = schedule.nextRunDescription {
                    ScheduleConfigBadge(
                        icon: "clock",
                        text: nextRun,
                        color: .green
                    )
                }
            }
        }
    }
}

// MARK: - Quick Action Button

private struct ScheduleQuickActionButton: View {
    @Environment(\.theme) private var theme

    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isHovered ? theme.tertiaryBackground : theme.tertiaryBackground.opacity(0.5))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .help(help)
    }
}

// MARK: - Config Badge (matching PersonaCard pattern)

private struct ScheduleConfigBadge: View {
    @Environment(\.theme) private var theme

    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(color)

            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Frequency Tab Selector

private struct FrequencyTabSelector: View {
    @Environment(\.theme) private var theme
    @Binding var selection: ScheduleFrequencyType

    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleFrequencyType.allCases, id: \.self) { type in
                FrequencyTabButton(
                    type: type,
                    isSelected: selection == type,
                    namespace: tabNamespace
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = type
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground.opacity(0.6))
        )
    }
}

private struct FrequencyTabButton: View {
    @Environment(\.theme) private var theme

    let type: ScheduleFrequencyType
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: type.icon)
                    .font(.system(size: 10, weight: .medium))

                Text(type.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(
                isSelected ? theme.primaryText : theme.secondaryText
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.cardBackground)
                            .shadow(
                                color: theme.shadowColor.opacity(0.1),
                                radius: 3,
                                x: 0,
                                y: 1
                            )
                            .matchedGeometryEffect(id: "frequency_indicator", in: namespace)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.secondaryBackground.opacity(0.5))
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Schedule Time Picker

private struct ScheduleTimePicker: View {
    @Environment(\.theme) private var theme

    @Binding var hour: Int
    @Binding var minute: Int

    @State private var hourText: String = ""
    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var hourFocused: Bool
    @FocusState private var minuteFocused: Bool

    private var period: String {
        hour >= 12 ? "PM" : "AM"
    }

    private var displayHour: Int {
        let h = hour % 12
        return h == 0 ? 12 : h
    }

    var body: some View {
        HStack(spacing: 4) {
            // Clock icon
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.leading, 10)

            // Hour input
            TextField("", text: $hourText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($hourFocused)
                .onAppear {
                    hourText = "\(displayHour)"
                }
                .onChange(of: hour) { _, _ in
                    if !hourFocused {
                        hourText = "\(displayHour)"
                    }
                }
                .onSubmit { validateHour() }
                .onChange(of: hourFocused) { _, focused in
                    isFocused = focused || minuteFocused
                    if !focused { validateHour() }
                }

            Text(":")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            // Minute input
            TextField("", text: $minuteText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($minuteFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !minuteFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: minuteFocused) { _, focused in
                    isFocused = hourFocused || focused
                    if !focused { validateMinute() }
                }

            // AM/PM toggle
            Button(action: togglePeriod) {
                Text(period)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentColor.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateHour() {
        if let value = Int(hourText), value >= 1, value <= 12 {
            let isPM = hour >= 12
            if value == 12 {
                hour = isPM ? 12 : 0
            } else {
                hour = isPM ? value + 12 : value
            }
        }
        hourText = "\(displayHour)"
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            minute = value
        }
        minuteText = String(format: "%02d", minute)
    }

    private func togglePeriod() {
        if hour >= 12 {
            hour -= 12
        } else {
            hour += 12
        }
    }
}

// MARK: - Weekday Button

private struct WeekdayButton: View {
    @Environment(\.theme) private var theme

    let day: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var dayLetter: String {
        String(Calendar.current.shortWeekdaySymbols[day - 1].prefix(1))
    }

    var body: some View {
        Button(action: action) {
            Text(dayLetter)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    isSelected
                        ? .white
                        : (isHovering ? theme.primaryText : theme.secondaryText)
                )
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(
                            isSelected
                                ? theme.accentColor
                                : (isHovering
                                    ? theme.tertiaryBackground
                                    : theme.inputBackground)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected
                                        ? theme.accentColor
                                        : (isHovering
                                            ? theme.accentColor.opacity(0.3)
                                            : theme.inputBorder),
                                    lineWidth: 1
                                )
                        )
                )
                .scaleEffect(isHovering && !isSelected ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Once Date Picker

private struct OnceDatePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedDate: Date

    @State private var isHovering = false
    @State private var showingPopover = false

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: selectedDate)
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)

                Text(formattedDate)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(8)
            }
            .background(theme.cardBackground)
        }
    }
}

// MARK: - Once Time Picker

private struct OnceTimePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedDate: Date

    @State private var hourText: String = ""
    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var hourFocused: Bool
    @FocusState private var minuteFocused: Bool

    private var hour: Int {
        Calendar.current.component(.hour, from: selectedDate)
    }

    private var minute: Int {
        Calendar.current.component(.minute, from: selectedDate)
    }

    private var period: String {
        hour >= 12 ? "PM" : "AM"
    }

    private var displayHour: Int {
        let h = hour % 12
        return h == 0 ? 12 : h
    }

    private func updateHour(_ newHour: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selectedDate)
        components.hour = newHour
        if let newDate = Calendar.current.date(from: components) {
            selectedDate = newDate
        }
    }

    private func updateMinute(_ newMinute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selectedDate)
        components.minute = newMinute
        if let newDate = Calendar.current.date(from: components) {
            selectedDate = newDate
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Clock icon
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.leading, 10)

            // Hour input
            TextField("", text: $hourText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($hourFocused)
                .onAppear {
                    hourText = "\(displayHour)"
                }
                .onChange(of: hour) { _, _ in
                    if !hourFocused {
                        hourText = "\(displayHour)"
                    }
                }
                .onSubmit { validateHour() }
                .onChange(of: hourFocused) { _, focused in
                    isFocused = focused || minuteFocused
                    if !focused { validateHour() }
                }

            Text(":")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            // Minute input
            TextField("", text: $minuteText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($minuteFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !minuteFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: minuteFocused) { _, focused in
                    isFocused = hourFocused || focused
                    if !focused { validateMinute() }
                }

            // AM/PM toggle
            Button(action: togglePeriod) {
                Text(period)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentColor.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateHour() {
        if let value = Int(hourText), value >= 1, value <= 12 {
            let isPM = hour >= 12
            if value == 12 {
                updateHour(isPM ? 12 : 0)
            } else {
                updateHour(isPM ? value + 12 : value)
            }
        }
        hourText = "\(displayHour)"
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            updateMinute(value)
        }
        minuteText = String(format: "%02d", minute)
    }

    private func togglePeriod() {
        if hour >= 12 {
            updateHour(hour - 12)
        } else {
            updateHour(hour + 12)
        }
    }
}

// MARK: - Month Picker

private struct MonthPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedMonth: Int

    @State private var isHovering = false
    @State private var showingPopover = false

    private var monthName: String {
        Calendar.current.monthSymbols[selectedMonth - 1]
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 4) {
                Text(monthName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(1 ... 12, id: \.self) { month in
                    MonthOptionRow(
                        month: month,
                        isSelected: selectedMonth == month,
                        action: {
                            selectedMonth = month
                            showingPopover = false
                        }
                    )
                }
            }
            .padding(6)
            .frame(width: 160)
            .background(theme.cardBackground)
        }
    }
}

// MARK: - Month Option Row

private struct MonthOptionRow: View {
    @Environment(\.theme) private var theme

    let month: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var monthName: String {
        Calendar.current.monthSymbols[month - 1]
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(monthName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isHovering
                            ? theme.tertiaryBackground
                            : (isSelected ? theme.accentColor.opacity(0.1) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Day of Month Input

private struct DayOfMonthPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedDay: Int

    @State private var dayText: String = ""
    @State private var isFocused = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("", text: $dayText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 32)
                .multilineTextAlignment(.center)
                .focused($textFieldFocused)
                .onAppear {
                    dayText = "\(selectedDay)"
                }
                .onChange(of: selectedDay) { _, newValue in
                    if !textFieldFocused {
                        dayText = "\(newValue)"
                    }
                }
                .onChange(of: dayText) { _, newValue in
                    if let value = Int(newValue), value >= 1, value <= 31 {
                        selectedDay = value
                    }
                }
                .onSubmit {
                    validateAndUpdateDay()
                }
                .onChange(of: textFieldFocused) { _, focused in
                    isFocused = focused
                    if !focused {
                        validateAndUpdateDay()
                    }
                }

            // Stepper buttons
            VStack(spacing: 0) {
                Button(action: { incrementDay() }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)

                Button(action: { decrementDay() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateAndUpdateDay() {
        if let value = Int(dayText) {
            selectedDay = min(max(value, 1), 31)
        }
        dayText = "\(selectedDay)"
    }

    private func incrementDay() {
        selectedDay = selectedDay < 31 ? selectedDay + 1 : 1
        dayText = "\(selectedDay)"
    }

    private func decrementDay() {
        selectedDay = selectedDay > 1 ? selectedDay - 1 : 31
        dayText = "\(selectedDay)"
    }
}

// MARK: - Persona Picker

private struct PersonaPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedPersonaId: UUID?
    let personas: [Persona]

    @State private var isHovering = false
    @State private var showingPopover = false

    private var selectedPersona: Persona? {
        if let id = selectedPersonaId {
            return personas.first(where: { $0.id == id })
        }
        return nil
    }

    private var selectedPersonaName: String {
        selectedPersona?.name ?? "Default"
    }

    private var selectedPersonaDescription: String? {
        if selectedPersonaId == nil {
            return "Uses the default system behavior"
        }
        let desc = selectedPersona?.description ?? ""
        return desc.isEmpty ? nil : desc
    }

    private var hasDescription: Bool {
        selectedPersonaDescription != nil
    }

    private func personaColor(for name: String) -> Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 12) {
                // Persona avatar
                Circle()
                    .fill(personaColor(for: selectedPersonaName).opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(personaColor(for: selectedPersonaName))
                    )

                if hasDescription {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedPersonaName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)

                        Text(selectedPersonaDescription!)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                } else {
                    Text(selectedPersonaName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // Default option
                PersonaOptionRow(
                    name: "Default",
                    description: "Uses the default system behavior",
                    isSelected: selectedPersonaId == nil,
                    action: {
                        selectedPersonaId = nil
                        showingPopover = false
                    }
                )

                if !personas.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    ForEach(personas, id: \.id) { persona in
                        PersonaOptionRow(
                            name: persona.name,
                            description: persona.description,
                            isSelected: selectedPersonaId == persona.id,
                            action: {
                                selectedPersonaId = persona.id
                                showingPopover = false
                            }
                        )
                    }
                }
            }
            .padding(8)
            .frame(minWidth: 280)
            .background(theme.cardBackground)
        }
    }
}

// MARK: - Persona Option Row

private struct PersonaOptionRow: View {
    @Environment(\.theme) private var theme

    let name: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.tertiaryBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Schedule Editor Sheet

private struct ScheduleEditorSheet: View {
    enum Mode {
        case create
        case edit(Schedule)
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var personaManager = PersonaManager.shared

    let mode: Mode
    let onSave: (Schedule) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var instructions: String = ""
    @State private var selectedPersonaId: UUID? = nil
    @State private var frequencyType: ScheduleFrequencyType = .daily
    @State private var isEnabled: Bool = true

    // Time components
    @State private var selectedHour: Int = 9
    @State private var selectedMinute: Int = 0

    // Day components
    @State private var selectedDayOfWeek: Int = 2  // Monday
    @State private var selectedDayOfMonth: Int = 1
    @State private var selectedMonth: Int = 1
    @State private var selectedDay: Int = 1

    // For "once" frequency
    @State private var selectedDate: Date = Date()

    @State private var hasAppeared = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingId: UUID? {
        if case .edit(let schedule) = mode { return schedule.id }
        return nil
    }

    private var existingCreatedAt: Date? {
        if case .edit(let schedule) = mode { return schedule.createdAt }
        return nil
    }

    private var existingLastRunAt: Date? {
        if case .edit(let schedule) = mode { return schedule.lastRunAt }
        return nil
    }

    private var existingLastChatSessionId: UUID? {
        if case .edit(let schedule) = mode { return schedule.lastChatSessionId }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Info Section
                    scheduleInfoSection

                    // Instructions Section
                    instructionsSection

                    // Frequency Section
                    frequencySection

                    // Persona Section
                    personaSection
                }
                .padding(24)
            }

            // Footer
            footerView
        }
        .frame(width: 580, height: 680)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            if case .edit(let schedule) = mode {
                loadSchedule(schedule)
            }
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "calendar.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Schedule" : "Create Schedule")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(isEditing ? "Modify your scheduled task" : "Set up an automated AI task")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Schedule Info Section

    private var scheduleInfoSection: some View {
        ScheduleEditorSection(title: "Schedule Info", icon: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 16) {
                // Name field with label
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    ScheduleTextField(
                        placeholder: "e.g., Daily Summary",
                        text: $name,
                        icon: "textformat"
                    )
                }

                // Enabled toggle
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(
                                isEnabled
                                    ? theme.successColor : theme.tertiaryText
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enabled")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(isEnabled ? "Schedule is active" : "Schedule is paused")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isEnabled
                                        ? theme.successColor.opacity(0.3)
                                        : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
            }
        }
    }

    // MARK: - Instructions Section

    private var instructionsSection: some View {
        ScheduleEditorSection(title: "Instructions", icon: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text("What should the AI do when this runs?")
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                            .padding(.top, 12)
                            .padding(.leading, 16)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100, maxHeight: 150)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Text("These instructions will be sent to the AI when the schedule runs.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Frequency Section

    private var frequencySection: some View {
        ScheduleEditorSection(title: "Frequency", icon: "clock.fill") {
            VStack(spacing: 16) {
                // Frequency type selector with animated pills
                FrequencyTabSelector(selection: $frequencyType)

                // Frequency-specific options
                frequencyOptionsView
                    .animation(.easeInOut(duration: 0.2), value: frequencyType)
            }
        }
    }

    @ViewBuilder
    private var frequencyOptionsView: some View {
        switch frequencyType {
        case .once:
            onceOptions
        case .daily:
            dailyOptions
        case .weekly:
            weeklyOptions
        case .monthly:
            monthlyOptions
        case .yearly:
            yearlyOptions
        }
    }

    private var onceOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Combined Date & Time in a nice row
            HStack(spacing: 16) {
                // Date selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Date")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    OnceDatePicker(selectedDate: $selectedDate)
                }

                // Time selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Time")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    OnceTimePicker(selectedDate: $selectedDate)
                }

                Spacer()
            }

            // Preview of when it will run
            oncePreview
        }
    }

    private var oncePreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scheduled for")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text(formattedOnceDate)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var formattedOnceDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(selectedDate) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInTomorrow(selectedDate) {
            formatter.dateFormat = "'Tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        }

        return formatter.string(from: selectedDate)
    }

    private var dailyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Time selection
            VStack(alignment: .leading, spacing: 6) {
                Text("Time")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                timePicker
            }

            // Preview
            schedulePreview(text: dailyPreviewText)
        }
    }

    private var dailyPreviewText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Every day at \(formatter.string(from: date))"
        }
        return "Every day at \(selectedHour):\(String(format: "%02d", selectedMinute))"
    }

    private var weeklyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Day of week selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Day of Week")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 6) {
                    ForEach(1 ... 7, id: \.self) { day in
                        WeekdayButton(
                            day: day,
                            isSelected: selectedDayOfWeek == day,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedDayOfWeek = day
                                }
                            }
                        )
                    }
                }
            }

            // Time selection
            VStack(alignment: .leading, spacing: 6) {
                Text("Time")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                timePicker
            }

            // Preview
            schedulePreview(text: weeklyPreviewText)
        }
    }

    private var weeklyPreviewText: String {
        let dayName = Calendar.current.weekdaySymbols[selectedDayOfWeek - 1]
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Every \(dayName) at \(formatter.string(from: date))"
        }
        return "Every \(dayName)"
    }

    private var monthlyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Day and Time selection in a row
            HStack(spacing: 16) {
                // Day picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Day of Month")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    DayOfMonthPicker(selectedDay: $selectedDayOfMonth)
                }

                // Time picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Time")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    timePicker
                }

                Spacer()
            }

            Text("If the day doesn't exist in a month, it will run on the last day.")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 4)

            // Preview
            schedulePreview(text: monthlyPreviewText)
        }
    }

    private var monthlyPreviewText: String {
        let suffix = daySuffix(selectedDayOfMonth)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Monthly on the \(selectedDayOfMonth)\(suffix) at \(formatter.string(from: date))"
        }
        return "Monthly on the \(selectedDayOfMonth)\(suffix)"
    }

    private func daySuffix(_ day: Int) -> String {
        switch day {
        case 1, 21, 31: return "st"
        case 2, 22: return "nd"
        case 3, 23: return "rd"
        default: return "th"
        }
    }

    private var yearlyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Month, Day, and Time selection
            HStack(spacing: 12) {
                // Month picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Month")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    MonthPicker(selectedMonth: $selectedMonth)
                }

                // Day picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Day")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    DayOfMonthPicker(selectedDay: $selectedDay)
                }

                // Time picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Time")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    timePicker
                }

                Spacer()
            }

            // Preview
            schedulePreview(text: yearlyPreviewText)
        }
    }

    private var yearlyPreviewText: String {
        let monthName = Calendar.current.monthSymbols[selectedMonth - 1]
        let suffix = daySuffix(selectedDay)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Yearly on \(monthName) \(selectedDay)\(suffix) at \(formatter.string(from: date))"
        }
        return "Yearly on \(monthName) \(selectedDay)\(suffix)"
    }

    private var timePicker: some View {
        ScheduleTimePicker(hour: $selectedHour, minute: $selectedMinute)
    }

    // Helper view for schedule preview
    private func schedulePreview(text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "repeat")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Schedule")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Persona Section

    private var personaSection: some View {
        ScheduleEditorSection(title: "Persona", icon: "person.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                PersonaPicker(
                    selectedPersonaId: $selectedPersonaId,
                    personas: personaManager.personas.filter { !$0.isBuiltIn }
                )
                .frame(maxWidth: .infinity)

                Text("The persona determines the AI's behavior and available tools.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(ScheduleSecondaryButtonStyle())

            Button(isEditing ? "Save Changes" : "Create Schedule") {
                saveSchedule()
            }
            .buttonStyle(SchedulePrimaryButtonStyle())
            .disabled(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    // MARK: - Helpers

    private func loadSchedule(_ schedule: Schedule) {
        name = schedule.name
        instructions = schedule.instructions
        selectedPersonaId = schedule.personaId
        isEnabled = schedule.isEnabled
        frequencyType = schedule.frequency.frequencyType

        switch schedule.frequency {
        case .once(let date):
            selectedDate = date
        case .daily(let hour, let minute):
            selectedHour = hour
            selectedMinute = minute
        case .weekly(let dayOfWeek, let hour, let minute):
            selectedDayOfWeek = dayOfWeek
            selectedHour = hour
            selectedMinute = minute
        case .monthly(let dayOfMonth, let hour, let minute):
            selectedDayOfMonth = dayOfMonth
            selectedHour = hour
            selectedMinute = minute
        case .yearly(let month, let day, let hour, let minute):
            selectedMonth = month
            selectedDay = day
            selectedHour = hour
            selectedMinute = minute
        }
    }

    private func buildFrequency() -> ScheduleFrequency {
        switch frequencyType {
        case .once:
            return .once(date: selectedDate)
        case .daily:
            return .daily(hour: selectedHour, minute: selectedMinute)
        case .weekly:
            return .weekly(dayOfWeek: selectedDayOfWeek, hour: selectedHour, minute: selectedMinute)
        case .monthly:
            return .monthly(dayOfMonth: selectedDayOfMonth, hour: selectedHour, minute: selectedMinute)
        case .yearly:
            return .yearly(month: selectedMonth, day: selectedDay, hour: selectedHour, minute: selectedMinute)
        }
    }

    private func saveSchedule() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty else { return }

        let schedule = Schedule(
            id: existingId ?? UUID(),
            name: trimmedName,
            instructions: trimmedInstructions,
            personaId: selectedPersonaId,
            frequency: buildFrequency(),
            isEnabled: isEnabled,
            lastRunAt: existingLastRunAt,
            lastChatSessionId: existingLastChatSessionId,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date()
        )

        onSave(schedule)
    }
}

// MARK: - Editor Section

private struct ScheduleEditorSection<Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Text Field

private struct ScheduleTextField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    @Binding var text: String
    let icon: String?

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isFocused ? theme.accentColor : theme.tertiaryText
                    )
                    .frame(width: 16)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }
}

// MARK: - Button Styles

private struct SchedulePrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct ScheduleSecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    SchedulesView()
}
