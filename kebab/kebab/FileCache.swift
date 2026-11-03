//
//  FileCache.swift
//  kebab
//
//  Downloaded file originals, on disk in Caches. Keyed by storage path, never by
//  signed URL, because a signed URL changes every time it's made. Each file sits
//  in its own folder under its original name, so Quick Look and the share sheet
//  show that name rather than a hash.
//

import CryptoKit
import Foundation

nonisolated final class FileCache: Sendable {

    static let shared = FileCache(
        directory: FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kebab-files", isDirectory: true)
    )

    static let defaultCapacity: Int64 = 500 * 1024 * 1024

    private let directory: URL
    private let capacity: Int64

    init(directory: URL, capacity: Int64 = FileCache.defaultCapacity) {
        self.directory = directory
        self.capacity = capacity
    }

    /// The cached original for a path, marked as just used.
    func cachedURL(forPath path: String) -> URL? {
        guard let file = fileInFolder(folder(forPath: path)) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    /// Moves a file into the cache under `path` and evicts down to the cap.
    @discardableResult
    func adopt(_ source: URL, path: String, name: String) throws -> URL {
        let folder = folder(forPath: path)
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // The name came from someone's filesystem, so it can't choose a folder.
        let safeName = (name as NSString).lastPathComponent
        let destination = folder.appendingPathComponent(safeName.isEmpty ? "file" : safeName)
        try manager.moveItem(at: source, to: destination)
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        enforceCapacity()
        return destination
    }

    func evict(path: String) {
        try? FileManager.default.removeItem(at: folder(forPath: path))
    }

    /// On sign-out, alongside the image cache purge.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    struct Item: Equatable {
        let key: String
        let size: Int64
        let lastUsed: Date
    }

    /// Which items to drop to fit the cap: least recently used first.
    static func evictionPlan(_ items: [Item], capacity: Int64) -> [String] {
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        var doomed: [String] = []
        for item in items.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > capacity else { break }
            total -= item.size
            doomed.append(item.key)
        }
        return doomed
    }

    private func enforceCapacity() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let items: [Item] = folders.compactMap { folder in
            guard let file = fileInFolder(folder),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return nil }
            return Item(
                key: folder.lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                lastUsed: values.contentModificationDate ?? .distantPast
            )
        }
        for key in Self.evictionPlan(items, capacity: capacity) {
            try? manager.removeItem(at: directory.appendingPathComponent(key, isDirectory: true))
        }
    }

    private func folder(forPath path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true)
    }

    private func fileInFolder(_ folder: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first
    }
}
