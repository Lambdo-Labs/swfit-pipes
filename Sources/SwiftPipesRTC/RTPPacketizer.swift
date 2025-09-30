//
//  RTPPacketizer.swift
//  SwiftPipesRTC
//
//  RTP packetizer for H.265 video frames
//

import Foundation
import SwiftPipes

/// RTP packet header
public struct RTPHeader: Sendable {
    public var version: UInt8 = 2
    public var padding: Bool = false
    public var `extension`: Bool = false
    public var csrcCount: UInt8 = 0
    public var marker: Bool = false
    public var payloadType: UInt8 = 96 // Dynamic payload type for H.265
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    
    public func marshal() -> Data {
        var data = Data()
        
        // First byte: V(2), P(1), X(1), CC(4)
        var firstByte = (version << 6) | (csrcCount & 0x0F)
        if padding { firstByte |= 0x20 }
        if `extension` { firstByte |= 0x10 }
        data.append(firstByte)
        
        // Second byte: M(1), PT(7)
        var secondByte = payloadType & 0x7F
        if marker { secondByte |= 0x80 }
        data.append(secondByte)
        
        // Sequence number (2 bytes, big endian)
        data.append(UInt8((sequenceNumber >> 8) & 0xFF))
        data.append(UInt8(sequenceNumber & 0xFF))
        
        // Timestamp (4 bytes, big endian)
        data.append(UInt8((timestamp >> 24) & 0xFF))
        data.append(UInt8((timestamp >> 16) & 0xFF))
        data.append(UInt8((timestamp >> 8) & 0xFF))
        data.append(UInt8(timestamp & 0xFF))
        
        // SSRC (4 bytes, big endian)
        data.append(UInt8((ssrc >> 24) & 0xFF))
        data.append(UInt8((ssrc >> 16) & 0xFF))
        data.append(UInt8((ssrc >> 8) & 0xFF))
        data.append(UInt8(ssrc & 0xFF))
        
        return data
    }
}

/// RTP packet containing H.265 data
public struct RTPPacket: BufferProtocol, Sendable {
    public let header: RTPHeader
    public let payload: Data
    
    public var data: Data {
        header.marshal() + payload
    }
    
    public init(header: RTPHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

/// RTP packetizer for H.265 video
/// This creates RTP packets from H.265 encoded frames
public actor RTPPacketizer: PipelineFilterElement {
    public typealias InputBuffers = EncodedH265Buffer
    public typealias OutputBuffers = AsyncStream<RTPPacket>
    
    public nonisolated let id: String
    private let ssrc: UInt32
    private var sequenceNumber: UInt16 = 0
    private let maxPayloadSize: Int = 1400 // Keep under typical MTU
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: RTPPacket.self)
    
    // Statistics for RTCP
    private(set) var packetsSent: UInt32 = 0
    private(set) var octetsSent: UInt32 = 0
    
    public var outputPads: [ElementOutputPad<OutputBuffers>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<InputBuffers>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(
        id: String = "RTPPacketizer",
        ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    ) {
        self.id = id
        self.ssrc = ssrc
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        // Convert CMTime to RTP timestamp (90kHz clock for video)
        // Handle overflow by wrapping around
        let timestampValue = buffer.timestamp.seconds * 90000
        let rtpTimestamp = UInt32(truncatingIfNeeded: Int64(timestampValue))
        
        // For small NAL units, send as single RTP packet
        if buffer.data.count <= maxPayloadSize {
            let header = RTPHeader(
                sequenceNumber: getNextSequenceNumber(),
                timestamp: rtpTimestamp,
                ssrc: ssrc
            )
            
            let packet = RTPPacket(header: header, payload: buffer.data)
            outputContinuation.yield(packet)
            
            // Update statistics
            packetsSent += 1
            octetsSent += UInt32(buffer.data.count)
            
        } else {
            // For large NAL units, fragment using FU-A (Fragmentation Unit)
            // This is simplified - real implementation would properly handle H.265 FU format
            var offset = 0
            let nalUnitHeader = buffer.data[0..<2] // First 2 bytes of H.265 NAL
            
            while offset < buffer.data.count {
                let remainingBytes = buffer.data.count - offset
                let fragmentSize = min(maxPayloadSize - 3, remainingBytes) // -3 for FU header
                
                var header = RTPHeader(
                    sequenceNumber: getNextSequenceNumber(),
                    timestamp: rtpTimestamp,
                    ssrc: ssrc
                )
                
                // Set marker bit on last fragment
                if offset + fragmentSize >= buffer.data.count {
                    header.marker = true
                }
                
                // Create FU payload (simplified)
                var fuPayload = Data()
                fuPayload.append(contentsOf: nalUnitHeader) // FU header
                fuPayload.append(offset == 0 ? 0x80 : 0x00) // S bit for start
                fuPayload.append(contentsOf: buffer.data[offset..<(offset + fragmentSize)])
                
                let packet = RTPPacket(header: header, payload: fuPayload)
                outputContinuation.yield(packet)
                
                packetsSent += 1
                octetsSent += UInt32(fragmentSize)
                offset += fragmentSize
            }
        }
    }
    
    private func getNextSequenceNumber() -> UInt16 {
        let seq = sequenceNumber
        sequenceNumber &+= 1
        return seq
    }
    
    /// Get current statistics for RTCP reporting
    public func getStatistics() -> (packets: UInt32, octets: UInt32) {
        return (packetsSent, octetsSent)
    }
    
    public func finish() {
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {}
}