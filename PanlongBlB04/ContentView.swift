//
//  ContentView.swift
//  PanlongBlB04
//
//  Created by Sylvia Wake-Hood on 7/7/26.
//

import SwiftUI

struct OBD2DashboardView: View {
    @StateObject private var bluetoothManager = OBD2ConnectionManager()
    @State private var customCommand: String = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                
                // Status Header Card
                VStack(spacing: 8) {
                    Text("Connection State")
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
                
                // Live Metric Display
                HStack {
                    VStack(alignment: .leading) {
                        Text("Engine Speed")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(bluetoothManager.engineRPM)
                            .font(.system(.title, design: .rounded))
                            .fontWeight(.black)
                    }
                    Spacer()
                    Button(action: {
                        bluetoothManager.sendCommand("01 0C") // Standard Request RPM PID
                    }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title)
                    }
                    .disabled(bluetoothManager.connectionStatus != "Connected")
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                
                // Action Control Panel
                HStack(spacing: 15) {
                    if bluetoothManager.connectionStatus == "Connected" {
                        Button(action: { bluetoothManager.disconnect() }) {
                            Text("Disconnect")
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
                                if bluetoothManager.isScanning {
                                    ProgressView()
                                        .padding(.trailing, 5)
                                }
                                Text(bluetoothManager.isScanning ? "Scanning..." : "Connect Device")
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
                
                // Send Manual Hex Command
                HStack {
                    TextField("Enter custom command (e.g. 01 00)", text: $customCommand)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    
                    Button("Send") {
                        bluetoothManager.sendCommand(customCommand)
                        customCommand = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bluetoothManager.connectionStatus != "Connected" || customCommand.isEmpty)
                }
                
                // Console Serial Stream Monitor
                VStack(alignment: .leading) {
                    Text("Console Output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                    
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
                        .onChange(of: bluetoothManager.receivedLogs.count) { oldValue, newValue in
                            if newValue > 0 {
                                withAnimation {
                                    proxy.scrollTo(newValue - 1)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Panlong Diagnostic")
        }
    }
    
    // Status visual color selector helper
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

