# SwiftPipes

A graph-/pipeline-based multimedia framework for Swift, designed for audio/video processing with sources, transforms, and sinks.

## Overview

SwiftPipes provides a flexible, actor-based pipeline architecture for building data processing graphs. It's inspired by multimedia frameworks like GStreamer but designed with Swift's modern concurrency features in mind.

### Key Features

- **Actor-based concurrency**: Thread-safe by design using Swift actors
- **Flexible graph architecture**: Connect sources, filters, and sinks in any configuration
- **AsyncSequence support**: Built on Swift's AsyncSequence for efficient streaming
- **Type-safe connections**: Compile-time checking of buffer compatibility
- **Dynamic pipeline management**: Add/remove elements at runtime
- **Multi-pad support**: Elements can have multiple inputs/outputs

## Core Concepts

### Elements

1. **Source Elements** (`PipelineSourceElement`): Produce data without requiring input
2. **Sink Elements** (`PipelineSinkElement`): Consume data without producing output  
3. **Filter Elements** (`PipelineFilterElement`): Transform data (both source and sink)

### Pads

Elements communicate through pads:
- **Output Pads**: Send data to downstream elements
- **Input Pads**: Receive data from upstream elements

### Buffers

All data flowing through the pipeline must conform to `BufferProtocol`.

## Installation

Add SwiftPipes to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/swift-pipes.git", from: "0.1.0")
]
```

## Usage

### Basic Pipeline

```swift
import SwiftPipes

// Create pipeline elements
let source = TestDataSource()
let filter = TransformFilter { data in
    // Transform your data
    return transformedData
}
let sink = DebugPrintSink()

// Create and configure pipeline
let pipeline = SimplePipeline()
await pipeline.buildLinear([
    .source(child: source),
    .filter(child: filter),
    .sink(child: sink)
])

// Start the source
await source.start()

// Run for some time...
try await Task.sleep(nanoseconds: 5_000_000_000)

// Clean up
await source.stop()
await pipeline.stop()
```

### Multi-Output Pipeline

```swift
// Create a source with multiple outputs
let multiSource = MultiOutputSource()
let mainSink = DebugPrintSink(prefix: "Main")
let metaSink = DebugPrintSink(prefix: "Metadata")

// Build pipeline with multiple paths
await pipeline.buildGroups([
    (id: "main", children: [
        .source(child: multiSource, viaOut: .outputDefault),
        .sink(child: mainSink)
    ]),
    (id: "metadata", children: [
        .sourceRef(id: multiSource.id, viaOut: .custom(id: "metadata")),
        .sink(child: metaSink)
    ])
])
```

### Creating Custom Elements

#### Custom Source

```swift
actor MySource: PipelineSourceElement {
    nonisolated let id = "MySource"
    
    private var (stream, continuation) = AsyncStream.makeStream(of: MyBuffer.self)
    
    var outputPads: [ElementOutputPad<AsyncStream<MyBuffer>>] {
        [.init(ref: .outputDefault, stream: stream)]
    }
    
    func produceData() {
        // Generate and yield data
        continuation.yield(myBuffer)
    }
    
    func onCancel(task: PipeTask) {
        // Handle cancellation
    }
}
```

#### Custom Filter

```swift
actor MyFilter: PipelineFilterElement {
    nonisolated let id = "MyFilter"
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: MyBuffer.self)
    
    var outputPads: [ElementOutputPad<AsyncStream<MyBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    var inputPads: [ElementInputPad<MyBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: MyBuffer) async {
        // Process buffer
        let processed = process(buffer)
        outputContinuation.yield(processed)
    }
    
    func onCancel(task: PipeTask) {
        // Handle cancellation
    }
}
```

## Examples

The package includes several example elements in `Sources/SwiftPipes/Examples/`:

- `TestDataSource`: Generates test data at regular intervals
- `DebugPrintSink`: Prints received buffers for debugging
- `TransformFilter`: Applies a transformation to data
- `MultiOutputSource`: Demonstrates multiple output pads
- `BufferingFilter`: Buffers items before processing

## Requirements

- Swift 6.1+
- macOS 13.0+ / iOS 16.0+ / tvOS 16.0+ / watchOS 9.0+

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgments

Based on concepts from the delay-mirror project by Andre Carrera.