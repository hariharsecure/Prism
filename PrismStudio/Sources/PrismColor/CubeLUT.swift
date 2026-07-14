import Foundation
import simd

/// Errors from `.cube` parsing.
public enum CubeLUTError: Error, Equatable, CustomStringConvertible {
    /// The file/string contained no parseable content.
    case emptyInput
    /// Neither `LUT_1D_SIZE` nor `LUT_3D_SIZE` was declared before data.
    case missingSize
    /// Both (or repeated) size declarations were found.
    case conflictingSize
    /// Declared size is out of the sane range (1D: 2…65536, 3D: 2…129).
    case invalidSize(Int)
    /// A line that is neither a known keyword, a comment, nor an
    /// `R G B` float triple (1-based line number + content).
    case malformedLine(line: Int, content: String)
    /// `DOMAIN_MIN`/`DOMAIN_MAX` malformed or min ≥ max on some channel.
    case invalidDomain
    /// Data-row count ≠ size (1D) or size³ (3D).
    case entryCountMismatch(expected: Int, found: Int)
    /// The file could not be read as UTF-8 text.
    case unreadableFile(String)

    public var description: String {
        switch self {
        case .emptyInput: return "cube LUT: empty input"
        case .missingSize: return "cube LUT: missing LUT_1D_SIZE / LUT_3D_SIZE"
        case .conflictingSize: return "cube LUT: conflicting/duplicate size declarations"
        case .invalidSize(let n): return "cube LUT: invalid size \(n)"
        case .malformedLine(let line, let content): return "cube LUT: malformed line \(line): '\(content)'"
        case .invalidDomain: return "cube LUT: invalid DOMAIN_MIN/DOMAIN_MAX"
        case .entryCountMismatch(let expected, let found):
            return "cube LUT: expected \(expected) entries, found \(found)"
        case .unreadableFile(let path): return "cube LUT: cannot read '\(path)' as UTF-8"
        }
    }
}

/// A parsed Adobe/Resolve `.cube` LUT — 1D or 3D, with `DOMAIN_MIN`/`DOMAIN_MAX`
/// support. Pure value type: parsing touches no GPU and is unit-testable.
///
/// Data layout: flat `[Float]` of RGB triples. For 3D LUTs the `.cube`
/// convention is preserved — **red varies fastest, then green, then blue** —
/// which maps directly onto a Metal 3D texture as (x=r, y=g, z=b).
/// Values outside 0…1 are allowed (HDR/extended LUTs).
public struct CubeLUT: Sendable {
    public enum Dimension: Sendable, Equatable {
        /// `size` entries; each channel is looked up independently.
        case oneD
        /// `size`³ entries; trilinear interpolation in the cube.
        case threeD
    }

    public let dimension: Dimension
    /// Edge length: entry count is `size` (1D) or `size`³ (3D).
    public let size: Int
    /// Flat RGB triples, `.cube` order (red fastest for 3D).
    public let data: [Float]
    /// Input value mapped to the first LUT entry (default 0,0,0).
    public let domainMin: SIMD3<Float>
    /// Input value mapped to the last LUT entry (default 1,1,1).
    public let domainMax: SIMD3<Float>
    /// `TITLE` string, if present.
    public let title: String?
    /// Stable identity token — lets `ColorProcessor` cache the GPU texture
    /// without hashing the payload.
    public let id: UUID

    // MARK: - Construction

    init(dimension: Dimension, size: Int, data: [Float],
         domainMin: SIMD3<Float>, domainMax: SIMD3<Float>, title: String?) {
        self.dimension = dimension
        self.size = size
        self.data = data
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.title = title
        self.id = UUID()
    }

    /// Parse `.cube` text. Comment lines (`#`) and blank lines are skipped;
    /// unknown keyword lines are ignored (files in the wild carry extras).
    public init(string: String) throws {
        var declaredSize: Int?
        var dimension: Dimension?
        var title: String?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var data: [Float] = []

        var sawAnything = false
        let lines = string.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            sawAnything = true
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = tokens.first else { continue }

            func floats(_ count: Int) throws -> [Float] {
                let values = tokens.dropFirst().compactMap { Float($0) }
                guard values.count == count, tokens.count == count + 1 else {
                    throw CubeLUTError.malformedLine(line: index + 1, content: line)
                }
                return values
            }

            switch first.uppercased() {
            case "TITLE":
                title = line.dropFirst("TITLE".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_1D_SIZE", "LUT_3D_SIZE":
                guard declaredSize == nil else { throw CubeLUTError.conflictingSize }
                guard tokens.count == 2, let n = Int(tokens[1]) else {
                    throw CubeLUTError.malformedLine(line: index + 1, content: line)
                }
                declaredSize = n
                dimension = first.uppercased() == "LUT_1D_SIZE" ? .oneD : .threeD
            case "DOMAIN_MIN":
                let v = try floats(3); domainMin = SIMD3(v[0], v[1], v[2])
            case "DOMAIN_MAX":
                let v = try floats(3); domainMax = SIMD3(v[0], v[1], v[2])
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                // Iridas variant: two scalars applied to all channels.
                let values = tokens.dropFirst().compactMap { Float($0) }
                guard values.count == 2 else {
                    throw CubeLUTError.malformedLine(line: index + 1, content: line)
                }
                domainMin = SIMD3(repeating: values[0])
                domainMax = SIMD3(repeating: values[1])
            default:
                if let scalar = first.unicodeScalars.first,
                   CharacterSet(charactersIn: "+-.0123456789").contains(scalar) {
                    // Data row: exactly three floats.
                    let values = tokens.compactMap { Float($0) }
                    guard values.count == 3, tokens.count == 3 else {
                        throw CubeLUTError.malformedLine(line: index + 1, content: line)
                    }
                    data.append(contentsOf: values)
                }
                // Unknown keyword line → ignored.
            }
        }

        guard sawAnything else { throw CubeLUTError.emptyInput }
        guard let size = declaredSize, let dim = dimension else { throw CubeLUTError.missingSize }
        switch dim {
        case .oneD: guard (2...65536).contains(size) else { throw CubeLUTError.invalidSize(size) }
        case .threeD: guard (2...129).contains(size) else { throw CubeLUTError.invalidSize(size) }
        }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y, domainMax.z > domainMin.z else {
            throw CubeLUTError.invalidDomain
        }
        let expected = dim == .oneD ? size : size * size * size
        guard data.count == expected * 3 else {
            throw CubeLUTError.entryCountMismatch(expected: expected, found: data.count / 3)
        }
        self.init(dimension: dim, size: size, data: data,
                  domainMin: domainMin, domainMax: domainMax, title: title)
    }

    /// Parse a `.cube` file from disk.
    public init(contentsOf url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CubeLUTError.unreadableFile(url.path)
        }
        try self.init(string: text)
    }

    /// An identity 3D cube (useful for tests and as a neutral slot).
    public static func identity(size: Int) -> CubeLUT {
        precondition((2...129).contains(size))
        var data = [Float]()
        data.reserveCapacity(size * size * size * 3)
        let scale = 1.0 / Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    data.append(Float(r) * scale)
                    data.append(Float(g) * scale)
                    data.append(Float(b) * scale)
                }
            }
        }
        return CubeLUT(dimension: .threeD, size: size, data: data,
                       domainMin: SIMD3(repeating: 0), domainMax: SIMD3(repeating: 1),
                       title: "identity\(size)")
    }
}
