import Foundation

enum ModelRegistry {
    static let shared: [TranscriptionModel] = loadModels()

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }

    private static func loadModels() -> [TranscriptionModel] {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json") else {
            fatalError("models.json missing from bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(ModelsManifest.self, from: data)
            return manifest.models
        } catch {
            fatalError("failed to decode models.json: \(error)")
        }
    }
}
