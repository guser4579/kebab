//
//  FileAttachmentTests.swift
//  kebabTests
//
//  The general file pipeline, minus the network: the model and its back-compat,
//  outbox staging, object paths, limits, the cache, cleanup and search.
//

import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import kebab

private let fileJSON = """
{
  "type": "file",
  "url": "uid/abc.pdf",
  "file": {
    "path": "uid/abc.pdf",
    "name": "lease-2026.pdf",
    "mime": "application/pdf",
    "size": 2400000,
    "kind": "pdf",
    "thumb_url": "https://x.supabase.co/storage/v1/object/public/entry-images/uid/abc-thumb.jpg",
    "page_count": 12
  }
}
"""

private func decodeFile() throws -> EntryAttachment {
    try JSONDecoder().decode(EntryAttachment.self, from: Data(fileJSON.utf8))
}

private func entry(content: String = "", hidden: Bool = false, attachments: [EntryAttachment]?) -> Entry {
    Entry(
        id: UUID(),
        user_id: UUID(),
        parent_id: nil,
        root_id: nil,
        depth: 0,
        content: content,
        created_at: Date(),
        pinned_at: nil,
        isContentHidden: hidden,
        comment_count: nil,
        resurface_count: 0,
        fire_count: 0,
        attachments: attachments,
        collection_id: nil,
        collection_name: nil,
        collection_parent_id: nil,
        collection_parent_name: nil
    )
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("File attachments")
struct FileAttachmentTests {

    // MARK: - Model

    @Test("A file attachment round-trips with its metadata")
    func roundTrip() throws {
        let attachment = try decodeFile()
        let again = try JSONDecoder().decode(EntryAttachment.self, from: JSONEncoder().encode(attachment))
        #expect(again == attachment)
        #expect(again.attachmentType == .file)
        #expect(again.file?.page_count == 12)
        #expect(again.file?.fileKind == .pdf)
    }

    /// Build 92's field set, frozen here. It has to read what this build writes.
    private struct Build92Attachment: Decodable {
        let type: String
        let url: String
        let title: String?
        let favicon_url: String?
        let image_url: String?
        enum AttachmentType: String { case link, image }
        var attachmentType: AttachmentType? { AttachmentType(rawValue: type) }
    }

    @Test("An older build still decodes a file attachment and treats it as neither link nor image")
    func oldBuildDecodes() throws {
        let old = try JSONDecoder().decode(Build92Attachment.self, from: Data(fileJSON.utf8))
        #expect(old.url == "uid/abc.pdf")
        #expect(old.attachmentType == nil)
    }

    @Test("A kind from a later build reads as a plain file")
    func unknownKind() {
        let file = FileMetadata(path: "p", name: "n", mime: "m", size: 1, kind: "hologram", thumb_url: nil, duration: nil, page_count: nil)
        #expect(file.fileKind == .file)
    }

    @Test("A file is never mistaken for a link or an image")
    func accessorsStaySeparate() throws {
        let subject = entry(attachments: [try decodeFile()])
        #expect(subject.linkAttachment == nil)
        #expect(subject.imageAttachments.isEmpty)
        #expect(subject.xPostSource == nil)
        #expect(subject.fileAttachments.count == 1)
    }

    @Test("Enriching a sibling link keeps the file's metadata")
    func withSourceKeepsFile() throws {
        let attachment = try decodeFile()
        #expect(attachment.withSource(nil).file == attachment.file)
    }

    @Test("Hidden thoughts show no file cards")
    func hiddenThoughts() throws {
        let attachments = [try decodeFile()]
        #expect(entry(hidden: true, attachments: attachments).visibleFileAttachments.isEmpty)
        #expect(entry(hidden: false, attachments: attachments).visibleFileAttachments.count == 1)
    }

    // MARK: - Outbox

    @Test("Entries queued by older builds decode without files")
    func oldOutboxJSON() throws {
        let json = """
        {"id":"\(UUID().uuidString)","content":"hi","imageFilenames":[],"createdAt":"2026-08-20T10:00:00Z","attempts":0,"failed":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pending = try decoder.decode(PendingEntry.self, from: Data(json.utf8))
        #expect(pending.files == nil)
    }

    private func stage(_ store: OutboxStore, name: String = "notes.md", thumbnail: Bool = true) throws -> PendingFile {
        let source = temporaryDirectory().appendingPathComponent(name)
        try Data("hello".utf8).write(to: source)
        let id = UUID()
        let size = try store.stageCopy(of: source, id: id, name: name)
        return PendingFile(
            id: id,
            localFilename: store.stagedFileURL(id: id, name: name).lastPathComponent,
            name: name,
            mime: "text/markdown",
            size: size,
            kind: .file,
            thumbnailFilename: thumbnail ? try store.writeThumbnail(Data([0xFF]), id: id) : nil
        )
    }

    private func exists(_ store: OutboxStore, _ filename: String?) -> Bool {
        guard let filename else { return false }
        return FileManager.default.fileExists(atPath: store.fileURL(for: filename).path)
    }

    @Test("Staging copies the bytes and records the size")
    func stagingCopies() throws {
        let store = OutboxStore(directory: temporaryDirectory())
        let file = try stage(store)
        #expect(file.size == 5)
        #expect(exists(store, file.localFilename))
        #expect(exists(store, file.thumbnailFilename))
    }

    @MainActor
    @Test("Files survive a reload, and removing the entry deletes them")
    func enqueueAndRemove() throws {
        let directory = temporaryDirectory()
        let store = OutboxStore(directory: directory)
        let file = try stage(store)
        let pending = try store.enqueue(content: "", images: [], files: [file], linkURL: nil, collectionId: nil, authorUserId: nil)

        let reloaded = OutboxStore(directory: directory).loadAll()
        #expect(reloaded.first?.files == [file])

        store.remove(pending)
        #expect(!exists(store, file.localFilename))
        #expect(!exists(store, file.thumbnailFilename))
        #expect(store.loadAll().isEmpty)
    }

    @MainActor
    @Test("A staged .json can't pass for a pending entry")
    func attachedJSONIsNotAnEntry() throws {
        let store = OutboxStore(directory: temporaryDirectory())
        _ = try stage(store, name: "data.json", thumbnail: false)
        #expect(store.loadAll().isEmpty)
    }

    @Test("Removing a chip deletes its staged file and thumbnail")
    func removeStaged() throws {
        let store = OutboxStore(directory: temporaryDirectory())
        let file = try stage(store)
        store.removeStaged(file)
        #expect(!exists(store, file.localFilename))
        #expect(!exists(store, file.thumbnailFilename))
    }

    @Test("A file whose staging never finished is removed by id")
    func removeUnfinished() throws {
        let store = OutboxStore(directory: temporaryDirectory())
        let file = try stage(store)
        store.removeStaged(id: file.id)
        #expect(!exists(store, file.localFilename))
        #expect(!exists(store, file.thumbnailFilename))
    }

    @MainActor
    @Test("The launch sweep clears a lost draft's files and keeps queued ones")
    func sweep() throws {
        let store = OutboxStore(directory: temporaryDirectory())
        let queued = try stage(store)
        let lost = try stage(store)
        let pending = try store.enqueue(content: "", images: [], files: [queued], linkURL: nil, collectionId: nil, authorUserId: nil)

        store.sweepOrphanedFiles(keeping: [pending])

        #expect(exists(store, queued.localFilename))
        #expect(exists(store, queued.thumbnailFilename))
        #expect(!exists(store, lost.localFilename))
        #expect(!exists(store, lost.thumbnailFilename))
    }

    @MainActor
    @Test("purgeAll takes files too, and staging still works afterwards")
    func purge() throws {
        let store = OutboxStore(directory: temporaryDirectory())
        let file = try stage(store)
        store.purgeAll()
        #expect(!exists(store, file.localFilename))
        #expect(try stage(store).size == 5)
    }

    // MARK: - Object paths

    @Test("Object paths are the same on every retry, and lowercased for RLS")
    func deterministicPaths() {
        let fileId = UUID()
        let userId = UUID()
        let first = AttachmentStorage.filePath(fileId: fileId, name: "Lease 2026.PDF", userId: userId)
        #expect(first == AttachmentStorage.filePath(fileId: fileId, name: "Lease 2026.PDF", userId: userId))
        #expect(first == "\(userId.uuidString.lowercased())/\(fileId.uuidString.lowercased()).pdf")
        #expect(AttachmentStorage.thumbnailPath(fileId: fileId, userId: userId)
            == "\(userId.uuidString.lowercased())/\(fileId.uuidString.lowercased())-thumb.jpg")
    }

    @Test("The filename never reaches the path")
    func nameStaysOutOfPath() {
        let path = AttachmentStorage.filePath(fileId: UUID(), name: "../../secret plan.t x!t", userId: UUID())
        #expect(!path.contains("secret"))
        #expect(!path.contains(".."))
        #expect(!path.contains(" "))
        #expect(!path.contains("!"))
        #expect(AttachmentStorage.filePath(fileId: UUID(), name: "../../secret.PDF", userId: UUID()).hasSuffix(".pdf"))
        #expect(AttachmentStorage.filePath(fileId: UUID(), name: "README", userId: UUID()).hasSuffix(".bin"))
    }

    @Test("An object that already landed counts as uploaded, in either form")
    func duplicateIsSuccess() {
        let duplicate = Data(#"{"statusCode":"409","error":"Duplicate","message":"exists"}"#.utf8)
        let tooLarge = Data(#"{"statusCode":"413","error":"Payload too large"}"#.utf8)
        #expect(AttachmentStorage.uploadSucceeded(status: 200, body: Data()))
        #expect(AttachmentStorage.uploadSucceeded(status: 409, body: Data()))
        #expect(AttachmentStorage.uploadSucceeded(status: 400, body: duplicate))
        #expect(!AttachmentStorage.uploadSucceeded(status: 400, body: tooLarge))
        #expect(!AttachmentStorage.uploadSucceeded(status: 403, body: Data()))
    }

    // MARK: - Video names

    private let noon = Date(timeIntervalSince1970: 1_793_707_200) // Nov 3, 2026, 12:00 UTC
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    @Test("A video is named for the day it was recorded")
    func videoNamedByDate() {
        #expect(VideoNaming.name(recordedOn: noon, taken: [], locale: us, timeZone: utc)
            == "Video \u{00B7} Nov 3, 2026.mp4")
    }

    @Test("With no date it stays Video.mp4, numbered the same way")
    func videoWithoutDate() {
        #expect(VideoNaming.name(recordedOn: nil, taken: []) == "Video.mp4")
        #expect(VideoNaming.name(recordedOn: nil, taken: ["Video.mp4"]) == "Video 2.mp4")
        #expect(VideoNaming.name(recordedOn: nil, taken: ["Video.mp4", "Video 2.mp4"]) == "Video 3.mp4")
    }

    @Test("Two videos from one day in a thought get different names")
    func sameDayVideos() {
        let first = VideoNaming.name(recordedOn: noon, taken: ["lease.pdf"], locale: us, timeZone: utc)
        let second = VideoNaming.name(recordedOn: noon, taken: [first], locale: us, timeZone: utc)
        let third = VideoNaming.name(recordedOn: noon, taken: [first, second], locale: us, timeZone: utc)
        #expect(second == "Video \u{00B7} Nov 3, 2026 2.mp4")
        #expect(third == "Video \u{00B7} Nov 3, 2026 3.mp4")
    }

    @Test("The date follows the locale, and never puts a slash in the name")
    func videoNameLocales() {
        let german = VideoNaming.name(recordedOn: noon, taken: [], locale: Locale(identifier: "de_DE"), timeZone: utc)
        #expect(german == "Video \u{00B7} 03.11.2026.mp4")
        let japanese = VideoNaming.name(recordedOn: noon, taken: [], locale: Locale(identifier: "ja_JP"), timeZone: utc)
        #expect(!japanese.contains("/"))
        #expect((japanese as NSString).lastPathComponent == japanese)
        #expect((japanese as NSString).pathExtension == "mp4")
    }

    @Test("The day comes from the user's time zone")
    func videoNameTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let evening = noon.addingTimeInterval(8 * 3600) // 20:00 UTC, already Nov 4 in Tokyo
        #expect(VideoNaming.name(recordedOn: evening, taken: [], locale: us, timeZone: utc).contains("Nov 3"))
        #expect(VideoNaming.name(recordedOn: evening, taken: [], locale: us, timeZone: tokyo).contains("Nov 4"))
    }

    /// A real one-frame movie, so the metadata read goes through AVFoundation.
    private func writeMovie(metadata: [AVMetadataItem], type: AVFileType) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type == .mov ? "mov" : "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        adaptor.append(try #require(buffer), withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test("The recorded date is read from QuickTime metadata, as an iPhone writes it")
    func readsQuickTimeDate() async throws {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.value = "2026-11-03T12:00:00+0000" as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        let url = try await writeMovie(metadata: [item], type: .mov)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await VideoNaming.creationDate(of: url) == noon)
    }

    @Test("A file with nothing readable has no recorded date")
    func readsNoDate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await VideoNaming.creationDate(of: url) == nil)
    }

    // MARK: - Limits

    @Test("50 MB per file, up to 4 files")
    func limits() {
        #expect(FileLimits.refusal(existingCount: 0, size: FileLimits.maxBytes) == nil)
        #expect(FileLimits.refusal(existingCount: 0, size: FileLimits.maxBytes + 1) == .tooLarge)
        #expect(FileLimits.refusal(existingCount: 3, size: 10) == nil)
        #expect(FileLimits.refusal(existingCount: 4, size: 10) == .tooMany)
        #expect(FileLimits.refusal(existingCount: 3, size: nil) == nil)
        #expect(FileLimits.maxBytes == 52_428_800)
    }

    // MARK: - Kinds, icons, meta lines

    @Test(arguments: [
        ("a.pdf", FileKind.pdf, "pdf-01"),
        ("a.mov", .video, "video-01"),
        ("a.mp4", .video, "video-01"),
        ("a.m4a", .audio, "file-01"),
        ("a.docx", .file, "doc-01"),
        ("a.pages", .file, "doc-01"),
        ("a.rtf", .file, "doc-01"),
        ("a.md", .file, "txt-01"),
        ("a.TXT", .file, "txt-01"),
        ("a.csv", .file, "xls-01"),
        ("a.numbers", .file, "xls-01"),
        ("a.key", .file, "ppt-01"),
        ("a.pptx", .file, "ppt-01"),
        ("a.zip", .file, "zip-01"),
        ("a.unknown", .file, "file-01"),
        ("noextension", .file, "file-01"),
    ])
    func kindAndIcon(name: String, kind: FileKind, icon: String) {
        #expect(FileKind.of(filename: name) == kind)
        #expect(FileIcon.name(forKind: kind, filename: name) == icon)
    }

    @Test("Meta lines read as the extension, then pages, then size")
    func metaLine() {
        let pdf = FileMeta.line(name: "lease.pdf", size: 2_400_000, pageCount: 12)
        #expect(pdf.hasPrefix("PDF · 12 pages · "))
        #expect(pdf.hasSuffix(FileMeta.byteCount(2_400_000)))
        #expect(FileMeta.line(name: "a.pdf", size: 1000, pageCount: 1).hasPrefix("PDF · 1 page · "))
        #expect(FileMeta.line(name: "a.docx", size: 1_200_000, pageCount: nil).hasPrefix("DOCX · "))
        #expect(!FileMeta.line(name: "README", size: 1000, pageCount: nil).hasPrefix(" · "))
    }

    @Test("Durations read like a player's")
    func durations() {
        #expect(FileMeta.duration(42) == "0:42")
        #expect(FileMeta.duration(725) == "12:05")
        #expect(FileMeta.duration(3729) == "1:02:09")
    }

    // MARK: - Cache

    private func sourceFile(bytes: Int = 10) throws -> URL {
        let url = temporaryDirectory().appendingPathComponent("download")
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    @Test("The cache is keyed by path and keeps the original name")
    func cacheKeyedByPath() throws {
        let cache = FileCache(directory: temporaryDirectory())
        #expect(cache.cachedURL(forPath: "uid/a.pdf") == nil)
        try cache.adopt(try sourceFile(), path: "uid/a.pdf", name: "lease.pdf")
        #expect(cache.cachedURL(forPath: "uid/a.pdf")?.lastPathComponent == "lease.pdf")
        #expect(cache.cachedURL(forPath: "uid/b.pdf") == nil)

        cache.evict(path: "uid/a.pdf")
        #expect(cache.cachedURL(forPath: "uid/a.pdf") == nil)
    }

    @Test("A filename can't escape its cache folder")
    func cacheNameIsContained() throws {
        let directory = temporaryDirectory()
        let cache = FileCache(directory: directory)
        let url = try cache.adopt(try sourceFile(), path: "uid/a", name: "../../evil.txt")
        #expect(url.lastPathComponent == "evil.txt")
        #expect(url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path))
    }

    @Test("Eviction drops the least recently used until it fits")
    func evictionPlan() {
        let now = Date()
        let items = [
            FileCache.Item(key: "newest", size: 40, lastUsed: now),
            FileCache.Item(key: "oldest", size: 40, lastUsed: now.addingTimeInterval(-100)),
            FileCache.Item(key: "middle", size: 40, lastUsed: now.addingTimeInterval(-50)),
        ]
        #expect(FileCache.evictionPlan(items, capacity: 120).isEmpty)
        #expect(FileCache.evictionPlan(items, capacity: 100) == ["oldest"])
        #expect(FileCache.evictionPlan(items, capacity: 50) == ["oldest", "middle"])
    }

    @Test("Going over the cap evicts what hasn't been used lately")
    func cacheEvictsLRU() throws {
        let cache = FileCache(directory: temporaryDirectory(), capacity: 25)
        let first = try cache.adopt(try sourceFile(), path: "uid/first", name: "first")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: first.path)
        let second = try cache.adopt(try sourceFile(), path: "uid/second", name: "second")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -50)], ofItemAtPath: second.path)

        // Opening `first` makes `second` the oldest.
        #expect(cache.cachedURL(forPath: "uid/first") != nil)
        try cache.adopt(try sourceFile(), path: "uid/third", name: "third")

        #expect(cache.cachedURL(forPath: "uid/first") != nil)
        #expect(cache.cachedURL(forPath: "uid/second") == nil)
        #expect(cache.cachedURL(forPath: "uid/third") != nil)
    }

    @Test("removeAll empties the cache")
    func cacheRemoveAll() throws {
        let cache = FileCache(directory: temporaryDirectory())
        try cache.adopt(try sourceFile(), path: "uid/a", name: "a")
        cache.removeAll()
        #expect(cache.cachedURL(forPath: "uid/a") == nil)
    }

    // MARK: - Cleanup

    @Test("Cleanup finds originals and thumbnails in the right buckets")
    func objectPaths() throws {
        let image = EntryAttachment(
            type: "image",
            url: "https://x.supabase.co/storage/v1/object/public/entry-images/uid/photo.jpg",
            title: nil, favicon_url: nil, image_url: nil
        )
        let link = EntryAttachment(type: "link", url: "https://example.com/a.pdf", title: nil, favicon_url: nil, image_url: nil)
        let paths = AttachmentStorage.objectPaths(for: [image, link, try decodeFile()])
        #expect(paths.images == ["uid/photo.jpg", "uid/abc-thumb.jpg"])
        #expect(paths.files == ["uid/abc.pdf"])
    }

    @Test("A file with no thumbnail only owns its original")
    func objectPathsWithoutThumbnail() {
        let attachment = EntryAttachment(
            type: "file", url: "uid/a.zip", title: nil, favicon_url: nil, image_url: nil,
            file: FileMetadata(path: "uid/a.zip", name: "a.zip", mime: "application/zip", size: 1, kind: "file", thumb_url: nil, duration: nil, page_count: nil)
        )
        let paths = AttachmentStorage.objectPaths(for: [attachment])
        #expect(paths.images.isEmpty)
        #expect(paths.files == ["uid/a.zip"])
    }

    // MARK: - Search

    private func results(for subject: Entry, query: String) async -> [UUID] {
        let engine = SearchEngine()
        await engine.update(snapshot: SearchCorpusSnapshot(entries: [subject], membership: [:], collectionNames: [:]))
        return await engine.search(rawQuery: query, recentActivityRoots: []).results.map(\.entry.id)
    }

    @Test("Searching a word from a filename finds the thought")
    func searchFindsFilename() async throws {
        let subject = entry(attachments: [try decodeFile()])
        #expect(await results(for: subject, query: "lease") == [subject.id])
    }

    @Test("A hidden thought's filename never matches")
    func searchSkipsHidden() async throws {
        let subject = entry(hidden: true, attachments: [try decodeFile()])
        #expect(await results(for: subject, query: "lease").isEmpty)
    }

    @Test("A files-only thought previews as its filename")
    func previewFallback() throws {
        #expect(SearchDisplay.previewText(for: entry(attachments: [try decodeFile()])) == "lease-2026.pdf")
    }
}
