import Foundation
/// RFC 6455 framing for the daemon's Unix socket. Client frames are always masked.
public struct WebSocketCodec {
    public enum Failure: Error { case malformed, oversized, closed }
    private var buffer = Data()
    private var fragment = Data()
    private var fragmentOpcode: UInt8?
    public init() {}
    public static func frame(_ payload: Data, opcode: UInt8 = 1) -> Data {
        var bytes = Data([0x80 | opcode])
        if payload.count < 126 { bytes.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            bytes.append(0xfe); bytes.append(UInt8(payload.count >> 8)); bytes.append(UInt8(payload.count & 255))
        } else {
            bytes.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        bytes.append(contentsOf: mask)
        bytes.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return bytes
    }
    public mutating func append(_ data: Data) throws -> [(UInt8, Data)] {
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else { throw Failure.oversized }
        var messages: [(UInt8, Data)] = []
        while buffer.count >= 2 {
            let b = [UInt8](buffer.prefix(14)); let final = b[0] & 0x80 != 0; let op = b[0] & 15
            guard b[0] & 0x70 == 0, b[1] & 0x80 == 0 else { throw Failure.malformed }
            var length = UInt64(b[1] & 127); var header = 2
            if length == 126 {
                guard buffer.count >= 4 else { break }; length = UInt64(b[2]) << 8 | UInt64(b[3]); header = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { break }; length = b[2..<10].reduce(0) { ($0 << 8) | UInt64($1) }; header = 10
            }
            guard length <= 8 * 1024 * 1024 else { throw Failure.oversized }
            guard op < 8 || (final && length <= 125) else { throw Failure.malformed }
            guard buffer.count >= header + Int(length) else { break }
            let payload = Data(buffer.dropFirst(header).prefix(Int(length)))
            buffer = Data(buffer.dropFirst(header + Int(length)))
            if op == 8 { throw Failure.closed }
            if op == 9 || op == 10 { messages.append((op, payload)); continue }
            if op == 0 {
                guard fragmentOpcode != nil else { throw Failure.malformed }
                fragment.append(payload)
                guard fragment.count <= 8 * 1024 * 1024 else { throw Failure.oversized }
                if final { messages.append((fragmentOpcode!, fragment)); fragment.removeAll(); fragmentOpcode = nil }
            } else {
                guard (op == 1 || op == 2) && fragmentOpcode == nil else { throw Failure.malformed }
                if final { messages.append((op, payload)) } else { fragmentOpcode = op; fragment = payload }
            }
        }
        return messages
    }
}
