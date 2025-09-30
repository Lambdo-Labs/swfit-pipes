# RTPRTCPSimpleExample - Professional RTP/RTCP Streaming

This example demonstrates professional video streaming using RTP/RTCP protocols.

## Key Concepts

- **Proper RTP/RTCP separation** (different ports: 5004 for RTP, 5005 for RTCP)
- How RTP carries the actual H.265 video data
- How RTCP provides control/feedback on a separate channel
- Professional streaming concepts:
  - Sender Reports (statistics)
  - Picture Loss Indication (keyframe requests)
  - REMB (bitrate estimation)

## Architecture

```
Video → H.265 Encoder → RTP Packetizer → Port 5004 (RTP)
                              ↓
                        RTCP Manager → Port 5005 (RTCP)
```

## Usage

```bash
swift run RTPRTCPSimpleExample
```

This example shows how RTP and RTCP work as separate channels in professional video streaming, with RTP carrying media and RTCP providing quality feedback.