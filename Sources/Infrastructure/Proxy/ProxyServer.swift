import Foundation
import Network
import OllamaBarCore

/// A transparent TCP relay in front of Ollama.
///
/// Bytes are copied between the two sockets untouched — no parsing, no re-encoding, no header
/// rewriting. HTTP is reconstructed separately from a copy of the stream purely for display, so a
/// bug in the parser costs visibility and nothing else. See docs/PLAN.md for why this beats an
/// HTTP-aware proxy here.
public final class ProxyServer: ProxyEventSource, @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    private let listenPort: UInt16
    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let queue = DispatchQueue(label: "com.fosteev.ollamabar.proxy")

    private let stream: AsyncStream<ProxyEvent>
    private let continuation: AsyncStream<ProxyEvent>.Continuation

    private var listener: NWListener?
    private var liveConnections: [ObjectIdentifier: NWConnection] = [:]

    private let stateLock = NSLock()
    private var _state: State = .stopped

    public private(set) var state: State {
        get { stateLock.withLock { _state } }
        set { stateLock.withLock { _state = newValue } }
    }

    public init(listenPort: UInt16, upstreamHost: String = "127.0.0.1", upstreamPort: UInt16 = 11434) {
        self.listenPort = listenPort
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        listener?.cancel()
        continuation.finish()
    }

    public func events() -> AsyncStream<ProxyEvent> { stream }

    public func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: listenPort) else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    // Port 0 means "pick one for me" — tests rely on this.
                    self.state = .running(port: self.listener?.port?.rawValue ?? self.listenPort)
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .stopped
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.liveConnections.values { connection.cancel() }
            self.liveConnections.removeAll()
        }
        state = .stopped
    }

    // MARK: - Relay

    private func accept(_ client: NWConnection) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? .any,
            using: .tcp
        )
        let sniffer = ConnectionSniffer { [weak self] event in
            self?.continuation.yield(event)
        }
        let closeOnce = OnceFlag()

        let teardown: @Sendable (String?) -> Void = { [weak self] reason in
            guard closeOnce.take() else { return }
            sniffer.closed(reason: reason)
            client.cancel()
            upstream.cancel()
            self?.forget(client)
            self?.forget(upstream)
        }

        remember(client)
        remember(upstream)

        client.stateUpdateHandler = { state in
            if case .failed(let error) = state { teardown(error.localizedDescription) }
        }
        upstream.stateUpdateHandler = { state in
            if case .failed(let error) = state { teardown("upstream: \(error.localizedDescription)") }
        }

        client.start(queue: queue)
        upstream.start(queue: queue)

        pump(from: client, to: upstream, observe: { sniffer.clientBytes($0) }, teardown: teardown)
        pump(from: upstream, to: client, observe: { sniffer.serverBytes($0) }, teardown: teardown)
    }

    /// Forwards one direction. The next read is armed only once the previous write has been
    /// handed off, which keeps a slow reader from making us buffer without bound.
    private func pump(
        from source: NWConnection,
        to destination: NWConnection,
        observe: @escaping @Sendable (Data) -> Void,
        teardown: @escaping @Sendable (String?) -> Void
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in

            if let error {
                teardown(error.localizedDescription)
                return
            }

            let forwardMore: @Sendable () -> Void = {
                if isComplete {
                    // Propagate the half-close instead of tearing the other direction down.
                    destination.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                self.pump(from: source, to: destination, observe: observe, teardown: teardown)
            }

            guard let data, !data.isEmpty else {
                forwardMore()
                return
            }

            observe(data)
            destination.send(
                content: data,
                completion: .contentProcessed { sendError in
                    if let sendError {
                        teardown(sendError.localizedDescription)
                        return
                    }
                    forwardMore()
                }
            )
        }
    }

    private func remember(_ connection: NWConnection) {
        queue.async { self.liveConnections[ObjectIdentifier(connection)] = connection }
    }

    private func forget(_ connection: NWConnection) {
        queue.async { self.liveConnections.removeValue(forKey: ObjectIdentifier(connection)) }
    }
}

/// Guards teardown so both directions failing does not report the connection twice.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
