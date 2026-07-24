import AVFoundation
import Combine
import Foundation

enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case couldNotStart
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required. Open Noted once and allow microphone access before using the Action Button."
        case .couldNotStart:
            "Noted could not start recording."
        case .noActiveRecording:
            "There is no active recording."
        }
    }
}

struct RecordingResult: Sendable {
    var meetingID: UUID
    var filename: String
    var durationMilliseconds: Int
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    var onElapsed: ((TimeInterval) -> Void)?
    var onUnexpectedStop: ((Error?) -> Void)?

    private var recorder: AVAudioRecorder?
    private var meetingID: UUID?
    private var filename: String?
    private var timer: Timer?
    private let persistence: LocalPersistence

    init(persistence: LocalPersistence = .shared) {
        self.persistence = persistence
        super.init()
    }

    func start(meetingID: UUID) async throws -> String {
        guard !isRecording else {
            return filename ?? ""
        }
        guard await prepareMicrophoneAccess() else {
            throw RecordingError.microphonePermissionDenied
        }

#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif

        let url = try await persistence.newAudioURL(meetingID: meetingID)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
#if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw RecordingError.couldNotStart
        }

        self.recorder = recorder
        self.meetingID = meetingID
        self.filename = url.lastPathComponent
        self.elapsed = 0
        self.isRecording = true
        startTimer()
        return url.lastPathComponent
    }

    func stop() throws -> RecordingResult {
        guard let recorder, let meetingID, let filename else {
            throw RecordingError.noActiveRecording
        }

        let duration = recorder.currentTime
        timer?.invalidate()
        timer = nil
        recorder.stop()
        teardownAudioSession()

        self.recorder = nil
        self.meetingID = nil
        self.filename = nil
        self.elapsed = duration
        self.isRecording = false

        return RecordingResult(
            meetingID: meetingID,
            filename: filename,
            durationMilliseconds: max(0, Int((duration * 1_000).rounded()))
        )
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        isRecording = false
        teardownAudioSession()
        onUnexpectedStop?(flag ? nil : RecordingError.couldNotStart)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                self.onElapsed?(recorder.currentTime)
            }
        }
    }

    func prepareMicrophoneAccess() async -> Bool {
#if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
#else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
#endif
    }

    private func teardownAudioSession() {
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }
}
