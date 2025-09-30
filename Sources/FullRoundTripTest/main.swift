import Foundation
import SwiftPipesRTC
import SwiftPipes
import AVFoundation
import VideoToolbox
import CoreMedia
import RTC
@preconcurrency import RTP
import NIOCore

@main
struct FullRoundTripTest {
    static func main() async {
        print("Full Round-Trip Test: Camera → H.265 → RTP → Decode")
        print("===================================================")
        
        do {
            print("Checking camera permission...")
            // Check camera permission
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            print("Camera permission status: \(status.rawValue)")
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted {
                    print("ERROR: Camera permission denied")
                    return
                }
            } else if status != .authorized {
                print("ERROR: Camera permission not authorized")
                return
            }
            
            // Create test components
            let test = RoundTripTest()
            try await test.run()
            
        } catch {
            print("ERROR: \(error)")
        }
    }
}

actor RoundTripTest {
    // Collectors for each stage
    var capturedFrames: [VideoFrameBuffer] = []
    var encodedFrames: [EncodedH265Buffer] = []
    var depacketizedFrames: [EncodedH265Buffer] = []
    var decodedFrames: [DecodedVideoBuffer] = []
    var rtcpPackets: [Data] = []
    
    func addCapturedFrame(_ frame: VideoFrameBuffer) {
        capturedFrames.append(frame)
    }
    
    func addEncodedFrame(_ frame: EncodedH265Buffer) {
        encodedFrames.append(frame)
    }
    
    func addDepacketizedFrame(_ frame: EncodedH265Buffer) {
        depacketizedFrames.append(frame)
    }
    
    func addDecodedFrame(_ frame: DecodedVideoBuffer) {
        decodedFrames.append(frame)
    }
    
    func run() async throws {
        print("\n1. Setting up pipeline...")
        
        let pipeline = SimplePipeline()
        
        // Create pipeline elements
        let cameraSource = CameraCaptureSource(id: "camera")
        let frameCollector = VideoFrameCollector(id: "frameCollector", test: self)
        
        let h265Encoder = H265EncoderFilter(
            id: "h265Encoder",
            bitRate: 5_000_000,
            frameRate: 30.0
        )
        let encodedCollector = EncodedFrameCollector(id: "encodedCollector", test: self)
        
        let rtpPacketizer = H265RTPPacketizerFilter(
            id: "h265RTPPacketizer",
            ssrc: 0x12345678
        )
        
        let rtpDepacketizer = H265RTPDepacketizerFilter(id: "h265RTPDepacketizer")
        let depacketizedCollector = DepacketizedFrameCollector(id: "depacketizedCollector", test: self)
        
        let h265Decoder = H265DecoderFilter(id: "h265Decoder")
        let decodedCollector = DecodedFrameCollector(id: "decodedCollector", test: self)
        
        // Build pipeline with collectors at each stage
        await pipeline.buildGroups([
            (id: "capture", children: [
                .source(child: cameraSource),
                .sink(child: frameCollector)
            ]),
            (id: "encode", children: [
                .sourceRef(id: "camera", viaOut: .outputDefault),
                .filter(child: h265Encoder),
                .sink(child: encodedCollector)
            ]),
            (id: "packetize", children: [
                .filterRef(id: "h265Encoder", viaOut: .outputDefault),
                .filter(child: rtpPacketizer),
                .filter(child: rtpDepacketizer),
                .sink(child: depacketizedCollector)
            ]),
            (id: "decode", children: [
                .filterRef(id: "h265RTPDepacketizer", viaOut: .outputDefault),
                .filter(child: h265Decoder),
                .sink(child: decodedCollector)
            ])
        ])
        
        // Start camera
        print("2. Starting camera capture...")
        try await cameraSource.start()
        await pipeline.start()
        
        // Capture for 3 seconds
        print("3. Capturing video for 3 seconds...")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        // Stop pipeline
        print("4. Stopping capture...")
        await cameraSource.finish()
        await h265Encoder.finish()
        await rtpPacketizer.finish()
        await rtpDepacketizer.finish()
        await h265Decoder.finish()
        
        // Give pipeline time to process remaining frames
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        await pipeline.stop()
        
        // Analyze results
        print("\n=== RESULTS ===")
        print("Captured frames: \(capturedFrames.count)")
        print("Encoded H.265 frames: \(encodedFrames.count)")
        print("Depacketized frames: \(depacketizedFrames.count)")
        print("Decoded frames: \(decodedFrames.count)")
        
        // Verify H.265 encoding
        if !encodedFrames.isEmpty {
            print("\n5. Verifying H.265 encoding...")
            let keyFrames = encodedFrames.filter { $0.isKeyFrame }.count
            let totalSize = encodedFrames.reduce(0) { $0 + $1.data.count }
            print("  - Key frames: \(keyFrames)")
            print("  - Average frame size: \(totalSize / encodedFrames.count) bytes")
            
            // Try to decode first key frame
            if let firstKeyFrame = encodedFrames.first(where: { $0.isKeyFrame }) {
                print("  - First key frame size: \(firstKeyFrame.data.count) bytes")
                await verifyH265Frame(firstKeyFrame)
            } else if let firstFrame = encodedFrames.first {
                print("  - No key frames found, checking first frame (size: \(firstFrame.data.count) bytes)")
                await verifyH265Frame(firstFrame)
            }
        }
        
        // We're now testing direct pipeline connection
        
        // Generate and verify RTCP
        print("\n7. Generating RTCP packets...")
        generateRTCPPackets()
        print("  - Generated \(rtcpPackets.count) RTCP packets")
        
        // Verify depacketization
        if !depacketizedFrames.isEmpty {
            print("\n8. Verifying RTP depacketization...")
            print("  - Successfully depacketized \(depacketizedFrames.count) frames")
            let totalSize = depacketizedFrames.reduce(0) { $0 + $1.data.count }
            print("  - Average frame size: \(totalSize / depacketizedFrames.count) bytes")
            
            // Compare with original encoded frames
            if depacketizedFrames.count == encodedFrames.count {
                print("  ✓ Frame count matches original")
            } else {
                print("  ✗ Frame count mismatch: expected \(encodedFrames.count), got \(depacketizedFrames.count)")
            }
        }
        
        // Verify decoding
        if !decodedFrames.isEmpty {
            print("\n9. Verifying H.265 decoding...")
            print("  - Successfully decoded \(decodedFrames.count) frames")
            
            if let firstDecoded = decodedFrames.first {
                let width = CVPixelBufferGetWidth(firstDecoded.imageBuffer)
                let height = CVPixelBufferGetHeight(firstDecoded.imageBuffer)
                print("  - Resolution: \(width)x\(height)")
            }
            
            // Compare frame counts
            if decodedFrames.count == capturedFrames.count {
                print("  ✓ Decoded frame count matches captured")
            } else {
                print("  ✗ Frame count mismatch: captured \(capturedFrames.count), decoded \(decodedFrames.count)")
            }
        }
        
        print("\n=== TEST COMPLETE ===")
        
        // Final summary
        let success = capturedFrames.count > 0 && 
                     encodedFrames.count > 0 && 
                     depacketizedFrames.count > 0 && 
                     decodedFrames.count > 0
        
        if success {
            print("✅ FULL ROUND-TRIP TEST PASSED")
            print("   Camera → H.265 → RTP → Depacketize → Decode")
        } else {
            print("❌ TEST INCOMPLETE")
            if capturedFrames.isEmpty { print("   - No frames captured") }
            if encodedFrames.isEmpty { print("   - No frames encoded") }
            if depacketizedFrames.isEmpty { print("   - No frames depacketized") }
            if decodedFrames.isEmpty { print("   - No frames decoded") }
        }
    }
    
    func verifyH265Frame(_ frame: EncodedH265Buffer) async {
        // Verify we have valid H.265 data by checking NAL unit headers
        print("  - Frame data first 16 bytes: \(frame.data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
        let nalUnits = extractNALUnits(from: frame.data)
        print("  - Found \(nalUnits.count) NAL units using start codes")
        
        // Check if it might be AVCC format instead
        if nalUnits.isEmpty && frame.data.count >= 4 {
            let lengthSize = 4 // Typical for AVCC
            var offset = 0
            var avccUnits = 0
            while offset + lengthSize < frame.data.count {
                let length = frame.data.withUnsafeBytes { bytes in
                    bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
                }
                if offset + lengthSize + Int(length) <= frame.data.count {
                    avccUnits += 1
                    offset += lengthSize + Int(length)
                } else {
                    break
                }
            }
            if avccUnits > 0 {
                print("  - Looks like AVCC format with \(avccUnits) NAL units")
            }
        }
        
        var hasValidNALUs = false
        
        for nalu in nalUnits {
            if nalu.count >= 2 {
                let nalType = (nalu[0] >> 1) & 0x3F
                // Check for valid H.265 NAL unit types
                if nalType <= 40 { // Valid range for H.265 NAL units
                    hasValidNALUs = true
                    print("  - Found NAL unit type: \(nalType), size: \(nalu.count)")
                }
            }
        }
        
        if hasValidNALUs {
            print("  ✓ Valid H.265 NAL units found")
        } else {
            print("  ✗ No valid H.265 NAL units found")
        }
    }
    
    func extractNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0
        
        while currentIndex < data.count - 4 {
            // Look for start code
            if data[currentIndex] == 0x00 && data[currentIndex + 1] == 0x00 {
                let startCodeLength: Int
                if currentIndex + 3 < data.count && 
                   data[currentIndex + 2] == 0x00 && 
                   data[currentIndex + 3] == 0x01 {
                    startCodeLength = 4
                } else if data[currentIndex + 2] == 0x01 {
                    startCodeLength = 3
                } else {
                    currentIndex += 1
                    continue
                }
                
                // Find next start code
                var nextStartIndex = currentIndex + startCodeLength
                while nextStartIndex < data.count - 2 {
                    if data[nextStartIndex] == 0x00 && 
                       data[nextStartIndex + 1] == 0x00 &&
                       (data[nextStartIndex + 2] == 0x01 || 
                        (nextStartIndex + 3 < data.count && 
                         data[nextStartIndex + 2] == 0x00 && 
                         data[nextStartIndex + 3] == 0x01)) {
                        break
                    }
                    nextStartIndex += 1
                }
                
                let naluStart = currentIndex + startCodeLength
                let naluEnd = nextStartIndex
                
                if naluStart < naluEnd {
                    nalUnits.append(data[naluStart..<naluEnd])
                }
                
                currentIndex = nextStartIndex
            } else {
                currentIndex += 1
            }
        }
        
        return nalUnits
    }
    
    
    func generateRTCPPackets() {
        // Generate Sender Report
        var srData = Data()
        
        // RTCP header
        srData.append(0x80) // Version=2, P=0, RC=0
        srData.append(200)  // PT=200 (Sender Report)
        
        // Length (in 32-bit words - 1)
        let lengthInWords: UInt16 = 6
        srData.append(UInt8((lengthInWords >> 8) & 0xFF))
        srData.append(UInt8(lengthInWords & 0xFF))
        
        // SSRC
        let ssrc: UInt32 = 0x12345678
        srData.append(UInt8((ssrc >> 24) & 0xFF))
        srData.append(UInt8((ssrc >> 16) & 0xFF))
        srData.append(UInt8((ssrc >> 8) & 0xFF))
        srData.append(UInt8(ssrc & 0xFF))
        
        // NTP timestamp
        let now = Date().timeIntervalSince1970
        let ntpSeconds = UInt32(now + 2208988800)
        srData.append(UInt8((ntpSeconds >> 24) & 0xFF))
        srData.append(UInt8((ntpSeconds >> 16) & 0xFF))
        srData.append(UInt8((ntpSeconds >> 8) & 0xFF))
        srData.append(UInt8(ntpSeconds & 0xFF))
        srData.append(contentsOf: [0, 0, 0, 0]) // NTP fraction
        
        // RTP timestamp
        let rtpTimestamp = UInt32(UInt64(now * 90000) % UInt64(UInt32.max))
        srData.append(UInt8((rtpTimestamp >> 24) & 0xFF))
        srData.append(UInt8((rtpTimestamp >> 16) & 0xFF))
        srData.append(UInt8((rtpTimestamp >> 8) & 0xFF))
        srData.append(UInt8(rtpTimestamp & 0xFF))
        
        // Packet count (estimate)
        let packetCount = UInt32(encodedFrames.count * 20) // Estimate ~20 packets per frame
        srData.append(UInt8((packetCount >> 24) & 0xFF))
        srData.append(UInt8((packetCount >> 16) & 0xFF))
        srData.append(UInt8((packetCount >> 8) & 0xFF))
        srData.append(UInt8(packetCount & 0xFF))
        
        // Octet count (estimate)
        let octetCount = UInt32(encodedFrames.reduce(0) { $0 + $1.data.count })
        srData.append(UInt8((octetCount >> 24) & 0xFF))
        srData.append(UInt8((octetCount >> 16) & 0xFF))
        srData.append(UInt8((octetCount >> 8) & 0xFF))
        srData.append(UInt8(octetCount & 0xFF))
        
        rtcpPackets.append(srData)
        
        // Verify RTCP packet
        if srData.count >= 8 {
            let version = (srData[0] >> 6) & 0x03
            let pt = srData[1]
            let length = (UInt16(srData[2]) << 8) | UInt16(srData[3])
            print("  - RTCP SR: version=\(version), PT=\(pt), length=\(length+1) words")
            print("  - Reported packets: \(packetCount), bytes: \(octetCount)")
        }
    }
}

// Collector elements
actor VideoFrameCollector: PipelineSinkElement {
    nonisolated let id: String
    let test: RoundTripTest
    
    var inputPads: [ElementInputPad<VideoFrameBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, test: RoundTripTest) {
        self.id = id
        self.test = test
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: VideoFrameBuffer) async {
        await test.addCapturedFrame(buffer)
    }
}

actor EncodedFrameCollector: PipelineSinkElement {
    nonisolated let id: String
    let test: RoundTripTest
    
    var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, test: RoundTripTest) {
        self.id = id
        self.test = test
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        await test.addEncodedFrame(buffer)
    }
}

actor DepacketizedFrameCollector: PipelineSinkElement {
    nonisolated let id: String
    let test: RoundTripTest
    
    var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, test: RoundTripTest) {
        self.id = id
        self.test = test
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        await test.addDepacketizedFrame(buffer)
    }
}

actor DecodedFrameCollector: PipelineSinkElement {
    nonisolated let id: String
    let test: RoundTripTest
    
    var inputPads: [ElementInputPad<DecodedVideoBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, test: RoundTripTest) {
        self.id = id
        self.test = test
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: DecodedVideoBuffer) async {
        await test.addDecodedFrame(buffer)
    }
}