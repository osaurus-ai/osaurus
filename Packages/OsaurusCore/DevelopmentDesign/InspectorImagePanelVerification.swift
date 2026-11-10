#if OSAURUS_DESIGN_INSPECTOR
import AppKit
import SwiftUI

/// The app's image-generation sheet with local samples and no generation service.
struct InspectorImagePanelVerification: View {
    private enum Preview: String, CaseIterable, Identifiable {
        case generate = "Generate"
        case edit = "Edit"
        case upscale = "Upscale"
        case samplers = "Samplers"
        case dimensions = "Custom dimensions"
        case disabled = "Disabled"
        case loading = "Loading model"
        case running = "Running"
        case livePreview = "Live preview"
        case cancelling = "Cancelling"
        case cancelled = "Cancelled"
        case error = "Error"
        case result = "Result"
        case multiple = "Multiple results"

        var id: String { rawValue }

        var phase: ImageGenerationPanelModel.Phase {
            switch self {
            case .loading: .loadingModel("Sample image model")
            case .running, .livePreview, .cancelling: .running(step: 3, total: 8, eta: 12)
            case .cancelled: .cancelled
            case .error: .failed("The image model couldn’t be loaded.")
            case .result, .multiple: .done
            default: .idle
            }
        }
    }

    @Environment(\.theme) private var theme
    @State private var preview = Preview.generate

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Settings → Models → Image · sheet preview with sample data")
                .font(SettingsFont.caption)
                .foregroundStyle(theme.text.secondary)
            Picker("Preview state", selection: $preview) {
                ForEach(Preview.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.menu)
            ImageGenerationPanelView(
                modelId: "inspector-local-display", displayName: "Sample image model", isEdit: preview == .edit,
                modelInfo: ImageModelInfo(
                    id: "inspector-local-display", canonicalName: preview == .dimensions ? "flux3-image-klein" : nil,
                    displayName: "Sample image model", kind: "imageGen", ready: false, quantizationBits: nil,
                    defaultSteps: 20, defaultGuidance: 3.5,
                    capabilities: ImageModelCapabilities(textToImage: true, imageEdit: preview == .edit,
                        upscale: preview == .upscale, negativePrompt: preview != .dimensions),
                    blockedReasons: [], totalBytes: 0
                ),
                inspectionDisplay: display
            )
            .id(preview)
            .disabled(preview == .disabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var display: ImageGenerationPanelView.InspectionDisplay {
        let sample = Self.images.first?.url
        return .init(
            phase: preview.phase,
            resultURL: preview == .result || preview == .multiple ? sample : nil,
            sampling: preview == .samplers
                ? .init(samplers: ["euler", "heun"], schedulers: ["normal", "simple"], supportsShift: true, maxSourceImages: 1)
                : nil,
            results: preview == .multiple ? Self.images : [],
            isCancelling: preview == .cancelling,
            previewURL: preview == .livePreview ? sample : nil,
            sourceURLs: preview == .edit || preview == .upscale ? Array(Self.images.prefix(1).map(\.url)) : [],
            prompt: preview.phase == .idle || preview == .upscale ? "" : "A blue dinosaur on a pale background"
        )
    }

    private static let images: [GeneratedImage] = ["osaurus-blue-create", "osaurus-orange-create"].enumerated().compactMap { index, name in
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-image-preview-\(index + 1).png")
        guard let image = Bundle.module.image(forResource: NSImage.Name(name)),
            let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:]),
            (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return GeneratedImage(url: url, seed: UInt64(1234 + index))
    }
}
#endif
