import Testing
@testable import SwiftPipes
import Foundation

@Suite("Data Flow Tests")
struct DataFlowTests {
    
    // Helper sink that collects received buffers
    actor CollectorSink: PipelineSinkElement {
        nonisolated let id: String
        private(set) var collectedData: [DataBuffer] = []
        
        var inputPads: [ElementInputPad<DataBuffer>] {
            [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
        }
        
        init(id: String = "CollectorSink") {
            self.id = id
        }
        
        @Sendable
        private func handleBuffer(context: any Pipeline, buffer: DataBuffer) async {
            collectedData.append(buffer)
        }
        
        func getCollectedCount() async -> Int {
            collectedData.count
        }
        
        func getCollectedData() async -> [DataBuffer] {
            collectedData
        }
    }
    
    @Test("Data flows from source to sink")
    func testBasicDataFlow() async throws {
        let pipeline = SimplePipeline()
        let source = TestDataSource(id: "flow-source")
        let collector = CollectorSink(id: "flow-collector")
        
        await pipeline.buildLinear([
            .source(child: source),
            .sink(child: collector)
        ])
        
        // Start source and let it generate some data
        await source.start(interval: 0.01)
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        await source.finish()
        
        // Give pipeline time to process
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let count = await collector.getCollectedCount()
        #expect(count > 0)
        #expect(count <= 12) // Should be around 10 items
    }
    
    @Test("Transform filter modifies data correctly")
    func testTransformFilter() async throws {
        let pipeline = SimplePipeline()
        let source = TestDataSource(id: "transform-source")
        let filter = TransformFilter(id: "uppercase-filter") { data in
            if let string = String(data: data, encoding: .utf8) {
                return string.uppercased().data(using: .utf8) ?? data
            }
            return data
        }
        let collector = CollectorSink(id: "transform-collector")
        
        await pipeline.buildLinear([
            .source(child: source),
            .filter(child: filter),
            .sink(child: collector)
        ])
        
        // Generate one item
        await source.start(interval: 1.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        await source.finish()
        
        // Give pipeline time to process
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let collected = await collector.getCollectedData()
        #expect(collected.count >= 1)
        
        if let first = collected.first,
           let text = String(data: first.data, encoding: .utf8) {
            #expect(text.contains("TEST DATA"))
        }
    }
    
    @Test("Buffering filter accumulates data")
    func testBufferingFilter() async throws {
        let pipeline = SimplePipeline()
        let source = TestDataSource(id: "buffer-source")
        let bufferFilter = BufferingFilter(id: "accumulator", bufferSize: 3)
        let collector = CollectorSink(id: "buffer-collector")
        
        await pipeline.buildLinear([
            .source(child: source),
            .filter(child: bufferFilter),
            .sink(child: collector)
        ])
        
        // Generate exactly 6 items
        await source.start(interval: 0.01)
        try await Task.sleep(nanoseconds: 70_000_000) // 0.07 seconds
        await source.stop()
        await bufferFilter.finish()
        
        // Give pipeline time to process
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let collected = await collector.getCollectedData()
        // Should have ~2 buffers (6 items / 3 buffer size)
        #expect(collected.count >= 1)
        #expect(collected.count <= 3)
        
        if let first = collected.first,
           let text = String(data: first.data, encoding: .utf8) {
            // Should contain multiple test data entries
            #expect(text.contains("Test data"))
            #expect(text.contains(","))
        }
    }
    
    @Test("Multi-output source delivers to correct sinks")
    func testMultiOutput() async throws {
        let pipeline = SimplePipeline()
        let multiSource = MultiOutputSource(id: "multi")
        let mainCollector = TextCollectorSink(id: "main-collector")
        let metaCollector = TextCollectorSink(id: "meta-collector")
        
        await pipeline.buildGroups([
            (id: "main", children: [
                .source(child: multiSource, viaOut: .outputDefault),
                .sink(child: mainCollector)
            ]),
            (id: "metadata", children: [
                .sourceRef(id: "multi", viaOut: .custom(id: "metadata")),
                .sink(child: metaCollector)
            ])
        ])
        
        await multiSource.start()
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds to get more items
        await multiSource.finish()
        
        // Give pipeline time to process
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let mainCount = await mainCollector.getCollectedCount()
        let metaCount = await metaCollector.getCollectedCount()
        
        #expect(mainCount > 0)
        #expect(metaCount > 0)
        // Metadata should have fewer items (sent every 3rd iteration)
        #expect(metaCount <= mainCount)
        // Approximately 1 metadata for every 3 main items
        #expect(Double(metaCount) <= Double(mainCount) / 2.0)
    }
}

// Helper sink for TextBuffer
actor TextCollectorSink: PipelineSinkElement {
    nonisolated let id: String
    private(set) var collectedTexts: [String] = []
    
    var inputPads: [ElementInputPad<TextBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    init(id: String = "TextCollectorSink") {
        self.id = id
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: TextBuffer) async {
        collectedTexts.append(buffer.text)
    }
    
    func getCollectedCount() async -> Int {
        collectedTexts.count
    }
}