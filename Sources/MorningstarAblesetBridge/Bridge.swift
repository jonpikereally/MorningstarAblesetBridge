import Foundation

/// What AbleSet is doing, from its OSC updates.
struct SetState: Equatable {
    var playing = false
    var loop = false
    var tempo: Double?
    var songs: [String] = []
    var songIndex: Int?
    var songName = ""
    var nextName = ""

    var previousName: String? {
        guard let i = songIndex, i > 0, i - 1 < songs.count else { return nil }
        return songs[i - 1]
    }

    mutating func apply(_ m: OSCMessage) {
        switch m.address {
        case "/global/isPlaying": playing = (m.number ?? 0) != 0
        case "/setlist/loopEnabled": loop = (m.number ?? 0) != 0
        case "/global/tempo": tempo = m.number
        case "/setlist/activeSongName": songName = m.text ?? ""
        case "/setlist/nextSongName": nextName = m.text ?? ""
        case "/setlist/activeSongIndex": songIndex = m.number.map { Int($0) }
        case "/setlist/songs": songs = m.args.compactMap { $0.text }
        default: break
        }
    }
}

/// What the pedal should show for a given state. Keys identify each
/// message so unchanged ones aren't resent. Every switch is the same on all
/// four pages of the MorningstarAblesetBridge bank, so each change goes to presets n, n+4,
/// n+8 and n+12.
enum PedalView {
    static let pages = 4
    static let A = 0, B = 1, C = 2, D = 3
    // LED colours (Morningstar colour chart)
    static let green: UInt8 = 1, yellow: UInt8 = 4, orange: UInt8 = 8

    static func bankTitle(_ s: SetState) -> String {
        let song = s.songName.isEmpty ? "AbleSet" : s.songName
        guard let t = s.tempo else { return song }
        let bpm = abs(t - t.rounded()) < 0.05 ? String(Int(t.rounded())) : String(format: "%.1f", t)
        return "\(song) \(bpm)"
    }

    static func aLabel(_ s: SetState) -> (String, UInt8) {
        if !s.playing { return ("PLAY", green) }
        return s.loop ? ("LOOP ON", orange) : ("LOOP OFF", yellow)
    }

    static func messages(_ s: SetState) -> [(key: String, bytes: [UInt8])] {
        var out: [(String, [UInt8])] = []
        out.append(("bank", Morningstar.setBankName(bankTitle(s))))
        let (label, led) = aLabel(s)
        let prev = s.previousName ?? "-"
        let next = s.nextName.isEmpty ? "-" : s.nextName
        for page in 0..<pages {
            let o = page * 4
            out.append(("A\(o)", Morningstar.setName(.short, preset: A + o, label)))
            out.append(("Acol\(o)", Morningstar.colours(preset: A + o, led: led)))
            out.append(("C\(o)", Morningstar.setName(.short, preset: C + o, prev)))
            out.append(("Cl\(o)", Morningstar.setName(.long, preset: C + o, "< " + prev)))
            out.append(("D\(o)", Morningstar.setName(.short, preset: D + o, next)))
            out.append(("Dl\(o)", Morningstar.setName(.long, preset: D + o, "> " + next)))
        }
        return out
    }
}

/// Glues AbleSet (OSC) to the MC4 PRO (MIDI).
final class Bridge {
    static let smartCC = 110                // switch A in the MorningstarAblesetBridge bank
    static let bankCC = 111                 // MorningstarAblesetBridge bank: 127 on entering it, 0 on leaving
    /// The bank's own (saved) names: the current one, and the one from before the rename.
    static let bankNames: Set<String> = ["AbleSet Bridge", "PedalLink AbleSet"]

    var onChange: () -> Void = {}
    private(set) var state = SetState()
    private(set) var ableSetAlive = false
    private(set) var inBank: Bool?          // nil = not known since launch (no bank change seen yet)
    private(set) var problems: [ErrorCode: AppError] = [:]

    let midi = PedalMIDI()
    private let osc = OSCTransport()
    private var lastAbleSet: Date?
    private var sent: [String: [UInt8]] = [:]
    private var timers: [Timer] = []
    private var pollsUnanswered = 0
    private var titlesSent: Set<String> = []    // bank names MorningstarAblesetBridge has written, as the pedal stores them

    private let defaults = UserDefaults.standard
    var host: String { defaults.string(forKey: "ableSetHost") ?? "127.0.0.1" }
    var listenPort: UInt16 { UInt16(defaults.integer(forKey: "listenPort").nonZero ?? 39161) }
    var ableSetPort: UInt16 { UInt16(defaults.integer(forKey: "ableSetPort").nonZero ?? 39051) }

    func start() {
        midi.match = defaults.string(forKey: "pedalName") ?? "MC4"
        midi.onControlChange = { [weak self] ch, n, v in self?.pedalCC(ch, n, v) }
        midi.onSysex = { [weak self] in self?.pedalSysex($0) }
        midi.onConnectionChange = { [weak self] in self?.pedalConnectionChanged() }
        midi.onSendError = { [weak self] in self?.raise($0) }
        do { try midi.start() } catch let e as AppError { raise(e) } catch { raise(AppError(.unexpected, "\(error)")) }

        osc.onMessages = { [weak self] msgs in DispatchQueue.main.async { self?.ableSet(msgs) } }
        do {
            try osc.open(host: host, sendPort: ableSetPort, listenPort: listenPort)
            subscribe()
        } catch let e as AppError { raise(e) } catch { raise(AppError(.unexpected, "\(error)")) }

        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkAbleSet() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.pollPedal() })
        pedalConnectionChanged()
    }

    // MARK: AbleSet

    private func subscribe() {
        osc.send(OSCMessage(address: "/subscribe", args: [.string(host == "127.0.0.1" ? "127.0.0.1" : "auto"),
                                                          .int(Int32(listenPort)), .string("MorningstarAblesetBridge")]))
        osc.send(OSCMessage(address: "/getValues", args: []))
    }

    private func ableSet(_ msgs: [OSCMessage]) {
        lastAbleSet = Date()
        if !ableSetAlive {
            ableSetAlive = true
            clear(.ableSetSilent)
        }
        let before = state
        msgs.forEach { state.apply($0) }
        if state != before {
            if state.songName != before.songName, !state.songName.isEmpty, inBank == true {
                midi.send(Morningstar.lcd(PedalView.bankTitle(state), tenths: 25))
            }
            push()
        }
        onChange()
    }

    private var lastSubscribe = Date.distantPast
    private func checkAbleSet() {
        // AbleSet sends /heartbeat every 2 s to subscribers, so 5 s of silence means it's gone.
        guard Date().timeIntervalSince(lastAbleSet ?? launch) > 5 else { return }
        ableSetAlive = false
        raise(AppError(.ableSetSilent, "No OSC from \(host):\(ableSetPort) for 5 s"))
        if Date().timeIntervalSince(lastSubscribe) > 5 {
            lastSubscribe = Date()
            subscribe()          // AbleSet forgets subscribers when it restarts
        }
    }
    private let launch = Date()

    /// CC 111: the MorningstarAblesetBridge bank was entered (127) or left (0).
    /// CC 110: switch A — play when stopped, loop toggle when playing.
    private func pedalCC(_ channel: Int, _ number: Int, _ value: Int) {
        switch number {
        case Self.bankCC:
            setInBank(value > 0)
        case Self.smartCC where value > 0:
            setInBank(true)            // only the MorningstarAblesetBridge bank sends CC 110
            osc.send(OSCMessage(address: state.playing ? "/loop/toggle" : "/global/play", args: []))
        default: break
        }
    }

    private func setInBank(_ now: Bool) {
        guard now != inBank else { return }
        inBank = now
        if now {
            sent.removeAll()           // the pedal reset its names when the bank was entered
            push()
            if !state.songName.isEmpty { midi.send(Morningstar.lcd(PedalView.bankTitle(state), tenths: 20)) }
        }
        onChange()
    }

    // MARK: Pedal

    private func pedalConnectionChanged() {
        sent.removeAll()
        inBank = nil
        pollsUnanswered = 0
        if midi.isConnected {
            clear(.pedalNotFound)
        } else {
            raise(AppError(.pedalNotFound, "No MIDI device whose name contains “\(midi.match)”"))
        }
        onChange()
    }

    /// Every 1.5 s ask the pedal for its current bank name. In the MorningstarAblesetBridge
    /// bank that's either the bank's own name (just entered, nothing written
    /// yet) or a song title MorningstarAblesetBridge wrote.
    private func pollPedal() {
        guard midi.isConnected, midi.queued == 0 else { return }
        pollsUnanswered += 1
        if pollsUnanswered > 4 {
            raise(AppError(.pedalSilent, "No SysEx reply from \(midi.destinationName ?? "?") to \(pollsUnanswered - 1) requests"))
        }
        midi.send(Morningstar.currentBankName())
    }

    private func pedalSysex(_ bytes: [UInt8]) {
        guard let r = Morningstar.parse(bytes) else { return }
        pollsUnanswered = 0
        clear(.pedalSilent)
        if r.isError {
            if r.ack != 0 {
                let why = [1: "wrong model ID", 2: "wrong checksum", 3: "wrong payload size"][Int(r.ack)] ?? "ack \(r.ack)"
                raise(AppError(.pedalRejected, "\(why) (transaction \(r.txn))"))
            }
            return
        }
        guard r.op2 == 0x30 else { return }       // current bank name (the MC4 replies with op2 30)
        let name = r.text
        if Self.bankNames.contains(name) {
            // Freshly entered (or re-entered between polls): the pedal shows the saved names again.
            if inBank != true { setInBank(true) } else if sent["bank"] != nil, !titlesSent.contains(name) { sent.removeAll(); push() }
        } else {
            // A title this run wrote, or (after a restart) the title for the current song.
            setInBank(titlesSent.contains(name) || name == Self.stored(PedalView.bankTitle(state)))
        }
    }

    /// A name as the pedal stores and reports it (ASCII, 32 chars, no padding).
    static func stored(_ name: String) -> String {
        String(decoding: Morningstar.ascii(name, length: Morningstar.nameLength, pad: false), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Send whatever differs from what the pedal was last told.
    func push() {
        // Without AbleSet there's nothing true to show, so leave the pedal as it is.
        guard midi.isConnected, inBank == true, ableSetAlive else { return }
        titlesSent.insert(Self.stored(PedalView.bankTitle(state)))
        for (key, bytes) in PedalView.messages(state) where sent[key] != bytes {
            midi.send(bytes)
            sent[key] = bytes
        }
    }

    /// Menu: resend everything (and trust that the MorningstarAblesetBridge bank is showing).
    func resendAll() {
        inBank = true
        sent.removeAll()
        problems.removeAll()
        midi.rescan()
        subscribe()
        push()
        onChange()
    }

    // MARK: Problems

    private func raise(_ e: AppError) {
        if problems[e.code] == nil { ErrorReporter.log(e) }
        problems[e.code] = e
        onChange()
    }

    private func clear(_ code: ErrorCode) {
        if problems.removeValue(forKey: code) != nil { onChange() }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
