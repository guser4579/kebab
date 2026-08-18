//
//  LocalStore.swift
//  kebab
//

import Foundation

/// Disk-backed JSON snapshots — the offline read layer. The feed and
/// collections lists are small (hundreds of rows), so whole-snapshot atomic
/// writes of the existing Codable models are simpler and more durable than a
/// database: no schema, no migrations, nothing to corrupt halfway.
///
/// Deliberately nonisolated: work runs on whatever thread calls it. Small
/// snapshots keep calling synchronously from the main actor; the search
/// corpus (unbounded) calls from detached tasks so its whole-corpus encodes
/// never touch the main thread.
nonisolated enum LocalStore {

    private static var directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("kebab-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Wipes every cached snapshot. Called when a session definitively ends:
    /// the feed and per-scope page caches are device-global (not keyed by
    /// user), so nothing from one account may survive into the next.
    static func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
