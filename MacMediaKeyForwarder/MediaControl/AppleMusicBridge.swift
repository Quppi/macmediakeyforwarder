import ScriptingBridge

// MARK: - ScriptingBridge Protocol

@objc private protocol MusicApplication {
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func backTrack()
    @objc optional func fastForward()
    @objc optional func rewind()
    @objc optional func resume()
}

extension SBApplication: MusicApplication {}

// MARK: - Apple Music Bridge

/// ScriptingBridge wrapper for Apple Music (com.apple.Music).
final class AppleMusicBridge {

    private static let bundleID = "com.apple.Music"

    private var app: (any MusicApplication)? {
        SBApplication(bundleIdentifier: Self.bundleID)
    }

    var isRunning: Bool {
        (app as? SBApplication)?.isRunning ?? false
    }

    func playPause() {
        app?.playpause?()
    }

    func nextTrack() {
        app?.nextTrack?()
    }

    func backTrack() {
        app?.backTrack?()
    }

    func fastForward() {
        app?.fastForward?()
    }

    func rewind() {
        app?.rewind?()
    }

    func resume() {
        app?.resume?()
    }
}
