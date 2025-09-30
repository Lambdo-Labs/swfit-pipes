//
//  H265Decoder.swift
//  SwiftPipesRTC
//
//  H.265/HEVC decoder using VideoToolbox
//

import Foundation
import SwiftPipes
import VideoToolbox
import CoreMedia
import AVFoundation

/// Decoded video frame buffer
public struct DecodedVideoBuffer: BufferProtocol {
    public let imageBuffer: CVImageBuffer
    public let timestamp: CMTime
    public let duration: CMTime
    
    public init(imageBuffer: CVImageBuffer, timestamp: CMTime, duration: CMTime) {
        self.imageBuffer = imageBuffer
        self.timestamp = timestamp
        self.duration = duration
    }
}

// CVImageBuffer doesn't conform to Sendable but is thread-safe
extension DecodedVideoBuffer: @unchecked Sendable {}

/// H.265 decoder filter element using VideoToolbox
@available(iOS 13.0, macOS 10.15, *)
public actor H265DecoderFilter: PipelineFilterElement {
    public nonisolated let id: String
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: DecodedVideoBuffer.self, bufferingPolicy: .bufferingNewest(100))
    
    public var outputPads: [ElementOutputPad<AsyncStream<DecodedVideoBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "H265Decoder") {
        self.id = id
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        print("H265Decoder: Received frame with size \(buffer.data.count), keyframe: \(buffer.isKeyFrame), has format desc: \(buffer.formatDescription != nil)")
        
        // Skip frames that are too small to contain actual video data
        if buffer.data.count < 1000 {
            print("H265Decoder: Skipping small frame (\(buffer.data.count) bytes)")
            return
        }
        
        // Create format description if we have one from the encoder
        if formatDescription == nil {
            if let desc = buffer.formatDescription {
                formatDescription = desc
                print("H265Decoder: Using format description from buffer")
                
                // Debug format description extensions
                if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                    print("H265Decoder: Format has extensions")
                    if let atoms = extensions["SampleDescriptionExtensionAtoms"] as? [String: Any] {
                        if let hvcC = atoms["hvcC"] as? Data {
                            print("H265Decoder: Has hvcC atom with \(hvcC.count) bytes")
                            // Parse hvcC to see what parameter sets are included
                            if hvcC.count > 22 {
                                let configVersion = hvcC[0]
                                // let generalProfileSpace = (hvcC[1] >> 6) & 0x03
                                // let generalTierFlag = (hvcC[1] >> 5) & 0x01
                                let generalProfile = hvcC[1] & 0x1F
                                let generalLevelIDC = hvcC[12]
                                let lengthSizeMinusOne = hvcC[21] & 0x03
                                let numOfArrays = hvcC[22]
                                print("  Config version: \(configVersion)")
                                print("  Profile: \(generalProfile), Level: \(generalLevelIDC)")
                                print("  Length size minus one: \(lengthSizeMinusOne)")
                                print("  Number of parameter set arrays: \(numOfArrays)")
                            }
                        } else {
                            print("H265Decoder: Has hvcC atom but not as Data")
                        }
                    }
                } else {
                    print("H265Decoder: No extensions in format description!")
                }
                
                await createDecompressionSession()
            } else {
                // Try to create format description from the data
                print("H265Decoder: No format description in buffer, trying to create one")
                await createFormatDescription(from: buffer.data)
            }
        }
        
        guard let session = decompressionSession else {
            print("H265Decoder: No decompression session available")
            return
        }
        
        // Create sample buffer
        // Debug: Check the data format and find second NAL
        let preview = buffer.data.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("H265Decoder: First 48 bytes: \(preview)")
        
        // Show where second NAL unit should be
        if buffer.data.count > 40 {
            let secondNalPreview = buffer.data[36..<min(44, buffer.data.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
            print("H265Decoder: Bytes at offset 36 (after first NAL): \(secondNalPreview)")
        }
        
        // Debug: Parse AVCC format
        var offset = 0
        var nalUnits: [(type: String, size: Int)] = []
        while offset + 4 <= buffer.data.count {
            // Read length safely to avoid alignment issues
            let length = UInt32(buffer.data[offset]) << 24 |
                        UInt32(buffer.data[offset + 1]) << 16 |
                        UInt32(buffer.data[offset + 2]) << 8 |
                        UInt32(buffer.data[offset + 3])
            if offset + 4 + Int(length) <= buffer.data.count && length > 0 {
                let nalType = (buffer.data[offset + 4] >> 1) & 0x3F
                let nalTypeName = switch nalType {
                    case 32: "VPS"
                    case 33: "SPS" 
                    case 34: "PPS"
                    case 35: "AUD"
                    case 39: "PREFIX_SEI"
                    case 40: "SUFFIX_SEI"
                    case 19: "IDR_W_RADL"
                    case 20: "IDR_N_LP"
                    case 1: "TRAIL_N"
                    case 0: "TRAIL_R"
                    default: "Type_\(nalType)"
                }
                // Actually check the full byte - 0x4E >> 1 = 39, not VPS
                if offset + 5 < buffer.data.count {
                    print("  NAL header bytes: 0x\(String(format: "%02X", buffer.data[offset + 4])) 0x\(String(format: "%02X", buffer.data[offset + 5]))")
                }
                nalUnits.append((type: nalTypeName, size: Int(length)))
                offset += 4 + Int(length)
            } else {
                break
            }
        }
        print("H265Decoder: NAL units: \(nalUnits)")
        
        // Don't strip SEI - let VideoToolbox handle the full data
        let processedBuffer = buffer
        print("H265Decoder: Processing frame with \(nalUnits.count) NAL units")
        
        guard let sampleBuffer = createSampleBuffer(from: processedBuffer) else {
            print("H265Decoder: Failed to create sample buffer")
            return
        }
        
        // Create context for callback
        let context = DecoderContext(continuation: outputContinuation)
        
        // Decode the frame
        let flags: VTDecodeFrameFlags = []
        var flagsOut = VTDecodeInfoFlags()
        
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            infoFlagsOut: &flagsOut,
            outputHandler: { status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
                guard status == noErr,
                      let imageBuffer = imageBuffer else {
                    print("H265Decoder: Decode error: \(status)")
                    if status == -12909 {
                        print("  Error -12909: Invalid parameter - check format")
                    }
                    return
                }
                
                let decodedBuffer = DecodedVideoBuffer(
                    imageBuffer: imageBuffer,
                    timestamp: presentationTimeStamp,
                    duration: presentationDuration
                )
                
                context.continuation.yield(decodedBuffer)
                print("H265Decoder: Successfully decoded frame")
            }
        )
        
        if status != noErr {
            print("H265Decoder: Failed to decode frame: \(status)")
            if flagsOut.contains(.frameDropped) {
                print("  Frame was dropped")
            }
        }
    }
    
    private func createFormatDescription(from data: Data) async {
        // Try to extract parameter sets from the frame data
        print("H265Decoder: Attempting to create format description from frame data")
        
        // Parse AVCC format to find VPS/SPS/PPS
        var vps: Data?
        var sps: Data?
        var pps: Data?
        
        var offset = 0
        while offset + 4 <= data.count {
            // Read length safely to avoid alignment issues  
            let length = UInt32(data[offset]) << 24 |
                        UInt32(data[offset + 1]) << 16 |
                        UInt32(data[offset + 2]) << 8 |
                        UInt32(data[offset + 3])
            if offset + 4 + Int(length) <= data.count && length > 0 {
                let nalType = (data[offset + 4] >> 1) & 0x3F
                let nalData = data[(offset + 4)..<(offset + 4 + Int(length))]
                
                switch nalType {
                case 32, 39: // VPS
                    vps = nalData
                    print("  Found VPS: \(nalData.count) bytes")
                case 33: // SPS
                    sps = nalData
                    print("  Found SPS: \(nalData.count) bytes")
                case 34: // PPS
                    pps = nalData
                    print("  Found PPS: \(nalData.count) bytes")
                default:
                    break
                }
                
                offset += 4 + Int(length)
            } else {
                break
            }
        }
        
        // If we found parameter sets, try to create format description
        if let vps = vps, let sps = sps, let pps = pps {
            print("H265Decoder: Found all parameter sets, creating format description")
            
            let parameterSets: [Data] = [vps, sps, pps]
            let parameterSetSizes = parameterSets.map { $0.count }
            
            var formatDesc: CMFormatDescription?
            let status = vps.withUnsafeBytes { vpsBytes in
                sps.withUnsafeBytes { spsBytes in
                    pps.withUnsafeBytes { ppsBytes in
                        let parameterSetPointers: [UnsafePointer<UInt8>] = [
                            vpsBytes.bindMemory(to: UInt8.self).baseAddress!,
                            spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                            ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                        ]
                        
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
            
            if status == noErr, let desc = formatDesc {
                formatDescription = desc
                print("H265Decoder: Successfully created format description from parameter sets")
                await createDecompressionSession()
            } else {
                print("H265Decoder: Failed to create format description: \(status)")
            }
        } else {
            print("H265Decoder: Missing parameter sets - VPS: \(vps != nil), SPS: \(sps != nil), PPS: \(pps != nil)")
        }
    }
    
    private func createDecompressionSession() async {
        guard let formatDesc = formatDescription else { return }
        
        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: false
        ]
        
        // Create output image buffer attributes
        let imageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_32BGRA
            ],
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080
        ]
        
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        
        if status == noErr, let session = session {
            self.decompressionSession = session
            print("H265Decoder: Created decompression session")
        } else {
            print("H265Decoder: Failed to create decompression session: \(status)")
            if status == -12910 {
                print("  Error -12910: Format not supported")
            }
        }
    }
    
    private func createSampleBuffer(from buffer: EncodedH265Buffer) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription else { 
            print("H265Decoder: No format description available")
            return nil 
        }
        
        // Debug format description
        let mediaType = CMFormatDescriptionGetMediaType(formatDesc)
        let subType = CMFormatDescriptionGetMediaSubType(formatDesc)
        print("H265Decoder: Format desc - media type: \(mediaType), subtype: \(subType) (HEVC: \(kCMVideoCodecType_HEVC))")
        
        var blockBuffer: CMBlockBuffer?
        
        // Create block buffer with a copy of the data
        var status = buffer.data.withUnsafeBytes { dataPtr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: buffer.data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: buffer.data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        guard status == noErr, let blockBuffer = blockBuffer else {
            print("H265Decoder: Failed to create empty block buffer: \(status)")
            return nil
        }
        
        // Copy data into block buffer
        status = buffer.data.withUnsafeBytes { dataPtr in
            CMBlockBufferReplaceDataBytes(
                with: dataPtr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: buffer.data.count
            )
        }
        
        guard status == noErr else {
            print("H265Decoder: Failed to create empty block buffer: \(status)")
            return nil
        }
        
        print("H265Decoder: Created block buffer with \(buffer.data.count) bytes")
        
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [buffer.data.count]
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(
                duration: buffer.duration.isValid ? buffer.duration : CMTime(value: 1, timescale: 30),
                presentationTimeStamp: buffer.timestamp,
                decodeTimeStamp: buffer.timestamp
            )],
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        if status != noErr {
            print("H265Decoder: Failed to create sample buffer: \(status)")
            switch status {
            case -12731: print("  Error -12731: Invalid size")
            case -12710: print("  Error -12710: Invalid parameter") 
            case -12737: print("  Error -12737: Invalid sample data")
            default: break
            }
            return nil
        }
        
        return sampleBuffer
    }
    
    public func finish() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
}

// Helper class to pass context through callback
private final class DecoderContext: @unchecked Sendable {
    let continuation: AsyncStream<DecodedVideoBuffer>.Continuation
    
    init(continuation: AsyncStream<DecodedVideoBuffer>.Continuation) {
        self.continuation = continuation
    }
}