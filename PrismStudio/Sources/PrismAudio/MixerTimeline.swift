import AudioToolbox
import AVFAudio
import CoreMedia
import Foundation
import PrismCore
import os

/// One PTS/render-frame epoch shared by every channel and the master tap.
///
/// Channels keep their own render cursors (AVAudioEngine renders source nodes
/// sequentially), while this object owns only the common coordinate system and
/// the completed master cursor. No storage grows with timestamp distance.
final class MixerTimeline: @unchecked Sendable {
    struct Placement {
        /// Positive = prepend silence; negative = trim PCM.
        let frameOffset: Int
        let wasCapped: Bool
    }

    private enum RunMode {
        case idle
        case manual
        case live
    }

    private struct State {
        var mode: RunMode = .idle
        var sampleTimeBase: Double?
        var completedMasterFrame: Int64 = 0
        var originPTS: CMTime = .invalid
        var originRenderFrame: Int64 = 0
    }

    private let timescale: CMTimeScale
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    init(sampleRate: Double) {
        self.timescale = CMTimeScale(sampleRate.rounded())
    }

    func beginRun(manual: Bool) {
        lock.withLock { state in
            state.mode = manual ? .manual : .live
            // Offline AVAudioEngine sample time always starts at zero. This is
            // independent of the input PTS epoch, which remains lazily anchored.
            if manual, state.sampleTimeBase == nil { state.sampleTimeBase = 0 }
        }
    }

    /// Clear the epoch only when the whole engine stops. Removing one channel
    /// must leave the epoch intact so a replacement aligns with surviving inputs.
    func reset() {
        lock.withLock { $0 = State() }
    }

    var currentRenderFrame: Int64 {
        lock.withLock { state in
            guard state.mode == .live,
                  let nowFrame = mappedFrame(for: HouseClock.now(), state: state) else {
                return state.completedMasterFrame
            }
            return max(state.completedMasterFrame, nowFrame)
        }
    }

    /// The offline render call is synchronous, so its explicit sample counter is
    /// a more current cursor than the master tap (which batches delivery).
    func publishManualRenderCompleted(_ frame: Int64) {
        lock.withLock { state in
            guard state.mode == .manual else { return }
            state.completedMasterFrame = max(state.completedMasterFrame, frame)
        }
    }

    func presentationTime(for renderFrame: Int64) -> CMTime? {
        lock.withLock { mappedPTS(for: renderFrame, state: $0) }
    }

    /// Translate a source-node render timestamp to the shared frame coordinate.
    /// In live mode, the first valid host timestamp establishes exact house time.
    func sourceRenderFrame(for timestamp: AudioTimeStamp) -> Int64? {
        guard timestamp.mFlags.contains(.sampleTimeValid), timestamp.mSampleTime.isFinite else {
            return nil
        }
        return lock.withLock { state in
            let frame = normalizedFrame(sampleTime: timestamp.mSampleTime, state: &state)
            if state.mode == .live,
               !state.originPTS.isValid,
               timestamp.mFlags.contains(.hostTimeValid) {
                state.originPTS = CMClockMakeHostTimeFromSystemUnits(timestamp.mHostTime)
                state.originRenderFrame = frame
            }
            return frame
        }
    }

    /// Publish the completed master block and return its start frame plus the PTS
    /// derived from the same epoch used for channel placement.
    func observeMasterRender(when: AVAudioTime, frameCount: Int) -> (frame: Int64, pts: CMTime?) {
        lock.withLock { state in
            let frame: Int64
            if when.isSampleTimeValid {
                frame = normalizedFrame(sampleTime: Double(when.sampleTime), state: &state)
            } else {
                frame = state.completedMasterFrame
            }

            if state.mode == .live, !state.originPTS.isValid, when.isHostTimeValid {
                state.originPTS = CMClockMakeHostTimeFromSystemUnits(when.hostTime)
                state.originRenderFrame = frame
            }

            let (end, overflow) = frame.addingReportingOverflow(Int64(frameCount))
            if !overflow { state.completedMasterFrame = max(state.completedMasterFrame, end) }
            return (frame, mappedPTS(for: frame, state: state))
        }
    }

    /// Map a packet start onto `renderFrame`. Positive placement is capped before
    /// integer conversion; negative placement never exceeds the packet itself.
    func placement(
        for pts: CMTime,
        at renderFrame: Int64,
        packetFrames: Int,
        maximumLeadingFrames: Int
    ) -> Placement? {
        guard pts.isValid, pts.isNumeric, packetFrames > 0 else { return nil }
        return lock.withLock { state in
            if !state.originPTS.isValid {
                state.originPTS = pts
                state.originRenderFrame = renderFrame
            }
            guard let renderPTS = mappedPTS(for: renderFrame, state: state) else { return nil }

            let delta = CMTimeSubtract(pts, renderPTS)
            guard delta.isValid, delta.isNumeric else { return nil }

            let leadLimit = max(0, maximumLeadingFrames)
            let maximumLead = CMTime(value: CMTimeValue(leadLimit), timescale: timescale)
            if CMTimeCompare(delta, maximumLead) > 0 {
                return Placement(frameOffset: leadLimit, wasCapped: true)
            }

            let packetDuration = CMTime(value: CMTimeValue(packetFrames), timescale: timescale)
            if CMTimeCompare(delta, CMTimeMultiplyByFloat64(packetDuration, multiplier: -1)) <= 0 {
                return Placement(frameOffset: -packetFrames, wasCapped: false)
            }

            let scaled = CMTimeConvertScale(delta, timescale: timescale, method: .default)
            guard scaled.isValid, scaled.isNumeric else { return nil }
            let bounded = min(Int64(leadLimit), max(-Int64(packetFrames), scaled.value))
            return Placement(frameOffset: Int(bounded), wasCapped: false)
        }
    }

    private func normalizedFrame(sampleTime: Double, state: inout State) -> Int64 {
        if state.sampleTimeBase == nil { state.sampleTimeBase = sampleTime }
        let delta = sampleTime - (state.sampleTimeBase ?? sampleTime)
        guard delta.isFinite else { return state.completedMasterFrame }
        if delta >= Double(Int64.max) { return Int64.max }
        if delta <= Double(Int64.min) { return Int64.min }
        return Int64(delta.rounded())
    }

    private func mappedPTS(for frame: Int64, state: State) -> CMTime? {
        guard state.originPTS.isValid, state.originPTS.isNumeric else { return nil }
        let (delta, overflow) = frame.subtractingReportingOverflow(state.originRenderFrame)
        guard !overflow else { return nil }
        return CMTimeAdd(state.originPTS, CMTime(value: delta, timescale: timescale))
    }

    private func mappedFrame(for pts: CMTime, state: State) -> Int64? {
        guard state.originPTS.isValid, state.originPTS.isNumeric,
              pts.isValid, pts.isNumeric else { return nil }
        let delta = CMTimeConvertScale(CMTimeSubtract(pts, state.originPTS),
                                       timescale: timescale, method: .default)
        guard delta.isValid, delta.isNumeric else { return nil }
        let (frame, overflow) = state.originRenderFrame.addingReportingOverflow(delta.value)
        return overflow ? nil : frame
    }
}
