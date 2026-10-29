import Foundation

struct VisualizationLayout: Equatable, Sendable {
    let width: Double
    let height: Double
    let minimumWidth: Double
    let maximumWidth: Double
    var aspectRatio: Double { height / width }
    static let desktop = VisualizationLayout(width: 400, height: 260, minimumWidth: 40, maximumWidth: 1000)
}

struct VisualizationDescriptor: Equatable, Sendable {
    let id: String
    let name: String
    var layout: VisualizationLayout = .desktop
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
    func applyAppearance(_ appearance: VisualizationAppearance)
    func activate(viewport: VisualizationViewport)
    func receive(keyboard: KeyboardInput)
    func update(input: FeatureInput, deltaTime: Double)
    func resize(to viewport: VisualizationViewport)
    func deactivate()
    func dispose()
}

// Simulations have no paint. Native drawing adapters implement this hook.
extension VisualizationSession {
    func applyAppearance(_ appearance: VisualizationAppearance) {}
    func receive(keyboard: KeyboardInput) {}
}

@MainActor
final class VisualizationRegistry {
    private var factories = [String: () -> any VisualizationSession]()
    private(set) var descriptors = [VisualizationDescriptor]()
    func register(_ descriptor: VisualizationDescriptor, makeSession: @escaping () -> any VisualizationSession) {
        precondition(factories[descriptor.id] == nil, "Duplicate visualization identifier")
        let layout = descriptor.layout
        precondition([layout.width, layout.height, layout.minimumWidth, layout.maximumWidth].allSatisfy { $0.isFinite && $0 > 0 }
                     && layout.minimumWidth <= layout.width && layout.width <= layout.maximumWidth, "Invalid visualization layout")
        descriptors.append(descriptor); factories[descriptor.id] = makeSession
    }
    /// Plugin preview replaces factories only; existing sessions remain alive until switched.
    func replace(_ descriptor: VisualizationDescriptor, makeSession: @escaping () -> any VisualizationSession) {
        if let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) {
            descriptors[index] = descriptor; factories[descriptor.id] = makeSession
        } else { register(descriptor, makeSession: makeSession) }
    }
    func remove(id: String) { factories.removeValue(forKey:id); descriptors.removeAll { $0.id==id } }
    func descriptor(id: String) -> VisualizationDescriptor? { descriptors.first { $0.id == id } }
    func makeSession(id: String) -> (any VisualizationSession)? { factories[id]?() }
}

/// Selects exactly one module. This controller has no capture controls or native view types.
@MainActor
final class VisualizationController {
    let registry: VisualizationRegistry
    private let source: any AudioFeatureSource
    private var subscription: FeatureSubscription
    private let keyboardSource: (any KeyboardFeatureSource)?
    private var keyboardSubscription: KeyboardSubscription?
    private(set) var current: (any VisualizationSession)?
    private(set) var isActive = false
    private(set) var appearance: VisualizationAppearance?
    private var viewport = VisualizationViewport.desktop
    init(source: any AudioFeatureSource, registry: VisualizationRegistry,
         keyboardSource: (any KeyboardFeatureSource)? = nil) {
        self.source = source; self.registry = registry; subscription = source.subscribe()
        self.keyboardSource = keyboardSource; keyboardSubscription = keyboardSource?.subscribe()
    }
    @discardableResult
    func select(id: String) -> Bool {
        if current?.descriptor.id == id { return true }
        guard let candidate = registry.makeSession(id: id) else { return false }
        precondition(candidate.descriptor.id == id, "Session identifier must match its registry entry")
        current?.deactivate(); current?.dispose()
        subscription = source.subscribe() // New module sees the snapshot, not old bursts.
        keyboardSubscription = keyboardSource?.subscribe()
        current = candidate
        if let appearance { candidate.applyAppearance(appearance) }
        if isActive { candidate.activate(viewport: viewport) }
        return true
    }
    func resize(to viewport: VisualizationViewport) {
        self.viewport = viewport; current?.resize(to: viewport)
    }
    func applyAppearance(_ appearance: VisualizationAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance; current?.applyAppearance(appearance)
    }
    func resume() {
        guard !isActive else { return }
        isActive = true; subscription = source.subscribe(); keyboardSubscription = keyboardSource?.subscribe()
        current?.activate(viewport: viewport)
    }
    func pause() {
        guard isActive else { return }
        isActive = false; current?.deactivate()
    }
    @discardableResult
    func tick(deltaTime: Double) -> FeatureInput? {
        guard isActive else { return nil }
        let input = subscription.read()
        if let keyboard = keyboardSubscription?.read() { current?.receive(keyboard: keyboard) }
        current?.update(input: input, deltaTime: deltaTime)
        return input
    }
    func dispose() { pause(); current?.dispose(); current = nil }
}
