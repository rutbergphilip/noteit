import Darwin
import Foundation
import NoteItDocTestSupport

/// A blocking TCP client for what `URLSession` can't do: a forged `Host`, reusing one connection, reading a stream.
final class RawHTTPClient {
    private let fd: Int32
    private var pending = Data()

    /// nil when the connection is refused.
    init?(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 5) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
    }

    deinit { Darwin.close(fd) }

    func send(_ text: String) {
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
    }

    /// Blocks until all of `data` is written; the `errno` of a failed write, or nil.
    func sendAll(_ data: Data) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += count
            }
            return nil
        }
    }

    /// Reads until `done` holds for everything read so far (consuming it), EOF or timeout.
    @discardableResult
    func read(until done: (String) -> Bool) -> String {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !done(String(decoding: pending, as: UTF8.self)) {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            pending.append(buffer, count: count)
        }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    func read(containing text: String) -> String { read { $0.contains(text) } }

    /// One complete response with a Content-Length body; anything after it stays buffered.
    func readResponse() -> String {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let text = String(decoding: pending, as: UTF8.self)
            if let found = pending.range(of: Data("\r\n\r\n".utf8)) {
                let end = (found.lowerBound - pending.startIndex)..<(found.upperBound - pending.startIndex)
                let head = String(decoding: pending.prefix(end.lowerBound), as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if pending.count >= end.upperBound + length {
                    let total = end.upperBound + length
                    let response = String(decoding: pending.prefix(total), as: UTF8.self)
                    pending = Data(pending.dropFirst(total))
                    return response
                }
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return text }
            pending.append(buffer, count: count)
        }
    }

    /// Keeps writing a byte every 10 ms until a write fails, which happens once the server has torn the connection
    /// down (a lingering server still reads and discards them). False when writes still succeed after `timeout`.
    func isResetOnWrite(timeout: TimeInterval = TestTiming.scaled(2)) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0x61
        while Date() < deadline {
            if Darwin.send(fd, &byte, 1, 0) < 0, errno != EINTR { return true }
            usleep(10_000)
        }
        return false
    }

    /// True when the server closed the connection (EOF) before the timeout.
    func isClosedByPeer() -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = recv(fd, &byte, 1, 0)
            if count == 0 { return true }
            if count < 0 { return errno == ECONNRESET }
        }
    }
}
