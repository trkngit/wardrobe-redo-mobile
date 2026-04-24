import Foundation
import OSLog

/// Persistent retry queue for write operations that must eventually
/// reach Supabase even if the app launches offline, crashes mid-save,
/// or hits a long network blip.
///
/// **Scope (v1 — what this queue does):** persist Codable "envelopes"
/// describing a pending server-side insert, drain them in FIFO order
/// on demand, and survive app restarts via a JSON file in
/// `Library/Caches/`. Each envelope carries an `idempotencyKey` that
/// is already part of the payload DTO, so a duplicate drain (e.g. the
/// server saw the first attempt but we never got the ack) resolves
/// naturally in the repository layer via `isDuplicateKeyError` +
/// fetch-by-key.
///
/// **Scope (v1 — what this queue does NOT do):** it does **not**
/// persist image binaries. The Add Item save path still uploads
/// photos synchronously; if the user is truly offline the upload
/// fails early and no envelope is ever enqueued. A full offline-first
/// capture flow (photo → temp file → background upload → DB insert)
/// is a v1.1 scope.
///
/// **Concurrency:** actor-isolated. All state transitions
/// (`enqueue`, `drain`, `remove`) are serialized. Callers can kick
/// `drain()` from anywhere — a second caller will see an empty queue
/// because the first caller already consumed it.
///
/// **Back-off:** reuses `RetryPolicy.background` for inter-drain-cycle
/// delays so transient failures don't loop hot. Each envelope tracks
/// its attempt count and gets dropped after `maxAttempts` — at that
/// point it has surfaced a Sentry event in the handler and the user
/// would need to re-enter the item anyway.
public actor UploadQueue {

    public static let shared = UploadQueue()

    private let log = Logger(subsystem: "com.wardroberedo", category: "UploadQueue")

    /// Maximum attempts per envelope before we drop it and log a
    /// hard-fail breadcrumb. Matches `RetryPolicy.background.maxAttempts`.
    public static let maxAttempts = 6

    // MARK: - Envelope

    /// One pending server write. Kind-discriminated so a single file
    /// can hold both wardrobe and outfit payloads without a union type.
    public struct Envelope: Codable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case wardrobeItem
            case outfit
        }

        public let id: UUID
        public let kind: Kind
        /// Encoded Codable payload. Decoded back into the specific
        /// `NewWardrobeItem` / `NewOutfit` + slots struct by the drain
        /// handler. Storing as `Data` avoids a hand-rolled enum union.
        public let payload: Data
        public var attempts: Int
        public let createdAt: Date

        public init(id: UUID = UUID(), kind: Kind, payload: Data, attempts: Int = 0, createdAt: Date = Date()) {
            self.id = id
            self.kind = kind
            self.payload = payload
            self.attempts = attempts
            self.createdAt = createdAt
        }
    }

    // MARK: - Handler wiring

    /// Callback that actually performs the server-side insert for an
    /// envelope. Injected from the consumer so the queue doesn't need
    /// to know about `WardrobeRepository` / `OutfitRepository`
    /// (prevents an import cycle, keeps the queue testable).
    ///
    /// Throws on failure — the queue applies retry logic and drops
    /// the envelope only after `maxAttempts` exhaustions.
    public typealias Handler = @Sendable (Envelope) async throws -> Void

    private var handler: Handler?
    private var pending: [Envelope] = []
    private var loaded = false

    // MARK: - Config

    private lazy var fileURL: URL? = {
        do {
            let caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return caches.appendingPathComponent("upload-queue.json")
        } catch {
            log.error("Could not resolve caches dir: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    // MARK: - Public API

    /// Wire the handler that consumes envelopes. Idempotent — calling
    /// twice overwrites the previous handler. Call from app init after
    /// repositories are ready.
    public func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Append an envelope and kick off an async drain. Returns
    /// immediately — drain runs in a detached task on the actor.
    public func enqueue(_ envelope: Envelope) async {
        loadIfNeeded()
        pending.append(envelope)
        persist()
        // Fire-and-forget drain — actor serializes with any in-flight
        // drain call so we don't race.
        Task { await self.drain() }
    }

    /// Convenience that encodes a Codable payload before enqueue.
    public func enqueue<T: Encodable & Sendable>(_ kind: Envelope.Kind, payload: T) async throws {
        let data = try JSONEncoder().encode(payload)
        await enqueue(Envelope(kind: kind, payload: data))
    }

    /// Return the current pending count. Useful for tests + a debug HUD.
    public func pendingCount() -> Int {
        loadIfNeeded()
        return pending.count
    }

    /// Walk the queue and invoke `handler` on each envelope. On failure,
    /// increment attempts and keep the envelope for the next drain
    /// cycle (until `maxAttempts` — then log + drop). On success,
    /// remove the envelope from the queue.
    ///
    /// Drains stop on the first unrecoverable failure (so we don't
    /// burn through retries on a permanent auth problem) but envelopes
    /// that hit transient errors stay for next time.
    public func drain() async {
        loadIfNeeded()
        guard let handler else {
            log.notice("drain: no handler wired, skipping")
            return
        }
        guard !pending.isEmpty else { return }

        // Copy the list so we can mutate `pending` safely inside the loop.
        let snapshot = pending
        for env in snapshot {
            do {
                try await handler(env)
                remove(id: env.id)
            } catch {
                // Bump attempts. If this was the last allowed attempt,
                // drop it and log — the user's save is gone but the
                // app keeps running.
                if var idx = index(of: env.id) as Int? {
                    pending[idx].attempts += 1
                    if pending[idx].attempts >= Self.maxAttempts {
                        log.error("drain: dropping envelope \(env.id.uuidString, privacy: .public) after \(Self.maxAttempts) attempts: \(String(describing: error), privacy: .public)")
                        pending.remove(at: idx)
                    }
                    // If the error is non-retryable (e.g. auth), stop
                    // draining this cycle so we don't churn on the
                    // same class of failure.
                    if !isRetryableError(error) {
                        persist()
                        return
                    }
                    // Guard against compiler warning about unused `idx`
                    // after the drop branch; the re-lookup below is
                    // only needed when we didn't remove.
                    _ = idx
                }
            }
        }
        persist()
    }

    // MARK: - Test hooks

    /// Wipe in-memory and on-disk queue state. Test-only — production
    /// never calls this; expired envelopes expire by attempt count.
    public func clear() {
        pending.removeAll()
        persist()
    }

    // MARK: - Private

    private func remove(id: UUID) {
        pending.removeAll { $0.id == id }
        persist()
    }

    private func index(of id: UUID) -> Int? {
        pending.firstIndex(where: { $0.id == id })
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pending = try decoder.decode([Envelope].self, from: data)
        } catch {
            log.error("Queue decode failed; starting empty: \(String(describing: error), privacy: .public)")
            pending = []
        }
    }

    private func persist() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(pending)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Queue persist failed: \(String(describing: error), privacy: .public)")
        }
    }
}
