//
//  SimpleRTCExample.swift
//  SwiftPipesRTC
//
//  Simple example showing SwiftPipes + swift-rtc integration
//

import Foundation
import SwiftPipes
import RTC
@preconcurrency import RTP
@preconcurrency import SDP
import NIOCore

/// Example: Create a simple RTP processing pipeline
public func createSimpleRTPPipeline() async -> SimplePipeline {
    let pipeline = SimplePipeline()
    
    // Create a test video source that generates MediaBuffers
    let videoSource = SimpleVideoSource(id: "videoSource")
    
    // RTP packetizer using swift-rtc
    let rtpPacketizer = RTPPacketizerFilterV2(
        id: "rtpPacketizer",
        ssrc: 0x12345678,
        payloadType: 96, // H.264
        clockRate: 90000
    )
    
    // Debug sink to print packets
    let debugSink = RTPDebugSink(id: "rtpDebugSink")
    
    // Build pipeline
    await pipeline.buildLinear([
        .source(child: videoSource),
        .filter(child: rtpPacketizer),
        .sink(child: debugSink)
    ])
    
    // Start the source
    await videoSource.start()
    
    return pipeline
}

/// Simple video source that generates MediaBuffer
actor SimpleVideoSource: PipelineSourceElement {
    nonisolated let id: String
    private var task: Task<Void, Never>?
    private var (stream, continuation) = AsyncStream.makeStream(of: MediaBuffer.self)
    
    var outputPads: [ElementOutputPad<AsyncStream<MediaBuffer>>] {
        [.init(ref: .outputDefault, stream: stream)]
    }
    
    init(id: String = "SimpleVideoSource") {
        self.id = id
    }
    
    func start() async {
        stop()
        
        task = Task {
            var frameNumber: UInt32 = 0
            var sequenceNumber: UInt16 = 0
            
            while !Task.isCancelled {
                // Generate fake video frame data
                let isKeyframe = frameNumber % 30 == 0
                let frameData = generateFakeFrame(isKeyframe: isKeyframe)
                
                let buffer = MediaBuffer(
                    data: frameData,
                    mediaType: .video,
                    timestamp: frameNumber * 3000, // 30 fps at 90kHz
                    sequenceNumber: sequenceNumber,
                    ssrc: 0, // Will be set by packetizer
                    payloadType: 0, // Will be set by packetizer
                    marker: true // End of frame
                )
                
                continuation.yield(buffer)
                frameNumber += 1
                sequenceNumber += 1
                
                // 30 fps
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }
    
    func stop() {
        task?.cancel()
        task = nil
    }
    
    func finish() {
        stop()
        continuation.finish()
    }
    
    func onCancel(task: PipeTask) {
        stop()
    }
    
    private func generateFakeFrame(isKeyframe: Bool) -> Data {
        // Generate minimal fake H.264 NAL unit
        var frame = Data()
        
        if isKeyframe {
            // IDR frame NAL unit header
            frame.append(0x65)
        } else {
            // P-frame NAL unit header
            frame.append(0x61)
        }
        
        // Add some dummy payload
        frame.append(Data(repeating: 0xFF, count: isKeyframe ? 1000 : 500))
        
        return frame
    }
}

/// Debug sink for RTP packets
actor RTPDebugSink: PipelineSinkElement {
    nonisolated let id: String
    private var packetCount = 0
    
    var inputPads: [ElementInputPad<RTPPacketBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String = "RTPDebugSink") {
        self.id = id
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: RTPPacketBuffer) async {
        packetCount += 1
        print("[\(id)] RTP Packet \(packetCount):")
        print("  Sequence: \(buffer.header.sequenceNumber)")
        print("  Timestamp: \(buffer.header.timestamp)")
        print("  SSRC: 0x\(String(format: "%08X", buffer.header.ssrc))")
        print("  Payload Type: \(buffer.header.payloadType)")
        print("  Marker: \(buffer.header.marker)")
        print("  Payload Size: \(buffer.payload.readableBytes) bytes")
    }
}

/// Example: Create SDP for RTP session
public func createSDPExample() -> String {
    // Simple SDP creation example
    // In a real application, you would use the SDP module's builder methods
    let sdp = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=SwiftPipes RTC Session
    t=0 0
    m=video 5004 RTP/AVP 96
    a=rtpmap:96 H264/90000
    a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
    a=sendrecv
    """
    
    print("Created SDP:")
    print(sdp)
    
    return sdp
}