import Foundation

/// Durable ownership of per-service DNS preferences. The helper serializes calls.
/// Save before changing a service: a crash at any later point can be recovered by
/// a fresh helper. Never restore over a user's subsequent preference change.
public struct PendingNetSystemDNS {
    public struct Entry: Codable, Equatable {
        public let original: Data?
        public let applied: Data
    }
    public struct Backend {
        public var services: () throws -> [String]
        public var read: (String) throws -> Data?
        public var write: (String, Data?, Data?) throws -> Void
        public var load: () throws -> Data?
        public var save: (Data?) throws -> Void
        public init(services: @escaping () throws -> [String], read: @escaping (String) throws -> Data?,
                    write: @escaping (String, Data?, Data?) throws -> Void,
                    load: @escaping () throws -> Data?, save: @escaping (Data?) throws -> Void) {
            self.services = services; self.read = read; self.write = write
            self.load = load; self.save = save
        }
    }
    public enum Failure: Error { case changedService(String), noServices, invalidJournal }
    public let backend: Backend
    public init(backend: Backend) { self.backend = backend }

    public static func loopbackConfiguration(from original: Data?) throws -> Data {
        var value: [String: Any] = [:]
        if let original {
            guard let decoded = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw Failure.invalidJournal
            }
            value = decoded
        }
        value["ServerAddresses"] = ["127.0.0.1"]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func journal() throws -> [String: Entry] {
        guard let data = try backend.load() else { return [:] }
        return try JSONDecoder().decode([String: Entry].self, from: data)
    }
    private func persist(_ entries: [String: Entry]) throws {
        try backend.save(entries.isEmpty ? nil : JSONEncoder().encode(entries))
    }
    private func addresses(_ data: Data?) throws -> [String]? {
        guard let data else { return nil }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["ServerAddresses"] as? [String]
    }
    private func restored(_ current: Data?, owned: Entry) throws -> Data? {
        if current == owned.applied { return owned.original }
        guard let current, var value = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
            throw Failure.invalidJournal
        }
        var original: [String: Any] = [:]
        if let data = owned.original {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.invalidJournal
            }
            original = decoded
        }
        value["ServerAddresses"] = original["ServerAddresses"]
        return value.isEmpty ? nil : try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// `ready` must verify the running engine's local DNS listener before any
    /// system preference is redirected. Existing ownership is reconciled after
    /// a helper restart without treating loopback as the original configuration.
    public func acquire(ready: () throws -> Void) throws {
        try ready()
        var entries = try journal()
        let services = try backend.services()
        guard !services.isEmpty else { throw Failure.noServices }
        do {
            for service in services {
                let current = try backend.read(service)
                if let owned = entries[service] {
                    guard try addresses(current) == addresses(owned.applied) else { throw Failure.changedService(service) }
                    continue
                }
                let applied = try Self.loopbackConfiguration(from: current)
                entries[service] = Entry(original: current, applied: applied)
                try persist(entries)
                try backend.write(service, current, applied)
                guard try backend.read(service) == applied else { throw Failure.changedService(service) }
            }
        } catch {
            // Retain the journal if restoration fails; never silently lose the
            // only copy of DHCP/static preferences after partial acquisition.
            do { try release() } catch let recovery {
                throw NSError(domain: "PendingNetSystemDNS", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "DNS接管失败：\(error)；恢复失败：\(recovery)"])
            }
            throw error
        }
    }

    public func release() throws {
        var entries = try journal()
        for service in entries.keys.sorted() {
            guard let owned = entries[service] else { continue }
            let current = try backend.read(service)
            if try addresses(current) == addresses(owned.applied) {
                let previous = try restored(current, owned: owned)
                try backend.write(service, current, previous)
                guard try backend.read(service) == previous else { throw Failure.changedService(service) }
            }
            // A different preference belongs to its current editor. Leave it.
            entries.removeValue(forKey: service)
            try persist(entries)
        }
    }
}
