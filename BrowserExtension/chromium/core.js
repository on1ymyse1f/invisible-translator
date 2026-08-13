// @ts-check
/*
 * Shared, dependency-free logic.  It deliberately contains no network code:
 * all translation requests are handed to the signed native companion.
 */
(function attachCore(global) {
  "use strict";

  /** @type {ReadonlySet<string>} */
  const allowedHosts = new Set([
    "chatgpt.com", "chat.openai.com", "claude.ai", "x.com", "twitter.com",
    "youtube.com", "www.youtube.com"
  ]);
  const maxBatchItems = 64;
  const maxBatchBytes = 256 * 1024;

  const siteRules = Object.freeze({
    chatgpt: {
      hosts: ["chatgpt.com", "chat.openai.com"],
      rootSelectors: ["main"],
      textSelectors: ["[data-message-author-role]", "article"]
    },
    claude: {
      hosts: ["claude.ai"],
      rootSelectors: ["main", "[data-testid='chat-messages']"],
      textSelectors: ["[data-test-render-count]", "[data-is-streaming]", "article"]
    },
    x: {
      hosts: ["x.com", "twitter.com"],
      rootSelectors: ["main", "[data-testid='primaryColumn']"],
      textSelectors: ["article [lang]", "article"]
    },
    youtube: {
      hosts: ["youtube.com", "www.youtube.com"],
      rootSelectors: ["#movie_player", "#primary"],
      textSelectors: ["#movie_player .ytp-caption-window-container", "#description-inline-expander"]
    }
  });

  function utf8ByteLength(text) {
    return new TextEncoder().encode(text).byteLength;
  }

  function isAllowedURL(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" && allowedHosts.has(parsed.hostname.toLowerCase());
    } catch (_) {
      return false;
    }
  }

  function ruleForHost(hostname) {
    const host = hostname.toLowerCase();
    return Object.values(siteRules).find((rule) => rule.hosts.includes(host)) || null;
  }

  /**
   * Keeps source text in one batch under both segment and UTF-8 byte budgets.
   * Oversized text is not silently truncated; it is returned to the caller to
   * be split by the native app's structure-aware long-text pipeline.
   */
  function packBatch(items, maxItems = maxBatchItems, maxBytes = maxBatchBytes) {
    const accepted = [];
    const deferred = [];
    let bytes = 0;
    for (const item of items) {
      const itemBytes = utf8ByteLength(item.text || "");
      if (!item.text || itemBytes > maxBytes || accepted.length >= maxItems || bytes + itemBytes > maxBytes) {
        deferred.push(item);
        continue;
      }
      accepted.push(item);
      bytes += itemBytes;
    }
    return { accepted, deferred, bytes };
  }

  function normaliseCaption(text) {
    return String(text || "").replace(/\s+/g, " ").trim();
  }

  /**
   * Merges fragmented DOM captions without inventing words.  It favours an
   * existing sentence boundary, then a natural whitespace boundary.
   */
  function mergeCaption(previous, next, maxCharacters = 180) {
    const left = normaliseCaption(previous);
    const right = normaliseCaption(next);
    if (!left) return right;
    if (!right || left.endsWith(right)) return left;
    const merged = `${left} ${right}`;
    if (merged.length <= maxCharacters) return merged;
    const punctuation = Math.max(
      merged.lastIndexOf("。", maxCharacters), merged.lastIndexOf("！", maxCharacters),
      merged.lastIndexOf("？", maxCharacters), merged.lastIndexOf(".", maxCharacters),
      merged.lastIndexOf("!", maxCharacters), merged.lastIndexOf("?", maxCharacters)
    );
    const whitespace = merged.lastIndexOf(" ", maxCharacters);
    const cut = Math.max(punctuation, whitespace);
    return merged.slice(0, cut > 20 ? cut + 1 : maxCharacters).trim();
  }

  function splitCaptionLines(text, maxCharacters = 42) {
    const source = normaliseCaption(text);
    if (source.length <= maxCharacters) return [source];
    const lines = [];
    let remaining = source;
    while (remaining.length > maxCharacters) {
      const section = remaining.slice(0, maxCharacters + 1);
      const punctuation = Math.max(
        section.lastIndexOf("。"), section.lastIndexOf("！"), section.lastIndexOf("？"),
        section.lastIndexOf("."), section.lastIndexOf("!"), section.lastIndexOf("?"), section.lastIndexOf(" ")
      );
      const cut = punctuation > Math.floor(maxCharacters * 0.45) ? punctuation + 1 : maxCharacters;
      lines.push(remaining.slice(0, cut).trim());
      remaining = remaining.slice(cut).trim();
    }
    if (remaining) lines.push(remaining);
    return lines;
  }

  const api = {
    allowedHosts, maxBatchItems, maxBatchBytes, siteRules, utf8ByteLength,
    isAllowedURL, ruleForHost, packBatch, normaliseCaption, mergeCaption, splitCaptionLines
  };
  global.InvisibleTranslatorCore = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
