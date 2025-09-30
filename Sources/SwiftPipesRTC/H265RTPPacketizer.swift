//
//  H265RTPPacketizer.swift
//  SwiftPipesRTC
//
//  H.265/HEVC RTP packetizer according to RFC 7798
//

import Foundation
import SwiftPipes
import RTC
@preconcurrency import RTP
import NIOCore
import CoreMedia

enum PacketizerError: Error {
    case invalidNALUnit
}

/// H.265 RTP packetizer filter element
@available(iOS 13.0, macOS 10.15, *)
public actor H265RTPPacketizerFilter: PipelineFilterElement {
    public nonisolated let id: String
    private let ssrc: UInt32
    private let payloadType: UInt8 = 98 // Typical for H.265
    private let clockRate: UInt32 = 90000 // Standard for video
    private let maxPayloadSize: Int
    private var sequenceNumber: UInt16 = 0
    private var allocator = ByteBufferAllocator()
    private var currentFormatDescription: CMFormatDescription?
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: RTPPacketBuffer.self, bufferingPolicy: .bufferingNewest(1000))
    
    public var outputPads: [ElementOutputPad<AsyncStream<RTPPacketBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(
        id: String = "H265RTPPacketizer",
        ssrc: UInt32 = UInt32.random(in: 1...UInt32.max),
        maxPayloadSize: Int = 1400 // Leave room for IP/UDP headers
    ) {
        self.id = id
        self.ssrc = ssrc
        self.maxPayloadSize = maxPayloadSize
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        // Store format description if available
        if let formatDesc = buffer.formatDescription {
            currentFormatDescription = formatDesc
        }
        
        // Get NAL unit length size from format description
        var lengthSize = 4 // default
        if let formatDesc = buffer.formatDescription {
            // Try to get the actual length size from the format description
            // For H.265, this is typically stored in the hvcC atom
            let cfDict = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any]
            if let sampleDescriptionExtensions = cfDict?["SampleDescriptionExtensionAtoms"] as? [String: Any],
               let hvcC = sampleDescriptionExtensions["hvcC"] as? Data,
               hvcC.count > 22 {
                // The lengthSizeMinusOne is at byte offset 21 (last 2 bits)
                lengthSize = Int((hvcC[21] & 0x03) + 1)
            }
        }
        
        // Process the entire buffer as AVCC format
        let nalUnits = extractNALUnitsAVCCSafe(from: buffer.data, lengthSize: lengthSize)
        
        if nalUnits.isEmpty {
            print("H265RTPPacketizer: No NAL units found in \(buffer.data.count) byte frame")
            // Debug: print first few bytes
            let preview = buffer.data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  First bytes: \(preview)")
            print("  Length size: \(lengthSize)")
            return
        }
        
        // Debug NAL units
        print("H265RTPPacketizer: Found \(nalUnits.count) NAL units, length size: \(lengthSize)")
        
        // Convert to RTP timestamp, using modulo to prevent overflow
        let timestampValue = buffer.timestamp.seconds * Double(clockRate)
        let rtpTimestamp = UInt32(UInt64(timestampValue) % UInt64(UInt32.max))
        
        // For H.265, we should send all NAL units of a frame together
        // Only set marker on the last packet of the entire frame
        var totalPackets = 0
        for nalu in nalUnits {
            if nalu.count <= maxPayloadSize {
                totalPackets += 1
            } else {
                // Calculate fragments needed
                let payloadDataSize = maxPayloadSize - 3 // 2 for PayloadHdr, 1 for FU header
                totalPackets += (nalu.count + payloadDataSize - 1) / payloadDataSize
            }
        }
        
        var packetsSent = 0
        for naluData in nalUnits {
            let packetsForThisNALU = await packetizeNALUnit(naluData, timestamp: rtpTimestamp, 
                                                           currentPacket: &packetsSent, 
                                                           totalPackets: totalPackets)
        }
    }
    
    private func extractNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0
        
        while currentIndex < data.count - 4 {
            // Look for start code (0x00 0x00 0x00 0x01) or (0x00 0x00 0x01)
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
    
    private func extractNALUnitsAVCCSafe(from data: Data, lengthSize: Int = 4) -> [Data] {
        var nalUnits: [Data] = []
        var offset = 0
        let dataArray = Array(data) // Convert to array for safer access
        
        while offset + lengthSize <= dataArray.count {
            // Read length based on lengthSize (big-endian)
            var length: UInt32 = 0
            
            switch lengthSize {
            case 1:
                length = UInt32(dataArray[offset])
            case 2:
                length = UInt32(dataArray[offset]) << 8 | UInt32(dataArray[offset + 1])
            case 3:
                length = UInt32(dataArray[offset]) << 16 | UInt32(dataArray[offset + 1]) << 8 | UInt32(dataArray[offset + 2])
            case 4:
                length = UInt32(dataArray[offset]) << 24 | UInt32(dataArray[offset + 1]) << 16 | 
                         UInt32(dataArray[offset + 2]) << 8 | UInt32(dataArray[offset + 3])
            default:
                break
            }
            
            // Sanity check
            if length == 0 || offset + lengthSize + Int(length) > dataArray.count {
                break
            }
            
            // Extract NAL unit data and create a new Data object
            let naluStart = offset + lengthSize
            let naluEnd = naluStart + Int(length)
            
            // Only process NAL units with at least 2 bytes (for header)
            if naluEnd > naluStart + 1 {
                let naluBytes = Array(dataArray[naluStart..<naluEnd])
                let naluData = Data(naluBytes)
                
                // Debug print
                print("  NAL unit \(nalUnits.count): size=\(naluData.count)")
                if naluData.count >= 4 {
                    let preview = naluBytes[0..<4].map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("    First bytes: \(preview)")
                }
                
                nalUnits.append(naluData)
            }
            
            offset = naluEnd
        }
        
        return nalUnits
    }
    
    private func packetizeNALUnit(_ naluData: Data, timestamp: UInt32, currentPacket: inout Int, totalPackets: Int) async -> Int {
        guard naluData.count >= 2 else { 
            print("H265RTPPacketizer: Skipping NAL unit with invalid size: \(naluData.count)")
            return 0
        }
        
        var packetCount = 0
        do {
            if naluData.count <= maxPayloadSize {
                // Single NAL unit packet
                currentPacket += 1
                let isLastPacket = currentPacket == totalPackets
                try await sendSingleNALUPacket(naluData, timestamp: timestamp, marker: isLastPacket)
                packetCount = 1
            } else {
                // Fragment using FU (Fragmentation Units)
                let fragments = try await sendFragmentedNALU(naluData, timestamp: timestamp, 
                                                           currentPacket: &currentPacket, 
                                                           totalPackets: totalPackets)
                packetCount = fragments
            }
        } catch {
            print("H265RTPPacketizer: Error packetizing NAL unit: \(error)")
        }
        return packetCount
    }
    
    private func sendSingleNALUPacket(_ naluData: Data, timestamp: UInt32, marker: Bool) async throws {
        var payload = allocator.buffer(capacity: naluData.count)
        payload.writeBytes(Array(naluData))
        
        let header = RTP.Header(
            version: 2,
            padding: false,
            ext: false,
            marker: marker,
            payloadType: payloadType,
            sequenceNumber: nextSequenceNumber(),
            timestamp: timestamp,
            ssrc: ssrc,
            csrcs: [],
            extensionProfile: 0,
            extensions: []
        )
        
        let packet = RTP.Packet(header: header, payload: payload)
        let rtpBuffer = RTPPacketBuffer(packet: packet, formatDescription: currentFormatDescription)
        outputContinuation.yield(rtpBuffer)
    }
    
    private func sendFragmentedNALU(_ naluData: Data, timestamp: UInt32, currentPacket: inout Int, totalPackets: Int) async throws -> Int {
        guard naluData.count >= 2 else { throw PacketizerError.invalidNALUnit }
        
        // Convert to array for safe access
        let naluArray = Array(naluData)
        
        // H.265 uses 2-byte NAL unit header
        let naluHeader = UInt16(naluArray[0]) << 8 | UInt16(naluArray[1])
        
        // Create FU header from NAL unit header
        let fuType: UInt8 = 49 // FU type for H.265
        let layerId = (naluHeader >> 9) & 0x3F
        let tid = naluHeader & 0x07
        
        // PayloadHdr (16 bits) for FU
        let payloadHdr = (UInt16(fuType) << 9) | (UInt16(layerId) << 3) | UInt16(tid)
        
        var offset = 2 // Skip NAL header
        var isFirst = true
        var fragmentCount = 0
        
        while offset < naluData.count {
            let remaining = naluData.count - offset
            let payloadSize = min(remaining, maxPayloadSize - 3) // 2 bytes for PayloadHdr, 1 for FU header
            
            var payload = allocator.buffer(capacity: payloadSize + 3)
            
            // Write PayloadHdr (2 bytes)
            payload.writeInteger(UInt8(payloadHdr >> 8))
            payload.writeInteger(UInt8(payloadHdr & 0xFF))
            
            // Write FU header (1 byte)
            // Extract NAL unit type from first byte (bits 1-6)
            let firstByte = UInt8(naluHeader >> 8)
            let nalUnitType = (firstByte >> 1) & 0x3F
            var fuHeader: UInt8 = nalUnitType
            if isFirst {
                fuHeader |= 0x80 // S bit (start)
            }
            if offset + payloadSize >= naluData.count {
                fuHeader |= 0x40 // E bit (end)
            }
            payload.writeInteger(fuHeader)
            
            // Write payload data
            let payloadBytes = Array(naluArray[offset..<offset + payloadSize])
            payload.writeBytes(payloadBytes)
            
            currentPacket += 1
            let isLastPacket = currentPacket == totalPackets
            
            let header = RTP.Header(
                version: 2,
                padding: false,
                ext: false,
                marker: isLastPacket,
                payloadType: payloadType,
                sequenceNumber: nextSequenceNumber(),
                timestamp: timestamp,
                ssrc: ssrc,
                csrcs: [],
                extensionProfile: 0,
                extensions: []
            )
            
            let packet = RTP.Packet(header: header, payload: payload)
            let rtpBuffer = RTPPacketBuffer(packet: packet, formatDescription: currentFormatDescription)
            outputContinuation.yield(rtpBuffer)
            
            offset += payloadSize
            isFirst = false
            fragmentCount += 1
        }
        
        return fragmentCount
    }
    
    private func nextSequenceNumber() -> UInt16 {
        let seq = sequenceNumber
        sequenceNumber &+= 1 // Wrapping add
        return seq
    }
    
    public func finish() {
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
}