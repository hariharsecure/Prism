import CoreAudio
import CoreMedia
import Foundation
import PrismCore
import os

/// Availability-safe entry point for system-audio capture. The CoreAudio
/// process-tap API needs macOS 14.2+; below that this throws a typed error
/// instead of crashing at symbol load.
public enum SystemAudioCapture {
    /// Make a system-wide audio source (all processes except our own).
    /// - Throws: `PrismAudioError.unsupportedOS` below macOS 14.2.
    public static func makeSource(id: SourceID = SourceID("system-audio")) throws -> AudioSource {
        guard #available(macOS 14.2, *) else {
            throw PrismAudioError.unsupportedOS(required: "macOS 14.2")
        }
        return SystemAudioSource(id: id)
    }
}

/// System-wide audio capture via a CoreAudio process tap (macOS 14.2+).
///
/// Plumbing (see AudioHardwareTapping.h / CATapDescription.h):
///  1. `CATapDescription` — global stereo tap of every process **except ours**
///     (excluding ourselves prevents feedback when the mixer monitors).
///  2. `AudioHardwareCreateProcessTap` → tap AudioObjectID.
///  3. A **private aggregate device** whose tap list contains the tap
///     (`kAudioAggregateDeviceTapListKey`, drift-compensated) and whose
///     sub-device is the default output device.
///  4. `AudioDeviceCreateIOProcIDWithBlock` on the aggregate: each IO cycle's
///     input buffer list *is* the tapped system audio.
///
/// Timing: the IOProc's `inInputTime.mHostTime` is mach host time — mapped to
/// house time via `CMClockMakeHostTimeFromSystemUnits` (HouseClock *is* the
/// host clock, DESIGN.md §3.3), so PTS passes straight through, no re-stamping.
///
/// Caveats: requires the audio-recording TCC grant (NSAudioCaptureUsageDescription);
/// `start()` will prompt. Never started by verification code.
@available(macOS 14.2, *)
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let id: SourceID
    public var onAudio: ((AudioPacket) -> Void)?

    public private(set) var state: SourceState {
        get { stateLock.withLock { $0 } }
        set { stateLock.withLock { $0 = newValue } }
    }

    private let stateLock = OSAllocatedUnfairLock<SourceState>(initialState: .idle)
    private let log = EngineLog.logger("audio.systemtap")
    private let ioQueue = DispatchQueue(label: "studio.prism.audio.systemtap", qos: .userInteractive)

    // CoreAudio objects owned while running.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatDescription: CMAudioFormatDescription?
    private var bytesPerFrame: Int = 0
    private var sampleRate: Double = 0

    public init(id: SourceID = SourceID("system-audio")) {
        self.id = id
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    public func start() throws {
        guard state == .idle || state == .failed else {
            throw PrismAudioError.invalidState("SystemAudioSource.start() while \(state.rawValue)")
        }
        state = .starting
        do {
            try startTap()
            state = .running
            log.info("system audio tap running (tap \(self.tapID), aggregate \(self.aggregateID))")
        } catch {
            teardown()
            state = .failed
            throw error
        }
    }

    public func stop() {
        guard state == .running || state == .starting else { return }
        state = .stopping
        teardown()
        state = .idle
        log.info("system audio tap stopped")
    }

    // MARK: Tap plumbing

    private func startTap() throws {
        // 1. Our own process object (to exclude from the global tap).
        let ownProcessObject = try translatePIDToProcessObject(pid: ProcessInfo.processInfo.processIdentifier)

        // 2. The tap: stereo mixdown of everything except us. Private so it
        //    never shows up in other apps' device lists; unmuted so tapping
        //    doesn't silence the speakers.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject])
        description.name = "Prism System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw PrismAudioError.osStatus(operation: "AudioHardwareCreateProcessTap", status: status)
        }
        tapID = newTapID

        // 3. The tap's stream format → CMAudioFormatDescription (created once,
        //    reused for every emitted sample buffer).
        var asbd = try readTapFormat(tapID: tapID)
        bytesPerFrame = Int(asbd.mBytesPerFrame)
        sampleRate = asbd.mSampleRate
        var fd: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &fd
        )
        guard status == noErr, let fd else {
            throw PrismAudioError.osStatus(operation: "CMAudioFormatDescriptionCreate(tap format)", status: status)
        }
        formatDescription = fd

        // 4. Private aggregate device that hosts the tap. The default output
        //    device is the clock-master sub-device; the tap rides along with
        //    drift compensation.
        let outputUID = try defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prism System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            throw PrismAudioError.osStatus(operation: "AudioHardwareCreateAggregateDevice", status: status)
        }
        aggregateID = newAggregateID

        // 5. IOProc: the input buffer list is the tapped audio.
        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleIO(inputData: inInputData, inputTime: inInputTime)
        }
        guard status == noErr, let newIOProcID else {
            throw PrismAudioError.osStatus(operation: "AudioDeviceCreateIOProcIDWithBlock", status: status)
        }
        ioProcID = newIOProcID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw PrismAudioError.osStatus(operation: "AudioDeviceStart", status: status)
        }
    }

    private func handleIO(inputData: UnsafePointer<AudioBufferList>,
                          inputTime: UnsafePointer<AudioTimeStamp>) {
        guard let onAudio, let formatDescription, bytesPerFrame > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard buffers.count > 0, buffers[0].mData != nil else { return }
        let frameCount = Int(buffers[0].mDataByteSize) / bytesPerFrame
        guard frameCount > 0 else { return }

        // Host time of the first tapped frame → house time (same clock).
        let pts: CMTime
        if inputTime.pointee.mFlags.contains(.hostTimeValid) {
            pts = CMClockMakeHostTimeFromSystemUnits(inputTime.pointee.mHostTime)
        } else {
            pts = HouseClock.now() // degenerate fallback; HAL always sets host time in practice
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate.rounded())),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            log.error("CMSampleBufferCreate failed: \(status)")
            return
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: inputData
        )
        guard status == noErr else {
            log.error("CMSampleBufferSetDataBufferFromAudioBufferList failed: \(status)")
            return
        }
        onAudio(AudioPacket(sampleBuffer: sampleBuffer, source: id))
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        formatDescription = nil
    }

    // MARK: CoreAudio property helpers

    private func translatePIDToProcessObject(pid: Int32) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid_t(pid)
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &dataSize, &processObject
        )
        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw PrismAudioError.osStatus(operation: "TranslatePIDToProcessObject", status: status)
        }
        return processObject
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        guard status == noErr, asbd.mBytesPerFrame > 0 else {
            throw PrismAudioError.osStatus(operation: "kAudioTapPropertyFormat", status: status)
        }
        return asbd
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw PrismAudioError.osStatus(operation: "DefaultSystemOutputDevice", status: status)
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        dataSize = UInt32(MemoryLayout<CFString>.size)
        status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, uidPtr)
        }
        guard status == noErr else {
            throw PrismAudioError.osStatus(operation: "kAudioDevicePropertyDeviceUID", status: status)
        }
        return uid as String
    }
}
