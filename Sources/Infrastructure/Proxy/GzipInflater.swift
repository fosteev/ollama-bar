import Compression
import Foundation

/// Streaming gzip decoder, for reading along with a compressed response.
///
/// This only ever touches the *copy* of the stream. The relay forwards bytes exactly as they
/// arrive, so a bug here costs visibility and can never corrupt what the client receives.
///
/// `Compression.framework` speaks raw deflate, not gzip, so the wrapper is peeled off by hand:
/// the header up front, and the CRC trailer simply left unread once the deflate stream ends.
final class GzipInflater {
    private static let bufferSize = 64 * 1024

    private let stream: UnsafeMutablePointer<compression_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private var streamValid = false
    /// Header bytes seen so far. It can arrive split across reads like anything else.
    private var header = Data()
    private var headerDone = false
    private var finished = false
    /// Set when the bytes turn out not to be gzip after all, or inflation fails.
    private(set) var failed = false

    init?() {
        stream = .allocate(capacity: 1)
        buffer = .allocate(capacity: Self.bufferSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else {
            stream.deallocate()
            buffer.deallocate()
            return nil
        }
        streamValid = true
    }

    deinit {
        if streamValid { compression_stream_destroy(stream) }
        stream.deallocate()
        buffer.deallocate()
    }

    /// Feed compressed bytes, get back whatever became readable. Empty is a normal answer.
    func inflate(_ incoming: Data) -> Data {
        guard streamValid, !failed, !finished, !incoming.isEmpty else { return Data() }

        var input = incoming
        if !headerDone {
            header.append(input)
            switch Self.headerLength(of: header) {
            case .needMore:
                return Data()
            case .notGzip:
                failed = true
                return Data()
            case .bytes(let count):
                input = Data(header.dropFirst(count))
                header.removeAll()
                headerDone = true
            }
        }
        guard !input.isEmpty else { return Data() }

        var output = Data()
        input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count

            var again = true
            while again {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = Self.bufferSize
                let status = compression_stream_process(stream, 0)
                let produced = Self.bufferSize - stream.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }

                switch status {
                case COMPRESSION_STATUS_OK:
                    // More input left, or the output buffer filled up and there may be more.
                    again = stream.pointee.src_size > 0 || produced == Self.bufferSize
                case COMPRESSION_STATUS_END:
                    finished = true
                    again = false
                default:
                    failed = true
                    again = false
                }
            }
        }
        return output
    }

    // MARK: - Header

    enum HeaderLength: Equatable {
        case needMore
        case notGzip
        case bytes(Int)
    }

    /// RFC 1952: ten fixed bytes, then optional extra field, file name, comment and header CRC,
    /// each announced by a flag bit.
    static func headerLength(of data: Data) -> HeaderLength {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else {
            // Even the magic number can be split, so only judge once there is enough to judge on.
            if bytes.count >= 2, bytes[0] != 0x1F || bytes[1] != 0x8B { return .notGzip }
            return .needMore
        }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B else { return .notGzip }
        // Deflate is the only compression method gzip has ever used.
        guard bytes[2] == 0x08 else { return .notGzip }

        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 {  // FEXTRA
            guard bytes.count >= offset + 2 else { return .needMore }
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2 + length
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {  // FNAME, FCOMMENT
            guard let end = bytes[safe: offset...].firstIndex(of: 0) else { return .needMore }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC

        return bytes.count >= offset ? .bytes(offset) : .needMore
    }
}

private extension Array where Element == UInt8 {
    /// Slicing past the end is a normal state here — the header is still arriving.
    subscript(safe range: PartialRangeFrom<Int>) -> ArraySlice<UInt8> {
        range.lowerBound < count ? self[range] : []
    }
}
