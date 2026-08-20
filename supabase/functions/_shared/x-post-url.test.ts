// Server-side URL recognition, held to the same cases as
// kebabTests/SourceClassifierTests.swift. If these two ever disagree, the
// client will spend a billed X read on something the function then rejects.
//
//   deno test supabase/functions/_shared/x-post-url.test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { parseXPostURL } from "./x-post-url.ts";

const ID = "1234567890123456789";

Deno.test("recognizes every accepted post URL shape", () => {
  const accepted = [
    `https://x.com/kebabapp/status/${ID}`,
    `https://www.x.com/kebabapp/status/${ID}`,
    `https://twitter.com/kebabapp/status/${ID}`,
    `https://www.twitter.com/kebabapp/status/${ID}`,
    `https://mobile.twitter.com/kebabapp/status/${ID}`,
    `https://m.x.com/kebabapp/status/${ID}`,
    `http://x.com/kebabapp/status/${ID}`,
    `https://twitter.com/kebabapp/statuses/${ID}`,
    `https://x.com/kebabapp/status/${ID}?s=20&t=abcDEF`,
    `https://x.com/kebabapp/status/${ID}?utm_source=newsletter`,
    `https://x.com/kebabapp/status/${ID}#anchor`,
    `https://x.com/kebabapp/status/${ID}/photo/1`,
    `https://x.com/kebabapp/status/${ID}/video/1`,
  ];
  for (const url of accepted) {
    assertEquals(parseXPostURL(url), { postId: ID, username: "kebabapp" }, url);
  }
});

Deno.test("reserved routing forms carry no handle", () => {
  assertEquals(parseXPostURL(`https://x.com/i/web/status/${ID}`), {
    postId: ID,
    username: null,
  });
  assertEquals(parseXPostURL(`https://x.com/i/status/${ID}`), {
    postId: ID,
    username: null,
  });
});

Deno.test("rejects X URLs that are not posts", () => {
  const rejected = [
    "https://x.com/kebabapp",
    "https://x.com/kebabapp/with_replies",
    "https://x.com/kebabapp/media",
    "https://x.com",
    "https://x.com/",
    "https://x.com/home",
    "https://x.com/explore",
    "https://x.com/search?q=incentive%20alignment",
    "https://x.com/hashtag/design",
    "https://x.com/messages",
    "https://x.com/notifications",
    "https://x.com/i/spaces/1YpKkZWyQAvxj",
    "https://x.com/i/lists/12345",
    "https://x.com/compose/post",
    "https://twitter.com/settings/account",
    `https://x.com/kebabapp/status/${ID}/likes`,
    `https://x.com/kebabapp/status/${ID}/retweets`,
    `https://x.com/kebabapp/status/${ID}/analytics`,
    "https://x.com/kebabapp/status/notanumber",
    "https://x.com/kebabapp/status/",
    "https://x.com/kebabapp/status/12345678901234567890123456789",
    "https://x.com/this-handle-is-way-too-long/status/1",
    "https://x.com/bad.handle/status/1",
  ];
  for (const url of rejected) {
    assertEquals(parseXPostURL(url), null, url);
  }
});

Deno.test("rejects foreign, lookalike and malformed hosts", () => {
  const rejected = [
    `https://nytimes.com/kebabapp/status/${ID}`,
    `https://x.com.evil.example/kebabapp/status/${ID}`,
    `https://notx.com/kebabapp/status/${ID}`,
    `https://twitter.com.phish.example/kebabapp/status/${ID}`,
    `https://fixupx.com/kebabapp/status/${ID}`,
    `https://vxtwitter.com/kebabapp/status/${ID}`,
    "javascript:alert(1)//x.com/a/status/1",
    `ftp://x.com/kebabapp/status/${ID}`,
    "",
    "   ",
    "not a url at all",
  ];
  for (const url of rejected) {
    assertEquals(parseXPostURL(url), null, url);
  }
});
