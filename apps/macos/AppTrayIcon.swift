#if canImport(MiucsCore)
import MiucsCore
#endif
import AppKit

/// Application identity and animation are owned by the shell, independently of Lua workers.
@MainActor
final class AppTrayIcon {
    private let item: NSStatusItem
    private let source: any KeyboardFeatureSource
    private var subscription: KeyboardSubscription?
    private var animationEnabled: Bool
    private var head = TrayHeadAnimation()
    private var timer: Timer?
    private var last = ProcessInfo.processInfo.systemUptime
    private var lastPose = Int.min
    private var reasons = Set<String>()
    private var observers = [NSObjectProtocol]()
    private var frames = [Int:NSImage]()
    private let portrait: NSImage

    init(item: NSStatusItem, source: any KeyboardFeatureSource, animationEnabled: Bool = true) {
        self.item = item
        self.source = source
        self.animationEnabled = animationEnabled
        portrait=(Bundle.main.url(forResource:"PixelCatHead",withExtension:"png") ?? Bundle.main.url(forResource:"cat-head",withExtension:"png")).flatMap(NSImage.init(contentsOf:)) ?? NSImage(size:NSSize(width:64,height:64))
        NSApp.applicationIconImage=portrait
        item.button?.setAccessibilityLabel("Miucs")
        let center=NSWorkspace.shared.notificationCenter
        for (name,reason,paused) in [(NSWorkspace.willSleepNotification,"sleep",true),(NSWorkspace.didWakeNotification,"sleep",false),(NSWorkspace.sessionDidResignActiveNotification,"session",true),(NSWorkspace.sessionDidBecomeActiveNotification,"session",false)] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(paused,reason:reason) }
            })
        }
        schedule()
    }

    func setAnimationEnabled(_ enabled: Bool) {
        guard animationEnabled != enabled else { return }
        animationEnabled = enabled
        schedule()
    }

    private func suspend(_ paused: Bool, reason: String) {
        if paused { reasons.insert(reason) } else { reasons.remove(reason) }
        schedule()
    }
    private func schedule() {
        timer?.invalidate()
        timer = nil
        subscription = nil
        head.reset()
        present(0)
        guard animationEnabled, reasons.isEmpty else { return }
        subscription = source.subscribe()
        last = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func tick() {
        guard let subscription else { return }
        let now=ProcessInfo.processInfo.systemUptime
        head.advance(seconds:max(0,now-last),input:subscription.read());last=now
        present(Int((head.angle * 180 / .pi).rounded()))
    }
    private func present(_ angle: Int) {
        let pose=max(-12,min(12,angle))
        guard pose != lastPose else { return };lastPose=pose
        if frames[pose]==nil {
            // Cache at most 25 small raster poses; no script or plugin surface participates.
            let image=NSImage(size:NSSize(width:36,height:36))
            image.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .none
            let transform=AffineTransform(translationByX:18,byY:5)
            var rotation=transform;rotation.rotate(byDegrees:-CGFloat(pose));rotation.translate(x:-18,y:-5)
            (rotation as NSAffineTransform).concat()
            portrait.draw(in:NSRect(x:1,y:1,width:34,height:34))
            image.unlockFocus();image.size=NSSize(width:18,height:18);image.isTemplate=false
            frames[pose]=image
        }
        item.button?.image=frames[pose]
    }
    func stop() {
        timer?.invalidate();timer=nil
        subscription = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) };observers=[]
    }
}
