import Foundation
import SwiftPipesRTC
import AVFoundation

@main
struct CameraRTPExample {
    static func main() async {
        print("Camera to H.265 RTP Streaming Example")
        print("=====================================")
        
        // Get configuration from environment or use defaults
        let remoteHost = ProcessInfo.processInfo.environment["RTP_HOST"] ?? "127.0.0.1"
        let remotePort = UInt16(ProcessInfo.processInfo.environment["RTP_PORT"] ?? "5004") ?? 5004
        let bitRate = Int(ProcessInfo.processInfo.environment["BITRATE"] ?? "5000000") ?? 5_000_000
        
        print("Configuration:")
        print("  Remote Host: \(remoteHost)")
        print("  RTP Port: \(remotePort)")
        print("  RTCP Port: \(remotePort + 1)")
        print("  Bitrate: \(bitRate / 1_000_000) Mbps")
        print()
        
        // Check camera permission
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            print("Requesting camera permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                print("ERROR: Camera permission denied")
                exit(1)
            }
        } else if status != .authorized {
            print("ERROR: Camera permission not authorized")
            print("Please grant camera permission in System Settings > Privacy & Security > Camera")
            exit(1)
        }
        
        do {
            print("Creating pipeline...")
            
            // Create the pipeline
            let pipeline = try await createCameraToRTPPipeline(
                remoteHost: remoteHost,
                remotePort: remotePort,
                bitRate: bitRate,
                frameRate: 30.0
            )
            
            print()
            print("Pipeline is running!")
            print()
            print("To receive the stream, use one of these commands:")
            print("  ffplay -protocol_whitelist rtp,udp,file -i rtp://\(remoteHost):\(remotePort)")
            print("  gst-launch-1.0 udpsrc port=\(remotePort) ! 'application/x-rtp, media=video, encoding-name=H265' ! rtph265depay ! h265parse ! avdec_h265 ! videoconvert ! autovideosink")
            print()
            print("Press Ctrl+C to stop...")
            
            // Setup signal handler
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT)
            sigintSource.setEventHandler {
                print("\nShutting down...")
                Task {
                    await pipeline.stop()
                    print("Done.")
                    exit(0)
                }
            }
            sigintSource.resume()
            signal(SIGINT, SIG_IGN) // Ignore default handler
            
            // Keep running forever
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000_000) // 1000 seconds
            }
            
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
}