import Foundation
import SwiftPipesRTC
import SwiftPipes
import AVFoundation

@main
struct RTPRTCPSimpleExample {
    static func main() async {
        print("RTP/RTCP Simple Example: H.265 Video Streaming")
        print("==============================================")
        print("This example demonstrates how RTP and RTCP work as separate channels")
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
            let example = SimpleRTPRTCPExample()
            try await example.run()
            
        } catch {
            print("ERROR: \(error)")
        }
    }
}

/// Simplified RTCP packet structure for demonstration
struct SimpleRTCPPacket {
    enum PacketType {
        case senderReport
        case receiverReport
        case sourceDescription
        case pictureLossIndication
        case remb
    }
    
    let type: PacketType
    let ssrc: UInt32
    let data: Data
    let info: String
    
    init(type: PacketType, ssrc: UInt32, info: String) {
        self.type = type
        self.ssrc = ssrc
        self.info = info
        // In real implementation, this would be properly formatted RTCP data
        self.data = "\(type) from \(ssrc): \(info)".data(using: .utf8)!
    }
}

/// Simple RTCP manager for demonstration
actor SimpleRTCPManager {
    private let ssrc: UInt32
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    private var lastSentTime = Date()
    
    init(ssrc: UInt32) {
        self.ssrc = ssrc
    }
    
    func updateStats(packets: UInt32, octets: UInt32) {
        self.packetCount = packets
        self.octetCount = octets
    }
    
    func generateSenderReport() -> SimpleRTCPPacket {
        lastSentTime = Date()
        return SimpleRTCPPacket(
            type: .senderReport,
            ssrc: ssrc,
            info: "packets=\(packetCount), octets=\(octetCount)"
        )
    }
    
    func generatePLI(targetSSRC: UInt32) -> SimpleRTCPPacket {
        return SimpleRTCPPacket(
            type: .pictureLossIndication,
            ssrc: ssrc,
            info: "requesting keyframe from \(targetSSRC)"
        )
    }
    
    func generateREMB(bitrate: UInt64) -> SimpleRTCPPacket {
        return SimpleRTCPPacket(
            type: .remb,
            ssrc: ssrc,
            info: "estimated bitrate=\(bitrate) bps"
        )
    }
}

actor SimpleRTPRTCPExample {
    func run() async throws {
        print("1. Setting up RTP video pipeline...")
        
        let pipeline = SimplePipeline()
        let ssrc = UInt32.random(in: 1...UInt32.max)
        print("   Session SSRC: 0x\(String(format: "%08X", ssrc))")
        
        // RTP Pipeline
        let cameraSource = CameraCaptureSource(id: "camera")
        let h265Encoder = H265EncoderFilter(
            id: "h265Encoder",
            bitRate: 2_000_000,
            frameRate: 30.0
        )
        let rtpPacketizer = RTPPacketizer(id: "rtpPacketizer", ssrc: ssrc)
        let rtpOutput = RTPOutputHandler(id: "rtpOutput", port: 5004)
        
        await pipeline.buildGroups([
            (id: "rtpPipeline", children: [
                .source(child: cameraSource),
                .filter(child: h265Encoder),
                .filter(child: rtpPacketizer),
                .sink(child: rtpOutput)
            ])
        ])
        
        print("\n2. Setting up RTCP channel (separate from RTP)...")
        
        // RTCP runs independently
        let rtcpManager = SimpleRTCPManager(ssrc: ssrc)
        let rtcpOutput = RTCPOutputHandler(port: 5005)
        
        // Start RTCP report timer
        let rtcpTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                
                // Get current RTP stats
                let (packets, octets) = await rtpPacketizer.getStatistics()
                await rtcpManager.updateStats(packets: packets, octets: octets)
                
                // Send RTCP Sender Report
                let sr = await rtcpManager.generateSenderReport()
                await rtcpOutput.send(sr)
            }
        }
        
        print("\n3. Starting streams...")
        print("   📹 RTP video → port 5004")
        print("   📊 RTCP control → port 5005")
        print()
        
        try await cameraSource.start()
        await pipeline.start()
        
        // Demonstrate RTCP feedback messages
        
        // After 3 seconds - simulate keyframe request
        try await Task.sleep(nanoseconds: 3_000_000_000)
        print("\n4. Simulating decoder feedback...")
        let pli = await rtcpManager.generatePLI(targetSSRC: ssrc)
        await rtcpOutput.send(pli)
        
        // After 6 seconds - simulate bandwidth estimation
        try await Task.sleep(nanoseconds: 3_000_000_000)
        print("\n5. Simulating bandwidth adaptation...")
        let remb = await rtcpManager.generateREMB(bitrate: 1_500_000)
        await rtcpOutput.send(remb)
        
        // Run for 10 more seconds
        try await Task.sleep(nanoseconds: 10_000_000_000)
        
        print("\n6. Stopping streams...")
        rtcpTask.cancel()
        await cameraSource.finish()
        await h265Encoder.finish()
        await rtpPacketizer.finish()
        await pipeline.stop()
        
        // Final stats
        let (finalPackets, finalOctets) = await rtpPacketizer.getStatistics()
        print("\n=== Final Statistics ===")
        print("📹 RTP:")
        print("   Packets sent: \(finalPackets)")
        print("   Bytes sent: \(finalOctets)")
        print("   Average packet size: \(finalPackets > 0 ? finalOctets/finalPackets : 0) bytes")
        print("\n📊 RTCP:")
        print("   Sender Reports: ~\(20/5) (every 5 seconds)")
        print("   PLI sent: 1 (keyframe request)")
        print("   REMB sent: 1 (bandwidth estimation)")
        
        print("\n=== KEY CONCEPTS DEMONSTRATED ===")
        print("• RTP carries the actual video data")
        print("• RTCP provides control and feedback")
        print("• They use separate ports (RTP: even, RTCP: odd)")
        print("• RTCP includes:")
        print("  - Sender Reports (statistics)")
        print("  - Receiver Reports (quality feedback)")
        print("  - PLI/FIR (keyframe requests)")
        print("  - REMB (bandwidth estimation)")
        
        print("\n=== EXAMPLE COMPLETE ===")
    }
}

// RTP output handler
actor RTPOutputHandler: PipelineSinkElement {
    nonisolated let id: String
    private let port: UInt16
    private var stats = StreamStats()
    
    struct StreamStats {
        var packets: UInt32 = 0
        var bytes: UInt64 = 0
        var keyframes: UInt32 = 0
        var lastLogTime = Date()
    }
    
    var inputPads: [ElementInputPad<RTPPacket>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, port: UInt16) {
        self.id = id
        self.port = port
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: RTPPacket) async {
        stats.packets += 1
        stats.bytes += UInt64(buffer.data.count)
        
        // Log periodically
        if Date().timeIntervalSince(stats.lastLogTime) >= 5.0 {
            print("RTP[\(port)]: \(stats.packets) packets, \(stats.bytes) bytes, bitrate: \(calculateBitrate()) Mbps")
            stats.lastLogTime = Date()
        }
    }
    
    private func calculateBitrate() -> String {
        let duration = Date().timeIntervalSince(stats.lastLogTime)
        guard duration > 0 else { return "0" }
        let bitsPerSecond = Double(stats.bytes * 8) / duration
        let mbps = bitsPerSecond / 1_000_000
        return String(format: "%.2f", mbps)
    }
    
    func onCancel(task: PipeTask) {}
}

// RTCP output handler
actor RTCPOutputHandler {
    private let port: UInt16
    private var reportCount = 0
    
    init(port: UInt16) {
        self.port = port
    }
    
    func send(_ packet: SimpleRTCPPacket) {
        reportCount += 1
        
        let icon = switch packet.type {
        case .senderReport: "📈"
        case .receiverReport: "📉"
        case .sourceDescription: "ℹ️"
        case .pictureLossIndication: "🖼️"
        case .remb: "📊"
        }
        
        print("RTCP[\(port)]: \(icon) \(packet.type) - \(packet.info)")
    }
}