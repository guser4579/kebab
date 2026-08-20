//
//  XPostRepository.swift
//  kebab
//

import Foundation
import Supabase

/// Kebab's only route to X.
///
/// The client never holds an X credential and never talks to api.x.com; it
/// calls the `x-post` Edge Function with the signed-in user's Supabase session,
/// and the function performs the lookup server-side. Every failure comes back
/// classified so the caller knows whether the verdict is permanent (persist it,
/// never ask again) or transient (leave unresolved, allow one bounded retry).
final class XPostRepository {

    /// The Edge Function's answer, reduced to the only three things a caller
    /// can act on.
    enum Outcome: Sendable {
        /// The post is ours to keep.
        case resolved(XPostSource)
        /// A permanent verdict — deleted, protected, unsupported, malformed,
        /// or a Kebab-side configuration problem X will keep rejecting. The
        /// entry keeps its generic link card and nothing retries.
        case unavailable(reason: String)
        /// Offline, timed out, rate limited, or X is down. Nothing is
        /// persisted; a later bounded attempt may succeed.
        case retryable(reason: String)
    }

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// One lookup. Callers are expected to invoke this once per saved source —
    /// X bills per read, and a resolved source is persisted, never refreshed.
    func resolve(postID: String) async -> Outcome {
        do {
            let response: ResolveResponse = try await supabase.functions.invoke(
                "x-post",
                options: FunctionInvokeOptions(body: ResolveRequest(post_id: postID))
            )
            guard let post = response.post else {
                return .unavailable(reason: "empty_response")
            }
            return .resolved(post)

        } catch let error as FunctionsError {
            switch error {
            case .relayError:
                return .retryable(reason: "relay_error")
            case let .httpError(code, data):
                return Self.outcome(forHTTPCode: code, body: data)
            }

        } catch is URLError {
            // Offline or transport failure — the classic "saved it on the
            // subway" case. Worth trying again later.
            return .retryable(reason: "offline")

        } catch is DecodingError {
            // The function answered 200 in a shape this build doesn't know.
            // Retrying would produce the same bytes.
            return .unavailable(reason: "decoding_failed")

        } catch {
            return .retryable(reason: "unknown")
        }
    }

    /// Maps the function's typed error body onto the caller's decision. The
    /// body's own `retryable` flag is authoritative when present; the status
    /// code is the fallback for anything that never reached the function
    /// (gateway errors, auth rejections at the edge).
    private static func outcome(forHTTPCode code: Int, body: Data) -> Outcome {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
            let reason = envelope.error.code
            return envelope.error.retryable ? .retryable(reason: reason) : .unavailable(reason: reason)
        }
        switch code {
        case 401, 403:
            // The gateway refused the session rather than the post. Not this
            // source's fault, and a refreshed session may work later.
            return .retryable(reason: "unauthorized")
        case 408, 429, 500...599:
            return .retryable(reason: "http_\(code)")
        default:
            return .unavailable(reason: "http_\(code)")
        }
    }

    // MARK: - Wire types

    private struct ResolveRequest: Encodable {
        let post_id: String
    }

    private struct ResolveResponse: Decodable {
        let status: String
        let post: XPostSource?
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: String
            let retryable: Bool
        }
        let error: Payload
    }
}
