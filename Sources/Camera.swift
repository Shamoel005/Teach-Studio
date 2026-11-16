import AppKit
import AVFoundation

enum BubbleShape: String, CaseIterable, Identifiable {
    case circle = "Circle"
    case rounded = "Rounded square"
    var id: String { rawValue }
}

enum Corner: String, CaseIterable, Identifiable {
    case bottomLeft = "Bottom left"
    case bottomRight = "Bottom right"
    case topLeft = "Top left"
    case topRight = "Top right"
    var id: String { rawValue }
}

enum Devices {
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}

/// Borderless floating window that never takes focus, so it doesn't disturb your writing app.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Live camera preview clipped to a circle / rounded square with a (gradient) ring border.
final class BubbleView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let videoMask = CAShapeLayer()
    private var shape: BubbleShape = .circle
    private var ringWidth: CGFloat = 8
    private var mirrored = false

    init(session: AVCaptureSession, frame: NSRect) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.mask = videoMask
        layer?.addSublayer(previewLayer)

        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ring.mask = ringMask
        ring.startPoint = CGPoint(x: 0, y: 0)
        ring.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    func update(ringWidth: CGFloat, colors: [NSColor], shape: BubbleShape, mirrored: Bool) {
        self.ringWidth = ringWidth
        self.shape = shape
        self.mirrored = mirrored
        ring.colors = colors.map { $0.cgColor }
        needsLayout = true
        applyMirror()
    }

    func applyMirror() {
        guard let c = previewLayer.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = mirrored
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMirror()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        previewLayer.frame = b
        videoMask.frame = b
        videoMask.path = path(in: b.insetBy(dx: max(0, ringWidth - 0.5), dy: max(0, ringWidth - 0.5)))
        ring.frame = b
        ringMask.frame = b
        ringMask.path = path(in: b.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        ringMask.lineWidth = ringWidth
        CATransaction.commit()
    }

    private func path(in r: CGRect) -> CGPath {
        switch shape {
        case .circle:
            return CGPath(ellipseIn: r, transform: nil)
        case .rounded:
            let radius = r.width * 0.18
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }
}

@MainActor
final class CameraBubble {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "teachstudio.camera")
    private var input: AVCaptureDeviceInput?
    private var panel: BubblePanel?
    private var view: BubbleView?

    private var size: CGFloat = 220
    private var ring: CGFloat = 8
    private var c1 = NSColor.systemRed
    private var c2 = NSColor.systemOrange
    private var shape: BubbleShape = .circle
    private var mirrored = false

    var isShown: Bool { panel?.isVisible ?? false }
    var windowNumber: Int? {
        guard let p = panel, p.isVisible else { return nil }
        return p.windowNumber
    }

    func setStyle(size: CGFloat, ring: CGFloat, c1: NSColor, c2: NSColor, shape: BubbleShape, mirrored: Bool) {
        self.size = size
        self.ring = ring
        self.c1 = c1
        self.c2 = c2
        self.shape = shape
        self.mirrored = mirrored
        view?.update(ringWidth: ring, colors: [c1, c2], shape: shape, mirrored: mirrored)
        resizePanel()
    }

    func show(device: AVCaptureDevice, displayID: CGDirectDisplayID) throws {
        try attach(device)
        if panel == nil {
            let p = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = BubbleView(session: session, frame: NSRect(x: 0, y: 0, width: size, height: size))
            p.contentView = v
            panel = p
            view = v
            move(to: .bottomLeft, displayID: displayID)
        }
        view?.update(ringWidth: ring, colors: [c1, c2], shape: shape, mirrored: mirrored)
        panel?.orderFrontRegardless()
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.view?.applyMirror()
        }
    }

    func switchDevice(_ device: AVCaptureDevice) throws {
        try attach(device)
        view?.applyMirror()
    }

    func hide() {
        panel?.orderOut(nil)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func move(to corner: Corner, displayID: CGDirectDisplayID?) {
        guard let p = panel else { return }
        let screen = displayID.flatMap { Devices.screen(for: $0) } ?? p.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let m: CGFloat = 36
        let left = (corner == .bottomLeft || corner == .topLeft)
        let bottom = (corner == .bottomLeft || corner == .bottomRight)
        let x = left ? vf.minX + m : vf.maxX - size - m
        let y = bottom ? vf.minY + m : vf.maxY - size - m
        p.setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
    }

    private func resizePanel() {
        guard let p = panel else { return }
        let f = p.frame
        p.setFrame(NSRect(x: f.midX - size / 2, y: f.midY - size / 2, width: size, height: size), display: true)
    }

    private func attach(_ device: AVCaptureDevice) throws {
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if let old = input {
            session.removeInput(old)
            input = nil
        }
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            throw RecorderError.message("Could not use the camera \"\(device.localizedName)\".")
        }
        session.addInput(newInput)
        input = newInput
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        session.commitConfiguration()
    }
}
