import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOTransportServices

private let pingToken = HTTP2PingData(withInteger: 0x5633_3931)

func runHTTP2(_ credentials: BenchmarkCredentials, scenario: BenchmarkScenario) async throws -> BenchmarkMeasurement {
    let group = NIOTSEventLoopGroup(loopCount: 2)
    defer { group.shutdownGracefully { _ in } }
    let bulkReceived = (0..<scenario.bulkStreamCount).map { _ in ByteCounter() }
    let canceled = ByteCounter()
    let windowUpdates = bulkReceived.map { _ in ByteCounter() }
    let acknowledged = ByteCounter()
    let peerBounds = ByteCounter()
    let settings: HTTP2Settings = [
        .init(parameter: .maxConcurrentStreams, value: 8),
        .init(parameter: .maxFrameSize, value: 16_384),
        .init(parameter: .initialWindowSize, value: 65_535),
        .init(parameter: .maxHeaderListSize, value: 4_096),
    ]
    var configuration = NIOHTTP2Handler.ConnectionConfiguration()
    configuration.initialSettings = settings
    let serverConfiguration = configuration
    configuration.initialSettings.append(.init(parameter: .enablePush, value: 0))
    let clientConfiguration = configuration

    let server = try await NIOTSListenerBootstrap(group: group)
        .tlsOptions(credentials.tlsOptions(server: true, alpn: "h2"))
        .childChannelInitializer { channel in
            channel.configureHTTP2Pipeline(
                mode: .server, connectionConfiguration: serverConfiguration, streamConfiguration: .init()
            ) { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandler(
                        HTTP2Receiver(bulkReceived: bulkReceived, canceled: canceled)
                    )
                }
            }.map { _ in () }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    defer { server.close(promise: nil) }
    guard let address = server.localAddress else { throw BenchmarkError("Missing HTTP/2 listener address.") }

    func dial(
        includeIdentity: Bool,
        ack: ByteCounter,
        bounds: ByteCounter
    ) async throws -> (Channel, NIOHTTP2Handler.StreamMultiplexer) {
        try await NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .tlsOptions(credentials.tlsOptions(server: false, alpn: "h2", clientIdentity: includeIdentity ? .pinned : .missing))
            .connect(to: address) { channel in
                channel.configureHTTP2Pipeline(
                    mode: .client, connectionConfiguration: clientConfiguration, streamConfiguration: .init()
                ) { inbound in
                    inbound.eventLoop.makeFailedFuture(BenchmarkError("Unexpected HTTP/2 server push."))
                }.flatMap { multiplexer in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            HTTP2Events(acknowledged: ack, peerBounds: bounds, expectedSettings: settings)
                        )
                        return (channel, multiplexer)
                    }
                }
            }
    }

    let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(pingToken, ack: false))
    let unauthenticatedAck = ByteCounter()
    do {
        let (unauthorized, _) = try await dial(includeIdentity: false, ack: unauthenticatedAck, bounds: ByteCounter())
        defer { unauthorized.close(promise: nil) }
        do {
            try await unauthorized.writeAndFlush(ping).get()
        } catch where !unauthorized.isActive {
            // Transport Services can finish the client handshake before the listener issues its fatal alert.
        }
        try await pollFor("missing-client-certificate rejection") {
            !unauthorized.isActive || unauthenticatedAck.value > 0
        }
    } catch let error as BenchmarkError {
        throw error
    } catch {
        // A handshake or first write failure also demonstrates that the peer was not ready for HTTP/2.
    }
    guard unauthenticatedAck.value == 0 else {
        throw BenchmarkError("HTTP/2 answered a PING from a client without a certificate.")
    }
    print("HTTP/2 rejected a client without a certificate before any PING acknowledgement")

    let (client, multiplexer) = try await dial(includeIdentity: true, ack: acknowledged, bounds: peerBounds)
    defer { client.close(promise: nil) }

    let probe = try await openHTTP2Stream(multiplexer, path: "/cancel")
    try await probe.writeAndFlush(HTTP2Frame.FramePayload.rstStream(.cancel)).get()
    try await client.writeAndFlush(ping).get()
    try await pollFor("RST_STREAM, PING acknowledgement, and peer settings") {
        canceled.value > 0 && acknowledged.value > 0 && peerBounds.value > 0
    }
    print("HTTP/2 received peer RST_STREAM(CANCEL) and matching PING ACK")

    let replies = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let rpc = try await openHTTP2Stream(multiplexer, path: "/rpc", replies: replies.continuation)
    defer { rpc.close(promise: nil) }
    var bulkStreams: [Channel] = []
    defer { bulkStreams.forEach { $0.close(promise: nil) } }
    for index in bulkReceived.indices {
        bulkStreams.append(try await openHTTP2Stream(
            multiplexer, path: "/bulk/\(index)", windows: windowUpdates[index]
        ))
    }
    let bulkSenders = bulkStreams.map { stream in
        Task {
            let chunk = http2Data(bulkPayload)
            while !Task.isCancelled { try await stream.writeAndFlush(chunk).get() }
        }
    }
    defer { bulkSenders.forEach { $0.cancel() } }
    if !bulkStreams.isEmpty {
        try await pollFor("sustained bulk and per-stream WINDOW_UPDATE") {
            bulkReceived.allSatisfy { $0.value >= 256 * 1_024 } && windowUpdates.allSatisfy { $0.value > 0 }
        }
        print("HTTP/2 observed per-stream WINDOW_UPDATE under bulk traffic; limits 8 streams, 16 KiB frames")
    }
    var response = replies.stream.makeAsyncIterator()
    return try await measure(bulkStreams: bulkReceived) {
        try await rpc.writeAndFlush(http2Data(rpcPayload)).get()
        guard await response.next() == rpcPayload else { throw BenchmarkError("HTTP/2 echo mismatch.") }
    }
}

private func http2Data(_ bytes: Data) -> HTTP2Frame.FramePayload {
    var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    return .data(.init(data: .byteBuffer(buffer)))
}

private func openHTTP2Stream(
    _ multiplexer: NIOHTTP2Handler.StreamMultiplexer,
    path: String,
    replies: AsyncStream<Data>.Continuation? = nil,
    windows: ByteCounter? = nil
) async throws -> Channel {
    let stream = try await multiplexer.createStreamChannel { channel in
        channel.eventLoop.makeCompletedFuture {
            if replies != nil {
                try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(8)))
            }
            if replies != nil || windows != nil {
                try channel.pipeline.syncOperations.addHandler(HTTP2Replies(replies: replies, windows: windows))
            }
        }
    }.get()
    let headers = HPACKHeaders([
        (":method", "POST"), (":scheme", "https"), (":authority", "127.0.0.1"), (":path", path),
    ])
    try await stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers))).get()
    return stream
}

private final class HTTP2Events: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    let acknowledged: ByteCounter
    let peerBounds: ByteCounter
    let expectedSettings: HTTP2Settings

    init(acknowledged: ByteCounter, peerBounds: ByteCounter, expectedSettings: HTTP2Settings) {
        self.acknowledged = acknowledged
        self.peerBounds = peerBounds
        self.expectedSettings = expectedSettings
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data).payload {
        case .ping(let token, ack: true) where token == pingToken:
            acknowledged.add(1)
        case .settings(.settings(let values)) where expectedSettings.allSatisfy(values.contains):
            peerBounds.add(1)
        default:
            break
        }
        context.fireChannelRead(data)
    }
}

private final class HTTP2Receiver: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    let bulkReceived: [ByteCounter]
    let canceled: ByteCounter
    var path = ""

    init(bulkReceived: [ByteCounter], canceled: ByteCounter) {
        self.bulkReceived = bulkReceived
        self.canceled = canceled
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if path == "/cancel", let closed = error as? NIOHTTP2Errors.StreamClosed, closed.errorCode == .cancel {
            canceled.add(1)
        }
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let headers):
            path = headers.headers.first(name: ":path") ?? ""
            let response = HPACKHeaders([(":status", "200")])
            context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: response))), promise: nil)
        case .data(let part):
            if path.hasPrefix("/bulk/"), let index = Int(path.dropFirst("/bulk/".count)),
               bulkReceived.indices.contains(index), case .byteBuffer(let buffer) = part.data {
                bulkReceived[index].add(buffer.readableBytes)
            } else if path == "/rpc" {
                context.writeAndFlush(wrapOutboundOut(.data(part)), promise: nil)
            }
        default:
            break
        }
    }
}

private final class HTTP2Replies: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload

    let replies: AsyncStream<Data>.Continuation?
    let windows: ByteCounter?
    var pending = ByteBuffer()

    init(replies: AsyncStream<Data>.Continuation?, windows: ByteCounter?) {
        self.replies = replies
        self.windows = windows
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .data(let part):
            guard let replies, case .byteBuffer(var buffer) = part.data else { return }
            pending.writeBuffer(&buffer)
            while let payload = pending.readBytes(length: rpcPayload.count) { replies.yield(Data(payload)) }
            pending.discardReadBytes()
        case .windowUpdate:
            windows?.add(1)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event as? IdleStateHandler.IdleStateEvent == .read {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        replies?.finish()
        context.fireChannelInactive()
    }
}
