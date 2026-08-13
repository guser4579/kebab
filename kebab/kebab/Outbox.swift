//
//  Outbox.swift
//  kebab
//

import Foundation
import UIKit

/// An entry composed on-device that hasn't reached the server yet.
///
/// `id` is client-generated and becomes the entry's server id on sync, which
/// makes retries idempotent: if a previous attempt actually landed before the
/// connection dropped, the duplicate-key rejection is treated as success.
struct PendingEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let content: String
    let collectionId: UUID?
    let imageFilenames: [String]
    let createdAt: Date
    var attempts: Int = 0
    /// True after repeated server rejections (not mere connectivity loss);
    /// surfaces the tappable warning state in the feed.
    var failed: Bool = false
}

/// File-backed outbox: one JSON per pending entry plus its image files.
/// Everything survives force-quit and reboot — the durability promise is
/// "nothing composed can be lost between your thumb and the server."
final class OutboxStore {

    private let directory: URL

    init() {
        directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("kebab-outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func loadAll() -> [PendingEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? decoder.decode(PendingEntry.self, from: $0) }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func enqueue(content: String, images: [UIImage], collectionId: UUID?) throws -> PendingEntry {
        let id = UUID()
        var filenames: [String] = []
        for (index, image) in images.enumerated() {
            let data = try ImageStorageRepository.jpegData(from: image)
            let filename = "\(id.uuidString)-\(index).jpg"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            filenames.append(filename)
        }
        let pending = PendingEntry(
            id: id,
            content: content,
            collectionId: collectionId,
            imageFilenames: filenames,
            createdAt: Date()
        )
        try persist(pending)
        return pending
    }

    func update(_ pending: PendingEntry) {
        try? persist(pending)
    }

    func remove(_ pending: PendingEntry) {
        try? FileManager.default.removeItem(at: jsonURL(for: pending.id))
        for filename in pending.imageFilenames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        }
    }

    func loadImages(for pending: PendingEntry) -> [UIImage] {
        pending.imageFilenames.compactMap { filename in
            (try? Data(contentsOf: directory.appendingPathComponent(filename)))
                .flatMap(UIImage.init(data:))
        }
    }

    /// file:// URL for a pending image — CachedAsyncImage renders these
    /// directly, so offline entries show their photos at full parity.
    func imageURL(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    private func persist(_ pending: PendingEntry) throws {
        let data = try encoder.encode(pending)
        try data.write(to: jsonURL(for: pending.id), options: .atomic)
    }

    private func jsonURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
