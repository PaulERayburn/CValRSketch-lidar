import CoreBluetooth
import SwiftUI

// A Bluetooth laser measure. Both kinds send every reading in metric, whatever
// unit the screen shows, and other messages (unit changes, keep-alives) are
// ignored.
//
// Huepar S-series (advertises as "LDM-…"): readings are notifications on AE02.
//   F1 04 01 00 07 | 03 01 31 50 | D2 D1 D0 | 01 | CK
// Byte 4 is the payload length; the last three payload bytes are the distance,
// big-endian, in hundredths of a millimetre; CK is the sum of bytes 1 through
// the end of the payload, mod 256. Decoded from an S60-G-BT; the published
// notes for the S120R-BT give the same service but a different reading prefix.
//
// Bosch GLM-C (advertises service 02A6C0D0…, usually with no name): readings
// are indications on 02A6C0D1, sent only after writing C0 55 02 01 00 1A there.
//   C0 55 10 06 00 <n> 00 | float32 metres, little-endian | 8 × 00 | CRC
// The CRC is CRC-8, polynomial 0xA6, initial 0xAA, over every byte before it.
// Checked on a GLM165-27C.
@MainActor
final class Laser: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = Laser()

    enum Status: Equatable { case off, unauthorized, bluetoothOff, searching, connected(String) }
    struct Reading: Equatable {
        let id = UUID()
        let millimeters: Double
        var inches: Int { Int((millimeters / 25.4).rounded()) }
    }

    @Published private(set) var status = Status.off
    @Published private(set) var reading: Reading?

    private static let service = CBUUID(string: "AE30")
    private static let data = CBUUID(string: "AE02")
    private static let boschService = CBUUID(string: "02A6C0D0-0451-4000-B000-FB3210111989")
    private static let boschData = CBUUID(string: "02A6C0D1-0451-4000-B000-FB3210111989")
    private static let boschSendReadings = Data([0xC0, 0x55, 0x02, 0x01, 0x00, 0x1A])
    private static let rememberKey = "laserConnect"

    private var central: CBCentralManager?
    private var laser: CBPeripheral?

    // Reconnects at launch once the laser has been connected before, so the
    // Bluetooth permission is asked only when someone taps Connect.
    override init() {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.rememberKey) { connect() }
    }

    func connect() {
        UserDefaults.standard.set(true, forKey: Self.rememberKey)
        if let central { centralManagerDidUpdateState(central) } else { central = CBCentralManager(delegate: self, queue: nil) }
    }

    func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.rememberKey)
        central?.stopScan()
        if let laser { central?.cancelPeripheralConnection(laser) }
        laser = nil
        status = .off
    }

    static func millimeters(from d: Data) -> Double? {
        let b = [UInt8](d)
        if b.count == 20, b[0] == 0xC0, b[1] == 0x55, b[2] == 0x10, b[3] == 0x06 {
            guard crc8(b[0..<19]) == b[19] else { return nil }
            let bits = UInt32(b[7]) | UInt32(b[8]) << 8 | UInt32(b[9]) << 16 | UInt32(b[10]) << 24
            let meters = Double(Float(bitPattern: bits))
            return meters > 0 ? meters * 1000 : nil
        }
        guard b.count >= 9, b[0] == 0xF1, b[1] == 0x04 else { return nil }
        let len = Int(b[4])
        guard len >= 3, b.count == 7 + len else { return nil }
        let end = 5 + len
        guard b[1..<end].reduce(0, { ($0 + Int($1)) & 0xFF }) == Int(b[end + 1]) else { return nil }
        let raw = Int(b[end - 3]) << 16 | Int(b[end - 2]) << 8 | Int(b[end - 1])
        return Double(raw) / 100
    }

    private static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var c: UInt8 = 0xAA
        for byte in bytes {
            c ^= byte
            for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0xA6 : c << 1 }
        }
        return c
    }

    private var wanted: Bool { UserDefaults.standard.bool(forKey: Self.rememberKey) }

    private func scan() {
        guard let central, central.state == .poweredOn, wanted, laser == nil else { return }
        status = .searching
        central.scanForPeripherals(withServices: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: if laser == nil { scan() }
        case .unauthorized: status = .unauthorized
        case .poweredOff: status = .bluetoothOff; laser = nil
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? ad[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.hasPrefix("LDM") || services.contains(Self.boschService), laser == nil else { return }
        laser = p
        c.stopScan()
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        p.discoverServices([Self.service, Self.boschService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        laser = nil
        scan()
    }

    // The laser switches itself off after a while; keep looking so it comes
    // back as soon as it is turned on again.
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == laser else { return }
        laser = nil
        status = wanted ? .searching : .off
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics([Self.data, Self.boschData], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == Self.data || ch.uuid == Self.boschData {
            p.setNotifyValue(true, for: ch)
            if ch.uuid == Self.boschData { p.writeValue(Self.boschSendReadings, for: ch, type: .withResponse) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if ch.isNotifying { status = .connected(p.name ?? (ch.uuid == Self.boschData ? "Bosch" : "Laser")) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, let mm = Self.millimeters(from: v) else { return }
        reading = Reading(millimeters: mm)
    }
}

// A row for a reading field: connects the laser, or says it's ready.
struct LaserRow: View {
    @ObservedObject private var laser = Laser.shared

    var body: some View {
        switch laser.status {
        case .off:
            Button("Connect laser", systemImage: "dot.radiowaves.left.and.right") { laser.connect() }
        case .searching:
            HStack {
                ProgressView()
                Text("Looking for the laser. Turn it on.").foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { laser.disconnect() }.buttonStyle(.borderless)
            }
        case .connected:
            HStack {
                Label("Laser connected: take the reading", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Spacer()
                Button("Disconnect") { laser.disconnect() }.buttonStyle(.borderless).font(.footnote)
            }
        case .bluetoothOff:
            Text("Bluetooth is off. Turn it on in Control Center to use the laser.").foregroundStyle(.orange)
        case .unauthorized:
            Text("CValRScan isn't allowed to use Bluetooth. Turn it on in Settings → CValRScan.").foregroundStyle(.orange)
        }
    }
}

extension View {
    // Fills a reading field from the laser: the first reading replaces an
    // empty field, later ones are added as pieces (" + 6 5"), to the nearest
    // inch. With `pieces` off each reading replaces the last.
    func laserInput(_ text: Binding<String>, pieces: Bool = true) -> some View {
        modifier(LaserInput(text: text, pieces: pieces))
    }
}

private struct LaserInput: ViewModifier {
    @Binding var text: String
    let pieces: Bool
    @ObservedObject private var laser = Laser.shared

    func body(content: Content) -> some View {
        content.onChange(of: laser.reading) { _, r in
            guard let r else { return }
            let entry = "\(r.inches / 12) \(r.inches % 12)"
            let current = text.trimmingCharacters(in: .whitespaces)
            text = pieces && !current.isEmpty ? current + " + " + entry : entry
        }
    }
}
