import Testing
import Foundation
@testable import AetherEngine

/// A live stream read straight off its URL (an IPTV panel's continuous MPEG-TS form of a channel)
/// and refused for a while, as a connection-limited panel refuses an account's requests with 509
/// while another device holds its last slot, keeps its session: the reader asks again every second
/// and carries on the moment it is served, the refusals arm no pacer, and a refused open is the
/// origin's answer, typed, rather than a minute of the same request.
@Suite("Live stream reader rides out refusals", .offCooperativePool, .timeLimit(.minutes(2)))
struct LiveStreamRefusalRetryTests {

    // MARK: - Loopback origin

    /// One HTTP/1.1 response per connection (Connection: close), scripted per request.
    private final class ScriptedOrigin: @unchecked Sendable {
        struct Response {
            var status: Int
            var headers: [String: String] = [:]
            var body = Data()
        }

        let port: UInt16
        private let listener: LoopbackListener
        private let respond: @Sendable (_ index: Int) -> Response
        private let lock = NSLock()
        private var times: [Date] = []

        /// `respond` gets how many requests came before this one.
        init?(respond: @escaping @Sendable (_ index: Int) -> Response) {
            self.respond = respond
            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { [weak self] conn in
                guard let self else { close(conn); return false }
                Thread.detachNewThread { [weak self] in
                    self?.serve(conn)
                }
                return true
            }
        }

        func stop() {
            listener.stop()
        }

        var requestTimes: [Date] {
            lock.withLock { times }
        }

        var url: URL {
            URL(string: "http://127.0.0.1:\(port)/live/user/pass/1.ts")!
        }

        private func serve(_ conn: Int32) {
            defer { close(conn) }
            var request = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(conn, &buf, buf.count)
                guard n > 0 else { return }
                request.append(contentsOf: buf[0..<n])
                if request.count > 64 * 1024 { return }
            }
            let index: Int = lock.withLock {
                times.append(Date())
                return times.count - 1
            }
            let response = respond(index)
            var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
            header += "Content-Type: video/mp2t\r\n"
            for (field, value) in response.headers {
                header += "\(field): \(value)\r\n"
            }
            header += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { write(conn, $0, strlen($0)) }
            response.body.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(conn, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }

    /// Valid sync bytes at 188-byte cadence, enough to be read in several reader calls.
    private static func streamBytes(count packets: Int) -> Data {
        var data = Data(capacity: packets * 188)
        for packet in 0..<packets {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: packet), count: 188)
            ts[0] = 0x47
            data.append(contentsOf: ts)
        }
        return data
    }

    private static func makeLiveReader(_ url: URL) -> AVIOReader {
        AVIOReader(url: url, label: "live", prefetchEnabled: true, isLive: true)
    }

    /// Reads until `expectedBytes` have come through or the reader fails; the bytes, and the code
    /// the read ended with when it did not deliver them.
    private static func drain(_ reader: AVIOReader, expectedBytes: Int) -> (bytes: Int, failure: Int32?) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        var total = 0
        while total < expectedBytes {
            let n = reader.read(into: buf, size: 64 * 1024)
            if n <= 0 { return (total, n) }
            total += Int(n)
        }
        return (total, nil)
    }

    private static func gaps(_ times: [Date]) -> [TimeInterval] {
        zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
    }

    // MARK: - Tests

    @Test("a stream refused mid-session is asked for again every second until it is served")
    func refusedMidStreamIsRetriedEverySecond() throws {
        let first = Self.streamBytes(count: 400)
        let second = Self.streamBytes(count: 400)
        let origin = try #require(ScriptedOrigin { index in
            switch index {
            case 0: return .init(status: 200, body: first)
            case 1, 2, 3: return .init(status: 509)
            default: return .init(status: 200, body: second)
            }
        })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let drained = Self.drain(reader, expectedBytes: first.count + second.count)

        #expect(drained.failure == nil)
        #expect(drained.bytes >= first.count + second.count)
        let times = origin.requestTimes
        #expect(times.count >= 5)
        // The three refusals are retried a second apart, give or take the request itself and a
        // loaded test host; never up the 0.5, 1, 2, 4 s ladder, whose third rung alone is 4 s.
        let retryGaps = Array(Self.gaps(times).dropFirst()).prefix(3)
        #expect(retryGaps.count == 3)
        for gap in retryGaps {
            #expect(gap >= 0.9 && gap <= 3.5, "retry gap \(gap)s")
        }
        #expect(retryGaps.reduce(0, +) <= 7, "retry gaps \(Array(retryGaps))")
        // The refusals armed no pacer and lowered no budget: the books hold no refusal for this
        // origin (a witness stamp carries no count).
        let books = OriginRequestBudget.shared.snapshot(for: origin.url)
        #expect((books?.refusals ?? 0) == 0)
        #expect(books?.limit == nil)
    }

    @Test("the origin's Retry-After stretches the wait, up to five seconds")
    func retryAfterStretchesTheWait() throws {
        let first = Self.streamBytes(count: 400)
        let second = Self.streamBytes(count: 400)
        let origin = try #require(ScriptedOrigin { index in
            switch index {
            case 0: return .init(status: 200, body: first)
            case 1: return .init(status: 503, headers: ["Retry-After": "2"])
            case 2: return .init(status: 503, headers: ["Retry-After": "30"])
            default: return .init(status: 200, body: second)
            }
        })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let drained = Self.drain(reader, expectedBytes: first.count + second.count)

        #expect(drained.failure == nil)
        let retryGaps = Array(Self.gaps(origin.requestTimes).dropFirst())
        #expect(retryGaps.count >= 2)
        if retryGaps.count >= 2 {
            #expect(retryGaps[0] >= 1.9 && retryGaps[0] <= 4.5, "Retry-After 2 gap \(retryGaps[0])s")
            #expect(retryGaps[1] >= 4.9 && retryGaps[1] <= 8, "Retry-After 30 capped gap \(retryGaps[1])s")
        }
    }

    @Test("a stream refused for longer than the budget ends as a read error")
    func refusedPastTheBudgetGivesUp() throws {
        let first = Self.streamBytes(count: 400)
        let origin = try #require(ScriptedOrigin { index in
            index == 0 ? .init(status: 200, body: first) : .init(status: 509)
        })
        defer { origin.stop() }
        AVIOReader.liveRefusalRetryBudgetForTesting = 3
        defer { AVIOReader.liveRefusalRetryBudgetForTesting = nil }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let drained = Self.drain(reader, expectedBytes: first.count + 1)

        #expect(drained.bytes == first.count)
        #expect(drained.failure == FFmpegErr.eio)
        // Asked about three times over the budget, one a second, then given up.
        let refusals = origin.requestTimes.count - 1
        #expect(refusals >= 3 && refusals <= 6, "\(refusals) refused attempts")
    }

    @Test("a live open the origin refuses fails typed with its status at once")
    func refusedOpenFailsTyped() throws {
        let origin = try #require(ScriptedOrigin { _ in .init(status: 509) })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }

        let started = Date()
        let failure = #expect(throws: AVIOReaderError.self) { try reader.open() }
        #expect(failure == .httpStatus(509))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(origin.requestTimes.count == 1)
    }

    @Test("a live open answered 403 fails typed too")
    func forbiddenOpenFailsTyped() throws {
        let origin = try #require(ScriptedOrigin { _ in .init(status: 403) })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }

        let failure = #expect(throws: AVIOReaderError.self) { try reader.open() }
        #expect(failure == .httpStatus(403))
    }
}
