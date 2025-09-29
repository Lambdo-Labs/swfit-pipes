import Testing
@testable import SwiftPipes
import Foundation

@Suite("Pipeline Lifecycle Tests")
struct PipelineLifecycleTests {
    
    @Test("Pipeline can be created and destroyed")
    func testPipelineCreationAndDestruction() async throws {
        let pipeline = SimplePipeline()
        let status = await pipeline.status()
        #expect(status.childCount == 0)
        #expect(status.activeConnections == 0)
        #expect(status.groups.isEmpty)
    }
    
    @Test("Pipeline can add and remove children dynamically")
    func testDynamicPipelineManagement() async throws {
        let pipeline = SimplePipeline()
        let source = TestDataSource(id: "dynamic-source")
        let sink = DebugPrintSink(id: "dynamic-sink")
        
        // Add elements
        await pipeline.buildLinear([
            .source(child: source),
            .sink(child: sink)
        ])
        
        var status = await pipeline.status()
        #expect(status.childCount == 1)
        #expect(status.activeConnections == 1)
        
        // Remove element
        await pipeline.removeChild(id: "dynamic-source")
        
        status = await pipeline.status()
        #expect(status.childCount == 0)
        #expect(status.activeConnections == 0)
    }
    
    @Test("Pipeline stops all tasks when stopped")
    func testPipelineStop() async throws {
        let pipeline = SimplePipeline()
        let source = TestDataSource(id: "stop-test-source")
        let sink = DebugPrintSink(id: "stop-test-sink")
        
        await pipeline.buildLinear([
            .source(child: source),
            .sink(child: sink)
        ])
        
        await source.start(interval: 0.1)
        
        var status = await pipeline.status()
        #expect(status.activeConnections == 1)
        
        await pipeline.stop()
        
        status = await pipeline.status()
        #expect(status.activeConnections == 0)
    }
    
    @Test("Pipeline can rebuild with new configuration")
    func testPipelineRebuild() async throws {
        let pipeline = SimplePipeline()
        let source1 = TestDataSource(id: "source1")
        let sink1 = DebugPrintSink(id: "sink1")
        
        // Initial build
        await pipeline.buildLinear([
            .source(child: source1),
            .sink(child: sink1)
        ])
        
        var status = await pipeline.status()
        #expect(status.childCount == 1)
        
        // Rebuild with new elements
        let source2 = TestDataSource(id: "source2")
        let filter = TransformFilter(id: "filter") { $0 }
        let sink2 = DebugPrintSink(id: "sink2")
        
        await pipeline.buildLinear([
            .source(child: source2),
            .filter(child: filter),
            .sink(child: sink2)
        ])
        
        status = await pipeline.status()
        #expect(status.childCount == 1)
        #expect(status.activeConnections == 2) // source->filter, filter->sink
    }
}