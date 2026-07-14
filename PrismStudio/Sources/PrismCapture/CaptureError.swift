import CoreVideo
import Foundation

/// Typed errors for the PrismCapture module.
public enum CaptureError: Error, CustomStringConvertible {
    /// No AVCaptureDevice with this uniqueID exists (unplugged?).
    case deviceNotFound(uniqueID: String)
    /// AVCaptureDeviceInput creation failed (TCC denial surfaces here too).
    case inputCreationFailed(device: String, underlying: Error)
    /// Session refused the device input.
    case cannotAddInput(device: String)
    /// Session refused the data output.
    case cannotAddOutput(device: String)
    /// Format index outside the device's `formats` array.
    case formatIndexOutOfRange(Int)
    /// Requested fps not inside any supported frame-rate range of the active format.
    case frameRateUnsupported(Double)
    /// The data output cannot deliver the requested pixel format.
    case pixelFormatUnavailable(OSType)
    /// lockForConfiguration / configuration change failed.
    case configurationFailed(device: String, underlying: Error)

    public var description: String {
        switch self {
        case .deviceNotFound(let id):
            return "capture device not found: \(id)"
        case .inputCreationFailed(let dev, let err):
            return "could not create input for \(dev): \(err)"
        case .cannotAddInput(let dev):
            return "session rejected input for \(dev)"
        case .cannotAddOutput(let dev):
            return "session rejected data output for \(dev)"
        case .formatIndexOutOfRange(let i):
            return "format index \(i) out of range"
        case .frameRateUnsupported(let fps):
            return "frame rate \(fps) fps unsupported by active format"
        case .pixelFormatUnavailable(let fmt):
            return "pixel format '\(FourCC.string(fmt))' unavailable on data output"
        case .configurationFailed(let dev, let err):
            return "configuration failed for \(dev): \(err)"
        }
    }
}

/// FourCC pretty-printing for pixel/media format codes.
public enum FourCC {
    public static func string(_ code: OSType) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        guard printable, let s = String(bytes: bytes, encoding: .ascii) else {
            return String(format: "0x%08X", code)
        }
        return s
    }
}
