//
//  RTPPacketizerV2.swift
//  SwiftPipesRTC
//
//  Updated pipeline elements for RTP packetization using swift-rtc API
//

import Foundation
import SwiftPipes
import RTC
@preconcurrency import RTP
import NIOCore

/// Filter element that packetizes media data into RTP packets
public actor RTPPacketizerFilterV2: PipelineFilterElement {
    public nonisolated let id: String
    private let ssrc: UInt32
    private let payloadType: UInt8
    private let clockRate: UInt32
    private var sequenceNumber: UInt16 = 0
    private var allocator = ByteBufferAllocator()
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: RTPPacketBuffer.self)
    
    public var outputPads: [ElementOutputPad<AsyncStream<RTPPacketBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<MediaBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(
        id: String = "RTPPacketizerV2",
        ssrc: UInt32,
        payloadType: UInt8,
        clockRate: UInt32
    ) {
        self.id = id
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.clockRate = clockRate
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: MediaBuffer) async {
        // Create ByteBuffer from Data
        var payloadBuffer = allocator.buffer(capacity: buffer.data.count)
        payloadBuffer.writeBytes(buffer.data)
        
        // Create RTP header
        let header = RTP.Header(
            version: 2,
            padding: false,
            ext: false,
            marker: buffer.marker,
            payloadType: payloadType,
            sequenceNumber: nextSequenceNumber(),
            timestamp: buffer.timestamp,
            ssrc: ssrc,
            csrcs: [],
            extensionProfile: 0,
            extensions: []
        )
        
        let packet = RTP.Packet(header: header, payload: payloadBuffer)
        let rtpBuffer = RTPPacketBuffer(packet: packet)
        outputContinuation.yield(rtpBuffer)
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

/// Filter element that depacketizes RTP packets into media data
public actor RTPDepacketizerFilterV2: PipelineFilterElement {
    public nonisolated let id: String
    private let mediaType: MediaBuffer.MediaType
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: MediaBuffer.self)
    
    public var outputPads: [ElementOutputPad<AsyncStream<MediaBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<RTPPacketBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "RTPDepacketizerV2", mediaType: MediaBuffer.MediaType) {
        self.id = id
        self.mediaType = mediaType
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: RTPPacketBuffer) async {
        // Convert ByteBuffer to Data
        let data = Data(buffer.payload.readableBytesView)
        
        let mediaBuffer = MediaBuffer(
            data: data,
            mediaType: mediaType,
            timestamp: buffer.header.timestamp,
            sequenceNumber: buffer.header.sequenceNumber,
            ssrc: buffer.header.ssrc,
            payloadType: buffer.header.payloadType,
            marker: buffer.header.marker
        )
        
        outputContinuation.yield(mediaBuffer)
    }
    
    public func finish() {
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
}