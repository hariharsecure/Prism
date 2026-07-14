import Foundation

/// Errors for the Phase-0 AR depth spike (`docs/UNREAL_AR_3D_CHARACTER_DESIGN.md`,
/// "Phase 0 — bounded spike"). This module is an ISOLATED prove-or-kill harness:
/// it proves the compositing + depth-alignment MATH on synthetic data and does
/// not touch the production `MetalCompositor`/`RenderLoop`.
public enum DepthSpikeError: Error, CustomStringConvertible {
    /// No Metal device / required capability missing.
    case metalUnavailable(String)
    /// Runtime MSL compilation failed (embedded shader source).
    case libraryCompilationFailed(underlying: Error)
    /// A named kernel is missing from the compiled library.
    case functionNotFound(String)
    case pipelineCreationFailed(String, underlying: Error)
    case textureCacheCreationFailed(Int32)
    /// Wrapping an input/output pixel buffer as a Metal texture failed.
    case textureWrapFailed(String)
    case commandCreationFailed
    /// A committed command buffer finished in a non-`.completed` state; output
    /// pixels are undefined and MUST NOT be trusted.
    case gpuExecutionFailed(underlying: Error?)
    /// Buffer allocation from the pool failed.
    case bufferAllocationFailed(underlying: Error)
    /// The depth-alignment fit could not be solved (degenerate / too few points).
    case fitDegenerate(String)
    /// Input arrays / dimensions did not agree.
    case dimensionMismatch(String)

    public var description: String {
        switch self {
        case .metalUnavailable(let s): return "metalUnavailable(\(s))"
        case .libraryCompilationFailed(let e): return "libraryCompilationFailed(\(e))"
        case .functionNotFound(let s): return "functionNotFound(\(s))"
        case .pipelineCreationFailed(let s, let e): return "pipelineCreationFailed(\(s): \(e))"
        case .textureCacheCreationFailed(let s): return "textureCacheCreationFailed(\(s))"
        case .textureWrapFailed(let s): return "textureWrapFailed(\(s))"
        case .commandCreationFailed: return "commandCreationFailed"
        case .gpuExecutionFailed(let e): return "gpuExecutionFailed(\(String(describing: e)))"
        case .bufferAllocationFailed(let e): return "bufferAllocationFailed(\(e))"
        case .fitDegenerate(let s): return "fitDegenerate(\(s))"
        case .dimensionMismatch(let s): return "dimensionMismatch(\(s))"
        }
    }
}
