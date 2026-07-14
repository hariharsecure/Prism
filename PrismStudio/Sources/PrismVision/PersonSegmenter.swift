import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import Vision

/// Vision-based person-matte producer, running **off the render path**
/// (DESIGN.md §3.5: "the render loop never waits on ML").
///
/// `submit(_:)` is non-blocking and safe to call from a capture callback or
/// the render thread: it takes a lock for a few loads/stores and (at most)
/// enqueues one async block. Segmentation runs on a private serial queue;
/// while a request is in flight newer frames replace the pending slot
/// (**latest wins**) and a rate limiter caps Vision work at `targetRate` Hz
/// (default 15 — the shader keeps sampling the last matte in between).
///
/// Results arrive via `onMatte` on the segmenter's serial queue, carrying the
/// source frame's PTS + source id so consumers can pair matte and frame.
///
/// Design notes:
/// - `VNGeneratePersonSegmentationRequest` produces the single combined
///   person matte we want in one shot, natively in `OneComponent8`.
///   `VNGeneratePersonInstanceMaskRequest` was considered and rejected for
///   v1: it returns per-instance float mattes that must be scaled/merged
///   through CoreImage per instance — extra passes for no benefit while the
///   deliverable is one combined matte. Revisit for per-person effects.
/// - Vision's output buffers are Vision-pool allocations; if one ever arrives
///   without an IOSurface it is copied (~64 KB, at ≤ targetRate Hz, off the
///   render path) into a `PixelBufferPool` buffer so downstream GPU wrapping
///   stays zero-copy. IOSurface-backed mattes pass through untouched.
///
/// Thread-safety: `submit`/`segmentNow`/`stats` are safe from any thread.
/// Set `onMatte`/`onError` before submitting frames.
public final class PersonSegmenter: @unchecked Sendable {
    /// Maps 1:1 onto `VNGeneratePersonSegmentationRequest.QualityLevel`.
    public enum Quality: Sendable {
        /// Lowest latency, coarsest matte.
        case fast
        /// The live-video default.
        case balanced
        /// Highest quality, slowest — stills / offline.
        case accurate

        var vnLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .fast: return .fast
            case .balanced: return .balanced
            case .accurate: return .accurate
            }
        }
    }

    /// Pipeline counters (all monotonic).
    public struct Stats: Sendable {
        /// Frames handed to `submit`.
        public let submitted: Int
        /// Frames dropped by the rate limiter.
        public let rateLimited: Int
        /// Frames that were replaced in the pending slot before Vision ran (latest-wins).
        public let superseded: Int
        /// Vision runs completed (with or without a detection).
        public let processed: Int
        /// Vision runs that produced a matte.
        public let mattes: Int
        /// Vision runs that threw.
        public let errors: Int
    }

    /// Delivered on the segmenter's serial queue for every frame Vision found
    /// a person in. No callback fires for a clean no-detection.
    public var onMatte: ((SegmentationMatte) -> Void)?
    /// Delivered on the segmenter's serial queue when a Vision run throws.
    public var onError: ((Error) -> Void)?

    public let quality: Quality
    /// Target segmentation rate in Hz; frames arriving faster are dropped.
    public let targetRate: Double

    private let queue = DispatchQueue(label: "studio.prism.vision.segmenter", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: VideoFrame?
    private var busy = false
    private var lastAcceptedSeconds = -Double.infinity
    private var submittedCount = 0
    private var rateLimitedCount = 0
    private var supersededCount = 0
    private var processedCount = 0
    private var matteCount = 0
    private var errorCount = 0
    private var copyPool: PixelBufferPool?
    private let logger = EngineLog.logger("vision")

    public init(quality: Quality = .balanced, targetRate: Double = 15) {
        self.quality = quality
        self.targetRate = max(targetRate, 0.1)
    }

    /// Non-blocking. Rate-limits on the frame's house-time PTS; if a request
    /// is already in flight the frame parks in the single pending slot,
    /// replacing (dropping) any frame already parked there.
    public func submit(_ frame: VideoFrame) {
        let seconds = frame.pts.seconds.isFinite ? frame.pts.seconds : HouseClock.nowSeconds()
        lock.lock()
        submittedCount += 1
        if seconds - lastAcceptedSeconds < 1.0 / targetRate {
            rateLimitedCount += 1
            lock.unlock()
            return
        }
        lastAcceptedSeconds = seconds
        if pending != nil { supersededCount += 1 }
        pending = frame
        let shouldStart = !busy
        if shouldStart { busy = true }
        lock.unlock()
        if shouldStart {
            queue.async { [weak self] in self?.drain() }
        }
    }

    /// True when no request is running and nothing is parked (test/teardown aid).
    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !busy && pending == nil
    }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(submitted: submittedCount, rateLimited: rateLimitedCount,
                     superseded: supersededCount, processed: processedCount,
                     mattes: matteCount, errors: errorCount)
    }

    /// Synchronous one-shot segmentation — bypasses the queue and the rate
    /// limiter. For tests and offline/still use, NOT the live path.
    /// Returns `nil` on a clean no-detection.
    public func segmentNow(_ frame: VideoFrame) throws -> SegmentationMatte? {
        try performSegmentation(frame)
    }

    // MARK: - Worker

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pending else {
                busy = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            do {
                let matte = try performSegmentation(frame)
                lock.lock()
                processedCount += 1
                if matte != nil { matteCount += 1 }
                lock.unlock()
                if let matte { onMatte?(matte) }
            } catch {
                lock.lock()
                processedCount += 1
                errorCount += 1
                lock.unlock()
                logger.error("segmentation failed for \(frame.source): \(error)")
                onError?(error)
            }
        }
    }

    private func performSegmentation(_ frame: VideoFrame) throws -> SegmentationMatte? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.vnLevel
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw VisionError.segmentationFailed(underlying: error)
        }
        guard let observation = request.results?.first else { return nil }
        let buffer = try normalizedMatteBuffer(observation.pixelBuffer)
        return SegmentationMatte(pixelBuffer: buffer, pts: frame.pts, source: frame.source)
    }

    /// Guarantees the matte handed downstream is OneComponent8 and
    /// IOSurface-backed (so `CVMetalTextureCache` wraps stay zero-copy).
    private func normalizedMatteBuffer(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 else {
            throw VisionError.unsupportedMatteFormat(format)
        }
        if CVPixelBufferGetIOSurface(buffer) != nil { return buffer }

        // Rare fallback path: copy into a pooled IOSurface buffer. This locks
        // base addresses — allowed here because segmentation is off the
        // render path and rate-limited (AGENTS.md #6 targets the hot path).
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if copyPool == nil || copyPool!.width != width || copyPool!.height != height {
            do {
                copyPool = try PixelBufferPool(width: width, height: height,
                                               pixelFormat: kCVPixelFormatType_OneComponent8,
                                               minimumBufferCount: 3)
            } catch { throw VisionError.outputBufferFailed(underlying: error) }
        }
        let copy: CVPixelBuffer
        do { copy = try copyPool!.makeBuffer() }
        catch { throw VisionError.outputBufferFailed(underlying: error) }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(buffer),
              let dstBase = CVPixelBufferGetBaseAddress(copy) else {
            throw VisionError.matteCopyFailed
        }
        let srcRow = CVPixelBufferGetBytesPerRow(buffer)
        let dstRow = CVPixelBufferGetBytesPerRow(copy)
        for row in 0..<height {
            memcpy(dstBase + row * dstRow, srcBase + row * srcRow, min(srcRow, dstRow))
        }
        logger.debug("matte lacked an IOSurface — copied \(width)x\(height) into pool")
        return copy
    }
}
