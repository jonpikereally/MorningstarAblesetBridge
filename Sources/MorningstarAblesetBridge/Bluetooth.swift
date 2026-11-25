import CoreBluetooth
import CoreMIDI
import Foundation

// Reconnecting the pedal over Bluetooth MIDI without macOS's Bluetooth MIDI
// window (v2.8). macOS doesn't reconnect a Bluetooth MIDI device that was
// switched off and on; an app can, with Apple's recipe from CoreMIDI's
// MIDIBluetoothConnection.h:
//   1. scan for the pedal's Bluetooth LE MIDI advertisement (CoreBluetooth),
//   2. connect to it,
//   3. call MIDIBluetoothDriverActivateAllConnections, which turns that
//      connection into an online CoreMIDI device,
//   4. once CoreMIDI lists the pedal, drop the app's own connection: CoreMIDI
//      keeps one of its own.

/// A Bluetooth MIDI device as CoreBluetooth reports it.
struct RadioDevice: Equatable {
    let id: UUID
    let name: String
    var label: String { name.isEmpty ? "the pedal" : name }
}

enum RadioState: Equatable { case starting, on, off, notAllowed, unsupported }

enum RadioEvent {
    case state(RadioState)
    case found(RadioDevice)
    case connected(UUID)
    case failed(UUID, String)
    case disconnected(UUID)
}

/// The Bluetooth radio, behind a protocol so --selftest can drive the
/// reconnect logic with a pretend one (the sandbox has no Bluetooth).
protocol BluetoothRadio: AnyObject {
    var onEvent: (RadioEvent) -> Void { get set }
    /// Starts Bluetooth (the first time, macOS may ask for permission) and
    /// reports its state, now or shortly.
    func start()
    /// Bluetooth MIDI devices already connected to this Mac, by any app.
    func connectedMIDIDevices() -> [RadioDevice]
    func scan(_ on: Bool)
    func connect(_ id: UUID)
    func disconnect(_ id: UUID)
    /// Hands every Bluetooth MIDI device this app is connected to over to
    /// CoreMIDI, as an online MIDI device.
    func activateMIDI() -> OSStatus
}

final class CoreBluetoothRadio: NSObject, BluetoothRadio, CBCentralManagerDelegate {
    /// The Bluetooth LE MIDI service, which every BLE MIDI device advertises.
    static let midiService = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")

    var onEvent: (RadioEvent) -> Void = { _ in }
    private var central: CBCentralManager?
    /// Devices seen in the current scan, and the ones connected or being
    /// connected. CoreBluetooth drops a connection to a device nobody holds.
    private var discovered: [UUID: CBPeripheral] = [:]
    private var held: [UUID: CBPeripheral] = [:]

    func start() {
        if let central { onEvent(.state(Self.state(central.state))); return }
        // No system "Turn On Bluetooth" alert: the menu says it instead.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    static func state(_ s: CBManagerState) -> RadioState {
        switch s {
        case .poweredOn: return .on
        case .poweredOff: return .off
        case .unauthorized: return .notAllowed
        case .unsupported: return .unsupported
        default: return .starting           // unknown or resetting: a real state follows
        }
    }

    func connectedMIDIDevices() -> [RadioDevice] {
        guard let central, central.state == .poweredOn else { return [] }
        return central.retrieveConnectedPeripherals(withServices: [Self.midiService]).map {
            discovered[$0.identifier] = $0
            return RadioDevice(id: $0.identifier, name: $0.name ?? "")
        }
    }

    func scan(_ on: Bool) {
        guard let central, central.state == .poweredOn else { return }
        if on {
            discovered.removeAll()
            // Duplicates on: a device's name can arrive in a later scan
            // response than its first advertisement.
            central.scanForPeripherals(withServices: [Self.midiService],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if central.isScanning {
            central.stopScan()
        }
    }

    func connect(_ id: UUID) {
        guard let central, let p = held[id] ?? discovered[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            onEvent(.failed(id, "Bluetooth no longer knows that device"))
            return
        }
        held[id] = p
        central.connect(p, options: nil)
    }

    func disconnect(_ id: UUID) {
        guard let p = held.removeValue(forKey: id) else { return }
        central?.cancelPeripheralConnection(p)
    }

    func activateMIDI() -> OSStatus { MIDIBluetoothDriverActivateAllConnections() }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent(.state(Self.state(central.state)))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discovered[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        onEvent(.found(RadioDevice(id: peripheral.identifier, name: name)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        held[peripheral.identifier] = peripheral       // so a connection nobody waits for can still be let go
        onEvent(.connected(peripheral.identifier))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        held.removeValue(forKey: peripheral.identifier)
        onEvent(.failed(peripheral.identifier, error?.localizedDescription ?? "no reason given"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        held.removeValue(forKey: peripheral.identifier)
        onEvent(.disconnected(peripheral.identifier))
    }
}

/// Looks for the pedal over Bluetooth and hands it to CoreMIDI. One look runs
/// at a time; asking again while one runs only extends it.
final class BluetoothReconnect {
    enum Phase: Equatable {
        case idle
        case starting                       // waiting for Bluetooth to be on and allowed
        case looking                        // scanning for the pedal's advertisement
        case connecting(RadioDevice)
        case handingOver(RadioDevice)       // connected; waiting for CoreMIDI to list it
    }

    static let connectTimeout: TimeInterval = 15
    static let handOverTimeout: TimeInterval = 10
    /// Automatic looks stop after this many reconnects within 10 minutes, so a
    /// pedal that drops out straight after each one can't keep this going.
    static let maxAutoReconnects = 3

    private(set) var phase: Phase = .idle
    private(set) var radioState: RadioState = .starting
    private(set) var until: Date?
    /// The user chose Reconnect, so failing says so. Automatic looks fail quietly.
    private(set) var asked = false
    /// Other Bluetooth MIDI devices seen while looking, for the menu and the log.
    private(set) var seen: [String] = []
    /// When the last look ended without the pedal (nil after a reconnect or a new look).
    private(set) var gaveUpAt: Date?
    private var startedAt = Date()
    private var phaseStarted = Date()
    private var reconnects: [Date] = []
    private var radio: BluetoothRadio?
    private var timer: Timer?
    private let makeRadio: () -> BluetoothRadio

    var isPedal: (RadioDevice) -> Bool = { _ in false }
    /// Whether CoreMIDI lists this device as a Bluetooth MIDI port now.
    var isOnline: (RadioDevice) -> Bool = { _ in false }
    var onReconnected: (RadioDevice) -> Void = { _ in }
    var raise: (AppError) -> Void = { _ in }
    var clear: (ErrorCode) -> Void = { _ in }
    var onChange: () -> Void = {}
    var log: (String) -> Void = { ErrorReporter.note("Bluetooth: " + $0) }
    var now: () -> Date = Date.init
    /// --selftest calls tick() itself.
    var usesTimer = true

    init(makeRadio: @escaping () -> BluetoothRadio) { self.makeRadio = makeRadio }

    /// Starts Bluetooth without looking, so macOS's one-time permission
    /// question comes while the pedal is being connected rather than later,
    /// when it has dropped out.
    func prepare() {
        guard radio == nil else { return }
        ensureRadio().start()
    }

    /// Looks for the pedal for `seconds` (longer if a look is already running).
    /// Returns false when an automatic look is refused because the pedal has
    /// dropped out straight after reconnecting too often.
    @discardableResult
    func look(for seconds: TimeInterval, asked: Bool) -> Bool {
        let t = now()
        reconnects.removeAll { t.timeIntervalSince($0) >= 600 }
        if !asked, reconnects.count >= Self.maxAutoReconnects { return false }
        clear(.bluetoothNotFound)
        clear(.bluetoothHandOver)
        gaveUpAt = nil
        until = max(until ?? t, t.addingTimeInterval(seconds))
        self.asked = self.asked || asked
        if phase == .idle {
            seen = []
            startedAt = t
            enter(.starting)
            if usesTimer { timer = Timer.common(1) { [weak self] in self?.tick() } }
        }
        ensureRadio().start()       // reports the radio's state; when it's on, the look begins
        onChange()
        return true
    }

    /// The bridge has the pedal again: CoreMIDI lists it, or it came back
    /// another way (USB, macOS's Bluetooth MIDI window).
    func pedalArrived() {
        switch phase {
        case .idle: return
        case .handingOver(let d): succeed(d)
        case .connecting(let d):
            radio?.disconnect(d.id)
            finish("the pedal came back another way")
        case .starting, .looking:
            finish("the pedal came back another way")
        }
    }

    func stop(_ why: String) {
        switch phase {
        case .idle: return
        case .connecting(let d), .handingOver(let d): radio?.disconnect(d.id)
        case .starting, .looking: break
        }
        finish(why)
    }

    func handle(_ event: RadioEvent) {
        switch event {
        case .state(let s):
            radioState = s
            switch s {
            case .on:
                clear(.bluetoothOff)
                clear(.bluetoothNotAllowed)
                if phase == .starting { begin() }
            case .off, .notAllowed:
                guard phase != .idle else { break }
                raise(s == .off ? AppError(.bluetoothOff, "Bluetooth is switched off on this Mac")
                                : AppError(.bluetoothNotAllowed, "macOS says MorningstarAblesetBridge isn't allowed to use Bluetooth"))
                // Scans and connections end with the radio; wait for it to come back.
                switch phase {
                case .connecting(let d), .handingOver(let d): radio?.disconnect(d.id); enter(.starting)
                case .looking: enter(.starting)
                case .idle, .starting: break
                }
            case .unsupported:
                guard phase != .idle else { break }
                raise(AppError(.bluetoothOff, "This Mac has no Bluetooth LE"))
                finish("this Mac has no Bluetooth LE")
            case .starting:
                break
            }
            onChange()
        case .found(let d):
            guard phase == .looking else { return }
            if isPedal(d) {
                connect(d)
            } else {
                let label = d.name.isEmpty ? "(no name)" : d.name
                if !seen.contains(label), seen.count < 6 { seen.append(label); onChange() }
            }
        case .connected(let id):
            guard case .connecting(let d) = phase, d.id == id else {
                radio?.disconnect(id)           // a late connection nothing is waiting for: let it go
                return
            }
            let status = radio?.activateMIDI() ?? noErr
            guard status == noErr else {
                radio?.disconnect(id)
                raise(AppError(.bluetoothHandOver, "MIDIBluetoothDriverActivateAllConnections returned \(status)"))
                finish("CoreMIDI refused \(d.label) (\(status))")
                return
            }
            log("connected to \(d.label); handing it to CoreMIDI")
            enter(.handingOver(d))
            if isOnline(d) { succeed(d) }
        case .failed(let id, let why):
            guard case .connecting(let d) = phase, d.id == id else { return }
            log("connecting to \(d.label) failed (\(why))")
            lookAgain()
        case .disconnected(let id):
            switch phase {
            case .connecting(let d) where d.id == id, .handingOver(let d) where d.id == id:
                log("\(d.label) disconnected before CoreMIDI took it over")
                lookAgain()
            default:
                break
            }
        }
    }

    /// Every second while a look runs: time limits, and whether CoreMIDI has the pedal yet.
    func tick() {
        let t = now()
        switch phase {
        case .idle:
            return
        case .starting, .looking:
            if let until, t >= until { giveUp() }
        case .connecting(let d):
            guard t.timeIntervalSince(phaseStarted) >= Self.connectTimeout else { return }
            radio?.disconnect(d.id)
            log("\(d.label) didn't connect within \(Int(Self.connectTimeout)) s")
            lookAgain()
        case .handingOver(let d):
            if isOnline(d) { succeed(d); return }
            guard t.timeIntervalSince(phaseStarted) >= Self.handOverTimeout else { return }
            radio?.disconnect(d.id)
            raise(AppError(.bluetoothHandOver, "\(d.label) connected, but CoreMIDI didn't list it within \(Int(Self.handOverTimeout)) s"))
            finish("CoreMIDI didn't take over \(d.label)")
        }
    }

    private func ensureRadio() -> BluetoothRadio {
        if let radio { return radio }
        let r = makeRadio()
        r.onEvent = { [weak self] in self?.handle($0) }
        radio = r
        return r
    }

    private func begin() {
        // Linked to the Mac already (by another app, say) but not a MIDI device: no scan needed.
        if let d = radio?.connectedMIDIDevices().first(where: isPedal) {
            log("\(d.label) is already linked over Bluetooth")
            connect(d)
            return
        }
        enter(.looking)
        radio?.scan(true)
    }

    private func connect(_ d: RadioDevice) {
        enter(.connecting(d))
        radio?.connect(d.id)
    }

    private func lookAgain() {
        guard let until, now() < until else { giveUp(); return }
        if radioState == .on { begin() } else { enter(.starting) }
    }

    private func succeed(_ d: RadioDevice) {
        radio?.disconnect(d.id)             // CoreMIDI keeps its own connection
        reconnects.append(now())
        onReconnected(d)
        [ErrorCode.bluetoothNotFound, .bluetoothHandOver, .bluetoothOff, .bluetoothNotAllowed].forEach(clear)
        finish("\(d.label) is back as a MIDI device after \(Int(now().timeIntervalSince(startedAt))) s")
    }

    private func giveUp() {
        let saw = seen.isEmpty ? "no other Bluetooth MIDI devices seen" : "seen: " + seen.joined(separator: ", ")
        if asked {
            switch radioState {
            case .on: raise(AppError(.bluetoothNotFound, "Looked for \(Int(now().timeIntervalSince(startedAt))) s; \(saw)"))
            case .starting: raise(AppError(.bluetoothOff, "Bluetooth didn't start"))
            case .off, .notAllowed, .unsupported: break      // already reported
            }
        }
        gaveUpAt = now()
        finish("stopped looking for the pedal (\(saw))")
    }

    private func finish(_ why: String) {
        if phase == .looking { radio?.scan(false) }
        phase = .idle
        until = nil
        asked = false
        timer?.invalidate()
        timer = nil
        log(why)
        onChange()
    }

    private func enter(_ p: Phase) {
        if phase == .looking, p != .looking { radio?.scan(false) }
        phase = p
        phaseStarted = now()
        onChange()
    }
}
