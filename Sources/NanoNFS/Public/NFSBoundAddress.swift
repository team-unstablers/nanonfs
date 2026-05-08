import Foundation

/// Address that the transport ended up bound to. Transport-agnostic — does
/// not expose any NIO type. `host` is the IPv4 / IPv6 textual representation
/// (e.g. `127.0.0.1` or `::1`); `port` is the post-bind port number, which is
/// useful when the listener was constructed with port `0`.
public struct NFSBoundAddress: Sendable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}
