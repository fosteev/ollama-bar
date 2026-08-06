import Foundation
import Testing

@testable import OllamaBarInfrastructure

struct ChunkedDecoderTests {
    @Test func decodesASimpleBody() {
        var decoder = ChunkedDecoder()
        let payload = decoder.decode(Data("5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n".utf8))

        #expect(String(data: payload, encoding: .utf8) == "helloworld")
        #expect(decoder.isFinished)
    }

    /// Chunk boundaries have nothing to do with packet boundaries.
    @Test(arguments: [1, 2, 3, 5, 7, 13])
    func decodesRegardlessOfHowTheBytesArrive(stride packetSize: Int) {
        let raw = Array("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        var decoder = ChunkedDecoder()
        var payload = Data()

        for index in Swift.stride(from: 0, to: raw.count, by: packetSize) {
            payload += decoder.decode(Data(raw[index..<min(index + packetSize, raw.count)]))
        }

        #expect(String(data: payload, encoding: .utf8) == "hello world")
        #expect(decoder.isFinished)
    }

    @Test func acceptsChunkExtensions() {
        var decoder = ChunkedDecoder()
        let payload = decoder.decode(Data("5;name=value\r\nhello\r\n0\r\n\r\n".utf8))

        #expect(String(data: payload, encoding: .utf8) == "hello")
        #expect(decoder.isFinished)
    }

    @Test func skipsTrailerHeaders() {
        var decoder = ChunkedDecoder()
        let payload = decoder.decode(Data("3\r\nabc\r\n0\r\nX-Checksum: 1\r\n\r\n".utf8))

        #expect(String(data: payload, encoding: .utf8) == "abc")
        #expect(decoder.isFinished)
    }

    @Test func incompleteBodyYieldsWhatItCan() {
        var decoder = ChunkedDecoder()
        let payload = decoder.decode(Data("5\r\nhel".utf8))

        #expect(String(data: payload, encoding: .utf8) == "hel")
        #expect(!decoder.isFinished)
    }

    /// Hex sizes above 9 are the common off-by-one in hand-rolled decoders.
    @Test func handlesLargeHexSizes() {
        let body = String(repeating: "x", count: 0x2A)
        var decoder = ChunkedDecoder()
        let payload = decoder.decode(Data("2a\r\n\(body)\r\n0\r\n\r\n".utf8))

        #expect(String(data: payload, encoding: .utf8) == body)
        #expect(decoder.isFinished)
    }

    @Test func garbageSizeStopsDecodingInsteadOfSpinning() {
        var decoder = ChunkedDecoder()
        _ = decoder.decode(Data("zz\r\nhello\r\n".utf8))

        #expect(decoder.isFinished)
    }
}
