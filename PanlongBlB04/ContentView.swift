//
//  ContentView.swift
//  PanlongBlB04
//
//  Created by Sylvia Wake-Hood on 7/7/26.
//
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
                    // Status Card
                    VStack(spacing: 4) {
                        Text("Hardware Node Connection").font(.caption).foregroundColor(.secondary)
                        Text(bluetoothManager.connectionStatus).font(.body).fontWeight(.bold).foregroundColor(statusColor)
                    }.frame(maxWidth: .infinity).padding(10).background(Color(.systemBackground)).cornerRadius(10).shadow(radius: 1)
                    
                    // Core Hardware Metrics Block
                    Group {
                        MetricRow(title: "MCU RunTime", color: .green, val: bluetoothManager.mcuRunTime, cmd: "01 1F", btn: "Query Run Time", bm: bluetoothManager)
                        MetricRow(title: "MCU Version", color: .blue, val: bluetoothManager.mcuVersion, cmd: "22 DD 80", btn: "Query Version", bm: bluetoothManager)
                        MetricRow(title: "MCU Pack Voltage", color: .purple, val: bluetoothManager.mcuPackVoltage, cmd: "22 DD 83", btn: "Query Voltage", bm: bluetoothManager)
                        MetricRow(title: "MCU Pack Current", color: .orange, val: bluetoothManager.mcuPackCurrent, cmd: "22 DD 84", btn: "Query Current", bm: bluetoothManager)
                        MetricRow(title: "Pack State of Charge", color: .cyan, val: bluetoothManager.mcuSOC, cmd: "22 DD 85", btn: "Query SOC", bm: bluetoothManager)
                    }
                    
                    // Battery Cell Metrics Block
                    Group {
                        MetricRow(title: "Cell Minimum", color: .indigo, val: bluetoothManager.cellMin, cmd: "22 DD 86", btn: "Query Cell Min", bm: bluetoothManager)
                        MetricRow(title: "Cell Maximum", color: .pink, val: bluetoothManager.cellMax, cmd: "22 DD 87", btn: "Query Cell Max", bm: bluetoothManager)
                        MetricRow(title: "Cell Mean", color: .teal, val: bluetoothManager.cellMean, cmd: "22 DD 88", btn: "Query Cell Mean", bm: bluetoothManager)
                        MetricRow(title: "Cell Std Dev", color: .red, val: bluetoothManager.cellStdDev, cmd: "22 DD 89", btn: "Query Cell Std Dev", bm: bluetoothManager)
                    }
                    
                    // Connection Interface Control Panel
                    HStack(spacing: 12) {
                        if bluetoothManager.connectionStatus == "Connected" {
                            Button("Disconnect Link") { bluetoothManager.disconnect() }.font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity).padding(10).background(Color.red.opacity(0.1)).foregroundColor(.red).cornerRadius(8)
                        } else {
                            Button(action: { bluetoothManager.startScanning() }) {
                                HStack { if bluetoothManager.isScanning { ProgressView().padding(.trailing, 2) }; Text(bluetoothManager.isScanning ? "Locating..." : "Establish Connection") }
                            }.font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity).padding(10).background(Color.blue).foregroundColor(.white).cornerRadius(8).disabled(bluetoothManager.isScanning)
                        }
                    }
                    
                    // Text Logging Viewer Window Terminal
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
                            .frame(height: 100).background(Color.black).cornerRadius(6)
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

// Sub-Component Row View to reduce code size and stop file trimming issues
struct MetricRow: View {
    let title: String
    let color: Color
    let val: String
    let cmd: String
    let btn: String
    let bm: OBD2ConnectionManager
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundColor(color).fontWeight(.bold)
                Text(val).font(.system(.body, design: .rounded)).fontWeight(.black)
            }
            Spacer()
            Button(btn) { bm.sendCommand(cmd) }
                .font(.caption2).fontWeight(.bold).padding(8)
                .background(bm.connectionStatus == "Connected" ? color : Color.secondary.opacity(0.3))
                .foregroundColor(.white).cornerRadius(6)
                .disabled(bm.connectionStatus != "Connected")
        }
        .padding(10).background(Color(.systemBackground)).cornerRadius(10)
    }
}

#Preview { ContentView() }



#Preview {
    ContentView()
}



