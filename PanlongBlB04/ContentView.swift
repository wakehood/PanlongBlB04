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
                    // Status Header Connection Display Card
                    VStack(spacing: 4) {
                        Text("Hardware Node Connection").font(.caption).foregroundColor(.secondary)
                        Text(bluetoothManager.connectionStatus) // Renders Scanning..., Connecting..., Connected
                            .font(.body).fontWeight(.bold).foregroundColor(statusColor)
                    }
                    .frame(maxWidth: .infinity).padding(10).background(Color(.systemBackground)).cornerRadius(10).shadow(radius: 1)
                    
                    // System Fault Indicator Warning Flags Panel Block
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
                    
                    // Core Telemetry Parameter Rows
                    Group {
                        MetricRow(title: "MCU RunTime", color: .green, val: bluetoothManager.mcuRunTime, cmd: "01 1F", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "MCU Version", color: .blue, val: bluetoothManager.mcuVersion, cmd: "22 DD 80", btn: "Query", bm: bluetoothManager)
                        MetricRow(title: "MCU Pack Voltage", color: .purple, val: bluetoothManager.mcuPackVoltage, cmd: "22 DD 83", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "MCU Pack Current", color: .orange, val: bluetoothManager.mcuPackCurrent, cmd: "22 DD 84", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Pack State of Charge", color: .cyan, val: bluetoothManager.mcuSOC, cmd: "22 DD 85", btn: "Live", bm: bluetoothManager)
                    }
                    
                    // Battery Cell Parameter Rows
                    Group {
                        MetricRow(title: "Cell Minimum", color: .indigo, val: bluetoothManager.cellMin, cmd: "22 DD 86", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Cell Maximum", color: .pink, val: bluetoothManager.cellMax, cmd: "22 DD 87", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Cell Mean", color: .teal, val: bluetoothManager.cellMean, cmd: "22 DD 88", btn: "Live", bm: bluetoothManager)
                        MetricRow(title: "Cell Std Dev", color: .red, val: bluetoothManager.cellStdDev, cmd: "22 DD 89", btn: "Live", bm: bluetoothManager)
                    }
                    
                    // Burst Performance Test Toggle Card
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DD84 Burst Performance Test").font(.caption).foregroundColor(.orange).fontWeight(.bold)
                            if bluetoothManager.isBurstTesting {
                                Text("Run #\(bluetoothManager.burstRunCount + 1) \u{2014}  Sent: \(bluetoothManager.burstSentCount)   Rcvd: \(bluetoothManager.burstReplyCount)   TO: \(bluetoothManager.burstTimeoutCount)")
                                    .font(.system(.caption2, design: .monospaced)).foregroundColor(.orange)
                            }
                        }
                        Spacer()
                        Button("Start Test") { bluetoothManager.startBurstTest() }
                            .font(.caption2).fontWeight(.bold).padding(8)
                            .background(bluetoothManager.isBurstTesting || bluetoothManager.connectionStatus != "Connected" ? Color.secondary.opacity(0.3) : Color.orange)
                            .foregroundColor(.white).cornerRadius(6)
                            .disabled(bluetoothManager.connectionStatus != "Connected" || bluetoothManager.isBurstTesting)
                    }
                    .frame(maxWidth: .infinity).padding(10).background(Color(.systemBackground)).cornerRadius(10)

                    // Active Console Line Trace Output Window Terminal
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

struct AlertLamp: View {
    let name: String; let state: Int
    var body: some View {
        VStack(spacing: 4) {
            Circle().fill(state == 1 ? Color.red : Color.green).frame(width: 14, height: 14).shadow(color: state == 1 ? Color.red : Color.clear, radius: 4)
            Text(name).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.vertical, 6).background(Color(.systemGroupedBackground).opacity(0.5)).cornerRadius(6)
    }
}

#Preview { ContentView() }


