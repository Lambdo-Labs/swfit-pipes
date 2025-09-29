//
//  BasicElements.swift
//  SwiftPipes
//
//  Example implementations of basic pipeline elements
//

import Foundation

// MARK: - Example Buffer Types

public struct DataBuffer: BufferProtocol {
    public let data: Data
    public let timestamp: TimeInterval
    
    public init(data: Data, timestamp: TimeInterval) {
        self.data = data
        self.timestamp = timestamp
    }
}

public struct TextBuffer: BufferProtocol {
    public let text: String
    public let metadata: [String: Any]
    
    public init(text: String, metadata: [String: Any] = [:]) {
        self.text = text
        self.metadata = metadata
    }
}

// MARK: - Basic Source Element

/// A source element that generates test data at regular intervals
public actor TestDataSource: PipelineSourceElement {
    public nonisolated let id: String
    
    private var (stream, continuation) = AsyncStream.makeStream(of: DataBuffer.self)
    private var task: Task<Void, Never>?
    
    public var outputPads: [ElementOutputPad<AsyncStream<DataBuffer>>] {
        [.init(ref: .outputDefault, stream: stream)]
    }
    
    public init(id: String = "TestDataSource") {
        self.id = id
    }
    
    public func start(interval: TimeInterval = 1.0) {
        stop() // Cancel any existing task
        
        task = Task {
            var counter = 0
            while !Task.isCancelled {
                let data = "Test data \(counter)".data(using: .utf8)!
                let buffer = DataBuffer(data: data, timestamp: Date().timeIntervalSince1970)
                continuation.yield(buffer)
                counter += 1
                
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
    
    public func stop() {
        task?.cancel()
        task = nil
    }
    
    public func finish() {
        stop()
        continuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
    
    deinit {
        task?.cancel()
    }
}

// MARK: - Basic Sink Element

/// A sink element that prints received buffers
public actor DebugPrintSink: PipelineSinkElement {
    public nonisolated let id: String
    private let prefix: String
    
    public var inputPads: [ElementInputPad<DataBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "DebugPrintSink", prefix: String = "Debug") {
        self.id = id
        self.prefix = prefix
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: DataBuffer) async {
        if let string = String(data: buffer.data, encoding: .utf8) {
            print("[\(prefix)] Received: \(string) at \(buffer.timestamp)")
        }
    }
}

// MARK: - Basic Filter Element

/// A filter element that transforms data buffers
public actor TransformFilter: PipelineFilterElement {
    public nonisolated let id: String
    private let transform: @Sendable (Data) -> Data
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: DataBuffer.self)
    
    public var outputPads: [ElementOutputPad<AsyncStream<DataBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<DataBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "TransformFilter", transform: @escaping @Sendable (Data) -> Data) {
        self.id = id
        self.transform = transform
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: DataBuffer) async {
        let transformedData = transform(buffer.data)
        let newBuffer = DataBuffer(data: transformedData, timestamp: buffer.timestamp)
        outputContinuation.yield(newBuffer)
    }
    
    public func finish() {
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
}

// MARK: - Multi-Output Source

/// A source element with multiple output pads
public actor MultiOutputSource: PipelineSourceElement {
    public nonisolated let id: String
    
    private var (mainStream, mainContinuation) = AsyncStream.makeStream(of: TextBuffer.self)
    private var (metadataStream, metadataContinuation) = AsyncStream.makeStream(of: TextBuffer.self)
    private var task: Task<Void, Never>?
    
    public var outputPads: [ElementOutputPad<AsyncStream<TextBuffer>>] {
        [
            .init(ref: .outputDefault, stream: mainStream),
            .init(ref: .custom(id: "metadata"), stream: metadataStream)
        ]
    }
    
    public init(id: String = "MultiOutputSource") {
        self.id = id
    }
    
    public func start() {
        stop()
        
        task = Task {
            var counter = 0
            while !Task.isCancelled {
                // Send main data
                let mainBuffer = TextBuffer(text: "Main data \(counter)")
                mainContinuation.yield(mainBuffer)
                
                // Send metadata every 3rd iteration
                if counter % 3 == 0 {
                    let metaBuffer = TextBuffer(
                        text: "Metadata",
                        metadata: ["counter": counter, "timestamp": Date().timeIntervalSince1970]
                    )
                    metadataContinuation.yield(metaBuffer)
                }
                
                counter += 1
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
    }
    
    public func stop() {
        task?.cancel()
        task = nil
    }
    
    public func finish() {
        stop()
        mainContinuation.finish()
        metadataContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
    
    deinit {
        task?.cancel()
    }
}

// MARK: - Buffering Filter

/// A filter element that buffers items before processing
public actor BufferingFilter: PipelineFilterElement {
    public nonisolated let id: String
    private let bufferSize: Int
    private var buffer: [DataBuffer] = []
    
    private var (outputStream, outputContinuation) = AsyncStream.makeStream(of: DataBuffer.self)
    
    public var outputPads: [ElementOutputPad<AsyncStream<DataBuffer>>] {
        [.init(ref: .outputDefault, stream: outputStream)]
    }
    
    public var inputPads: [ElementInputPad<DataBuffer>] {
        [.init(ref: .inputDefault, handleBuffer: self.handleBuffer)]
    }
    
    public init(id: String = "BufferingFilter", bufferSize: Int = 5) {
        self.id = id
        self.bufferSize = bufferSize
    }
    
    @Sendable
    private func handleBuffer(context: any Pipeline, buffer: DataBuffer) async {
        self.buffer.append(buffer)
        
        if self.buffer.count >= bufferSize {
            // Process buffered items
            let combined = self.buffer.map { buf in
                String(data: buf.data, encoding: .utf8) ?? ""
            }.joined(separator: ", ")
            
            let combinedData = combined.data(using: .utf8) ?? Data()
            let avgTimestamp = self.buffer.map { $0.timestamp }.reduce(0, +) / Double(self.buffer.count)
            
            let outputBuffer = DataBuffer(data: combinedData, timestamp: avgTimestamp)
            outputContinuation.yield(outputBuffer)
            
            // Clear buffer
            self.buffer.removeAll()
        }
    }
    
    public func flush() async {
        if !buffer.isEmpty {
            let combined = buffer.map { buf in
                String(data: buf.data, encoding: .utf8) ?? ""
            }.joined(separator: ", ")
            
            let combinedData = combined.data(using: .utf8) ?? Data()
            let avgTimestamp = buffer.map { $0.timestamp }.reduce(0, +) / Double(buffer.count)
            
            let outputBuffer = DataBuffer(data: combinedData, timestamp: avgTimestamp)
            outputContinuation.yield(outputBuffer)
            
            buffer.removeAll()
        }
    }
    
    public func finish() async {
        await flush()
        outputContinuation.finish()
    }
    
    public func onCancel(task: PipeTask) {
        // Handle cancellation if needed
    }
}