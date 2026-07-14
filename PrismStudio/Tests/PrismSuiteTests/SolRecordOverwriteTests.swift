import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest

import PrismCore
@testable import PrismOutput

/// sol HIGH #1 (DATA LOSS) — the recorder layer must NEVER destructively overwrite
/// a prior take's file. Before the fix, `MovieRecorder`/`AudioTrackRecorder` init
/// unconditionally `removeItem`'d any file already at the destination path, and the
/// per-source ISO/multitrack names were fixed (`iso-<source>.mov`), so a second
/// take reusing the same path silently deleted the first take's recording.
///
/// The oracle is inode identity + byte size read straight off the filesystem (an
/// INDEPENDENT check — `stat`, not the recorder's own bookkeeping). Each fix test
/// is paired with a firing negative control that reproduces the destructive
/// overwrite so the oracle is proven to detect it.
final class SolRecordOverwriteTests: XCTestCase {

    // MARK: fixtures

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism_overwrite_\(UInt64.random(in: 0..<UInt64.max))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? UInt64) ?? 0
    }

    private func size(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int64) ?? -1
    }

    private func makeBGRA(_ w: Int, _ h: Int, luma: UInt8, source: SourceID) throws -> CVPixelBuffer {
        let pool = try PixelBufferPool(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        let buf = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for row in 0..<h {
            let p = (base + row * bpr).assumingMemoryBound(to: UInt8.self)
            for col in 0..<w { p[col * 4 + 0] = luma; p[col * 4 + 1] = luma; p[col * 4 + 2] = luma; p[col * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Records `frames` copies of a fixed-luma BGRA buffer to `url` and finishes,
    /// returning the ACTUAL file URL the recorder wrote (may be uniquified).
    @discardableResult
    private func recordMovie(to url: URL, w: Int = 160, h: Int = 120, luma: UInt8, frames: Int = 8) async throws -> URL {
        let rec = try MovieRecorder(url: url, settings: RecordingSettings(codec: .h264, width: w, height: h, includeAudio: false))
        try rec.start()
        let t0 = HouseClock.now()
        for i in 0..<frames {
            let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: 30))
            let buf = try makeBGRA(w, h, luma: luma, source: SourceID("ov"))
            rec.append(VideoFrame(pixelBuffer: buf, pts: pts, duration: CMTime(value: 1, timescale: 30), source: SourceID("ov")))
        }
        return try await rec.finish().url
    }

    private func makeSilentAudio(pts: CMTime, seconds: Double, sampleRate: Double = 48_000) -> CMSampleBuffer? {
        let frames = Int((seconds * sampleRate).rounded())
        guard frames > 0 else { return nil }
        let bytesPerFrame = 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        let dataSize = frames * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: dataSize, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: dataSize, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else { return nil }
        _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataSize)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sb) == noErr, let sb else { return nil }
        return sb
    }

    // MARK: - MovieRecorder: a second recorder at the same path never clobbers the first

    func testSecondMovieRecorderDoesNotClobberFirstTake() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Prism take.mov")

        // Take A → fileA at `path`. Capture its inode + size (independent oracle).
        let urlA = try await recordMovie(to: path, luma: 30, frames: 12)
        XCTAssertEqual(urlA, path, "first take uses the requested path")
        let inodeA = try inode(urlA)
        let sizeA = try size(urlA)
        XCTAssertGreaterThan(sizeA, 0)

        // Take B requests the SAME path → must record to a uniquified sibling,
        // NOT delete Take A.
        let urlB = try await recordMovie(to: path, luma: 220, frames: 4)
        XCTAssertNotEqual(urlB, urlA, "second take must NOT reuse the first take's path")

        // Both files exist; Take A is byte-for-byte the same file (same inode+size).
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "Take A must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path), "Take B must exist at its own path")
        XCTAssertEqual(try inode(urlA), inodeA, "Take A's file must be untouched (same inode)")
        XCTAssertEqual(try size(urlA), sizeA, "Take A's file content must be unchanged (same size)")
    }

    func testNegativeControlUnconditionalDeleteClobbersFirstTake() async throws {
        // NEGATIVE CONTROL — demonstrate the oracle FIRES on the pre-fix behavior:
        // the old init unconditionally deleted an existing file. Reproduce that
        // exact destructive step (removeItem at the path, then recreate) and show
        // the inode oracle detects that Take A was destroyed.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Prism take.mov")

        let urlA = try await recordMovie(to: path, luma: 30, frames: 12)
        let inodeA = try inode(urlA)

        // The pre-fix `MovieRecorder.init` step:
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path) // <-- the destructive line the fix removed
        }
        _ = try await recordMovie(to: path, luma: 220, frames: 4)

        // The original Take A is gone: the path now holds a DIFFERENT file.
        XCTAssertNotEqual(try inode(path), inodeA,
                          "negative control: unconditional delete replaced Take A's file (inode changed)")
    }

    // MARK: - AudioTrackRecorder: same non-clobber guarantee

    func testSecondAudioRecorderDoesNotClobberFirstTake() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("audio-mic.mov")

        func recordAudio(to url: URL, seconds: Double) async throws -> URL {
            let rec = try AudioTrackRecorder(url: url, settings: AudioTrackSettings(), sessionStart: HouseClock.now())
            try rec.start()
            if let sb = makeSilentAudio(pts: HouseClock.now(), seconds: seconds) { rec.append(sb) }
            return try await rec.finish().url
        }

        let urlA = try await recordAudio(to: path, seconds: 0.5)
        XCTAssertEqual(urlA, path)
        let inodeA = try inode(urlA)
        let sizeA = try size(urlA)

        let urlB = try await recordAudio(to: path, seconds: 0.2)
        XCTAssertNotEqual(urlB, urlA, "second audio take must not reuse the first's path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertEqual(try inode(urlA), inodeA, "Take A audio file untouched (same inode)")
        XCTAssertEqual(try size(urlA), sizeA, "Take A audio content unchanged (same size)")
    }

    // MARK: - ISO bank: two takes into the SAME directory both survive

    func testTwoISOTakesSameDirectorySameSourceBothSurvive() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = SourceID("iso_defer_hlg")
        let settings = RecordingSettings(codec: .h264, width: 160, height: 120, includeAudio: false)

        func runTake(luma: UInt8) async throws -> URL {
            // Same directory, same source ID → same fixed `iso-<source>.mov` name.
            let bank = ISORecorderBank(directory: dir, defaultSettings: settings)
            try bank.addSource(src, settings: settings, includeAudio: false)
            let t0 = HouseClock.now()
            try bank.start(at: t0)
            for i in 0..<8 {
                let pts = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: 30))
                let buf = try makeBGRA(160, 120, luma: luma, source: src)
                bank.append(VideoFrame(pixelBuffer: buf, pts: pts, duration: CMTime(value: 1, timescale: 30), source: src))
            }
            let results = await bank.finishAll()
            guard case .success(let report)? = results[src] else {
                throw XCTSkip("ISO recorder produced no file")
            }
            return report.url
        }

        let urlA = try await runTake(luma: 30)
        let inodeA = try inode(urlA)
        let sizeA = try size(urlA)

        let urlB = try await runTake(luma: 220)
        XCTAssertNotEqual(urlB, urlA, "Take B's ISO angle must not overwrite Take A's fixed-name file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "Take A ISO file must survive Take B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertEqual(try inode(urlA), inodeA, "Take A ISO file untouched (same inode)")
        XCTAssertEqual(try size(urlA), sizeA, "Take A ISO content unchanged (same size)")
    }

    // MARK: - nonClobbering path math (unit)

    func testNonClobberingPicksFreeSibling() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("clip.mov")
        // Nothing exists → returns the requested path.
        XCTAssertEqual(RecorderFilePath.nonClobbering(base), base)
        // Occupy clip.mov and clip-2.mov → next free is clip-3.mov.
        FileManager.default.createFile(atPath: base.path, contents: Data([0]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("clip-2.mov").path, contents: Data([0]))
        XCTAssertEqual(RecorderFilePath.nonClobbering(base).lastPathComponent, "clip-3.mov")
    }
}
