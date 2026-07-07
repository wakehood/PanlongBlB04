import Foundation
import CoreBluetooth
import Combine

class OBD2ConnectionManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // SwiftUI observable states
    @Published var connectionStatus: String = "Disconnected"
    @Published var isScanning: Bool = false
    @Published var receivedLogs: [String] = []
    @Published var engineRPM: String = "-- RPM"
    
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?
    
    // Split pipelines required by the FFF0 specification
    private var txCharacteristic: CBCharacteristic? // Write pipe
    private var rxCharacteristic: CBCharacteristic? // Read/Notify pipe
    
    // Corrected Panlong / LELink Specific UUIDs
    private let serialServiceUUID = CBUUID(string: "FFF0")
    private let writeCharacteristicUUID = CBUUID(string: "FFF1") // Property: .write / .writeWithoutResponse
    private let notifyCharacteristicUUID = CBUUID(string: "FFF2") // Property: .notify / .read

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            logMessage("Bluetooth is not turned on.")
            return
        }
        logMessage("Scanning for Panlong adapter (FFF0 Profile)...")
        isScanning = true
        connectionStatus = "Scanning..."
        
        // Scan specifically filtering for your service UUID to improve efficiency
        centralManager.scanForPeripherals(withServices: [serialServiceUUID], options: nil)
    }
    
    func disconnect() {
        if let peripheral = obdPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    func sendCommand(_ command: String) {
        // Enforce using the dedicated FFF1 Tx write channel
        guard let peripheral = obdPeripheral, let characteristic = txCharacteristic else {
            logMessage("Error: Write channel (FFF1) not available.")
            return
        }
        
        let fullCommand = command + "\r"
        if let data = fullCommand.data(using: .utf8) {
            // Write to FFF1 channel
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
    
    // MARK: - Central Manager Delegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            if central.state == .poweredOn {
                self.connectionStatus = "Ready to Scan"
            } else {
                self.connectionStatus = "Bluetooth Unavailable"
                self.isScanning = false
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        logMessage("Discovered hardware unit: \(peripheral.name ?? "Unknown Device")")
        
        centralManager.stopScan()
        obdPeripheral = peripheral
        obdPeripheral?.delegate = self
        
        DispatchQueue.main.async {
            self.isScanning = false
            self.connectionStatus = "Connecting..."
        }
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
        logMessage("Pipeline severed.")
    }
    
    // MARK: - Peripheral Delegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serialServiceUUID {
            // Discover both specific characteristics within the FFF0 service
            peripheral.discoverCharacteristics([writeCharacteristicUUID, notifyCharacteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            if characteristic.uuid == writeCharacteristicUUID {
                self.txCharacteristic = characteristic
                logMessage("Tx Channel Active: FFF1 (Write)")
            } else if characteristic.uuid == notifyCharacteristicUUID {
                self.rxCharacteristic = characteristic
                // Subscribe to notifications exclusively on the FFF2 read line
                peripheral.setNotifyValue(true, for: characteristic)
                logMessage("Rx Channel Active: FFF2 (Notify)")
            }
        }
        
        // Initialize once both channels are discovered
        if txCharacteristic != nil && rxCharacteristic != nil {
            logMessage("Full FFF0 duplex pipe open.")
            initializeELM327()
        }
    }
    
    // Data stream intercept on the notify channel (FFF2)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharacteristicUUID else { return }
        guard let data = characteristic.value, let response = String(data: data, encoding: .utf8) else { return }
        
        let cleanedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        logMessage("Received: \(cleanedResponse)")
        parseOBDResponse(cleanedResponse)
    }
    
    // MARK: - ELM327 Setup & Parser
    
    private func initializeELM327() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.sendCommand("AT Z") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.sendCommand("AT SP 0") }
    }
    
    private func parseOBDResponse(_ response: String) {
        if response.contains("41 0C") {
            let components = response.components(separatedBy: " ")
            if let index = components.firstIndex(of: "0C"), index + 2 < components.count {
                let aString = components[index + 1]
                let bString = components[index + 2]
                
                if let aVal = Int(aString, radix: 16), let bVal = Int(bString, radix: 16) {
                    let rpm = ((aVal * 256) + bVal) / 4
                    DispatchQueue.main.async {
                        self.engineRPM = "\(rpm) RPM"
                    }
                }
            }
        }
    }
}
