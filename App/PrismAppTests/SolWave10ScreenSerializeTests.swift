import AVFoundation
import CoreMedia
import CoreVideo
import os
import XCTest

import PrismAudio
import PrismCore
import PrismScreen
@testable import Prism

/// sol #10 (gpt-5.6-sol, TSan-confirmed) — the live screen-source HDR hot-swap.
///
/// DECISION (June, lead): SERIALIZE the reconfigure — fully quiesce the OLD capture's use of
/// the shared `SourceEffectGPU` (`effectPipelines[id]`) and `MixerChannel` BEFORE the NEW
/// generation ingests into them, so those non-thread-safe resources are never used
/// concurrently; a brief reconfigure hitch is accepted (see `commitScreenReplacement`).
///
/// Each test REPRODUCES the pre-fix defect via a negative-control seam (red when the fix is
/// neutralized), then proves the fix. The concurrency findings (#2 SourceEffectGPU, #3
/// MixerChannel) are proven with a forced-overlap probe + an instrumented concurrency counter
/// (`ScreenSwapConcurrencyProbe`) that measures the MAX simultaneous use of each shared
/// resource by the two generations: a serialized reconfigure never exceeds 1; the pre-fix
/// eager-armed overlap reaches 2. Thread Sanitizer is not runnable in this xcodebuild harness,
/// so the deterministic concurrency counter is the instrument (per the task's explicit fallback).
@MainActor
final class SolWave10ScreenSerializeTests: XCTestCase {

    // MARK: - Fixtures

    private static func makeBGRAFrame(source: SourceID) throws -> VideoFrame {
        let pool = try PixelBufferPool(width: 16, height: 16, pixelFormat: kCVPixelFormatType_32BGRA)
        return VideoFrame(pixelBuffer: try pool.makeBuffer(), pts: HouseClock.now(), source: source)
    }

    /// A 256-frame silent mono audio packet — mirrors a real SCK app-audio buffer (the pre-fix
    /// ungated leak advanced the mixer channel by exactly one such packet after teardown).
    private static func makeAudioPacket(source: SourceID, frames: Int = 256, sampleRate: Double = 48_000) throws -> AudioPacket {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else {
            throw XCTSkip("could not build audio format")
        }
        let dataSize = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: dataSize, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: dataSize,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: dataSize) == noErr else {
            throw XCTSkip("could not build audio block buffer")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sb) == noErr, let sb else {
            throw XCTSkip("could not build audio sample buffer")
        }
        return AudioPacket(sampleBuffer: sb, source: source)
    }

    private func registerScreen(_ engine: AppEngine, id: String, captureAudio: Bool) throws -> (SourceID, ScreenSource) {
        let desc = SourceDescriptor(kind: .display, id: id, name: "Display")
        let src = try ScreenSource(descriptor: desc,
                                   configuration: AppEngine.screenCaptureConfiguration(captureAudio: captureAudio, hdr: false))
        engine.integrationDebugRegisterScreenSource(src, descriptor: desc)
        return (SourceID(id), src)
    }

    // MARK: - #1 the ORIGINAL screen callbacks must be gated (frame AND audio)

    /// #1 HIGH — the original/active screen source's frame + audio callbacks must go dead the
    /// instant it is retired. Pre-fix they were ungated: `removeSource` retired nothing the
    /// closure checked, so an in-flight capture callback posted a frame (mailbox +1) and
    /// advanced the shared/detached mixer channel (+256) after teardown.
    func testOriginalScreenFrameAndAudioDieAfterRemove() throws {
        func run(gated: Bool) throws -> (liveOK: Bool, frameLeaked: Bool, audioLeaked: Bool) {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            AppEngine._test_skipOriginalScreenGate = !gated
            defer { AppEngine._test_skipOriginalScreenGate = false; AppEngine._test_clearScreenSwapProbes() }

            let (id, source) = try registerScreen(engine, id: "display:1", captureAudio: true)
            let probe = AppEngine._test_installScreenSwapProbe(for: id)
            let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: id))
            let frame = try Self.makeBGRAFrame(source: id)
            let packet = try Self.makeAudioPacket(source: id)

            // Baseline: a LIVE original screen source delivers frames + audio.
            source.onFrame?(frame)
            source.onAudio?(packet)
            let liveVideo = probe.videoDeliveries, liveAudio = probe.audioDeliveries
            let liveMailbox = mailbox.stats.delivered
            let liveOK = liveVideo >= 1 && liveAudio >= 1 && liveMailbox >= 1

            // Retire the source, then drive its (possibly in-flight) callbacks again.
            engine.removeSource(id)
            let mailboxAfterRemove = mailbox.stats.delivered
            source.onFrame?(frame)
            source.onAudio?(packet)
            let frameLeaked = probe.videoDeliveries > liveVideo || mailbox.stats.delivered > mailboxAfterRemove
            let audioLeaked = probe.audioDeliveries > liveAudio
            return (liveOK, frameLeaked, audioLeaked)
        }

        // FIX: gated — nothing is delivered after removeSource.
        let fixed = try run(gated: true)
        XCTAssertTrue(fixed.liveOK, "baseline: a live original screen source must deliver a frame + audio")
        XCTAssertFalse(fixed.frameLeaked, "#1: the original screen FRAME callback posted after removeSource")
        XCTAssertFalse(fixed.audioLeaked, "#1: the original screen AUDIO callback advanced the channel after removeSource")

        // NEGATIVE CONTROL: ungated — the pre-fix closures leak a frame and/or audio packet.
        let neg = try run(gated: false)
        XCTAssertTrue(neg.frameLeaked || neg.audioLeaked,
                      "negative control vacuous: the ungated original callbacks delivered nothing after removeSource")
    }

    /// #1 — same guarantee across `shutdown()` (the source lives in `activeSources`, but its
    /// captured mailbox/channel outlive the teardown; a late capture callback must post nothing).
    func testOriginalScreenFrameDiesAfterShutdown() async throws {
        func frameLeakedAfterShutdown(gated: Bool) async throws -> Bool {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            AppEngine._test_skipOriginalScreenGate = !gated
            defer { AppEngine._test_skipOriginalScreenGate = false; AppEngine._test_clearScreenSwapProbes() }

            let (id, source) = try registerScreen(engine, id: "display:2", captureAudio: false)
            _ = AppEngine._test_installScreenSwapProbe(for: id)
            let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: id))
            let frame = try Self.makeBGRAFrame(source: id)

            await engine.shutdown()
            let before = mailbox.stats.delivered
            source.onFrame?(frame)
            return mailbox.stats.delivered > before
        }
        let fixed = try await frameLeakedAfterShutdown(gated: true)
        XCTAssertFalse(fixed, "#1: the original screen FRAME callback posted after shutdown")
        let neg = try await frameLeakedAfterShutdown(gated: false)
        XCTAssertTrue(neg, "negative control vacuous: the ungated original callback delivered nothing after shutdown")
    }

    /// #1 — the FIRST HDR replacement's commit retires the original. After commit the original
    /// source's captured callback must be dead (the commit retires its gate before arming the
    /// successor). The pipeline/mailbox are REUSED by the successor (not torn down), so this
    /// isolates the gate — not teardown — as the thing that silences the original.
    func testOriginalScreenFrameDiesAfterFirstHDRCommit() throws {
        func frameLeakedAfterCommit(gated: Bool) throws -> Bool {
            let engine = AppEngine()
            guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
            AppEngine._test_skipOriginalScreenGate = !gated
            AppEngine._test_skipScreenSourceStart = true
            AppEngine._test_simulatedScreenStartOutcome = .success   // commit the HDR replacement
            defer {
                AppEngine._test_skipOriginalScreenGate = false
                AppEngine._test_skipScreenSourceStart = false
                AppEngine._test_simulatedScreenStartOutcome = .none
                AppEngine._test_clearScreenSwapProbes()
            }
            let (id, original) = try registerScreen(engine, id: "display:3", captureAudio: false)
            _ = AppEngine._test_installScreenSwapProbe(for: id)
            let mailbox = try XCTUnwrap(engine._test_screenMailbox(for: id))
            let frame = try Self.makeBGRAFrame(source: id)

            engine.setHDREnabled(true)
            guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
            // The original was replaced; its ref is retired. Driving it must post nothing.
            let before = mailbox.stats.delivered
            original.onFrame?(frame)
            return mailbox.stats.delivered > before
        }
        XCTAssertFalse(try frameLeakedAfterCommit(gated: true),
                       "#1: the replaced original screen source still posted after the HDR commit")
        XCTAssertTrue(try frameLeakedAfterCommit(gated: false),
                      "negative control vacuous: the ungated replaced original delivered nothing after commit")
    }

    // MARK: - #2 / #3 the shared SourceEffectGPU + MixerChannel are never used concurrently

    /// Forced-overlap probe: pin the OLD generation's delivery body INSIDE the shared resource
    /// (holding its gate lock), then drive the NEW generation. Returns the max simultaneous
    /// use of the shared resource. `drive` selects the frame (SourceEffectGPU, #2) or audio
    /// (MixerChannel, #3) callback; `concurrency` reads the matching counter.
    private func maxSharedConcurrency(eagerArm: Bool,
                                      captureAudio: Bool,
                                      drive: @escaping (ScreenSource, SourceID) -> Void,
                                      concurrency: (ScreenSwapConcurrencyProbe) -> Int) throws -> Int {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_armReplacementGateEagerly = eagerArm
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .none      // replacement stays PENDING (no commit)
        defer {
            AppEngine._test_armReplacementGateEagerly = false
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_screenDeliveryInside = nil
            AppEngine._test_clearScreenSwapProbes()
        }
        let (id, _) = try registerScreen(engine, id: "display:4", captureAudio: captureAudio)
        let probe = AppEngine._test_installScreenSwapProbe(for: id)
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let old = try XCTUnwrap(engine._test_activeScreenSource(for: id))
        let pending = try XCTUnwrap(engine._test_pendingScreenReplacementHandles(for: id)).source

        let inside = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let hookCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        AppEngine._test_screenDeliveryInside = {
            let n = hookCount.withLock { $0 += 1; return $0 }
            if n == 1 { inside.signal(); release.wait() }   // pin the FIRST (old) body inside the shared resource
        }

        // Thread A pins the OLD generation inside the shared pipeline/channel.
        let qA = DispatchQueue(label: "prism.test.serialize.A")
        qA.async { drive(old, id) }
        guard inside.wait(timeout: .now() + 5) == .success else {
            release.signal(); throw XCTSkip("old delivery never entered the shared resource")
        }
        // Thread B drives the NEW generation WHILE the old is pinned inside.
        let doneB = DispatchSemaphore(value: 0)
        DispatchQueue(label: "prism.test.serialize.B").async { drive(pending, id); doneB.signal() }
        _ = doneB.wait(timeout: .now() + 5)   // fixed: B no-ops instantly; neg: B runs to completion
        let observed = concurrency(probe)     // read while A is still pinned
        release.signal()                      // let A finish
        let drained = DispatchSemaphore(value: 0)
        qA.async { drained.signal() }
        _ = drained.wait(timeout: .now() + 5)
        return observed
    }

    /// #2 HIGH — the hot-swap must not run the OLD and NEW ScreenSources over the SAME
    /// non-thread-safe `SourceEffectGPU` pipeline concurrently.
    func testSerializedReconfigureNeverOverlapsSharedPipeline() throws {
        let drive: (ScreenSource, SourceID) -> Void = { source, id in
            let frame = try? Self.makeBGRAFrame(source: id)
            if let frame { source.onFrame?(frame) }
        }
        XCTAssertEqual(try maxSharedConcurrency(eagerArm: false, captureAudio: false,
                                                drive: drive, concurrency: { $0.maxVideoConcurrency }), 1,
                       "#2: a serialized reconfigure let both generations use the shared SourceEffectGPU at once")
        XCTAssertEqual(try maxSharedConcurrency(eagerArm: true, captureAudio: false,
                                                drive: drive, concurrency: { $0.maxVideoConcurrency }), 2,
                       "negative control vacuous: the eager-armed overlap did not reach concurrency 2 on the pipeline")
    }

    /// #3 HIGH — the hot-swap must not ingest the OLD and NEW generations into the SAME
    /// single-writer `MixerChannel` concurrently.
    func testSerializedReconfigureNeverOverlapsMixerChannel() throws {
        let drive: (ScreenSource, SourceID) -> Void = { source, id in
            let packet = try? Self.makeAudioPacket(source: id)
            if let packet { source.onAudio?(packet) }
        }
        XCTAssertEqual(try maxSharedConcurrency(eagerArm: false, captureAudio: true,
                                                drive: drive, concurrency: { $0.maxAudioConcurrency }), 1,
                       "#3: a serialized reconfigure let both generations ingest the shared MixerChannel at once")
        XCTAssertEqual(try maxSharedConcurrency(eagerArm: true, captureAudio: true,
                                                drive: drive, concurrency: { $0.maxAudioConcurrency }), 2,
                       "negative control vacuous: the eager-armed overlap did not reach concurrency 2 on the channel")
    }

    /// The deferred-arm gate must not permanently silence the successor: after commit the new
    /// source's callback delivers (the SERIALIZE arm at commit re-enables ingest). Guards
    /// against a fix that closes the race by simply never arming the replacement.
    func testCommittedReplacementDeliversAfterArm() throws {
        let engine = AppEngine()
        guard engine.renderLoop != nil else { throw XCTSkip("no Metal device") }
        AppEngine._test_skipScreenSourceStart = true
        AppEngine._test_simulatedScreenStartOutcome = .success
        defer {
            AppEngine._test_skipScreenSourceStart = false
            AppEngine._test_simulatedScreenStartOutcome = .none
            AppEngine._test_clearScreenSwapProbes()
        }
        let (id, _) = try registerScreen(engine, id: "display:5", captureAudio: false)
        let probe = AppEngine._test_installScreenSwapProbe(for: id)
        engine.setHDREnabled(true)
        guard engine.hdrEnabled else { throw XCTSkip("HDR toggle did not take") }
        let committed = try XCTUnwrap(engine._test_activeScreenSource(for: id))
        let before = probe.videoDeliveries
        committed.onFrame?(try Self.makeBGRAFrame(source: id))
        XCTAssertGreaterThan(probe.videoDeliveries, before,
                             "the committed (armed) replacement must deliver frames after the SERIALIZE handoff")
    }
}
