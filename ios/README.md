# MoDi Connect for iOS

原生 SwiftUI LAN 发送端，目标是把 iPhone 系统音频发送到现有 Windows MoDi Connect 的 `SpeakerOnly` 路线。Windows 不需要虚拟声卡、VB-CABLE 或更改默认输出设备。

> 2026-09-11：用户已确认 0.1.1 真机播放可用，该版本保存在 `stable/0.1.1`，commit `19cd9dbf504eaa446e0919074866d8f4a04bb225`。[基线云编译](https://github.com/Akuair/MoDi-Connect-iOS-Public/actions/runs/34560676995)通过 12 项测试、跳过 2 项硬件测试，224 个 Swift packet 与原版 .NET codec 交叉校验通过。本分支是 0.1.2 稳定性候选版，改善效果仍需相同设备 A/B 验证，不替代已确认的基线。安装 IPA 前需要个人签名。

## 0.1.2 音频稳定性候选版

实际路径：ScreenCaptureKit → 复用 AVAudioConverter → PCM16/960 samples → 有界 PCM 队列 → 单调时钟每 20 ms 一帧 → 原参数 libopus → 原 MoDi packet → UDP → 原 Windows SpeakerOnly。

- 设置可选 40 ms（默认）或 80 ms 发送缓冲。从第一个真实 PCM 到达后计时，不能被批量回调绕过。缓冲将增加延迟，不承诺总延迟低于 150 ms。
- 定时器轻微迟到沿用原时间基准，避免不断累积调度漂移；严重迟到重设下一次 deadline，不追赶式连发。
- 捕获短缺时编码淡出/静音、恢复时 5 ms 过渡。不是恢复丢失音频，也不是降噪；源 App 暂停时补静音计数增长属于预期行为。
- PCM 队列最多 7 帧（40 ms 设置）或 9 帧（80 ms 设置）；过载时丢弃旧 PCM 并做短过渡，防止无限积压。丢弃发生在 Opus 编码和 sequence 分配之前，不人为制造 Windows 序号空洞。
- 音频回调与转换/编码使用同一串行队列，去除一次无界 async 转发。输入/输出 AVAudioPCMBuffer 按容量复用，停止时清除重采样器状态。
- UDP 请求 `interactiveVoice` 服务等级；只是向系统提示流量类型，路由器未必尊重。最多允许 4 个尚未完成本地提交的 datagram，阻塞时走原重连/新握手，避免无限堆积。
- UI 显示本地提交速率、积压丢帧、补静音、调度迟到和捕获间隔。没有接收反馈，不能从这些数值声称测出了网络丢包率、实际播放延迟或已经改善的百分比。

### 源码证据与方案边界

旧 iOS `AudioPipeline.consume` 在一个回调内循环 encode/send，多帧可能集中提交，且每回调分配 AVAudioPCMBuffer。它们是可修正的抖动风险，不是已经通过现场日志证实的唯一杂音根因。

Windows `AudioEngine.OnPacketReceived` 先 `TrackSequence` / `DecodeFec` / `Decode`，后 `PlaybackScheduler.Push`，即有状态解码在 PCM jitter buffer 排序之前。因此没有新增重复发包、重传、自定义 FEC 或聚合音频包。它们不能安全地当作零修改兼容方案。Windows 初始化 jitter buffer 为 24 帧容量、5 帧预缓冲；`PlaybackScheduler` 每 20 ms 取帧，短缺时 PLC；`SpeakerRenderer` 原样通过 WaveOutEvent 输出默认设备。

48 kHz / mono / PCM16 / 20 ms / 128 kbps / complexity 10 / CVBR / FEC / loss hint 15% 均保持基线参数。FEC enabled 不保证每包都有冗余，实际模式由 libopus 决定；没有启用需要新版接收解码器的 DRED。单纯提高码率不是对无线干扰的修复。

参考：[Apple AVAudioConverter 连续重采样](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)、[Apple 网络服务等级](https://developer.apple.com/documentation/network/nwparameters/serviceclass-swift.property)、[Opus 编码参数/FEC](https://opus-codec.org/docs/opus_api-1.6/group__opus__encoderctls.html)。

### 真机比较步骤

1. 同一段音乐、同一音量、同一网络，分别用 0.1.1 和 0.1.2 连续播放至少 10 分钟；记录杂音次数与发生时刻。
2. 新版先用 128 kbps + 40 ms；若补静音在源音频持续播放时增加，再断开切换 80 ms。更大缓冲只抵抗有限捕获抖动，不能救回网络中丢掉的包。
3. 若新统计平稳但电脑仍杂音，查看原 Windows 的 `[Diag] decFail / pullNull / jbCount`，区分接收/解码失败与播放端短缺；也检查 Windows 音量缩放是否造成削波。不要把 source 暂停产生的补静音当成 Wi-Fi 丢包。
4. 分别验证正常播放、快速切 App、源暂停/恢复、锁屏、断网/重连和停止后重新开始。暂未实测无线丢包场景与长期设备时钟漂移；新版不宣称可修复 Windows 解码顺序或播放调度的限制。
5. 效果不佳时重签安装已保存的 0.1.1 IPA，或从 `stable/0.1.1` 构建回退。

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

在你有写权限的私有研究仓库中提交完整源码后，`iOS build` workflow 会执行协议交叉测试、模拟器测试、真机 arm64 Release 构建，并上传 `MoDiConnect-unsigned-ipa` artifact（保留7天）。其中包含未签名 IPA、SHA-256 和安装说明。该 IPA 需要个人签名后才能安装到 iPhone，不能直接当作已签名应用安装。构建失败不会上传 IPA；测试结果单独保留。

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
- 0.1.1 已获用户真机可用反馈；0.1.2 的杂音改善尚未真机验收。
- iOS 系统音频捕获必须经过系统 picker，用户可随时停止；App 无法静默绕过授权。
- 后台、锁屏、通话、音频 route 变化和系统压力均可能终止 capture；实现会退出 streaming 并显示失败/重连状态，但最终行为必须在 iOS 27 真机确认。
- DRM/受保护内容可能被静音或禁止捕获。
- `screen-capture` background mode 及相关 API 的 App Store 审核/发布支持应在提交前用当期 Xcode 和 App Store Connect 验证。
- 当前重连与 Android 一致，固定原 host、2 秒间隔、最多 5 次；IP 变化后需要重新发现并选择。
- UI 仅显示发送队列长度；未获得 Windows 回传测量，不显示伪造的端到端延迟或丢包率。

## Protocol compatibility checks

兼容 adapter 把下列 semantic packet 映射到 MoDi Protocol 0.1.1（wire version 2）：

- HELLO: type HELLO、link WIFI_LAN、sequence 0、payload `route(0) + UUID(16-byte network order)`
- HELLO_ACK: 校验 type 与相同 session UUID
- AUDIO: type AUDIO、link WIFI_LAN、递增 UInt32 sequence、payload 为纯 Opus packet

在仓库根目录运行 `dotnet run --project ios/Tools/ProtocolProbe`，使用现有 .NET 二进制验证 Swift 测试中的固定样例。macOS/GitHub Actions 还会编译生产 Swift codec，生成224个包交给同一 .NET 二进制验证。具体命令见 WIRE-COMPATIBILITY.md。下一步仍须进行 `iPhone → existing Windows → current default speaker` 真机验收。

