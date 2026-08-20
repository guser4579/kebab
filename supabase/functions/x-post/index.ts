// x-post — resolve public X post metadata for a Kebab entry's attached source.
//
// The one place the X bearer token is ever read. The iOS client never sees it
// and never calls api.x.com directly; it posts a URL (or post id) here and
// gets back a small Kebab-owned model, or a typed error.
//
// Scope on purpose: ONE public post, by id, with only the fields the native
// card renders. No engagement metrics (likes/replies/reposts/bookmarks/views/
// followers) are requested — X bills per read and Kebab has no use for them.
//
// Auth: the platform verifies the JWT signature (verify_jwt, see config.toml),
// and this function additionally resolves it to a real user, because the anon
// publishable key is itself a structurally valid JWT and would otherwise pass.
// That keeps the function from becoming an open X proxy.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { parseXPostURL, POST_ID_PATTERN, type XPostRef } from "../_shared/x-post-url.ts";

// ---------------------------------------------------------------------------
// X API request shape
// ---------------------------------------------------------------------------

const X_POST_ENDPOINT = "https://api.x.com/2/tweets";
const UPSTREAM_TIMEOUT_MS = 8_000;

// Minimum viable field set for the native card. Deliberately excludes
// public_metrics / organic_metrics / non_public_metrics and every user metric.
const X_QUERY = new URLSearchParams({
  "tweet.fields": "created_at,text,entities,attachments",
  "expansions": "author_id,attachments.media_keys",
  "user.fields": "name,username,profile_image_url,verified,verified_type",
  "media.fields": "type,url,preview_image_url,width,height,alt_text",
});

// ---------------------------------------------------------------------------
// Normalization into Kebab's model
// ---------------------------------------------------------------------------

/** X returns post text with these five entities encoded. */
function decodeEntities(text: string): string {
  return text
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    // &amp; last, so "&amp;lt;" survives as the literal "&lt;".
    .replaceAll("&amp;", "&");
}

/**
 * Post text as a reader would see it: t.co shortlinks swapped for their
 * display form, and the trailing shortlink X appends for attached media
 * removed entirely (the media renders as media). Quoted-post links are left
 * in place as visible text — v1 does not render nested quotes.
 */
function normalizeText(raw: unknown, entities: unknown): string {
  let text = typeof raw === "string" ? raw : "";
  const urls = (entities as { urls?: unknown[] } | undefined)?.urls;
  if (Array.isArray(urls)) {
    for (const entry of urls) {
      const item = entry as { url?: unknown; display_url?: unknown };
      if (typeof item?.url !== "string" || item.url.length === 0) continue;
      const display = typeof item.display_url === "string" ? item.display_url : "";
      const isMediaLink =
        display.startsWith("pic.x.com") || display.startsWith("pic.twitter.com");
      text = text.replaceAll(item.url, isMediaLink ? "" : display);
    }
  }
  return decodeEntities(text).replace(/[ \t]+$/gm, "").trim();
}

/**
 * X hands back the 48pt "_normal" avatar. The same object exists at
 * _400x400, which is what a retina card needs; the swap is a documented,
 * long-stable URL convention and costs no extra request.
 */
function upgradeAvatar(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length === 0) return null;
  return raw.replace("_normal.", "_400x400.");
}

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function optionalInt(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : null;
}

interface NormalizedMedia {
  key: string;
  type: string;
  url: string | null;
  preview_image_url: string | null;
  width: number | null;
  height: number | null;
  alt_text: string | null;
}

function normalizeMedia(data: any, includes: any): NormalizedMedia[] {
  const pool: any[] = Array.isArray(includes?.media) ? includes.media : [];
  if (pool.length === 0) return [];

  const byKey = new Map<string, any>();
  for (const item of pool) {
    if (typeof item?.media_key === "string") byKey.set(item.media_key, item);
  }

  // attachments.media_keys is the authoritative order the author chose.
  const keys: unknown = data?.attachments?.media_keys;
  const ordered = Array.isArray(keys)
    ? keys.map((k) => (typeof k === "string" ? byKey.get(k) : undefined)).filter(Boolean)
    : [];
  const source = ordered.length > 0 ? ordered : pool;

  // X permits at most 4 attachments; the slice is a defensive ceiling.
  return source.slice(0, 4).map((item: any) => ({
    key: typeof item.media_key === "string" ? item.media_key : "",
    type: typeof item.type === "string" ? item.type : "unknown",
    url: optionalString(item.url),
    preview_image_url: optionalString(item.preview_image_url),
    width: optionalInt(item.width),
    height: optionalInt(item.height),
    alt_text: optionalString(item.alt_text),
  }));
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/**
 * A typed failure. `retryable` is the client's whole decision procedure: false
 * is persisted as a permanent verdict and never looked up again, true leaves
 * the source unresolved so a bounded later attempt may run.
 *
 * `detail` is only ever set from an upstream X error body — public API error
 * text, never a header, credential, or anything derived from the token.
 */
function fail(
  status: number,
  code: string,
  retryable: boolean,
  message: string,
  detail?: string,
): Response {
  const error: Record<string, unknown> = { code, retryable, message };
  if (detail) error.detail = detail.slice(0, 300);
  return json({ error }, status);
}

/** Compact, non-secret upstream text for operator diagnosis. */
function upstreamDetail(body: unknown): string | undefined {
  if (typeof body !== "string" || body.length === 0) return undefined;
  return body.replace(/\s+/g, " ").slice(0, 300);
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return fail(405, "invalid_request", false, "Use POST.");
  }

  // --- Caller must be a signed-in Kebab user -------------------------------
  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    return fail(401, "unauthorized", false, "Missing authorization.");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error("x-post: project environment incomplete");
    return fail(500, "server_error", true, "Server misconfigured.");
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData?.user) {
    return fail(401, "unauthorized", false, "Sign-in required.");
  }

  // --- Input ---------------------------------------------------------------
  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return fail(400, "invalid_request", false, "Body must be JSON.");
  }

  const body = (payload ?? {}) as { url?: unknown; post_id?: unknown };
  let ref: XPostRef | null = null;

  if (typeof body.url === "string" && body.url.length > 0) {
    if (body.url.length > 2_048) {
      return fail(400, "invalid_request", false, "URL too long.");
    }
    ref = parseXPostURL(body.url);
    if (!ref) {
      return fail(400, "unsupported_url", false, "Not a public X post URL.");
    }
  } else if (typeof body.post_id === "string" && POST_ID_PATTERN.test(body.post_id)) {
    ref = { postId: body.post_id, username: null };
  } else {
    return fail(400, "invalid_request", false, "Provide `url` or `post_id`.");
  }

  // --- Upstream ------------------------------------------------------------
  const bearer = Deno.env.get("X_BEARER_TOKEN");
  if (!bearer) {
    console.error("x-post: X_BEARER_TOKEN is not configured");
    return fail(500, "server_error", false, "X lookup is not configured.");
  }

  let upstream: Response;
  let rawBody: string;
  try {
    upstream = await fetch(`${X_POST_ENDPOINT}/${ref.postId}?${X_QUERY}`, {
      method: "GET",
      headers: {
        // The only place the token is used. Never logged, never echoed.
        Authorization: `Bearer ${bearer}`,
        Accept: "application/json",
        "User-Agent": "kebab-x-post/1",
      },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    rawBody = await upstream.text();
  } catch {
    // Timeout / DNS / TLS — transient by nature.
    console.error("x-post: upstream unreachable");
    return fail(503, "upstream_unavailable", true, "X did not respond.");
  }

  if (!upstream.ok) {
    console.error(`x-post: upstream status ${upstream.status}`);
    const detail = upstreamDetail(rawBody);
    switch (upstream.status) {
      case 401:
        return fail(502, "upstream_auth", false, "X rejected Kebab's credentials.", detail);
      case 402:
        return fail(502, "upstream_quota", false, "X API credits unavailable.", detail);
      case 403:
        return fail(403, "forbidden", false, "This post is not publicly accessible.", detail);
      case 404:
        return fail(404, "not_found", false, "This post no longer exists.", detail);
      case 429:
        return fail(429, "rate_limited", true, "X is rate limiting Kebab.", detail);
      case 500:
      case 502:
      case 503:
      case 504:
        return fail(503, "upstream_unavailable", true, "X is unavailable.", detail);
      default:
        return fail(502, "upstream_error", false, "X returned an unexpected error.", detail);
    }
  }

  let parsed: any;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    console.error("x-post: upstream body was not JSON");
    return fail(502, "decoding_failed", false, "X returned an unreadable response.");
  }

  const data = parsed?.data;
  if (!data || typeof data.id !== "string") {
    // A 200 with only `errors` — the usual shape for deleted, protected, or
    // suspended-author posts.
    const first = Array.isArray(parsed?.errors) ? parsed.errors[0] : undefined;
    const title = typeof first?.title === "string" ? first.title.toLowerCase() : "";
    const detail = upstreamDetail(typeof first?.detail === "string" ? first.detail : undefined);
    if (title.includes("not found")) {
      return fail(404, "not_found", false, "This post no longer exists.", detail);
    }
    if (title.includes("authorization") || title.includes("forbidden")) {
      return fail(403, "forbidden", false, "This post is not publicly accessible.", detail);
    }
    return fail(502, "upstream_error", false, "X returned no post.", detail);
  }

  const includes = parsed?.includes ?? {};
  const users: any[] = Array.isArray(includes.users) ? includes.users : [];
  const author = users.find((u) => u?.id === data.author_id) ?? users[0];
  if (!author || typeof author.username !== "string" || typeof author.id !== "string") {
    // Nothing to attribute the post to — a Kebab card cannot be built, and a
    // retry would return the same thing.
    console.error("x-post: response carried no author expansion");
    return fail(422, "unsupported_post", false, "Post author unavailable.");
  }

  const media = normalizeMedia(data, includes);
  const unsupported = media.find((m) => m.type !== "photo")?.type ?? null;

  return json({
    status: "resolved",
    post: {
      post_id: data.id,
      url: `https://x.com/${author.username}/status/${data.id}`,
      text: normalizeText(data.text, data.entities),
      created_at: optionalString(data.created_at),
      author: {
        id: author.id,
        name: typeof author.name === "string" ? author.name : author.username,
        username: author.username,
        profile_image_url: upgradeAvatar(author.profile_image_url),
        verified: typeof author.verified === "boolean" ? author.verified : null,
        verified_type: optionalString(author.verified_type),
      },
      media,
      unsupported_media: unsupported,
    },
  }, 200);
});
