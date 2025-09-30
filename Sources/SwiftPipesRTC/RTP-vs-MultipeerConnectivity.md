# RTP/RTCP vs MultipeerConnectivity

This document compares the two main approaches for streaming H.265 video demonstrated in SwiftPipesRTC.

## Two Example Implementations

### 1. **RTPRTCPSimpleExample** - Professional RTP/RTCP Streaming

Demonstrates:
- **Proper RTP/RTCP separation** (different ports: 5004 for RTP, 5005 for RTCP)
- How RTP carries the actual H.265 video data
- How RTCP provides control/feedback on a separate channel
- Professional streaming concepts:
  - Sender Reports (statistics)
  - Picture Loss Indication (keyframe requests)
  - REMB (bitrate estimation)

### 2. **MultipeerSimpleExample** - Apple Framework (MultipeerConnectivity)

Demonstrates:
- **Codable H.265 frames** for MultipeerConnectivity
- **RTCP-like feedback** adapted for peer-to-peer
- All messages as a single `MultipeerVideoMessage` enum
- How to send/receive via JSONEncoder/Decoder
- Sequence numbers for loss detection
- Same feedback concepts (SR, PLI, REMB) but Codable

## Key Differences

These two examples show the contrast between:
- **Professional streaming** (RTP/RTCP with binary protocols, separate channels)
- **Apple peer-to-peer** (MultipeerConnectivity with JSON/Codable, single channel)

Both achieve the same goal (H.265 video with quality feedback) but adapted to their respective transport mechanisms.

## When to Use Which

### Use RTP/RTCP when:
- Building professional streaming applications
- Interoperating with standard video equipment
- Need lowest possible latency and overhead
- Working with existing RTP infrastructure

### Use MultipeerConnectivity approach when:
- Building iOS/macOS peer-to-peer apps
- Want type-safe Swift code with Codable
- Need reliable transport (TCP-based)
- Prefer simplicity over efficiency

## Running the Examples

```bash
# Professional RTP/RTCP
swift run RTPRTCPSimpleExample

# Apple MultipeerConnectivity
swift run MultipeerSimpleExample
```