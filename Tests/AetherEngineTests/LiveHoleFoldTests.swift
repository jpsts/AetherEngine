import Testing
@testable import AetherEngine

/// A live feed that lost a few seconds keeps playing across the hole in its stamps, in whichever order
/// the two streams reach it; a sparse picture over continuous sound is no hole.
@Suite("Live hole fold")
struct LiveHoleFoldTests {
    private func running(video: Double = 100, audio: Double = 100) -> LiveHoleFold {
        var fold = LiveHoleFold()
        fold.noteVideo(seconds: video)
        _ = fold.audio(seconds: audio, currentFoldSeconds: 0)
        return fold
    }

    @Test("a hole in both streams opens at the video packet past it")
    func holeInBoth() {
        let fold = running()
        #expect(fold.opensHole(videoSeconds: 107.76))
        #expect(!fold.opensHole(videoSeconds: 102.9), "below the threshold")
    }

    @Test("video that jumps under continuous sound is no hole")
    func sparsePicture() {
        var fold = running()
        for tick in 1...300 {
            #expect(fold.audio(seconds: 100 + Double(tick) * 0.02, currentFoldSeconds: 0) == .play(foldSeconds: 0))
        }
        #expect(!fold.opensHole(videoSeconds: 106))
    }

    @Test("audio over the hole first waits for the video, then plays folded")
    func audioCrossesFirst() {
        var fold = running()
        #expect(fold.audio(seconds: 107.8, currentFoldSeconds: 0) == .drop)
        #expect(fold.audio(seconds: 107.82, currentFoldSeconds: 0) == .drop)
        #expect(fold.opensHole(videoSeconds: 107.76), "held audio does not count as having crossed")
        fold.noteFold(fromVideoSeconds: 100, toVideoSeconds: 107.76, foldBefore: 0)
        fold.noteVideo(seconds: 107.76)
        #expect(fold.audio(seconds: 107.84, currentFoldSeconds: 7.72) == .play(foldSeconds: 7.72))
    }

    @Test("audio still short of the hole keeps the fold before it")
    func videoCrossesFirst() {
        var fold = running()
        fold.noteFold(fromVideoSeconds: 100, toVideoSeconds: 107.76, foldBefore: 2)
        fold.noteVideo(seconds: 107.76)
        #expect(fold.audio(seconds: 100.02, currentFoldSeconds: 9.72) == .play(foldSeconds: 2))
        #expect(fold.audio(seconds: 107.7, currentFoldSeconds: 9.72) == .play(foldSeconds: 9.72),
                "audio past the hole, just below the video, folds with it")
    }

    @Test("audio with a hole of its own is held only briefly")
    func audioOnlyHole() {
        var fold = running()
        var audio = 106.0
        for _ in 0..<LiveHoleFold.audioPacketsHeldAtMost {
            #expect(fold.audio(seconds: audio, currentFoldSeconds: 0) == .drop)
            audio += 0.02
        }
        #expect(fold.audio(seconds: audio, currentFoldSeconds: 0) == .play(foldSeconds: 0))
    }
}
