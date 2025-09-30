//
//  CameraCapture.swift
//  SwiftPipesRTC
//
//  Camera capture source element for iOS/macOS
//

import Foundation
import SwiftPipes
@preconcurrency import AVFoundation
import CoreMedia

/// Buffer type for video frames from camera
public struct VideoFrameBuffer: BufferProtocol {
    public let sampleBuffer: CMSampleBuffer
    public let timestamp: TimeInterval
    
    public init(sampleBuffer: CMSampleBuffer, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.sampleBuffer = sampleBuffer
        self.timestamp = timestamp
    }
}

/// Camera capture source element
@available(iOS 13.0, macOS 10.15, *)
public actor CameraCaptureSource: PipelineSourceElement {
    public nonisolated let id: String
    private let session = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "camera.capture.queue")
    private var delegate: CaptureDelegate?
    
    private var (stream, continuation) = AsyncStream.makeStream(of: VideoFrameBuffer.self)
    
    public var outputPads: [ElementOutputPad<AsyncStream<VideoFrameBuffer>>] {
        [.init(ref: .outputDefault, stream: stream)]
    }
    
    public init(id: String = "CameraCapture") {
        self.id = id
    }
    
    public func start() async throws {
        // Configure session
        session.beginConfiguration()
        
        // Add video input
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            throw CameraCaptureError.noVideoDevice
        }
        
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        
        guard session.canAddInput(videoInput) else {
            throw CameraCaptureError.cannotAddInput
        }
        
        session.addInput(videoInput)
        
        // Configure video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        guard session.canAddOutput(videoOutput) else {
            throw CameraCaptureError.cannotAddOutput
        }
        
        session.addOutput(videoOutput)
        self.videoOutput = videoOutput
        
        // Set up delegate
        let delegate = CaptureDelegate(continuation: continuation)
        self.delegate = delegate
        videoOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        
        session.commitConfiguration()
        
        // Start capture
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak session] in
                session?.startRunning()
                continuation.resume()
            }
        }
    }
    
    public func stop() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak session] in
                session?.stopRunning()
                continuation.resume()
            }
        }
        
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        delegate = nil
    }
    
    public func finish() async {
        await stop()
        continuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        Task {
            await stop()
        }
    }
}

// Camera capture delegate
private class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let continuation: AsyncStream<VideoFrameBuffer>.Continuation
    
    init(continuation: AsyncStream<VideoFrameBuffer>.Continuation) {
        self.continuation = continuation
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let buffer = VideoFrameBuffer(sampleBuffer: sampleBuffer)
        continuation.yield(buffer)
        
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Handle dropped frames if needed
    }
}

enum CameraCaptureError: Error {
    case noVideoDevice
    case cannotAddInput
    case cannotAddOutput
}

// Make CMSampleBuffer Sendable (it's thread-safe in practice)
extension CMSampleBuffer: @retroactive @unchecked Sendable {}