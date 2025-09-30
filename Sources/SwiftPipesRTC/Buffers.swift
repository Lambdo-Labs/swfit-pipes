//
//  Buffers.swift
//  SwiftPipesRTC
//
//  Buffer types for RTC pipeline elements
//

import Foundation
import SwiftPipes

/// Buffer containing raw media data with RTP metadata
public struct MediaBuffer: BufferProtocol {
    public let data: Data
    public let mediaType: MediaType
    public let timestamp: UInt32 // RTP timestamp
    public let sequenceNumber: UInt16
    public let ssrc: UInt32
    public let payloadType: UInt8
    public let marker: Bool
    
    public enum MediaType: Sendable {
        case audio
        case video
    }
    
    public init(
        data: Data,
        mediaType: MediaType,
        timestamp: UInt32,
        sequenceNumber: UInt16,
        ssrc: UInt32,
        payloadType: UInt8,
        marker: Bool = false
    ) {
        self.data = data
        self.mediaType = mediaType
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.marker = marker
    }
}