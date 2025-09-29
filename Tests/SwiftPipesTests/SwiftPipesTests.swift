import Testing
@testable import SwiftPipes

@Test func testBasicPipelineCreation() async throws {
    let pipeline = SimplePipeline()
    
    let source = TestDataSource(id: "testSource")
    let sink = DebugPrintSink(id: "testSink")
    
    await pipeline.buildLinear([
        .source(child: source),
        .sink(child: sink)
    ])
    
    let status = await pipeline.status()
    #expect(status.childCount == 1)
    #expect(status.activeConnections == 1)
}

@Test func testMultiOutputSource() async throws {
    let source = MultiOutputSource(id: "multiTest")
    let pads = await source.outputPads
    
    #expect(pads.count == 2)
    #expect(pads[0].ref == .outputDefault)
    #expect(pads[1].ref == .custom(id: "metadata"))
}

@Test func testBufferingFilter() async throws {
    let filter = BufferingFilter(id: "bufferTest", bufferSize: 3)
    let inputPads = await filter.inputPads
    let outputPads = await filter.outputPads
    
    #expect(inputPads.count == 1)
    #expect(outputPads.count == 1)
}

@Test func testPipelineWithFilter() async throws {
    let pipeline = SimplePipeline()
    
    let source = TestDataSource(id: "source")
    let filter = TransformFilter(id: "transform") { data in
        return data // Identity transform for testing
    }
    let sink = DebugPrintSink(id: "sink")
    
    await pipeline.buildLinear([
        .source(child: source),
        .filter(child: filter),
        .sink(child: sink)
    ])
    
    let status = await pipeline.status()
    #expect(status.activeConnections == 2) // source->filter, filter->sink
}
