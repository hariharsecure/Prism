import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os
import PrismCore

/// Host-side pump: program `VideoFrame`s → the extension's SINK stream.
///
/// Plumbing (DESIGN.md §3.6): the extension is a separate sandboxed process;
/// the only host-visible surface it has is the legacy CoreMediaIO DAL C API.
/// The feeder therefore:
///   1. enumerates DAL devices (`kCMIOHardwarePropertyDevices`) and matches
///      `kCMIODevicePropertyDeviceUID` against `PrismVCamConstants.deviceUID`,
///   2. finds the SINK stream on that device (`kCMIOStreamPropertyDirection`),
///   3. copies the stream's buffer queue (`CMIOStreamCopyBufferQueue`) and
///      starts the stream (`CMIODeviceStartStream`),
///   4. wraps each program frame's IOSurface-backed pixel buffer in a
///      CMSampleBuffer (zero-copy — the IOSurface crosses the process
///      boundary by reference) and enqueues it.
///
/// Threading: discovery/lifecycle is confined to an internal serial queue;
/// `send(_:)` is callable from the render thread and touches only
/// lock-guarded pointers (no allocation beyond the CMSampleBuffer wrapper,
/// no base-address locks — AGENTS.md hot-path rules).
public final class VirtualCameraFeeder: @unchecked Sendable {

    // MARK: Public surface

    public enum State: Equatable, Sendable {
        /// Not started.
        case idle
        /// Looking for the extension's device (listener + periodic rescan).
        case searching
        /// No Prism device in the DAL — extension not installed/approved yet.
        /// The feeder keeps watching; install can complete at any time.
        case extensionNotInstalled
        /// Device + sink stream found, queue open, stream started: frames
        /// passed to `send(_:)` are being delivered.
        case feeding
        /// `stop()` was called.
        case stopped
        /// Unrecoverable setup failure (state also reverts to searching where
        /// retry makes sense; see `FeederError`).
        case failed(FeederError)
    }

    public enum FeederError: Error, Equatable, Sendable {
        /// Device present but its sink stream could not be identified.
        case sinkStreamNotFound
        /// CMIOStreamCopyBufferQueue failed.
        case bufferQueueUnavailable(OSStatus)
        /// CMIODeviceStartStream failed.
        case startStreamFailed(OSStatus)
    }

    /// State callbacks; invoked on the feeder's internal serial queue.
    public var onStateChange: ((State) -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    public private(set) var state: State {
        get { lock.withLock { _state } }
        set {
            let (changed, callback): (Bool, ((State) -> Void)?) = lock.withLock {
                guard _state != newValue else { return (false, nil) }
                _state = newValue
                return (true, _onStateChange)
            }
            if changed {
                logger.info("state → \(String(describing: newValue), privacy: .public)")
                callback?(newValue)
            }
        }
    }

    /// Delivery counters (frames enqueued; dropped because the sink queue was
    /// full; dropped because the sink isn't attached yet).
    public var stats: (enqueued: UInt64, droppedQueueFull: UInt64, droppedNotReady: UInt64) {
        lock.withLock { (_enqueued, _droppedQueueFull, _droppedNotReady) }
    }

    public init() {}

    deinit {
        teardownStream()
    }

    /// Begin discovery. Safe to call before the extension is installed — the
    /// feeder reports `.extensionNotInstalled` and hooks the DAL device-list
    /// property so it attaches the moment the user approves the extension.
    public func start() {
        workQueue.async { [weak self] in
            guard let self else { return }
            // Idempotency + leak accounting live in the pure lifecycle model:
            // `start()` keeps `.feeding` when already attached (so a repeat
            // "vcam on" doesn't drop to `.searching`), and asks us to install a
            // DAL listener only when one isn't already registered.
            let needsListener = self.lifecycle.start()
            if !self.lifecycle.attached {
                self.state = .searching
            }
            if needsListener { self.installDeviceListListener() }
            self.armRescanTimer()
            self.attemptAttach()
        }
    }

    /// Stop feeding and release the DAL stream/queue.
    public func stop() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.lifecycle.stop()
            self.disarmRescanTimer()
            self.removeDeviceListListener()
            self.teardownStream()
            self.state = .stopped
        }
    }

    /// Await the completion of any teardown queued by `stop()` (2c external-output
    /// barrier). `stop()` posts its DAL-stream release to a SERIAL work queue and
    /// returns immediately; this fences that queue so app shutdown can guarantee
    /// the virtual camera is fully detached before the process exits (no lingering
    /// vcam). Does not rewrite the lifecycle — it only observes queue drain.
    public func drainTeardown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workQueue.async { continuation.resume() }
        }
    }

    /// Enqueue one program frame. Render-thread-safe; drops (and counts) when
    /// the sink isn't attached or its queue is full — never blocks.
    public func send(_ frame: VideoFrame) {
        // Snapshot the queue under the lock; CMSimpleQueue itself is
        // thread-safe for single-producer enqueue.
        // withLockUnchecked: CMSimpleQueue isn't Sendable, but we only move a
        // reference under the lock; the queue itself is thread-safe for our
        // single-producer enqueue.
        let queue: CMSimpleQueue? = lock.withLockUnchecked { _sinkQueue }
        guard let queue else {
            lock.withLock { _droppedNotReady += 1 }
            return
        }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            lock.withLock { _droppedQueueFull += 1 }
            return
        }
        guard let sampleBuffer = makeSampleBuffer(for: frame) else {
            lock.withLock { _droppedNotReady += 1 }
            return
        }
        // Enqueue RETAINED: the DAL machinery in the extension's registry
        // takes ownership and releases after transmission. If we tear down
        // with buffers still queued, teardownStream() drains + releases them.
        let retained = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        if status == noErr {
            lock.withLock { _enqueued += 1 }
        } else {
            // Enqueue refused (raced a concurrent fill) — reclaim our retain.
            retained.release()
            lock.withLock { _droppedQueueFull += 1 }
        }
    }

    // MARK: - Internals

    private let logger = EngineLog.logger("vcam.feeder")
    private let workQueue = DispatchQueue(label: "studio.prism.vcam.feeder")
    private let lock = OSAllocatedUnfairLock()

    // Guarded by `lock`:
    private var _state: State = .idle
    private var _onStateChange: ((State) -> Void)?
    private var _sinkQueue: CMSimpleQueue?
    private var _formatDescription: CMVideoFormatDescription?
    private var _enqueued: UInt64 = 0
    private var _droppedQueueFull: UInt64 = 0
    private var _droppedNotReady: UInt64 = 0

    // Confined to `workQueue`:
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOObjectID = 0
    private var streamStarted = false
    private var rescanTimer: DispatchSourceTimer?
    /// Pure state-transition + DAL-listener accounting (idempotency / no leak).
    private var lifecycle = VCamLifecycleModel()
    /// The exact listener block registered with the DAL, retained so we can
    /// unregister the *identical* reference on stop() (the removal API matches
    /// by block identity). `nil` ⇔ no listener registered — the leak fix.
    private var deviceListListenerBlock: CMIOObjectPropertyListenerBlock?

    /// C callback the DAL invokes when the sink queue is altered (for output
    /// streams: on removals, i.e. the extension consumed a buffer). We only
    /// use it as a liveness signal. refCon is `self` unretained — valid
    /// because teardownStream() always unregisters before self can die
    /// (deinit calls it).
    private static let queueAlteredProc: CMIODeviceStreamQueueAlteredProc = { _, _, refCon in
        guard let refCon else { return }
        let feeder = Unmanaged<VirtualCameraFeeder>.fromOpaque(refCon).takeUnretainedValue()
        feeder.logger.debug("sink queue altered (extension consuming)")
    }

    private var deviceListAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private func installDeviceListListener() {
        // Belt-and-braces: never register a second block over a live one.
        guard deviceListListenerBlock == nil else { return }
        // Re-attempt attach whenever the device list changes (extension
        // installed, approved, upgraded, or unloaded). Hold the block so the
        // matching stop() can remove this EXACT reference.
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.attemptAttach()
        }
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &deviceListAddress, workQueue, block
        )
        if status == noErr {
            deviceListListenerBlock = block
        } else {
            // Install failed — undo the model's accounting so a later start
            // retries and stop() won't try to remove a phantom listener.
            lifecycle.listenerInstallFailed()
            logger.warning("device-list listener failed (\(status)); relying on rescan timer")
        }
    }

    private func removeDeviceListListener() {
        // Remove the identical block reference we registered (the DAL matches by
        // block identity), then drop it so off/on cycles never leak listeners.
        guard let block = deviceListListenerBlock else { return }
        let status = CMIOObjectRemovePropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &deviceListAddress, workQueue, block
        )
        if status != noErr {
            logger.warning("device-list listener removal failed (\(status))")
        }
        deviceListListenerBlock = nil
    }

    private func armRescanTimer() {
        guard rescanTimer == nil else { return }
        // Belt-and-braces: some device-list transitions (notably extension
        // replacement during upgrade) have been flaky about notifications.
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.attemptAttach() }
        timer.resume()
        rescanTimer = timer
    }

    private func disarmRescanTimer() {
        rescanTimer?.cancel()
        rescanTimer = nil
    }

    /// Idempotent: find device → sink stream → queue → start. Called on
    /// workQueue from start(), the device-list listener, and the rescan timer.
    private func attemptAttach() {
        let attached = lock.withLock { _sinkQueue != nil }
        if attached {
            // Verify our device is still present (extension unload/upgrade).
            if findPrismDevice() == nil {
                logger.warning("Prism device vanished; tearing down and re-searching")
                teardownStream()
                lifecycle.detach()
                state = .extensionNotInstalled
            }
            return
        }
        guard state != .stopped else { return }

        guard let device = findPrismDevice() else {
            state = .extensionNotInstalled
            return
        }
        guard let sink = findSinkStream(device: device) else {
            state = .failed(.sinkStreamNotFound)
            return
        }

        // Copy the sink stream's buffer queue. The returned queue is created
        // with +1 retain ("Copy" rule) — takeRetainedValue balances it.
        var queueRef: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(
            sink,
            VirtualCameraFeeder.queueAlteredProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &queueRef
        )
        guard copyStatus == noErr, let queue = queueRef?.takeRetainedValue() else {
            state = .failed(.bufferQueueUnavailable(copyStatus))
            return
        }

        // Start the sink stream so the extension begins its consume loop.
        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            state = .failed(.startStreamFailed(startStatus))
            return
        }

        deviceID = device
        sinkStreamID = sink
        streamStarted = true
        lock.withLockUnchecked { _sinkQueue = queue }
        lifecycle.attach()
        logger.info("attached: device \(device) sink stream \(sink) queue capacity \(CMSimpleQueueGetCapacity(queue))")
        state = .feeding
    }

    /// Stop the stream, drop the queue, and release any sample buffers we
    /// retained on enqueue that were never consumed.
    private func teardownStream() {
        let queue: CMSimpleQueue? = lock.withLockUnchecked {
            let q = _sinkQueue
            _sinkQueue = nil
            _formatDescription = nil
            return q
        }
        if streamStarted {
            let status = CMIODeviceStopStream(deviceID, sinkStreamID)
            if status != noErr { logger.warning("CMIODeviceStopStream: \(status)") }
            streamStarted = false
        }
        if let queue {
            // Unregister our queueAlteredProc (header contract: pass NULL to
            // unregister; the freshly copied queue must also be released,
            // which Swift's takeRetainedValue does for us).
            var replacement: Unmanaged<CMSimpleQueue>?
            if CMIOStreamCopyBufferQueue(sinkStreamID, nil, nil, &replacement) == noErr {
                _ = replacement?.takeRetainedValue()
            }
            // Drain buffers we enqueued (each carries our +1 retain).
            while let element = CMSimpleQueueDequeue(queue) {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            }
        }
        deviceID = 0
        sinkStreamID = 0
    }

    // MARK: DAL property helpers (the fiddly C bridging, kept in one place)

    /// All Prism queries are global-scope / main-element.
    private func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    /// Fetch a variable-length array of CMIOObjectIDs (device or stream lists).
    private func objectIDs(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var addr = address(selector)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, dataSize, &dataUsed, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    /// Fetch a CFString property (e.g. the device UID). The DAL hands back a
    /// +1-retained CFString; binding through Unmanaged keeps ARC honest.
    private func stringProperty(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var addr = address(selector)
        var unmanaged: Unmanaged<CFString>?
        var dataUsed: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &dataUsed, pointer)
        }
        guard status == noErr, let value = unmanaged?.takeRetainedValue() else { return nil }
        return value as String
    }

    private func uint32Property(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            object, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value
        )
        return status == noErr ? value : nil
    }

    /// Scan kCMIOHardwarePropertyDevices for our device UID.
    private func findPrismDevice() -> CMIOObjectID? {
        let devices = objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        return devices.first { device in
            stringProperty(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == PrismVCamConstants.deviceUID
        }
    }

    /// Identify the sink stream. Primary signal: kCMIOStreamPropertyDirection
    /// — "0 means output stream, 1 means input stream" (CMIOHardwareStream.h),
    /// where directions are client-relative: a camera's capture feed is an
    /// *input* (1) and a sink we push into is an *output* (0). This matches
    /// the CMIOExtension docs, which say the sink-stream properties translate
    /// to the kCMIOStreamPropertyOutput* DAL properties.
    /// Fallback: our extension adds source first, sink second, so index 1.
    private func findSinkStream(device: CMIOObjectID) -> CMIOObjectID? {
        let streams = objectIDs(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        guard !streams.isEmpty else { return nil }
        if let sink = streams.first(where: { uint32Property(of: $0, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)) == 0 }) {
            return sink
        }
        logger.warning("no stream reports direction==0; falling back to stream order (sink added second)")
        return streams.count >= 2 ? streams[1] : nil
    }

    // MARK: Sample buffer wrapping

    /// Wrap a program frame in a CMSampleBuffer. PTS passes through untouched
    /// — it is already house time (AGENTS.md §5), and the extension's streams
    /// run on the host clock, which is the same clock.
    private func makeSampleBuffer(for frame: VideoFrame) -> CMSampleBuffer? {
        // Cache the format description across frames of identical format.
        var description: CMVideoFormatDescription? = lock.withLock { _formatDescription }
        if let cached = description,
           !CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: frame.pixelBuffer) {
            description = nil
        }
        if description == nil {
            var fresh: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &fresh
            ) == noErr, let fresh else { return nil }
            lock.withLock { _formatDescription = fresh }
            description = fresh
        }
        var timing = CMSampleTimingInfo(
            duration: frame.duration.isNumeric
                ? frame.duration
                : CMTime(value: 1, timescale: PrismVCamConstants.frameRate),
            presentationTimeStamp: frame.pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: description!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
