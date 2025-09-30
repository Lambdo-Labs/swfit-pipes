import Foundation
import SwiftPipesRTC
import SwiftPipes
import AVFoundation

@main
struct MultipeerSimpleExample {
    static func main() async {
        print("MultipeerConnectivity + H.265 + RTCP Example (Simplified)")
        print("========================================================")
        print("This example shows how to use Codable H.265 frames with RTCP feedback")
        print()
        
        do {
            // Check camera permission
            let status = AVCaptureDevice.authorizationStatus(for: .video)
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
            
            // Run the example
            let example = MultipeerExample()
            try await example.run()
            
        } catch {
            print("ERROR: \(error)")
        }
    }
}

actor MultipeerExample {
    func run() async throws {
        print("1. Setting up video pipeline with MultipeerConnectivity support...")
        
        let pipeline = SimplePipeline()
        let ssrc = UInt32.random(in: 1...UInt32.max)
        print("   Session SSRC: 0x\(String(format: "%08X", ssrc))")
        
        // Create pipeline
        let cameraSource = CameraCaptureSource(id: "camera")
        let h265Encoder = H265EncoderFilter(
            id: "h265Encoder",
            bitRate: 1_000_000, // 1 Mbps for peer-to-peer
            frameRate: 15.0     // Lower framerate for peer-to-peer
        )
        let multipeerFilter = MultipeerVideoFilter(id: "multipeerFilter", ssrc: ssrc)
        let outputSink = CodableVideoSink(id: "output")
        
        await pipeline.buildGroups([
            (id: "videoPipeline", children: [
                .source(child: cameraSource),
                .filter(child: h265Encoder),
                .filter(child: multipeerFilter),
                .sink(child: outputSink)
            ])
        ])
        
        print("\n2. Message types for MultipeerConnectivity:")
        print("   • Video frames (Codable H.265)")
        print("   • Sender reports (statistics)")
        print("   • Receiver reports (quality feedback)")
        print("   • Keyframe requests (PLI/FIR)")
        print("   • Bitrate estimation (REMB)")
        
        print("\n3. Starting video capture...")
        try await cameraSource.start()
        await pipeline.start()
        
        // Run for 10 seconds
        try await Task.sleep(nanoseconds: 10_000_000_000)
        
        // Demonstrate RTCP-like messages
        print("\n4. Example RTCP messages for MultipeerConnectivity:")
        
        // Get RTCP session from filter
        let rtcpSession = await multipeerFilter.getRTCPSession()
        
        // Example: Generate sender report
        let senderReport = await rtcpSession.generateSenderReport()
        print("\n📊 Sender Report:")
        printMessage(senderReport)
        
        // Example: Generate keyframe request
        let keyframeRequest = await rtcpSession.requestKeyframe(from: ssrc, reason: "packet loss detected")
        print("\n🖼️ Keyframe Request:")
        printMessage(keyframeRequest)
        
        // Example: Generate bitrate estimation
        let bitrateEstimation = await rtcpSession.estimateBitrate(750_000)
        print("\n📊 Bitrate Estimation:")
        printMessage(bitrateEstimation)
        
        print("\n5. Stopping pipeline...")
        await cameraSource.finish()
        await h265Encoder.finish()
        await multipeerFilter.finish()
        await pipeline.stop()
        
        // Get final statistics
        let stats = await outputSink.getStatistics()
        print("\n=== Final Statistics ===")
        print("📹 Video frames sent: \(stats.frameCount)")
        print("📦 Total data size: \(formatBytes(stats.totalBytes))")
        print("🎯 Keyframes: \(stats.keyframeCount)")
        print("📏 Average frame size: \(formatBytes(stats.frameCount > 0 ? stats.totalBytes / UInt64(stats.frameCount) : 0))")
        
        print("\n=== How to Use with MultipeerConnectivity ===")
        print("1. Encode messages using JSONEncoder:")
        print("   let data = try JSONEncoder().encode(message)")
        print("   session.send(data, toPeers: peers, with: .reliable)")
        print()
        print("2. Decode received messages:")
        print("   let message = try JSONDecoder().decode(MultipeerVideoMessage.self, from: data)")
        print("   switch message { ... }")
        print()
        print("3. Handle feedback:")
        print("   • On keyframe request → force encoder to generate keyframe")
        print("   • On bitrate estimation → adjust encoder bitrate")
        print("   • On receiver report → monitor quality")
        
        print("\n=== EXAMPLE COMPLETE ===")
    }
    
    private func printMessage(_ message: MultipeerVideoMessage) {
        switch message {
        case .senderReport(let report):
            print("   SSRC: 0x\(String(format: "%08X", report.ssrc))")
            print("   Packets: \(report.packetCount)")
            print("   Bytes: \(report.octetCount)")
            
        case .keyframeRequest(let request):
            print("   From: 0x\(String(format: "%08X", request.requestingSSRC))")
            print("   To: 0x\(String(format: "%08X", request.targetSSRC))")
            print("   Reason: \(request.reason)")
            
        case .bitrateEstimation(let estimation):
            print("   SSRC: 0x\(String(format: "%08X", estimation.ssrc))")
            print("   Bitrate: \(estimation.estimatedBitrate / 1000) kbps")
            
        default:
            break
        }
        
        // Show how it would be encoded
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(message)
            print("   JSON size: \(data.count) bytes")
            if data.count < 500 {
                print("   JSON preview:")
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("   " + jsonString.replacingOccurrences(of: "\n", with: "\n   "))
                }
            }
        } catch {
            print("   Encoding error: \(error)")
        }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// Sink that counts Codable video frames
actor CodableVideoSink: PipelineSinkElement {
    nonisolated let id: String
    private var statistics = Statistics()
    
    struct Statistics {
        var frameCount: UInt32 = 0
        var totalBytes: UInt64 = 0
        var keyframeCount: UInt32 = 0
    }
    
    var inputPads: [ElementInputPad<MultipeerVideoFrame>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String) {
        self.id = id
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: MultipeerVideoFrame) async {
        statistics.frameCount += 1
        statistics.totalBytes += UInt64(buffer.encodedBuffer.data.count)
        
        if buffer.encodedBuffer.isKeyFrame {
            statistics.keyframeCount += 1
        }
        
        // Log every 30 frames (2 seconds at 15fps)
        if statistics.frameCount % 30 == 0 {
            print("Progress: \(statistics.frameCount) frames, \(formatBytes(statistics.totalBytes))")
        }
    }
    
    func getStatistics() -> Statistics {
        return statistics
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    func onCancel(task: PipeTask) {}
}