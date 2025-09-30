# SwiftPipesRTC

SwiftPipesRTC extends SwiftPipes with RTC (Real-Time Communication) capabilities using the [swift-rtc](https://github.com/ngr-tc/swift-rtc) library.

## Overview

This module provides pipeline elements for:
- RTP packet handling (packetization/depacketization)
- Media buffer management
- Video codec support (H.264)
- Network transport elements
- SDP parsing integration

## Key Components

### Buffers

- `MediaBuffer`: Contains raw media data with RTP metadata
- `RTPPacketBuffer`: Contains RTP packets with headers and payloads
- `EncodedVideoBuffer`: Contains encoded video frames with codec information
- `EncodedAudioBuffer`: Contains encoded audio frames with codec information

### Pipeline Elements

#### Sources
- `SimpleVideoSource`: Generates test video frames
- `RTPNetworkSource`: Receives RTP packets from network

#### Filters
- `RTPPacketizerFilterV2`: Converts media data to RTP packets
- `RTPDepacketizerFilterV2`: Extracts media data from RTP packets
- `H264PacketizerFilter`: Packetizes H.264 video frames
- `H264DepacketizerFilter`: Depacketizes H.264 from RTP

#### Sinks
- `RTPNetworkSink`: Sends RTP packets over network
- `RTPDebugSink`: Prints RTP packet information

## Usage Example

```swift
import SwiftPipes
import SwiftPipesRTC

// Create a simple RTP processing pipeline
let pipeline = await createSimpleRTPPipeline()

// Run for a while
try await Task.sleep(nanoseconds: 5_000_000_000)

// Clean up
await pipeline.stop()
```

## Integration with swift-rtc

SwiftPipesRTC uses swift-rtc for:
- RTP packet structure and serialization
- SDP session description parsing
- Protocol implementations

Note: swift-rtc is a low-level protocol library. SwiftPipesRTC provides the pipeline abstraction on top of it for easier media processing workflows.

## Current Limitations

- swift-rtc is still in development and doesn't include full WebRTC implementation
- ICE/TURN support is not yet available
- Only basic RTP functionality is exposed

## Future Enhancements

- SRTP support for encrypted media
- RTCP feedback mechanisms
- Full WebRTC peer connection support
- More codec support (VP8, VP9, Opus)