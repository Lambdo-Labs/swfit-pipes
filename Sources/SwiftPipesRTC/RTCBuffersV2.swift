//
//  RTCBuffersV2.swift
//  SwiftPipesRTC
//
//  Updated buffer types for RTC pipeline elements using NIOCore
//

import Foundation
import SwiftPipes
import RTC
@preconcurrency import RTP
import NIOCore
import CoreMedia

/// Buffer containing an RTP packet
public struct RTPPacketBuffer: BufferProtocol {
    public let header: RTP.Header
    public let payload: ByteBuffer
    public let timestamp: TimeInterval
    public let formatDescription: CMFormatDescription?
    
    public init(header: RTP.Header, payload: ByteBuffer, timestamp: TimeInterval = Date().timeIntervalSince1970, formatDescription: CMFormatDescription? = nil) {
        self.header = header
        self.payload = payload
        self.timestamp = timestamp
        self.formatDescription = formatDescription
    }
    
    public init(packet: RTP.Packet, timestamp: TimeInterval = Date().timeIntervalSince1970, formatDescription: CMFormatDescription? = nil) {
        self.header = packet.header
        self.payload = packet.payload
        self.timestamp = timestamp
        self.formatDescription = formatDescription
    }
}

/// Extension to make RTP types Sendable with @preconcurrency
extension RTP.Header: @retroactive @unchecked Sendable {}
extension RTP.Packet: @retroactive @unchecked Sendable {}
extension RTP.Extension: @retroactive @unchecked Sendable {}