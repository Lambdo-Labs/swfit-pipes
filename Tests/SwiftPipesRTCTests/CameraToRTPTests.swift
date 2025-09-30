import Testing
import SwiftPipes
import SwiftPipesRTC
import AVFoundation
import Network

@available(iOS 13.0, macOS 10.15, *)
@Test("Camera to H.265 RTP pipeline test")
func testCameraToH265RTPPipeline() async throws {
    // This test creates the full pipeline:
    // Camera -> H.265 Encoder -> RTP Packetizer -> Network Sender
    
    // Create test receiver to verify packets are sent
    let testReceiver = TestRTPReceiver()
    try await testReceiver.start(port: 5004)
    
    print("Test receiver started on ports 5004 (RTP) and 5005 (RTCP)")
    
    // Create the pipeline
    let pipeline = SimplePipeline()
    
    // Create pipeline elements
    let cameraSource = CameraCaptureSource(id: "camera")
    let h265Encoder = H265EncoderFilter(
        id: "h265Encoder",
        bitRate: 1_000_000, // 1 Mbps for test
        frameRate: 30.0
    )
    let rtpPacketizer = H265RTPPacketizerFilter(
        id: "h265RTPPacketizer",
        ssrc: 0x12345678
    )
    let networkSender = RTPNetworkSenderSink(
        id: "rtpSender",
        remoteHost: "127.0.0.1",
        remotePort: 5004
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
    do {
        try await cameraSource.start()
    } catch {
        // Skip test if no camera available (CI environment)
        print("Camera error: \(error)")
        if error.localizedDescription.contains("No video device") || 
           error.localizedDescription.contains("not authorized") {
            print("Skipping test - no camera or permission")
            return
        }
        throw error
    }
    
    // Start the pipeline
    await pipeline.start()
    
    // Wait for packets to be received
    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
    
    // Stop the pipeline
    await pipeline.stop()
    await cameraSource.finish()
    await testReceiver.stop()
    
    // Verify we received packets
    let stats = await testReceiver.getStats()
    print("Test Results:")
    print("  RTP packets received: \(stats.rtpPackets)")
    print("  RTCP packets received: \(stats.rtcpPackets)")
    print("  Total bytes received: \(stats.totalBytes)")
    
    // Assert we received both RTP and RTCP packets
    #expect(stats.rtpPackets > 0, "Should have received RTP packets")
    #expect(stats.rtcpPackets > 0, "Should have received RTCP packets")
    #expect(stats.totalBytes > 0, "Should have received data")
}

// Test receiver to verify packets are sent
@available(iOS 13.0, macOS 10.15, *)
actor TestRTPReceiver {
    private var rtpConnection: NWListener?
    private var rtcpConnection: NWListener?
    private var rtpPackets = 0
    private var rtcpPackets = 0
    private var totalBytes = 0
    
    struct Stats {
        let rtpPackets: Int
        let rtcpPackets: Int
        let totalBytes: Int
    }
    
    func start(port: UInt16) async throws {
        let rtpPort = NWEndpoint.Port(rawValue: port)!
        let rtcpPort = NWEndpoint.Port(rawValue: port + 1)!
        
        // Start RTP listener
        rtpConnection = try NWListener(using: .udp, on: rtpPort)
        rtpConnection?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection, isRTCP: false)
            }
        }
        rtpConnection?.start(queue: .main)
        
        // Start RTCP listener
        rtcpConnection = try NWListener(using: .udp, on: rtcpPort)
        rtcpConnection?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection, isRTCP: true)
            }
        }
        rtcpConnection?.start(queue: .main)
        
        // Wait for listeners to be ready
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    
    private func handleConnection(_ connection: NWConnection, isRTCP: Bool) {
        connection.start(queue: .main)
        receiveData(on: connection, isRTCP: isRTCP)
    }
    
    private func receiveData(on connection: NWConnection, isRTCP: Bool) {
        Task {
            await receiveDataAsync(on: connection, isRTCP: isRTCP)
        }
    }
    
    private func receiveDataAsync(on connection: NWConnection, isRTCP: Bool) async {
        await withCheckedContinuation { continuation in
            connection.receiveMessage { [weak self] data, context, isComplete, error in
                guard let data = data else {
                    continuation.resume()
                    return
                }
                
                Task {
                    await self?.recordPacket(data: data, isRTCP: isRTCP)
                    await self?.receiveDataAsync(on: connection, isRTCP: isRTCP)
                }
                
                continuation.resume()
            }
        }
    }
    
    private func recordPacket(data: Data, isRTCP: Bool) {
        if isRTCP {
            rtcpPackets += 1
        } else {
            rtpPackets += 1
        }
        totalBytes += data.count
        
        // Debug output
        let packetType = isRTCP ? "RTCP" : "RTP"
        print("[\(packetType)] Received \(data.count) bytes")
    }
    
    func getStats() -> Stats {
        Stats(rtpPackets: rtpPackets, rtcpPackets: rtcpPackets, totalBytes: totalBytes)
    }
    
    func stop() {
        rtpConnection?.cancel()
        rtcpConnection?.cancel()
    }
}

@available(iOS 13.0, macOS 10.15, *)
@Test("H.265 encoder produces valid output")
func testH265EncoderOutput() async throws {
    // Create a simple test pipeline to verify H.265 encoding works
    let pipeline = SimplePipeline()
    
    // Create test source with synthetic video frames
    let testSource = TestVideoSource(id: "testVideoSource")
    let h265Encoder = H265EncoderFilter(
        id: "h265Encoder",
        bitRate: 1_000_000,
        frameRate: 30.0
    )
    let collector = H265CollectorSink(id: "collector")
    
    // Build pipeline
    await pipeline.buildLinear([
        .source(child: testSource),
        .filter(child: h265Encoder),
        .sink(child: collector)
    ])
    
    // Start the source
    await testSource.start()
    
    // Start pipeline
    await pipeline.start()
    
    // Generate a few frames
    await testSource.generateFrames(count: 10)
    
    // Wait for encoding
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // Stop
    await pipeline.stop()
    await testSource.finish()
    
    // Check results
    let frames = await collector.getFrames()
    print("Encoded \(frames.count) H.265 frames")
    
    #expect(frames.count > 0, "Should have encoded frames")
    #expect(frames.contains { $0.isKeyFrame }, "Should have at least one key frame")
    #expect(frames.allSatisfy { $0.data.count > 0 }, "All frames should have data")
}

// Test video source that generates synthetic frames
@available(iOS 13.0, macOS 10.15, *)
actor TestVideoSource: PipelineSourceElement {
    nonisolated let id: String
    private var (stream, continuation) = AsyncStream.makeStream(of: VideoFrameBuffer.self)
    
    var outputPads: [ElementOutputPad<AsyncStream<VideoFrameBuffer>>] {
        [.init(ref: .outputDefault, stream: stream)]
    }
    
    init(id: String) {
        self.id = id
    }
    
    func start() async {
        // Ready to generate frames
    }
    
    func generateFrames(count: Int) async {
        for i in 0..<count {
            if let pixelBuffer = createTestPixelBuffer() {
                let sampleBuffer = createSampleBuffer(from: pixelBuffer, frameNumber: i)
                if let sampleBuffer = sampleBuffer {
                    let buffer = VideoFrameBuffer(sampleBuffer: sampleBuffer)
                    continuation.yield(buffer)
                }
            }
            
            // 30 fps timing
            try? await Task.sleep(nanoseconds: 33_333_333)
        }
    }
    
    private func createTestPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1280, 720,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        // Fill with test pattern
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        // Y plane - gradient
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            
            for y in 0..<yHeight {
                for x in 0..<yStride {
                    yPtr[y * yStride + x] = UInt8((y * 255) / yHeight)
                }
            }
        }
        
        return buffer
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, frameNumber: Int) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameNumber), timescale: 30),
            decodeTimeStamp: .invalid
        )
        
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let formatDesc = formatDescription else { return nil }
        
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer
    }
    
    func finish() {
        continuation.finish()
    }
    
    func onCancel(task: PipeTask) {
        continuation.finish()
    }
}

// Collector for H.265 frames
@available(iOS 13.0, macOS 10.15, *)
actor H265CollectorSink: PipelineSinkElement {
    nonisolated let id: String
    private var frames: [EncodedH265Buffer] = []
    
    var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String) {
        self.id = id
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        frames.append(buffer)
    }
    
    func getFrames() -> [EncodedH265Buffer] {
        frames
    }
}