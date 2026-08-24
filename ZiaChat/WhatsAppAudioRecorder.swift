import AVFoundation
import Combine
import Foundation

@MainActor
final class WhatsAppAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?

    func start() async throws {
        guard !isRecording else { return }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else { throw WhatsAppAudioRecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zia-whatsapp-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw WhatsAppAudioRecorderError.couldNotStart }

        self.recorder = recorder
        outputURL = url
        duration = 0
        isRecording = true
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(updateDuration),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() throws -> URL {
        guard let recorder, let outputURL else { throw WhatsAppAudioRecorderError.noRecording }
        recorder.stop()
        finishSession()
        return outputURL
    }

    func cancel() {
        recorder?.stop()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        finishSession()
    }

    private func finishSession() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        outputURL = nil
        isRecording = false
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func updateDuration() {
        duration = recorder?.currentTime ?? 0
    }
}

enum WhatsAppAudioRecorderError: LocalizedError {
    case permissionDenied
    case couldNotStart
    case noRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Activa el acceso al micrófono para grabar una nota de voz."
        case .couldNotStart: return "No se pudo iniciar la grabación."
        case .noRecording: return "No hay una grabación lista para enviar."
        }
    }
}
