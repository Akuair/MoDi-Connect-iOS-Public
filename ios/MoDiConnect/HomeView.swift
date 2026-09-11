import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @State private var showingSettings = false
    @State private var showingManualConnection = false

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("连接", value: app.state.label)
                    LabeledContent("路线", value: "系统音频 → 电脑扬声器")
                }

                Section("发现的设备") {
                    if let message = app.discoveryMessage {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                    if app.devices.isEmpty {
                        ContentUnavailableView("尚未发现电脑", systemImage: "desktopcomputer.and.macbook")
                    }
                    ForEach(app.devices) { device in
                        Button {
                            app.selectedDeviceID = device.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).font(.headline)
                                    Text("\(device.address):\(device.portNumber)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.selectedDeviceID == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!app.canConnect)
                    }
                    Button("重新发现", systemImage: "arrow.clockwise") { app.restartDiscovery() }
                        .disabled(!app.canConnect)
                    Button("手动 IP / 端口 · 扫码连接", systemImage: "qrcode.viewfinder") {
                        showingManualConnection = true
                    }.disabled(!app.canConnect)
                }

                if app.state == .streaming {
                    Section("传输统计") {
                        LabeledContent("Latency", value: String(format: "%.0f ms+", app.metrics.latencyMilliseconds))
                        LabeledContent("Packet rate", value: String(format: "%.1f pps", app.metrics.packetRate))
                        LabeledContent("Bitrate", value: String(format: "%.1f kbps", app.metrics.bitrate / 1_000))
                        LabeledContent("Dropped frames", value: "\(app.metrics.droppedFrames)")
                    }
                }

                Section {
                    actions
                } footer: {
                    Text("与电脑连接同一局域网，系统音频将通过电脑当前默认播放设备输出。")
                }
            }
            .navigationTitle("MoDi Connect")
            .toolbar {
                Button("设置", systemImage: "gear") { showingSettings = true }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingManualConnection) { ManualConnectionView() }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch app.state {
        case .connected:
            Button("开始传输") { Task { await app.startStreaming() } }
            Button("断开连接", role: .destructive) { app.stop() }
        case .streaming, .startingCapture, .reconnecting:
            Button("停止", role: .destructive) { app.stop() }
        case .connecting, .handshaking, .stopping:
            ProgressView()
        default:
            Button("连接") { Task { await app.connectSelected() } }
                .disabled(app.selectedDevice == nil)
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Opus bitrate", selection: $app.bitrate) {
                    Text("64 kbps").tag(64_000)
                    Text("96 kbps").tag(96_000)
                    Text("128 kbps（Android 默认）").tag(128_000)
                }
                Toggle("Debug logging", isOn: $app.debugLogging)
            }
            .navigationTitle("设置")
            .toolbar {
                Button("完成") {
                    app.applySettings()
                    dismiss()
                }
            }
        }
    }
}

