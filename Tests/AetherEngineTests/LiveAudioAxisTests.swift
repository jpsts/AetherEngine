import Testing
@testable import AetherEngine

/// A live source's audio and video stamps can sit a day apart; the audio then has to play on the
/// video's axis, while audio and video that merely cross a seam at different moments stay as stamped.
@Suite("Live audio axis")
struct LiveAudioAxisTests {
    /// What FFmpeg's wrap correction makes of audio 274 s behind its video.
    private static let wrappedOffset = 95_169.6

    @Test("audio a day from its video plays on the video's axis from the first packet")
    func wrappedAudioMovesAtOnce() {
        var axis = LiveAudioAxis()
        axis.noteVideo(ptsSeconds: 13_914)
        #expect(axis.audio(ptsSeconds: 13_914 + Self.wrappedOffset) == .play(shiftSeconds: Self.wrappedOffset))
        axis.noteVideo(ptsSeconds: 13_915)
        #expect(axis.audio(ptsSeconds: 13_915 + Self.wrappedOffset) == .play(shiftSeconds: Self.wrappedOffset))
    }

    @Test("audio near its video keeps its stamps")
    func nearbyAudioStays() {
        var axis = LiveAudioAxis()
        axis.noteVideo(ptsSeconds: 100)
        #expect(axis.audio(ptsSeconds: 103) == .play(shiftSeconds: 0))
    }

    @Test("audio before the first video waits for it, for a while")
    func audioBeforeVideo() {
        var axis = LiveAudioAxis()
        #expect(axis.audio(ptsSeconds: 500) == .drop)
        #expect(axis.audio(ptsSeconds: 504.9) == .drop)
        #expect(axis.audio(ptsSeconds: 505) == .play(shiftSeconds: 0))
    }

    @Test("a seam the audio crosses first drops only until the video follows")
    func seamCrossedByAudioFirst() {
        var axis = LiveAudioAxis()
        axis.noteVideo(ptsSeconds: 100)
        #expect(axis.audio(ptsSeconds: 100) == .play(shiftSeconds: 0))
        #expect(axis.audio(ptsSeconds: 5_000) == .play(shiftSeconds: 0), "no video has moved yet")
        axis.noteVideo(ptsSeconds: 100.04)
        #expect(axis.audio(ptsSeconds: 5_000.02) == .drop)
        axis.noteVideo(ptsSeconds: 5_000.04)
        #expect(axis.audio(ptsSeconds: 5_000.06) == .play(shiftSeconds: 0))
    }

    @Test("clocks that move apart mid-session move the audio once both have shown it for good")
    func clocksMoveApartForGood() {
        var axis = LiveAudioAxis()
        axis.noteVideo(ptsSeconds: 100)
        #expect(axis.audio(ptsSeconds: 100) == .play(shiftSeconds: 0))
        var video = 100.0
        var audio = 1_100.0
        var last = LiveAudioAxis.Decision.drop
        for _ in 0..<LiveAudioAxis.audioPacketsBeforeMoving {
            video += 0.02
            audio += 0.02
            axis.noteVideo(ptsSeconds: video)
            last = axis.audio(ptsSeconds: audio)
        }
        #expect(last == .play(shiftSeconds: audio - video))
    }

    /// One picture a minute over continuous sound: the sound is never dropped or moved.
    @Test("sound under a sparse still image is left alone")
    func sparseVideoKeepsSound() {
        var axis = LiveAudioAxis()
        axis.noteVideo(ptsSeconds: 0)
        var audio = 0.0
        for frame in 1...5 {
            while audio < Double(frame) * 60 {
                audio += 0.02
                #expect(axis.audio(ptsSeconds: audio) == .play(shiftSeconds: 0))
            }
            axis.noteVideo(ptsSeconds: Double(frame) * 60)
        }
    }
}
