import Foundation

/// A parsed request or status line plus its headers.
struct HTTPHead: Equatable {
    let startLine: String
    let headers: [(name: String, value: String)]

    static func == (lhs: HTTPHead, rhs: HTTPHead) -> Bool {
        lhs.startLine == rhs.startLine && lhs.headers.map(\.name) == rhs.headers.map(\.name)
    }

    func value(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `POST /api/chat HTTP/1.1` → ("POST", "/api/chat")
    var requestTarget: (method: String, path: String)? {
        let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// `HTTP/1.1 200 OK` → 200
    var statusCode: Int? {
        let parts = startLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}

/// Splits an HTTP byte stream into head and body without ever altering it.
///
/// This runs on a *copy* of the proxied bytes — see docs/PLAN.md. Anything it cannot make sense of
/// is skipped, because losing visibility is always preferable to disturbing the connection.
enum HTTPStreamParser {
    static let headTerminator = Data("\r\n\r\n".utf8)

    /// Splits off a complete header block if the buffer already holds one.
    static func takeHead(from buffer: inout Data) -> HTTPHead? {
        guard let range = buffer.range(of: headTerminator) else { return nil }
        let headData = buffer[buffer.startIndex..<range.lowerBound]
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)

        guard let text = String(data: headData, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let startLine = lines.first, !startLine.isEmpty else { return nil }
        lines.removeFirst()

        let headers: [(name: String, value: String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
        return HTTPHead(startLine: startLine, headers: headers)
    }

    /// How the body that follows a given head is framed.
    enum BodyFraming: Equatable {
        case none
        case length(Int)
        case chunked
        case untilClose
    }

    static func framing(for head: HTTPHead, isResponse: Bool) -> BodyFraming {
        if let status = head.statusCode, isResponse {
            if status == 204 || status == 304 || (100..<200).contains(status) { return .none }
        }
        if head.value("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            return .chunked
        }
        if let length = head.value("Content-Length").flatMap(Int.init) {
            return length > 0 ? .length(length) : .none
        }
        return isResponse ? .untilClose : .none
    }
}

/// Incremental `Transfer-Encoding: chunked` decoder.
struct ChunkedDecoder {
    private enum State {
        case size
        case body(remaining: Int)
        /// The CRLF that closes a chunk may arrive in a later packet than the chunk itself.
        case chunkEnd
        case trailer
        case finished
    }

    private var state: State = .size
    private var buffer = Data()

    var isFinished: Bool { if case .finished = state { true } else { false } }

    /// Returns whatever payload bytes became available. Incomplete chunks are held back.
    mutating func decode(_ incoming: Data) -> Data {
        buffer.append(incoming)
        var payload = Data()

        loop: while true {
            switch state {
            case .finished:
                break loop

            case .size:
                guard let line = takeLine() else { break loop }
                // The size may carry chunk extensions after a semicolon.
                let sizeText = line.split(separator: ";").first.map(String.init) ?? line
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    state = .finished
                    break loop
                }
                state = size == 0 ? .trailer : .body(remaining: size)

            case .body(let remaining):
                guard !buffer.isEmpty else { break loop }
                let take = min(remaining, buffer.count)
                payload.append(buffer.prefix(take))
                buffer.removeFirst(take)
                let left = remaining - take
                state = left == 0 ? .chunkEnd : .body(remaining: left)

            case .chunkEnd:
                guard takeLine() != nil else { break loop }
                state = .size

            case .trailer:
                guard let line = takeLine() else { break loop }
                if line.isEmpty { state = .finished }
            }
        }
        return payload
    }

    private mutating func takeLine() -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let lineData = buffer[buffer.startIndex..<range.lowerBound]
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return String(data: lineData, encoding: .utf8) ?? ""
    }
}
