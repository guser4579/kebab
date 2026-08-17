//
//  FeedbackRepository.swift
//  kebab
//

import Foundation
import Supabase

/// Inserts one feedback row. Write-only from the app — RLS permits insert
/// of the caller's own row and nothing else.
final class FeedbackRepository {

    private struct FeedbackSubmission: Encodable {
        let user_id: UUID?
        let name: String?
        let email: String?
        let message: String
        let app_version: String
    }

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func submit(
        userId: UUID?,
        name: String?,
        email: String?,
        message: String
    ) async throws {
        try await supabase
            .from("feedback")
            .insert(FeedbackSubmission(
                user_id: userId,
                name: name,
                email: email,
                message: message,
                app_version: Self.appVersion
            ))
            .execute()
    }

    /// "1.0 (64)" — marketing version plus build.
    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
