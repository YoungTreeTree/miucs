import Foundation

struct VisualizationDescriptor: Equatable, Sendable {
    let id: String
    let name: String
}

struct VisualizationViewport: Equatable, Sendable {
    var width: Double
    var height: Double
    var scale: Double
    static let desktop = VisualizationViewport(width: 400, height: 260, scale: 1)
}

/// Native views belong to platform adapters, never to this shared interface.
@MainActor
protocol VisualizationSession: AnyObject {
    var descriptor: VisualizationDescriptor { get }
    func activate(viewport: VisualizationViewport)
    func update(input: FeatureInput, deltaTime: Double)
    func resize(to viewport: VisualizationViewport)
    func deactivate()
    func dispose()
}

@MainActor
final class VisualizationRegistry {
    private var factories = [String: () -> any VisualizationSession]()
    private(set) var descriptors = [VisualizationDescriptor]()
    func register(_ descriptor: VisualizationDescriptor, makeSession: @escaping () -> any VisualizationSession) {
        precondition(factories[descriptor.id] == nil, "Duplicate visualization identifier")
        descriptors.append(descriptor); factories[descriptor.id] = makeSession
    }
    func makeSession(id: String) -> (any VisualizationSession)? { factories[id]?() }
}

/// Selects exactly one module. This controller has no capture controls or native view types.
@MainActor
final class VisualizationController {
    let registry: VisualizationRegistry
    private let source: any AudioFeatureSource
    private var subscription: FeatureSubscription
    private(set) var current: (any VisualizationSession)?
    private(set) var isActive = false
    private var viewport = VisualizationViewport.desktop
    init(source: any AudioFeatureSource, registry: VisualizationRegistry) {
        self.source = source; self.registry = registry; subscription = source.subscribe()
    }
    @discardableResult
    func select(id: String) -> Bool {
        if current?.descriptor.id == id { return true }
        guard let candidate = registry.makeSession(id: id) else { return false }
        precondition(candidate.descriptor.id == id, "Session identifier must match its registry entry")
        current?.deactivate(); current?.dispose()
        subscription = source.subscribe() // New module sees the snapshot, not old bursts.
        current = candidate
        if isActive { candidate.activate(viewport: viewport) }
        return true
    }
    func resize(to viewport: VisualizationViewport) {
        self.viewport = viewport; current?.resize(to: viewport)
    }
    func resume() {
        guard !isActive else { return }
        isActive = true; subscription = source.subscribe(); current?.activate(viewport: viewport)
    }
    func pause() {
        guard isActive else { return }
        isActive = false; current?.deactivate()
    }
    @discardableResult
    func tick(deltaTime: Double) -> FeatureInput? {
        guard isActive else { return nil }
        let input = subscription.read()
        current?.update(input: input, deltaTime: deltaTime)
        return input
    }
    func dispose() { pause(); current?.dispose(); current = nil }
}
