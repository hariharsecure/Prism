import CoreMIDI
import Foundation
import PrismCore

/// CoreMIDI client that surfaces every connected MIDI source as a stream of
/// clean ``MIDIMessage`` values.
///
/// It creates a MIDI client (with a notification block for hot-plug), an input
/// port connected to all current sources, and a virtual destination (so other
/// apps / IAC can drive Prism too). Incoming ``MIDIPacketList``s are parsed on
/// CoreMIDI's high-priority receive thread and delivered via ``onMessage``.
///
/// Threading: ``onMessage`` fires on CoreMIDI's receive thread — the consumer
/// must be prepared for that. The engine's own mutable state (per-source
/// parsers, connected-source set) is guarded by a lock.
///
/// Verification note: the packet-parsing path (``parse(packetList:source:)``)
/// is pure and exercised headlessly by ``ControlSurfaceSelfTest`` using
/// synthetic ``MIDIPacketList``s. Creating a real `MIDIClientRef` is attempted
/// by the self-test and reported, but full hardware round-trips are UNVERIFIED.
public final class MIDIEngine: @unchecked Sendable {
    public enum MIDIEngineError: Error, CustomStringConvertible {
        case clientCreateFailed(OSStatus)
        case inputPortCreateFailed(OSStatus)
        case virtualDestinationCreateFailed(OSStatus)
        public var description: String {
            switch self {
            case .clientCreateFailed(let s): return "MIDIClientCreateWithBlock failed: \(s)"
            case .inputPortCreateFailed(let s): return "MIDIInputPortCreateWithBlock failed: \(s)"
            case .virtualDestinationCreateFailed(let s): return "MIDIDestinationCreateWithBlock failed: \(s)"
            }
        }
    }

    private let log = EngineLog.logger("controlsurface.midi")
    private let clientName: String

    /// Called for every parsed message, on CoreMIDI's receive thread.
    public var onMessage: ((MIDIMessage) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var virtualDest = MIDIEndpointRef()
    private var started = false

    private let lock = NSLock()
    /// One parser per source endpoint (keyed by endpoint ref; 0 = virtual dest)
    /// so running status never bleeds across devices.
    private var parsers: [MIDIEndpointRef: MIDIStreamParser] = [:]
    private var connectedSources: Set<MIDIEndpointRef> = []

    public init(clientName: String = "PrismControlSurface") {
        self.clientName = clientName
    }

    // MARK: Lifecycle

    /// Create the CoreMIDI client, input port and virtual destination, and
    /// connect to all current sources. Idempotent.
    public func start() throws {
        guard !started else { return }

        // Client with a notification block for hot-plug (add/remove).
        var status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            self?.handleNotification(notification)
        }
        guard status == noErr else { throw MIDIEngineError.clientCreateFailed(status) }

        // Input port: receives from connected physical/virtual sources.
        status = MIDIInputPortCreateWithBlock(client, "\(clientName) In" as CFString, &inputPort) { [weak self] packetList, srcConnRefCon in
            let source = MIDIEndpointRef(UInt(bitPattern: srcConnRefCon))
            self?.receive(packetList, source: source)
        }
        guard status == noErr else {
            MIDIClientDispose(client)
            client = MIDIClientRef()
            throw MIDIEngineError.inputPortCreateFailed(status)
        }

        // Virtual destination: lets other apps / IAC send into Prism.
        status = MIDIDestinationCreateWithBlock(client, "\(clientName)" as CFString, &virtualDest) { [weak self] packetList, _ in
            self?.receive(packetList, source: 0)
        }
        guard status == noErr else {
            MIDIPortDispose(inputPort)
            inputPort = MIDIPortRef()
            MIDIClientDispose(client)
            client = MIDIClientRef()
            throw MIDIEngineError.virtualDestinationCreateFailed(status)
        }

        started = true
        connectAllSources()
        log.info("MIDIEngine started (client=\(self.client), sources connected=\(self.connectedSources.count))")
    }

    /// Disconnect, dispose all CoreMIDI objects, and reset. Idempotent.
    public func stop() {
        guard started else { return }
        lock.lock()
        for source in connectedSources {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources.removeAll()
        parsers.removeAll()
        lock.unlock()

        if virtualDest != 0 { MIDIEndpointDispose(virtualDest); virtualDest = MIDIEndpointRef() }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = MIDIPortRef() }
        if client != 0 { MIDIClientDispose(client); client = MIDIClientRef() }
        started = false
        log.info("MIDIEngine stopped")
    }

    deinit {
        stop()
    }

    /// Number of currently connected input sources.
    public var connectedSourceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connectedSources.count
    }

    // MARK: Source connection / hot-plug

    private func connectAllSources() {
        guard started else { return }
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }

            // Atomically RESERVE the source before connecting: `insert` under the
            // lock returns `inserted == false` if it is already present (or a
            // concurrent hot-plug notification just reserved it), so we never
            // issue a second `MIDIPortConnectSource` for the same endpoint (#10).
            // The reservation is inserted *before* the connect call — the earlier
            // check-unlock-connect-relock left a window in which start() and a
            // hot-plug callback could both pass the check and double-connect.
            lock.lock()
            let reserved = connectedSources.insert(source).inserted
            lock.unlock()
            guard reserved else { continue }

            // Pass the source endpoint itself as the connection refCon so the
            // receive block can key its parser by source.
            let refCon = UnsafeMutableRawPointer(bitPattern: UInt(source))
            let status = MIDIPortConnectSource(inputPort, source, refCon)
            if status == noErr {
                log.debug("connected MIDI source \(source)")
            } else {
                // Connect failed — release the reservation so a later re-scan can
                // retry this source.
                lock.lock()
                connectedSources.remove(source)
                lock.unlock()
                log.error("MIDIPortConnectSource failed for \(source): \(status)")
            }
        }
    }

    private func handleNotification(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
        case .msgObjectAdded, .msgObjectRemoved:
            // A device/entity/endpoint changed. Re-scan and connect any new
            // sources; dropped sources are cleaned lazily (their parser simply
            // stops receiving). This is the MIDIObjectAddRemoveNotification path.
            connectAllSources()
        case .msgSetupChanged:
            connectAllSources()
        default:
            break
        }
    }

    // MARK: Receive path

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>, source: MIDIEndpointRef) {
        let messages = parse(packetList: packetList, source: source)
        if let onMessage {
            for m in messages { onMessage(m) }
        }
    }

    /// Parse a ``MIDIPacketList`` into messages, advancing the running-status
    /// parser for `source`. Public so the self-test can feed synthetic lists.
    public func parse(packetList: UnsafePointer<MIDIPacketList>, source: MIDIEndpointRef) -> [MIDIMessage] {
        lock.lock()
        var parser = parsers[source] ?? MIDIStreamParser()
        lock.unlock()

        var out: [MIDIMessage] = []
        MIDIEngine.forEachPacket(in: packetList) { bytes in
            out.append(contentsOf: parser.parse(bytes))
        }

        lock.lock()
        parsers[source] = parser
        lock.unlock()
        return out
    }

    /// Iterate the packets in a ``MIDIPacketList``, yielding each packet's MIDI
    /// bytes. Walks the *original* list memory (via `MIDIPacketNext`) rather
    /// than a by-value copy, so multi-packet lists are handled correctly.
    static func forEachPacket(in list: UnsafePointer<MIDIPacketList>, _ body: ([UInt8]) -> Void) {
        let numPackets = Int(list.pointee.numPackets)
        guard numPackets > 0 else { return }

        // Address of the first MIDIPacket *inside the list's memory*.
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        var packetPtr = UnsafeRawPointer(list)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)

        for _ in 0..<numPackets {
            let length = Int(packetPtr.pointee.length)
            let bytes = withUnsafeBytes(of: packetPtr.pointee.data) { raw -> [UInt8] in
                Array(raw.prefix(length))
            }
            body(bytes)
            packetPtr = UnsafePointer(MIDIPacketNext(packetPtr))
        }
    }
}
