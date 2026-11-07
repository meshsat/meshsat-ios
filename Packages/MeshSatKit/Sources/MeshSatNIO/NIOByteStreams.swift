// MeshSatNIO: MeshSatNet's ByteStream, ByteStreamDialer and ByteStreamListener on SwiftNIO's POSIX
// sockets, for Linux (the Kit's tests and the Python interop runs) and the Mac. The app uses
// Network.framework instead (Packages/MeshSatApple's NWByteStreamDialer and NWByteStreamListener);
// nothing on the phone links this target. Plain TCP only: the TLS variants the Hub needs are the
// app's.
import Foundation
import MeshSatNet
import NIOCore
import NIOPosix

/// One event loop group for every NIO socket the Kit opens in a process.
public enum NIOShared {
    public static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
}

/// Pipes a channel's inbound bytes into an AsyncStream; the stream ends when the channel does.
private final class StreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let feed: AsyncStream<[UInt8]>.Continuation

    init(feed: AsyncStream<[UInt8]>.Continuation) { self.feed = feed }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes), !bytes.isEmpty { feed.yield(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        feed.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        feed.finish()
        context.close(promise: nil)
    }
}

public final class NIOByteStream: ByteStream, @unchecked Sendable {
    public let incoming: AsyncStream<[UInt8]>
    private let channel: any Channel

    fileprivate init(channel: any Channel, incoming: AsyncStream<[UInt8]>) {
        self.channel = channel
        self.incoming = incoming
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard channel.isActive else { throw ByteStreamError.closed }
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        try await channel.writeAndFlush(buf).get()
    }

    public func close() async {
        try? await channel.close().get()
    }

    /// The peer's address, for logs.
    public var remoteDescription: String { channel.remoteAddress?.description ?? "?" }
}

/// Dials plain TCP. `tls` is refused: the Kit's Linux tests never need it and the app has its own dialer.
public struct NIOByteStreamDialer: ByteStreamDialer {
    public init() {}

    public func dial(host: String, port: Int, tls: TlsClientOptions?, timeoutSeconds: Double) async throws -> any ByteStream {
        guard tls == nil else { throw ByteStreamError.refused("the NIO dialer carries plain TCP only") }
        var continuation: AsyncStream<[UInt8]>.Continuation!
        let incoming = AsyncStream<[UInt8]>(bufferingPolicy: .unbounded) { continuation = $0 }
        let feed = continuation!
        let bootstrap = ClientBootstrap(group: NIOShared.group)
            .connectTimeout(.milliseconds(Int64(timeoutSeconds * 1000)))
            .channelOption(ChannelOptions.Types.SocketOption(level: .tcp, name: .tcp_nodelay), value: 1)
            .channelInitializer { channel in channel.pipeline.addHandler(StreamHandler(feed: feed)) }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            feed.finish()
            throw ByteStreamError.refused("\(error)")
        }
        return NIOByteStream(channel: channel, incoming: incoming)
    }
}

public final class NIOByteStreamListener: ByteStreamListener, @unchecked Sendable {
    public let connections: AsyncStream<any ByteStream>
    private let feed: AsyncStream<any ByteStream>.Continuation
    private let channel: any Channel

    fileprivate init(channel: any Channel, connections: AsyncStream<any ByteStream>, feed: AsyncStream<any ByteStream>.Continuation) {
        self.channel = channel
        self.connections = connections
        self.feed = feed
    }

    public var port: Int { channel.localAddress?.port ?? 0 }

    public func close() async {
        feed.finish()
        try? await channel.close().get()
    }
}

public struct NIOByteStreamListenerFactory: ByteStreamListenerFactory {
    public init() {}

    public func listen(host: String, port: Int) async throws -> any ByteStreamListener {
        var continuation: AsyncStream<any ByteStream>.Continuation!
        let connections = AsyncStream<any ByteStream>(bufferingPolicy: .unbounded) { continuation = $0 }
        let feedConnections = continuation!
        let bootstrap = ServerBootstrap(group: NIOShared.group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.Types.SocketOption(level: .tcp, name: .tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                var c: AsyncStream<[UInt8]>.Continuation!
                let incoming = AsyncStream<[UInt8]>(bufferingPolicy: .unbounded) { c = $0 }
                let feed = c!
                feedConnections.yield(NIOByteStream(channel: channel, incoming: incoming))
                return channel.pipeline.addHandler(StreamHandler(feed: feed))
            }
        let channel = try await bootstrap.bind(host: host, port: port).get()
        return NIOByteStreamListener(channel: channel, connections: connections, feed: feedConnections)
    }
}
