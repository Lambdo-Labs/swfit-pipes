//
//  RTPNetworkSender.swift
//  SwiftPipesRTC
//
//  RTP/RTCP network sender using Network framework
//

import Foundation
import SwiftPipes
import RTC
@preconcurrency import RTP
import NIOCore
import Network

/// RTP network sink that sends packets over UDP
@available(iOS 13.0, macOS 10.15, *)
public actor RTPNetworkSenderSink: PipelineSinkElement {
    public nonisolated let id: String
    private let remoteHost: String
    private let remotePort: UInt16
    private let rtcpPort: UInt16
    private var rtpConnection: NWConnection?
    private var rtcpConnection: NWConnection?
    private let queue = DispatchQueue(label: "RTPNetworkSender")
    
    // RTCP statistics
    private var packetsSent: UInt32 = 0
    private var octetsSent: UInt32 = 0
    private var lastRTCPTime: Date = Date()
    private let rtcpInterval: TimeInterval = 5.0 // Send RTCP every 5 seconds
    
    public var inputPads: [ElementInputPad<RTPPacketBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(
        id: String = "RTPNetworkSender",
        remoteHost: String,
        remotePort: UInt16,
        rtcpPort: UInt16? = nil
    ) {
        self.id = id
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.rtcpPort = rtcpPort ?? (remotePort + 1) // RTCP typically on next port
    }
    
    public func start() async {
        // Create RTP connection
        let rtpEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(remoteHost),
            port: NWEndpoint.Port(integerLiteral: remotePort)
        )
        
        rtpConnection = NWConnection(to: rtpEndpoint, using: .udp)
        
        rtpConnection?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("RTPNetworkSender: RTP connected to \(self.remoteHost):\(self.remotePort)")
            case .failed(let error):
                print("RTPNetworkSender: RTP connection failed: \(error)")
            default:
                break
            }
        }
        
        rtpConnection?.start(queue: queue)
        
        // Create RTCP connection
        let rtcpEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(remoteHost),
            port: NWEndpoint.Port(integerLiteral: rtcpPort)
        )
        
        rtcpConnection = NWConnection(to: rtcpEndpoint, using: .udp)
        
        rtcpConnection?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("RTPNetworkSender: RTCP connected to \(self.remoteHost):\(self.rtcpPort)")
            case .failed(let error):
                print("RTPNetworkSender: RTCP connection failed: \(error)")
            default:
                break
            }
        }
        
        rtcpConnection?.start(queue: queue)
        
        // Start RTCP timer
        Task {
            await startRTCPTimer()
        }
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: RTPPacketBuffer) async {
        guard let connection = rtpConnection else {
            print("RTPNetworkSender: No RTP connection available")
            return
        }
        
        do {
            // Create RTP packet from buffer components
            let packet = RTP.Packet(header: buffer.header, payload: buffer.payload)
            
            // Serialize RTP packet
            var packetBuffer = ByteBufferAllocator().buffer(capacity: 1500)
            let size = try packet.marshalTo(&packetBuffer)
            
            // Convert to Data
            let data = Data(buffer: packetBuffer.readSlice(length: size)!)
            
            // Send data
            await sendData(data, on: connection)
            
            // Update statistics
            packetsSent += 1
            octetsSent += UInt32(data.count)
            
            
            // Check if we need to send RTCP
            if Date().timeIntervalSince(lastRTCPTime) >= rtcpInterval {
                await sendRTCPReport(ssrc: buffer.header.ssrc)
                lastRTCPTime = Date()
            }
            
        } catch {
            print("RTPNetworkSender: Failed to serialize packet: \(error)")
        }
    }
    
    private func sendData(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("RTPNetworkSender: Send error: \(error)")
                }
                continuation.resume()
            })
        }
    }
    
    private func startRTCPTimer() async {
        // Send periodic RTCP reports
        while true {
            try? await Task.sleep(nanoseconds: UInt64(rtcpInterval * 1_000_000_000))
            
            // We need an SSRC to send reports
            // In a real implementation, this would be tracked properly
            // For now, we'll skip if we haven't sent any packets
            if packetsSent > 0 {
                // Use a placeholder SSRC - in real implementation, track from RTP packets
                await sendRTCPReport(ssrc: 0)
            }
        }
    }
    
    private func sendRTCPReport(ssrc: UInt32) async {
        guard let connection = rtcpConnection else { return }
        
        // Create a simple Sender Report (SR)
        // In a real implementation, you'd use proper RTCP structures
        // For now, create a minimal SR packet
        var data = Data()
        
        // RTCP header
        data.append(0x80) // Version=2, P=0, RC=0
        data.append(200)  // PT=200 (Sender Report)
        
        // Length (in 32-bit words - 1)
        let lengthInWords: UInt16 = 6 // Minimal SR
        data.append(UInt8((lengthInWords >> 8) & 0xFF))
        data.append(UInt8(lengthInWords & 0xFF))
        
        // SSRC
        data.append(UInt8((ssrc >> 24) & 0xFF))
        data.append(UInt8((ssrc >> 16) & 0xFF))
        data.append(UInt8((ssrc >> 8) & 0xFF))
        data.append(UInt8(ssrc & 0xFF))
        
        // NTP timestamp (8 bytes) - simplified
        let now = Date().timeIntervalSince1970
        let ntpSeconds = UInt32(now + 2208988800) // NTP epoch offset
        data.append(UInt8((ntpSeconds >> 24) & 0xFF))
        data.append(UInt8((ntpSeconds >> 16) & 0xFF))
        data.append(UInt8((ntpSeconds >> 8) & 0xFF))
        data.append(UInt8(ntpSeconds & 0xFF))
        data.append(contentsOf: [0, 0, 0, 0]) // NTP fraction
        
        // RTP timestamp (4 bytes) - use current time
        let rtpTimestampValue = now * 90000 // 90kHz clock
        let rtpTimestamp = UInt32(UInt64(rtpTimestampValue) % UInt64(UInt32.max))
        data.append(UInt8((rtpTimestamp >> 24) & 0xFF))
        data.append(UInt8((rtpTimestamp >> 16) & 0xFF))
        data.append(UInt8((rtpTimestamp >> 8) & 0xFF))
        data.append(UInt8(rtpTimestamp & 0xFF))
        
        // Sender's packet count
        data.append(UInt8((packetsSent >> 24) & 0xFF))
        data.append(UInt8((packetsSent >> 16) & 0xFF))
        data.append(UInt8((packetsSent >> 8) & 0xFF))
        data.append(UInt8(packetsSent & 0xFF))
        
        // Sender's octet count
        data.append(UInt8((octetsSent >> 24) & 0xFF))
        data.append(UInt8((octetsSent >> 16) & 0xFF))
        data.append(UInt8((octetsSent >> 8) & 0xFF))
        data.append(UInt8(octetsSent & 0xFF))
        
        await sendData(data, on: connection)
        print("RTPNetworkSender: Sent RTCP SR - packets: \(packetsSent), bytes: \(octetsSent)")
    }
    
    public func stop() async {
        rtpConnection?.cancel()
        rtpConnection = nil
        
        rtcpConnection?.cancel()
        rtcpConnection = nil
    }
}