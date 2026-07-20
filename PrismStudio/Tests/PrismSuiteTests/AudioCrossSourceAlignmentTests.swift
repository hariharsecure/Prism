import AudioToolbox
import AVFAudio
import CoreMedia
import Foundation
import os
import XCTest

import PrismAVTestKit
import PrismCore
@testable import PrismAudio

/// Regression coverage for mixer-wide initial-PTS placement. Independent source
/// FIFOs must share one render epoch instead of each treating its first packet as
/// frame zero.
final class AudioCrossSourceAlignmentTests: XCTestCase {
    private static let sampleRate = 48_000.0
    private static let sourceOffset = 0.250
    private static let skewBudget = 0.001 // 1 ms; identical-rate paths should be sample-accurate.

    func testRealMixerPreservesInitialPTSOffsetAcrossSources() throws {
        var fixtureConfiguration = AVRoundTripConfiguration()
        fixtureConfiguration.audioSampleRate = Self.sampleRate
        fixtureConfiguration.audioChunkFrames = 960

        let startA = CMTime.zero
        let startB = CMTime(seconds: Self.sourceOffset,
                            preferredTimescale: CMTimeScale(Self.sampleRate))
        let fixtureDuration = CMTime(seconds: 0.200,
                                     preferredTimescale: CMTimeScale(Self.sampleRate))
        let generator = AudioFixtureGenerator(configuration: fixtureConfiguration)
        let fixtureA = try generator.makePackets(startPTS: startA, duration: fixtureDuration)
        let fixtureB = try generator.makePackets(startPTS: startB, duration: fixtureDuration)

        let impulseA = try XCTUnwrap(fixtureA.expectedEvents.first { $0.kind == .impulse })
        let impulseB = try XCTUnwrap(fixtureB.expectedEvents.first { $0.kind == .impulse })
        XCTAssertEqual(fixtureA.expectedEvents.count, 1,
                       "the 200 ms source-A fixture must contain only its 100 ms impulse")
        XCTAssertEqual(fixtureB.expectedEvents.count, 1,
                       "the 200 ms source-B fixture must contain only its 100 ms impulse")
        XCTAssertEqual(impulseA.offsetSeconds, impulseB.offsetSeconds, accuracy: 1 / Self.sampleRate)
        XCTAssertEqual(try XCTUnwrap(fixtureA.packets.first).presentationTimeStamp.seconds,
                       startA.seconds, accuracy: 1 / Self.sampleRate)
        XCTAssertEqual(try XCTUnwrap(fixtureB.packets.first).presentationTimeStamp.seconds,
                       startB.seconds, accuracy: 1 / Self.sampleRate)

        // Route the same TestKit impulse into opposite stereo lanes. Both lanes
        // still pass through independent real MixerChannels and the real master
        // bus, but their marker positions remain independently observable even
        // if the bug lands both impulses on exactly the same output frame.
        let stereoFormat = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )
        let packetsA = try fixtureA.packets.map {
            try routeMonoFixturePacket($0, toStereoChannel: 0, format: stereoFormat)
        }
        let packetsB = try fixtureB.packets.map {
            try routeMonoFixturePacket($0, toStereoChannel: 1, format: stereoFormat)
        }

        var mixerConfiguration = AudioMixer.Configuration()
        mixerConfiguration.sampleRate = Self.sampleRate
        mixerConfiguration.channelCount = 2
        mixerConfiguration.ringSeconds = 1.0 // includes a future-correct 250 ms leading delay
        mixerConfiguration.tapBufferFrames = 256
        let mixer = AudioMixer(configuration: mixerConfiguration)
        let sourceA = SourceID("alignment.source-a")
        let sourceB = SourceID("alignment.source-b")
        let channelA = try mixer.addChannel(id: sourceA)
        let channelB = try mixer.addChannel(id: sourceB)

        let captured = OSAllocatedUnfairLock<[CMSampleBuffer]>(initialState: [])
        mixer.onMasterMix = { packet in
            captured.withLock { $0.append(packet.sampleBuffer) }
        }

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        for packet in packetsA {
            channelA.ingest(AudioPacket(sampleBuffer: packet, source: sourceA))
        }
        for packet in packetsB {
            channelB.ingest(AudioPacket(sampleBuffer: packet, source: sourceB))
        }

        var framesToRender = Int(Self.sampleRate * 0.600)
        while framesToRender > 0 {
            let block = min(framesToRender, 512)
            _ = try mixer.renderManually(frameCount: AVAudioFrameCount(block))
            framesToRender -= block
        }

        let master = try decodeMasterPackets(captured.withLock { $0 })
        XCTAssertEqual(master.left.count, master.right.count)
        XCTAssertFalse(master.packetPTS.isEmpty, "the real master tap produced no packets")
        XCTAssertTrue(zip(master.packetPTS, master.packetPTS.dropFirst()).allSatisfy {
            CMTimeCompare($0, $1) < 0
        }, "master output PTS must remain strictly monotonic in this reproducer")

        let markerA = try strongestMarker(in: master.left, label: "source A / left")
        let markerB = try strongestMarker(in: master.right, label: "source B / right")
        XCTAssertGreaterThan(markerA.amplitude, 0.75, "source A impulse did not traverse the mixer")
        XCTAssertGreaterThan(markerB.amplitude, 0.75, "source B impulse did not traverse the mixer")

        let trueMarkerPTS_A = startA.seconds + impulseA.offsetSeconds
        let trueMarkerPTS_B = startB.seconds + impulseB.offsetSeconds
        let trueOffset = trueMarkerPTS_B - trueMarkerPTS_A
        let measuredOffset = Double(markerB.frame - markerA.frame) / Self.sampleRate
        let evidence = String(
            format: "input offset %.3f ms; mixed-output offset %.3f ms; A frame %d peak %.3f; B frame %d peak %.3f; %d monotonic master PTS packets",
            trueOffset * 1_000,
            measuredOffset * 1_000,
            markerA.frame,
            markerA.amplitude,
            markerB.frame,
            markerB.amplitude,
            master.packetPTS.count
        )
        print("AudioCrossSourceAlignment evidence: \(evidence)")

        XCTAssertEqual(trueOffset, Self.sourceOffset, accuracy: 1 / Self.sampleRate)
        XCTAssertEqual(measuredOffset, trueOffset, accuracy: Self.skewBudget,
                       "real mixer did not preserve cross-source initial PTS; \(evidence)")
    }

    func testContiguousSingleSourceHasNoLeadingSilenceOrDrift() throws {
        let packetFrames = 960
        let packetCount = 20
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )

        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        configuration.ringSeconds = 0.5
        configuration.tapBufferFrames = 256
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let source = SourceID("alignment.contiguous")
        let channel = try mixer.addChannel(id: source)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        for packetIndex in 0..<packetCount {
            let pts = CMTime(value: CMTimeValue(packetIndex * packetFrames),
                             timescale: CMTimeScale(Self.sampleRate))
            let packet = try makeStereoImpulsePacket(
                pts: pts, frameCount: packetFrames, activeChannel: 0, format: format
            )
            channel.ingest(AudioPacket(sampleBuffer: packet, source: source))
        }

        let sourceFrames = packetFrames * packetCount
        let master = try renderOutput(mixer, frames: sourceFrames + 512)
        let markerFrames = master.left.indices.filter { abs(master.left[$0]) > 0.5 }
        let expectedFrames = (0..<packetCount).map { $0 * packetFrames + 100 }

        XCTAssertEqual(markerFrames, expectedFrames,
                       "contiguous packets gained leading silence or packet-boundary drift")
        XCTAssertTrue(master.right.allSatisfy { abs($0) < 1e-6 },
                      "inactive stereo lane must remain silent")
        XCTAssertEqual(channel.timingStats.gapsDetected, 0)
        XCTAssertEqual(channel.timingStats.silenceFramesInserted, 0)
    }

    func testAbsurdFutureFirstPTSUsesBoundedLeadingSilence() throws {
        let packetFrames = 960
        let alignmentCapFrames = Int(Self.sampleRate) // default one-second cap
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )

        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        configuration.ringSeconds = 2.0
        configuration.tapBufferFrames = 256
        configuration.maximumInitialAlignmentSeconds = 1.0
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let anchorID = SourceID("alignment.bound-anchor")
        let futureID = SourceID("alignment.bound-future")
        let anchor = try mixer.addChannel(id: anchorID)
        let future = try mixer.addChannel(id: futureID)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        let anchorPacket = try makeStereoImpulsePacket(
            pts: .zero, frameCount: packetFrames, activeChannel: 0, format: format
        )
        let futurePacket = try makeStereoImpulsePacket(
            pts: CMTime(seconds: 60, preferredTimescale: CMTimeScale(Self.sampleRate)),
            frameCount: packetFrames,
            activeChannel: 1,
            format: format
        )
        anchor.ingest(AudioPacket(sampleBuffer: anchorPacket, source: anchorID))
        future.ingest(AudioPacket(sampleBuffer: futurePacket, source: futureID))

        XCTAssertEqual(future.bufferedFrames, alignmentCapFrames + packetFrames,
                       "future placement must perform only bounded FIFO work")
        XCTAssertEqual(future.bufferStats.dropped, 0,
                       "a two-second ring must contain the one-second cap without overflow")

        let master = try renderOutput(
            mixer, frames: alignmentCapFrames + packetFrames + 512
        )
        let marker = try strongestMarker(in: master.right, label: "bounded future source / right")
        XCTAssertEqual(marker.frame, alignmentCapFrames + 100,
                       "future packet must land at the configured cap, not its 60-second PTS")
    }

    func testLateFirstPacketIsTrimmedToTheCurrentRenderFrame() throws {
        let packetFrames = 960
        let renderedBeforeLateSource = 4_800
        let latePacketPTSFrame = 4_320
        let impulseFrameInPacket = 600
        let expectedImpulseFrame = latePacketPTSFrame + impulseFrameInPacket
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )

        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let anchorID = SourceID("alignment.late-anchor")
        let lateID = SourceID("alignment.late-source")
        let anchor = try mixer.addChannel(id: anchorID)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        let anchorPacket = try makeStereoImpulsePacket(
            pts: .zero, frameCount: packetFrames, activeChannel: 0, format: format
        )
        anchor.ingest(AudioPacket(sampleBuffer: anchorPacket, source: anchorID))
        let beforeLatePacket = try renderOutput(mixer, frames: renderedBeforeLateSource)

        let late = try mixer.addChannel(id: lateID)
        let latePacket = try makeStereoImpulsePacket(
            pts: CMTime(value: CMTimeValue(latePacketPTSFrame),
                        timescale: CMTimeScale(Self.sampleRate)),
            frameCount: packetFrames,
            activeChannel: 1,
            impulseFrame: impulseFrameInPacket,
            format: format
        )
        late.ingest(AudioPacket(sampleBuffer: latePacket, source: lateID))
        XCTAssertEqual(late.bufferedFrames,
                       packetFrames - (renderedBeforeLateSource - latePacketPTSFrame),
                       "PCM before the current render frame must be discarded")

        let afterLatePacket = try renderOutput(mixer, frames: packetFrames + 512)
        let output = beforeLatePacket.right + afterLatePacket.right
        let marker = try strongestMarker(in: output, label: "late source / right")
        XCTAssertEqual(marker.frame, expectedImpulseFrame,
                       "late trimming must retain the packet's absolute house-time position")
    }

    func testRestartAfterRenderedPauseDoesNotInsertThePauseTwice() throws {
        let packetFrames = 960
        let restartFrame = 4_800
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )

        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        configuration.tapBufferFrames = 256
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let source = SourceID("alignment.restart")
        let channel = try mixer.addChannel(id: source)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        let first = try makeStereoImpulsePacket(
            pts: .zero, frameCount: packetFrames, activeChannel: 0, format: format
        )
        channel.ingest(AudioPacket(sampleBuffer: first, source: source))
        let beforeRestart = try renderOutput(mixer, frames: restartFrame)

        let restarted = try makeStereoImpulsePacket(
            pts: CMTime(value: CMTimeValue(restartFrame),
                        timescale: CMTimeScale(Self.sampleRate)),
            frameCount: packetFrames,
            activeChannel: 0,
            format: format
        )
        channel.ingest(AudioPacket(sampleBuffer: restarted, source: source))
        let afterRestart = try renderOutput(mixer, frames: packetFrames + 512)

        let output = beforeRestart.left + afterRestart.left
        let markerFrames = output.indices.filter { abs(output[$0]) > 0.5 }
        XCTAssertEqual(markerFrames, [100, restartFrame + 100],
                       "silence already rendered during a source pause must not be queued again")
        XCTAssertEqual(channel.timingStats.gapsDetected, 1)
        XCTAssertEqual(channel.timingStats.silenceFramesInserted, 0)
    }

    func testBackwardPTSResetRebasesOnlyThatChannel() throws {
        let firstPacketFrames = 5_120
        let resetPacketFrames = 960
        let format = try AudioSampleBufferFactory.interleavedFloatFormatDescription(
            sampleRate: Self.sampleRate, channelCount: 2
        )

        var configuration = AudioMixer.Configuration()
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 2
        let mixer = AudioMixer(configuration: configuration)
        mixer.isMonitoringEnabled = true
        let source = SourceID("alignment.backward-reset")
        let channel = try mixer.addChannel(id: source)

        try mixer.startManualRendering(maximumFrameCount: 512)
        defer { mixer.stop() }

        let first = try makeStereoImpulsePacket(
            pts: .zero, frameCount: firstPacketFrames, activeChannel: 0, format: format
        )
        channel.ingest(AudioPacket(sampleBuffer: first, source: source))
        let beforeReset = try renderOutput(mixer, frames: firstPacketFrames)

        // The source-local clock resets to zero after 100 ms. The mixer-wide
        // epoch must stay fixed while this one channel is rebased at frame 5,120.
        let reset = try makeStereoImpulsePacket(
            pts: .zero, frameCount: resetPacketFrames, activeChannel: 0, format: format
        )
        channel.ingest(AudioPacket(sampleBuffer: reset, source: source))
        XCTAssertEqual(channel.bufferedFrames, resetPacketFrames,
                       "reset PCM must be rebased intact, without trim or queued silence")
        let afterReset = try renderOutput(mixer, frames: resetPacketFrames + 512)

        let output = beforeReset.left + afterReset.left
        let markerFrames = output.indices.filter { abs(output[$0]) > 0.5 }
        XCTAssertEqual(markerFrames.count, 2)
        XCTAssertEqual(markerFrames.first, 100)
        let resetMarker = try XCTUnwrap(markerFrames.last)
        XCTAssertGreaterThanOrEqual(resetMarker, firstPacketFrames + 100)
        XCTAssertLessThanOrEqual(resetMarker, firstPacketFrames + 1_024 + 100,
                                 "reset must resume within the graph's prefetched render block")
    }

    private func render(_ mixer: AudioMixer, frames: Int) throws {
        var remaining = frames
        while remaining > 0 {
            let block = min(remaining, 512)
            _ = try mixer.renderManually(frameCount: AVAudioFrameCount(block))
            remaining -= block
        }
    }

    private func renderOutput(_ mixer: AudioMixer, frames: Int) throws -> DecodedMaster {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        var remaining = frames
        while remaining > 0 {
            let block = min(remaining, 512)
            let buffer = try mixer.renderManually(frameCount: AVAudioFrameCount(block))
            guard let channels = buffer.floatChannelData,
                  buffer.format.channelCount == 2 else {
                throw HarnessError.invalidPCM("manual mixer output is not deinterleaved stereo")
            }
            let rendered = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: rendered))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: rendered))
            remaining -= block
        }
        return DecodedMaster(left: left, right: right, packetPTS: [])
    }

    private func makeStereoImpulsePacket(
        pts: CMTime,
        frameCount: Int,
        activeChannel: Int,
        impulseFrame: Int = 100,
        format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        guard activeChannel == 0 || activeChannel == 1 else {
            throw HarnessError.invalidPCM("stereo channel \(activeChannel) is out of range")
        }
        guard impulseFrame >= 0, impulseFrame < frameCount else {
            throw HarnessError.invalidPCM("impulse frame \(impulseFrame) is out of range")
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

    private func routeMonoFixturePacket(
        _ packet: CMSampleBuffer,
        toStereoChannel activeChannel: Int,
        format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        guard activeChannel == 0 || activeChannel == 1 else {
            throw HarnessError.invalidPCM("stereo channel \(activeChannel) is out of range")
        }
        let frameCount = CMSampleBufferGetNumSamples(packet)
        guard frameCount > 0, let block = CMSampleBufferGetDataBuffer(packet) else {
            throw HarnessError.invalidPCM("fixture packet has no PCM data")
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount == frameCount * MemoryLayout<Float>.size else {
            throw HarnessError.invalidPCM(
                "fixture packet has \(byteCount) bytes for \(frameCount) mono Float32 frames"
            )
        }

        var mono = [Float](repeating: 0, count: frameCount)
        let copyStatus = mono.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                       destination: $0.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw HarnessError.coreMedia("CMBlockBufferCopyDataBytes(fixture)", copyStatus)
        }

        var stereo = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            stereo[frame * 2 + activeChannel] = mono[frame]
        }
        return try stereo.withUnsafeBufferPointer {
            try AudioSampleBufferFactory.makeInterleavedSampleBuffer(
                samples: $0.baseAddress!,
                frameCount: frameCount,
                channelCount: 2,
                formatDescription: format,
                pts: CMSampleBufferGetPresentationTimeStamp(packet)
            )
        }
    }

    private func decodeMasterPackets(_ packets: [CMSampleBuffer]) throws -> DecodedMaster {
        var left: [Float] = []
        var right: [Float] = []
        var packetPTS: [CMTime] = []

        for packet in packets {
            guard let description = CMSampleBufferGetFormatDescription(packet),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                throw HarnessError.invalidPCM("master packet has no audio format")
            }
            let format = asbd.pointee
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  format.mChannelsPerFrame == 2 else {
                throw HarnessError.invalidPCM("master packet is not interleaved stereo Float32 PCM")
            }
            guard let block = CMSampleBufferGetDataBuffer(packet) else {
                throw HarnessError.invalidPCM("master packet has no data buffer")
            }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount.isMultiple(of: 2 * MemoryLayout<Float>.size) else {
                throw HarnessError.invalidPCM("master packet byte count \(byteCount) is not whole stereo frames")
            }
            var interleaved = [Float](repeating: 0,
                                      count: byteCount / MemoryLayout<Float>.size)
            let copyStatus = interleaved.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                           destination: $0.baseAddress!)
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw HarnessError.coreMedia("CMBlockBufferCopyDataBytes(master)", copyStatus)
            }
            for frame in stride(from: 0, to: interleaved.count, by: 2) {
                left.append(interleaved[frame])
                right.append(interleaved[frame + 1])
            }
            packetPTS.append(CMSampleBufferGetPresentationTimeStamp(packet))
        }
        return DecodedMaster(left: left, right: right, packetPTS: packetPTS)
    }

    private func strongestMarker(in samples: [Float], label: String) throws -> Marker {
        guard let strongest = samples.enumerated().max(by: {
            abs($0.element) < abs($1.element)
        }) else {
            throw HarnessError.invalidPCM("\(label) output was empty")
        }
        let amplitude = abs(strongest.element)
        guard amplitude > 0.1 else {
            throw HarnessError.invalidPCM("\(label) contained no impulse (peak \(amplitude))")
        }
        return Marker(frame: strongest.offset, amplitude: amplitude)
    }
}

private struct DecodedMaster {
    let left: [Float]
    let right: [Float]
    let packetPTS: [CMTime]
}

private struct Marker {
    let frame: Int
    let amplitude: Float
}

private enum HarnessError: Error, CustomStringConvertible {
    case invalidPCM(String)
    case coreMedia(String, OSStatus)

    var description: String {
        switch self {
        case .invalidPCM(let reason):
            return reason
        case .coreMedia(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}
