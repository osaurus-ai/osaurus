//
//  ShareLinkComponents.swift
//  osaurus
//
//  Pieces for showing a share link: a QR card and a labelled value with a
//  copy button.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// White-backed QR code of `text`.
struct ShareQRCardView: View {
    @Environment(\.theme) private var theme
    let text: String

    @State private var qrImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(FixedPalette.qrPaper)
                .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.strong, lineWidth: theme.stroke.default))
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(theme.space.s8)
            } else {
                Image(systemName: "qrcode")
                    .glyphSize(36)
                    .foregroundColor(theme.text.disabled)
            }
        }
        .onAppear { qrImage = Self.render(text) }
        .onChange(of: text) { _, newValue in qrImage = Self.render(newValue) }
    }

    static func render(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// A label over a single-line monospaced value with a copy button.
struct ShareCopyRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
            HStack(spacing: 8) {
                Text(verbatim: value)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s8)
                    .settingsChrome(.control)
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .glyphSize(12, weight: .medium)
                        .foregroundColor(copied ? theme.status.success.foreground : theme.text.primary)
                        .frame(width: 32, height: 32)
                        .settingsChrome(.subtle)
                }
                .buttonStyle(.plain)
                .help(copied ? L("Copied") : L("Copy to clipboard"))
            }
        }
    }

    private func copy() {
        ShareLinkPasteboard.copy(value)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

enum ShareLinkPasteboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
