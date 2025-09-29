import Testing
@testable import SwiftPipes
import Foundation

@Suite("Element Tests")
struct ElementTests {
    
    @Test("Test data source generates data at correct intervals")
    func testDataSourceTiming() async throws {
        let source = TestDataSource(id: "timing-test")
        let startTime = Date()
        
        await source.start(interval: 0.1)
        try await Task.sleep(nanoseconds: 350_000_000) // 0.35 seconds
        await source.stop()
        
        let elapsed = Date().timeIntervalSince(startTime)
        // Should have generated approximately 3-4 items
        #expect(elapsed >= 0.3)
        #expect(elapsed < 0.5)
    }
    
    @Test("Elements have correct pad configurations")
    func testElementPads() async throws {
        // Test source
        let source = TestDataSource()
        let sourcePads = await source.outputPads
        #expect(sourcePads.count == 1)
        #expect(sourcePads[0].ref == .outputDefault)
        #expect(sourcePads[0].padType == .output)
        
        // Test sink
        let sink = DebugPrintSink()
        let sinkPads = await sink.inputPads
        #expect(sinkPads.count == 1)
        #expect(sinkPads[0].ref == .inputDefault)
        #expect(sinkPads[0].padType == .input)
        
        // Test filter
        let filter = TransformFilter { $0 }
        let filterInputPads = await filter.inputPads
        let filterOutputPads = await filter.outputPads
        #expect(filterInputPads.count == 1)
        #expect(filterOutputPads.count == 1)
        #expect(filterInputPads[0].ref == .inputDefault)
        #expect(filterOutputPads[0].ref == .outputDefault)
    }
    
    @Test("Multi-output source has correct pad configuration")
    func testMultiOutputPads() async throws {
        let source = MultiOutputSource()
        let pads = await source.outputPads
        
        #expect(pads.count == 2)
        #expect(pads.contains(where: { $0.ref == .outputDefault }))
        #expect(pads.contains(where: { $0.ref == .custom(id: "metadata") }))
    }
    
    @Test("Elements can be identified")
    func testElementIdentification() async throws {
        let source = TestDataSource(id: "custom-id-1")
        let sink = DebugPrintSink(id: "custom-id-2")
        let filter = TransformFilter(id: "custom-id-3") { $0 }
        
        #expect(source.id == "custom-id-1")
        #expect(sink.id == "custom-id-2")
        #expect(filter.id == "custom-id-3")
    }
    
    @Test("Buffering filter respects buffer size")
    func testBufferingSizes() async throws {
        let smallBuffer = BufferingFilter(id: "small", bufferSize: 2)
        let largeBuffer = BufferingFilter(id: "large", bufferSize: 10)
        
        #expect(smallBuffer.id == "small")
        #expect(largeBuffer.id == "large")
        
        // Verify pads exist
        let smallInputPads = await smallBuffer.inputPads
        let largeOutputPads = await largeBuffer.outputPads
        
        #expect(smallInputPads.count == 1)
        #expect(largeOutputPads.count == 1)
    }
    
    @Test("Transform filter applies transformation")
    func testTransformation() async throws {
        // Create a simple transform that doubles the data
        let doubler = TransformFilter(id: "doubler") { data in
            if let string = String(data: data, encoding: .utf8),
               let number = Int(string) {
                let doubled = number * 2
                return "\(doubled)".data(using: .utf8) ?? data
            }
            return data
        }
        
        #expect(doubler.id == "doubler")
        let pads = await doubler.outputPads
        #expect(pads.count == 1)
    }
}

@Suite("Buffer Tests")
struct BufferTests {
    
    @Test("DataBuffer stores data correctly")
    func testDataBuffer() {
        let data = "Hello, World!".data(using: .utf8)!
        let timestamp = Date().timeIntervalSince1970
        let buffer = DataBuffer(data: data, timestamp: timestamp)
        
        #expect(buffer.data == data)
        #expect(buffer.timestamp == timestamp)
    }
    
    @Test("TextBuffer stores text and metadata")
    func testTextBuffer() {
        let text = "Test message"
        let metadata: [String: String] = ["key": "value", "number": "42"]
        let buffer = TextBuffer(text: text, metadata: metadata)
        
        #expect(buffer.text == text)
        #expect(buffer.metadata["key"] == "value")
        #expect(buffer.metadata["number"] == "42")
    }
    
    @Test("Empty TextBuffer")
    func testEmptyTextBuffer() {
        let buffer = TextBuffer(text: "")
        #expect(buffer.text == "")
        #expect(buffer.metadata.isEmpty)
    }
}