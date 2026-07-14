import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import os
import PrismCore
@testable import PrismSources
import XCTest

/// Regression coverage for the cross-queue lifecycle races that ordinary movie
/// playback tests do not force. Every test uses a local synthetic media file.
final class MovieLifecycleRegressionTests: XCTestCase {
    private static let deadlockProbeEnvironmentKey = "PRISM_MOVIE_DEADLOCK_PROBE"
    private static let drainOwnershipProbeEnvironmentKey = "PRISM_MOVIE_DRAIN_OWNERSHIP_PROBE"
    private static let probeFixtureEnvironmentKey = "PRISM_MOVIE_PROBE_FIXTURE"

    func testConcurrentVideoAudioCallbackStopsAndExternalStopDoNotDeadlock() throws {
        if ProcessInfo.processInfo.environment[Self.deadlockProbeEnvironmentKey] == "1" {
            try runConcurrentStopProbe(fileURL: try probeFixtureURL())
            return
        }

        let url = try makeClip(videoFrames: 12, fps: 24, audioSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        try runProbeInChild(
            testName: "testConcurrentVideoAudioCallbackStopsAndExternalStopDoNotDeadlock",
            environmentKey: Self.deadlockProbeEnvironmentKey,
            fixtureURL: url,
            timeoutMessage: "external stop deadlocked with movie delivery callbacks"
        )
    }

    private func runConcurrentStopProbe(fileURL: URL) throws {
        let source = try MovieSource(
            id: SourceID("movie.lifecycle.concurrent-stop"),
            fileURL: fileURL,
            canvasSize: CanvasSize(width: 160, height: 120),
            loop: true
        )
        let videoEntered = DispatchSemaphore(value: 0)
        let audioEntered = DispatchSemaphore(value: 0)
        let releaseVideo = DispatchSemaphore(value: 0)
        let releaseAudio = DispatchSemaphore(value: 0)
        let videoStopReturned = DispatchSemaphore(value: 0)
        let audioStopReturned = DispatchSemaphore(value: 0)
        let externalStopReturned = DispatchSemaphore(value: 0)
        let videoCallbacks = OSAllocatedUnfairLock(initialState: 0)
        let audioCallbacks = OSAllocatedUnfairLock(initialState: 0)

        source.onFrame = { _ in
            videoCallbacks.withLock { $0 += 1 }
            videoEntered.signal()
            _ = releaseVideo.wait(timeout: .now() + 3.0)
            source.stop()
            videoStopReturned.signal()
        }
        source.onAudio = { _ in
            audioCallbacks.withLock { $0 += 1 }
            audioEntered.signal()
            _ = releaseAudio.wait(timeout: .now() + 3.0)
            source.stop()
            audioStopReturned.signal()
        }

        try source.start()
        guard videoEntered.wait(timeout: .now() + 5.0) == .success,
              audioEntered.wait(timeout: .now() + 5.0) == .success else {
            releaseVideo.signal()
            releaseAudio.signal()
            source.stop()
            XCTFail("synthetic A/V clip did not enter both delivery callbacks")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            source.stop()
            externalStopReturned.signal()
        }
        XCTAssertTrue(
            waitUntil(timeout: 2.0) { source.state == .stopping },
            "external stop never completed its lifecycle transition"
        )

        // On the old implementation the external stop still owns
        // lifecycleQueue while draining videoQueue. Both callbacks then block
        // trying to enter lifecycleQueue, completing the lock cycle.
        releaseVideo.signal()
        releaseAudio.signal()
        XCTAssertEqual(
            videoStopReturned.wait(timeout: .now() + 2.0), .success,
            "video callback stop deadlocked with the external stop"
        )
        XCTAssertEqual(
            audioStopReturned.wait(timeout: .now() + 2.0), .success,
            "audio callback stop deadlocked with the external stop"
        )
        XCTAssertEqual(
            externalStopReturned.wait(timeout: .now() + 2.0), .success,
            "external stop did not finish draining movie delivery queues"
        )
        XCTAssertEqual(source.state, .idle)

        let videoCountAtReturn = videoCallbacks.withLock { $0 }
        let audioCountAtReturn = audioCallbacks.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(videoCallbacks.withLock { $0 }, videoCountAtReturn,
                       "a video callback began after external stop returned")
        XCTAssertEqual(audioCallbacks.withLock { $0 }, audioCountAtReturn,
                       "an audio callback began after external stop returned")
        source.onFrame = nil
        source.onAudio = nil
    }

    func testCallbackOwnedStopWaitsForConcurrentExternalDrainBeforeIdle() throws {
        if ProcessInfo.processInfo.environment[Self.drainOwnershipProbeEnvironmentKey] == "1" {
            try runCallbackOwnedStopProbe(fileURL: try probeFixtureURL())
            return
        }

        let url = try makeClip(videoFrames: 12, fps: 24, audioSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        try runProbeInChild(
            testName: "testCallbackOwnedStopWaitsForConcurrentExternalDrainBeforeIdle",
            environmentKey: Self.drainOwnershipProbeEnvironmentKey,
            fixtureURL: url,
            timeoutMessage: "a restart overtook a concurrent external movie drain"
        )
    }

    private func runCallbackOwnedStopProbe(fileURL: URL) throws {
        let source = try MovieSource(
            id: SourceID("movie.lifecycle.drain-ownership"),
            fileURL: fileURL,
            canvasSize: CanvasSize(width: 160, height: 120),
            loop: true
        )
        let videoEntered = DispatchSemaphore(value: 0)
        let audioEntered = DispatchSemaphore(value: 0)
        let allowVideoStop = DispatchSemaphore(value: 0)
        let releaseAudio = DispatchSemaphore(value: 0)
        let callbackStopReturned = DispatchSemaphore(value: 0)
        let callbackStartReturned = DispatchSemaphore(value: 0)
        let externalStopReturned = DispatchSemaphore(value: 0)
        let videoCallbacks = OSAllocatedUnfairLock(initialState: 0)
        let audioCallbacks = OSAllocatedUnfairLock(initialState: 0)
        let restartError = OSAllocatedUnfairLock<Error?>(initialState: nil)

        source.onAudio = { _ in
            let callback = audioCallbacks.withLock { count -> Int in
                count += 1
                return count
            }
            guard callback == 1 else { return }
            audioEntered.signal()
            _ = releaseAudio.wait(timeout: .now() + 4.0)
        }
        source.onFrame = { _ in
            let callback = videoCallbacks.withLock { count -> Int in
                count += 1
                return count
            }
            guard callback == 1 else { return }
            videoEntered.signal()
            _ = allowVideoStop.wait(timeout: .now() + 4.0)

            // This callback owns the running -> stopping transition and blocks
            // draining the deliberately held audio callback.
            source.stop()
            callbackStopReturned.signal()

            // A concurrent external stop still owns a drain, so state remains
            // `.stopping` and this preserves start()'s historical no-op behavior.
            do {
                try source.start()
            } catch {
                restartError.withLock { $0 = error }
            }
            callbackStartReturned.signal()
        }

        try source.start()
        guard audioEntered.wait(timeout: .now() + 3.0) == .success,
              videoEntered.wait(timeout: .now() + 3.0) == .success else {
            allowVideoStop.signal()
            releaseAudio.signal()
            XCTFail("synthetic A/V clip did not enter both held callbacks")
            return
        }

        allowVideoStop.signal()
        XCTAssertTrue(
            waitUntil(timeout: 2.0) {
                source.state == .stopping && source.pendingStopDrainCount == 1
            },
            "callback stop did not become the first drain owner"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            source.stop()
            externalStopReturned.signal()
        }
        XCTAssertTrue(
            waitUntil(timeout: 2.0) { source.pendingStopDrainCount == 2 },
            "external repeat stop did not register its drain ownership"
        )

        releaseAudio.signal()
        XCTAssertEqual(callbackStopReturned.wait(timeout: .now() + 2.0), .success,
                       "callback-owned stop did not finish its sibling drain")
        XCTAssertEqual(callbackStartReturned.wait(timeout: .now() + 2.0), .success,
                       "callback start attempt did not return")
        XCTAssertNil(restartError.withLock { $0 })
        XCTAssertEqual(externalStopReturned.wait(timeout: .now() + 2.0), .success,
                       "external repeat stop was trapped behind restarted playback")
        XCTAssertEqual(source.state, .idle)

        let videoCountAtReturn = videoCallbacks.withLock { $0 }
        let audioCountAtReturn = audioCallbacks.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(videoCallbacks.withLock { $0 }, videoCountAtReturn,
                       "callback-side start escaped while external stop was draining")
        XCTAssertEqual(audioCallbacks.withLock { $0 }, audioCountAtReturn,
                       "audio restarted while external stop was draining")
        source.onFrame = nil
        source.onAudio = nil
    }

    func testCallbackStopThenStartRunsOnlyTheNewGeneration() throws {
        let url = try makeClip(videoFrames: 8, fps: 2, audioSeconds: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try MovieSource(
            id: SourceID("movie.lifecycle.restart-generation"),
            fileURL: url,
            canvasSize: CanvasSize(width: 160, height: 120),
            loop: true
        )
        defer {
            source.stop()
            source.onFrame = nil
            source.videoSampleHook = nil
        }
        let callbackCount = OSAllocatedUnfairLock(initialState: 0)
        let sampleIndices = OSAllocatedUnfairLock(initialState: [Int]())
        let callbackPTS = OSAllocatedUnfairLock(initialState: [CMTime]())
        let restartError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let restartReturned = DispatchSemaphore(value: 0)
        let secondCallback = DispatchSemaphore(value: 0)

        // sampleIndex is local to each queued playback loop. After callback 1
        // restarts the source, the next decoded sample must therefore be index 0
        // from the new loop. The old global-running-bit implementation produces
        // index 1 here because the old loop observes the restarted running state
        // and starves the new loop queued behind it.
        source.videoSampleHook = { index in
            sampleIndices.withLock { $0.append(index) }
        }
        source.onFrame = { frame in
            let callback = callbackCount.withLock { value -> Int in
                value += 1
                return value
            }
            callbackPTS.withLock { $0.append(frame.pts) }
            if callback == 1 {
                source.stop()
                do {
                    try source.start()
                } catch {
                    restartError.withLock { $0 = error }
                }
                restartReturned.signal()
            } else if callback == 2 {
                source.stop()
                secondCallback.signal()
            }
        }

        try source.start()
        XCTAssertEqual(restartReturned.wait(timeout: .now() + 3.0), .success,
                       "callback stop/start did not return")
        XCTAssertNil(restartError.withLock { $0 })
        XCTAssertEqual(secondCallback.wait(timeout: .now() + 3.0), .success,
                       "the restarted generation did not emit")
        source.stop()

        let indices = sampleIndices.withLock { $0 }
        XCTAssertGreaterThanOrEqual(indices.count, 2)
        if indices.count >= 2 {
            XCTAssertEqual(Array(indices.prefix(2)), [0, 0],
                           "the old playback loop continued after callback restart")
        }
        let pts = callbackPTS.withLock { $0 }
        XCTAssertGreaterThanOrEqual(pts.count, 2)
        if pts.count >= 2 {
            let restartDelta = CMTimeSubtract(pts[1], pts[0]).seconds
            XCTAssertLessThan(restartDelta, 0.30,
                              "second callback remained on the old 0.5-second timeline")
        }
        XCTAssertEqual(source.state, .idle)
        let countAtStop = callbackCount.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(callbackCount.withLock { $0 }, countAtStop,
                       "a stale generation emitted after stop returned")
    }

    private func runProbeInChild(
        testName: String,
        environmentKey: String,
        fixtureURL: URL,
        timeoutMessage: String
    ) throws {
        // A real Dispatch lock cycle keeps xctest alive after semaphore-based
        // assertions time out. Isolate each reproducer in a filtered child so
        // this parent can convert a cycle into a bounded test failure.
        let child = Process()
        child.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
        )
        child.arguments = [
            "-XCTest",
            "PrismSuiteTests.MovieLifecycleRegressionTests/" + testName,
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[environmentKey] = "1"
        environment[Self.probeFixtureEnvironmentKey] = fixtureURL.path
        child.environment = environment

        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        let terminated = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in terminated.signal() }
        try child.run()

        guard terminated.wait(timeout: .now() + 6.0) == .success else {
            child.terminate()
            if terminated.wait(timeout: .now() + 1.0) != .success {
                kill(child.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1.0)
            }
            XCTFail(timeoutMessage)
            return
        }

        let childOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(child.terminationStatus, 0, childOutput)
    }

    private func probeFixtureURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[Self.probeFixtureEnvironmentKey] else {
            throw FixtureError.missingProbeFixture
        }
        return URL(fileURLWithPath: path)
    }

    private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return predicate() }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return true
    }

    private func makeClip(videoFrames: Int, fps: Int, audioSeconds: Double?) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_movie_generation_\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 160
        let height = 120
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw FixtureError.cannotAddVideo
        }
        writer.add(videoInput)

        let sampleRate = 44_100
        let channels = 2
        var audioInput: AVAssetWriterInput?
        if audioSeconds != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 96_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw FixtureError.cannotAddAudio
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let pool = try PixelBufferPool(width: width, height: height)
        for videoIndex in 0..<videoFrames {
            let buffer = try pool.makeBuffer()
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(
                    baseAddress,
                    Int32((videoIndex * 31) & 0xFF),
                    CVPixelBufferGetDataSize(buffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try waitUntilReady(videoInput, writer: writer, track: "video")
            let pts = CMTime(
                value: CMTimeValue(videoIndex),
                timescale: CMTimeScale(fps)
            )
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw FixtureError.writerFailed(writer.error)
            }
        }
        videoInput.markAsFinished()

        if let audioInput, let audioSeconds {
            guard let audioFormat = makeAudioFormat(
                sampleRate: sampleRate,
                channels: channels
            ) else {
                throw FixtureError.audioFormat
            }
            let totalAudioFrames = Int(audioSeconds * Double(sampleRate))
            var audioStartFrame = 0
            while audioStartFrame < totalAudioFrames {
                let frameCount = min(1_024, totalAudioFrames - audioStartFrame)
                guard let sample = makeSilentAudioSample(
                    format: audioFormat,
                    sampleRate: sampleRate,
                    channels: channels,
                    frameCount: frameCount,
                    startFrame: audioStartFrame
                ) else {
                    throw FixtureError.audioSample
                }
                try waitUntilReady(audioInput, writer: writer, track: "audio")
                guard audioInput.append(sample) else {
                    throw FixtureError.writerFailed(writer.error)
                }
                audioStartFrame += frameCount
            }
            audioInput.markAsFinished()
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 10.0) == .success,
              writer.status == .completed else {
            throw FixtureError.writerFailed(writer.error)
        }
        return url
    }

    private func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        track: String
    ) throws {
        let deadline = Date().addingTimeInterval(5.0)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled {
                throw FixtureError.writerFailed(writer.error)
            }
            guard Date() < deadline else {
                throw FixtureError.inputReadinessTimedOut(track)
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func makeAudioFormat(sampleRate: Int, channels: Int) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private func makeSilentAudioSample(
        format: CMAudioFormatDescription,
        sampleRate: Int,
        channels: Int,
        frameCount: Int,
        startFrame: Int
    ) -> CMSampleBuffer? {
        let byteCount = frameCount * channels * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        let silence = [UInt8](repeating: 0, count: byteCount)
        guard silence.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }) == noErr else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = channels * MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    private enum FixtureError: Error {
        case cannotAddVideo
        case cannotAddAudio
        case audioFormat
        case audioSample
        case inputReadinessTimedOut(String)
        case missingProbeFixture
        case writerFailed(Error?)
    }
}
