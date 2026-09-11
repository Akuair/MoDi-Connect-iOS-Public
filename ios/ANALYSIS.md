# Android → Windows LAN / SpeakerOnly 源码分析

本文记录 iOS 开发前对仓库现有实现的源码追踪结果。结论来自 `android/`、`windows/` 和 `third_party/modi-protocol/`，不是新协议设计。

更新：以下是初始分析记录。2026-09-11 根据用户个人研究请求，已通过原 .NET 库的公开接口确认 wire 格式，并实现独立 Swift codec；下文“缺少 SDK”描述的是初始阶段，不再是当前技术阻塞。最新验证结果见 [WIRE-COMPATIBILITY.md](WIRE-COMPATIBILITY.md)。

## 真实调用链

```text
Android MediaProjectionService
  → MediaProjectionOwner / SystemAudioCapturer
  → CaptureLoop / AudioPipeline
  → PcmFrameAssembler（每帧 960 samples / 1920 bytes）
  → AudioEncoder（Concentus Opus）
  → EncodeSender
  → MoDi Protocol Packet(AUDIO, WIFI_LAN, sequence, opus)
  → UdpTransport :12345

Windows UdpTransport :12345
  → AudioEngine.OnPacketReceived
  → MoDi Protocol decode
  → OpusDecodePipeline（含单包 FEC / PLC）
  → JitterBuffer（24 帧容量，5 帧预填充）
  → PlaybackScheduler（20 ms）
  → AudioRouter(RouteMode.SpeakerOnly)
  → SpeakerRenderer
  → WaveOutEvent + BufferedWaveProvider
  → Windows 当前默认播放设备
```

握手链为：Android `WifiLanLink` 创建 UUID → `HandshakeManager` 向 UDP 12347 发送 HELLO → Windows `HandshakeEndpoint` 解码并切换 route、重置 `AudioEngine` 会话 → 返回 HELLO_ACK → Android 校验 ACK 中的 session UUID → 启动音频管线。

## 兼容参数清单

1. **端口**：音频 UDP `12345`；握手/路线控制 UDP `12347`。LAN 链路没有 TCP 端口。
2. **Bonjour 类型**：`_modi._udp`。Windows 发布的服务端口为音频端口 `12345`。
3. **TXT record**：Windows `MdnsPublisher` 只构造名称、类型和端口，没有添加应用自定义 TXT record。
4. **HELLO / HELLO_ACK 语义格式**：协议包分别为 `PacketType.HELLO(1)` / `HELLO_ACK(2)`，`LinkType.WIFI_LAN(1)`，sequence `0`。LAN payload 固定 17 bytes：`route: UInt8` + `session UUID: 16-byte network order`。ACK payload 回显 route/session；Android验证 payload 合法且 session 相同。没有设备名、版本、capability 字段。协议包外层 wire header 由私有 MoDi Protocol 0.1.1 codec 产生，仓库没有其可重实现规范。
5. **route/mode**：HELLO payload 第 0 byte；运行中 ROUTE 包 payload 也是单字节 route。route `0` 是 Android SYSTEM capture / Windows `SpeakerOnly`；route `1` 的混音也在 Android 完成，Windows仍走 `SpeakerOnly`；route `2/3` 走 cable。iOS MVP 固定 `0`。
6. **session ID**：每次连接/重连由发送端 `UUID.randomUUID()` 生成。它只出现在 HELLO/ACK payload，不在每个音频包中。Windows 收到新 HELLO 后重置 jitter buffer 和 sequence 追踪。
7. **sequence**：音频会话从 `UInt32(0)` 开始，每个 Opus frame 加一，使用无符号回绕语义。HELLO 和 ROUTE 使用 `0`。
8. **timestamp**：现有应用层 `Packet` 构造、Windows接收和 jitter buffer 路径没有传递音频 timestamp。排序依据 sequence；iOS 不应添加自定义 timestamp。
9. **音频 packet header**：应用可确认的语义字段只有 packet type（AUDIO=`6`）、link type（WIFI_LAN=`1`）、UInt32 sequence 和 payload；协议公共常量可确认 magic=`1279345218`、current version=`2`、header size=`15` bytes，但字段排列、字节序、长度/校验规则属于未随仓库提供的协议实现，不能据此猜测。
10. **payload**：AUDIO payload 是 `AudioEncoder.encodeFrame` 返回的纯 Opus packet；没有每帧 JSON、时间戳、session 或其他 metadata。
11. **FEC**：Android 设置 Opus in-band FEC=true、expected packet loss=15%。Windows检测到恰好缺一帧时，用下一包的 FEC 解码上一帧；更大缺口计丢包并由播放调度器 PLC。
12. **丢包/保活/重连**：发送队列容量 64，满时丢最旧包。UDP没有独立 keepalive。Windows音频看门狗为 3000 ms；jitter buffer无帧时最多连续 25 帧 PLC。Android LAN 网络丢失后停止管线，固定原 host，每 2 秒重试，最多 5 次；成功后新 session、新 sequence。HELLO 首两次等待 800 ms，LAN 最后一次等待 500 ms。
13. **Opus frame**：20 ms。
14. **sample rate**：48,000 Hz。
15. **channel count**：1（mono）。
16. **PCM 输入**：signed 16-bit little-endian、mono、每帧 960 samples / 1920 bytes。
17. **Opus 设置**：`OPUS_APPLICATION_AUDIO`，128,000 bps，complexity 10，VBR（库默认并在 iOS 明确开启），constrained VBR，in-band FEC，15% loss，signal MUSIC；Android预热并丢弃一帧静音输出。
18. **Windows最终 PCM**：Opus 解码为 PCM16 mono 48 kHz，随后转为 IEEE float32 mono 48 kHz；`SpeakerRenderer` 的 `BufferedWaveProvider` 使用该 float 格式，`WaveOutEvent` 输出至当前默认设备，buffer/desired latency 均为 100 ms。
19. **私有协议依赖**：是。Android 依赖 JVM 17 的 `modi-protocol-jvm:0.1.1`；Windows 依赖 .NET 10 的 `MoDi.Protocol 0.1.1`。应用源码没有实现外层 wire codec。
20. **iOS binary / C ABI**：没有。artifact manifest 只列 JAR、Maven metadata 和 NuGet；不存在 Swift package、XCFramework、静态库或 C ABI。仓库也没有协议规范或 golden vector，只有 vector-set hash。

## 协议法律与工程边界

`LICENSE-PROTOCOL-BINARY.txt` 没有授予 Protocol Source（其中明确定义包含 specification、tests、golden vectors）的复制、修改、披露或衍生权；`BINARY-REDISTRIBUTION-GRANT.txt` 只授权清单内未修改的 JAR/.NET 二进制作为本应用组件分发。其 mandatory-rights 条款保留适用法律强制赋予的互操作权利，但它本身并未提供 iOS 实现许可或规范。

初始提交因缺少规范而使用失败占位 adapter。后续研究通过公开 Encode/Decode 接口进行输入输出测试，替换为独立兼容实现；没有复制、反编译原库代码，也不把研究测试向量标为官方 golden vectors。若采用官方 SDK 路径，则需要协议所有者提供以下之一：

- 清单覆盖的 arm64 iOS XCFramework / C ABI；或
- 可供本项目实现与分发的书面授权、完整 wire specification 和 golden vectors。

## iOS 对应路径

```text
SCContentSharingPicker / SCStream (.audio)
  → CMSampleBuffer
  → PCMConverter（长期复用 AVAudioConverter）
  → PCMFrameAssembler（精确 960 samples）
  → libopus C bridge（Android 同参数）
  → MoDiProtocolAdapter
  → NWConnection UDP :12345
```

Bonjour、握手、重连与状态机已经接入兼容 codec。真实 iOS 捕获和 Windows 播放尚未验收。
