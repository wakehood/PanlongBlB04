import Foundation
import CoreBluetooth
import Observation

@Observable
class OBD2ConnectionManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var connectionStatus = "Initializing..."
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
    
    var rawRunTimeSeconds = 0
    var rawVersionData: (version: Int, revision: Int) = (0, 0)
    var rawPackVoltage = 0.0
    var rawPackCurrent = 0.0
    var rawSOCPercentage = 0
    var rawCellMin = 0.0
    var rawCellMax = 0.0
    var rawCellMean = 0.0
    var rawCellStdDev = 0.0
    
    // FIX: Separated single-line comma declarations to satisfy the Observation macro criteria
    var alertHardware = 0
    var alertCCensus = 0
    var alertTCensus = 0
    var alertHVC = 0
    var alertLVC = 0
    var alertHiTemp = 0
    var alertLoTemp = 0

    var isBurstTesting = false
    var burstSentCount = 0
    var burstReplyCount = 0
    var burstTimeoutCount = 0
    var burstRunCount = 0

    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var incomingBuffer = ""
    private var pollingTimer: Timer?
    private var currentInitStep = 0
    private var masterTickCounter = 0
    private var cellCycleCounter = 0
    private var burstStartDate: Date?
    private var burstStartInstant: ContinuousClock.Instant?
    private var burstTimeoutWorkItem: DispatchWorkItem?
    private var burstDurationWorkItem: DispatchWorkItem?
    private var burstStopRequested = false
    private var burstRunResults: [(rps: Double, successRate: Double, timeouts: Int)] = []
    
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
            if !isBurstTesting { logMessage("Sent: \(command)") }
        }
    }
    
    private func logMessage(_ msg: String) { DispatchQueue.main.async { self.receivedLogs.append(msg); if self.receivedLogs.count > 25 { self.receivedLogs.removeFirst() } } }
    
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
        stopAutomaticPolling(); masterTickCounter = 0; cellCycleCounter = 0
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.connectionStatus == "Connected" else { return }
            switch self.masterTickCounter {
            case 0: self.sendCommand("22 DD 83")
            case 1: self.sendCommand("22 DD 84")
            case 2:
                let inner = self.cellCycleCounter % 4
                if inner == 0 || inner == 2 { self.sendCommand("01 1F") }
                else if inner == 1 { self.sendCommand("22 DD 85") }
                else if inner == 3 { self.sendCommand("22 DD 81") }
            case 3:
                let cellQueue = ["22 DD 86", "22 DD 87", "22 DD 88", "22 DD 89"]
                self.sendCommand(cellQueue[self.cellCycleCounter % 4])
                self.cellCycleCounter = (self.cellCycleCounter + 1) % 100
            default: break
            }
            self.masterTickCounter = (self.masterTickCounter + 1) % 4
        }
    }
    
    func stopAutomaticPolling() { pollingTimer?.invalidate(); pollingTimer = nil }

    func startBurstTest() {
        guard connectionStatus == "Connected", !isBurstTesting else { return }
        stopAutomaticPolling()
        isBurstTesting = true; burstStopRequested = false
        burstSentCount = 0; burstReplyCount = 0; burstTimeoutCount = 0
        burstStartDate = Date(); burstStartInstant = ContinuousClock.now
        let stamp = DateFormatter.localizedString(from: burstStartDate!, dateStyle: .none, timeStyle: .medium)
        print("╔══════════════════════════════╗")
        print("║  DD84 BURST TEST START       ║  \(stamp)")
        print("╚══════════════════════════════╝")
        let durationItem = DispatchWorkItem { [weak self] in
            guard let self, self.isBurstTesting else { return }
            self.burstStopRequested = true
        }
        burstDurationWorkItem = durationItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: durationItem)
        sendBurstCommand()
    }

    private func sendBurstCommand() {
        guard isBurstTesting else { return }
        if burstStopRequested { stopBurstTest(); return }
        burstSentCount += 1; sendCommand("22 DD 84"); armBurstTimeout()
    }

    private func armBurstTimeout() {
        burstTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isBurstTesting else { return }
            self.burstTimeoutCount += 1; self.sendBurstCommand()
        }
        burstTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func stopBurstTest() {
        isBurstTesting = false; burstStopRequested = false
        burstTimeoutWorkItem?.cancel(); burstTimeoutWorkItem = nil
        burstDurationWorkItem?.cancel(); burstDurationWorkItem = nil
        let stopDate = Date()
        let stopStamp = DateFormatter.localizedString(from: stopDate, dateStyle: .none, timeStyle: .medium)
        let startStamp = burstStartDate.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "?"
        let elapsed = burstStartInstant.map { ContinuousClock.now - $0 }
        let secs = elapsed.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
        let rps = secs > 0 ? Double(burstReplyCount) / secs : 0
        let pct = burstSentCount > 0 ? Double(burstReplyCount) / Double(burstSentCount) * 100 : 0
        burstRunCount += 1
        burstRunResults.append((rps: rps, successRate: pct, timeouts: burstTimeoutCount))
        print("╔══════════════════════════════╗")
        print("║  DD84 BURST TEST STOP  Run #\(burstRunCount)  ║  \(stopStamp)")
        print("╠══════════════════════════════╣")
        print("  Start:         \(startStamp)")
        print("  Stop:          \(stopStamp)")
        print("  Duration:      \(String(format: "%.3f", secs)) s")
        print("  Sent:          \(burstSentCount)")
        print("  Received:      \(burstReplyCount)")
        print("  Timeouts:      \(burstTimeoutCount)")
        print("  Success Rate:  \(String(format: "%.1f", pct))%")
        print("  Avg Msgs/sec:  \(String(format: "%.2f", rps)) completed round-trips/sec")
        print("╚══════════════════════════════╝")
        if burstRunResults.count >= 2 {
            let rpsList = burstRunResults.map { $0.rps }
            let srList  = burstRunResults.map { $0.successRate }
            let toList  = burstRunResults.map { $0.timeouts }
            let meanRPS = rpsList.reduce(0, +) / Double(rpsList.count)
            let meanSR  = srList.reduce(0, +)  / Double(srList.count)
            let meanTO  = Double(toList.reduce(0, +)) / Double(toList.count)
            print("  ── Cumulative (\(burstRunResults.count) runs) ─────────────────────")
            print("  Avg Msgs/sec:  min=\(String(format: "%.2f", rpsList.min()!))  max=\(String(format: "%.2f", rpsList.max()!))  mean=\(String(format: "%.2f", meanRPS))")
            print("  Success Rate:  min=\(String(format: "%.1f", srList.min()!))%  max=\(String(format: "%.1f", srList.max()!))%  mean=\(String(format: "%.1f", meanSR))%")
            print("  Timeouts/run:  min=\(toList.min()!)  max=\(toList.max()!)  mean=\(String(format: "%.1f", meanTO))")
            print("  ──────────────────────────────────────────────")
        }
        startAutomaticPolling()
    }

    private func printBurstProgress() {
        let elapsed = burstStartInstant.map { ContinuousClock.now - $0 }
        let secs = elapsed.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
        let rps = secs > 0 ? Double(burstReplyCount) / secs : 0
        print("  [burst] sent=\(burstSentCount) rcvd=\(burstReplyCount) to=\(burstTimeoutCount) rps=\(String(format: "%.1f", rps))")
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        DispatchQueue.main.async {
            if c.state == .poweredOn {
                self.startScanning()
            } else {
                self.connectionStatus = "Bluetooth Off"
                self.isScanning = false
            }
        } }
    
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) { centralManager.stopScan(); obdPeripheral = p; p.delegate = self; DispatchQueue.main.async { self.isScanning = false; self.connectionStatus = "Connecting..." }; centralManager.connect(p, options: nil) }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { DispatchQueue.main.async { self.connectionStatus = "Connected" }; p.discoverServices([serialServiceUUID]) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { stopAutomaticPolling(); if isBurstTesting { isBurstTesting = false; burstStopRequested = false; burstTimeoutWorkItem?.cancel(); burstTimeoutWorkItem = nil; burstDurationWorkItem?.cancel(); burstDurationWorkItem = nil; print("  [burst] interrupted by disconnect") }; currentInitStep = 0; DispatchQueue.main.async { self.connectionStatus = "Disconnected"; self.obdPeripheral = nil; self.txCharacteristic = nil; self.rxCharacteristic = nil; self.startScanning() }; logMessage("Re-scanning...") }
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
                if !isBurstTesting { logMessage("Received: \(res)") }
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
        if let v = getVal("411F") { self.rawRunTimeSeconds = v; self.mcuRunTime = String(format: "%02d:%02d:%02d", v / 3600, (v % 3600) / 60, v % 60) }
        if let v = getVal("62DD80") { let ver = v % 256, rev = v / 256; self.rawVersionData = (version: ver, revision: rev); self.mcuVersion = "\(ver).\(rev)"; if currentInitStep == 6 { advanceHandshake() } }
        if let v = getVal("62DD83") { self.rawPackVoltage = Double(v) * 0.1; self.mcuPackVoltage = String(format: "%.1f V", self.rawPackVoltage) }
        if let v = getVal("62DD84") {
            self.rawPackCurrent = Double(Int(Int16(bitPattern: UInt16(v)))) * 0.1; self.mcuPackCurrent = String(format: "%.1f A", self.rawPackCurrent)
            if isBurstTesting { burstReplyCount += 1; if burstReplyCount % 100 == 0 { printBurstProgress() }; burstTimeoutWorkItem?.cancel(); sendBurstCommand() }
        }
        if let r = clean.range(of: "62DD85"), let soc = Int(clean[r.upperBound..<clean.index(r.upperBound, offsetBy: 2)], radix: 16) { self.rawSOCPercentage = min(soc, 100); self.mcuSOC = "\(self.rawSOCPercentage)%" }
        if let r = clean.range(of: "62DD81"), let byteAA = Int(String(clean[r.upperBound..<clean.index(r.upperBound, offsetBy: 2)]), radix: 16) {
            self.alertHardware = (byteAA >> 6) & 1; self.alertCCensus = (byteAA >> 5) & 1; self.alertTCensus = (byteAA >> 4) & 1
            self.alertHVC = (byteAA >> 3) & 1; self.alertLVC = (byteAA >> 2) & 1; self.alertHiTemp = (byteAA >> 1) & 1; self.alertLoTemp = (byteAA >> 0) & 1
        }
        for did in ["62DD86", "62DD87", "62DD88", "62DD89"] {
            if let v = getVal(did) {
                let cellValue = Double(Int(Int16(bitPattern: UInt16(v)))) * 0.0001, strFormat = String(format: "%.4f V", cellValue)
                if did == "62DD86" { self.rawCellMin = cellValue; self.cellMin = strFormat }
                else if did == "62DD87" { self.rawCellMax = cellValue; self.cellMax = strFormat }
                else if did == "62DD88" { self.rawCellMean = cellValue; self.cellMean = strFormat }
                else if did == "62DD89" { self.rawCellStdDev = cellValue; self.cellStdDev = strFormat }
            }
        }
    }
}

