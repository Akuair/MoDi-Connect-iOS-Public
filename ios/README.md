# MoDi Connect for iOS

原生 SwiftUI LAN 发送端，目标是把 iPhone 系统音频发送到现有 Windows MoDi Connect 的 `SpeakerOnly` 路线。Windows 不需要虚拟声卡、VB-CABLE 或更改默认输出设备。

> 当前状态：已接入独立 Swift 兼容 codec，用仓库原版 .NET 0.1.1 协议库验证了四个固定 wire 样例。iOS 不再依赖官方 iOS SDK。实际 Swift 执行、Xcode 编译和真机音频链路仍待验证。详见 [WIRE-COMPATIBILITY.md](WIRE-COMPATIBILITY.md)。

## Requirements

- Xcode 27 或兼容 iOS 27 SDK 的更新版本
- iOS 27+ 的实体 iPhone（系统音频捕获应以真机验证）
- iPhone 与 Windows PC 位于同一局域网
- 本地网络权限（`NSLocalNetworkUsageDescription`）
- Bonjour 权限声明（`NSBonjourServices` 包含 `_modi._udp`）
- 用户通过系统 `SCContentSharingPicker` 明确选择共享内容
- 屏幕捕获用途说明和 `screen-capture` background mode

系统捕获遵循公开 ScreenCaptureKit API，不使用 private API。受保护/DRM 音频是否可捕获由 iOS 和内容提供方决定。

云端 Xcode 27 beta 6 实际 SDK 检查：ScreenCaptureKit 仅存在于 iPhoneOS SDK，不存在于 iPhoneSimulator SDK。模拟器可运行协议、Opus、帧组装单元测试，但开始捕获会明确报错，不能用模拟器验证系统音频。iOS 不提供 macOS 的 `queueDepth` / `minimumFrameInterval` 配置；接收的视频帧直接丢弃，不声称已降至 1 fps。

## Build

1. 在 macOS 安装 Xcode 27，打开 `ios/MoDiConnect.xcodeproj`。
2. Xcode 将解析固定为 `0.3.0` 的 `sbooth/opus-binary-xcframework`，以及该二进制声明需要的 `sbooth/ogg-binary-xcframework` `0.1.3`。
3. 在 Signing & Capabilities 中选择自己的 Development Team，并按需要更换 bundle identifier。
4. 默认已使用 `CompatibleMoDiProtocolAdapter`，不需要另行安装 MoDi iOS SDK。
5. 选择 iOS 27 模拟器做编译/单元测试；系统音频和端到端测试使用实体 iPhone。

命令行（无签名模拟器构建）：

```bash
xcodebuild -resolvePackageDependencies \
  -project ios/MoDiConnect.xcodeproj \
  -scheme MoDiConnect

xcodebuild build-for-testing \
  -project ios/MoDiConnect.xcodeproj \
  -scheme MoDiConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test-without-building \
  -project ios/MoDiConnect.xcodeproj \
  -scheme MoDiConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

仓库同时提供 `.github/workflows/ios-build.yml`，用于 GitHub 的 Xcode 27 runner。runner 镜像或设备名变化时，先用 `xcrun simctl list devices available` 确认可用 destination。

### Cloud IPA package

在你有写权限的私有研究仓库中提交完整源码后，`iOS build` workflow 会执行协议交叉测试、模拟器测试、真机 arm64 Release 构建，并上传 `MoDiConnect-unsigned-ipa` artifact（保留7天）。其中包含未签名 IPA、SHA-256 和安装说明。该 IPA 需要个人签名后才能安装到 iPhone，不能直接当作已签名应用安装。构建失败不会上传 IPA；测试结果单独保留。

当前尚未运行云编译。原作者仓库对当前连接的 GitHub 账号只有读取权限，需使用用户指定的有写权限的仓库。若需要云端直接输出已签名 IPA，还需通过安全的签名配置提供 Apple 证书与匹配的 provisioning profile；不要将私钥提交到源码仓库。

## Run

1. 安装并启动 App；允许“本地网络”访问。
2. App 通过 `_modi._udp` 查找 Windows 服务，并显示设备名、解析后的地址及音频端口。
3. 选择 PC 并连接。客户端向该主机 UDP 12347 发送 SpeakerOnly HELLO。
4. 点击“开始传输”，在系统 picker 中选择整个显示内容。
5. `.audio` sample buffer 被转换为 48 kHz mono PCM16LE，按 960 samples 拼帧、Opus 编码并发往 Bonjour 广告的 UDP 12345。
6. 停止共享可从系统 UI 或 App 内“停止”执行。

当前默认 adapter 使用已对照原库验证的 wire 格式，完成 HELLO/ACK 与音频包封装。

## Connect to Windows

1. 在 Windows 打开现有 MoDi Connect。
2. 让 Windows 与 iPhone 连接同一 LAN，并允许 Windows 防火墙接收 UDP 12345/12347。
3. iPhone 打开 MoDi Connect，选择发现的电脑并连接。
4. iOS 固定请求 route `0` / `SpeakerOnly`。
5. 点击“开始传输”并完成系统共享 picker。
6. 在 Safari、Apple Music 或游戏中播放允许捕获的内容。
7. Windows 通过现有 `SpeakerRenderer` 在当前默认扬声器/耳机播放；无需 VB-CABLE。

## Tests

- `PCMFrameAssemblerTests`：以任意 chunk 大小输入，验证每帧始终 1920 bytes，且无丢失/重复。
- `OpusEncoderTests`：生成 1 kHz、48 kHz mono、20 ms 正弦波；libopus 编码再解码，验证 960 samples。
- `ProtocolCompatibilityTests`：验证17-byte HELLO payload、完整 wire 固定样例、回绕序号、截断和异常长度，不再跳过协议测试。
- `DiscoveryIntegrationTests`：在同 LAN 的 Mac 上设置 `MODI_RUN_LAN_TESTS=1` 后，等待解析出 UDP 12345 的真实 Windows 服务；普通 CI 明确 skip。
- `EndToEndIntegrationTests`：保留不可自动化的真机验收入口。系统 picker 需要用户操作，最终验收依照下方清单执行并记录结果。

## Known limitations

- 当前交付用于用户指定的个人互操作研究；不代表协议所有者授权或认证。未进行公开发布。
- Xcode/真机验收尚未执行；协议样例通过不等于实际系统音频播放通过。
- iOS 系统音频捕获必须经过系统 picker，用户可随时停止；App 无法静默绕过授权。
- 后台、锁屏、通话、音频 route 变化和系统压力均可能终止 capture；实现会退出 streaming 并显示失败/重连状态，但最终行为必须在 iOS 27 真机确认。
- DRM/受保护内容可能被静音或禁止捕获。
- `screen-capture` background mode 及相关 API 的 App Store 审核/发布支持应在提交前用当期 Xcode 和 App Store Connect 验证。
- 当前重连与 Android 一致，固定原 host、2 秒间隔、最多 5 次；IP 变化后需要重新发现并选择。
- UI 延迟值只含发送侧 20 ms frame 下限；未获得 Windows 回传测量，因此不声称是实际端到端延迟。

## Protocol compatibility checks

兼容 adapter 把下列 semantic packet 映射到 MoDi Protocol 0.1.1（wire version 2）：

- HELLO: type HELLO、link WIFI_LAN、sequence 0、payload `route(0) + UUID(16-byte network order)`
- HELLO_ACK: 校验 type 与相同 session UUID
- AUDIO: type AUDIO、link WIFI_LAN、递增 UInt32 sequence、payload 为纯 Opus packet

在仓库根目录运行 `dotnet run --project ios/Tools/ProtocolProbe`，使用现有 .NET 二进制验证 Swift 测试中的固定样例。macOS/GitHub Actions 还会编译生产 Swift codec，生成224个包交给同一 .NET 二进制验证。具体命令见 WIRE-COMPATIBILITY.md。下一步仍须进行 `iPhone → existing Windows → current default speaker` 真机验收。

