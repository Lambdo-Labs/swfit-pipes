//
//  Pipeline.swift
//  SwiftPipes
//
//  A graph-/pipeline-based multimedia framework for audio/video processing
//  Based on concepts from delay-mirror by Andre Carrera
//

import Foundation

// MARK: - Core Pipeline Framework
// A pipeline will receive a list of children and the flow through them.

// MARK: - Pad Types and References

public enum ElementPadType: Sendable {
  case input
  case output
}

//protocol ElementPadProtocol: Sendable {
//  var ref: String { get }
//  var padType: ElementPadType { get }
////  var stream: any AsyncSequence { get }
//  // todo add format
//}

public enum PadRef: Hashable, Sendable {
  case none
  case inputDefault
  case outputDefault
  case custom(id: String)
}

// MARK: - Element Pads

public struct ElementOutputPad<Stream: AsyncSequence>: Sendable
where Stream.Element: Sendable, Stream: Sendable {
  //  var stream: any AsyncSequence
  
  public var ref: PadRef = .outputDefault
  public var padType: ElementPadType = .output
  public var stream: Stream
  //  var stream: Stream
  // todo add format
  
  public init(ref: PadRef = .outputDefault, padType: ElementPadType = .output, stream: Stream) {
    self.ref = ref
    self.padType = padType
    self.stream = stream
  }
}

/// a pad within an element that receives data for a separate element
/// and sends it to the internal element
public struct ElementInputPad<Buffer: BufferProtocol>: Sendable {
  //  var stream: any AsyncSequence
  
  public var ref: PadRef = .inputDefault
  public var padType: ElementPadType = .input
  public var handleBuffer: @Sendable (Pipeline, Buffer) async -> Void
  // todo add format
  
  public init(ref: PadRef = .inputDefault, padType: ElementPadType = .input, handleBuffer: @escaping @Sendable (Pipeline, Buffer) async -> Void) {
    self.ref = ref
    self.padType = padType
    self.handleBuffer = handleBuffer
  }
}

// a pad within an element that receives data from the element
// and sends it to the following external element
//protocol ElementOutputPad {
//  associatedtype Buffer
//  var stream: AsyncStream<Buffer> { get }
//}

// MARK: - Pipeline Elements

public enum PipelineElement {
  case Filter(any PipelineFilterElement)
  case Source(any PipelineSourceElement)
}

public protocol BufferProtocol: Sendable {
  // Define properties and methods common to your buffers
}

public protocol PipelineSourceElement: Actor, Identifiable {
  associatedtype Buffers: AsyncSequence, Sendable where Buffers.Element: BufferProtocol
  nonisolated var id: String { get }
  var outputPads: [ElementOutputPad<Buffers>] { get }
  func onCancel(task: PipeTask)
}

extension PipelineSourceElement {
  func onCancel(task: PipeTask) {
    
  }
}

public protocol PipelineSinkElement: Actor, Identifiable {
  associatedtype Buffer: BufferProtocol
  nonisolated var id: String { get }
  var inputPads: [ElementInputPad<Buffer>] { get }
  
}

extension PipelineSinkElement {
  var inputRefToPad: [PadRef: ElementInputPad<Buffer>] {
    Dictionary.init(grouping: self.inputPads) { element in
      element.ref
    }.mapValues { element in
      element.first!
    }
  }
}

/// an element that is both a source and a sink
public protocol PipelineFilterElement: PipelineSourceElement, PipelineSinkElement {
  
}

public protocol NamedPipelineElement {
  var name: String { get }
  var element: PipelineElement { get }
}

public protocol RefPipelineElement {
  var name: String { get }
  //  var element: PipelineElement { get }
}

// MARK: - Pipeline Schema

public enum PipelineSchemaItem {
  case ordered(children: [PipelineChild])
  // group?
  case orderedGroup(id: String, children: [PipelineChild])
  
  func getProperties() -> (groupId: String, children: [PipelineChild]) {
    switch self {
    case .ordered(let children):
      return ("default", children)
    case .orderedGroup(let id, let children):
      return (id, children)
    }
  }
}

public enum PipelineChild: Identifiable {
  public var id: String {
    switch self {
    case .source(child: let pipelineSourceElement, viaOut: _):
      pipelineSourceElement.id
    case .filter(child: let pipelineFilterElement, viaIn: _, viaOut: _):
      pipelineFilterElement.id
    case .sink(child: let pipelineSinkElement, viaIn: _):
      pipelineSinkElement.id
    case .sourceRef(let id, viaOut: _):
      id
    case .filterRef(let id, viaIn: _, viaOut: _):
      id
    case .sinkRef(let id, viaIn: _):
      id
    }
  }
  var sourceChild: (any PipelineSourceElement)? {
    switch self {
    case .source(child: let pipelineSourceElement, viaOut: _):
      pipelineSourceElement
    case .filter(child: let pipelineFilterElement, viaIn: _, viaOut: _):
      pipelineFilterElement
    default: nil
    }
  }
  
  var isAnySource: Bool {
    switch self {
    case .source(_, _):
      true
    case .filter(_, _, _):
      true
    case .sink(_, _):
      false
    case .sourceRef(_, _):
      true
    case .filterRef(_, _, _):
      true
    case .sinkRef(_, _):
      false
    }
  }
  
  var isRef: Bool {
    switch self {
    case .source(_, _):
      false
    case .filter(_, _, _):
      false
    case .sink(_, _):
      false
    case .sourceRef(_, _):
      true
    case .filterRef(_, _, _):
      true
    case .sinkRef(_, _):
      true
    }
  }
  
  case source(child: any PipelineSourceElement, viaOut: PadRef = .outputDefault)
  case filter(
    child: any PipelineFilterElement, viaIn: PadRef = .inputDefault, viaOut: PadRef = .outputDefault
  )
  case sink(child: any PipelineSinkElement, viaIn: PadRef = .inputDefault)
  case sourceRef(id: String, viaOut: PadRef = .outputDefault)
  case filterRef(id: String, viaIn: PadRef = .inputDefault, viaOut: PadRef = .outputDefault)
  case sinkRef(id: String, viaIn: PadRef = .inputDefault)
  //  case child(PipelineChild, PipelineSourceElement)
}

public typealias PipeTask = (source: String, sink: String?, groupId: String, task: Task<(), Error>)

// MARK: - Pipeline Protocol

public protocol Pipeline: Actor {
  
  var children: [PipelineSchemaItem] { get set }
  var pipeTasks: [PipeTask] { get set }
}

// MARK: - Pipeline Extension

public extension Pipeline {
  
  /// all children that are not refs
  var idToChild: [String: PipelineChild] {
    let childrenArray = self.children
      .flatMap { $0.getProperties().children }
      .filter { !$0.isRef }
    
    return Dictionary(grouping: childrenArray) { $0.id }
      .mapValues { value in
        guard let first = value.first else {
          fatalError("Should have at least one item in grouping")
        }
        assert(value.count == 1, "more than one Pipline Element for id \(first.id)")
        return first
      }
    
  }
  
  func removeChild(id: String) async {
    let matchingTasks = self.pipeTasks.filter { $0.source == id || $0.sink == id }
    for pipeTask in matchingTasks {
      pipeTask.task.cancel()
      if pipeTask.sink == id,
          let sourceChild = idToChild[pipeTask.source]?.sourceChild {
        await sourceChild.onCancel(task: pipeTask)
      }
    }
    self.pipeTasks.removeAll(where: { $0.source == id || $0.sink == id })
    self.children.removeAll(where: { $0.getProperties().children.contains(where: { $0.id == id }) })
  }
  
  func spec(children: [PipelineSchemaItem]) {
    self.children.append(contentsOf: children)
    
    let allChildrenProperties = self.children.map { $0.getProperties() }
    
    let pipeTasksLists = allChildrenProperties.map { (groupId, children) in
      let groupPipeTasks = self.getChildrenMatchesTasks(groupId: groupId, children: children)
      return groupPipeTasks.map {
        (source: $0.source, sink: $0.sink, groupId: groupId, task: $0.task)
      }
    }
    
    let _ = pipeTasksLists.compactMap { tasks -> PipelineChild? in
      let last = tasks.last
      guard let last else {
        return nil
      }
      guard let child = idToChild[last.sink] else {
        fatalError("can't find id \(last)")
      }
      if !child.isAnySource {
        return nil
      }
      
      let isTerminated = pipeTasksLists.contains(where: { $0.first?.source == last.sink })
      return isTerminated ? nil : child
    }
    
    //    let defaultTerminateTasks = self.defaultTerminateChildren(children: unterminatedEndSources)
    
    let pipeTasks = pipeTasksLists.flatMap { $0 }
    
    self.pipeTasks.append(contentsOf: pipeTasks)
    // TODO include the group so it can be added to the array
    //    for pipeTask in defaultTerminateTasks {
    //      self.pipeTasks.append(pipeTask)
    //    }
  }
  
  func getChildrenMatchesTasks(groupId: String, children: [PipelineChild]) -> [(
    source: String, sink: String, task: Task<(), Error>
  )] {
    let pipeTask: [(source: String, sink: String, task: Task<(), Error>)] = zip(
      children, children.dropFirst()
    )
      .compactMap { (child, nextChild) in
        let isExisting = self.pipeTasks.contains(where: {
          $0.groupId == groupId && $0.source == child.id && $0.sink == nextChild.id
        })
        guard !isExisting else { return nil }
        let task = self.pipeToNext(child: child, nextChild: nextChild)
        return (source: child.id, sink: nextChild.id, task)
      }
    return pipeTask
  }
  
  func defaultTerminateChildren(children: [PipelineChild]) -> [(
    source: String, sink: String?, task: Task<(), Error>
  )] {
    children.map { child in
      guard case let .filter(child: child, viaIn: _, viaOut: sourceOut) = child else {
        fatalError("only filters should be default terminated. tried with \(child.id)")
      }
      let task = matchTask(source: child, sourceOutputPad: sourceOut)
      return (source: child.id, sink: nil, task)
    }
  }
  func matchTask<Source: PipelineSourceElement>(source: Source, sourceOutputPad: PadRef) -> Task<
    (), Error
  > {
    Task {
      guard let sourcePad = await source.outputPads.first(where: { $0.ref == sourceOutputPad })
      else {
        fatalError("output pad not found")
      }
      try await match(sourcePad: sourcePad)
    }
  }
  
  func pipeToNext(child: PipelineChild, nextChild: PipelineChild) -> Task<(), Error> {
    switch (child, nextChild) {
    case (
      PipelineChild.source(child: let source, viaOut: let sourcePadRef),
      .sink(child: let sink, viaIn: let sinkPadRef)
    ):
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.source(child: let source, viaOut: let sourcePadRef),
      .filter(child: let sink, viaIn: let sinkPadRef, viaOut: _)
    ):
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filter(child: let source, viaIn: _, viaOut: let sourcePadRef),
      .filter(child: let sink, viaIn: let sinkPadRef, viaOut: _)
    ):
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filter(child: let source, viaIn: _, viaOut: let sourcePadRef),
      .sink(child: let sink, viaIn: let sinkPadRef)
    ):
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.sourceRef(id: let id, viaOut: let sourcePadRef),
      .sink(child: let sink, viaIn: let sinkPadRef)
    ):
      guard let sourceChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .source(child: source, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.sourceRef(id: let id, viaOut: let sourcePadRef),
      .filter(child: let sink, viaIn: let sinkPadRef, viaOut: _)
    ):
      guard let sourceChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .source(child: source, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filterRef(id: let id, viaIn: _, viaOut: let sourcePadRef),
      .filter(child: let sink, viaIn: let sinkPadRef, viaOut: _)
    ):
      guard let sourceChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: source, viaIn: _, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filterRef(id: let id, viaIn: _, viaOut: let sourcePadRef),
      .sink(child: let sink, viaIn: let sinkPadRef)
    ):
      guard let sourceChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: source, viaIn: _, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.source(child: let source, viaOut: let sourcePadRef),
      .sinkRef(id: let id, viaIn: let sinkPadRef)
    ):
      guard let sourceChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .sink(child: sink, viaIn: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.source(child: let source, viaOut: let sourcePadRef),
      .filterRef(id: let id, viaIn: let sinkPadRef, viaOut: _)
    ):
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: sink, viaIn: _, viaOut: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filter(child: let source, viaIn: _, viaOut: let sourcePadRef),
      .filterRef(id: let id, viaIn: let sinkPadRef, viaOut: _)
    ):
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: sink, viaIn: _, viaOut: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filter(child: let source, viaIn: _, viaOut: let sourcePadRef),
      .sinkRef(id: let id, viaIn: let sinkPadRef)
    ):
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .sink(child: sink, viaIn: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.sourceRef(id: let sourceId, viaOut: let sourcePadRef),
      .sinkRef(id: let id, viaIn: let sinkPadRef)
    ):
      guard let sourceChild = self.idToChild[sourceId] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .source(child: source, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .sink(child: sink, viaIn: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.sourceRef(id: let sourceId, viaOut: let sourcePadRef),
      .filterRef(id: let id, viaIn: let sinkPadRef, viaOut: _)
    ):
      guard let sourceChild = self.idToChild[sourceId] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .source(child: source, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: sink, viaIn: _, viaOut: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filterRef(id: let sourceId, viaIn: _, viaOut: let sourcePadRef),
      .filterRef(id: let id, viaIn: let sinkPadRef, viaOut: _)
    ):
      guard let sourceChild = self.idToChild[sourceId] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: source, viaIn: _, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: sink, viaIn: _, viaOut: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
      
    case (
      PipelineChild.filterRef(id: let sourceId, viaIn: _, viaOut: let sourcePadRef),
      .sinkRef(id: let id, viaIn: let sinkPadRef)
    ):
      guard let sourceChild = self.idToChild[sourceId] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .filter(child: source, viaIn: _, viaOut: _) = sourceChild else {
        fatalError("element not matching ref type \(child)")
      }
      
      guard let sinkChild = self.idToChild[id] else {
        fatalError("element id not found in children: \(id)")
      }
      guard case let .sink(child: sink, viaIn: _) = sinkChild else {
        fatalError("element not matching ref type \(child)")
      }
      return self.matchTask(
        source: source, sourceOutputPad: sourcePadRef, sink: sink, sinkInputPad: sinkPadRef)
    case (.sink(child: _, viaIn: _), _):
      fatalError("attempted to pipe sink into another value")
    case (.sinkRef(id: _, viaIn: _), _):
      fatalError("attempted to pipe sinkRef into another value")
    case (_, .source(child: _, viaOut: _)):
      fatalError("attempted to pipe value into a source")
    case (_, .sourceRef(id: _, viaOut: _)):
      fatalError("attempted to pipe value into a sourceRef")
    }
  }
  
  func matchTask<Source: PipelineSourceElement, Sink: PipelineSinkElement>(
    source: Source, sourceOutputPad: PadRef, sink: Sink, sinkInputPad: PadRef
  ) -> Task<(), Error> {
    Task {
      guard let sourcePad = await source.outputPads.first(where: { $0.ref == sourceOutputPad })
      else {
        fatalError("output pad not found")
      }
      guard let sinkPad = await sink.inputRefToPad[sinkInputPad] else {
        fatalError("destionationPad not found")
      }
      
      // this code is being used to debug my specific pipeline
      //      if sink.id == "VideoSaver" && source.id == "EncodedHandlerElement" {
      //        try await match2(sourcePad: sourcePad, sinkPad: sinkPad)
      //      } else {
      try await match(sourcePad: sourcePad, sinkPad: sinkPad)
      print("exited stream \(source.id) with pad \(sourcePad.ref) to sink \(sink.id) with pad \(sinkPad.ref)")
      //      }
    }
  }
  func match<Buffer, Buffers>(
    sourcePad: ElementOutputPad<Buffers>, sinkPad: ElementInputPad<Buffer>
  ) async throws {
    let stream = sourcePad.stream
    for try await buffer in stream {
      guard let buffer = buffer as? Buffer else {
        print("ERROR: mismatching source and sink")
        return
      }
      await sinkPad.handleBuffer(self, buffer)
    }
  }
  
  // this is the same as the above function but is used for debugging
  //  func match2<Buffer, Buffers>(
  //    sourcePad: ElementOutputPad<Buffers>, sinkPad: ElementInputPad<Buffer>
  //  ) async throws {
  //    let stream = sourcePad.stream
  //    do {
  //      for try await buffer in stream {
  //        guard let buffer = buffer as? Buffer else {
  //          print("ERROR: mismatching source and sink")
  //          return
  //        }
  //        await sinkPad.handleBuffer(self, buffer)
  //      }
  //      print("ERROR: shouldn't exit \(stream)")
  //    } catch {
  //      throw error
  //    }
  //
  //  }
  
  func match<Buffers>(sourcePad: ElementOutputPad<Buffers>) async throws {
    let stream = sourcePad.stream
    for try await _ in stream {
    }
  }
  
}

