//
//  ContentView.swift
//  PanlongBlB04
//
//  Created by Sylvia Wake-Hood on 7/7/26.
//
import SwiftUI

struct OBD2DashboardView: View {
    @State private var bluetoothManager = OBD2ConnectionManager()
    @State private var customCommand: String = ""
    @FocusState private var isInputActive: Bool // Focus state to track keyboard presence
    
    var body: some View {
        NavigationView {
            // FIX 1: Wrap everything in a top-level ScrollView so fields can glide upwards
            ScrollView {
                VStack(spacing: 20) {
                    
                    // Hardware Connection Card
                    VStack(spacing: 8) {
                        Text("Hardware Node Connection")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(bluetoothManager.connectionStatus)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(statusColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    
                    // 1. Toyota Camry Hybrid Module (RPM)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Toyota Camry Hybrid Speed")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .fontWeight(.bold)
                            Text(bluetoothManager.engineRPM)
                                .font(.system(.title, design: .rounded))
                                .fontWeight(.black)
                        }
                        Spacer()
                        Button(action: {
                            bluetoothManager.sendCommand("01 0C") // Option A: 01 0C maps to a 02 01 0C CAN frame
                        }) {
                            Text("Query RPM")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(bluetoothManager.connectionStatus == "Connected" ? Color.blue : Color.secondary.opacity(0.3))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(bluetoothManager.connectionStatus != "Connected")
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    
                    // 2. Custom EV device Layout Module (MCU Run Time)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("EV Master Control Unit (MCU)")
                                .font(.caption)
                                .foregroundColor(.green)
                                .fontWeight(.bold)
                            Text(bluetoothManager.mcuRunTime)
                                .font(.system(.title, design: .rounded))
                                .fontWeight(.black)
                        }
                        Spacer()
                        Button(action: {
                            bluetoothManager.sendCommand("01 1F") // Option A: 01 1F maps to a 02 01 1F CAN frame
                        }) {
                            Text("Query MCU")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(bluetoothManager.connectionStatus == "Connected" ? Color.green : Color.secondary.opacity(0.3))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(bluetoothManager.connectionStatus != "Connected")
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    
                    // Global Action Control Panel
                    HStack(spacing: 15) {
                        if bluetoothManager.connectionStatus == "Connected" {
                            Button(action: { bluetoothManager.disconnect() }) {
                                Text("Disconnect Link")
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.red.opacity(0.1))
                                    .foregroundColor(.red)
                                    .cornerRadius(10)
                            }
                        } else {
                            Button(action: { bluetoothManager.startScanning() }) {
                                HStack {
                                    if bluetoothManager.isScanning { ProgressView().padding(.trailing, 5) }
                                    Text(bluetoothManager.isScanning ? "Locating Adapter..." : "Establish Interface Connection")
                                }
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .disabled(bluetoothManager.isScanning)
                        }
                    }
                    
                    // FIX 2: Manual Console Hex Overrides moved higher or within natural scroll bounds
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Manual Direct HEX Injection")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            TextField("e.g. 01 00", text: $customCommand)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.allCharacters)
                                .disableAutocorrection(true)
                                .focused($isInputActive) // Track focus state here
                            
                            Button("Inject") {
                                bluetoothManager.sendCommand(customCommand)
                                customCommand = ""
                                isInputActive = false // Dismiss keyboard upon sending
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(bluetoothManager.connectionStatus != "Connected" || customCommand.isEmpty)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    
                    // Active Diagnostic Trace Monitor
                    VStack(alignment: .leading) {
                        Text("Bus Active Line Traces")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<bluetoothManager.receivedLogs.count, id: \.self) { index in
                                        Text(bluetoothManager.receivedLogs[index])
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.green)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(index)
                                    }
                                }
                                .padding(10)
                            }
                            .frame(height: 180) // Lock tracing frame size so it fits perfectly on smaller devices
                            .background(Color.black)
                            .cornerRadius(8)
                            .onChange(of: bluetoothManager.receivedLogs.count) { _, newValue in
                                if newValue > 0 {
                                    withAnimation { proxy.scrollTo(newValue - 1) }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("EV & Vehicle Interlock")
            // FIX 3: Keyboard access controller overlay toolbar item button
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isInputActive = false
                    }
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch bluetoothManager.connectionStatus {
        case "Connected": return .green
        case "Scanning...", "Connecting...": return .orange
        case "Ready to Scan": return .blue
        default: return .red
        }
    }
}

