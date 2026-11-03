import Foundation

/// A live source that lost a few seconds of its feed comes back with a hole in its timestamps. Played
/// out, the hole is a standing picture with the clock running through it, so a hole folds out of the
/// timeline like any larger jump. Audio decides what is a hole: under a sparse picture (a still image
/// over a radio channel) the video's stamps jump while the sound carries on.
struct LiveHoleFold {
    enum AudioDecision: Equatable {
        /// Plays, this many seconds earlier than stamped.
        case play(foldSeconds: Double)
        case drop
    }

    static let forwardHoleSeconds = 3.0
    /// Audio past a hole the video stays short of (about 2 s of AAC) has a hole of its own.
    static let audioPacketsHeldAtMost = 100

    private var lastVideoSeconds = Double.nan
    private var lastAudioSeconds = Double.nan
    private var isHoldingAudio = false
    private var audioPacketsHeld = 0
    private var seam: (middleSeconds: Double, foldBefore: Double)?

    /// Whether this video packet opened a hole both streams have in them.
    func opensHole(videoSeconds: Double) -> Bool {
        guard !lastVideoSeconds.isNaN, !lastAudioSeconds.isNaN else { return false }
        return videoSeconds - lastVideoSeconds >= Self.forwardHoleSeconds
            && videoSeconds - lastAudioSeconds >= Self.forwardHoleSeconds
    }

    mutating func noteVideo(seconds: Double) {
        lastVideoSeconds = seconds
    }

    /// The video crossed a forward jump: audio still short of it keeps the fold it was stamped under.
    /// The middle of the jump tells them apart, since audio past it may stamp just below the video.
    mutating func noteFold(fromVideoSeconds: Double, toVideoSeconds: Double, foldBefore: Double) {
        seam = ((fromVideoSeconds + toVideoSeconds) / 2, foldBefore)
    }

    mutating func audio(seconds: Double, currentFoldSeconds: Double) -> AudioDecision {
        if let seam {
            if seconds < seam.middleSeconds {
                lastAudioSeconds = seconds
                return .play(foldSeconds: seam.foldBefore)
            }
            self.seam = nil
        }
        // Audio over a hole the video has yet to reach waits for the fold.
        if isHoldingAudio {
            if seconds - lastVideoSeconds >= Self.forwardHoleSeconds, audioPacketsHeld < Self.audioPacketsHeldAtMost {
                audioPacketsHeld += 1
                return .drop
            }
            isHoldingAudio = false
        } else if !lastAudioSeconds.isNaN, !lastVideoSeconds.isNaN,
                  seconds - lastAudioSeconds >= Self.forwardHoleSeconds,
                  seconds - lastVideoSeconds >= Self.forwardHoleSeconds {
            isHoldingAudio = true
            audioPacketsHeld = 1
            return .drop
        }
        lastAudioSeconds = seconds
        return .play(foldSeconds: currentFoldSeconds)
    }
}
