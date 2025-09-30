//
//  H265Encoder.swift
//  SwiftPipesRTC
//
//  H.265/HEVC encoder using VideoToolbox
//

import Foundation
import SwiftPipes
import VideoToolbox
import CoreMedia

/// Buffer containing encoded H.265 data
public struct EncodedH265Buffer: BufferProtocol {
    public let data: Data
    public let timestamp: CMTime
    public let duration: CMTime
    public let isKeyFrame: Bool
    public let formatDescription: CMFormatDescription?
    
    public init(
        data: Data,
        timestamp: CMTime,
        duration: CMTime,
        isKeyFrame: Bool,
        formatDescription: CMFormatDescription? = nil
    ) {
        self.data = data
        self.timestamp = timestamp
        self.duration = duration
        self.isKeyFrame = isKeyFrame
        self.formatDescription = formatDescription
    }
}

// MARK: - Codable support for network transmission
extension EncodedH265Buffer: Codable {
    enum CodingKeys: String, CodingKey {
        case data
        case timestampSeconds
        case timestampTimescale
        case durationSeconds
        case durationTimescale
        case isKeyFrame
        case formatDescriptionData
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(Data.self, forKey: .data)
        
        // Decode CMTime
        let timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        let timestampTimescale = try container.decode(Int32.self, forKey: .timestampTimescale)
        timestamp = CMTime(seconds: timestampSeconds, preferredTimescale: timestampTimescale)
        
        let durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        let durationTimescale = try container.decode(Int32.self, forKey: .durationTimescale)
        duration = CMTime(seconds: durationSeconds, preferredTimescale: durationTimescale)
        
        isKeyFrame = try container.decode(Bool.self, forKey: .isKeyFrame)
        
        // Decode format description if present
        if let formatData = try container.decodeIfPresent(Data.self, forKey: .formatDescriptionData) {
            // For H.265, we need to extract parameter sets from the data
            // This is a simplified version - in production you'd properly parse the format
            formatDescription = nil // Will be recreated on the receiving side
        } else {
            formatDescription = nil
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        
        // Encode CMTime
        try container.encode(timestamp.seconds, forKey: .timestampSeconds)
        try container.encode(timestamp.timescale, forKey: .timestampTimescale)
        try container.encode(duration.seconds, forKey: .durationSeconds)
        try container.encode(duration.timescale, forKey: .durationTimescale)
        
        try container.encode(isKeyFrame, forKey: .isKeyFrame)
        
        // For format description, we could serialize it but it's complex
        // For now, we'll let the decoder recreate it from the first keyframe
        // In a real implementation, you'd extract and encode the parameter sets
    }
}

/// H.265 encoder filter element using VideoToolbox
@available(iOS 13.0, macOS 10.15, *)
public actor H265EncoderFilter: PipelineFilterElement {
    public nonisolated let id: String
    private var compressionSession: VTCompressionSession?
    private var formatDescription: CMFormatDescription?
    private let bitRate: Int
    private let frameRate: Double
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: EncodedH265Buffer.self)
    
    public var outputPads: [ElementOutputPad<AsyncStream<EncodedH265Buffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<VideoFrameBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(
        id: String = "H265Encoder",
        bitRate: Int = 10_000_000, // 10 Mbps
        frameRate: Double = 30.0
    ) {
        self.id = id
        self.bitRate = bitRate
        self.frameRate = frameRate
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: VideoFrameBuffer) async {
        guard let imageBuffer = buffer.sampleBuffer.imageBuffer else { return }
        
        // Create compression session if needed
        if compressionSession == nil {
            await createCompressionSession(for: imageBuffer)
        }
        
        guard let session = compressionSession else { return }
        
        // Encode the frame
        let presentationTimeStamp = buffer.sampleBuffer.presentationTimeStamp
        let duration = buffer.sampleBuffer.duration
        
        // Create callback context
        let context = EncoderContext(
            continuation: outputContinuation,
            formatDescription: formatDescription
        )
        
        // Encode frame
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { status, infoFlags, sampleBuffer in
                guard status == noErr, let sampleBuffer = sampleBuffer else {
                    print("H265Encoder: Encode error: \(status)")
                    return
                }
                
                
                // Extract encoded data
                guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    dataBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )
                
                guard status == noErr, let dataPointer = dataPointer else { return }
                
                // The data from VideoToolbox is in AVCC format (length-prefixed)
                // For RTP, we need to extract individual NAL units
                let data = Data(bytes: dataPointer, count: totalLength)
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
                let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
                
                // Get format description
                let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
                if isKeyFrame && formatDesc != nil {
                    context.formatDescription = formatDesc
                }
                
                // Use the stored format description for all frames
                let currentFormatDesc = context.formatDescription ?? formatDesc
                
                let encodedBuffer = EncodedH265Buffer(
                    data: data,
                    timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                    duration: CMSampleBufferGetDuration(sampleBuffer),
                    isKeyFrame: isKeyFrame,
                    formatDescription: currentFormatDesc
                )
                
                context.continuation.yield(encodedBuffer)
            }
        )
        
        if status != noErr {
            print("H265Encoder: Failed to encode frame: \(status)")
        }
    }
    
    private func createCompressionSession(for imageBuffer: CVImageBuffer) async {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        let encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: false
        ]
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("H265Encoder: Failed to create compression session: \(status)")
            return
        }
        
        // Configure session
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main_AutoLevel
        )
        
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitRate)
        )
        
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: frameRate)
        )
        
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: Int(frameRate * 2)) // Keyframe every 2 seconds
        )
        
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 2.0) // 2 seconds between keyframes
        )
        
        // Set data rate limits
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bitRate * 2, 1] as CFArray
        )
        
        // Allow frame reordering for better compression
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanTrue
        )
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        
        self.compressionSession = session
    }
    
    func setFormatDescription(_ desc: CMFormatDescription) {
        self.formatDescription = desc
    }
    
    public func finish() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
}

// Helper class to pass context through C callback
private final class EncoderContext: @unchecked Sendable {
    let continuation: AsyncStream<EncodedH265Buffer>.Continuation
    var formatDescription: CMFormatDescription?
    
    init(continuation: AsyncStream<EncodedH265Buffer>.Continuation, formatDescription: CMFormatDescription?) {
        self.continuation = continuation
        self.formatDescription = formatDescription
    }
}