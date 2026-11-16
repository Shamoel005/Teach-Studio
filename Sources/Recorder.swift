import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

enum AudioMode: String, CaseIterable, Identifiable {
    case system = "System audio"
    case microphone = "Microphone"
    case both = "Mic + System"
    case none = "No audio"

    var id: String { rawValue }
    var wantsSystem: Bool { self == .system || self == .both }
    var wantsMic: Bool { self == .microphone || self == .both }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

struct CaptureSettings {
    var display: SCDisplay
    var audio: AudioMode
    var micDeviceID: String
    var outputWidth: Int          // 0 = native
    var fps: Int
    var excludedWindows: [SCWindow]
}

/// Captures the screen + audio with ScreenCaptureKit and writes a temporary .mov.
/// Supports pause/resume and keeps video alive on a static screen (important when
/// you are mostly talking over a still slide / writing pad).
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "teachstudio.samples")
    private var heartbeat: DispatchSourceTimer?

    // State below is only touched on `queue`
    private var sessionStarted = false
    private var sessionStart = CMTime.zero
    private var paused = false
    private var pauseStart = CMTime.zero
    private var offset = CMTime.zero
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPTS = CMTime.zero   // original (host clock) timeline

    var onError: (@Sendable (String) -> Void)?

    // MARK: Start / stop

    func start(_ s: CaptureSettings, to url: URL) async throws {
        let display = s.display
        let pm = CGDisplayCopyDisplayMode(display.displayID)
        let nativeW = pm?.pixelWidth ?? display.width * 2
        let nativeH = pm?.pixelHeight ?? display.height * 2
        var w = s.outputWidth > 0 ? min(s.outputWidth, nativeW) : nativeW
        var h = Int((Double(w) * Double(nativeH) / Double(nativeW)).rounded())
        w -= w % 2
        h -= h % 2

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(s.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = s.audio.wantsSystem
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.captureMicrophone = s.audio.wantsMic            // macOS 15+
        if s.audio.wantsMic, !s.micDeviceID.isEmpty {
            config.microphoneCaptureDeviceID = s.micDeviceID
        }

        // Writer (temporary .mov, converted to a YouTube-ready .mp4 afterwards)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1) // crash-safe

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(w * h * s.fps) * 0.1),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: s.fps * 2,
                AVVideoExpectedSourceFrameRateKey: s.fps
            ]
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        var sysIn: AVAssetWriterInput?
        var micIn: AVAssetWriterInput?
        if s.audio.wantsSystem {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            sysIn = a
        }
        if s.audio.wantsMic {
            let m = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            m.expectsMediaDataInRealTime = true
            writer.add(m)
            micIn = m
        }
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.message("Could not start the video writer.")
        }

        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.systemInput = sysIn
            self.micInput = micIn
            self.sessionStarted = false
            self.paused = false
            self.offset = .zero
            self.lastVideoSample = nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: s.excludedWindows)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if s.audio.wantsSystem {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if s.audio.wantsMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
        startHeartbeat()
    }

    func stop() async throws {
        try? await stream?.stopCapture()
        stream = nil

        var started = false
        queue.sync {
            heartbeat?.cancel()
            heartbeat = nil
            started = sessionStarted
            if sessionStarted, !paused, let last = lastVideoSample {
                appendDuplicate(of: last, at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            lastVideoSample = nil
            videoInput?.markAsFinished()
            systemInput?.markAsFinished()
            micInput?.markAsFinished()
        }
        guard let w = writer else { return }
        defer {
            writer = nil
            videoInput = nil
            systemInput = nil
            micInput = nil
        }
        if !started {
            w.cancelWriting()
            throw RecorderError.message("No video frames were captured. Check that Screen Recording permission is allowed for this app.")
        }
        await w.finishWriting()
        if w.status == .failed {
            throw w.error ?? RecorderError.message("Recording failed while saving.")
        }
    }

    // MARK: Pause / resume

    func pause() {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            self.pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.offset = CMTimeAdd(self.offset, CMTimeSubtract(now, self.pauseStart))
            self.paused = false
        }
    }

    // MARK: Heartbeat (repeat last frame when the screen is static)

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.heartbeatTick() }
        t.resume()
        heartbeat = t
    }

    private func heartbeatTick() {
        guard sessionStarted, !paused, let last = lastVideoSample else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard CMTimeGetSeconds(CMTimeSubtract(now, lastVideoPTS)) >= 0.5 else { return }
        appendDuplicate(of: last, at: now)
    }

    private func appendDuplicate(of sb: CMSampleBuffer, at now: CMTime) {
        guard let v = videoInput, v.isReadyForMoreMediaData else { return }
        let target = CMTimeSubtract(now, offset)
        let shift = CMTimeSubtract(sb.presentationTimeStamp, target)
        if let dup = Self.shifted(sb, by: shift) {
            v.append(dup)
            lastVideoPTS = now
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, CMSampleBufferDataIsReady(sb), let writer, writer.status == .writing else { return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  CMSampleBufferGetImageBuffer(sb) != nil else { return }
            let pts = sb.presentationTimeStamp
            if !sessionStarted {
                sessionStart = pts
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
                lastVideoPTS = pts
            }
            if paused { return }
            lastVideoSample = sb
            lastVideoPTS = pts
            if let v = videoInput, v.isReadyForMoreMediaData, let out = Self.shifted(sb, by: offset) {
                v.append(out)
            }

        case .audio:
            appendAudio(sb, to: systemInput)

        case .microphone:
            appendAudio(sb, to: micInput)

        @unknown default:
            break
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, !paused, let input, input.isReadyForMoreMediaData else { return }
        if CMTimeCompare(sb.presentationTimeStamp, sessionStart) < 0 { return }
        if let out = Self.shifted(sb, by: offset) { input.append(out) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    // MARK: Helpers

    /// Returns a copy of the buffer with all timestamps moved earlier by `shift`.
    private static func shifted(_ sb: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(shift, .zero) == 0 { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in 0..<count {
            info[i].presentationTimeStamp = CMTimeSubtract(info[i].presentationTimeStamp, shift)
            if info[i].decodeTimeStamp.isValid {
                info[i].decodeTimeStamp = CMTimeSubtract(info[i].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sb,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &info,
                                              sampleBufferOut: &out)
        return out
    }
}

/// Turns the temporary .mov into a YouTube-ready .mp4:
/// video is copied untouched, and system audio + microphone are mixed into ONE AAC track
/// (YouTube only plays the first audio track of an upload).
enum Finalizer {
    static func makeYouTubeReady(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let vTrack = videoTracks.first else {
            throw RecorderError.message("The recording has no video track.")
        }
        let formats = try await vTrack.load(.formatDescriptions)

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        reader.add(vOut)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        writer.add(vIn)

        var aOut: AVAssetReaderAudioMixOutput?
        var aIn: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2
            ])
            reader.add(o)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            writer.add(i)
            aOut = o
            aIn = i
        }

        guard reader.startReading() else {
            throw reader.error ?? RecorderError.message("Could not read the recording.")
        }
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.message("Could not create the output file.")
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(vOut, into: vIn) }
            if let aOut, let aIn {
                group.addTask { await pump(aOut, into: aIn) }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? RecorderError.message("Could not finish the output file.")
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput) async {
        let q = DispatchQueue(label: "teachstudio.finalize.\(UUID().uuidString)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData {
                    if let buf = output.copyNextSampleBuffer() {
                        if !input.append(buf) {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                    } else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}
