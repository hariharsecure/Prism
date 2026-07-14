import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os
import PrismCore

/// Device source for the one "Prism Camera" device. Owns the two streams and
/// all the (deliberately minimal — DESIGN.md §3.6 "keep it dumb") logic:
///
///  - SINK → SOURCE mirror: buffers the host app pushes into the sink stream
///    are re-sent on the source stream untouched (CMSampleBuffers carrying
///    IOSurfaces — zero-copy across the process boundary).
///  - Placeholder: while any source client is streaming but the sink is
///    silent (app not running / not sending), a 30 fps timer serves a cached
///    branded card so client apps never stall. The card is rendered ONCE per
///    pixel format; the timer only re-stamps timestamps.
final class PrismExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: PrismExtensionStreamSource!
    private var sinkStream: PrismExtensionStreamSink!

    private let logger = EngineLog.logger("vcam.ext.device")

    /// All mutable state below is confined to `stateLock`. CMIOExtension
    /// callbacks arrive on the provider's clientQueue; the placeholder timer
    /// fires on its own queue.
    private let stateLock = OSAllocatedUnfairLock()
    private var _activeFormatIndex = 0
    private var _frameDuration = CMTime(value: 1, timescale: PrismVCamConstants.frameRate)
    private var _sourceClientCount = 0
    private var _sinkStreaming = false
    private var _lastSinkFrameHostSeconds: Double = 0
    private var _placeholderCache: [Int: (CVPixelBuffer, CMVideoFormatDescription)] = [:] // format index → card

    private var placeholderTimer: DispatchSourceTimer?
    private let placeholderQueue = DispatchQueue(label: "studio.prism.vcam.placeholder", qos: .userInteractive)

    /// Converts a mirrored program frame to the client-negotiated active format
    /// before it is sent on the source stream (sol #5 #6).
    private let formatConverter = VCamFormatConverter()

    /// One format description per entry in `formats` (index-aligned).
    private let formatDescriptions: [CMVideoFormatDescription]
    private let streamFormats: [CMIOExtensionStreamFormat]

    // MARK: - Advertised format descriptions

    /// Build the `CMVideoFormatDescription` for one advertised vcam pixel format
    /// at the fixed vcam canvas. sol #5 #12: the 10-bit (`l10r`) format carries
    /// Rec.2020 primaries / BT.2100-HLG transfer / Rec.2020 matrix color
    /// extensions so its negotiation declares HDR colorimetry (not just a wider
    /// bit-depth); the 8-bit formats are advertised with no color extensions
    /// (SDR — a client tags them as its default, historically sRGB/709). Static
    /// + pure so the format set is unit-testable without the CMIO host runtime.
    static func makeFormatDescription(for codec: OSType) -> CMVideoFormatDescription? {
        var extensions: CFDictionary?
        if codec == PrismVCamConstants.pixelFormat10bit {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ] as CFDictionary
        }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: Int32(PrismVCamConstants.width),
            height: Int32(PrismVCamConstants.height),
            extensions: extensions,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }

    // MARK: - Placeholder freshness gate (sol #7 #9)

    /// The placeholder card should send when a source client is streaming AND the sink
    /// hasn't delivered a real frame within `staleness`. Sink freshness
    /// (`_lastSinkFrameHostSeconds`) is advanced ONLY by a SUCCESSFUL send in
    /// `mirrorToSource` — so a run of DROPPED conversions lets the sink go stale and the
    /// placeholder ENGAGES (instead of the client freezing on the last good frame). Pure
    /// / static so the gate is unit-testable without the CMIO host runtime.
    static func placeholderShouldSend(sourceClientCount: Int, now: Double,
                                      lastSinkFrameHostSeconds: Double, staleness: Double) -> Bool {
        sourceClientCount > 0 && (now - lastSinkFrameHostSeconds) > staleness
    }

    #if DEBUG
    /// NEGATIVE CONTROL (sol #7 #9): reproduce the pre-fix behaviour where `mirrorToSource`
    /// refreshed sink freshness BEFORE the conversion (i.e. even for a DROPPED frame),
    /// pinning `placeholderShouldSend` shut so the placeholder never engaged during a run
    /// of conversion failures.
    static var _test_refreshFreshnessBeforeConversion = false
    #endif

    // MARK: - Init

    override init() {
        // Build the advertised formats: 1920×1080 BGRA (index 0, default),
        // 420v (index 1), and 10-bit ARGB2101010 (index 2, the HDR program),
        // frame rates 30…60 (min duration 1/60, max 1/30 — the 30 fps
        // placeholder cadence stays in-spec).
        var descs: [CMVideoFormatDescription] = []
        for codec in PrismVCamConstants.advertisedPixelFormats {
            guard let desc = PrismExtensionDeviceSource.makeFormatDescription(for: codec) else {
                fatalError("CMVideoFormatDescriptionCreate failed for codec \(codec)")
            }
            descs.append(desc)
        }
        formatDescriptions = descs
        streamFormats = descs.map {
            CMIOExtensionStreamFormat(
                formatDescription: $0,
                maxFrameDuration: CMTime(value: 1, timescale: PrismVCamConstants.placeholderFrameRate),
                minFrameDuration: CMTime(value: 1, timescale: PrismVCamConstants.frameRate),
                validFrameDurations: nil
            )
        }
        super.init()

        device = CMIOExtensionDevice(
            localizedName: PrismVCamConstants.deviceName,
            deviceID: PrismVCamConstants.deviceID,
            legacyDeviceID: PrismVCamConstants.deviceUID, // DAL device UID the feeder matches on
            source: self
        )
        sourceStream = PrismExtensionStreamSource(formats: streamFormats, deviceSource: self)
        sinkStream = PrismExtensionStreamSink(formats: streamFormats, deviceSource: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams to Prism Camera device: \(error)")
        }
    }

    // MARK: - Shared stream state (accessed by both stream sources)

    var activeFormatIndex: Int {
        get { stateLock.withLock { _activeFormatIndex } }
        set { stateLock.withLock { _activeFormatIndex = newValue } }
    }

    var frameDuration: CMTime {
        get { stateLock.withLock { _frameDuration } }
        set { stateLock.withLock { _frameDuration = newValue } }
    }

    // MARK: - CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) {
            deviceProperties.model = PrismVCamConstants.deviceModel
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // Nothing settable.
    }

    // MARK: - Source stream lifecycle

    func sourceStreamStarted() {
        let clientCount = stateLock.withLock { () -> Int in
            _sourceClientCount += 1
            return _sourceClientCount
        }
        logger.info("source stream started (streaming clients now \(clientCount))")
        if clientCount == 1 { startPlaceholderTimer() }
    }

    func sourceStreamStopped() {
        let becameIdle = stateLock.withLock {
            _sourceClientCount = max(0, _sourceClientCount - 1)
            return _sourceClientCount == 0
        }
        logger.info("source stream stopped")
        if becameIdle { stopPlaceholderTimer() }
    }

    // MARK: - Sink stream lifecycle + consume loop

    func sinkStreamStarted(client: CMIOExtensionClient) {
        stateLock.withLock {
            _sinkStreaming = true
            _lastSinkFrameHostSeconds = 0
        }
        logger.info("sink stream started; beginning consume loop")
        consumeNextBuffer(from: client)
    }

    func sinkStreamStopped() {
        stateLock.withLock {
            _sinkStreaming = false
            _lastSinkFrameHostSeconds = 0
        }
        logger.info("sink stream stopped; placeholder resumes if source clients remain")
    }

    /// Self-rescheduling consume loop: each completed consume immediately
    /// requests the next buffer (the CMIOExtension flow-control idiom — the
    /// completion fires when the client has enqueued a buffer for us).
    private func consumeNextBuffer(from client: CMIOExtensionClient) {
        guard stateLock.withLock({ _sinkStreaming }) else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            guard let self else { return }
            _ = hasMoreSampleBuffers
            if let error {
                // Client gone or stream torn down; the loop ends here and is
                // restarted by the next sinkStreamStarted.
                self.logger.error("consumeSampleBuffer failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let sampleBuffer {
                self.mirrorToSource(sampleBuffer, discontinuity: discontinuity)
                // Tell the feeder its buffer was output (drives DAL queue
                // accounting on the host side).
                let nowNs = UInt64(HouseClock.nowSeconds() * Double(NSEC_PER_SEC))
                self.sinkStream.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: nowNs)
                )
            }
            self.consumeNextBuffer(from: client)
        }
    }

    /// Re-send a sink buffer on the source stream, CONVERTED to the client's
    /// negotiated active format (sol #5 #6). The program frame is BGRA (SDR) or
    /// 10-bit `l10r` (HDR) regardless of what the client selected; sending it
    /// untouched would violate CMIO's active-format contract whenever the two
    /// disagree, so we convert (bit-depth + chroma) to the negotiated format.
    /// When they already match (the common case) the converter passes the buffer
    /// through untouched — no copy. PTS is already house time (the feeder stamps
    /// the program frame's PTS; house clock == host clock == this stream's
    /// .hostTime clockType).
    private func mirrorToSource(_ sampleBuffer: CMSampleBuffer, discontinuity: CMIOExtensionStream.DiscontinuityFlags) {
        let (hasSourceClients, formatIndex) = stateLock.withLock { () -> (Bool, Int) in
            // sol #7 #9: do NOT refresh sink freshness here (before the conversion). See
            // the refresh AFTER a successful send below. The negative-control seam
            // reproduces the pre-fix early refresh that pinned the placeholder gate shut.
            #if DEBUG
            if PrismExtensionDeviceSource._test_refreshFreshnessBeforeConversion {
                _lastSinkFrameHostSeconds = HouseClock.nowSeconds()
            }
            #endif
            return (_sourceClientCount > 0, _activeFormatIndex)
        }
        guard hasSourceClients else { return }
        let formats = PrismVCamConstants.advertisedPixelFormats
        let targetFormat = formats.indices.contains(formatIndex) ? formats[formatIndex] : formats[0]
        // sol #6 #4: on a conversion FAILURE, DROP this frame — never fall back to
        // sending the original wrong-format sample (that hands the client a buffer
        // whose real pixel format / dynamic range is not the one it negotiated). The
        // placeholder timer covers any resulting gap; the next frame reconverts.
        guard let outgoing = formatConverter.makeSampleBuffer(from: sampleBuffer, targetFormat: targetFormat) else {
            logger.error("format conversion to \(targetFormat) failed; dropping frame (not sending wrong-format sample)")
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(outgoing)
        let hostNs = pts.isNumeric ? UInt64(max(0, pts.seconds) * Double(NSEC_PER_SEC))
                                   : UInt64(HouseClock.nowSeconds() * Double(NSEC_PER_SEC))
        sourceStream.stream.send(outgoing, discontinuity: discontinuity, hostTimeInNanoseconds: hostNs)
        // sol #7 #9: advance sink freshness ONLY on a SUCCESSFUL send. Pre-fix this ran at
        // the top (before conversion), so a run of DROPPED conversions kept the sink
        // "fresh" and `placeholderShouldSend` never engaged — the client saw a frozen last
        // frame instead of the placeholder card. Refreshing only here lets repeated drops
        // go stale → the placeholder engages.
        stateLock.withLock { _lastSinkFrameHostSeconds = HouseClock.nowSeconds() }
    }

    // MARK: - Placeholder generator

    private func startPlaceholderTimer() {
        placeholderQueue.async { [weak self] in
            guard let self, self.placeholderTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.placeholderQueue)
            let interval = 1.0 / Double(PrismVCamConstants.placeholderFrameRate)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.placeholderTick() }
            timer.resume()
            self.placeholderTimer = timer
            self.logger.info("placeholder timer armed at \(PrismVCamConstants.placeholderFrameRate) fps")
        }
    }

    private func stopPlaceholderTimer() {
        placeholderQueue.async { [weak self] in
            guard let self else { return }
            self.placeholderTimer?.cancel()
            self.placeholderTimer = nil
            self.logger.info("placeholder timer disarmed")
        }
    }

    /// Runs at 30 fps whenever any source client is streaming. Sends the card
    /// only while the sink is stale (no real frame for > 0.5 s) — covering
    /// "app not running", "app wedged", and the startup gap, and yielding
    /// within one placeholder period once real frames flow.
    private func placeholderTick() {
        let now = HouseClock.nowSeconds()
        let (shouldSend, formatIndex): (Bool, Int) = stateLock.withLock {
            let send = Self.placeholderShouldSend(
                sourceClientCount: _sourceClientCount, now: now,
                lastSinkFrameHostSeconds: _lastSinkFrameHostSeconds,
                staleness: PrismVCamConstants.sinkStalenessSeconds)
            return (send, _activeFormatIndex)
        }
        guard shouldSend else { return }
        guard let (card, formatDescription) = placeholderBuffer(formatIndex: formatIndex) else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: PrismVCamConstants.placeholderFrameRate),
            presentationTimeStamp: HouseClock.now(),
            decodeTimeStamp: .invalid
        )
        // The card buffer is immutable after render, so sharing one buffer
        // (and its cached format description) across sends is safe; each
        // send just gets a fresh sample buffer + PTS.
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: card,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        sourceStream.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        )
    }

    /// Lazily render + cache the card for a format index (cold path; see
    /// PlaceholderRenderer header comment for the zero-copy justification).
    private func placeholderBuffer(formatIndex: Int) -> (CVPixelBuffer, CMVideoFormatDescription)? {
        // withLockUnchecked: CVPixelBuffer is not Sendable, but the cached card
        // is immutable after render — sharing the reference is safe.
        if let cached = stateLock.withLockUnchecked({ _placeholderCache[formatIndex] }) { return cached }
        do {
            let bgraPool = try PixelBufferPool(
                width: PrismVCamConstants.width,
                height: PrismVCamConstants.height,
                pixelFormat: PrismVCamConstants.pixelFormatBGRA,
                minimumBufferCount: 1
            )
            let bgra = try PlaceholderRenderer.renderBGRA(
                width: PrismVCamConstants.width, height: PrismVCamConstants.height, pool: bgraPool
            )
            let card: CVPixelBuffer
            switch formatIndex {
            case 1:
                let pool420 = try PixelBufferPool(
                    width: PrismVCamConstants.width,
                    height: PrismVCamConstants.height,
                    pixelFormat: PrismVCamConstants.pixelFormat420v,
                    minimumBufferCount: 1
                )
                card = try PlaceholderRenderer.convert420v(from: bgra, pool: pool420)
            case 2:
                let pool10 = try PixelBufferPool(
                    width: PrismVCamConstants.width,
                    height: PrismVCamConstants.height,
                    pixelFormat: PrismVCamConstants.pixelFormat10bit,
                    minimumBufferCount: 1
                )
                card = try PlaceholderRenderer.convert10bit(from: bgra, pool: pool10)
            default:
                card = bgra
            }
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: card, formatDescriptionOut: &description
            ) == noErr, let description else { return nil }
            let entry = (card, description)
            stateLock.withLockUnchecked { _placeholderCache[formatIndex] = entry }
            return entry
        } catch {
            logger.error("placeholder render failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
