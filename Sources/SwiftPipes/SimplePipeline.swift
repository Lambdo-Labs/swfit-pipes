//
//  SimplePipeline.swift
//  SwiftPipes
//
//  A concrete implementation of the Pipeline protocol
//

import Foundation

/// A simple implementation of the Pipeline protocol
public actor SimplePipeline: Pipeline {
    public var children: [PipelineSchemaItem] = []
    public var pipeTasks: [PipeTask] = []
    
    public init() {}
    
    /// Starts all tasks in the pipeline
    public func start() async {
        // The tasks are automatically started when spec() is called
        // This method can be used for any additional startup logic
        print("Pipeline started with \(pipeTasks.count) active connections")
    }
    
    /// Stops all tasks in the pipeline
    public func stop() async {
        for pipeTask in pipeTasks {
            pipeTask.task.cancel()
            
            // Notify source elements about cancellation
            if let sourceChild = idToChild[pipeTask.source]?.sourceChild {
                await sourceChild.onCancel(task: pipeTask)
            }
        }
        pipeTasks.removeAll()
        print("Pipeline stopped")
    }
    
    /// Builds and runs a pipeline with the given children
    public func build(_ builder: () -> [PipelineSchemaItem]) async {
        await stop() // Stop any existing pipeline
        children.removeAll()
        
        let newChildren = builder()
        spec(children: newChildren)
    }
    
    /// Gets the current pipeline status
    public func status() -> (childCount: Int, activeConnections: Int, groups: [String]) {
        let groups = children.map { $0.getProperties().groupId }
        return (children.count, pipeTasks.count, groups)
    }
    
    /// Waits for all pipeline tasks to complete
    public func waitForCompletion() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for pipeTask in pipeTasks {
                group.addTask {
                    try await pipeTask.task.value
                }
            }
            try await group.waitForAll()
        }
    }
}

// MARK: - Pipeline Builder Convenience

public extension SimplePipeline {
    /// Creates a linear pipeline from a sequence of elements
    func buildLinear(_ elements: [PipelineChild]) async {
        await build {
            [.ordered(children: elements)]
        }
    }
    
    /// Creates a pipeline with multiple parallel groups
    func buildGroups(_ groups: [(id: String, children: [PipelineChild])]) async {
        await build {
            groups.map { group in
                .orderedGroup(id: group.id, children: group.children)
            }
        }
    }
}

// MARK: - Usage Example

public func createExamplePipeline() async throws {
    let pipeline = SimplePipeline()
    
    // Create elements
    let source = TestDataSource(id: "source1")
    let filter = TransformFilter(id: "transform1") { data in
        // Convert to uppercase
        if let string = String(data: data, encoding: .utf8) {
            return string.uppercased().data(using: .utf8) ?? data
        }
        return data
    }
    let sink = DebugPrintSink(id: "sink1", prefix: "Pipeline")
    
    // Build pipeline: source -> filter -> sink
    await pipeline.buildLinear([
        .source(child: source),
        .filter(child: filter),
        .sink(child: sink)
    ])
    
    // Start the source
    await source.start(interval: 1.0)
    
    // Run for a few seconds
    try await Task.sleep(nanoseconds: 5_000_000_000)
    
    // Stop the pipeline
    await source.stop()
    await pipeline.stop()
}

// MARK: - Complex Pipeline Example

public func createComplexPipeline() async throws {
    let pipeline = SimplePipeline()
    
    // Create elements
    let multiSource = MultiOutputSource(id: "multiSource")
    let mainSink = DebugPrintSink(id: "mainSink", prefix: "Main")
    let metaSink = DebugPrintSink(id: "metaSink", prefix: "Metadata")
    
    let dataSource = TestDataSource(id: "dataSource")
    let bufferFilter = BufferingFilter(id: "buffer", bufferSize: 3)
    let bufferSink = DebugPrintSink(id: "bufferSink", prefix: "Buffered")
    
    // Build pipeline with multiple groups
    await pipeline.buildGroups([
        (id: "main-flow", children: [
            .source(child: multiSource, viaOut: .outputDefault),
            .sink(child: mainSink)
        ]),
        (id: "meta-flow", children: [
            .sourceRef(id: "multiSource", viaOut: .custom(id: "metadata")),
            .sink(child: metaSink)
        ]),
        (id: "buffer-flow", children: [
            .source(child: dataSource),
            .filter(child: bufferFilter),
            .sink(child: bufferSink)
        ])
    ])
    
    // Start sources
    await multiSource.start()
    await dataSource.start(interval: 0.3)
    
    // Run for a few seconds
    try await Task.sleep(nanoseconds: 5_000_000_000)
    
    // Stop everything
    await multiSource.stop()
    await dataSource.stop()
    await bufferFilter.finish()
    await pipeline.stop()
}