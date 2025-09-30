//
//  H265RTPDepacketizer.swift
//  SwiftPipesRTC
//
//  H.265/HEVC RTP depacketizer according to RFC 7798
//

import Foundation
import SwiftPipes
import RTC
@preconcurrency import RTP
import NIOCore
import CoreMedia

/// H.265 RTP depacketizer filter element
@available(iOS 13.0, macOS 10.15, *)
public actor H265RTPDepacketizerFilter: PipelineFilterElement {
    public nonisolated let id: String
    private var frameBuffer: [UInt32: [RTPPacketBuffer]] = [:] // Group by timestamp
    private var currentTimestamp: UInt32?
    private var lastSequenceNumber: UInt16?
    private var formatDescription: CMFormatDescription? // Store from first keyframe
    private var frameCount = 0
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: EncodedH265Buffer.self, bufferingPolicy: .bufferingNewest(100))
    
    public var outputPads: [ElementOutputPad<AsyncStream<EncodedH265Buffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<RTPPacketBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "H265RTPDepacketizer") {
        self.id = id
    }
    
    public func finish() async {
        // Process any remaining frames
        for timestamp in frameBuffer.keys.sorted() {
            await processFrame(timestamp: timestamp)
        }
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: RTPPacketBuffer) async {
        let timestamp = buffer.header.timestamp
        let sequenceNumber = buffer.header.sequenceNumber
        let marker = buffer.header.marker
        
        // Check for sequence number gap only within same timestamp
        if currentTimestamp == timestamp, let lastSeq = lastSequenceNumber {
            let expectedSeq = (lastSeq &+ 1) & 0xFFFF
            if sequenceNumber != expectedSeq {
                print("H265RTPDepacketizer: Sequence gap within frame. Expected \(expectedSeq), got \(sequenceNumber)")
            }
        } else if currentTimestamp != timestamp {
            // New frame
            currentTimestamp = timestamp
        }
        lastSequenceNumber = sequenceNumber
        
        // Buffer packets by timestamp
        if frameBuffer[timestamp] == nil {
            frameBuffer[timestamp] = []
        }
        frameBuffer[timestamp]?.append(buffer)
        
        // Store format description from any packet that has it
        if let formatDesc = buffer.formatDescription, formatDescription == nil {
            formatDescription = formatDesc
            print("H265RTPDepacketizer: Received format description")
        }
        
        // If marker bit is set, this is the last packet of the frame
        if marker {
            await processFrame(timestamp: timestamp)
        }
        
        // Don't process old frames automatically - wait for marker bit
        // Clean up very old frames (more than 10 timestamps old)
        if frameBuffer.count > 10 {
            let sortedTimestamps = frameBuffer.keys.sorted()
            for ts in sortedTimestamps.prefix(frameBuffer.count - 10) {
                frameBuffer.removeValue(forKey: ts)
            }
        }
    }
    
    private func processFrame(timestamp: UInt32) async {
        guard let packets = frameBuffer[timestamp] else { return }
        
        // Sort packets by sequence number
        let sortedPackets = packets.sorted { $0.header.sequenceNumber < $1.header.sequenceNumber }
        
        var nalUnits: [Data] = []
        var currentFragmentData = Data()
        var isFragmenting = false
        
        for packet in sortedPackets {
            var payload = packet.payload
            guard payload.readableBytes >= 2 else { continue }
            
            // Read first two bytes to determine packet type
            let byte1 = payload.getInteger(at: payload.readerIndex, as: UInt8.self) ?? 0
            let byte2 = payload.getInteger(at: payload.readerIndex + 1, as: UInt8.self) ?? 0
            
            let nalType = (byte1 >> 1) & 0x3F
            
            if nalType == 49 { // FU (Fragmentation Unit)
                // Skip PayloadHdr (2 bytes)
                payload.moveReaderIndex(forwardBy: 2)
                
                guard payload.readableBytes >= 1 else { continue }
                let fuHeader = payload.readInteger(as: UInt8.self) ?? 0
                
                let startBit = (fuHeader & 0x80) != 0
                let endBit = (fuHeader & 0x40) != 0
                let fuType = fuHeader & 0x3F
                
                // Debug FU header
                if startBit {
                    print("H265RTPDepacketizer: FU start - PayloadHdr: \(String(format: "%02X %02X", byte1, byte2)), FU header: \(String(format: "%02X", fuHeader)), FU type: \(fuType)")
                }
                
                if startBit {
                    // Start new fragmented NAL unit
                    currentFragmentData = Data()
                    isFragmenting = true
                    
                    // Reconstruct the 2-byte NAL unit header
                    // H.265 NAL header format:
                    // First byte: forbidden_zero_bit (1 bit) + nal_unit_type (6 bits) + layer_id_H (1 bit)
                    // Second byte: layer_id_L (5 bits) + temporal_id_plus1 (3 bits)
                    let firstByte = (fuType << 1) | (byte1 & 0x01)
                    let secondByte = byte2
                    
                    currentFragmentData.append(firstByte)
                    currentFragmentData.append(secondByte)
                }
                
                if isFragmenting {
                    // Add the payload data
                    if let data = payload.readBytes(length: payload.readableBytes) {
                        currentFragmentData.append(contentsOf: data)
                    }
                    
                    if endBit {
                        // End of fragmented NAL unit
                        nalUnits.append(currentFragmentData)
                        currentFragmentData = Data()
                        isFragmenting = false
                    }
                }
            } else {
                // Single NAL unit packet - entire payload is the NAL unit
                if let data = payload.readBytes(length: payload.readableBytes) {
                    nalUnits.append(Data(data))
                }
            }
        }
        
        // Combine NAL units into AVCC format (length-prefixed)
        var frameData = Data()
        var isKeyFrame = false
        
        for nalu in nalUnits {
            // Check NAL unit type for key frame detection
            if nalu.count >= 2 {
                let nalType = (nalu[0] >> 1) & 0x3F
                // H.265 NAL unit types:
                // 39,40,41: VPS, SPS, PPS  
                // 19,20: IDR (key frames)
                if nalType == 19 || nalType == 20 || nalType == 39 || nalType == 40 || nalType == 41 {
                    isKeyFrame = true
                }
            }
            
            // Write 4-byte length (big-endian)
            var length = UInt32(nalu.count).bigEndian
            frameData.append(Data(bytes: &length, count: 4))
            frameData.append(nalu)
        }
        
        if !frameData.isEmpty {
            // Convert RTP timestamp back to seconds
            let seconds = Double(timestamp) / 90000.0
            let cmTime = CMTime(seconds: seconds, preferredTimescale: 90000)
            
            let encodedBuffer = EncodedH265Buffer(
                data: frameData,
                timestamp: cmTime,
                duration: CMTime(seconds: 1.0/30.0, preferredTimescale: 30), // Assume 30fps
                isKeyFrame: isKeyFrame,
                formatDescription: formatDescription
            )
            
            // Debug: Check what we're outputting
            let outputPreview = frameData.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("H265RTPDepacketizer: Output first 48 bytes: \(outputPreview)")
            
            outputContinuation.yield(encodedBuffer)
            frameCount += 1
            print("H265RTPDepacketizer: Reconstructed frame #\(frameCount) with \(nalUnits.count) NAL units, total size: \(frameData.count), keyframe: \(isKeyFrame), has format desc: \(formatDescription != nil)")
        }
        
        // Clear processed frame
        frameBuffer.removeValue(forKey: timestamp)
    }
    
    // Removed - processing is now done inline in processFrame
}