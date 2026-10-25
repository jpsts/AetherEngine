import Foundation
import Testing
@testable import AetherEngine

/// AE#286: a VOD pump far enough ahead of its consumer relaxes to `.utility`, and it is still waited
/// on when it ends: a seek's restart stops it and blocks in `waitForFinish` on the local server's
/// `.userInitiated` queue. A condition donates no priority to the thread it waits for, so the
/// relaxed pump tore down and broadcast its finish at `.utility`, which Xcode's Thread Performance
/// Checker reports as a user-initiated thread waiting on a utility one.
@Suite("A relaxed pump unwinds at the responsive class (#286)", .serialized)
struct RelaxedPumpUnwindQoSTests {

    private final class Observed: @unchecked Sendable {
        private let lock = NSLock()
        private var _parkedQoS: qos_class_t?
        private var _finishedQoS: qos_class_t?
        func parked(_ qos: qos_class_t) { lock.withLock { _parkedQoS = qos } }
        func finished(_ qos: qos_class_t) { lock.withLock { _finishedQoS = qos } }
        var parkedQoS: qos_class_t? { lock.withLock { _parkedQoS } }
        var finishedQoS: qos_class_t? { lock.withLock { _finishedQoS } }
    }

    @Test("a stop waited on from a user-initiated thread finds the pump back at user-initiated",
          .timeLimit(.minutes(1)))
    func relaxedPumpUnwindsResponsive() async throws {
        let data = try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))

        // The fixture has a keyframe every second, so one segment per second. An 8 s target puts the
        // relaxed lead at its 2-segment floor, and a forward window of 4 parks the pump at segment 5
        // while the consumer sits on segment 0.
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        defer { cache.close() }
        cache.declareTarget(0)
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: videoIndex,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                         timeBase: stream.pointee.time_base, codecTagOverride: nil),
            cache: cache, targetSegmentDurationSeconds: 8, videoFallbackDurationPts: 200,
            desiredFirstVideoTfdtPts: 0, segmentBoundaries: (0..<15).map { Int64($0) * 1000 },
            bufferAheadSegments: 4)
        let observed = Observed()
        producer.hasStartedRenderingProvider = { true }
        // A paused consumer: the park holds without the wedge breaker ending the pump on its own.
        // Asked on the pump thread once a second while it is parked.
        producer.wantsToPlayProvider = { observed.parked(qos_class_self()); return false }
        // Runs on the pump thread right after the finish broadcast.
        producer.onPumpFinished = { _ in observed.finished(qos_class_self()) }
        producer.start()

        try await waitFor { observed.parkedQoS == QOS_CLASS_UTILITY }

        producer.stop()
        let exited = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: producer.waitForFinish(timeout: 30))
            }
        }
        #expect(exited)
        try await waitFor { observed.finishedQoS != nil }
        #expect(observed.finishedQoS == QOS_CLASS_USER_INITIATED,
                "the pump unwound at \(QoSClass.name(observed.finishedQoS ?? QOS_CLASS_UNSPECIFIED))")
    }
}
