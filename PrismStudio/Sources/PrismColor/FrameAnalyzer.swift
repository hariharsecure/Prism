import CoreVideo
import Foundation
import Metal
import PrismCore

/// Downsampled per-frame statistics, measured on **gamma-encoded BT.709**
/// values (the same space `ColorGrade`'s wheels operate in — stated so the
/// AutoColor math can convert knowingly).
public struct FrameStats: Sendable, Codable, Equatable {
    /// Per-channel means, 0…1.
    public let meanR: Double
    public let meanG: Double
    public let meanB: Double
    /// Per-channel standard deviations, 0…1.
    public let stdDevR: Double
    public let stdDevG: Double
    public let stdDevB: Double
    /// Geometric mean of BT.709 luma (`2^mean(log2 luma)`), luma floored at
    /// 1/8192 so black pixels don't drive it to −∞.
    public let logAverageLuma: Double
    /// Fraction of samples with every channel < 0.02 (crushed shadows).
    public let nearBlackFraction: Double
    /// Fraction of samples with any channel > 0.98 (clipped highlights).
    public let nearWhiteFraction: Double
    /// 64-bin luma histogram, normalized to sum to 1.
    public let lumaHistogram: [Double]
    /// Number of grid samples the stats were computed from.
    public let sampleCount: Int

    public static let histogramBins = 64

    public init(meanR: Double, meanG: Double, meanB: Double,
                stdDevR: Double, stdDevG: Double, stdDevB: Double,
                logAverageLuma: Double,
                nearBlackFraction: Double, nearWhiteFraction: Double,
                lumaHistogram: [Double], sampleCount: Int) {
        self.meanR = meanR; self.meanG = meanG; self.meanB = meanB
        self.stdDevR = stdDevR; self.stdDevG = stdDevG; self.stdDevB = stdDevB
        self.logAverageLuma = logAverageLuma
        self.nearBlackFraction = nearBlackFraction
        self.nearWhiteFraction = nearWhiteFraction
        self.lumaHistogram = lumaHistogram
        self.sampleCount = sampleCount
    }

    /// Luma value at percentile `p` (0…1), estimated from the histogram
    /// (bin-center resolution, 1/64).
    public func lumaPercentile(_ p: Double) -> Double {
        guard sampleCount > 0, !lumaHistogram.isEmpty else { return 0 }
        let target = min(max(p, 0), 1)
        var cumulative = 0.0
        for (i, weight) in lumaHistogram.enumerated() {
            cumulative += weight
            if cumulative >= target {
                return (Double(i) + 0.5) / Double(lumaHistogram.count)
            }
        }
        return 1
    }
}

/// GPU frame analysis for AutoColor / ShotMatch / scopes (DESIGN.md §3.7).
///
/// One compute pass samples the source on a small fixed grid (default
/// 96×54 ≈ 5.2k taps — a downsample by construction, never a full-res read)
/// and accumulates fixed-point sums + a 64-bin luma histogram into a shared
/// `MTLBuffer` via relaxed atomics; the CPU reads back 296 bytes.
///
/// Intended cadence: **a few Hz on demand, never per frame** — call it from
/// the analysis tick, not the render loop.
public final class FrameAnalyzer {
    /// Word offsets in the accumulator buffer — must match `accumulate_stats`
    /// in ColorShaders.
    private enum Layout {
        static let sumR = 0, sumG = 1, sumB = 2
        static let sumR2 = 3, sumG2 = 4, sumB2 = 5
        static let sumLogLuma = 6
        static let nearBlack = 7, nearWhite = 8, count = 9
        static let histogram = 10
        static let totalWords = 10 + FrameStats.histogramBins
        /// Fixed-point scale for value/value² sums.
        static let valueScale = 4096.0
        /// log2 luma is stored as (log2 + 16) × 256.
        static let logOffset = 16.0, logScale = 256.0
    }

    public let device: MTLDevice
    private let engine: MetalColorEngine
    private let statsBGRA: MTLComputePipelineState
    private let statsYUV: MTLComputePipelineState
    private let statsBuffer: MTLBuffer
    private let gridWidth: Int
    private let gridHeight: Int

    /// Mirrors the MSL `StatsUniforms` struct.
    /// `yuvTags`: YUV only — x = matrix (0/1/2), y = chromaOffsetX (siting).
    private struct StatsUniforms { var grid: SIMD4<Float>; var yuvTags: SIMD4<Float> }

    /// - Parameter sampleGrid: analysis grid size; the default (96×54) keeps
    ///   the pass trivially cheap while statistically stable.
    public init(device: MTLDevice, sampleGrid: (width: Int, height: Int) = (96, 54)) throws {
        precondition(sampleGrid.width > 0 && sampleGrid.height > 0)
        self.device = device
        self.engine = try MetalColorEngine(device: device, label: "stats")
        self.statsBGRA = try engine.pipeline("prism_stats_bgra")
        self.statsYUV = try engine.pipeline("prism_stats_yuv")
        self.gridWidth = sampleGrid.width
        self.gridHeight = sampleGrid.height
        guard let buffer = device.makeBuffer(length: Layout.totalWords * 4,
                                             options: .storageModeShared) else {
            throw ColorError.commandCreationFailed
        }
        buffer.label = "prism.color.stats"
        self.statsBuffer = buffer
    }

    /// Analyze one frame (synchronous GPU round-trip, ~single-digit µs of
    /// GPU work). BGRA8 and 420v/420f inputs are sampled zero-copy.
    public func analyze(_ frame: VideoFrame) throws -> FrameStats {
        var retained: [CVMetalTexture] = []
        // FrameAnalyzer writes to an atomic accumulator, not a pixel buffer, so the
        // output stays format-agnostic; only the 10-bit DECODE (float flag) matters.
        let (input, _) = try engine.inputTextures(for: frame, retained: &retained)

        memset(statsBuffer.contents(), 0, Layout.totalWords * 4)

        var uniforms = StatsUniforms(grid: SIMD4(Float(gridWidth), Float(gridHeight), 0, 0),
                                     yuvTags: .zero)
        let commandBuffer = try engine.makeCommandBuffer(label: "prism.color.stats")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ColorError.commandCreationFailed
        }
        encoder.label = "prism.color.stats.pass"
        let pipeline: MTLComputePipelineState
        switch input {
        case .bgra(let tex):
            pipeline = statsBGRA
            encoder.setTexture(tex, index: 0)
        case .yuv(let luma, let chroma, let fullRange, let tenBit):
            pipeline = statsYUV
            uniforms.grid.z = fullRange ? 1 : 0
            // sol #3 finding 1: analyze in the source's tagged matrix + siting so the
            // stats (AutoColor/ShotMatch/scopes) reflect the true decoded color.
            // wave-5b: yuvTags.z = tenBit.
            uniforms.yuvTags = SIMD4(Float(YCbCrTags.matrixCode(for: frame.pixelBuffer)),
                                     YCbCrTags.chromaOffsetX(for: frame.pixelBuffer, lumaWidth: frame.width),
                                     tenBit ? 1 : 0, 0)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
        }
        encoder.setBuffer(statsBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<StatsUniforms>.stride, index: 1)
        engine.dispatch(encoder, pipeline: pipeline, width: gridWidth, height: gridHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        // HIGH-4 / F13: a failed pass leaves undefined stats — throw, never report.
        if let err = ColorError.executionError(status: commandBuffer.status, error: commandBuffer.error) { throw err }

        return Self.decode(statsBuffer)
    }

    private static func decode(_ buffer: MTLBuffer) -> FrameStats {
        let words = buffer.contents().assumingMemoryBound(to: UInt32.self)
        let n = Double(words[Layout.count])
        guard n > 0 else {
            return FrameStats(meanR: 0, meanG: 0, meanB: 0,
                              stdDevR: 0, stdDevG: 0, stdDevB: 0,
                              logAverageLuma: 0, nearBlackFraction: 0, nearWhiteFraction: 0,
                              lumaHistogram: Array(repeating: 0, count: FrameStats.histogramBins),
                              sampleCount: 0)
        }
        func mean(_ index: Int) -> Double { Double(words[index]) / Layout.valueScale / n }
        func stdDev(_ sumIndex: Int, _ sqIndex: Int) -> Double {
            let m = mean(sumIndex)
            let m2 = mean(sqIndex)
            return max(m2 - m * m, 0).squareRoot()
        }
        let meanLog = Double(words[Layout.sumLogLuma]) / Layout.logScale / n - Layout.logOffset
        var histogram = [Double](repeating: 0, count: FrameStats.histogramBins)
        for i in 0..<FrameStats.histogramBins {
            histogram[i] = Double(words[Layout.histogram + i]) / n
        }
        return FrameStats(
            meanR: mean(Layout.sumR), meanG: mean(Layout.sumG), meanB: mean(Layout.sumB),
            stdDevR: stdDev(Layout.sumR, Layout.sumR2),
            stdDevG: stdDev(Layout.sumG, Layout.sumG2),
            stdDevB: stdDev(Layout.sumB, Layout.sumB2),
            logAverageLuma: exp2(meanLog),
            nearBlackFraction: Double(words[Layout.nearBlack]) / n,
            nearWhiteFraction: Double(words[Layout.nearWhite]) / n,
            lumaHistogram: histogram,
            sampleCount: Int(words[Layout.count]))
    }
}
