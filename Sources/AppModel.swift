import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Combine
import AppKit

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255,
                  green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .red
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Devices
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID = 0
    @Published var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID = ""          // "" = auto
    @Published var mics: [AVCaptureDevice] = []
    @Published var selectedMicID = ""             // "" = system default

    // Recording settings
    @Published var lectureTitle = ""
    @Published var audioMode: AudioMode = .both
    @Published var resolutionWidth = 1920
    @Published var fps = 30
    @Published var saveFolder: URL
    @Published var highlightCursor = true

    // Webcam bubble
    @Published var cameraOn = false
    @Published var bubbleSize = 220.0 { didSet { applyStyle() } }
    @Published var ringWidth = 8.0 { didSet { applyStyle() } }
    @Published var ringColor1 = Color.red { didSet { applyStyle() } }
    @Published var ringColor2 = Color.orange { didSet { applyStyle() } }
    @Published var useGradient = true { didSet { applyStyle() } }
    @Published var bubbleShape: BubbleShape = .circle { didSet { applyStyle() } }
    @Published var mirrorCamera = false { didSet { applyStyle() } }
    @Published var corner: Corner = .bottomLeft

    // State
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isProcessing = false
    @Published var countdown: Int?
    @Published var elapsed: TimeInterval = 0
    @Published var lastFile: URL?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let engine = CaptureEngine()
    private let bubble = CameraBubble()
    private let highlighter = CursorHighlighter()
    private let hud = CountdownHUD()
    private var tempURL: URL?
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart = Date()
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        saveFolder = movies.appendingPathComponent("Teaching Recordings")
        loadPrefs()
        applyStyle()

        engine.onError = { [weak self] msg in
            Task { @MainActor in self?.handleStreamError(msg) }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
        nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }

        objectWillChange
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.savePrefs() }
            .store(in: &cancellables)

        HotKeys.register(id: 1, keyCode: 15, modifiers: HotKeys.controlOption) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        HotKeys.register(id: 2, keyCode: 35, modifiers: HotKeys.controlOption) { [weak self] in
            Task { @MainActor in self?.togglePause() }
        }
        HotKeys.register(id: 3, keyCode: 8, modifiers: HotKeys.controlOption) { [weak self] in
            Task { @MainActor in self?.setCameraOn(!(self?.cameraOn ?? false)) }
        }

        refreshDevices()
        Task { await refreshDisplays() }
    }

    // MARK: Devices

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            if !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = displays.first?.displayID ?? 0
            }
        } catch {
            errorMessage = "Screen Recording permission is needed. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."
        }
    }

    func refreshDevices() {
        cameras = Devices.cameras()
        mics = Devices.microphones()
        if !selectedCameraID.isEmpty, !cameras.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = ""
        }
        if !selectedMicID.isEmpty, !mics.contains(where: { $0.uniqueID == selectedMicID }) {
            selectedMicID = ""
        }
        if cameraOn, cameras.isEmpty {
            bubble.hide()
            cameraOn = false
            statusMessage = "Camera disconnected."
        }
    }

    // MARK: Webcam bubble

    private func pickedCamera() -> AVCaptureDevice? {
        if let c = cameras.first(where: { $0.uniqueID == selectedCameraID }) { return c }
        // Auto: prefer an external webcam if one is plugged in, otherwise the built-in camera.
        return cameras.first(where: { $0.deviceType == .external }) ?? cameras.first
    }

    func setCameraOn(_ on: Bool) {
        Task {
            if on {
                guard let dev = pickedCamera() else {
                    errorMessage = "No camera detected. Plug in a webcam and it will appear automatically."
                    cameraOn = false
                    return
                }
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    errorMessage = "Camera access denied. Allow it in System Settings → Privacy & Security → Camera."
                    cameraOn = false
                    return
                }
                do {
                    applyStyle()
                    try bubble.show(device: dev, displayID: selectedDisplayID)
                    cameraOn = true
                } catch {
                    errorMessage = error.localizedDescription
                    cameraOn = false
                }
            } else {
                bubble.hide()
                cameraOn = false
            }
        }
    }

    func selectCamera(_ id: String) {
        selectedCameraID = id
        guard cameraOn, let dev = pickedCamera() else { return }
        do { try bubble.switchDevice(dev) } catch { errorMessage = error.localizedDescription }
    }

    func snapBubble() {
        bubble.move(to: corner, displayID: selectedDisplayID)
    }

    private func applyStyle() {
        bubble.setStyle(size: CGFloat(bubbleSize),
                        ring: CGFloat(ringWidth),
                        c1: NSColor(ringColor1),
                        c2: NSColor(useGradient ? ringColor2 : ringColor1),
                        shape: bubbleShape,
                        mirrored: mirrorCamera)
    }

    // MARK: Recording

    func toggleRecording() {
        guard !isProcessing, countdown == nil else { return }
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            engine.resume()
            segmentStart = Date()
            isPaused = false
        } else {
            engine.pause()
            accumulated += Date().timeIntervalSince(segmentStart)
            isPaused = true
        }
    }

    func startRecording() async {
        guard !isRecording, !isProcessing, countdown == nil else { return }
        errorMessage = nil
        statusMessage = nil

        if audioMode.wantsMic {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                errorMessage = "Microphone access denied. Allow it in System Settings → Privacy & Security → Microphone."
                return
            }
        }

        for n in [3, 2, 1] {
            countdown = n
            hud.show(n)
            NSSound(named: NSSound.Name("Tink"))?.play()
            try? await Task.sleep(for: .seconds(1))
        }
        countdown = nil
        hud.hide()

        if highlightCursor { highlighter.start() }
        try? await Task.sleep(for: .milliseconds(300))

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                throw RecorderError.message("No display found.")
            }
            let keep = Set([bubble.windowNumber, highlighter.windowNumber].compactMap { $0 }.map { CGWindowID($0) })
            let me = Bundle.main.bundleIdentifier
            let excluded = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == me && !keep.contains($0.windowID)
            }
            let settings = CaptureSettings(display: display, audio: audioMode, micDeviceID: selectedMicID,
                                           outputWidth: resolutionWidth, fps: fps, excludedWindows: excluded)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("TeachStudio-\(UUID().uuidString).mov")
            try await engine.start(settings, to: tmp)
            tempURL = tmp

            isRecording = true
            isPaused = false
            accumulated = 0
            segmentStart = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            controlWindow?.orderOut(nil)   // get the window out of your way
        } catch {
            highlighter.stop()
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        isProcessing = true
        statusMessage = "Finishing your recording…"
        highlighter.stop()
        showControlWindow()

        let tmp = tempURL
        do {
            try await engine.stop()
            guard let tmp else { throw RecorderError.message("Temporary file missing.") }
            let out = outputURL()
            try await Finalizer.makeYouTubeReady(input: tmp, output: out)
            try? FileManager.default.removeItem(at: tmp)
            lastFile = out
            statusMessage = "Saved: \(out.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription + (tmp.map { " (raw recording kept at \($0.path))" } ?? "")
            statusMessage = nil
        }
        tempURL = nil
        isProcessing = false
    }

    private func handleStreamError(_ msg: String) {
        errorMessage = msg
        if isRecording { Task { await stopRecording() } }
    }

    private func tick() {
        elapsed = accumulated + (isPaused ? 0 : Date().timeIntervalSince(segmentStart))
    }

    private func outputURL() -> URL {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        var title = lectureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if title.isEmpty { title = "Lecture" }
        let base = "\(title) - \(df.string(from: Date()))"
        var url = saveFolder.appendingPathComponent("\(base).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = saveFolder.appendingPathComponent("\(base) (\(n)).mp4")
            n += 1
        }
        return url
    }

    // MARK: Windows & folders

    private var controlWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }

    func showControlWindow() {
        NSApp.activate()
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = saveFolder
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url { saveFolder = url }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Preferences

    private func loadPrefs() {
        let d = defaults
        if let v = d.string(forKey: "audioMode"), let m = AudioMode(rawValue: v) { audioMode = m }
        if d.object(forKey: "bubbleSize") != nil { bubbleSize = d.double(forKey: "bubbleSize") }
        if d.object(forKey: "ringWidth") != nil { ringWidth = d.double(forKey: "ringWidth") }
        if let v = d.string(forKey: "ring1") { ringColor1 = Color(hex: v) }
        if let v = d.string(forKey: "ring2") { ringColor2 = Color(hex: v) }
        if d.object(forKey: "useGradient") != nil { useGradient = d.bool(forKey: "useGradient") }
        if let v = d.string(forKey: "shape"), let s = BubbleShape(rawValue: v) { bubbleShape = s }
        if let v = d.string(forKey: "corner"), let c = Corner(rawValue: v) { corner = c }
        if d.object(forKey: "mirror") != nil { mirrorCamera = d.bool(forKey: "mirror") }
        if d.object(forKey: "resolution") != nil { resolutionWidth = d.integer(forKey: "resolution") }
        if d.object(forKey: "fps") != nil { fps = d.integer(forKey: "fps") }
        if d.object(forKey: "highlight") != nil { highlightCursor = d.bool(forKey: "highlight") }
        if let v = d.string(forKey: "folder") { saveFolder = URL(fileURLWithPath: v) }
    }

    private func savePrefs() {
        let d = defaults
        d.set(audioMode.rawValue, forKey: "audioMode")
        d.set(bubbleSize, forKey: "bubbleSize")
        d.set(ringWidth, forKey: "ringWidth")
        d.set(ringColor1.hex, forKey: "ring1")
        d.set(ringColor2.hex, forKey: "ring2")
        d.set(useGradient, forKey: "useGradient")
        d.set(bubbleShape.rawValue, forKey: "shape")
        d.set(corner.rawValue, forKey: "corner")
        d.set(mirrorCamera, forKey: "mirror")
        d.set(resolutionWidth, forKey: "resolution")
        d.set(fps, forKey: "fps")
        d.set(highlightCursor, forKey: "highlight")
        d.set(saveFolder.path, forKey: "folder")
    }
}
