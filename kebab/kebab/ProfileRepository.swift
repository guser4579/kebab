//
//  ProfileRepository.swift
//  kebab
//

import Foundation
import UIKit
import Supabase

/// The signed-in user's optional profile row. `email` mirrors the auth
/// email into the profiles table on upsert; `display_name` and `avatar_url`
/// are the only user-editable fields (V1 — no handle, no username).
struct Profile: Codable, Equatable {
    let id: UUID
    var email: String?
    var display_name: String?
    var avatar_url: String?

    // Manual encoding so nil fields serialize as explicit JSON nulls —
    // synthesized Codable omits nil keys, which would make an upsert unable
    // to clear a name or remove an avatar.
    enum CodingKeys: String, CodingKey {
        case id, email, display_name, avatar_url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(email, forKey: .email)
        try container.encode(display_name, forKey: .display_name)
        try container.encode(avatar_url, forKey: .avatar_url)
    }
}

/// Reads and writes the user's profile row, and manages avatar objects in
/// storage. Avatars reuse the existing public `entry-images` bucket under the
/// user's folder (`{userId}/avatar-{uuid}.jpg`) — same unguessable-URL privacy
/// model and the same folder-scoped RLS policies as entry images, so no new
/// storage infrastructure is needed.
final class ProfileRepository {

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func fetchProfile(userId: UUID) async throws -> Profile? {
        let rows: [Profile] = try await supabase
            .from("profiles")
            .select("id,email,display_name,avatar_url")
            .eq("id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// The profiles table has no signup trigger — the row is created lazily
    /// by the first profile edit, so writes are always upserts.
    func upsertProfile(_ profile: Profile) async throws {
        try await supabase
            .from("profiles")
            .upsert(profile, onConflict: "id")
            .execute()
    }

    /// Avatars are small; 512pt is retina-crisp at every size the app renders
    /// (96pt page avatar, 64pt menu card) without storing a full photo.
    func uploadAvatar(_ image: UIImage, userId: UUID) async throws -> String {
        let data = try ImageStorageRepository.jpegData(
            from: image,
            maxDimension: 512,
            quality: 0.82
        )
        let path = "\(userId.uuidString.lowercased())/avatar-\(UUID().uuidString.lowercased()).jpg"
        _ = try await supabase.storage
            .from(ImageStorageRepository.bucket)
            .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        return try supabase.storage
            .from(ImageStorageRepository.bucket)
            .getPublicURL(path: path)
            .absoluteString
    }

    /// Best-effort cleanup of a replaced or removed avatar object. A failure
    /// here never surfaces: the profile row is the source of truth and the
    /// orphaned object is unreachable (unguessable path).
    ///
    /// This is garbage collection, not a privacy guarantee — the object it
    /// drops is one the account no longer references, and the account-deletion
    /// purge covers the *current* avatar separately and strictly. So a failure
    /// stays non-throwing (same contract as per-entry image cleanup), but it
    /// must not be INVISIBLE: Storage answers 200 with an empty list when RLS
    /// filters the DELETE, so without this check a permanently no-opping
    /// cleanup looks identical to a working one.
    func deleteAvatarObject(publicUrl: String) async {
        guard let path = Self.storagePath(fromPublicUrl: publicUrl) else { return }
        do {
            let removed = try await supabase.storage
                .from(ImageStorageRepository.bucket)
                .remove(paths: [path])
            if removed.isEmpty {
                print("Avatar cleanup removed 0/1 object(s) — check the entry-images select+delete policies on storage.objects")
            }
        } catch {
            print("Avatar cleanup failed:", error.localizedDescription)
        }
    }

    /// Extracts the in-bucket object path from a public URL. Moved to
    /// `ImageStorageRepository`, which owns the bucket and mints these paths;
    /// kept here so existing avatar/account-deletion call sites read unchanged.
    static func storagePath(fromPublicUrl url: String) -> String? {
        ImageStorageRepository.storagePath(fromPublicUrl: url)
    }
}
