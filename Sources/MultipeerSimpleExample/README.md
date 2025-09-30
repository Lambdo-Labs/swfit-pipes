# MultipeerSimpleExample - Apple Framework (MultipeerConnectivity)

This example demonstrates H.265 video streaming adapted for Apple's MultipeerConnectivity framework.

## Key Concepts

- **Codable H.265 frames** for MultipeerConnectivity
- **RTCP-like feedback** adapted for peer-to-peer
- All messages as a single `MultipeerVideoMessage` enum
- How to send/receive via JSONEncoder/Decoder
- Sequence numbers for loss detection
- Same feedback concepts (SR, PLI, REMB) but Codable

## Architecture

```
Video → H.265 Encoder → MultipeerVideoFilter → MultipeerConnectivity
                              ↓
                        RTCP Session → Codable Feedback Messages
```

## Usage

```bash
swift run MultipeerSimpleExample
```

This example shows how to adapt professional streaming concepts (RTP/RTCP) to work with Apple's peer-to-peer framework using JSON/Codable messages on a single channel.