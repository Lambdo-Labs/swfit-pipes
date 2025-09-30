//
//  MultipeerRTCPSession.swift
//  SwiftPipesRTC
//
//  RTCP-like feedback for MultipeerConnectivity video streaming
//

import Foundation
import SwiftPipes

/// Message types for MultipeerConnectivity video streaming
public enum MultipeerVideoMessage: Codable, Sendable {
    case videoFrame(EncodedH265Buffer)
    case senderReport(SenderReport)
    case receiverReport(ReceiverReport)
    case keyframeRequest(KeyframeRequest)
    case bitrateEstimation(BitrateEstimation)
    
    /// RTCP-like Sender Report for Multipeer
    public struct SenderReport: Codable, Sendable {
        public let ssrc: UInt32
        public let packetCount: UInt32
        public let octetCount: UInt32
        public let timestamp: Date
        
        public init(ssrc: UInt32, packetCount: UInt32, octetCount: UInt32) {
            self.ssrc = ssrc
            self.packetCount = packetCount
            self.octetCount = octetCount
            self.timestamp = Date()
        }
    }
    
    /// RTCP-like Receiver Report for Multipeer
    public struct ReceiverReport: Codable, Sendable {
        public let ssrc: UInt32
        public let senderSSRC: UInt32
        public let packetsReceived: UInt32
        public let packetsLost: UInt32
        public let fractionLost: Float // 0.0 - 1.0
        public let timestamp: Date
        
        public init(ssrc: UInt32, senderSSRC: UInt32, packetsReceived: UInt32, packetsLost: UInt32) {
            self.ssrc = ssrc
            self.senderSSRC = senderSSRC
            self.packetsReceived = packetsReceived
            self.packetsLost = packetsLost
            self.fractionLost = packetsLost > 0 ? Float(packetsLost) / Float(packetsReceived + packetsLost) : 0
            self.timestamp = Date()
        }
    }
    
    /// Keyframe request (like RTCP PLI/FIR)
    public struct KeyframeRequest: Codable, Sendable {
        public let requestingSSRC: UInt32
        public let targetSSRC: UInt32
        public let reason: String
        
        public init(from: UInt32, to: UInt32, reason: String = "packet loss") {
            self.requestingSSRC = from
            self.targetSSRC = to
            self.reason = reason
        }
    }
    
    /// Bitrate estimation (like RTCP REMB)
    public struct BitrateEstimation: Codable, Sendable {
        public let ssrc: UInt32
        public let estimatedBitrate: UInt64 // bits per second
        public let timestamp: Date
        
        public init(ssrc: UInt32, bitrate: UInt64) {
            self.ssrc = ssrc
            self.estimatedBitrate = bitrate
            self.timestamp = Date()
        }
    }
}

/// Manages RTCP-like feedback for MultipeerConnectivity
public actor MultipeerRTCPSession {
    private let ssrc: UInt32
    private var senderStats = SenderStatistics()
    private var receiverStats = ReceiverStatistics()
    private var lastReportTime = Date()
    private let reportInterval: TimeInterval = 5.0
    
    public struct SenderStatistics: Sendable {
        public var framesSent: UInt32 = 0
        public var bytesSent: UInt32 = 0
        public var keyframesSent: UInt32 = 0
    }
    
    public struct ReceiverStatistics: Sendable {
        public var framesReceived: UInt32 = 0
        public var framesLost: UInt32 = 0
        public var lastSequenceNumber: UInt32 = 0
        public var outOfOrderFrames: UInt32 = 0
    }
    
    public init(ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.ssrc = ssrc
    }
    
    /// Update stats when sending a frame
    public func frameSent(_ frame: EncodedH265Buffer) {
        senderStats.framesSent += 1
        senderStats.bytesSent += UInt32(frame.data.count)
        if frame.isKeyFrame {
            senderStats.keyframesSent += 1
        }
    }
    
    /// Update stats when receiving a frame (with sequence number)
    public func frameReceived(sequenceNumber: UInt32, size: Int) {
        receiverStats.framesReceived += 1
        
        // Simple loss detection
        if receiverStats.lastSequenceNumber > 0 {
            let expected = receiverStats.lastSequenceNumber + 1
            if sequenceNumber != expected {
                if sequenceNumber > expected {
                    // Gap detected
                    let lost = sequenceNumber - expected
                    receiverStats.framesLost += lost
                } else {
                    // Out of order
                    receiverStats.outOfOrderFrames += 1
                }
            }
        }
        receiverStats.lastSequenceNumber = sequenceNumber
    }
    
    /// Check if it's time to send a report
    public func shouldSendReport() -> Bool {
        return Date().timeIntervalSince(lastReportTime) >= reportInterval
    }
    
    /// Generate sender report
    public func generateSenderReport() -> MultipeerVideoMessage {
        lastReportTime = Date()
        return .senderReport(
            MultipeerVideoMessage.SenderReport(
                ssrc: ssrc,
                packetCount: senderStats.framesSent,
                octetCount: senderStats.bytesSent
            )
        )
    }
    
    /// Generate receiver report
    public func generateReceiverReport(aboutSSRC: UInt32) -> MultipeerVideoMessage {
        return .receiverReport(
            MultipeerVideoMessage.ReceiverReport(
                ssrc: ssrc,
                senderSSRC: aboutSSRC,
                packetsReceived: receiverStats.framesReceived,
                packetsLost: receiverStats.framesLost
            )
        )
    }
    
    /// Request a keyframe
    public func requestKeyframe(from targetSSRC: UInt32, reason: String = "packet loss") -> MultipeerVideoMessage {
        return .keyframeRequest(
            MultipeerVideoMessage.KeyframeRequest(
                from: ssrc,
                to: targetSSRC,
                reason: reason
            )
        )
    }
    
    /// Send bitrate estimation
    public func estimateBitrate(_ bitrate: UInt64) -> MultipeerVideoMessage {
        return .bitrateEstimation(
            MultipeerVideoMessage.BitrateEstimation(
                ssrc: ssrc,
                bitrate: bitrate
            )
        )
    }
    
    /// Get current statistics
    public func getStatistics() -> (sent: SenderStatistics, received: ReceiverStatistics) {
        return (senderStats, receiverStats)
    }
}

/// Filter that adds sequence numbers and prepares frames for MultipeerConnectivity
public actor MultipeerVideoFilter: PipelineFilterElement {
    public typealias InputBuffers = EncodedH265Buffer
    public typealias OutputBuffers = AsyncStream<MultipeerVideoFrame>
    
    public nonisolated let id: String
    private let rtcpSession: MultipeerRTCPSession
    private var sequenceNumber: UInt32 = 0
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: MultipeerVideoFrame.self)
    
    public var outputPads: [ElementOutputPad<OutputBuffers>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<InputBuffers>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "MultipeerVideoFilter", ssrc: UInt32? = nil) {
        self.id = id
        self.rtcpSession = MultipeerRTCPSession(ssrc: ssrc ?? UInt32.random(in: 1...UInt32.max))
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        // Add sequence number for loss detection
        sequenceNumber &+= 1
        
        let frame = MultipeerVideoFrame(
            sequenceNumber: sequenceNumber,
            encodedBuffer: buffer
        )
        
        // Update RTCP statistics
        await rtcpSession.frameSent(buffer)
        
        // Output the frame
        outputContinuation.yield(frame)
        
        // Check if we should send RTCP report
        if await rtcpSession.shouldSendReport() {
            await sendReport()
        }
    }
    
    private func sendReport() async {
        let report = await rtcpSession.generateSenderReport()
        // In real implementation, this would be sent via MultipeerConnectivity
        print("MultipeerVideo: Sending \(report)")
    }
    
    /// Get the RTCP session for sending feedback
    public func getRTCPSession() -> MultipeerRTCPSession {
        return rtcpSession
    }
    
    public func finish() {
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {}
}

/// Video frame with sequence number for MultipeerConnectivity
public struct MultipeerVideoFrame: BufferProtocol, Codable {
    public let sequenceNumber: UInt32
    public let encodedBuffer: EncodedH265Buffer
    
    public init(sequenceNumber: UInt32, encodedBuffer: EncodedH265Buffer) {
        self.sequenceNumber = sequenceNumber
        self.encodedBuffer = encodedBuffer
    }
}