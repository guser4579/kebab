//
//  ProfileStore.swift
//  kebab
//

import Foundation
import UIKit
import Combine
import Supabase

/// Owns the signed-in user's optional profile (display name + avatar) for the
/// whole app. Cached per-user in UserDefaults (`profile_<userId>`) so Account
/// and the menu card render instantly and survive relaunch; refreshed from
/// the network on configure and whenever Account opens.
///
/// Per-user keying follows the recent-activity/search stores: the cache stays
/// for that account's return after sign-out, and is purged on account
/// deletion (AuthViewModel.deleteAccount).
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var displayName: String?
    @Published private(set) var avatarURL: URL?

    private let repository: ProfileRepository
    private var userId: UUID?
    private var email: String?

    private struct CachedProfile: Codable {
        var displayName: String?
        var avatarURL: String?
    }

    private var cacheKey: String {
        "profile_\(userId?.uuidString ?? "anonymous")"
    }

    init(supabase: SupabaseClient) {
        repository = ProfileRepository(supabase: supabase)
    }

    func configure(userId: UUID, email: String?) {
        self.email = email
        guard self.userId != userId else { return }
        self.userId = userId
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(CachedProfile.self, from: data) {
            displayName = cached.displayName
            avatarURL = cached.avatarURL.flatMap(URL.init(string:))
        } else {
            displayName = nil
            avatarURL = nil
        }
        Task { await refresh() }
    }

    /// Pulls current truth from the server; silent on failure (the cached
    /// copy keeps rendering, next open retries).
    func refresh() async {
        guard let userId else { return }
        guard let profile = try? await repository.fetchProfile(userId: userId) else { return }
        displayName = profile.display_name
        avatarURL = profile.avatar_url.flatMap(URL.init(string:))
        persistCache()
    }

    /// One staged avatar decision, applied together with the name on save.
    enum AvatarEdit {
        case keep
        case replace(UIImage)
        case remove
    }

    /// Persists the Account page's staged change set as a single upsert:
    /// upload first when a new photo is staged, then one row write, then
    /// best-effort cleanup of the replaced object. Published state changes
    /// only after the server accepts, so a failure leaves the store (and the
    /// caller's staged edits) exactly as they were.
    func applyEdits(displayName rawName: String, avatarEdit: AvatarEdit) async -> Bool {
        guard let userId else { return false }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? nil : String(trimmed.prefix(50))
        let previousAvatarURL = avatarURL

        var newAvatarURL = previousAvatarURL?.absoluteString
        var uploadedURL: String?
        do {
            switch avatarEdit {
            case .keep:
                break
            case .replace(let image):
                uploadedURL = try await repository.uploadAvatar(image, userId: userId)
                newAvatarURL = uploadedURL
            case .remove:
                newAvatarURL = nil
            }

            try await repository.upsertProfile(Profile(
                id: userId,
                email: email,
                display_name: newName,
                avatar_url: newAvatarURL
            ))

            displayName = newName
            avatarURL = newAvatarURL.flatMap(URL.init(string:))
            persistCache()

            // The old object is unreferenced now (replaced or removed).
            if case .keep = avatarEdit { } else if let previousAvatarURL {
                await repository.deleteAvatarObject(publicUrl: previousAvatarURL.absoluteString)
            }
            return true
        } catch {
            // If the upload landed but the row write failed, the fresh object
            // is unreferenced — clean it up so retries don't accumulate.
            if let uploadedURL {
                await repository.deleteAvatarObject(publicUrl: uploadedURL)
            }
            return false
        }
    }

    private func persistCache() {
        let cached = CachedProfile(
            displayName: displayName,
            avatarURL: avatarURL?.absoluteString
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
