import Foundation
import SwiftPipesRTC
import SwiftPipes
import AVFoundation
import VideoToolbox
import CoreMedia

@main
struct SimpleH265Test {
    static func main() async {
        print("Simple H.265 Test: Camera → Encode → Decode")
        print("==========================================")
        
        do {
            print("Checking camera permission...")
            // Check camera permission
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            print("Camera permission status: \(status.rawValue)")
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted {
                    print("ERROR: Camera permission denied")
                    return
                }
            } else if status != .authorized {
                print("ERROR: Camera permission not authorized")
                return
            }
            
            // Create test components
            let test = SimpleTest()
            try await test.run()
            
        } catch {
            print("ERROR: \(error)")
        }
    }
}

actor SimpleTest {
    var encodedFrames: [EncodedH265Buffer] = []
    var decodedFrames: [DecodedVideoBuffer] = []
    
    func run() async throws {
        print("\n1. Setting up pipeline for encoding...")
        
        let encodePipeline = SimplePipeline()
        
        // First pipeline: Camera → Encoder → Collect
        let cameraSource = CameraCaptureSource(id: "camera")
        let h265Encoder = H265EncoderFilter(
            id: "h265Encoder",
            bitRate: 5_000_000,
            frameRate: 30.0
        )
        let encodedCollector = EncodedFrameCollector(id: "encodedCollector", test: self)
        
        await encodePipeline.buildGroups([
            (id: "encode", children: [
                .source(child: cameraSource),
                .filter(child: h265Encoder),
                .sink(child: encodedCollector)
            ])
        ])
        
        // Start camera
        print("2. Starting camera capture...")
        try await cameraSource.start()
        await encodePipeline.start()
        
        // Capture for 2 seconds
        print("3. Capturing video for 2 seconds...")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Stop encoding pipeline
        print("4. Stopping capture...")
        await cameraSource.finish()
        await h265Encoder.finish()
        await encodePipeline.stop()
        
        print("\n5. Simulating network transmission...")
        print("Encoded \(encodedFrames.count) frames")
        
        // Simulate network transmission by encoding to JSON and back
        var transmittedFrames: [EncodedH265Buffer] = []
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for (index, frame) in encodedFrames.enumerated() {
            do {
                // Encode to Data (what you'd send over network)
                let jsonData = try encoder.encode(frame)
                print("Frame \(index): \(frame.data.count) bytes → JSON: \(jsonData.count) bytes")
                
                // Decode from Data (what you'd receive)
                let decodedFrame = try decoder.decode(EncodedH265Buffer.self, from: jsonData)
                transmittedFrames.append(decodedFrame)
            } catch {
                print("Failed to encode/decode frame \(index): \(error)")
            }
        }
        
        print("\n6. Setting up decode pipeline...")
        // Create decode pipeline with transmitted frames
        let decodePipeline = SimplePipeline()
        let frameSource = EncodedFrameSource(id: "frameSource", frames: transmittedFrames)
        let h265Decoder = H265DecoderFilter(id: "h265Decoder")
        let decodedCollector = DecodedFrameCollector(id: "decodedCollector", test: self)
        
        await decodePipeline.buildGroups([
            (id: "decode", children: [
                .source(child: frameSource),
                .filter(child: h265Decoder),
                .sink(child: decodedCollector)
            ])
        ])
        
        print("7. Decoding transmitted frames...")
        await decodePipeline.start()
        await frameSource.start()
        
        // Give time to decode
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        await frameSource.finish()
        await h265Decoder.finish()
        await decodePipeline.stop()
        
        // Analyze results
        print("\n=== RESULTS ===")
        print("Decoded frames: \(decodedFrames.count)")
        
        if !decodedFrames.isEmpty {
            print("\nDecoded frame details:")
            if let firstDecoded = decodedFrames.first {
                let width = CVPixelBufferGetWidth(firstDecoded.imageBuffer)
                let height = CVPixelBufferGetHeight(firstDecoded.imageBuffer)
                print("  - Resolution: \(width)x\(height)")
            }
        }
        
        print("\n=== TEST COMPLETE ===")
        
        let success = decodedFrames.count > 0
        
        if success {
            print("✅ SIMPLE H.265 TEST PASSED")
            print("   Successfully encoded and decoded \(decodedFrames.count) frames")
        } else {
            print("❌ TEST FAILED")
            print("   - No frames decoded")
        }
    }
    
    func addEncodedFrame(_ frame: EncodedH265Buffer) {
        encodedFrames.append(frame)
    }
    
    func addDecodedFrame(_ frame: DecodedVideoBuffer) {
        decodedFrames.append(frame)
        print("Successfully decoded frame #\(decodedFrames.count)")
    }
}

// Source that emits pre-encoded frames (simulating network receive)
actor EncodedFrameSource: PipelineSourceElement {
    nonisolated let id: String
    private let frames: [EncodedH265Buffer]
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: EncodedH265Buffer.self, bufferingPolicy: .bufferingOldest(100))
    
    var outputPads: [ElementOutputPad<AsyncStream<EncodedH265Buffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    init(id: String, frames: [EncodedH265Buffer]) {
        self.id = id
        self.frames = frames
    }
    
    func start() async {
        // Emit all frames with proper timing
        for (index, frame) in frames.enumerated() {
            outputContinuation.yield(frame)
            // Small delay between frames
            if index < frames.count - 1 {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps
            }
        }
    }
    
    func finish() async {
        outputContinuation.finish()
    }
    
    func onCancel(task: PipeTask) {}
}

// Collector elements
actor EncodedFrameCollector: PipelineSinkElement {
    nonisolated let id: String
    let test: SimpleTest
    
    var inputPads: [ElementInputPad<EncodedH265Buffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, test: SimpleTest) {
        self.id = id
        self.test = test
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: EncodedH265Buffer) async {
        await test.addEncodedFrame(buffer)
    }
    
    func onCancel(task: PipeTask) {}
}

actor DecodedFrameCollector: PipelineSinkElement {
    nonisolated let id: String
    let test: SimpleTest
    
    var inputPads: [ElementInputPad<DecodedVideoBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String, test: SimpleTest) {
        self.id = id
        self.test = test
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: DecodedVideoBuffer) async {
        await test.addDecodedFrame(buffer)
    }
    
    func onCancel(task: PipeTask) {}
}