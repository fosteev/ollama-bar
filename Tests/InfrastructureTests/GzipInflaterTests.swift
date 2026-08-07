import Foundation
import OllamaBarCore
import Testing

@testable import OllamaBarInfrastructure

struct GzipInflaterTests {
    @Test func inflatesARecordedStream() throws {
        let compressed = try Fixtures.data("stream-api-chat.ndjson.gz")
        let expected = try Fixtures.data("stream-api-chat.ndjson")

        let inflater = try #require(GzipInflater())

        #expect(inflater.inflate(compressed) == expected)
        #expect(!inflater.failed)
    }

    /// A compressed body arrives in whatever pieces the network hands over, and the gzip header
    /// itself can be split across two of them.
    @Test(arguments: [1, 3, 8, 64, 512])
    func inflatesAcrossArbitraryChunkBoundaries(chunk: Int) throws {
        let compressed = try Fixtures.data("stream-api-chat.ndjson.gz")
        let expected = try Fixtures.data("stream-api-chat.ndjson")

        let inflater = try #require(GzipInflater())
        var output = Data()
        var offset = compressed.startIndex
        while offset < compressed.endIndex {
            let end = compressed.index(offset, offsetBy: chunk, limitedBy: compressed.endIndex)
                ?? compressed.endIndex
            output.append(inflater.inflate(Data(compressed[offset..<end])))
            offset = end
        }

        #expect(output == expected)
        #expect(!inflater.failed)
    }

    @Test func plainTextIsRejectedRatherThanMangled() throws {
        let inflater = try #require(GzipInflater())

        let output = inflater.inflate(Data("{\"message\":{\"content\":\"hi\"}}\n".utf8))

        #expect(output.isEmpty)
        #expect(inflater.failed)
    }

    @Test func truncatedInputSimplyProducesNothing() throws {
        let compressed = try Fixtures.data("stream-api-chat.ndjson.gz")
        let inflater = try #require(GzipInflater())

        let output = inflater.inflate(Data(compressed.prefix(20)))

        #expect(output.count < compressed.count)
        #expect(!inflater.failed)
    }

    // MARK: - Header

    @Test func aHeaderThatIsStillArrivingAsksForMore() {
        #expect(GzipInflater.headerLength(of: Data([0x1F])) == .needMore)
        #expect(GzipInflater.headerLength(of: Data([0x1F, 0x8B, 0x08, 0x00])) == .needMore)
    }

    @Test func theShortestHeaderIsTenBytes() {
        let header = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03])
        #expect(GzipInflater.headerLength(of: header) == .bytes(10))
    }

    /// A file name in the header is common — `gzip` puts one there by default.
    @Test func aNamedHeaderCountsPastTheName() {
        var header = Data([0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03])
        header.append(Data("body.ndjson".utf8))
        header.append(0)
        #expect(GzipInflater.headerLength(of: header) == .bytes(22))
    }

    @Test func somethingElseEntirelyIsNotGzip() {
        #expect(GzipInflater.headerLength(of: Data("{\"a\":1}".utf8)) == .notGzip)
        // Right magic, wrong compression method.
        #expect(GzipInflater.headerLength(of: Data([0x1F, 0x8B, 0x07, 0, 0, 0, 0, 0, 0, 0])) == .notGzip)
    }
}
