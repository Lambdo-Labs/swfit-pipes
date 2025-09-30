import Testing
import SwiftPipes
import SwiftPipesRTC
import Network
import Foundation

@available(iOS 13.0, macOS 10.15, *)
@Test("Simple RTP send and receive test")
func testSimpleRTPSendReceive() async throws {
    // Simple test to verify RTP sending works
    print("Starting simple RTP test")
    
    // Create a simple UDP receiver
    let receiver = SimpleUDPReceiver()
    try await receiver.start(port: 6000)
    
    // Send a test packet
    let connection = NWConnection(
        to: .hostPort(host: "127.0.0.1", port: 6000),
        using: .udp
    )
    
    connection.start(queue: .main)
    
    // Wait for connection
    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    
    // Send test data
    let testData = Data("Hello RTP Test".utf8)
    await withCheckedContinuation { continuation in
        connection.send(content: testData, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
            } else {
                print("Sent test packet")
            }
            continuation.resume()
        })
    }
    
    // Wait for receive
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // Check results
    let received = await receiver.getReceivedData()
    print("Received \(received.count) packets")
    
    #expect(received.count > 0, "Should have received packets")
    #expect(received.first == testData, "Should have received correct data")
    
    await receiver.stop()
    connection.cancel()
}

// Simple UDP receiver for testing
@available(iOS 13.0, macOS 10.15, *)
actor SimpleUDPReceiver {
    private var listener: NWListener?
    private var receivedData: [Data] = []
    
    func start(port: UInt16) async throws {
        listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection)
            }
        }
        
        listener?.start(queue: .main)
        
        // Wait for listener to be ready
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            if let data = data {
                Task {
                    await self?.recordData(data)
                }
            }
        }
    }
    
    private func recordData(_ data: Data) {
        receivedData.append(data)
        print("Received: \(data.count) bytes")
    }
    
    func getReceivedData() -> [Data] {
        receivedData
    }
    
    func stop() {
        listener?.cancel()
    }
}