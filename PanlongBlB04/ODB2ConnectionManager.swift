import Foundation
import CoreBluetooth
import Observation // 1. Import Observation framework

@Observable // 2. Add the Macro here
class OBD2ConnectionManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // 3. Remove @Published keywords (they are no longer needed!)
    var connectionStatus: String = "Disconnected"
    var isScanning: Bool = false
    var receivedLogs: [String] = []
    var engineRPM: String = "-- RPM"
    var engineRunTime: String = "-- seconds"

    private var incomingBuffer: String = ""
    
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    
    private let serialServiceUUID = CBUUID(string: "FFF0")
    private let writeCharacteristicUUID = CBUUID(string: "FFF1")
    private let notifyCharacteristicUUID = CBUUID(string: "FFF2")
    


    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        logMessage("Scanning for Panlong adapter (FFF0 Profile)...")
        isScanning = true
        connectionStatus = "Scanning..."
        centralManager.scanForPeripherals(withServices: [serialServiceUUID], options: nil)
    }
    
    func disconnect() {
        if let peripheral = obdPeripheral { centralManager.cancelPeripheralConnection(peripheral) }
    }
    
    func sendCommand(_ command: String) {
        guard let peripheral = obdPeripheral, let characteristic = txCharacteristic else {
            logMessage("Error: No Tx channel assigned yet.")
            return
        }
        
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
    
    // MARK: - CoreBluetooth Delegates
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { self.connectionStatus = central.state == .poweredOn ? "Ready to Scan" : "Bluetooth Off" }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        logMessage("Discovered hardware unit: \(peripheral.name ?? "Unknown Device")")
        
        centralManager.stopScan()
        obdPeripheral = peripheral
        obdPeripheral?.delegate = self
        DispatchQueue.main.async { self.isScanning = false; self.connectionStatus = "Connecting..." }
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { self.connectionStatus = "Connected" }
        logMessage("Connected to hardware layer.")
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
        
        logMessage("Discovered characteristics for FFF0. Inspecting properties...")
        
        for characteristic in characteristics {
            let props = characteristic.properties
            
            // 1. Look for the channel that allows writing
            if props.contains(.write) || props.contains(.writeWithoutResponse) {
                self.txCharacteristic = characteristic
                logMessage("Tx Channel Found: \(characteristic.uuid) (Write)")
            }
            
            // 2. Look for the channel that allows notifications/reading
            if props.contains(.notify) || props.contains(.read) {
                self.rxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                logMessage("Rx Channel Found: \(characteristic.uuid) (Notify)")
            }
        }
        
        // 3. Trigger the handshake once both channels are verified and swapped
        if txCharacteristic != nil && rxCharacteristic != nil {
            logMessage("Duplex pipes safely inverted. Starting AT Z Handshake...")
            initializeCANProtocol()
        } else {
            logMessage("Error: Could not locate a complete matching Tx/Rx pair.")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == rxCharacteristic?.uuid,
              let data = characteristic.value,
              let fragment = String(data: data, encoding: .utf8) else { return }
        
        // Append the new fragment to our ongoing buffer
        incomingBuffer += fragment
        
        // The ELM327 signals the end of a complete response using the '>' character
        if incomingBuffer.contains(">") || incomingBuffer.contains("\r") {
            let completeResponse = incomingBuffer
            incomingBuffer = "" // Clear the buffer for the next message
            
            // Log and parse the full, stitched-together response
            let cleanedResponse = completeResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedResponse.isEmpty {
                logMessage("Received: \(cleanedResponse)")
                parseCANResponse(cleanedResponse)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logMessage("Write Execution Error: \(error.localizedDescription)")
        }
    }

    
    // MARK: - CAN Protocol Handshake Sequence
    private func initializeCANProtocol() {
        // Extend spacing intervals to 0.8 seconds to accommodate cheap microcontroller lag
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.sendCommand("AT Z") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.sendCommand("AT H1") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.sendCommand("AT SP 6") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { self.sendCommand("AT SH 7DF") }
    }

    
    // MARK: - CAN Response Parser
    private func parseCANResponse(_ response: String) {
        // 1. Clean the incoming string
        let cleanText = response.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        var components = cleanText.components(separatedBy: " ").filter { !$0.isEmpty && $0 != ">" }
        
        guard !components.isEmpty else { return }
        
        // 2. Handle ELM327 Version Signature directly on connection
        if response.contains("ELM327") {
            logMessage("Verified Authentic ELM327 Module Interlock.")
            return
        }
        
        // 3. Strip out the command echo if the ELM327 mirrored it back
        // If the string starts with our request bytes, remove them to isolate the ECU response
        if components.first == "02" && components.count > 3 {
            // Looks like an echo chain "02 01 1F 7E8 ...", drop the first 3 tokens
            if components[1] == "01" && (components[2] == "1F" || components[2] == "0C") {
                components.removeFirst(3)
            }
        } else if components.first == "02011F" || components.first == "010C" {
            // Packed echo style, drop the first token
            components.removeFirst()
        }
        
        // 4. Validate our isolated CAN address footprint
        guard let firstElement = components.first, firstElement == "7E8" else { return }
        
        // 5. Execute core state machine data extraction
        if components.contains("41") {
            if let modeIndex = components.firstIndex(of: "41"), modeIndex + 3 < components.count {
                let receivedPID = components[modeIndex + 1]
                let aString = components[modeIndex + 2]
                let bString = components[modeIndex + 3]
                
                guard let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) else { return }
                
                switch receivedPID {
                case "0C":
                    let rpm = ((aVal * 256) + bVal) / 4
                    DispatchQueue.main.async { self.engineRPM = "\(rpm) RPM" }
                case "1F":
                    let totalSeconds = (aVal * 256) + bVal
                    DispatchQueue.main.async { self.engineRunTime = "\(totalSeconds) sec" }
                default:
                    break
                }
            }
        }
    }

}
