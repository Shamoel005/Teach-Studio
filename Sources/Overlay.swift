import AppKit
import Carbon.HIToolbox

/// A soft highlight ring that follows the mouse / pen so students can see where you are pointing.
/// It is a real on-screen window, so it is recorded together with the screen.
@MainActor
final class CursorHighlighter {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private let size: CGFloat = 58
    private var pressed = false

    var windowNumber: Int? {
        guard let p = panel, p.isVisible else { return nil }
        return p.windowNumber
    }

    func start() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        v.layer?.cornerRadius = size / 2
        v.layer?.borderWidth = 2
        p.contentView = v
        panel = p
        refreshColors()
        move()
        p.orderFrontRegardless()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp,
                                           .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let t = e.type
            Task { @MainActor in self?.handle(t) }
        }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let t = e.type
            Task { @MainActor in self?.handle(t) }
            return e
        }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        pressed = false
    }

    private func handle(_ type: NSEvent.EventType) {
        if type == .leftMouseDown { pressed = true; refreshColors() }
        if type == .leftMouseUp { pressed = false; refreshColors() }
        move()
    }

    private func move() {
        guard let p = panel else { return }
        let loc = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: loc.x - size / 2, y: loc.y - size / 2))
    }

    private func refreshColors() {
        let base = pressed ? NSColor.systemRed : NSColor.systemYellow
        panel?.contentView?.layer?.backgroundColor = base.withAlphaComponent(0.28).cgColor
        panel?.contentView?.layer?.borderColor = base.withAlphaComponent(0.85).cgColor
    }
}

/// Big "3, 2, 1" before recording starts (visible even when you start with a hotkey).
@MainActor
final class CountdownHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ n: Int) {
        if panel == nil {
            let s: CGFloat = 170
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .screenSaver
            p.isReleasedWhenClosed = false
            let v = NSView(frame: NSRect(x: 0, y: 0, width: s, height: s))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            v.layer?.cornerRadius = 32
            label.font = .systemFont(ofSize: 96, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 18, width: s, height: 120)
            v.addSubview(label)
            p.contentView = v
            if let vf = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: vf.midX - s / 2, y: vf.midY - s / 2))
            }
            panel = p
        }
        label.stringValue = "\(n)"
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

/// Global hotkeys (work even while another app, e.g. your writing app, is in front).
enum HotKeys {
    static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static let controlOption = UInt32(controlKey | optionKey)

    static func register(id: UInt32, keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKeys.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), modifiers,
                            EventHotKeyID(signature: 0x54534B59, id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
