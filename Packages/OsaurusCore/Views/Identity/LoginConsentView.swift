//
//  LoginConsentView.swift
//  OsaurusCore
//
//  Body of the "Log in with Osaurus" consent panel. The site is named only
//  from the validated `client_id` origin, never from anything else in the
//  request.
//

import AppKit
import SwiftUI

struct LoginConsentView: View {
    let request: LoginConsentRequest
    let onContinue: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.surface.raised, theme.surface.raised],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 0) {
                header
                    .padding(.top, theme.space.s24)
                    .padding(.horizontal, theme.space.s24)

                originBlock
                    .padding(.top, theme.space.s12)
                    .padding(.horizontal, theme.space.s24)

                sharedBlock
                    .padding(.top, theme.space.s12)
                    .padding(.horizontal, theme.space.s24)

                Rectangle()
                    .fill(theme.border.subtle)
                    .frame(height: 1)
                    .padding(.top, theme.space.s16)

                actionButtons
                    .padding(.vertical, theme.space.s16)
                    .padding(.horizontal, theme.space.s24)
            }
            .opacity(appeared ? 1 : 0)
        }
        .frame(width: 400)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
        )
        .themeElevation(theme.elevation.overlay)
        .onAppear {
            withAnimation(theme.motion.springAnimation(responseMultiplier: 1.25).delay(0.05)) {
                appeared = true
            }
        }
        .environment(\.theme, themeManager.currentTheme)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(theme.status.info.background)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .glyphSize(20, weight: .semibold)
                        .foregroundColor(theme.text.link)
                )

            Text("Sign in to \(request.host)?", bundle: .module)
                .font(SettingsFont.detailTitle)
                .foregroundColor(theme.text.primary)
                .multilineTextAlignment(.center)

            Text("This website wants to confirm it's you using your Osaurus identity.", bundle: .module)
                .font(SettingsFont.body)
                .foregroundColor(theme.text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var originBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Website", bundle: .module)
            } icon: {
                Image(systemName: "globe")
            }
            .textStyle(.footnote, weight: 500)
            .foregroundColor(theme.text.secondary)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .glyphSize(10, weight: .semibold)
                    .foregroundColor(theme.status.success.foreground)
                Text(verbatim: request.origin)
                    .textStyle(.code)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.subtle)
        }
    }

    private var sharedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The website will receive:", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            sharedRow(Text("Your Osaurus address", bundle: .module))
            if let handle = request.osaurusHandle {
                sharedRow(Text("Your Osaurus ID (@\(handle))", bundle: .module))
            }
            Text(
                "It never gets your keys, chats, or files. You'll confirm with Touch ID or your password.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, theme.space.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sharedRow(_ label: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .glyphSize(10, weight: .bold)
                .foregroundColor(theme.status.success.foreground)
            label
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text("Cancel", bundle: .module)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.space.s8)
                    .background(theme.surface.hover)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous).stroke(theme.border.default, lineWidth: theme.stroke.default)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onContinue) {
                Label {
                    Text("Continue", bundle: .module)
                } icon: {
                    Image(systemName: "touchid")
                }
                .textStyle(.label, weight: 600)
                .foregroundColor(theme.isDark ? theme.surface.canvas : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, theme.space.s8)
                .background(theme.action.primary.default.background)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
