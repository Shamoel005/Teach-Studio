import SwiftUI
import AVFoundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private let resolutions: [(String, Int)] = [
        ("1080p (YouTube standard)", 1920),
        ("1440p", 2560),
        ("Native (largest file)", 0)
    ]
    private let presets: [(Color, Color)] = [
        (.red, .orange), (.blue, .cyan), (.purple, .pink), (.green, .yellow), (.white, .gray)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                lectureSection
                screenSection
                audioSection
                webcamSection
                toolsSection
                outputSection
            }
            .formStyle(.grouped)

            Divider()
            controlBar.padding(16)
        }
        .frame(minWidth: 540, minHeight: 560, idealHeight: 740)
    }

    // MARK: Sections

    private var lectureSection: some View {
        Section("Lecture") {
            TextField("Title (used as the file name)", text: $model.lectureTitle)
        }
    }

    private var screenSection: some View {
        Section("Screen") {
            Picker("Display", selection: $model.selectedDisplayID) {
                ForEach(model.displays, id: \.displayID) { d in
                    let name = Devices.screen(for: d.displayID)?.localizedName ?? "Display"
                    Text("\(name) (\(d.width)×\(d.height))").tag(d.displayID)
                }
            }
            Picker("Resolution", selection: $model.resolutionWidth) {
                ForEach(resolutions, id: \.1) { Text($0.0).tag($0.1) }
            }
            Picker("Frame rate", selection: $model.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Record", selection: $model.audioMode) {
                ForEach(AudioMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.audioMode.wantsMic {
                Picker("Microphone", selection: $model.selectedMicID) {
                    Text("System default").tag("")
                    ForEach(model.mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            if model.audioMode == .both {
                Text("Mic and system sound are mixed into one track automatically, ready for YouTube.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var webcamSection: some View {
        Section("Webcam bubble") {
            Toggle("Show webcam bubble", isOn: Binding(
                get: { model.cameraOn },
                set: { model.setCameraOn($0) }))

            if model.cameras.isEmpty {
                Text("No camera detected. Plug in a webcam and it will appear here automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("Camera", selection: Binding(
                    get: { model.selectedCameraID },
                    set: { model.selectCamera($0) })) {
                    Text("Auto (prefers an external webcam)").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }

            LabeledContent("Size") { Slider(value: $model.bubbleSize, in: 120...480) }
            LabeledContent("Border thickness") { Slider(value: $model.ringWidth, in: 0...24) }

            HStack {
                Text("Border style")
                Spacer()
                ForEach(presets.indices, id: \.self) { i in
                    Circle()
                        .fill(LinearGradient(colors: [presets[i].0, presets[i].1],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.4)))
                        .onTapGesture {
                            model.ringColor1 = presets[i].0
                            model.ringColor2 = presets[i].1
                            model.useGradient = true
                        }
                }
            }
            ColorPicker("Border color", selection: $model.ringColor1, supportsOpacity: false)
            Toggle("Gradient border", isOn: $model.useGradient)
            if model.useGradient {
                ColorPicker("Gradient second color", selection: $model.ringColor2, supportsOpacity: false)
            }

            Picker("Shape", selection: $model.bubbleShape) {
                ForEach(BubbleShape.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Mirror camera", isOn: $model.mirrorCamera)

            Picker("Snap to corner", selection: $model.corner) {
                ForEach(Corner.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: model.corner) { _, _ in model.snapBubble() }

            Text("Drag the bubble anywhere on screen. What you see is what gets recorded.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var toolsSection: some View {
        Section("Teaching tools") {
            Toggle("Highlight my cursor / pen while recording", isOn: $model.highlightCursor)
            Text("Hotkeys (work from any app):  ⌃⌥R start/stop   ⌃⌥P pause/resume   ⌃⌥C show/hide webcam")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        Section("Output") {
            HStack {
                Text(model.saveFolder.path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { model.chooseFolder() }
                Button("Open") { model.openFolder() }
            }
            Text("Saved as an .mp4 (H.264 + AAC) that you can upload to YouTube directly.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Control bar

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let n = model.countdown {
                    Text("Starting in \(n)…").font(.title3.bold())
                } else if model.isRecording {
                    Button { model.togglePause() } label: {
                        Label(model.isPaused ? "Resume" : "Pause",
                              systemImage: model.isPaused ? "play.fill" : "pause.fill")
                    }
                    .controlSize(.large)

                    Button { Task { await model.stopRecording() } } label: {
                        Label("Stop", systemImage: "stop.fill").frame(minWidth: 70)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)

                    Text(timeString(model.elapsed))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(model.isPaused ? Color.orange : Color.red)
                } else {
                    Button { Task { await model.startRecording() } } label: {
                        Label("Start Recording", systemImage: "record.circle").frame(minWidth: 150)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.isProcessing)
                }

                if model.isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                if let f = model.lastFile, !model.isRecording {
                    Button("Show in Finder") { model.reveal(f) }
                }
            }

            if let s = model.statusMessage {
                Text(s).font(.callout).foregroundStyle(.secondary)
            }
            if let e = model.errorMessage {
                Text(e).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
