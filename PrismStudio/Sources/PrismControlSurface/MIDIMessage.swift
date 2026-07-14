import Foundation

/// A parsed, channel-voice MIDI message — the clean value the rest of the
/// control-surface layer works with (never raw bytes).
///
/// All indices are as they arrive on the wire: `channel` is 0–15,
/// `note`/`cc`/`velocity`/`value`/`program` are 0–127, and `pitchBend` is a
/// 14-bit value 0–16383 (8192 = centre).
public enum MIDIMessage: Equatable, Sendable {
    case noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    case noteOff(note: UInt8, velocity: UInt8, channel: UInt8)
    case controlChange(cc: UInt8, value: UInt8, channel: UInt8)
    case programChange(program: UInt8, channel: UInt8)
    /// 14-bit bend value (0–16383, 8192 = centre).
    case pitchBend(value: UInt16, channel: UInt8)
}

/// Which physical edge an incoming message represents, for button-style actions.
public enum MIDIEdge: Sendable {
    /// Press / value in the "on" half (noteOn, CC ≥ 64, programChange, bend).
    case down
    /// Release / value in the "off" half (noteOff, noteOn velocity 0, CC < 64).
    case up
}

public extension MIDIMessage {
    /// A message decomposed into the pieces the action map needs: the
    /// value-independent `trigger` that identifies the control, the normalized
    /// 0–1 `value` (for faders/continuous), and the `edge` (for buttons).
    var decomposed: (trigger: MIDITrigger, value: Double, edge: MIDIEdge) {
        switch self {
        case let .noteOn(note, velocity, channel):
            let up = velocity == 0
            return (.note(note: note, channel: channel),
                    Double(velocity) / 127.0,
                    up ? .up : .down)
        case let .noteOff(note, _, channel):
            return (.note(note: note, channel: channel), 0, .up)
        case let .controlChange(cc, value, channel):
            return (.cc(cc: cc, channel: channel),
                    Double(value) / 127.0,
                    value >= 64 ? .down : .up)
        case let .programChange(program, channel):
            return (.programChange(program: program, channel: channel), 1, .down)
        case let .pitchBend(value, channel):
            return (.pitchBend(channel: channel),
                    Double(value) / 16383.0,
                    .down)
        }
    }
}

/// The value-independent identity of a control, used as the binding key in
/// ``MIDIActionMap``. A fader binding matches every CC value; a note binding
/// matches both the press and the release of that note.
public enum MIDITrigger: Hashable, Codable, Sendable {
    case note(note: UInt8, channel: UInt8)
    case cc(cc: UInt8, channel: UInt8)
    case programChange(program: UInt8, channel: UInt8)
    case pitchBend(channel: UInt8)
}

/// Incremental parser for a raw MIDI byte stream into ``MIDIMessage`` values.
///
/// Pure and self-contained (no CoreMIDI) so it is fully unit-testable. It
/// implements MIDI running status and ignores System Real-Time bytes
/// (0xF8–0xFF) without disturbing the running status, exactly as a hardware
/// receiver must. Aftertouch (0xA0/0xD0), System Common and SysEx are consumed
/// but not surfaced (not part of the control-surface vocabulary).
///
/// One parser instance is kept per MIDI source so running status from one
/// device never bleeds into another.
public struct MIDIStreamParser: Sendable {
    private var status: UInt8 = 0          // current running-status byte (0 = none)
    private var expected: Int = 0          // data bytes expected for `status`
    private var pending: [UInt8] = []      // data bytes collected so far

    public init() {}

    /// Feed the next chunk of bytes; returns any messages completed by them.
    public mutating func parse<S: Sequence>(_ bytes: S) -> [MIDIMessage] where S.Element == UInt8 {
        var out: [MIDIMessage] = []
        for b in bytes {
            if b >= 0xF8 {
                // System Real-Time: single byte, does not affect running status.
                continue
            }
            if b >= 0x80 {
                // Status byte.
                if b >= 0xF0 {
                    // System Common / SysEx start: cancels running status.
                    status = 0
                    expected = 0
                    pending.removeAll(keepingCapacity: true)
                    continue
                }
                status = b
                expected = Self.dataByteCount(for: b)
                pending.removeAll(keepingCapacity: true)
            } else {
                // Data byte.
                guard status != 0 else { continue } // no running status yet
                pending.append(b)
                if pending.count == expected {
                    if let msg = Self.message(status: status, data: pending) {
                        out.append(msg)
                    }
                    pending.removeAll(keepingCapacity: true) // keep running status
                }
            }
        }
        return out
    }

    private static func dataByteCount(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1   // program change, channel aftertouch
        default: return 2           // note off/on, poly aftertouch, CC, pitch bend
        }
    }

    private static func message(status: UInt8, data: [UInt8]) -> MIDIMessage? {
        let channel = status & 0x0F
        switch status & 0xF0 {
        case 0x80:
            return .noteOff(note: data[0], velocity: data[1], channel: channel)
        case 0x90:
            // Note-on with velocity 0 is, by convention, a note-off.
            return data[1] == 0
                ? .noteOff(note: data[0], velocity: 0, channel: channel)
                : .noteOn(note: data[0], velocity: data[1], channel: channel)
        case 0xB0:
            return .controlChange(cc: data[0], value: data[1], channel: channel)
        case 0xC0:
            return .programChange(program: data[0], channel: channel)
        case 0xE0:
            // LSB first, 7 bits each.
            let value = UInt16(data[0]) | (UInt16(data[1]) << 7)
            return .pitchBend(value: value, channel: channel)
        case 0xA0, 0xD0:
            return nil // aftertouch — not surfaced
        default:
            return nil
        }
    }
}
