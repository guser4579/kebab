//
//  EntryFilesView.swift
//  kebab
//
//  A thought's files, below its image strip: videos as poster cards that scroll
//  sideways like images, everything else as compact stacked cards. Opening goes
//  through `FileOpener`, so a card only knows how to show itself.
//

import AVKit
import Combine
import QuickLook
import SwiftUI

struct EntryFilesView: View {

    let attachments: [EntryAttachment]

    private var videos: [EntryAttachment] {
        attachments.filter { $0.file?.fileKind == .video }
    }

    private var documents: [EntryAttachment] {
        attachments.filter { $0.file?.fileKind != .video }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !videos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(videos, id: \.url) { attachment in
                            VideoPosterCard(attachment: attachment)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
            }
            ForEach(documents, id: \.url) { attachment in
                FileCardView(attachment: attachment)
            }
        }
    }
}

/// Everything a file card does when tapped. A pending row's attachment carries a
/// file:// URL and no path, so it opens its outbox copy directly.
@MainActor
final class FileOpener: ObservableObject {

    /// Downloading: 0…1. Drives the thin bar on the card.
    @Published private(set) var progress: Double?
    /// Non-nil presents Quick Look.
    @Published var previewURL: URL?

    private var isOpening = false

    private func localURL(for attachment: EntryAttachment) -> URL? {
        guard let file = attachment.file else { return nil }
        if file.path.isEmpty { return URL(string: attachment.url) }
        return FileCache.shared.cachedURL(forPath: file.path)
    }

    /// An outbox copy is named by id. Quick Look and Share show a filename, so
    /// a hard link gives them the real one without copying the bytes.
    private static func named(_ url: URL, as name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        let link = folder.appendingPathComponent((name as NSString).lastPathComponent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        return (try? FileManager.default.linkItem(at: url, to: link)) != nil ? link : url
    }

    func openDocument(_ attachment: EntryAttachment, storage: AttachmentStorage?, onFailure: @escaping (String) -> Void) {
        guard !isOpening, let file = attachment.file else { return }
        if let local = localURL(for: attachment) {
            previewURL = file.path.isEmpty ? Self.named(local, as: file.name) : local
            return
        }
        guard let storage else { return }
        isOpening = true
        progress = 0
        Task {
            defer {
                isOpening = false
                progress = nil
            }
            do {
                let signed = try await storage.signedURL(forPath: file.path)
                let temporary = try await FileDownload.run(from: signed) { [weak self] fraction in
                    self?.progress = fraction
                }
                previewURL = try FileCache.shared.adopt(temporary, path: file.path, name: file.name)
            } catch {
                onFailure("Couldn\u{2019}t open that file. Try again.")
            }
        }
    }

    func playVideo(_ attachment: EntryAttachment, storage: AttachmentStorage?, onFailure: @escaping (String) -> Void) {
        guard !isOpening, let file = attachment.file else { return }
        if let local = localURL(for: attachment) {
            VideoPresenter.present(local, title: file.name)
            return
        }
        guard let storage else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                VideoPresenter.present(try await storage.signedURL(forPath: file.path), title: file.name)
            } catch {
                onFailure("Couldn\u{2019}t play that video. Try again.")
            }
        }
    }
}

/// Presented by UIKit rather than a SwiftUI cover, because the system's
/// swipe-down-to-close only exists on a directly presented player.
enum VideoPresenter {

    @MainActor
    static func present(_ url: URL, title: String) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        // Plays through the silent switch, as a video the user chose to open should.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let item = AVPlayerItem(url: url)
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]
        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        top.present(controller, animated: true) {
            player.play()
        }
    }
}

/// One download with progress, ending in a temporary file the caller now owns.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func run(from url: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let download = FileDownload(onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let report = onProgress
        Task { @MainActor in report(fraction) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` when this returns.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

// MARK: - Cards

struct FileCardView: View {

    let attachment: EntryAttachment

    @Environment(\.supabase) private var supabase
    @EnvironmentObject private var noticeCenter: TransientNoticeCenter
    @StateObject private var opener = FileOpener()

    var body: some View {
        if let file = attachment.file {
            Button {
                opener.openDocument(attachment, storage: supabase.map(AttachmentStorage.init)) { noticeCenter.show($0) }
            } label: {
                content(file)
            }
            .buttonStyle(.plain)
            .quickLookPreview($opener.previewURL)
        }
    }

    private func content(_ file: FileMetadata) -> some View {
        HStack(spacing: 12) {
            FileLeadingTile(file: file)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(Style.Typography.linkCard())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(FileMeta.line(name: file.name, size: file.size, pageCount: file.page_count))
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius)
                .fill(Style.Color.background)
        )
        .overlay(alignment: .bottom) {
            if let progress = opener.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Style.Color.primaryText)
                    .scaleEffect(y: 0.5)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius)
                .strokeBorder(Style.Color.separator, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius))
    }
}

/// A 44×44 thumbnail, or the kind's icon on a soft tile.
struct FileLeadingTile: View {

    let file: FileMetadata

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Style.Color.separator.opacity(0.5))
            .overlay {
                if let thumb = file.thumb_url.flatMap(URL.init(string:)) {
                    CachedAsyncImage(url: thumb)
                } else {
                    Icon(FileIcon.name(forKind: file.fileKind, filename: file.name))
                        .foregroundColor(Style.Color.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct VideoPosterCard: View {

    let attachment: EntryAttachment

    @Environment(\.supabase) private var supabase
    @EnvironmentObject private var noticeCenter: TransientNoticeCenter
    @StateObject private var opener = FileOpener()

    // The image strip's cell, so a video sits beside photos as one family.
    private let cornerRadius: CGFloat = 12
    private let cellWidth: CGFloat = 221
    private let cellHeight: CGFloat = 175

    var body: some View {
        Button {
            opener.playVideo(attachment, storage: supabase.map(AttachmentStorage.init)) { noticeCenter.show($0) }
        } label: {
            Rectangle()
                .fill(Style.Color.separator)
                .overlay {
                    if let thumb = attachment.file?.thumb_url.flatMap(URL.init(string:)) {
                        CachedAsyncImage(url: thumb)
                    }
                }
                .overlay {
                    Icon("play")
                        .foregroundColor(Style.Color.primaryText)
                        .frame(width: 44, height: 44)
                        .kebabGlass(in: Circle())
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = attachment.file?.duration {
                        Text(FileMeta.duration(duration))
                            .font(Style.Typography.meta())
                            .monospacedDigit()
                            .foregroundColor(Style.Color.primaryText)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .kebabGlass(in: Capsule())
                            .padding(8)
                    }
                }
                .frame(width: cellWidth, height: cellHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Style.Color.separator, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(attachment.file?.name ?? "video")")
    }
}
