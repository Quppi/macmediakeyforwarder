import Cocoa
import ScriptingBridge

// MARK: - ScriptingBridge Protocol

@objc private protocol SpotifyApplication {
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
}

extension SBApplication: SpotifyApplication {}

// MARK: - Spotify Bridge

/// ScriptingBridge wrapper for Spotify (com.spotify.client).
final class SpotifyBridge {

    private static let bundleID = "com.spotify.client"

    private lazy var app: (any SpotifyApplication)? = {
        SBApplication(bundleIdentifier: Self.bundleID)
    }()

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    func playPause() {
        app?.playpause?()
    }

    func nextTrack() {
        app?.nextTrack?()
    }

    func previousTrack() {
        app?.previousTrack?()
    }
}
