import Foundation
import CoreBluetooth
import Observation

@Observable
class OBD2ConnectionManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    var connectionStatus: String = "Disconnected"
    var isScanning: Bool = false
    var receivedLogs: [String] = []
    
    // Split metrics for each target hardware unit
    var engineRPM: String = "-- RPM"
    var mcuRunTime: String = "-- seconds"
    
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var incomingBuffer: String = ""
    
    private let serialServiceUUID = CBUUID(string: "FFF0")
    private let writeCharacteristicUUID = CBUUID(string: "FFF1")
    private let notifyCharacteristicUUID = CBUUID(string: "FFF2")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        isScanning = true
        connectionStatus = "Scanning..."
        centralManager.scanForPeripherals(withServices: [serialServiceUUID], options: nil)
    }
    
    func disconnect() {
        if let peripheral = obdPeripheral { centralManager.cancelPeripheralConnection(peripheral) }
    }
    
    func sendCommand(_ command: String) {
        guard let peripheral = obdPeripheral, let characteristic = txCharacteristic else { return }
        
        let fullCommand = command + "\r"
        if let data = fullCommand.data(using: .utf8) {
            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(data, for: characteristic, type: writeType)
            logMessage("Sent: \(command)")
        }
    }
    
    private func logMessage(_ message: String) {
        DispatchQueue.main.async {
            self.receivedLogs.append(message)
            if self.receivedLogs.count > 50 { self.receivedLogs.removeFirst() }
        }
    }
    
    // MARK: - Central Manager & Peripheral Delegates
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { self.connectionStatus = central.state == .poweredOn ? "Ready to Scan" : "Bluetooth Off" }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        centralManager.stopScan()
        obdPeripheral = peripheral
        obdPeripheral?.delegate = self
        DispatchQueue.main.async { self.isScanning = false; self.connectionStatus = "Connecting..." }
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { self.connectionStatus = "Connected" }
        peripheral.discoverServices([serialServiceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.connectionStatus = "Disconnected"
            self.obdPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serialServiceUUID {
            peripheral.discoverCharacteristics([writeCharacteristicUUID, notifyCharacteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            let props = characteristic.properties
            if props.contains(.write) || props.contains(.writeWithoutResponse) { self.txCharacteristic = characteristic }
            if props.contains(.notify) || props.contains(.read) {
                self.rxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if txCharacteristic != nil && rxCharacteristic != nil { initializeCANProtocol() }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == rxCharacteristic?.uuid,
              let data = characteristic.value,
              let fragment = String(data: data, encoding: .utf8) else { return }
        
        incomingBuffer += fragment
        
        if incomingBuffer.contains(">") || incomingBuffer.contains("\r") {
            let completeResponse = incomingBuffer
            incomingBuffer = ""
            let cleanedResponse = completeResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !cleanedResponse.isEmpty {
                logMessage("Received: \(cleanedResponse)")
                parseCANResponse(cleanedResponse)
            }
        }
    }
    
    private func initializeCANProtocol() {
        let delayStep = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 1) { self.sendCommand("AT Z") }
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 2) { self.sendCommand("AT H1") }
        // Note: For 2018 Toyota Camry Hybrid, AT SP 6 (Standard CAN 500kbps) is the correct protocol.
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 3) { self.sendCommand("AT SP 6") }
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 4) { self.sendCommand("AT SH 7DF") }
    }
    
    // MARK: - Dedicated CAN Parser Matrix
    private func parseCANResponse(_ response: String) {
        // 1. Force the entire string to UPPERCASE and strip all whitespace/newlines
        let rawString = response.uppercased().replacingOccurrences(of: " ", with: "")
                                             .replacingOccurrences(of: "\r", with: "")
                                             .replacingOccurrences(of: "\n", with: "")
        
        // 2. Toyota Engine RPM Module ("410C")
        if let range = rawString.range(of: "410C") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            // Ensure we have at least 4 hex characters remaining (2 bytes: AA BB)
            if remainingString.count >= 4 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let bEnd = remainingString.index(aEnd, offsetBy: 2)
                
                let aString = String(remainingString[aStart..<aEnd])
                let bString = String(remainingString[aEnd..<bEnd])
                
                if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                    let rpm = ((aVal * 256) + bVal) / 4
                    
                    // Direct synchronous assignment to property
                    self.engineRPM = "\(rpm) RPM"
                }
            }
        }
        
        // 3. Custom EV MCU Run Time Module ("411F")
        if let range = rawString.range(of: "411F") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            // Ensure we have at least 4 hex characters remaining (2 bytes: AA BB)
            if remainingString.count >= 4 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let bEnd = remainingString.index(aEnd, offsetBy: 2)
                
                let aString = String(remainingString[aStart..<aEnd])
                let bString = String(remainingString[aEnd..<bEnd])
                
                if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                    let totalSeconds = (aVal * 256) + bVal
                    
                    // Direct synchronous assignment to property
                    self.mcuRunTime = "\(totalSeconds) sec"
                }
            }
        }
    }




}
