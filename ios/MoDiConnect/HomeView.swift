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
                        LabeledContent("发送缓冲（非端到端延迟）", value: "\(app.metrics.queuedMilliseconds) ms")
                        LabeledContent("Packet rate", value: String(format: "%.1f pps", app.metrics.packetRate))
                        LabeledContent("Bitrate", value: String(format: "%.1f kbps", app.metrics.bitrate / 1_000))
                        LabeledContent("本地积压丢帧", value: "\(app.metrics.droppedFrames)")
                        LabeledContent("捕获不足补静音", value: "\(app.metrics.concealedFrames)")
                        LabeledContent("发送调度迟到", value: "\(app.metrics.lateTicks)")
                        LabeledContent("最近最大捕获间隔", value: String(format: "%.1f ms", app.metrics.maximumCaptureGapMilliseconds))
                        Text("补静音也可能是源 App 暂停。统计不是网络丢包率，Windows 未提供接收反馈。")
                            .font(.footnote).foregroundStyle(.secondary)
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
                .disabled(!app.canConnect)
                Picker("发送缓冲", selection: $app.senderBufferMilliseconds) {
                    Text("40 ms（默认）").tag(40)
                    Text("80 ms（更耐捕获抖动）").tag(80)
                }
                .disabled(!app.canConnect)
                Text("缓冲增加延迟，不改变 Windows。先试 128 kbps + 40 ms；捕获补静音持续增长时可试 80 ms。音频参数需断开后修改。")
                    .font(.footnote)
                Picker("发送音量衰减", selection: $app.outputAttenuationDB) {
                    Text("0 dB（保持原音量）").tag(0)
                    Text("−6 dB（同时播放时测试）").tag(-6)
                    Text("−12 dB").tag(-12)
                }
                .disabled(!app.canConnect)
                Text("只降低手机送出的电平。若是 2.4 GHz 耳机无线干扰，降低音量或增加缓冲无法修复该无线链路。")
                    .font(.footnote)
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

