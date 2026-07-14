import Foundation

/// Minimal, correct RIFF/WAVE PCM writer (16- or 24-bit, interleaved).
/// Input is planar Float32 in [-1, 1]; samples are clamped and quantized.
enum WAVFile {
    enum BitDepth: Int { case pcm16 = 16, pcm24 = 24 }

    /// Encode planar float channels to a complete WAV file `Data`.
    static func encode(channels: [[Float]], sampleRate: Int, bitDepth: BitDepth) -> Data {
        let numCh = max(1, channels.count)
        let frames = channels.first?.count ?? 0
        let bytesPerSample = bitDepth.rawValue / 8
        let blockAlign = numCh * bytesPerSample
        let dataBytes = frames * blockAlign
        let byteRate = sampleRate * blockAlign

        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func ascii(_ s: String) { d.append(contentsOf: s.utf8) }

        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1)                 // PCM
        u16(UInt16(numCh)); u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(blockAlign)); u16(UInt16(bitDepth.rawValue))
        ascii("data"); u32(UInt32(dataBytes))

        var pcm = [UInt8](); pcm.reserveCapacity(dataBytes)
        switch bitDepth {
        case .pcm16:
            for f in 0..<frames {
                for c in 0..<numCh {
                    let s = max(-1, min(1, channels[c][f]))
                    let v = Int16(s * 32767)
                    let u = UInt16(bitPattern: v)
                    pcm.append(UInt8(u & 0xFF)); pcm.append(UInt8(u >> 8))
                }
            }
        case .pcm24:
            for f in 0..<frames {
                for c in 0..<numCh {
                    let s = max(-1, min(1, channels[c][f]))
                    let v = Int32(s * 8_388_607)
                    let u = UInt32(bitPattern: v)
                    pcm.append(UInt8(u & 0xFF)); pcm.append(UInt8((u >> 8) & 0xFF)); pcm.append(UInt8((u >> 16) & 0xFF))
                }
            }
        }
        d.append(contentsOf: pcm)
        return d
    }
}
