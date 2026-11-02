import Foundation

/// Notices messages added to chat.db and reports them in row order.
///
/// Messages.app writes new rows to `chat.db-wal`, so a file watcher on it
/// triggers a check shortly after each write. A slower poll backs it up,
/// because file events can be missed when SQLite recreates the WAL file.
/// Each check reads rows above the last row seen (the cursor), so nothing is
/// reported twice and nothing between checks is skipped.
public final class MessageWatcher: @unchecked Sendable {
    public struct Options: Sendable {
        /// Wait after a file event before reading, so a burst of writes is read once.
        public var delay: TimeInterval = 0.75
        public var pollInterval: TimeInterval = 5
        /// Most messages reported by one check. When more arrived (say, after
        /// the Mac slept), only the newest are reported.
        public var maxBatch = 100
        /// Messages older than this are not reported, so history synced from
        /// iCloud or another device doesn't look new.
        public var maxAge: TimeInterval = 3600

        public init() {}
    }

    public let dbPath: String
    public let options: Options
    private let queue = DispatchQueue(label: "imessage-bridge.watcher")
    private let onMessages: @Sendable ([Message]) -> Void
    private let onCursor: @Sendable (Int64) -> Void
    private var cursor: Int64?
    private var db: MessagesDB?
    private var fileSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var checkScheduled = false
    private var running = false
    private var _lastError: String?

    /// - Parameters:
    ///   - cursor: the last row reported before, or nil to start from the newest row.
    ///   - onMessages: new messages, oldest first. Called on the watcher's queue.
    ///   - onCursor: the new cursor after each check that moved it; save it to resume later.
    public init(dbPath: String = MessagesDB.defaultPath, cursor: Int64?, options: Options = Options(),
                onMessages: @escaping @Sendable ([Message]) -> Void,
                onCursor: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.dbPath = dbPath
        self.cursor = cursor
        self.options = options
        self.onMessages = onMessages
        self.onCursor = onCursor
    }

    /// Why the last check failed (usually missing Full Disk Access), or nil.
    public var lastError: String? { queue.sync { _lastError } }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + options.pollInterval, repeating: options.pollInterval)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if self.fileSource == nil { self.watchFile() }
                self.check()
            }
            t.resume()
            timer = t
            watchFile()
            check()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            fileSource?.cancel()
            fileSource = nil
            db = nil
        }
    }

    /// Reads new rows now. Blocks until done; for tests and manual refreshes.
    public func checkNow() {
        queue.sync { check() }
    }

    private func watchFile() {
        let fd = open(dbPath + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                // The WAL file was replaced; the poll timer watches the new one.
                src.cancel()
                self.fileSource = nil
            }
            self.scheduleCheck()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    private func scheduleCheck() {
        guard running, !checkScheduled else { return }
        checkScheduled = true
        queue.asyncAfter(deadline: .now() + options.delay) { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.check()
        }
    }

    private func check() {
        do {
            if db == nil { db = try MessagesDB(path: dbPath) }
            guard let db else { return }
            let newest = try db.maxMessageRowID()
            _lastError = nil
            guard let from = cursor else {
                move(to: newest)
                return
            }
            if newest < from {
                // The database was replaced or restored; start over from its newest row.
                move(to: newest)
                return
            }
            guard newest > from else { return }
            let cutoff = Date().addingTimeInterval(-options.maxAge)
            let msgs = try db.messages(afterRowID: from, through: newest, limit: options.maxBatch)
                .filter { $0.date >= cutoff }
            move(to: newest)
            if !msgs.isEmpty { onMessages(msgs) }
        } catch {
            db = nil   // reopen next time
            _lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func move(to row: Int64) {
        guard row != cursor else { return }
        cursor = row
        onCursor(row)
    }
}

/// Recently arrived messages, shared by everything that delivers events.
/// Keeps the last few hundred so a stream that reconnects can catch up.
public final class MessageFeed: @unchecked Sendable {
    public typealias Handler = @Sendable ([Message]) -> Void

    private let lock = NSLock()
    private let capacity: Int
    private var recent: [Message] = []
    private var handlers: [UUID: Handler] = [:]

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    /// Adds messages and passes them to every subscriber.
    public func publish(_ msgs: [Message]) {
        guard !msgs.isEmpty else { return }
        lock.lock()
        recent.append(contentsOf: msgs)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        let hs = Array(handlers.values)
        lock.unlock()
        for h in hs { h(msgs) }
    }

    /// Calls `handler` with each future batch, on the publisher's thread.
    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    /// Buffered messages above `rowID`, oldest first.
    public func messages(afterRowID rowID: Int64) -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        return recent.filter { $0.rowID > rowID }
    }
}
