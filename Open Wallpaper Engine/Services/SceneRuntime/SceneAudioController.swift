//
//  SceneAudioController.swift
//  Open Wallpaper Engine
//
//  Plays audio embedded in Wallpaper Engine scene packages.
//

import AVFoundation
import Foundation

protocol SceneAudioPlayerProtocol: AnyObject {
    var numberOfLoops: Int { get set }
    var enableRate: Bool { get set }
    var volume: Float { get set }
    var rate: Float { get set }
    var isPlaying: Bool { get }

    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: SceneAudioPlayerProtocol {}

struct SceneAudioPlaybackState: Equatable {
    var playRate: Float
    var volume: Float
    var isSleeping: Bool

    var shouldPlayAudio: Bool {
        playRate > 0 && !isSleeping
    }

    var shouldAnimateScene: Bool {
        playRate > 0 && !isSleeping
    }

    var effectivePlayerRate: Float {
        min(max(playRate, 0.5), 2)
    }

    var effectiveVolume: Float {
        min(max(volume, 0), 1)
    }
}

final class SceneAudioCoordinator {
    typealias PlayerFactory = (Data) throws -> any SceneAudioPlayerProtocol

    static let shared = SceneAudioCoordinator()

    private final class Session {
        let player: any SceneAudioPlayerProtocol
        var clientStates: [UUID: SceneAudioPlaybackState]

        init(
            player: any SceneAudioPlayerProtocol,
            clientID: UUID,
            state: SceneAudioPlaybackState
        ) {
            self.player = player
            self.clientStates = [clientID: state]
        }
    }

    private let playerFactory: PlayerFactory
    private var sessions: [String: Session] = [:]

    init(
        playerFactory: @escaping PlayerFactory = {
            try AVAudioPlayer(data: $0)
        }
    ) {
        self.playerFactory = playerFactory
    }

    var sessionCount: Int {
        sessions.count
    }

    func clientCount(for sourceKey: String) -> Int {
        sessions[sourceKey]?.clientStates.count ?? 0
    }

    @discardableResult
    func attach(
        clientID: UUID,
        sourceKey: String,
        data: Data?,
        state: SceneAudioPlaybackState
    ) -> Bool {
        if let session = sessions[sourceKey] {
            session.clientStates[clientID] = state
            applyPlaybackState(to: session)
            return true
        }

        guard let data, !data.isEmpty else { return false }

        do {
            let player = try playerFactory(data)
            player.numberOfLoops = -1
            player.enableRate = true
            _ = player.prepareToPlay()

            let session = Session(
                player: player,
                clientID: clientID,
                state: state
            )
            sessions[sourceKey] = session
            applyPlaybackState(to: session)
            return true
        } catch {
            NSLog("[SceneAudio] Failed to decode packaged audio: %@", "\(error)")
            return false
        }
    }

    func update(
        clientID: UUID,
        sourceKey: String,
        state: SceneAudioPlaybackState
    ) {
        guard let session = sessions[sourceKey],
              session.clientStates[clientID] != nil
        else {
            return
        }

        session.clientStates[clientID] = state
        applyPlaybackState(to: session)
    }

    func detach(clientID: UUID, sourceKey: String) {
        guard let session = sessions[sourceKey] else { return }
        session.clientStates.removeValue(forKey: clientID)

        if session.clientStates.isEmpty {
            session.player.stop()
            sessions.removeValue(forKey: sourceKey)
        } else {
            applyPlaybackState(to: session)
        }
    }

    func contains(clientID: UUID, sourceKey: String) -> Bool {
        sessions[sourceKey]?.clientStates[clientID] != nil
    }

    private func applyPlaybackState(to session: Session) {
        let states = Array(session.clientStates.values)
        let activeState = states.first(where: \.shouldPlayAudio)
        let representativeState = activeState ?? states.first

        session.player.volume = states.map(\.effectiveVolume).max() ?? 0
        session.player.rate = representativeState?.effectivePlayerRate ?? 1

        if activeState != nil {
            if !session.player.isPlaying {
                _ = session.player.play()
            }
        } else if session.player.isPlaying {
            session.player.pause()
        }
    }
}

final class SceneAudioController {
    private let coordinator: SceneAudioCoordinator
    private let clientID = UUID()
    private var sourceKey: String?

    private(set) var playbackState = SceneAudioPlaybackState(
        playRate: 1,
        volume: 1,
        isSleeping: false
    )

    init(coordinator: SceneAudioCoordinator = .shared) {
        self.coordinator = coordinator
    }

    var hasAudio: Bool {
        guard let sourceKey else { return false }
        return coordinator.contains(clientID: clientID, sourceKey: sourceKey)
    }

    func load(data: Data?) {
        load(sourceKey: "client-\(clientID.uuidString)", data: data)
    }

    func load(sourceKey: String, data: Data?) {
        stop()
        if coordinator.attach(
            clientID: clientID,
            sourceKey: sourceKey,
            data: data,
            state: playbackState
        ) {
            self.sourceKey = sourceKey
        }
    }

    func update(playRate: Float, volume: Float) {
        playbackState.playRate = playRate
        playbackState.volume = volume
        updateSharedSession()
    }

    func setSleeping(_ isSleeping: Bool) {
        playbackState.isSleeping = isSleeping
        updateSharedSession()
    }

    func stop() {
        guard let sourceKey else { return }
        coordinator.detach(clientID: clientID, sourceKey: sourceKey)
        self.sourceKey = nil
    }

    private func updateSharedSession() {
        guard let sourceKey else { return }
        coordinator.update(
            clientID: clientID,
            sourceKey: sourceKey,
            state: playbackState
        )
    }
}
