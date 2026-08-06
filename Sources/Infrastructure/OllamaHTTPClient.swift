import Foundation
import OllamaBarCore

public enum OllamaAPIError: Error, LocalizedError {
    case badStatus(Int)
    case malformedDate(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Ollama returned HTTP \(code)"
        case .malformedDate(let value): "Unparseable timestamp: \(value)"
        }
    }
}

/// Talks to the local Ollama HTTP API — `/api/ps` and `/api/tags` to observe, and `keep_alive`
/// on `/api/generate` to load or unload a model without generating anything.
public struct OllamaHTTPClient: ModelInventorySource, ModelController {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = OllamaHTTPClient.defaultBaseURL, timeout: TimeInterval = 3) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    public func loadedModels() async throws -> [LoadedModel] {
        try Self.decodeLoadedModels(from: try await get("/api/ps"))
    }

    public func installedModels() async throws -> [InstalledModel] {
        try Self.decodeInstalledModels(from: try await get("/api/tags"))
    }

    /// `keep_alive: 0` with an empty prompt evicts the model immediately and generates nothing.
    public func unload(model: String) async throws {
        try await setKeepAlive(0, for: model)
    }

    /// `-1` means "never expire" — the model stays until Ollama itself is stopped.
    public func pin(model: String) async throws {
        try await setKeepAlive(-1, for: model)
    }

    private func setKeepAlive(_ value: Int, for model: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "keep_alive": value]
        )

        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaAPIError.badStatus(http.statusCode)
        }
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(from: baseURL.appending(path: path))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaAPIError.badStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Decoding
    //
    // Kept separate from transport so tests can run against recorded fixtures.

    public static func decodeLoadedModels(from data: Data) throws -> [LoadedModel] {
        try JSONDecoder().decode(PSResponse.self, from: data).models.map { dto in
            LoadedModel(
                name: dto.name,
                size: dto.size,
                sizeVRAM: dto.sizeVRAM,
                contextLength: dto.contextLength ?? 0,
                expiresAt: RFC3339.date(from: dto.expiresAt) ?? .distantPast,
                details: dto.details.domain
            )
        }
    }

    public static func decodeInstalledModels(from data: Data) throws -> [InstalledModel] {
        try JSONDecoder().decode(TagsResponse.self, from: data).models.map { dto in
            InstalledModel(
                name: dto.name,
                size: dto.size,
                modifiedAt: RFC3339.date(from: dto.modifiedAt) ?? .distantPast,
                details: dto.details.domain
            )
        }
    }
}

// MARK: - Wire format

private struct DetailsDTO: Decodable {
    let family: String?
    let parameterSize: String?
    let quantizationLevel: String?

    enum CodingKeys: String, CodingKey {
        case family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }

    var domain: ModelDetails {
        ModelDetails(
            family: family ?? "",
            parameterSize: parameterSize ?? "",
            quantizationLevel: quantizationLevel ?? ""
        )
    }
}

private struct PSResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String
        let size: Int64
        let sizeVRAM: Int64
        let contextLength: Int?
        let expiresAt: String
        let details: DetailsDTO

        enum CodingKeys: String, CodingKey {
            case name, size, details
            case sizeVRAM = "size_vram"
            case contextLength = "context_length"
            case expiresAt = "expires_at"
        }
    }
}

private struct TagsResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String
        let size: Int64
        let modifiedAt: String
        let details: DetailsDTO

        enum CodingKeys: String, CodingKey {
            case name, size, details
            case modifiedAt = "modified_at"
        }
    }
}
