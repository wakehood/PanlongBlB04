import Foundation
import CoreBluetooth
import Observation

@Observable
class OBD2ConnectionManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var connectionStatus = "Disconnected"
    var isScanning = false
    var receivedLogs: [String] = []
    
    var mcuRunTime = "--:--:--"
    var mcuVersion = "--.--"
    var mcuPackVoltage = "--.- V"
    var mcuPackCurrent = "--.- A"
    var mcuSOC = "--%"
    var cellMin = "--.---- V"
    var cellMax = "--.---- V"
    var cellMean = "--.---- V"
    var cellStdDev = "--.---- V"
    
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    
    private var incomingBuffer = ""
    private var pollingTimer: Timer?
    private var currentInitStep = 0
    private var masterTickCounter = 0 // Tracks 0 to 3 to slow down data streams
    private var cellCycleCounter = 0   // Rotates through cell queries at 1x/sec
    
    private let serialServiceUUID = CBUUID(string: "FFF0")
    private let writeCharacteristicUUID = CBUUID(string: "FFF1")
    private let notifyCharacteristicUUID = CBUUID(string: "FFF2")
    
    override init() { super.init(); centralManager = CBCentralManager(delegate: self, queue: nil) }
    func startScanning() { guard centralManager.state == .poweredOn else { return }; isScanning = true; connectionStatus = "Scanning..."; centralManager.scanForPeripherals(withServices: [serialServiceUUID], options: nil) }
    func disconnect() { if let p = obdPeripheral { centralManager.cancelPeripheralConnection(p) } }
    
    func sendCommand(_ command: String) {
        guard let p = obdPeripheral, let ch = txCharacteristic else { return }
        if let data = (command + "\r").data(using: .utf8) {
            p.writeValue(data, for: ch, type: ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
            logMessage("Sent: \(command)")
        }
    }
    
    private func logMessage(_ msg: String) { DispatchQueue.main.async { self.receivedLogs.append(msg); if self.receivedLogs.count > 30 { self.receivedLogs.removeFirst() } } }
    
    private func advanceHandshake() {
        currentInitStep += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            switch self.currentInitStep {
            case 1: self.sendCommand("AT Z")
            case 2: self.sendCommand("AT E0")
            case 3: self.sendCommand("AT H1")
            case 4: self.sendCommand("AT SP 6")
            case 5: self.sendCommand("AT SH 7DF")
            case 6: self.sendCommand("22 DD 80")
            case 7: self.startAutomaticPolling()
            default: break
            }
        }
    }
    
    func startAutomaticPolling() {
        stopAutomaticPolling(); masterTickCounter = 0; cellCycleCounter = 0; logMessage("Relaxed Multi-Schedule Live.")
        // Master clock ticks exactly 4 times per second (every 250 milliseconds) to prevent buffer overflows
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.connectionStatus == "Connected" else { return }
            self.executeScheduledTicks()
        }
    }
    
    private func executeScheduledTicks() {
        switch masterTickCounter {
        case 0:
            // Halved: Voltage requested 4 times per second
            self.sendCommand("22 DD 83")
        case 1:
            // Halved: Current requested 4 times per second
            self.sendCommand("22 DD 84")
        case 2:
            // Run Time (2x/sec) and State of Charge (1x/sec) alternate on this slot
            // Across a 2-second cycle: Run Time fires twice, SOC fires once, 1 slot remains open for buffer cooling
            let innerCycle = cellCycleCounter % 4
            if innerCycle == 0 || innerCycle == 2 {
                self.sendCommand("01 1F")    // Run Time (Fires 2x / sec total)
            } else if innerCycle == 1 {
                self.sendCommand("22 DD 85") // SOC (Fires 1x / sec total)
            }
        case 3:
            // Cell specific metrics (Min, Max, Mean, Std Dev) take turns one by one
            // Each individual cell parameter is queried exactly 1 time per second
            let cellQueue = ["22 DD 86", "22 DD 87", "22 DD 88", "22 DD 89"]
            let currentCellCommand = cellQueue[cellCycleCounter % 4]
            self.sendCommand(currentCellCommand)
            
            // Advance our secondary lower-frequency index tracker
            cellCycleCounter = (cellCycleCounter + 1) % 100
        default:
            break
        }
        
        // Wrap master clock from 0 to 3
        masterTickCounter = (masterTickCounter + 1) % 4
    }
    
    func stopAutomaticPolling() { pollingTimer?.invalidate(); pollingTimer = nil }
    
    func centralManagerDidUpdateState(_ c: CBCentralManager) { DispatchQueue.main.async { self.connectionStatus = c.state == .poweredOn ? "Ready" : "Off" } }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) { centralManager.stopScan(); obdPeripheral = p; p.delegate = self; DispatchQueue.main.async { self.isScanning = false; self.connectionStatus = "Connecting..." }; centralManager.connect(p, options: nil) }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { DispatchQueue.main.async { self.connectionStatus = "Connected" }; p.discoverServices([serialServiceUUID]) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { stopAutomaticPolling(); currentInitStep = 0; DispatchQueue.main.async { self.connectionStatus = "Disconnected"; self.obdPeripheral = nil; self.txCharacteristic = nil; self.rxCharacteristic = nil }; logMessage("Loops halted.") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { if let services = p.services { for s in services where s.uuid == serialServiceUUID { p.discoverCharacteristics([writeCharacteristicUUID, notifyCharacteristicUUID], for: s) } } }
    
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let characteristics = s.characteristics else { return }
        for ch in characteristics {
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) { self.txCharacteristic = ch }
            if ch.properties.contains(.notify) || ch.properties.contains(.read) { self.rxCharacteristic = ch; p.setNotifyValue(true, for: ch) }
        }
        if txCharacteristic != nil && rxCharacteristic != nil { currentInitStep = 0; advanceHandshake() }
    }
    
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == rxCharacteristic?.uuid, let data = ch.value, let fragment = String(data: data, encoding: .utf8) else { return }
        incomingBuffer += fragment
        if incomingBuffer.contains(">") || incomingBuffer.contains("\r") {
            let res = incomingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            incomingBuffer = ""
            if !res.isEmpty {
                logMessage("Received: \(res)")
                if currentInitStep < 7 && (res.contains("OK") || res.contains("ELM327")) { advanceHandshake(); return }
                parseCANResponse(res.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))
            }
        }
    }

    private func parseCANResponse(_ clean: String) {
        let getVal = { (sub: String) -> Int? in
            guard let r = clean.range(of: sub), clean.count >= r.upperBound.utf16Offset(in: clean) + 4 else { return nil }
            let a = String(clean[r.upperBound..<clean.index(r.upperBound, offsetBy: 2)]), b = String(clean[clean.index(r.upperBound, offsetBy: 2)..<clean.index(r.upperBound, offsetBy: 4)])
            return (Int(b, radix: 16) ?? 0) * 256 + (Int(a, radix: 16) ?? 0)
        }
        if let v = getVal("411F") { self.mcuRunTime = String(format: "%02d:%02d:%02d", v / 3600, (v % 3600) / 60, v % 60) }
        if let v = getVal("62DD80") { self.mcuVersion = "\(v % 256).\(v / 256)"; if currentInitStep == 6 { advanceHandshake() } }
        if let v = getVal("62DD83") { self.mcuPackVoltage = String(format: "%.1f V", Double(v) * 0.1) }
        if let v = getVal("62DD84") { self.mcuPackCurrent = String(format: "%.1f A", Double(Int(Int16(bitPattern: UInt16(v)))) * 0.1) }
        if let r = clean.range(of: "62DD85"), let soc = Int(clean[r.upperBound..<clean.index(r.upperBound, offsetBy: 2)], radix: 16) { self.mcuSOC = "\(min(soc, 100))%" }
        
        let cellDIDs = ["62DD86", "62DD87", "62DD88", "62DD89"]
        for did in cellDIDs {
            if let v = getVal(did) {
                let res = String(format: "%.4f V", Double(Int(Int16(bitPattern: UInt16(v)))) * 0.0001)
                if did == "62DD86" { self.cellMin = res } else if did == "62DD87" { self.cellMax = res } else if did == "62DD88" { self.cellMean = res } else { self.cellStdDev = res }
            }
        }
    }
}
