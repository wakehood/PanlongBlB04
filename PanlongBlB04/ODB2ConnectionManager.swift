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
        guard let peripheral = obdPeripheral, let characteristic = txCharacteristic else { return }
        
        let fullCommand = command + "\r"
        if let data = fullCommand.data(using: .utf8) {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
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
        for characteristic in characteristics {
            if characteristic.uuid == writeCharacteristicUUID { self.txCharacteristic = characteristic }
                logMessage("Tx Channel Active: FFF1 (Write)")
            if characteristic.uuid == notifyCharacteristicUUID {
                self.rxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                logMessage("Rx Channel Active: FFF2 (Notify)")
            }
        }
        if txCharacteristic != nil && rxCharacteristic != nil {
            logMessage("Full FFF0 duplex pipe open.")
            initializeCANProtocol() }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharacteristicUUID,
              let data = characteristic.value,
              let response = String(data: data, encoding: .utf8) else { return }
        
        let cleanedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        logMessage("Received: \(cleanedResponse)")
        parseCANResponse(cleanedResponse)
    }
    
    // MARK: - CAN Protocol Handshake Sequence
    private func initializeCANProtocol() {
        let delayStep = 0.4
        
        // 1. Reset device
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 1) { self.sendCommand("AT Z") }
        // 2. Turn Headers ON so we can explicitly see 7E8 in the data stream
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 2) { self.sendCommand("AT H1") }
        // 3. Set protocol to ISO 15765-4 (CAN 11-bit ID, 500 kbps) - standard for most modern cars
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 3) { self.sendCommand("AT SP 6") }
        // 4. Force Transmit Header identifier to Functional ID 7DF
        DispatchQueue.main.asyncAfter(deadline: .now() + delayStep * 4) { self.sendCommand("AT SH 7DF") }
    }
    
    // MARK: - CAN Response Parser
    private func parseCANResponse(_ response: String) {
        // Strip out common text markers if present
        let cleanText = response.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let components = cleanText.components(separatedBy: " ").filter { !$0.isEmpty }
        
        // Confirm response starts with the target ECM source identifier (7E8)
        guard let firstElement = components.first, firstElement == "7E8" else { return }
        
        // Standard CAN frame layout after AT H1 is enabled:
        // components[0] = 7E8 (SID)
        // components[1] = PCI (Protocol Control Information / Data Length)
        // components[2] = Mode/Service (e.g., 41 for Show Current Data)
        // components[3] = PID (e.g., 0C for RPM)
        // components[4] = Data Byte A
        // components[5] = Data Byte B
        
        if components.contains("41") {
             if let modeIndex = components.firstIndex(of: "41"), modeIndex + 3 < components.count {
                 let receivedPID = components[modeIndex + 1]
                 let aString = components[modeIndex + 2]
                 let bString = components[modeIndex + 3]
                 
                 guard let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) else { return }
                 
                 switch receivedPID {
                 case "0C": // RPM Response
                     let rpm = ((aVal * 256) + bVal) / 4
                     DispatchQueue.main.async { self.engineRPM = "\(rpm) RPM" }
                     
                 case "1F": // PID 0x1F: Time Since Engine Start Response
                     // Formula for PID 1F: (A * 256) + B total seconds
                     let totalSeconds = (aVal * 256) + bVal
                     DispatchQueue.main.async { self.engineRunTime = "\(totalSeconds) sec" }
                     
                 default:
                     break
                 }
             }
         }
    }
}
