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

// Helper to extract parameter sets from CMFormatDescription
struct H265ParameterSets: Codable {
    let vps: Data
    let sps: Data
    let pps: Data
    
    init?(from formatDescription: CMFormatDescription) {
        // Get hvcC data from format description
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
              let atoms = extensions["SampleDescriptionExtensionAtoms"] as? [String: Any],
              let hvcC = atoms["hvcC"] as? Data else {
            return nil
        }
        
        // Parse hvcC to extract parameter sets
        // The hvcC format is complex, but we can extract the parameter sets
        guard hvcC.count > 22 else { return nil }
        
        var vps: Data?
        var sps: Data?
        var pps: Data?
        
        // Skip header (23 bytes) and read arrays
        var offset = 23
        let numArrays = Int(hvcC[22])
        
        for _ in 0..<numArrays {
            guard offset + 3 <= hvcC.count else { break }
            
            let arrayCompleteness = hvcC[offset]
            let nalUnitType = hvcC[offset] & 0x3F
            let numNalus = Int(hvcC[offset + 1]) << 8 | Int(hvcC[offset + 2])
            offset += 3
            
            for _ in 0..<numNalus {
                guard offset + 2 <= hvcC.count else { break }
                let nalUnitLength = Int(hvcC[offset]) << 8 | Int(hvcC[offset + 1])
                offset += 2
                
                guard offset + nalUnitLength <= hvcC.count else { break }
                let nalUnitData = hvcC[offset..<(offset + nalUnitLength)]
                
                switch nalUnitType {
                case 32: // VPS
                    vps = nalUnitData
                case 33: // SPS
                    sps = nalUnitData
                case 34: // PPS
                    pps = nalUnitData
                default:
                    break
                }
                
                offset += nalUnitLength
            }
        }
        
        guard let vpsData = vps, let spsData = sps, let ppsData = pps else {
            return nil
        }
        
        self.vps = vpsData
        self.sps = spsData
        self.pps = ppsData
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
        case parameterSets
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
        
        // Decode parameter sets and recreate format description if present
        if let parameterSets = try container.decodeIfPresent(H265ParameterSets.self, forKey: .parameterSets) {
            var formatDesc: CMFormatDescription?
            let status = parameterSets.vps.withUnsafeBytes { vpsBytes in
                parameterSets.sps.withUnsafeBytes { spsBytes in
                    parameterSets.pps.withUnsafeBytes { ppsBytes in
                        let parameterSetPointers: [UnsafePointer<UInt8>] = [
                            vpsBytes.bindMemory(to: UInt8.self).baseAddress!,
                            spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                            ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                        ]
                        let parameterSetSizes = [parameterSets.vps.count, parameterSets.sps.count, parameterSets.pps.count]
                        
                        return parameterSetPointers.withUnsafeBufferPointer { pointers in
                            parameterSetSizes.withUnsafeBufferPointer { sizes in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: pointers.baseAddress!,
                                    parameterSetSizes: sizes.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &formatDesc
                                )
                            }
                        }
                    }
                }
            }
            
            formatDescription = (status == noErr) ? formatDesc : nil
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
        
        // Extract and encode parameter sets from format description
        if let formatDesc = formatDescription,
           let parameterSets = H265ParameterSets(from: formatDesc) {
            try container.encode(parameterSets, forKey: .parameterSets)
        }
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
        
        var encoderSpecification: [String: Any] = [:]
        if #available(iOS 17.4, macOS 14.4, tvOS 17.4, *) {
            encoderSpecification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = false
        }
        
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