import AVFAudio
import Foundation
import os

/// Fixed-capacity ring buffer for interleaved Float32 PCM frames.
///
/// Policy (DESIGN.md §3.3 — live mixing never queues deep):
///  - **Drop-oldest** on overflow: the writer always wins; stale audio is discarded.
///  - **Underrun fills silence**: the reader always gets `frameCount` frames; the
///    tail that wasn't available is zeroed and counted as an underrun.
///
/// All storage is allocated in `init` — the audio-thread paths (`read`) never
/// allocate. Thread model: one producer (ingest queue) + one consumer (audio
/// render thread). The unfair lock guards index math and the memcpys; at mixer
/// block sizes this is nanoseconds-to-microseconds, the same trade `FrameMailbox`
/// makes (a lock-free ring is a later optimization, not a correctness need).
public final class PCMRingBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float> // interleaved, capacityFrames * channelCount
    private let lock = OSAllocatedUnfairLock<Indices>(initialState: Indices())

    private struct Indices {
        var head: Int = 0            // next write position (frames, un-wrapped modulo capacity)
        var count: Int = 0           // valid frames
        var droppedFrames: UInt64 = 0
        var underrunFrames: UInt64 = 0
    }

    public init(channelCount: Int, capacityFrames: Int) {
        precondition(channelCount >= 1 && capacityFrames >= 1)
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.storage = .allocate(capacity: channelCount * capacityFrames)
        self.storage.initialize(repeating: 0, count: channelCount * capacityFrames)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: Producer

    /// Write deinterleaved channel data (the `floatChannelData` layout of an
    /// `AVAudioPCMBuffer` in the standard non-interleaved format). Channels
    /// beyond `channelCount` are ignored; missing channels are duplicated from
    /// channel 0 (mono → stereo up-mix).
    public func write(deinterleaved channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                      sourceChannelCount: Int,
                      sourceFrameOffset: Int = 0,
                      frameCount: Int) {
        guard frameCount > 0, sourceChannelCount > 0, sourceFrameOffset >= 0 else { return }
        lock.withLockUnchecked { idx in
            var start = sourceFrameOffset
            var frames = frameCount
            if frames > capacityFrames { // writing more than capacity: keep only the newest
                let skipped = frames - capacityFrames
                start += skipped
                idx.droppedFrames += UInt64(skipped)
                frames = capacityFrames
            }
            // Drop oldest to make room.
            let free = capacityFrames - idx.count
            if frames > free {
                let drop = frames - free
                idx.count -= drop
                idx.droppedFrames += UInt64(drop)
                // head stays; logical read pointer is (head - count), which just advanced.
            }
            var writePos = (idx.head) % capacityFrames
            for f in 0..<frames {
                let base = writePos * channelCount
                for ch in 0..<channelCount {
                    let srcCh = ch < sourceChannelCount ? ch : 0
                    storage[base + ch] = channels[srcCh][start + f]
                }
                writePos += 1
                if writePos == capacityFrames { writePos = 0 }
            }
            idx.head = (idx.head + frames) % capacityFrames
            idx.count += frames
        }
    }

    /// Write interleaved frames (`sourceChannelCount` samples per frame).
    public func write(interleaved samples: UnsafePointer<Float>,
                      sourceChannelCount: Int,
                      frameCount: Int) {
        guard frameCount > 0, sourceChannelCount > 0 else { return }
        lock.withLockUnchecked { idx in
            var start = 0
            var frames = frameCount
            if frames > capacityFrames {
                start = frames - capacityFrames
                idx.droppedFrames += UInt64(start)
                frames = capacityFrames
            }
            let free = capacityFrames - idx.count
            if frames > free {
                let drop = frames - free
                idx.count -= drop
                idx.droppedFrames += UInt64(drop)
            }
            var writePos = (idx.head) % capacityFrames
            for f in 0..<frames {
                let srcBase = (start + f) * sourceChannelCount
                let dstBase = writePos * channelCount
                for ch in 0..<channelCount {
                    let srcCh = ch < sourceChannelCount ? ch : 0
                    storage[dstBase + ch] = samples[srcBase + srcCh]
                }
                writePos += 1
                if writePos == capacityFrames { writePos = 0 }
            }
            idx.head = (idx.head + frames) % capacityFrames
            idx.count += frames
        }
    }

    // MARK: Consumer (audio render thread — no allocation)

    /// Fill an `AudioBufferList` (interleaved single-buffer or non-interleaved
    /// multi-buffer layout) with `frameCount` frames. Returns the number of
    /// frames that came from real data; the remainder was zero-filled
    /// (underrun). Never allocates.
    public func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard frameCount > 0, buffers.count > 0 else { return 0 }
        return lock.withLockUnchecked { idx -> Int in
            let available = min(idx.count, frameCount)
            var readPos = (idx.head - idx.count + capacityFrames * 2) % capacityFrames

            if buffers.count == 1, Int(buffers[0].mNumberChannels) == channelCount {
                // Interleaved destination.
                guard let dst = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                for f in 0..<available {
                    let srcBase = readPos * channelCount
                    let dstBase = f * channelCount
                    for ch in 0..<channelCount { dst[dstBase + ch] = storage[srcBase + ch] }
                    readPos += 1
                    if readPos == capacityFrames { readPos = 0 }
                }
                if available < frameCount {
                    let silence = (frameCount - available) * channelCount
                    (dst + available * channelCount).update(repeating: 0, count: silence)
                }
            } else {
                // Non-interleaved destination: one buffer per channel.
                for (ch, buffer) in buffers.enumerated() {
                    guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    var pos = readPos
                    let srcCh = ch < channelCount ? ch : 0
                    for f in 0..<available {
                        dst[f] = storage[pos * channelCount + srcCh]
                        pos += 1
                        if pos == capacityFrames { pos = 0 }
                    }
                    if available < frameCount {
                        (dst + available).update(repeating: 0, count: frameCount - available)
                    }
                }
            }

            idx.count -= available
            if available < frameCount { idx.underrunFrames += UInt64(frameCount - available) }
            return available
        }
    }

    /// Frames currently buffered.
    public var bufferedFrames: Int { lock.withLock { $0.count } }

    /// Lifetime counters: frames dropped (overflow) and frames zero-filled (underrun).
    public var stats: (dropped: UInt64, underruns: UInt64) {
        lock.withLock { ($0.droppedFrames, $0.underrunFrames) }
    }

    /// Discard everything buffered.
    public func reset() {
        lock.withLock { idx in
            idx.count = 0
            idx.head = 0
        }
    }
}
