import Foundation
import Testing
@testable import OsaurusCore

struct ImageModelImportRoutingTests {
    @Test func diffusersLayoutsRouteToTheImageStore() {
        #expect(ImageModelDownloadService.isImageBundle(paths: ["model_index.json", "transformer/0.safetensors"]))
        #expect(ImageModelDownloadService.isImageBundle(paths: ["vae/config.json", "transformer/model.safetensors"]))
        #expect(ImageModelDownloadService.isImageBundle(paths: ["vae/a.safetensors", "unet/b.safetensors"]))
    }

    @Test func seedVR2SingleFileLayoutRoutesToTheImageStore() {
        #expect(
            ImageModelDownloadService.isImageBundle(paths: [
                "config.json", "pos_emb.safetensors", "transformer.safetensors", "vae.safetensors",
            ]))
    }

    @Test func languageModelsStayOnTheLLMPath() {
        #expect(
            !ImageModelDownloadService.isImageBundle(paths: [
                "config.json", "tokenizer.json", "model.safetensors", "model.safetensors.index.json",
            ]))
        #expect(!ImageModelDownloadService.isImageBundle(paths: ["config.json", "transformer.safetensors"]))
    }
}
