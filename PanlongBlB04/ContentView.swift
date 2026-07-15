//
//  ContentView.swift
//  PanlongBlB04
//
//  Created by Sylvia Wake-Hood on 7/7/26.
import SwiftUI

struct ContentView: View {
    var body: some View { OBD2DashboardView() }
}

struct OBD2DashboardView: View {
    @State private var bluetoothManager = OBD2ConnectionManager()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    // Status Header Connection Panel
                    VStack(spacing: 4) {
                        Text("Hardware Node Connection").font(.caption).foregroundColor(.secondary)
                        Text(bluetoothManager.connectionStatus).font(.body).fontWeight(.bold).foregroundColor(statusColor)
                    }.frame(maxWidth: .infinity).padding(10).background(Color(.systemBackground)).cornerRadius(10).shadow(radius: 1)
                    
                    // Connection Establishment Control
                    HStack(spacing: 12) {
                        if bluetoothManager.connectionStatus == "Connected" {
                            Button("Disconnect Link") { bluetoothManager.disconnect() }.font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity).padding(10).background(Color.red.opacity(0.1)).foregroundColor(.red).cornerRadius(8)
                        } else {
                            Button(action: { bluetoothManager.startScanning() }) {
                                HStack { if bluetoothManager.isScanning { ProgressView().padding(.trailing, 2) }; Text(bluetoothManager.isScanning ? "Locating..." : "Establish Connection") }
                            }.font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity).padding(10).background(Color.blue).foregroundColor(.white).cornerRadius(8).disabled(bluetoothManager.isScanning)
                        }
                    }
                    
                    // NEW: 1. System Fault Indicator Lamps Display Panel
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MCU Diagnostic Warning Status Flags").font(.caption).foregroundColor(.secondary).fontWeight(.bold)
                        
                        HStack(spacing: 6) {
                            AlertLamp(name: "Hardware", state: bluetoothManager.alertHardware)
                            AlertLamp(name: "CCensus", state: bluetoothManager.alertCCensus)
                            AlertLamp(name: "TCensus", state: bluetoothManager.alertTCensus)
                            AlertLamp(name: "HVC", state: bluetoothManager.alertHVC)
                            AlertLamp(name: "LVC", state: bluetoothManager.alertLVC)
                            AlertLamp(name: "HiTemp", state: bluetoothManager.alertHiTemp)
                            AlertLamp(name: "LoTemp", state: bluetoothManager.alertLoTemp)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(10).background(Color(.systemBackground)).cornerRadius(10)
                    
                    // 2. Core Telemetry Parameter Displays
                    Group {
                        MetricRow(title: "MCU RunTime", color: .green, val: bluetoothManager.mcuRunTime, cmd: "01 1F", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "MCU Version", color: .blue, val: bluetoothManager.mcuVersion, cmd: "22 DD 80", btn: "Query", bm: bluetoothManager)
                        MetricRow(title: "MCU Pack Voltage", color: .purple, val: bluetoothManager.mcuPackVoltage, cmd: "22 DD 83", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "MCU Pack Current", color: .orange, val: bluetoothManager.mcuPackCurrent, cmd: "22 DD 84", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Pack State of Charge", color: .cyan, val: bluetoothManager.mcuSOC, cmd: "22 DD 85", btn: "Live", bm: bluetoothManager)
                    }
                    
                    // 3. Battery Cell Voltage Parameter Displays
                    Group {
                        MetricRow(title: "Cell Minimum", color: .indigo, val: bluetoothManager.cellMin, cmd: "22 DD 86", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Cell Maximum", color: .pink, val: bluetoothManager.cellMax, cmd: "22 DD 87", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Cell Mean", color: .teal, val: bluetoothManager.cellMean, cmd: "22 DD 88", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Cell Std Dev", color: .red, val: bluetoothManager.cellStdDev, cmd: "22 DD 89", btn: "Live", bm: bluetoothManager)
                    }
                    
                    // 4. Terminal Activity Log window
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bus Active Line Traces").font(.caption2).foregroundColor(.secondary)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(0..<bluetoothManager.receivedLogs.count, id: \.self) { index in
                                        Text(bluetoothManager.receivedLogs[index]).font(.system(.caption2, design: .monospaced)).foregroundColor(.green).frame(maxWidth: .infinity, alignment: .leading).id(index)
                                    }
                                }
                                .padding(6)
                            }
                            .frame(height: 80).background(Color.black).cornerRadius(6)
                            .onChange(of: bluetoothManager.receivedLogs.count) { _, newValue in
                                if newValue > 0 { withAnimation { proxy.scrollTo(newValue - 1) } }
                            }
                        }
                    }
                }.padding(.horizontal, 12).padding(.top, 10)
            }
            .background(Color(.systemGroupedBackground)).navigationTitle("MCU Monitor")
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

// Subview Component for specific Row Layouts
struct MetricRow: View {
    let title: String; let color: Color; let val: String; let cmd: String; let btn: String; let bm: OBD2ConnectionManager
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundColor(color).fontWeight(.bold)
                Text(val).font(.system(.body, design: .rounded)).fontWeight(.black)
            }
            Spacer()
            Button(btn) { bm.sendCommand(cmd) }.font(.caption2).fontWeight(.bold).padding(8).background(bm.connectionStatus == "Connected" ? color : Color.secondary.opacity(0.3)).foregroundColor(.white).cornerRadius(6).disabled(bm.connectionStatus != "Connected")
        }.padding(10).background(Color(.systemBackground)).cornerRadius(10)
    }
}

// NEW: Subview Component for individual Status Indicator Lamps
struct AlertLamp: View {
    let name: String
    let state: Int
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                // Shifts color natively: 0 = Green (Safe), 1 = Red (Active Fault Condition)
                .fill(state == 1 ? Color.red : Color.green)
                .frame(width: 14, height: 14)
                // Adds a soft visual glow effect ring if a flag trips
                .shadow(color: state == 1 ? Color.red : Color.clear, radius: 4)
            
            Text(name)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground).opacity(0.5))
        .cornerRadius(6)
    }
}

#Preview { ContentView() }


