# Personal interoperability research — MoDi 0.1.1

## Observed wire format

Confirmed by calling the public `PacketHeader.EncodeHeader`, `PacketHeaderCodec.Encode` and `Decode` APIs of the bundled .NET binary. No original implementation was decompiled or translated.

| Offset | Size | Meaning |
|---|---|---|
| 0 | 4 | Magic `4C 41 42 42` |
| 4 | 1 | Wire version `02` (package version is 0.1.1) |
| 5 | 1 | Type: HELLO=1, ACK=2, NACK=3, ROUTE=4, ROUTE_ACK=5, AUDIO=6, DATA=7 |
| 6 | 1 | Link ID; LAN=1 |
| 7 | 4 | UInt32 sequence, big-endian |
| 11 | 4 | Payload byte count, big-endian, nonnegative Int32 |
| 15 | length | Raw payload, no extra checksum/trailer |

The original decoder rejects wrong magic/version/type, truncated payloads and trailing bytes. It accepts arbitrary link bytes. The Swift decoder follows these observed behaviors and rejects lengths above Int32.max before copying data. AUDIO has no timestamp or session field. LAN HELLO is route 0 + 16 network-order UUID bytes; ACK carries the same identity.

## Verification

From the repository root, with .NET 10:

```sh
dotnet run --project ios/Tools/ProtocolProbe
```

The probe extracts the existing NuGet DLL into ignored `obj/`, calls its public APIs, and verifies the exact four wire fixtures committed in the Swift unit tests. Result on Windows: PASS. These are research fixtures, not owner-issued golden vectors.

On macOS with Swift and .NET 10:

```sh
swiftc ios/MoDiConnect/MoDiProtocolAdapter.swift ios/Tools/CodecCheck.swift -o /tmp/modi-codec-check
/tmp/modi-codec-check > /tmp/modi-swift-packets.txt
dotnet run --project ios/Tools/ProtocolProbe -- /tmp/modi-swift-packets.txt
```

This executes the production Swift encoder/decoder across 7 message types, 8 payload sizes and 4 sequence values (224 packets). The original .NET decoder must accept every Swift packet, and the original encoder must reproduce it byte-for-byte. The Swift executable also rejects invalid framing. This cross-language execution PASSED in GitHub Actions on 2026-09-11; the local Windows environment still lacks Swift/Xcode.

## Status and boundaries

- Compatible Swift implementation: integrated, no official iOS SDK required.
- Four fixed fixtures against actual .NET binary: PASS.
- Production Swift execution and iOS build: PASS in [cloud run 34558863019](https://github.com/Akuair/MoDi-Connect-iOS-Public/actions/runs/34558863019), commit 48e5130bb337ab17d208f06333a0339714e861ab. Xcode 27 beta 6; iOS 27 arm64 Release IPA unsigned. Simulator: 5 unit tests passed, 2 hardware tests skipped. Swift 6 concurrency migration warnings remain under Swift 5 language mode.
- Real iPhone to Windows default speaker: NOT TESTED.
- Android/Windows and the bundled proprietary package: unchanged.
- Scope: personal interoperability research, published at the user's request on 2026-09-11. This is an independent implementation, not an official iOS SDK or a claim of owner approval. Proprietary protocol binaries are not republished in the iOS-only cloud-build repository.

