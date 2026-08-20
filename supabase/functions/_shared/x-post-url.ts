// Public X post URL recognition.
//
// Server-side authority for "is this a post, and which one?". Deliberately
// mirrors `SourceClassifier.swift` — the client classifies to decide routing,
// this decides what actually gets looked up. Kept in its own module so it can
// be exercised directly (see x-post-url.test.ts).

const X_HOSTS = new Set([
  "x.com",
  "www.x.com",
  "mobile.x.com",
  "m.x.com",
  "twitter.com",
  "www.twitter.com",
  "mobile.twitter.com",
  "m.twitter.com",
]);

// Only X's own per-media deep links may trail the post id. Anything else
// (/likes, /retweets, /analytics, a profile path, search, home) is not a post.
const MEDIA_SUFFIXES = new Set(["photo", "video", "gif"]);
const USERNAME_PATTERN = /^[A-Za-z0-9_]{1,15}$/;
export const POST_ID_PATTERN = /^[0-9]{1,25}$/;
const MEDIA_INDEX_PATTERN = /^[0-9]{1,2}$/;

export interface XPostRef {
  postId: string;
  /** null for /i/web/status/… and the reserved "i" handle. */
  username: string | null;
}

function isStatusSegment(segment: string): boolean {
  const lower = segment.toLowerCase();
  return lower === "status" || lower === "statuses";
}

/** Parses a public X post URL. Returns null for every other kind of X URL. */
export function parseXPostURL(raw: string): XPostRef | null {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (!X_HOSTS.has(url.hostname.toLowerCase())) return null;

  // Query and fragment are share decoration (?s=, ?t=, utm_*) — always dropped.
  const parts = url.pathname.split("/").filter((p) => p.length > 0);

  let username: string | null = null;
  let idIndex: number;

  if (
    parts.length >= 4 &&
    parts[0].toLowerCase() === "i" &&
    parts[1].toLowerCase() === "web" &&
    isStatusSegment(parts[2])
  ) {
    idIndex = 3;
  } else if (parts.length >= 3 && isStatusSegment(parts[1])) {
    if (!USERNAME_PATTERN.test(parts[0])) return null;
    // "i" is reserved routing, never a real handle — the API's author is truth.
    username = parts[0].toLowerCase() === "i" ? null : parts[0];
    idIndex = 2;
  } else {
    return null;
  }

  const postId = parts[idIndex];
  if (!POST_ID_PATTERN.test(postId)) return null;

  const trailing = parts.slice(idIndex + 1);
  if (trailing.length > 0) {
    if (trailing.length !== 2) return null;
    if (!MEDIA_SUFFIXES.has(trailing[0].toLowerCase())) return null;
    if (!MEDIA_INDEX_PATTERN.test(trailing[1])) return null;
  }

  return { postId, username };
}
