//
//  CameraToRTPPipeline.swift
//  SwiftPipesRTC
//
//  Complete pipeline: Camera -> H.265 Encoder -> RTP Packetizer -> Network
//

import Foundation
import SwiftPipes
import AVFoundation

/// Complete camera to RTP streaming pipeline
@available(iOS 13.0, macOS 10.15, *)
public func createCameraToRTPPipeline(
    remoteHost: String,
    remotePort: UInt16 = 5004,
    bitRate: Int = 10_000_000, // 10 Mbps
    frameRate: Double = 30.0
) async throws -> SimplePipeline {
    
    let pipeline = SimplePipeline()
    
    // Create pipeline elements
    let cameraSource = CameraCaptureSource(id: "camera")
    let h265Encoder = H265EncoderFilter(
        id: "h265Encoder",
        bitRate: bitRate,
        frameRate: frameRate
    )
    let rtpPacketizer = H265RTPPacketizerFilter(
        id: "h265RTPPacketizer",
        ssrc: UInt32.random(in: 1...UInt32.max)
    )
    let networkSender = RTPNetworkSenderSink(
        id: "rtpSender",
        remoteHost: remoteHost,
        remotePort: remotePort
    )
    
    // Build the pipeline
    await pipeline.buildLinear([
        .source(child: cameraSource),
        .filter(child: h265Encoder),
        .filter(child: rtpPacketizer),
        .sink(child: networkSender)
    ])
    
    // Start network sender
    await networkSender.start()
    
    // Start camera capture
    try await cameraSource.start()
    
    print("""
    Camera to RTP Pipeline Started:
    - Capturing from camera
    - Encoding to H.265 at \(bitRate / 1_000_000) Mbps, \(frameRate) fps
    - Streaming RTP to \(remoteHost):\(remotePort)
    - RTCP on port \(remotePort + 1)
    """)
    
    return pipeline
}

/// Pipeline with additional debug output
@available(iOS 13.0, macOS 10.15, *)
public func createDebugCameraToRTPPipeline(
    remoteHost: String,
    remotePort: UInt16 = 5004,
    bitRate: Int = 10_000_000,
    frameRate: Double = 30.0
) async throws -> SimplePipeline {
    
    let pipeline = SimplePipeline()
    
    // Create pipeline elements
    let cameraSource = CameraCaptureSource(id: "camera")
    let h265Encoder = H265EncoderFilter(
        id: "h265Encoder",
        bitRate: bitRate,
        frameRate: frameRate
    )
    let rtpPacketizer = H265RTPPacketizerFilter(
        id: "h265RTPPacketizer",
        ssrc: 0x12345678
    )
    
    // Debug sinks
    let encoderDebugSink = H265DebugSink(id: "h265Debug")
    let rtpDebugSink = RTPDebugSink(id: "rtpDebug")
    let networkSender = RTPNetworkSenderSink(
        id: "rtpSender",
        remoteHost: remoteHost,
        remotePort: remotePort
    )
    
    // Build the pipeline with debug taps
    await pipeline.buildGroups([
        // Main flow
        (id: "main", children: [
            .source(child: cameraSource),
            .filter(child: h265Encoder),
            .filter(child: rtpPacketizer),
            .sink(child: networkSender)
        ]),
        // Debug tap after encoder
        (id: "encoderDebug", children: [
            .filterRef(id: "h265Encoder", viaOut: .outputDefault),
            .sink(child: encoderDebugSink)
        ]),
        // Debug tap after packetizer
        (id: "rtpDebug", children: [
            .filterRef(id: "h265RTPPacketizer", viaOut: .outputDefault),
            .sink(child: rtpDebugSink)
        ])
    ])
    
    // Start network sender
    await networkSender.start()
    
    // Start camera capture
    try await cameraSource.start()
    
    return pipeline
}

/// Debug sink for H.265 encoded frames
@available(iOS 13.0, macOS 10.15, *)
actor H265DebugSink: PipelineSinkElement {
    nonisolated let id: String
    private var frameCount = 0
    
    var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String = "H265DebugSink") {
        self.id = id
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        frameCount += 1
        let frameType = buffer.isKeyFrame ? "IDR" : "P"
        print("[\(id)] H.265 Frame \(frameCount): \(frameType), \(buffer.data.count) bytes, pts: \(buffer.timestamp.seconds)")
    }
}


/// Example usage
@available(iOS 13.0, macOS 10.15, *)
public func runCameraRTPExample() async throws {
    // Check camera permission
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    if status != .authorized {
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                print("Camera access denied")
                return
            }
        } else {
            print("Camera access denied")
            return
        }
    }
    
    // Create and run pipeline
    let pipeline = try await createCameraToRTPPipeline(
        remoteHost: "192.168.1.100", // Replace with your receiver IP
        remotePort: 5004,
        bitRate: 5_000_000, // 5 Mbps
        frameRate: 30.0
    )
    
    // Run for a duration
    print("Streaming... Press Ctrl+C to stop")
    
    // In a real app, handle this more gracefully
    try await Task.sleep(nanoseconds: 60_000_000_000) // Run for 60 seconds
    
    // Stop the pipeline
    await pipeline.stop()
    print("Pipeline stopped")
}

/// Create SDP for the H.265 RTP stream
public func createH265SDP(
    sessionName: String = "SwiftPipes H.265 Stream",
    remoteIP: String,
    remotePort: UInt16 = 5004
) -> String {
    let sdp = """
    v=0
    o=- \(Date().timeIntervalSince1970.rounded()) \(Date().timeIntervalSince1970.rounded()) IN IP4 0.0.0.0
    s=\(sessionName)
    t=0 0
    m=video \(remotePort) RTP/AVP 98
    c=IN IP4 \(remoteIP)
    a=rtpmap:98 H265/90000
    a=fmtp:98 profile-id=1;sprop-sps=;sprop-pps=;sprop-vps=
    a=sendonly
    """
    
    return sdp
}