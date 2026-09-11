import CoreImage.CIFilterBuiltins
import SwiftUI

struct ManualConnectionView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var audioPort = "12345"
    @State private var handshakePort = "12347"
    @State private var errorMessage: String?
    @State private var showingScanner = false
    @State private var code: UIImage?
    @State private var codeText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Windows 局域网地址") {
                    TextField("IP 地址，例如 192.168.1.100", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("音频 UDP 端口", text: $audioPort).keyboardType(.numberPad)
                    TextField("握手 UDP 端口", text: $handshakePort).keyboardType(.numberPad)
                }
                Section {
                    Button("连接电脑") { connect() }.disabled(!app.canConnect)
                    Button("扫描 LAN 二维码", systemImage: "qrcode.viewfinder") { showingScanner = true }
                    Button("用此地址生成二维码", systemImage: "qrcode") { generateCode() }
                } footer: {
                    Text("默认：音频 12345、握手 12347。电脑端保持 LAN 模式，双方连接同一网络。扫码只填入地址，确认后才连接。Windows 现有 Wi-Fi Direct 配对码不适用于 LAN。")
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                if let code {
                    Section("LAN 地址分享码（不是 Windows 配对码）") {
                        Image(uiImage: code).interpolation(.none).resizable().scaledToFit()
                            .padding(16).background(.white)
                        Text(codeText).font(.caption).textSelection(.enabled)
                        ShareLink("分享连接文本", item: codeText)
                    }
                }
            }
            .navigationTitle("手动 / 扫码连接")
            .toolbar { Button("关闭") { dismiss() } }
            .onChange(of: host) { _, _ in clearCode() }
            .onChange(of: audioPort) { _, _ in clearCode() }
            .onChange(of: handshakePort) { _, _ in clearCode() }
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    QRCodeScanner { result in
                        showingScanner = false
                        do {
                            let address = try LANConnectionAddress.parseQR(result.get())
                            host = address.host
                            audioPort = String(address.audioPort)
                            handshakePort = String(address.handshakePort)
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .navigationTitle("扫描 LAN 连接码")
                    .toolbar { Button("取消") { showingScanner = false } }
                }
            }
        }
    }
    private func address() throws -> LANConnectionAddress {
        try LANConnectionAddress(host: host, audioPort: audioPort, handshakePort: handshakePort)
    }
    private func connect() {
        do {
            let target = try address()
            app.selectManual(target)
            dismiss()
            Task { await app.connectSelected() }
        } catch { errorMessage = error.localizedDescription }
    }
    private func clearCode() { code = nil; codeText = "" }
    private func generateCode() {
        do {
            let target = try address()
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(target.qrText.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output, from: output.extent) else { return }
            code = UIImage(cgImage: image)
            codeText = target.qrText
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

