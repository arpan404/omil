import Foundation

// MARK: - Keyboard link
//
// Lets the Omil keyboard drive dictation in the Omil app. Keyboard extensions
// have no microphone, so the app records: the keyboard opens the app once
// (omil://dictate), the app starts a mic session that keeps running in the
// background for a few minutes, and while it runs the keyboard starts and
// stops dictations without leaving the current app.
//
// Both sides share two small files in the App Group container and wake each
// other with Darwin notifications (which carry no data). The app writes the
// state and refreshes its heartbeat every second; a stale heartbeat means the
// app was suspended or quit, so the keyboard must open it again. Finished text
// still travels through ResultStore, so each result is inserted exactly once.

public enum KeyboardLink {
    public static let appGroupId = "group.sh.arpan.omil.shared"
    /// Opens the app and starts dictating for the keyboard.
    public static let dictateURL = URL(string: "omil://dictate")!
    /// Opens the app on the Mac pairing screen.
    public static let pairURL = URL(string: "omil://pair")!
    public static let stateChanged = "sh.arpan.omil.link.state"
    public static let commandPosted = "sh.arpan.omil.link.command"
    /// The heartbeat age after which the keyboard treats the app as gone.
    public static let heartbeatTimeout: TimeInterval = 4
    /// Commands older than this are ignored (e.g. one left over from a crash).
    public static let commandTimeout: TimeInterval = 10
}

/// What the app is doing for the keyboard.
public struct LinkState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No mic session: the keyboard must open the app to dictate.
        case off
        /// The mic session is running and waiting for the next dictation.
        case ready
        case starting
        case recording
        case processing
        case failed
    }

    public var phase: Phase
    /// When the mic session ends if nothing is dictated.
    public var sessionEnds: Date?
    public var recordingStarted: Date?
    /// Microphone level (0...1) while recording, for the keyboard's waveform.
    public var level: Double
    /// Live partial transcript while recording.
    public var draft: String
    /// A short, user-facing explanation when `phase == .failed`.
    public var message: String?
    /// The ResultStore session the keyboard should insert when it completes.
    public var sessionId: String?
    public var heartbeat: Date

    public init(phase: Phase = .off, sessionEnds: Date? = nil, recordingStarted: Date? = nil,
                level: Double = 0, draft: String = "", message: String? = nil,
                sessionId: String? = nil, heartbeat: Date = Date()) {
        self.phase = phase
        self.sessionEnds = sessionEnds
        self.recordingStarted = recordingStarted
        self.level = level
        self.draft = draft
        self.message = message
        self.sessionId = sessionId
        self.heartbeat = heartbeat
    }

    /// True when the app is running a mic session the keyboard can use.
    public func isLive(at now: Date = Date()) -> Bool {
        phase != .off && now.timeIntervalSince(heartbeat) < KeyboardLink.heartbeatTimeout
    }
}

/// A request from the keyboard to the app.
public struct LinkCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case start, stop, cancel, end
    }

    public var id: UUID
    public var kind: Kind
    public var issued: Date

    public init(_ kind: Kind, id: UUID = UUID(), issued: Date = Date()) {
        self.id = id
        self.kind = kind
        self.issued = issued
    }
}

/// App settings the keyboard needs (it can't read the app's own defaults).
public struct LinkSetup: Codable, Equatable, Sendable {
    public var paired: Bool
    public var macName: String?
    /// After inserting, switch back to the user's regular keyboard, so Omil
    /// works like a dictation key added to it.
    public var returnAfterInsert: Bool

    public init(paired: Bool, macName: String? = nil, returnAfterInsert: Bool = true) {
        self.paired = paired
        self.macName = macName
        self.returnAfterInsert = returnAfterInsert
    }
}

/// File-backed channel in the App Group container. Writes are atomic, so a
/// reader never sees half a file.
public final class LinkChannel: Sendable {
    private let directory: URL

    public init?(appGroupId: String = KeyboardLink.appGroupId) {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        self.directory = url.appendingPathComponent("KeyboardLink", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// For tests: any writable directory.
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var commandURL: URL { directory.appendingPathComponent("command.json") }
    private var setupURL: URL { directory.appendingPathComponent("setup.json") }

    // MARK: App side

    public func write(_ state: LinkState, notify: Bool = true) {
        save(state, to: stateURL)
        if notify { DarwinNotification.post(KeyboardLink.stateChanged) }
    }

    public func write(_ setup: LinkSetup) {
        guard readSetup() != setup else { return }
        save(setup, to: setupURL)
        DarwinNotification.post(KeyboardLink.stateChanged)
    }

    /// The latest command, if it's recent and differs from `lastHandled`.
    public func command(after lastHandled: UUID?, now: Date = Date()) -> LinkCommand? {
        guard let command: LinkCommand = load(commandURL),
              command.id != lastHandled,
              now.timeIntervalSince(command.issued) < KeyboardLink.commandTimeout else { return nil }
        return command
    }

    // MARK: Keyboard side

    public func readState() -> LinkState? { load(stateURL) }

    public func readSetup() -> LinkSetup? { load(setupURL) }

    public func send(_ command: LinkCommand) {
        save(command, to: commandURL)
        DarwinNotification.post(KeyboardLink.commandPosted)
    }

    // MARK: Files

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Darwin notifications

/// Cross-process wake-ups. They carry no payload; the receiver reads the
/// shared files.
public enum DarwinNotification {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Calls `handler` on the main queue each time `name` is posted, until released.
public final class DarwinObserver: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void

    public init(_ name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.handler() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil)
    }
}
