# MoDi Connect for iOS

原生 SwiftUI LAN 发送端，目标是把 iPhone 系统音频发送到现有 Windows MoDi Connect 的 `SpeakerOnly` 路线。Windows 不需要虚拟声卡、VB-CABLE 或更改默认输出设备。

> 0.1.3 是播放回归修复版：撤回 0.1.2 的音频稳定性改动，恢复用户已确认可播放的 0.1.1 音频路径。0.1.1 保存在 `stable/0.1.1`，commit `19cd9dbf504eaa446e0919074866d8f4a04bb225`；未签名 IPA 安装前需要个人签名。

## 0.1.3 播放回归修复

0.1.2 曾通过编译和单元测试，但用户真机反馈播放几秒后无声，并出现大量本地积压丢帧与调度迟到。这足以撤回该候选策略；仅凭发送端统计，不能断言持续无声的唯一机制或 Windows 接收状态。

修复方式是完整恢复已验证基线，而非增大队列阈值：
- 实际路径恢复为 ScreenCaptureKit → AVAudioConverter → PCM16/960 samples 拼帧 → libopus → 原 MoDi packet → UDP → 现有 Windows SpeakerOnly。
- 去掉定时发送、主动丢弃积压 PCM、补静音、音量衰减和新增 UDP 提交限额；真实捕获帧按基线逻辑发送。
- 48 kHz / mono / PCM16 / 20 ms / 128 kbps / complexity 10 / CVBR / FEC / loss hint 15% 保持基线参数。Windows、协议、握手、端口与路由均不修改。
- 保留 0.1.1 手动 IP/端口、扫码和 Bonjour 功能；删除失效的缓冲/音量设置和伪延迟显示。
- 云端构建会将 14 个生产音频、传输和协议文件与固定 0.1.1 commit 逐字节比对，不一致立即失败。
- 新增 200/500/1000 ms 批量回调拼帧、不足一帧后暂停/恢复、1 秒音频经拼帧→Opus→协议→解码的回归测试。测试不等价于真实 ScreenCaptureKit / UDP / Windows 播放验收。

### 真机验收

先用默认 128 kbps 连续播放至少 10 分钟，再测试切换音源、暂停/恢复、停止/重新开始。确认不再发生“几秒后完全无声”；若复现，记录无声时 iOS 发送统计及 Windows 同时段日志。UI 的 Dropped frames 是本地处理异常计数，不是网络丢包率。

本版首先恢复播放，不宣称解决原先的爆音、2.4 GHz 输出链路干扰或长期时钟漂移。0.1.3 尚需同一台移动设备和现有 Windows 真机验证。已确认可用的 0.1.1 源码和 IPA 继续保留，不覆盖。

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

## 手动连接与二维码（0.1.1）

首页选择“手动 IP / 端口 · 扫码连接”，填入 Windows 的局域网 IP（可在电脑 `ipconfig` 中查看）。默认音频 UDP 端口 **12345**、握手 UDP 端口 **12347**，不要把两个端口混用。点击“连接电脑”后仍需收到原版 Windows 的 HELLO_ACK 才会显示已连接。Windows 无须修改。

本页可以生成、分享并扫描 `modi://lan?host=192.168.1.100&port=12345&handshakePort=12347` 地址码。扫码仅填入表单，用户确认后才连接。扫描要求相机权限和支持 VisionKit 的真机，不上传或保存相机画面。生成的码只用于本 iOS 客户端分享 LAN 地址，不是新音频协议。

**Windows 现有二维码不能直接用于 LAN**：源码 `QrCodeHelper.BuildQrPayload` 生成的是 `MODI://version=1&transport=wifidirect&device=...&token=...`，没有 LAN IP/端口。iOS 扫到它会给出明确提示，不会把 Wi-Fi Direct token 当作 LAN 握手信息。

若完整错误为 `NWError.dns(-65569)`，Apple 将其定义为 `kDNSServiceErr_DefunctConnection`，表示与系统 DNS-SD 服务的连接失效，而非电脑握手失败。客户端会有限重建发现器，提供“重新发现”按钮；发现失败不会覆盖手动连接状态。`-65570` 才是策略拒绝。本地网络权限被拒绝、Wi-Fi 客户端隔离或防火墙拦截仍可能阻止手动连接。

参考：[Apple DNS-SD 错误定义](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/mDNSShared/dns_sd.h)。新功能的真机扫码、实际 LAN 握手仍须用户设备验证。

## 编译步骤

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

在你有写权限的个人研究仓库中提交完整源码后，`iOS build` workflow 会执行协议交叉测试、模拟器测试、真机 arm64 Release 构建，并上传 `MoDiConnect-unsigned-ipa` artifact（保留7天）。其中包含未签名 IPA、SHA-256 和安装说明。该 IPA 需要个人签名后才能安装到 iPhone，不能直接当作已签名应用安装。构建失败不会上传 IPA；测试结果单独保留。

云编译在用户授权的 `Akuair/MoDi-Connect-iOS-Public` 仓库运行，不修改原作者仓库。若需要云端直接输出已签名 IPA，还需通过安全的签名配置提供 Apple 证书与匹配的 provisioning profile；不要将私钥提交到源码仓库。

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

- 当前交付用于用户指定的个人互操作研究；不代表协议所有者授权或认证。源码已按用户授权上传个人公开仓库，未发布 App Store。
- 0.1.1 已获用户真机可用反馈；0.1.2 已因播放回归撤回；0.1.3 恢复基线音频实现，仍须真机验收。
- iOS 系统音频捕获必须经过系统 picker，用户可随时停止；App 无法静默绕过授权。
- 后台、锁屏、通话、音频 route 变化和系统压力均可能终止 capture；实现会退出 streaming 并显示失败/重连状态，但最终行为必须在 iOS 27 真机确认。
- DRM/受保护内容可能被静音或禁止捕获。
- `screen-capture` background mode 及相关 API 的 App Store 审核/发布支持应在提交前用当期 Xcode 和 App Store Connect 验证。
- 当前重连与 Android 一致，固定原 host、2 秒间隔、最多 5 次；IP 变化后需要重新发现并选择。
- UI 显示发送模式、本地提交速率和处理异常；未获得 Windows 回传测量，不显示伪造的端到端延迟或网络丢包率。

## Protocol compatibility checks

兼容 adapter 把下列 semantic packet 映射到 MoDi Protocol 0.1.1（wire version 2）：

- HELLO: type HELLO、link WIFI_LAN、sequence 0、payload `route(0) + UUID(16-byte network order)`
- HELLO_ACK: 校验 type 与相同 session UUID
- AUDIO: type AUDIO、link WIFI_LAN、递增 UInt32 sequence、payload 为纯 Opus packet

在仓库根目录运行 `dotnet run --project ios/Tools/ProtocolProbe`，使用现有 .NET 二进制验证 Swift 测试中的固定样例。macOS/GitHub Actions 还会编译生产 Swift codec，生成224个包交给同一 .NET 二进制验证。具体命令见 WIRE-COMPATIBILITY.md。下一步仍须进行 `iPhone → existing Windows → current default speaker` 真机验收。
