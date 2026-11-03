//
//  FileStaging.swift
//  kebab
//
//  Attach time for files: copy, compress, thumbnail. All of it runs off the main
//  actor and finishes before the send button enables, so sending never pays for
//  any of it.
//

import AVFoundation
import Combine
import CoreTransferable
import Foundation
import PDFKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file on its way through the composer. `pending` arrives when staging ends.
struct ComposerFile: Identifiable, Equatable {
    let id: UUID
    var name: String
    let kind: FileKind
    var pending: PendingFile?
    var thumbnail: UIImage?
    /// 0…1 while a video compresses.
    var progress: Double?
}

/// The draft's files. Owned by the main screen, so the inline and full-screen
/// composers share one set, the way they share the draft's text and images.
@MainActor
final class ComposerFileStager: ObservableObject {

    /// Stands in where a composer has no files; never gets any.
    static let idle = ComposerFileStager()

    @Published private(set) var files: [ComposerFile] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Picked videos whose recorded date hasn't been read yet. Their placeholder
    /// name doesn't count as taken.
    private var unnamedVideos: Set<UUID> = []
    private let store: OutboxStore
    var onNotice: (String) -> Void = { _ in }

    init(store: OutboxStore = OutboxStore()) {
        self.store = store
    }

    var isStaging: Bool {
        files.contains { $0.pending == nil }
    }

    /// A file from the Files app. `url` is security-scoped and only opens here.
    func add(importedFile url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            if scoped { url.stopAccessingSecurityScopedResource() }
            onNotice("Folders can\u{2019}t be attached. Try zipping it first.")
            return
        }
        let size = values?.fileSize.map(Int64.init)
        let name = url.lastPathComponent
        if let refusal = FileLimits.refusal(existingCount: files.count, size: size) {
            if scoped { url.stopAccessingSecurityScopedResource() }
            onNotice(refusal.message)
            return
        }
        let id = UUID()
        let kind = FileKind.of(filename: name)
        files.append(ComposerFile(id: id, name: name, kind: kind))
        let store = store
        let work = Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try store.stageCopy(of: url, id: id, name: name)
        }
        track(id: id, kind: kind, name: name, staged: { try await work.value })
    }

    /// A video from the Photos picker: compress, then stage.
    func add(pickedVideo item: PhotosPickerItem) {
        if let refusal = FileLimits.refusal(existingCount: files.count, size: nil) {
            onNotice(refusal.message)
            return
        }
        let id = UUID()
        let name = VideoNaming.placeholder
        unnamedVideos.insert(id)
        files.append(ComposerFile(id: id, name: name, kind: .video, progress: 0))
        let store = store
        track(id: id, kind: .video, name: name) { [weak self] in
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            // From the source, because export can drop the metadata.
            let recorded = await VideoNaming.creationDate(of: movie.url)
            await MainActor.run { self?.nameVideo(id: id, recordedOn: recorded) }
            store.prepareFilesDirectory()
            let destination = store.stagedFileURL(id: id, name: name)
            try await VideoCompressor.compress(movie.url, to: destination) { progress in
                await MainActor.run { self?.setProgress(progress, for: id) }
            }
            return try store.adoptStaged(at: destination, id: id, name: name)
        }
    }

    func remove(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        unnamedVideos.remove(id)
        if let pending = files.first(where: { $0.id == id })?.pending {
            store.removeStaged(pending)
        } else {
            store.removeStaged(id: id)
        }
        files.removeAll { $0.id == id }
    }

    /// Hands the ready files to a send and empties the draft.
    func takeReady() -> [PendingFile] {
        let ready = files.compactMap(\.pending)
        files.removeAll()
        tasks.removeAll()
        return ready
    }

    /// The send couldn't be queued, so the draft keeps its files.
    func restore(_ pending: [PendingFile]) {
        files = pending.map { file in
            ComposerFile(
                id: file.id,
                name: file.name,
                kind: file.kind,
                pending: file,
                thumbnail: file.thumbnailFilename.flatMap { UIImage(contentsOfFile: store.fileURL(for: $0).path) }
            )
        }
    }

    private func nameVideo(id: UUID, recordedOn date: Date?) {
        unnamedVideos.remove(id)
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let taken = files
            .filter { $0.id != id && !unnamedVideos.contains($0.id) }
            .map(\.name)
        files[index].name = VideoNaming.name(recordedOn: date, taken: taken)
    }

    private func setProgress(_ progress: Double, for id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].progress = progress
    }

    private func track(
        id: UUID,
        kind: FileKind,
        name: String,
        staged: @escaping () async throws -> Int64
    ) {
        let store = store
        tasks[id] = Task { [weak self] in
            do {
                let size = try await staged()
                try Task.checkCancellation()
                let finalName = self?.files.first(where: { $0.id == id })?.name ?? name
                let details = await Task.detached(priority: .userInitiated) {
                    await FileDetails.generate(for: store.stagedFileURL(id: id, name: name), kind: kind, id: id, store: store)
                }.value
                self?.finish(
                    id: id,
                    file: PendingFile(
                        id: id,
                        localFilename: store.stagedFileURL(id: id, name: name).lastPathComponent,
                        name: finalName,
                        mime: UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        size: size,
                        kind: kind,
                        thumbnailFilename: details.thumbnailFilename,
                        duration: details.duration,
                        pageCount: details.pageCount
                    ),
                    thumbnail: details.thumbnail
                )
            } catch {
                self?.fail(id: id, error: error)
            }
        }
    }

    private func finish(id: UUID, file: PendingFile, thumbnail: UIImage?) {
        guard let index = files.firstIndex(where: { $0.id == id }), !Task.isCancelled else {
            store.removeStaged(file)
            return
        }
        files[index].pending = file
        files[index].thumbnail = thumbnail
        files[index].progress = nil
        tasks[id] = nil
    }

    private func fail(id: UUID, error: Error) {
        store.removeStaged(id: id)
        unnamedVideos.remove(id)
        guard files.contains(where: { $0.id == id }) else { return }
        files.removeAll { $0.id == id }
        tasks[id] = nil
        guard !(error is CancellationError) else { return }
        onNotice((error as? VideoCompressor.Failure) == .tooLong
            ? "That video\u{2019}s too long for kebab. Try trimming it."
            : "Couldn\u{2019}t attach that file.")
    }
}

/// Photos hands a movie over as a temporary file. This takes ownership of a copy.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// What a video from Photos is called. The picker gives no filename, so it's
/// named for the day it was recorded.
nonisolated enum VideoNaming {

    static let placeholder = "Video.mp4"

    /// `Video · Nov 3, 2026.mp4`, or `Video.mp4` with no date, numbered from 2
    /// when the name is already taken in this thought.
    static func name(
        recordedOn date: Date?,
        taken: [String],
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var base = "Video"
        if let date {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            // Some locales write 2026/11/03, and a slash would cut the name
            // short everywhere it becomes a path.
            let day = formatter.string(from: date)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            base = "Video \u{00B7} \(day)"
        }
        var candidate = "\(base).mp4"
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(number).mp4"
            number += 1
        }
        return candidate
    }

    /// The common metadata key, then the QuickTime item Apple's camera writes.
    static func creationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
        guard let item = items.first else { return nil }
        return try? await item.load(.dateValue)
    }
}

nonisolated enum VideoCompressor {

    enum Failure: Error, Equatable {
        case tooLong
        case exportUnavailable
    }

    /// HEVC capped at 1080p, then a 720p retry if that's still over the limit.
    /// AVFoundation has no 720p HEVC preset, so the retry is H.264.
    static func compress(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        for preset in [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1280x720] {
            try? FileManager.default.removeItem(at: destination)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw Failure.exportUnavailable
            }
            session.shouldOptimizeForNetworkUse = true
            let watcher = Task {
                for await state in session.states(updateInterval: 0.2) {
                    if case .exporting(let exportProgress) = state {
                        // The second pass only happens when the first was over,
                        // so the bar restarts rather than pretending.
                        await progress(exportProgress.fractionCompleted)
                    }
                }
            }
            defer { watcher.cancel() }
            try await session.export(to: destination, as: .mp4)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? .max
            if size <= FileLimits.maxBytes { return }
        }
        try? FileManager.default.removeItem(at: destination)
        throw Failure.tooLong
    }
}

/// The thumbnail and numbers worked out once per file, on device, at attach.
nonisolated struct FileDetails: Sendable {
    var thumbnailFilename: String?
    var thumbnail: UIImage?
    var duration: Double?
    var pageCount: Int?

    private static let thumbnailEdge: CGFloat = 600

    static func generate(for url: URL, kind: FileKind, id: UUID, store: OutboxStore) async -> FileDetails {
        var details = FileDetails()
        var image: UIImage?
        switch kind {
        case .pdf:
            if let document = PDFDocument(url: url) {
                details.pageCount = document.pageCount
                if let page = document.page(at: 0) {
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = thumbnailEdge / max(bounds.width, bounds.height, 1)
                    image = page.thumbnail(
                        of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                        for: .mediaBox
                    )
                }
            }
        case .video:
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.isNumeric {
                details.duration = duration.seconds
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: thumbnailEdge, height: thumbnailEdge)
            if let frame = try? await generator.image(at: .zero).image {
                image = UIImage(cgImage: frame)
            }
        case .audio, .file:
            break
        }
        if let image, let jpeg = image.jpegData(compressionQuality: 0.8),
           let filename = try? store.writeThumbnail(jpeg, id: id) {
            details.thumbnailFilename = filename
            details.thumbnail = image
        }
        return details
    }
}
