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
    var songDescription = ""
    var songTags: [String] = []
    var nextDescription = ""
    var nextTags: [String] = []
    var songTempos: [Double] = []
    var songDescriptions: [String] = []

    /// A key, from (in order): "Key: Am" in the description (locator text like
    /// `Red {Key: Am}`), a description that is only a key (`{Am}`), a tag that
    /// looks like a key (`#Am`, `#F#`, `#Bbm`), or a key in brackets at the
    /// end of the song name (`Red (Am)`, `Red [F#m]`).
    static func key(description: String, tags: [String], name: String) -> String? {
        let keyLike = #"^[A-Ga-g][#b♯♭]?\s*(m|min|minor|maj|major|M)?$"#
        if let r = description.range(of: #"(?i)\bkey\s*[:=]\s*([^,;}\]\)]+)"#, options: .regularExpression) {
            let m = description[r]
            if let colon = m.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let v = m[m.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        let d = description.trimmingCharacters(in: .whitespaces)
        if d.range(of: keyLike, options: .regularExpression) != nil { return d }
        if let t = tags.map({ $0.hasPrefix("#") ? String($0.dropFirst()) : $0 })
            .first(where: { $0.range(of: keyLike, options: .regularExpression) != nil }) { return t }
        if let r = name.range(of: #"[\(\[]\s*[A-Ga-g][#b♯♭]?\s*(m|min|minor|maj|major|M)?\s*[\)\]]\s*$"#, options: .regularExpression) {
            return name[r].trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
        }
        return nil
    }

    private func listed<T>(_ list: [T], _ i: Int?) -> T? {
        guard let i, i >= 0, i < list.count else { return nil }
        return list[i]
    }

    var key: String? {
        Self.key(description: songDescription.isEmpty ? (listed(songDescriptions, songIndex) ?? "") : songDescription,
                 tags: songTags, name: songName)
    }

    var previousName: String? {
        guard let i = songIndex, i > 0, i - 1 < songs.count else { return nil }
        return songs[i - 1]
    }

    var previousTempo: Double? { songIndex.flatMap { listed(songTempos, $0 - 1) } }
    var previousKey: String? {
        guard let name = previousName else { return nil }
        return Self.key(description: songIndex.flatMap { listed(songDescriptions, $0 - 1) } ?? "", tags: [], name: name)
    }
    var nextTempo: Double? { songIndex.flatMap { listed(songTempos, $0 + 1) } }
    var nextKey: String? {
        guard !nextName.isEmpty else { return nil }
        let d = nextDescription.isEmpty ? (songIndex.flatMap { listed(songDescriptions, $0 + 1) } ?? "") : nextDescription
        return Self.key(description: d, tags: nextTags, name: nextName)
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
        case "/setlist/activeSongDescription": songDescription = m.text ?? ""
        case "/setlist/activeSongTags": songTags = m.args.compactMap { $0.text }
        case "/setlist/nextSongDescription": nextDescription = m.text ?? ""
        case "/setlist/nextSongTags": nextTags = m.args.compactMap { $0.text }
        case "/setlist/songTempos": songTempos = m.args.compactMap { $0.number }
        case "/setlist/songDescriptions": songDescriptions = m.args.map { $0.text ?? "" }
        default: break
        }
    }
}

/// What the pedal should show for a given state. Keys identify each
/// message so unchanged ones aren't resent.
///
/// Display only: the bank's switches send AbleSet's notes themselves and flip
/// pages themselves, so nothing here changes what a switch does.
/// Pages 1/3 (stopped): A PLAY. Pages 2/4 (playing): A LOOP. C and D are the
/// previous and next songs on every page. A on pages 1/3 and B are left as
/// the bank has them.
enum PedalView {
    static let pages = 4
    static let A = 0, B = 1, C = 2, D = 3
    // LED colours (Morningstar colour chart)
    static let green: UInt8 = 1, yellow: UInt8 = 4, orange: UInt8 = 8

    /// Menu toggles. Current song (screen): showBPM / showKey, on by default.
    /// Previous / next songs (C and D): showNeighbourBPM / showNeighbourKey, off by default.
    private static func flag(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    static var showBPM: Bool { get { flag("showBPM", true) } set { UserDefaults.standard.set(newValue, forKey: "showBPM") } }
    static var showKey: Bool { get { flag("showKey", true) } set { UserDefaults.standard.set(newValue, forKey: "showKey") } }
    static var showNeighbourBPM: Bool { get { flag("showNeighbourBPM", false) } set { UserDefaults.standard.set(newValue, forKey: "showNeighbourBPM") } }
    static var showNeighbourKey: Bool { get { flag("showNeighbourKey", false) } set { UserDefaults.standard.set(newValue, forKey: "showNeighbourKey") } }

    static func bpmText(_ t: Double) -> String {
        abs(t - t.rounded()) < 0.05 ? String(Int(t.rounded())) : String(format: "%.1f", t)
    }

    static func label(_ name: String, tempo: Double?, key: String?, bpm showBPM: Bool, key showKey: Bool) -> String {
        var parts = [name]
        if showBPM, let t = tempo { parts.append(bpmText(t)) }
        if showKey, let k = key { parts.append("(\(k))") }     // "Red 125 (Am)"
        return parts.joined(separator: " ")
    }

    /// "<song> <BPM> (<key>)", each extra only when switched on and known.
    static func bankTitle(_ s: SetState, bpm showBPM: Bool = PedalView.showBPM, key showKey: Bool = PedalView.showKey) -> String {
        label(s.songName.isEmpty ? "AbleSet" : s.songName, tempo: s.tempo, key: s.key, bpm: showBPM, key: showKey)
    }

    static func previousLabel(_ s: SetState, bpm: Bool = PedalView.showNeighbourBPM, key: Bool = PedalView.showNeighbourKey) -> String {
        guard let name = s.previousName else { return "-" }
        return label(name, tempo: s.previousTempo, key: s.previousKey, bpm: bpm, key: key)
    }

    static func nextLabel(_ s: SetState, bpm: Bool = PedalView.showNeighbourBPM, key: Bool = PedalView.showNeighbourKey) -> String {
        s.nextName.isEmpty ? "-" : label(s.nextName, tempo: s.nextTempo, key: s.nextKey, bpm: bpm, key: key)
    }

    /// A on the playing pages (2 and 4): AbleSet's real loop state. That A is a
    /// toggle preset, so both of its names are set; the pedal's own toggle
    /// position then doesn't matter. LOOP is always yellow: plain yellow when
    /// on, gold (a slightly deeper yellow) when off. Jon, 2026-11-24: the app
    /// must NEVER change PLAY's or STOP's colour or text; only LOOP is touched.
    static func loopLabel(_ s: SetState) -> String {
        s.loop ? "LOOP ON" : "LOOP OFF"
    }

    static let gold: UInt8 = 47
    static func loopColour(_ s: SetState) -> UInt8 { s.loop ? yellow : gold }

    /// Presets of A on the playing pages (page 2 A = 4, page 4 A = 12).
    static let loopPresets = [A + 4, A + 12]

    /// Long names are never written (Jon, 2026-11-24): the middle of the
    /// screen shows the pressed preset's long name, so they stay as the bank has them.
    static func messages(_ s: SetState) -> [(key: String, bytes: [UInt8])] {
        var out: [(String, [UInt8])] = []
        out.append(("bank", Morningstar.setBankName(bankTitle(s))))
        let label = loopLabel(s)
        let prev = previousLabel(s)
        let next = nextLabel(s)
        for p in loopPresets {
            out.append(("A\(p)", Morningstar.setName(.short, preset: p, label)))
            out.append(("At\(p)", Morningstar.setName(.toggle, preset: p, label)))
            // Black text on a yellow background, like the bank's own LOOP preset.
            let c = loopColour(s)
            out.append(("Acol\(p)", Morningstar.colours(preset: p, led: c, ledToggle: c, text: 0, background: c)))
        }
        for page in 0..<pages {
            let o = page * 4
            out.append(("C\(o)", Morningstar.setName(.short, preset: C + o, prev)))
            out.append(("D\(o)", Morningstar.setName(.short, preset: D + o, next)))
        }
        return out
    }
}

/// Glues AbleSet (OSC) to the MC4 PRO (MIDI).
final class Bridge {
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
        midi.exactName = defaults.string(forKey: "pedalPort")
        midi.onControlChange = { [weak self] ch, n, v in self?.pedalCC(ch, n, v) }
        midi.onSysex = { [weak self] in self?.pedalSysex($0) }
        midi.onRaw = { [weak self] in self?.recordRaw($0) }
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
    /// That's all the bridge listens for: the switches talk to AbleSet
    /// directly, and the bridge never sends AbleSet a transport command.
    private func pedalCC(_ channel: Int, _ number: Int, _ value: Int) {
        if number == Self.bankCC { setInBank(value > 0) }
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
        connectedAt = Date()
        lastReply = nil
        if midi.isConnected {
            clear(.pedalNotFound)
        } else {
            raise(AppError(.pedalNotFound, "No MIDI device whose name contains “\(midi.match)”"))
        }
        onChange()
    }

    /// Ask the pedal for its current bank name: every 1.5 s when stopped, every
    /// 5 s while playing. In the bridge bank that's the bank's own name (just
    /// entered, nothing written yet) or a song title the bridge wrote. Renames
    /// don't depend on the answers, so missing replies only matter for noticing
    /// bank changes; warn after 30 s without any.
    private func pollPedal() {
        guard midi.isConnected, midi.queued == 0 else { return }
        let interval = state.playing ? 5.0 : 1.5
        guard Date().timeIntervalSince(lastPoll) >= interval - 0.1 else { return }
        lastPoll = Date()
        pollsUnanswered += 1
        let silent = Date().timeIntervalSince(lastReply ?? connectedAt)
        if pollsUnanswered > 3, silent > 30 {
            if !silenceLogged {
                silenceLogged = true
                diagnostics("replies stopped")
            }
            raise(AppError(.pedalSilent, String(format: "No SysEx reply from %@ for %.0f s (%d requests; AbleSet %@)",
                                                 midi.destinationName ?? "?", silent, pollsUnanswered - 1,
                                                 state.playing ? "playing" : "stopped")))
        }
        midi.send(Morningstar.currentBankName())
    }

    // MARK: Diagnostics (written to the log when replies stop and start again)

    private var lastPoll = Date.distantPast
    private var lastReply: Date?
    private var connectedAt = Date()
    private var silenceLogged = false
    private var rxChunks = 0, rxReplies = 0, rxBadSysex = 0
    private var recentRx: [String] = []

    private func recordRaw(_ bytes: [UInt8]) {
        rxChunks += 1
        let stamp = String(format: "%.1f", Date().timeIntervalSince(connectedAt))
        recentRx.append("+\(stamp)s " + Morningstar.hex(Array(bytes.prefix(40))) + (bytes.count > 40 ? " …(\(bytes.count))" : ""))
        if recentRx.count > 25 { recentRx.removeFirst(recentRx.count - 25) }
    }

    private func diagnostics(_ what: String) {
        let input = "input \(midi.sourceName ?? "none")" + (midi.sourceConnectStatus.map { " (connect status \($0))" } ?? "")
            + ", \(midi.callbacks) input callbacks; all inputs: " + PedalMIDI.endpoints(sources: true).map(PedalMIDI.name).joined(separator: " | ")
        let lines = ["diagnostics: \(what) — pedal \(midi.destinationName ?? "?"), \(input), AbleSet \(state.playing ? "playing" : "stopped"), "
                     + "in-bank \(inBank.map { "\($0)" } ?? "unknown"), received \(rxChunks) chunks, \(rxReplies) good replies, "
                     + "\(rxBadSysex) garbled SysEx, \(pollsUnanswered) unanswered requests, outbox \(midi.queued)",
                     "last pedal traffic:"] + recentRx.map { "  " + $0 }
        ErrorReporter.note(lines.joined(separator: "\n"))
    }

    private func pedalSysex(_ bytes: [UInt8]) {
        guard let r = Morningstar.parse(bytes) else {
            if bytes.count >= 4, bytes[1] == 0x00, bytes[2] == 0x21, bytes[3] == 0x24 { rxBadSysex += 1 }
            return
        }
        rxReplies += 1
        lastReply = Date()
        pollsUnanswered = 0
        if silenceLogged {
            silenceLogged = false
            diagnostics("replies came back")
        }
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
            // A title this copy wrote, or one any copy (another Mac, an earlier run) would
            // write: "<a song in the setlist> <tempo>".
            let mine = titlesSent.contains(name) || name == Self.stored(PedalView.bankTitle(state))
                || state.songs.contains { name.hasPrefix(Self.stored($0) + " ") || name == Self.stored($0) }
            setInBank(mine)
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

    // MARK: Choosing ports

    /// nil = automatic (first MIDI port whose name contains "MC4").
    var pedalPort: String? { midi.exactName }

    func usePedalPort(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        defaults.set(value, forKey: "pedalPort")
        midi.exactName = value
        midi.rescan()
        pedalConnectionChanged()
    }

    /// Finds the port that answers Morningstar SysEx and switches to it.
    func findPedal(completion: @escaping ([String]) -> Void) {
        midi.search { [weak self] hits in
            if let first = hits.first(where: { $0.lowercased().contains("mc4") }) ?? hits.first {
                self?.usePedalPort(first)
            }
            completion(hits)
        }
    }

    func useAbleSetPorts(listen: UInt16, ableSet: UInt16) {
        defaults.set(Int(listen), forKey: "listenPort")
        defaults.set(Int(ableSet), forKey: "ableSetPort")
        osc.close()
        clear(.portInUse); clear(.socketFailed)
        do {
            try osc.open(host: host, sendPort: ableSetPort, listenPort: listenPort)
            lastAbleSet = Date()        // grace period before "not answering"
            lastSubscribe = Date()
            subscribe()
        } catch let e as AppError { raise(e) } catch { raise(AppError(.unexpected, "\(error)")) }
        onChange()
    }

    /// After a display setting changes.
    func displaySettingsChanged() {
        push()
        onChange()
    }

    /// Menu: Reconnect. Reopens the pedal's MIDI ports, forgets what the pedal
    /// was showing, re-subscribes to AbleSet and asks the pedal which bank it's
    /// on; the names are rewritten as soon as it answers with the bridge bank.
    func reconnect() {
        problems.removeAll()
        midi.reconnect()
        pedalConnectionChanged()
        lastAbleSet = Date()
        subscribe()
        if midi.isConnected { midi.send(Morningstar.currentBankName()) }
        onChange()
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
