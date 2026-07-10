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
    var mcuPackVoltage: String = "-- Volts"
    var mcuPackCurrent: String = "-- Amps"
    var mcuVersion: String = "-- . --"
    var mcuSOC: String = "-- %"
    var cellMin: String = "--.---- V"
    var cellMax: String = "--.---- V"
    var cellMean: String = "--.---- V"
    var cellStdDev: String = "--.---- V"

    
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
        
        // Custom EV MCU Run Time Module ("411F")
        if let range = rawString.range(of: "411F") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            if remainingString.count >= 4 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let bEnd = remainingString.index(aEnd, offsetBy: 2)
                
                let aString = String(remainingString[aStart..<aEnd]) // AA (Low Byte)
                let bString = String(remainingString[aEnd..<bEnd])   // BB (High Byte)
                
                if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                    // Evaluated as int16(BB:AA) -> BB is High Byte, AA is Low Byte
                    let totalSeconds = (bVal * 256) + aVal
                    
                    // Format total seconds into H:M:S
                    let hours = totalSeconds / 3600
                    let minutes = (totalSeconds % 3600) / 60
                    let seconds = totalSeconds % 60
                    
                    self.mcuRunTime = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                }
            }
        }


        
        // NEW: Custom EV MCU Pack Voltage Module ("62DD83")
        if let range = rawString.range(of: "62DD83") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            // Ensure we have at least 4 hex characters for AA and BB
            if remainingString.count >= 4 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let bEnd = remainingString.index(aEnd, offsetBy: 2)
                
                let aString = String(remainingString[aStart..<aEnd]) // AA (Low Byte)
                let bString = String(remainingString[aEnd..<bEnd])   // BB (High Byte)
                
                if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                    // Per your specification: BB is High Byte, AA is Low Byte
                    let rawValue = (bVal * 256) + aVal
                    
                    // Scale is 0.1 (Divide by 10.0 to get decimal voltage string format)
                    let actualVoltage = Double(rawValue) * 0.1
                    
                    // Formatted string to show one decimal spot (e.g., 380.5 V)
                    self.mcuPackVoltage = String(format: "%.1f V", actualVoltage)
                }
            }
        }
        
        // NEW: Custom EV MCU Pack Current Module ("62DD84")
        if let range = rawString.range(of: "62DD84") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            // Ensure we have at least 4 hex characters for AA and BB
            if remainingString.count >= 4 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let bEnd = remainingString.index(aEnd, offsetBy: 2)
                
                let aString = String(remainingString[aStart..<aEnd]) // AA (Low Byte)
                let bString = String(remainingString[aEnd..<bEnd])   // BB (High Byte)
                
                if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                    // Interpret BB as a signed 8-bit integer (Int8)
                    // Casting to Int8 tells Swift to treat values 128-255 as negative numbers (-128 to -1)
                    let signedBB = Int8(bitPattern: UInt8(bVal))
                    
                    // Reconstruct the 16-bit word: Shift the signed high byte up, then combine with the low byte
                    let rawSignedValue = (Int(signedBB) * 256) + aVal
                    
                    // Scale is 0.1
                    let actualCurrent = Double(rawSignedValue) * 0.1
                    
                    // Formatted string to show one decimal spot (e.g., 45.2 A or -12.5 A)
                    self.mcuPackCurrent = String(format: "%.1f A", actualCurrent)
                }
            }
        }
        
        // Custom EV MCU Version Module ("62DD80")
        if let range = rawString.range(of: "62DD80") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            if remainingString.count >= 4 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let bEnd = remainingString.index(aEnd, offsetBy: 2)
                
                let aString = String(remainingString[aStart..<aEnd]) // AA (Version)
                let bString = String(remainingString[aEnd..<bEnd])   // BB (Revision)
                
                if let versionVal = Int(aString, radix: 16), let revisionVal = Int(bString, radix: 16) {
                    self.mcuVersion = "\(versionVal).\(revisionVal)"
                }
            }
        }
        
        // Custom EV MCU State of Charge Module ("62DD85")
        if let range = rawString.range(of: "62DD85") {
            let dataStartIndex = range.upperBound
            let remainingString = rawString[dataStartIndex...]
            
            // Ensure we have at least 2 hex characters for the single byte AA
            if remainingString.count >= 2 {
                let aStart = remainingString.startIndex
                let aEnd = remainingString.index(aStart, offsetBy: 2)
                let aString = String(remainingString[aStart..<aEnd]) // AA (SOC Percentage)
                
                if let socVal = Int(aString, radix: 16) {
                    // Ensure value does not exceed the specification limit of 100
                    let finalSOC = min(socVal, 100)
                    self.mcuSOC = "\(finalSOC)%"
                }
            }
        }
        
        // Custom EV MCU Cell Telemetry Matrix ("62DD86", "62DD87", "62DD88", "62DD89")
        let cellDIDs = ["62DD86", "62DD87", "62DD88", "62DD89"]
        for did in cellDIDs {
            if let range = rawString.range(of: did) {
                let dataStartIndex = range.upperBound
                let remainingString = rawString[dataStartIndex...]
                
                if remainingString.count >= 4 {
                    let aStart = remainingString.startIndex
                    let aEnd = remainingString.index(aStart, offsetBy: 2)
                    let bEnd = remainingString.index(aEnd, offsetBy: 2)
                    
                    let aString = String(remainingString[aStart..<aEnd]) // AA (Low Byte)
                    let bString = String(remainingString[aEnd..<bEnd])   // BB (High Byte)
                    
                    if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                        // Reconstruct signed Int16 format (BB:AA)
                        let signedBB = Int8(bitPattern: UInt8(bVal))
                        let rawSignedValue = (Int(signedBB) * 256) + aVal
                        
                        // Equation: Int16(BB:AA) / 10000
                        let voltageValue = Double(rawSignedValue) * 0.0001
                        let formattedResult = String(format: "%.4f V", voltageValue)
                        
                        // Route to matching UI container
                        switch did {
                        case "62DD86": self.cellMin = formattedResult
                        case "62DD87": self.cellMax = formattedResult
                        case "62DD88": self.cellMean = formattedResult
                        case "62DD89": self.cellStdDev = formattedResult
                        default: break
                        }
                    }
                }
            }
        }

    }




}
