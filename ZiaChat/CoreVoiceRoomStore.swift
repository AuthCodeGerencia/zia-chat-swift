import AVFoundation
import Combine
import Foundation
import LiveKit

struct CoreVoiceParticipant: Identifiable, Equatable {
    var id: String
    var name: String
    var isLocal: Bool
    var isMuted: Bool
    var isSpeaking: Bool
}

enum CoreVoiceConnectionState: Equatable {
    case disconnected
    case requestingAccess
    case connecting
    case connected
    case reconnecting
}

enum CoreVoiceError: LocalizedError {
    case invalidAppURL
    case microphoneDenied
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidAppURL:
            return "The ZiaChat server URL is invalid."
        case .microphoneDenied:
            return "Microphone access is required to join a voice channel."
        case .invalidResponse:
            return "The voice server returned an invalid response."
        case .server(let message):
            return message
        }
    }
}

private struct CoreVoiceTokenResponse: Decodable {
    var ok: Bool
    var serverURL: String
    var token: String
    var room: String
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case serverURL = "serverUrl"
        case token
        case room
        case error
    }
}

private struct CoreVoiceTokenErrorResponse: Decodable {
    var error: String?
}

@MainActor
final class CoreVoiceRoomStore: NSObject, ObservableObject, RoomDelegate, @unchecked Sendable {
    @Published private(set) var connectionState: CoreVoiceConnectionState = .disconnected
    @Published private(set) var participants: [CoreVoiceParticipant] = []
    @Published private(set) var connectedChannel: CoreChannel?
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerEnabled = true
    @Published var lastError: String?

    private var room: Room?

    var isConnected: Bool {
        connectionState == .connected || connectionState == .reconnecting
    }

    func join(channel: CoreChannel, configuration: CoreAppConfiguration) async {
        guard channel.isVoice else { return }
        if connectedChannel?.id == channel.id, isConnected { return }

        await leave()
        connectionState = .requestingAccess
        lastError = nil

        do {
            guard await requestMicrophoneAccess() else {
                throw CoreVoiceError.microphoneDenied
            }

            connectionState = .connecting
            let session = try await fetchToken(channelId: channel.id, configuration: configuration)
            let room = Room(delegate: self)
            self.room = room
            connectedChannel = channel

            AudioManager.shared.isSpeakerOutputPreferred = isSpeakerEnabled
            try await room.connect(url: session.serverURL, token: session.token)
            try await room.localParticipant.setMicrophone(enabled: true)

            isMuted = false
            connectionState = .connected
            refreshParticipants(room)
        } catch {
            if let room {
                await room.disconnect()
            }
            room = nil
            connectedChannel = nil
            participants = []
            connectionState = .disconnected
            lastError = error.localizedDescription
        }
    }

    func leave() async {
        let activeRoom = room
        room = nil
        connectedChannel = nil
        participants = []
        isMuted = false
        connectionState = .disconnected
        if let activeRoom {
            await activeRoom.disconnect()
        }
    }

    func toggleMute() async {
        guard let room, isConnected else { return }
        let nextMuted = !isMuted
        do {
            try await room.localParticipant.setMicrophone(enabled: !nextMuted)
            isMuted = nextMuted
            refreshParticipants(room)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleSpeaker() {
        isSpeakerEnabled.toggle()
        AudioManager.shared.isSpeakerOutputPreferred = isSpeakerEnabled
    }

    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState connectionState: LiveKit.ConnectionState,
        from oldConnectionState: LiveKit.ConnectionState
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            switch connectionState {
            case .connecting:
                self.connectionState = .connecting
            case .connected:
                self.connectionState = .connected
            case .reconnecting:
                self.connectionState = .reconnecting
            case .disconnecting, .disconnected:
                self.connectionState = .disconnected
            @unknown default:
                break
            }
            self.refreshParticipants(room)
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            self?.refreshParticipants(room)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            self?.refreshParticipants(room)
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in
            self?.refreshParticipants(room)
        }
    }

    nonisolated func room(
        _ room: Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didUpdateIsMuted isMuted: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.refreshParticipants(room)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.room = nil
            self.connectedChannel = nil
            self.participants = []
            self.connectionState = .disconnected
            if let error {
                self.lastError = error.localizedDescription
            }
        }
    }

    private func refreshParticipants(_ room: Room) {
        let local = room.localParticipant
        var next = [
            participantRow(
                local,
                isLocal: true,
                fallbackName: "You",
                mutedOverride: isMuted
            )
        ]

        next.append(contentsOf: room.remoteParticipants.values.map {
            participantRow($0, isLocal: false, fallbackName: "Participant")
        })
        participants = next.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            if $0.isSpeaking != $1.isSpeaking { return $0.isSpeaking }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func participantRow(
        _ participant: Participant,
        isLocal: Bool,
        fallbackName: String,
        mutedOverride: Bool? = nil
    ) -> CoreVoiceParticipant {
        CoreVoiceParticipant(
            id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString,
            name: participant.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? fallbackName,
            isLocal: isLocal,
            isMuted: mutedOverride ?? !participant.isMicrophoneEnabled(),
            isSpeaking: participant.isSpeaking
        )
    }

    private func requestMicrophoneAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    private func fetchToken(
        channelId: String,
        configuration: CoreAppConfiguration
    ) async throws -> CoreVoiceTokenResponse {
        let environment = CoreEnvironment.load()
        guard let baseURL = URL(string: environment.appURL),
              let url = URL(string: "/api/core/voice-token", relativeTo: baseURL) else {
            throw CoreVoiceError.invalidAppURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["channelId": channelId])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoreVoiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let payload = try? JSONDecoder().decode(CoreVoiceTokenErrorResponse.self, from: data)
            throw CoreVoiceError.server(payload?.error ?? "Unable to join the voice channel.")
        }

        let payload = try JSONDecoder().decode(CoreVoiceTokenResponse.self, from: data)
        guard payload.ok, !payload.serverURL.isEmpty, !payload.token.isEmpty else {
            throw CoreVoiceError.server(payload.error ?? "Unable to join the voice channel.")
        }
        return payload
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
