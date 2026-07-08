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
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                
                // Status Header Card
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
                
                // 1. Toyota Camry Hybrid Layout Module (RPM)
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
                        bluetoothManager.sendCommand("01 0C") // Send OBD2 request to Toyota
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
                        bluetoothManager.sendCommand("02 01 1F") // Send raw message packet to MCU
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
                
                // Manual Console Hex Overrides
                HStack {
                    TextField("Manual Direct HEX string injection", text: $customCommand)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    
                    Button("Inject") {
                        bluetoothManager.sendCommand(customCommand)
                        customCommand = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bluetoothManager.connectionStatus != "Connected" || customCommand.isEmpty)
                }
                
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
            .background(Color(.systemGroupedBackground))
            .navigationTitle("EV & Vehicle Interlock")
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


// SwiftUI Preview Engine Layout Canvas
struct OBD2DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        OBD2DashboardView()
    }
}

