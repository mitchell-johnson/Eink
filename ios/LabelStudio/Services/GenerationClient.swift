import Foundation

struct GenerationJob: Codable {
    let id: String
    let status: String
    let model: String
    let error: ServerError?
}
struct ServerError: Codable { let code: String; let message: String }
struct ServerConfiguration: Decodable {
    let model: String
    let width: Int
    let height: Int
    let palette: [String]
    let ready: Bool
}

struct GenerationClient {
    let settings: ConnectionSettings
    static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    var session: URLSession = secureSession

    func configuration() async throws -> ServerConfiguration {
        let configuration: ServerConfiguration = try await json("v1/config")
        guard configuration.width == 400, configuration.height == 300,
              configuration.model == "gpt-image-2.5-sunburst",
              Set(configuration.palette.map { $0.uppercased() }) == Set(["#000000", "#FFFFFF", "#FFFF00", "#FF0000"]) else { throw GenerationError.incompatibleServer }
        return configuration
    }

    func create(id: UUID, prompt: String) async throws -> GenerationJob {
        try await json("v1/jobs/\(id.uuidString.lowercased())", method: "PUT", body: JSONEncoder().encode(["prompt": prompt]))
    }
    func status(id: UUID) async throws -> GenerationJob { try await json("v1/jobs/\(id.uuidString.lowercased())") }
    func image(id: UUID) async throws -> Data {
        try await request("v1/jobs/\(id.uuidString.lowercased())/image", maximumBytes: 20_000_000)
    }

    private func json<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await request(path, method: method, body: body, maximumBytes: 65_536)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GenerationError.invalidResponse }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: settings.endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == settings.endpoint.host else { throw GenerationError.invalidResponse }
        guard http.expectedContentLength <= maximumBytes else { throw GenerationError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw GenerationError.invalidResponse }
            data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Envelope: Decodable { let error: ServerError }
            let error = try? JSONDecoder().decode(Envelope.self, from: data).error
            throw GenerationError.server(http.statusCode, error?.message)
        }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum GenerationError: LocalizedError {
    case incompatibleServer, invalidResponse, notReady, server(Int, String?), failed(String)
    var errorDescription: String? {
        switch self {
        case .incompatibleServer: return "This server is not configured for your 400 × 300, four-colour label with GPT Image 2.5."
        case .invalidResponse: return "The server returned an unreadable response. Your current label is safe."
        case .notReady: return "Your private server is connected, but its OpenAI key has not been configured yet."
        case .server(401, _): return "Your connection code was not accepted. Reconnect in Settings."
        case .server(429, _): return "The server is busy. Wait a minute, then resume this request."
        case .server(404, _), .server(410, _): return "This saved request is unavailable or has expired. Start a new design when you are ready."
        case .server(_, let message): return message ?? "The server could not complete the request. You can resume without starting another generation."
        case .failed(let message): return message
        }
    }
}
