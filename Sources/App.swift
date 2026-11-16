import SwiftUI

@main
struct TeachStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Teach Studio") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.isRecording
                  ? (model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                  : "record.circle")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button(model.isRecording ? "Stop Recording  (⌃⌥R)" : "Start Recording  (⌃⌥R)") {
            model.toggleRecording()
        }
        Button(model.isPaused ? "Resume  (⌃⌥P)" : "Pause  (⌃⌥P)") {
            model.togglePause()
        }
        .disabled(!model.isRecording)

        Divider()

        Button(model.cameraOn ? "Hide Webcam  (⌃⌥C)" : "Show Webcam  (⌃⌥C)") {
            model.setCameraOn(!model.cameraOn)
        }
        Button("Show Window") { model.showControlWindow() }

        Divider()

        Button("Quit Teach Studio") { NSApp.terminate(nil) }
    }
}
