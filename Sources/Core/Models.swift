import Foundation

/// Model metadata reported by Ollama for both loaded and installed models.
public struct ModelDetails: Sendable, Equatable {
    public let family: String
    public let parameterSize: String
    public let quantizationLevel: String

    public init(family: String, parameterSize: String, quantizationLevel: String) {
        self.family = family
        self.parameterSize = parameterSize
        self.quantizationLevel = quantizationLevel
    }
}

/// A model currently resident in memory, as reported by `GET /api/ps`.
public struct LoadedModel: Sendable, Equatable, Identifiable {
    public let name: String
    /// Total resident size in bytes, VRAM and RAM combined.
    public let size: Int64
    /// Portion of `size` that lives in VRAM.
    public let sizeVRAM: Int64
    /// Context window the model was loaded with — not the model's maximum.
    public let contextLength: Int
    public let expiresAt: Date
    public let details: ModelDetails

    public var id: String { name }

    public init(
        name: String,
        size: Int64,
        sizeVRAM: Int64,
        contextLength: Int,
        expiresAt: Date,
        details: ModelDetails
    ) {
        self.name = name
        self.size = size
        self.sizeVRAM = sizeVRAM
        self.contextLength = contextLength
        self.expiresAt = expiresAt
        self.details = details
    }

    public var isFullyOnGPU: Bool { sizeVRAM >= size }

    /// Share of the model resident in VRAM, 0...1.
    public var vramFraction: Double {
        guard size > 0 else { return 0 }
        return min(1, Double(sizeVRAM) / Double(size))
    }

    /// Seconds until Ollama evicts the model, or 0 once the deadline has passed.
    public func timeUntilEviction(now: Date = .now) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }
}

/// A model available on disk, as reported by `GET /api/tags`.
public struct InstalledModel: Sendable, Equatable, Identifiable {
    public let name: String
    public let size: Int64
    public let modifiedAt: Date
    public let details: ModelDetails

    public var id: String { name }

    public init(name: String, size: Int64, modifiedAt: Date, details: ModelDetails) {
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
        self.details = details
    }
}
