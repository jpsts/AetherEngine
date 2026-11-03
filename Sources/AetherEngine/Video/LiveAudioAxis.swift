import Foundation

/// A live source whose audio stamps sit far from its video stamps plays on one clock only once the
/// audio is moved onto the video's axis. The packets arrive interleaved, so the video packet last
/// read says where the audio belongs.
///
/// An MPEG-TS source does this when its audio runs more than a minute behind its video: FFmpeg's
/// 33-bit wrap correction takes the audio for a stream that wrapped and adds 95,443 s to it. Left
/// there the audio sets the live edge, the rewind buffer discards every video packet as older than
/// its window, and the clock stands on an axis no picture is on.
struct LiveAudioAxis {
    enum Decision: Equatable {
        /// Plays, this many seconds earlier than stamped.
        case play(shiftSeconds: Double)
        case drop
    }

    /// Further apart than this, audio and video are not one timeline. A muxer's interleave is seconds.
    static let farApartSeconds = 30.0
    /// A source's clocks that disagree for this many audio packets (about 4 s of AAC) have moved
    /// apart for good; fewer is one stream crossing a seam ahead of the other.
    static let audioPacketsBeforeMoving = 200
    /// A picture this sparse is a still image over sound, which says nothing about the audio's axis.
    static let videoPacketsBeforeMoving = 20
    /// With no video by this much audio there may be none coming.
    static let audioSecondsWithoutVideo = 5.0

    private var lastVideoSeconds = Double.nan
    private var firstAudioSeconds = Double.nan
    private var shiftSeconds = 0.0
    private var hasCompared = false
    private var disagreeingAudioPackets = 0
    private var videoPacketsWhileDisagreeing = 0

    mutating func noteVideo(ptsSeconds: Double) {
        lastVideoSeconds = ptsSeconds
        if disagreeingAudioPackets > 0 {
            videoPacketsWhileDisagreeing += 1
        }
    }

    mutating func audio(ptsSeconds: Double) -> Decision {
        guard !lastVideoSeconds.isNaN else {
            if firstAudioSeconds.isNaN { firstAudioSeconds = ptsSeconds }
            return ptsSeconds - firstAudioSeconds < Self.audioSecondsWithoutVideo
                ? .drop
                : .play(shiftSeconds: 0)
        }
        guard abs(ptsSeconds - shiftSeconds - lastVideoSeconds) > Self.farApartSeconds else {
            hasCompared = true
            disagreeingAudioPackets = 0
            videoPacketsWhileDisagreeing = 0
            return .play(shiftSeconds: shiftSeconds)
        }
        guard hasCompared else {
            hasCompared = true
            moveOntoVideo(ptsSeconds)
            return .play(shiftSeconds: shiftSeconds)
        }
        disagreeingAudioPackets += 1
        if disagreeingAudioPackets >= Self.audioPacketsBeforeMoving,
           videoPacketsWhileDisagreeing >= Self.videoPacketsBeforeMoving {
            moveOntoVideo(ptsSeconds)
            return .play(shiftSeconds: shiftSeconds)
        }
        return videoPacketsWhileDisagreeing > 0 ? .drop : .play(shiftSeconds: shiftSeconds)
    }

    private mutating func moveOntoVideo(_ ptsSeconds: Double) {
        shiftSeconds = ptsSeconds - lastVideoSeconds
        disagreeingAudioPackets = 0
        videoPacketsWhileDisagreeing = 0
        EngineLog.emit(
            "[LiveAudioAxis] audio stamps are \(String(format: "%.2f", shiftSeconds))s from video; "
            + "playing the audio on the video's axis",
            category: .swPlayback
        )
    }
}
