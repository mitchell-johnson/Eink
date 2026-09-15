import SwiftUI

struct SavedDesign: Codable, Identifiable {
    let id: UUID
    let prompt: String
    let createdAt: Date
    var filename: String { "\(id.uuidString).png" }
}
struct PendingGeneration: Codable {
    let id: UUID
    let prompt: String
    let endpoint: String
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var prompt = ""
    @Published private(set) var artwork: LabelArtwork?
    @Published private(set) var designs: [SavedDesign] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var generationPhase = ""
    @Published private(set) var pending: PendingGeneration?
    @Published var message: String?
    @Published var connected = ConnectionSettings.load() != nil
    private var generationTask: Task<Void, Never>?
    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Designs", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { message = "Your designs could not be saved on this iPhone." }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")) {
            designs = (try? JSONDecoder().decode([SavedDesign].self, from: data)) ?? []
        }
        if let data = UserDefaults.standard.data(forKey: "pendingGeneration") {
            pending = try? JSONDecoder().decode(PendingGeneration.self, from: data)
            if let pending { prompt = pending.prompt; generationPhase = "A previous generation is ready to resume." }
        }
        if let latest = designs.first { open(latest) }
    }

    func generate() {
        guard !isGenerating, pending == nil else { return }
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 4_000 else { message = "Please shorten your description. The limit is about 4,000 English characters, or fewer for other languages."; return }
        guard let settings = ConnectionSettings.load() else { message = "Connect your private server in Settings first."; return }
        let job = PendingGeneration(id: UUID(), prompt: clean, endpoint: settings.endpoint.absoluteString)
        pending = job
        persistPending()
        run(job, settings: settings)
    }

    func resume() {
        guard !isGenerating, let pending else { return }
        guard let settings = ConnectionSettings.load() else { message = "Reconnect your private server in Settings."; return }
        guard settings.endpoint.absoluteString == pending.endpoint else { message = "Reconnect the original server to resume this design."; return }
        run(pending, settings: settings)
    }

    private func run(_ job: PendingGeneration, settings: ConnectionSettings) {
        isGenerating = true
        generationPhase = "Connecting to your private server"
        generationTask = Task {
            defer { isGenerating = false; generationTask = nil }
            do {
                let client = GenerationClient(settings: settings)
                _ = try await client.configuration()
                // PUT is an idempotent upsert; the persisted UUID is reused after any interrupted response.
                var status = try await client.create(id: job.id, prompt: job.prompt)
                let deadline = Date().addingTimeInterval(600)
                while status.status == "queued" || status.status == "running" {
                    try Task.checkCancellation()
                    generationPhase = status.status == "queued" ? "Your design is queued" : "GPT Image 2.5 is drawing your label"
                    guard Date() < deadline else { throw GenerationError.failed("This is taking longer than expected. Resume later to check the same request.") }
                    try await Task.sleep(for: .seconds(3))
                    status = try await client.status(id: job.id)
                }
                guard status.status == "succeeded" else {
                    pending = nil; persistPending()
                    throw GenerationError.failed(status.error?.message ?? "The design could not be generated. You can try a new request.")
                }
                generationPhase = "Preparing the four-colour preview"
                let data = try await client.image(id: job.id)
                try Task.checkCancellation()
                guard let source = UIImage(data: data) else { throw ArtworkError.invalidImage }
                let result = try LabelArtwork.render(source)
                try save(result, prompt: job.prompt, id: job.id)
                artwork = result
                pending = nil; persistPending()
                generationPhase = "Design ready · review before writing"
            } catch is CancellationError {
                generationPhase = "Paused · resume to collect your design"
            } catch {
                if case GenerationError.server(let code, _) = error, [400, 409, 413, 422].contains(code) {
                    pending = nil; persistPending()
                }
                if Task.isCancelled { generationPhase = "Paused · resume to collect your design" }
                else { message = error.localizedDescription; generationPhase = pending == nil ? "Generation stopped" : "Request saved · you can resume" }
            }
        }
    }

    func pause() {
        generationTask?.cancel()
        if isGenerating { generationPhase = "Pausing · your server may still finish the design" }
    }
    func forgetPending() {
        guard !isGenerating else { return }
        pending = nil; persistPending(); generationPhase = ""
    }
    private func persistPending() {
        if let pending, let data = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(data, forKey: "pendingGeneration") }
        else { UserDefaults.standard.removeObject(forKey: "pendingGeneration") }
    }

    func importImage(_ data: Data) {
        do {
            guard data.count <= 30_000_000, let image = UIImage(data: data) else { throw ArtworkError.invalidImage }
            let result = try LabelArtwork.render(image)
            try save(result, prompt: "Imported image", id: UUID())
            artwork = result
        } catch { message = error.localizedDescription }
    }
    func open(_ design: SavedDesign) {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(design.filename))
            guard let image = UIImage(data: data) else { throw ArtworkError.invalidImage }
            artwork = try LabelArtwork.render(image)
            if pending == nil { prompt = design.prompt == "Imported image" ? "" : design.prompt }
        } catch { message = "This saved design could not be opened." }
    }
    private func save(_ artwork: LabelArtwork, prompt: String, id: UUID) throws {
        guard let png = artwork.image.pngData() else { throw ArtworkError.invalidImage }
        let design = SavedDesign(id: id, prompt: prompt, createdAt: Date())
        try png.write(to: directory.appendingPathComponent(design.filename), options: [.atomic, .completeFileProtection])
        var updated = designs.filter { $0.id != id }
        updated.insert(design, at: 0)
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
        designs = updated
    }
    func thumbnail(_ design: SavedDesign) -> UIImage? { UIImage(contentsOfFile: directory.appendingPathComponent(design.filename).path) }
    func delete(_ design: SavedDesign) {
        do {
            let updated = designs.filter { $0.id != design.id }
            try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(design.filename))
            designs = updated
        } catch { message = "The saved design could not be deleted." }
    }
}
