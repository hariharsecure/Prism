import AudioToolbox
import AVFAudio
import CoreMedia
import Foundation
import os
import XCTest

import PrismAVTestKit
import PrismCore
@testable import PrismAudio

/// MEDIUM — a stale `ptsAdjustment` must not misplace a later forward
/// source-restart.
///
/// `MixerChannel.commit` sets `state.ptsAdjustment` in the backward-PTS-jump
/// branch (to rebase that one reset packet) and applies it to EVERY later
/// absolute placement. Pre-fix it was never cleared, so a subsequent forward
/// source-restart (`alreadyRenderedPause`) — which re-arms absolute placement to
/// re-align the restart packet to house time — inherited the stale large offset
/// and placed the restart packet ~one epoch into the future (spurious leading
/// silence, or the packet trimmed/dropped).
///
/// The fix (a) zeroes `ptsAdjustment` on the forward-restart branch and (b)
/// clears it after each successful `placeAbsolutely`, so the rebase only ever
/// affects the ONE packet it was computed for.
final class MixerStalePTSAdjustmentTests: XCTestCase {
    private static let sampleRate = 48_000.0

    // MARK: - reproduce-first: backward jump then forward restart lands at house time, not the stale offset

    func testForwardRestartAfterBackwardJumpIgnoresStaleAdjustment() throws {
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )
        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        configuration.ringSeconds = 1.0
        configuration.tapBufferFrames = 256
        configuration.maximumInitialAlignmentSeconds = 1.0
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let source = SourceID("mixer.stale-adjustment")
        let channel = try mixer.addChannel(id: source)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        // (1) First packet establishes the epoch at house frame 0.
        let firstFrames = 5_120
        let p1 = try makeStereoImpulsePacket(pts: .zero, frameCount: firstFrames,
                                             activeChannel: 0, format: format)
        channel.ingest(AudioPacket(sampleBuffer: p1, source: source))
        var output = try render(mixer, frames: firstFrames)   // renderedThroughFrame → 5120

        // (2) A backward PTS jump (>30 ms) rebases this one packet and sets a LARGE
        // stale ptsAdjustment (~5,120 frames ≈ 106 ms).
        let backwardFrames = 960
        let p2 = try makeStereoImpulsePacket(pts: .zero, frameCount: backwardFrames,
                                             activeChannel: 0, format: format)
        channel.ingest(AudioPacket(sampleBuffer: p2, source: source))
        XCTAssertEqual(channel.timingStats.gapsDetected, 0,
                       "a backward jump is a rebase, not a forward gap")
        output += try render(mixer, frames: backwardFrames)   // renderedThroughFrame → 6080

        // Drain past the buffer so the ring UNDERRUNS — the precondition for a
        // forward restart (`alreadyRenderedPause`).
        output += try render(mixer, frames: 512)              // renderedThroughFrame → 6592
        XCTAssertEqual(channel.bufferedFrames, 0)
        XCTAssertGreaterThan(channel.bufferStats.underruns, 0,
                             "the ring must have underrun to arm a source restart")

        // (3) The source RESTARTS on house time (pts == current render frame 6592):
        // a forward gap (>30 ms) after a rendered pause. It must be placed at ~house
        // time (offset ~0), NOT shoved ~5,120 frames into the future by the stale
        // adjustment.
        let restartFrames = 960
        let restartPTSFrame = 6_592
        let p3 = try makeStereoImpulsePacket(
            pts: CMTime(value: CMTimeValue(restartPTSFrame), timescale: CMTimeScale(Self.sampleRate)),
            frameCount: restartFrames, activeChannel: 0, format: format
        )
        channel.ingest(AudioPacket(sampleBuffer: p3, source: source))

        // KILLER deterministic assertion: with the fix, absolute placement maps the
        // restart pts to the current render frame with a ZERO offset → the ring holds
        // exactly the packet, no prepended silence. Pre-fix the stale ~5,120-frame
        // adjustment prepends ~5,120 silence frames → bufferedFrames ≈ 6,080.
        XCTAssertEqual(channel.bufferedFrames, restartFrames,
                       "forward restart must place at house time (no stale-offset silence); pre-fix this is ~6080")
        XCTAssertEqual(channel.timingStats.gapsDetected, 1, "the restart is the one forward gap")

        // Confirm the restart impulse lands where the render cursor is (~6,592+100),
        // not ~5,120 frames later, by rendering it out.
        output += try render(mixer, frames: restartFrames + 512)
        let markers = output.left.indices.filter { abs(output.left[$0]) > 0.5 }
        XCTAssertEqual(markers.count, 3, "first impulse, rebased-backward impulse, restart impulse")
        let restartMarker = try XCTUnwrap(markers.last)
        XCTAssertGreaterThanOrEqual(restartMarker, restartPTSFrame + 100)
        XCTAssertLessThan(restartMarker, restartPTSFrame + 100 + 1_024,
                          "restart impulse lands at house time; a stale offset would push it ~5,120 frames later")
    }

    // MARK: - negative control: a forward restart with NO prior backward jump is unchanged

    func testForwardRestartWithoutPriorBackwardJumpIsUnchanged() throws {
        // The stale-adjustment mechanism can only bite after a backward jump has set
        // a non-zero ptsAdjustment. With no backward jump, ptsAdjustment is always
        // zero, so this control must behave identically pre- and post-fix: the
        // restart places exactly at house time with no leading silence.
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )
        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        configuration.ringSeconds = 1.0
        configuration.tapBufferFrames = 256
        configuration.maximumInitialAlignmentSeconds = 1.0
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let source = SourceID("mixer.no-backward")
        let channel = try mixer.addChannel(id: source)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        let firstFrames = 5_120
        let p1 = try makeStereoImpulsePacket(pts: .zero, frameCount: firstFrames,
                                             activeChannel: 0, format: format)
        channel.ingest(AudioPacket(sampleBuffer: p1, source: source))
        var output = try render(mixer, frames: firstFrames)   // renderedThroughFrame → 5120
        // Long enough underrun that the restart's forward gap (>30 ms) still maps
        // to the current render frame (offset ~0) — the source paused, time passed.
        output += try render(mixer, frames: 2_048)            // underrun → 7168
        XCTAssertEqual(channel.bufferedFrames, 0)
        XCTAssertGreaterThan(channel.bufferStats.underruns, 0)

        let restartFrames = 960
        let restartPTSFrame = 7_168
        let p3 = try makeStereoImpulsePacket(
            pts: CMTime(value: CMTimeValue(restartPTSFrame), timescale: CMTimeScale(Self.sampleRate)),
            frameCount: restartFrames, activeChannel: 0, format: format
        )
        channel.ingest(AudioPacket(sampleBuffer: p3, source: source))
        XCTAssertEqual(channel.bufferedFrames, restartFrames,
                       "a plain forward restart already places at house time (identical pre/post fix)")
        XCTAssertEqual(channel.timingStats.gapsDetected, 1)

        output += try render(mixer, frames: restartFrames + 512)
        let markers = output.left.indices.filter { abs(output.left[$0]) > 0.5 }
        XCTAssertEqual(markers.count, 2, "first impulse + restart impulse")
        let restartMarker = try XCTUnwrap(markers.last)
        XCTAssertGreaterThanOrEqual(restartMarker, restartPTSFrame + 100)
        XCTAssertLessThan(restartMarker, restartPTSFrame + 100 + 1_024)
    }

    // MARK: - helpers

    private struct StereoOutput {
        var left: [Float] = []
        var right: [Float] = []
        static func += (lhs: inout StereoOutput, rhs: StereoOutput) {
            lhs.left += rhs.left; lhs.right += rhs.right
        }
    }

    private func render(_ mixer: AudioMixer, frames: Int) throws -> StereoOutput {
        var out = StereoOutput()
        out.left.reserveCapacity(frames)
        out.right.reserveCapacity(frames)
        var remaining = frames
        while remaining > 0 {
            let block = min(remaining, 512)
            let buffer = try mixer.renderManually(frameCount: AVAudioFrameCount(block))
            guard let channels = buffer.floatChannelData, buffer.format.channelCount == 2 else {
                throw MixerTestError.invalidPCM("manual mixer output is not deinterleaved stereo")
            }
            let rendered = Int(buffer.frameLength)
            out.left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: rendered))
            out.right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: rendered))
            remaining -= block
        }
        return out
    }

    private func makeStereoImpulsePacket(
        pts: CMTime,
        frameCount: Int,
        activeChannel: Int,
        impulseFrame: Int = 100,
        format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        guard activeChannel == 0 || activeChannel == 1 else {
            throw MixerTestError.invalidPCM("stereo channel \(activeChannel) is out of range")
        }
        guard impulseFrame >= 0, impulseFrame < frameCount else {
            throw MixerTestError.invalidPCM("impulse frame \(impulseFrame) is out of range")
        }
        var samples = [Float](repeating: 0, count: frameCount * 2)
        samples[impulseFrame * 2 + activeChannel] = 0.8
        return try samples.withUnsafeBufferPointer {
            try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: $0.baseAddress!,
                frameCount: frameCount,
                channelCount: 2,
                formatDescription: format,
                pts: pts
            )
        }
    }
}

private enum MixerTestError: Error, CustomStringConvertible {
    case invalidPCM(String)
    var description: String { if case .invalidPCM(let r) = self { return r }; return "unknown" }
}
