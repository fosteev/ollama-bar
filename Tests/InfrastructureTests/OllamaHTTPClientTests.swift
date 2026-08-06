import Foundation
import Testing

import OllamaBarCore
@testable import OllamaBarInfrastructure

struct OllamaHTTPClientTests {
    @Test func decodesLoadedModels() throws {
        let models = try OllamaHTTPClient.decodeLoadedModels(from: Fixtures.data("api-ps.json"))

        let model = try #require(models.first)
        #expect(model.name == "qwen3.5-27b-32k:latest")
        #expect(model.size == 18_256_861_592)
        #expect(model.sizeVRAM == 18_256_861_592)
        #expect(model.contextLength == 32_768)
        #expect(model.isFullyOnGPU)
        #expect(model.details.parameterSize == "27.8B")
        #expect(model.details.quantizationLevel == "Q4_K_M")
        #expect(model.details.family == "qwen35")
        #expect(model.expiresAt != .distantPast)
    }

    @Test func decodesInstalledModels() throws {
        let models = try OllamaHTTPClient.decodeInstalledModels(from: Fixtures.data("api-tags.json"))

        let model = try #require(models.first)
        #expect(!model.name.isEmpty)
        #expect(model.size > 0)
        #expect(model.modifiedAt != .distantPast)
    }

    @Test func emptyResponseIsNotAnError() throws {
        let data = Data(#"{"models":[]}"#.utf8)
        #expect(try OllamaHTTPClient.decodeLoadedModels(from: data).isEmpty)
    }

    /// `/api/ps` omitted `context_length` before Ollama 0.11; missing means "unknown", not a failure.
    @Test func toleratesMissingContextLength() throws {
        let data = Data("""
        {"models":[{"name":"m","size":1,"size_vram":1,"expires_at":"2026-08-06T12:34:35.170048+03:00",
        "details":{"family":"f","parameter_size":"7B","quantization_level":"Q4_K_M"}}]}
        """.utf8)

        let model = try #require(try OllamaHTTPClient.decodeLoadedModels(from: data).first)
        #expect(model.contextLength == 0)
    }
}

struct RFC3339Tests {
    /// Go emits nanosecond precision; ISO8601DateFormatter only accepts milliseconds.
    @Test(arguments: [
        "2026-08-06T11:54:20.829085541+03:00",  // 9 fractional digits, from /api/tags
        "2026-08-06T12:34:35.170048+03:00",     // 6, from /api/ps
        "2026-08-06T12:34:35.17+03:00",         // 2
        "2026-08-06T12:34:35+03:00",            // none
        "2026-08-06T09:34:35Z",
    ])
    func parsesEveryPrecisionOllamaEmits(input: String) {
        #expect(RFC3339.date(from: input) != nil)
    }

    @Test func keepsTheInstantAcrossPrecisions() throws {
        let withNanos = try #require(RFC3339.date(from: "2026-08-06T12:34:35.170048+03:00"))
        let withoutFraction = try #require(RFC3339.date(from: "2026-08-06T12:34:35+03:00"))

        #expect(abs(withNanos.timeIntervalSince(withoutFraction) - 0.170) < 0.001)
    }

    @Test func offsetIsRespected() throws {
        let moscow = try #require(RFC3339.date(from: "2026-08-06T12:34:35+03:00"))
        let utc = try #require(RFC3339.date(from: "2026-08-06T09:34:35Z"))

        #expect(moscow == utc)
    }

    @Test func rejectsNonsense() {
        #expect(RFC3339.date(from: "not a date") == nil)
    }
}
