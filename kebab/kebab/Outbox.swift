//
//  Outbox.swift
//  kebab
//

import Foundation
import UIKit

/// A file staged for sending. Its bytes and thumbnail live in the outbox, next
/// to the pending JSON, so they keep the same durability promise as images.
/// `id` also names its Storage objects, which is what makes retries idempotent.
nonisolated struct PendingFile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let localFilename: String
    /// The original filename.
    let name: String
    let mime: String
    let size: Int64
    let kind: FileKind
    var thumbnailFilename: String? = nil
    var duration: Double? = nil
    var pageCount: Int? = nil
}

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
    /// Explicitly staged link (composer chip). Optional so entries queued by
    /// older builds still decode.
    var linkURL: String? = nil
    /// Optional so entries queued by older builds still decode.
    var files: [PendingFile]? = nil
    let createdAt: Date
    var attempts: Int = 0
    /// True after repeated server rejections (not mere connectivity loss);
    /// surfaces the tappable warning state in the feed.
    var failed: Bool = false
    /// The account that authored this entry. Optional so entries queued by
    /// older builds still decode (nil = legacy, pre-binding). The flush
    /// refuses to upload an item whose author differs from the signed-in
    /// user, so a queued entry can never post into another account even if
    /// the sign-out purge races an in-flight flush.
    var authorUserId: UUID? = nil
}

/// File-backed outbox: one JSON per pending entry plus its image files, with
/// attached files and their thumbnails in a `files` folder alongside.
/// Everything survives force-quit and reboot — the durability promise is
/// "nothing composed can be lost between your thumb and the server."
nonisolated final class OutboxStore: @unchecked Sendable {

    private let directory: URL

    private var filesDirectory: URL {
        directory.appendingPathComponent("files", isDirectory: true)
    }

    convenience init() {
        self.init(directory: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("kebab-outbox", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Unsent private drafts (and their staged JPEGs) must not travel to
        // iCloud/Finder backups: a restore onto another device could re-post
        // them, and they are cleartext personal content. They re-derive from
        // nothing — losing them on restore is the correct outcome.
        LocalStore.excludeFromBackup(directory)
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

    /// Stages pre-encoded images: attach time already produced upload-ready
    /// JPEG bytes, so send-time staging is just small file writes — no
    /// resize, no encode, no main-thread image work.
    /// Files were staged at attach time, so they're only referenced here.
    @MainActor
    func enqueue(content: String, images: [PendingImage], files: [PendingFile] = [], linkURL: String?, collectionId: UUID?, authorUserId: UUID?) throws -> PendingEntry {
        let id = UUID()
        var filenames: [String] = []
        for (index, image) in images.enumerated() {
            let filename = "\(id.uuidString)-\(index).jpg"
            try image.jpegData.write(to: directory.appendingPathComponent(filename), options: .atomic)
            filenames.append(filename)
            // Seed the shared cache under the pending file:// URL so the
            // pending row renders its photos straight from memory.
            ImageCache.insert(image.image, for: imageURL(for: filename))
        }
        let pending = PendingEntry(
            id: id,
            content: content,
            collectionId: collectionId,
            imageFilenames: filenames,
            linkURL: linkURL,
            files: files.isEmpty ? nil : files,
            createdAt: Date(),
            authorUserId: authorUserId
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
        for file in pending.files ?? [] {
            removeStaged(file)
        }
    }

    /// The staged bytes, exactly as written at enqueue — already resized and
    /// JPEG-encoded, i.e. the upload payload itself.
    func loadImageDatas(for pending: PendingEntry) -> [Data] {
        pending.imageFilenames.compactMap { filename in
            try? Data(contentsOf: directory.appendingPathComponent(filename))
        }
    }

    /// file:// URL for a pending image — CachedAsyncImage renders these
    /// directly, so offline entries show their photos at full parity.
    func imageURL(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    // MARK: Files

    /// Where a staged file's bytes live. The filename is `{id}.{ext}`, so the
    /// original name can't collide or reach outside the folder, and an attached
    /// `.json` can't be mistaken for a pending entry.
    func stagedFileURL(id: UUID, name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let base = filesDirectory.appendingPathComponent(id.uuidString)
        return ext.isEmpty ? base : base.appendingPathExtension(ext)
    }

    /// file:// URL of a staged file or thumbnail.
    func fileURL(for filename: String) -> URL {
        filesDirectory.appendingPathComponent(filename)
    }

    /// Copies into the outbox and returns the size. `copyItem` clones or streams,
    /// so a 50 MB file is never held in memory. The caller keeps any security
    /// scope open until this returns.
    func stageCopy(of source: URL, id: UUID, name: String) throws -> Int64 {
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let destination = stagedFileURL(id: id, name: name)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let failure = coordinationError ?? copyError { throw failure }
        return try fileSize(at: destination)
    }

    /// Size of a file already written to `stagedFileURL`.
    func adoptStaged(at url: URL, id: UUID, name: String) throws -> Int64 {
        try fileSize(at: url)
    }

    func prepareFilesDirectory() {
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    func writeThumbnail(_ jpeg: Data, id: UUID) throws -> String {
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let filename = "\(id.uuidString)-thumb.jpg"
        try jpeg.write(to: fileURL(for: filename), options: .atomic)
        return filename
    }

    func removeStaged(_ file: PendingFile) {
        try? FileManager.default.removeItem(at: fileURL(for: file.localFilename))
        if let thumbnail = file.thumbnailFilename {
            try? FileManager.default.removeItem(at: fileURL(for: thumbnail))
        }
    }

    /// Removes a file whose staging never finished, by its id prefix.
    func removeStaged(id: UUID) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: filesDirectory.path)) ?? []
        for name in names where name.hasPrefix(id.uuidString) {
            try? FileManager.default.removeItem(at: fileURL(for: name))
        }
    }

    /// A draft's staged files don't survive the process, because only the text
    /// and link are saved. Called at launch, before anything is staged, to clear
    /// what no queued entry refers to.
    func sweepOrphanedFiles(keeping pending: [PendingEntry]) {
        var referenced = Set<String>()
        for file in pending.flatMap({ $0.files ?? [] }) {
            referenced.insert(file.localFilename)
            if let thumbnail = file.thumbnailFilename { referenced.insert(thumbnail) }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: filesDirectory.path)) ?? []
        for name in names where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: fileURL(for: name))
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    /// Deletes every queued entry and staged image. Called when a session
    /// definitively ends: entries flush as whoever is signed in at flush
    /// time, so a prior account's queue must never survive into the next.
    func purgeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func persist(_ pending: PendingEntry) throws {
        let data = try encoder.encode(pending)
        try data.write(to: jsonURL(for: pending.id), options: .atomic)
    }

    private func jsonURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
