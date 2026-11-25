import CoreMIDI
import Foundation

/// Morningstar's SysEx API for external apps (help.morningstar.io,
/// "SysEx Documentation for External Applications"). Layout, 0-based:
///   F0 00 21 24 <model> 00 70 op2 op3 op4 op5 op6 op7 <txn> 00 00 <payload…> <checksum> F7
/// checksum = XOR of every byte before it (F0 included) & 0x7F.
/// Nothing here is ever saved on the pedal: the save flag is left at 00, so
/// every change reverts when the pedal changes bank.
enum Morningstar {
    static let modelMC4PRO: UInt8 = 0x09
    static let nameLength = 32          // PRO series: short, toggle, long and bank names
    static let lcdLength = 20

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 ^ $1 } & 0x7F
    }

    static func message(_ op2: UInt8, op3: UInt8 = 0, op4: UInt8 = 0, op5: UInt8 = 0, op6: UInt8 = 0,
                        op7: UInt8 = 0, txn: UInt8 = 0, payload: [UInt8] = [], model: UInt8 = modelMC4PRO) -> [UInt8] {
        var b: [UInt8] = [0xF0, 0x00, 0x21, 0x24, model, 0x00, 0x70, op2, op3, op4, op5, op6, op7, txn, 0x00, 0x00]
        b += payload
        b.append(checksum(b))
        b.append(0xF7)
        return b
    }

    /// Printable ASCII only (the pedal's font), padded with spaces to `length`
    /// when `pad` is set.
    static func ascii(_ text: String, length: Int, pad: Bool) -> [UInt8] {
        var s = text
        for (from, to) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("…", "...")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        var out = s.unicodeScalars.map { (32..<127).contains($0.value) ? UInt8($0.value) : UInt8(ascii: "?") }
        if out.count > length { out = Array(out.prefix(length)) }
        if pad { out += [UInt8](repeating: 32, count: length - out.count) }
        return out
    }

    enum NameKind: UInt8 { case short = 0x01, toggle = 0x02, long = 0x03 }

    static func setName(_ kind: NameKind, preset: Int, _ text: String) -> [UInt8] {
        message(kind.rawValue, op3: UInt8(preset), payload: ascii(text, length: nameLength, pad: true))
    }

    static func getName(_ kind: NameKind, preset: Int, txn: UInt8 = 0) -> [UInt8] {
        message(kind.rawValue + 0x20, op3: UInt8(preset), txn: txn)
    }

    static func setBankName(_ text: String) -> [UInt8] {
        message(0x10, payload: ascii(text, length: nameLength, pad: true))
    }

    /// Temporary message on the LCD; duration in tenths of a second (max 127).
    static func lcd(_ text: String, tenths: Int = 20) -> [UInt8] {
        message(0x11, op4: UInt8(max(1, min(127, tenths))), payload: ascii(text, length: lcdLength, pad: false))
    }

    /// Opcode 0x05 "other data": the PRO's LED / text / background colours.
    /// The first four payload bytes (toggle mode, blink, scroll, toggle group)
    /// are sent as 0x7E = leave alone.
    static func colours(preset: Int, led: UInt8, ledToggle: UInt8 = 0, text: UInt8 = 7, background: UInt8 = 0) -> [UInt8] {
        let keep: UInt8 = 0x7E
        return message(0x05, op3: UInt8(preset),
                       payload: [keep, keep, keep, keep,
                                 led, ledToggle, led,
                                 text, text, text,
                                 background, background, background])
    }

    static func controllerInfo() -> [UInt8] { message(0x32) }
    static func currentBankName() -> [UInt8] { message(0x30) }

    struct Reply {
        let op2: UInt8, op3: UInt8, op4: UInt8, txn: UInt8
        let payload: [UInt8]
        var text: String { String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespaces) }
        var isError: Bool { op2 == 0x7F }
        /// For an error reply: 00 success, 01 wrong model, 02 wrong checksum, 03 wrong payload size.
        var ack: UInt8 { op3 }
    }

    static func parse(_ b: [UInt8]) -> Reply? {
        guard b.count >= 18, b[0] == 0xF0, b[1] == 0x00, b[2] == 0x21, b[3] == 0x24, b[6] == 0x70,
              b.last == 0xF7, checksum(b[0..<(b.count - 2)]) == b[b.count - 2] else { return nil }
        return Reply(op2: b[7], op3: b[8], op4: b[9], txn: b[13], payload: Array(b[16..<(b.count - 2)]))
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension Timer {
    /// A repeating timer on the main run loop in the common modes, so it keeps
    /// firing while the menu is open or an alert is showing. (v2.7: in the
    /// default mode alone they stopped, and so did the messages to the pedal.)
    static func common(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}

/// Runs `work` from the main run loop instead of from a main-queue block. An
/// alert shown inside a DispatchQueue.main block holds up every other
/// main-queue block until it's closed, and every AbleSet update and pedal
/// message arrives as one (v2.7).
func outsideMainQueue(_ work: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.common], block: work)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// CoreMIDI link to the first MIDI endpoint whose name contains `match`
/// ("MC4" by default: Bluetooth shows up as "MC4 PRO … Bluetooth").
/// Messages are paced so a Bluetooth link isn't flooded.
final class PedalMIDI {
    var match = "MC4"
    var onSysex: ([UInt8]) -> Void = { _ in }
    var onControlChange: (_ channel: Int, _ number: Int, _ value: Int) -> Void = { _, _, _ in }
    var onConnectionChange: () -> Void = {}
    var onSendError: (AppError) -> Void = { _ in }
    var onRaw: ([UInt8]) -> Void = { _ in }

    private(set) var destinationName: String?
    private(set) var sourceName: String?
    private(set) var sourceConnectStatus: OSStatus?
    /// Input callbacks seen since launch, counted before any parsing.
    private(set) var callbacks = 0
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var source = MIDIEndpointRef()
    private var sysex: [UInt8] = []
    /// SysEx messages dropped unfinished because another message began (diagnostics).
    private(set) var cutOffSysex = 0
    typealias Queued = (key: String?, bytes: [UInt8])
    private var outbox: [Queued] = []
    private var pump: Timer?
    static let spacing: TimeInterval = 0.03
    static var debug = false

    var isConnected: Bool { destination != 0 }
    /// The port in use is a Bluetooth one (v2.8), so losing it means the pedal dropped off Bluetooth.
    private(set) var destinationIsBluetooth = false
    /// When set, use the MIDI port with exactly this name instead of the first one containing `match`.
    var exactName: String?
    /// Automatic mode only: the port a search found answering (over USB the
    /// MC4 PRO shows Ports 1-4 and only Port 4 answers SysEx; v1.15).
    var autoPick: String?

    /// Destination names that automatic mode would consider.
    func matchingPortNames() -> [String] {
        let wanted = match.lowercased()
        return Self.portNames().filter { $0.lowercased().contains(wanted) }
    }
    private var searchHits: Set<String> = []
    /// Searches listen on their own input port (v2.7), so the pedal's normal
    /// input stays connected and heard while one runs.
    private var searchPort = MIDIPortRef()
    private var searchSources: [MIDIEndpointRef] = []
    private var waitingSearches: [(only: Set<String>?, completion: ([String]) -> Void)] = []
    private(set) var searching = false

    static func containsMorningstarReply(_ b: [UInt8]) -> Bool {
        // A real reply has 01 in byte 5; our own question (00 there) echoing back
        // through a loopback port like the IAC Driver doesn't count.
        guard b.count >= 8 else { return false }
        for i in 0...(b.count - 8) where b[i] == 0xF0 && b[i + 1] == 0x00 && b[i + 2] == 0x21 && b[i + 3] == 0x24
            && b[i + 5] == 0x01 && b[i + 6] == 0x70 { return true }
        return false
    }

    /// Names of every MIDI port the Mac can send to.
    static func portNames() -> [String] {
        Array(Set(endpoints(sources: false).map(name))).sorted()
    }

    /// Asks MIDI ports a Morningstar question ("controller info") and reports
    /// the ports whose matching input answered, within `seconds`. `only` limits
    /// it to ports with those names (the automatic search asks just the pedal's
    /// own ports); nil asks every port. Morningstar SysEx carries Morningstar's
    /// manufacturer ID, so other devices ignore it. A search asked for while
    /// another runs starts when that one ends (v2.7: it used to be dropped, and
    /// "Find Pedal Automatically" stayed on "Searching…").
    func search(only names: Set<String>? = nil, seconds: Double = 2.5, completion: @escaping ([String]) -> Void) {
        guard !searching else { waitingSearches.append((names, completion)); return }
        searching = true
        searchHits = []
        let asked = { (ep: MIDIEndpointRef) in names.map { $0.contains(Self.name(ep)) } ?? true }
        // The refCon is the source itself, not an object: a callback still
        // running after the search ends can't touch freed memory (v2.7).
        for src in Self.endpoints(sources: true) where asked(src) {
            if MIDIPortConnectSource(searchPort, src, UnsafeMutableRawPointer(bitPattern: UInt(src))) == noErr { searchSources.append(src) }
        }
        let question = Morningstar.controllerInfo()
        let ask = { [weak self] in for dest in Self.endpoints(sources: false) where asked(dest) { self?.sendNow(question, to: dest) } }
        ask()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) { ask() }   // ask twice: Bluetooth can drop one
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            for src in self.searchSources { MIDIPortDisconnectSource(self.searchPort, src) }
            self.searchSources = []
            self.searching = false
            let destNames = Set(Self.portNames())
            completion(self.searchHits.filter { destNames.contains($0) }.sorted())
            if !self.waitingSearches.isEmpty {
                let next = self.waitingSearches.removeFirst()
                self.search(only: next.only, completion: next.completion)
            }
        }
    }

    func start() throws {
        var status = MIDIClientCreateWithBlock("MorningstarAblesetBridge" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.rescan() }
        }
        guard status == noErr else { throw AppError(.midiFailed, "MIDIClientCreate \(status)") }
        status = MIDIOutputPortCreate(client, "MorningstarAblesetBridge out" as CFString, &outPort)
        guard status == noErr else { throw AppError(.midiFailed, "MIDIOutputPortCreate \(status)") }
        // The MIDI 1.0 "protocol" input API: the older packet-list API received
        // nothing from the MC4 over Bluetooth (2026-11-24), this one does.
        status = MIDIInputPortCreateWithProtocol(client, "MorningstarAblesetBridge in" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            var bytes: [UInt8] = []
            if PedalMIDI.debug {
                for packet in list.unsafeSequence() {
                    let w = Array(packet.words())
                    FileHandle.standardError.write(Data(("<< UMP " + w.map { String(format: "%08X", $0) }.joined(separator: " ") + "\n").utf8))
                }
            }
            for packet in list.unsafeSequence() {
                bytes += PedalMIDI.bytes(fromUMP: packet)
            }
            DispatchQueue.main.async { self?.callbacks += 1 }
            if !bytes.isEmpty { DispatchQueue.main.async { self?.receive(bytes) } }
        }
        guard status == noErr else { throw AppError(.midiFailed, "MIDIInputPortCreate \(status)") }
        // Port searches: each source is connected with its own endpoint ref as refCon.
        status = MIDIInputPortCreateWithProtocol(client, "MorningstarAblesetBridge search" as CFString, ._1_0, &searchPort) { [weak self] list, refCon in
            let src = MIDIEndpointRef(truncatingIfNeeded: UInt(bitPattern: refCon))
            guard src != 0 else { return }
            var bytes: [UInt8] = []
            for packet in list.unsafeSequence() { bytes += PedalMIDI.bytes(fromUMP: packet) }
            guard PedalMIDI.containsMorningstarReply(bytes) else { return }
            let name = PedalMIDI.name(src)
            DispatchQueue.main.async { self?.searchHits.insert(name) }
        }
        guard status == noErr else { throw AppError(.midiFailed, "MIDIInputPortCreate (search) \(status)") }
        rescan()
    }

    static func name(_ ep: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &s)
        return (s?.takeRetainedValue() as String?) ?? "?"
    }

    /// Turns MIDI 1.0 Universal MIDI Packets back into plain MIDI bytes:
    /// type 1 (system), type 2 (channel voice) and type 3 (SysEx, 6 bytes per packet).
    static func bytes(fromUMP p: UnsafePointer<MIDIEventPacket>) -> [UInt8] {
        // words() reads only this packet's own words. Packets are variable-length:
        // copying p.pointee read a full 64 words, past the end of a short packet (v2.7).
        let words = Array(p.words())
        var out: [UInt8] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            switch w >> 28 {
            case 1:     // system common / real time
                out.append(UInt8((w >> 16) & 0xFF))
                i += 1
            case 2:     // MIDI 1.0 channel voice
                let status = UInt8((w >> 16) & 0xFF)
                out.append(status)
                out.append(UInt8((w >> 8) & 0x7F))
                if status & 0xE0 != 0xC0 { out.append(UInt8(w & 0x7F)) }    // PC / channel pressure have one data byte
                i += 1
            case 3:     // SysEx7, two words
                guard i + 1 < words.count else { return out }
                let w2 = words[i + 1]
                let form = (w >> 20) & 0xF, n = Int((w >> 16) & 0xF)
                let data: [UInt8] = [UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F),
                                     UInt8((w2 >> 24) & 0x7F), UInt8((w2 >> 16) & 0x7F),
                                     UInt8((w2 >> 8) & 0x7F), UInt8(w2 & 0x7F)]
                if form == 0 || form == 1 { out.append(0xF0) }               // complete / start
                out += data.prefix(min(n, 6))
                if form == 0 || form == 3 { out.append(0xF7) }               // complete / end
                i += 2
            default:
                i += [0, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(w >> 28)]
            }
        }
        return out
    }

    static func endpoints(sources: Bool) -> [MIDIEndpointRef] {
        let n = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        return (0..<n).map { sources ? MIDIGetSource($0) : MIDIGetDestination($0) }
    }

    /// Whether a port belongs to macOS's Bluetooth MIDI driver: its name says
    /// Bluetooth ("MC4 PRO … Bluetooth"), or its device's driver does.
    static func isBluetooth(_ ep: MIDIEndpointRef) -> Bool {
        if name(ep).lowercased().contains("bluetooth") { return true }
        var entity = MIDIEntityRef(), device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(ep, &entity) == noErr, entity != 0,
              MIDIEntityGetDevice(entity, &device) == noErr, device != 0 else { return false }
        var owner: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(device, kMIDIPropertyDriverOwner, &owner) == noErr,
              let o = owner?.takeRetainedValue() as String? else { return false }
        return o.lowercased().contains("bluetooth")
    }

    /// Names of the Bluetooth MIDI ports the Mac can send to now.
    static func bluetoothPortNames() -> [String] {
        endpoints(sources: false).filter(isBluetooth).map(name)
    }

    /// Menu "Reconnect to Pedal": drop the current input and output and
    /// connect again from scratch, as if the pedal had just appeared.
    func reconnect() {
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
        source = 0; sourceName = nil; sourceConnectStatus = nil
        destination = 0; destinationName = nil; destinationIsBluetooth = false
        outbox.removeAll()
        sysex = []
        rescan()
        onConnectionChange()
    }

    func rescan() {
        let wanted = match.lowercased()
        let pick = exactName == nil ? autoPick.flatMap { Self.portNames().contains($0) ? $0 : nil } : nil
        let fits: (MIDIEndpointRef) -> Bool = { [exactName] ep in
            if let exact = exactName ?? pick { return Self.name(ep) == exact }
            return Self.name(ep).lowercased().contains(wanted)
        }
        let dest = Self.endpoints(sources: false).first(where: fits) ?? 0
        // Listen to the input that belongs to the same device as the output:
        // the same MIDI entity first, then the same name, then any match.
        // (v1.4: picking them separately sent to Bluetooth while listening to
        // another "MC4" port on Jon's playback laptop, so nothing came back.)
        let sources = Self.endpoints(sources: true)
        var src: MIDIEndpointRef = 0
        if dest != 0 {
            var destEntity = MIDIEntityRef()
            if MIDIEndpointGetEntity(dest, &destEntity) == noErr, destEntity != 0 {
                src = sources.first { var e = MIDIEntityRef(); return MIDIEndpointGetEntity($0, &e) == noErr && e == destEntity } ?? 0
            }
            if src == 0 { src = sources.first { Self.name($0) == Self.name(dest) } ?? 0 }
        }
        if src == 0 { src = sources.first(where: fits) ?? 0 }
        if src != source {
            if source != 0 { MIDIPortDisconnectSource(inPort, source) }
            sysex = []          // half a message from the old input must not swallow the new one's
            sourceConnectStatus = nil
            if src != 0 {
                let st = MIDIPortConnectSource(inPort, src, nil)
                sourceConnectStatus = st
                if PedalMIDI.debug { FileHandle.standardError.write(Data("[debug] connect source \(Self.name(src)) (inPort \(inPort)) -> \(st)\n".utf8)) }
            }
            source = src
            sourceName = src == 0 ? nil : Self.name(src)
        }
        let changed = dest != destination
        destination = dest
        destinationName = dest == 0 ? nil : Self.name(dest)
        if changed { destinationIsBluetooth = dest != 0 && Self.isBluetooth(dest) }
        if dest == 0 { outbox.removeAll() }
        if changed { onConnectionChange() }
    }

    /// Queue one complete MIDI message (SysEx or short). A message with a `key`
    /// replaces a waiting one with the same key, so a quick run of song changes
    /// sends only the newest names instead of every one in between (v2.7).
    func send(_ bytes: [UInt8], key: String? = nil) {
        guard destination != 0 else { return }
        Self.enqueue(&outbox, (key, bytes))
        if pump == nil {
            sendNext()
            pump = Timer.common(Self.spacing) { [weak self] in self?.sendNext() }
        }
    }

    static func enqueue(_ box: inout [Queued], _ item: Queued) {
        if let key = item.key, let i = box.firstIndex(where: { $0.key == key }) { box[i].bytes = item.bytes }
        else { box.append(item) }
    }

    var queued: Int { outbox.count }

    private func sendNow(_ bytes: [UInt8], to dest: MIDIEndpointRef) {
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(list)
        packet = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
        _ = MIDISend(outPort, dest, list)
    }

    private func sendNext() {
        guard !outbox.isEmpty, destination != 0 else {
            pump?.invalidate(); pump = nil
            return
        }
        let bytes = outbox.removeFirst().bytes
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(list)
        packet = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
        let t0 = Date()
        let status = MIDISend(outPort, destination, list)
        if PedalMIDI.debug { FileHandle.standardError.write(Data(String(format: "[debug] MIDISend %d bytes -> %d in %.0f ms\n", bytes.count, status, Date().timeIntervalSince(t0) * 1000).utf8)) }
        if status != noErr {
            onSendError(AppError(.sendFailed, "MIDISend \(status) to \(destinationName ?? "?")"))
        }
    }

    /// Splits incoming bytes into SysEx messages and CCs. Internal for --selftest.
    func receive(_ bytes: [UInt8]) {
        onRaw(bytes)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b >= 0xF8 { i += 1; continue }        // real-time bytes may interleave anywhere
            if b == 0xF0 {
                if !sysex.isEmpty { cutOffSysex += 1 }
                sysex = [b]
            } else if b == 0xF7 {
                if !sysex.isEmpty { sysex.append(b); onSysex(sysex); sysex = [] }
            } else if b < 0x80 {
                if !sysex.isEmpty { sysex.append(b) }
            } else {
                // Any other status byte ends an unfinished SysEx (MIDI 1.0): its F7
                // never came. v2.7: it used to swallow the CCs that followed.
                if !sysex.isEmpty { cutOffSysex += 1; sysex = [] }
                if b & 0xF0 == 0xB0, i + 2 < bytes.count {
                    onControlChange(Int(b & 0x0F) + 1, Int(bytes[i + 1]), Int(bytes[i + 2]))
                    i += 3; continue
                }
            }
            i += 1
        }
    }
}
