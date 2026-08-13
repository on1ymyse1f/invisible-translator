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
  const protocolVersion = 1;
  const translationKinds = new Set(["page", "hover", "subtitle"]);
  const allowedOrigins = new Set([...allowedHosts].map((host) => `https://${host}`));
  // Never scan or hover-translate drafts, controls, navigation chrome, code,
  // or translator-owned output. The content script applies this selector
  // before any text can enter a native-messaging request.
  const ignoredContainerSelector = [
    "[data-invisible-translation]", "[data-invisible-translator-source]",
    "input", "textarea", "[contenteditable]:not([contenteditable='false'])",
    "[role='textbox']", "form", "button", "nav", "script", "style",
    "noscript", "code", "pre", "svg"
  ].join(", ");

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
      // Only tweet/post bodies. Names, handles, timestamps, views, trends and
      // interaction chrome are intentionally outside automatic translation.
      textSelectors: ["article [data-testid='tweetText']"]
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
      // URL normalises an explicit default port away, so inspect the original
      // authority too: `https://chatgpt.com:443/` is not an allowed origin.
      const raw = String(url);
      const authority = raw.slice(raw.indexOf("//") + 2).split(/[/?#]/, 1)[0];
      return parsed.protocol === "https:" &&
        !parsed.port && !parsed.username && !parsed.password &&
        !authority.includes(":") && !authority.includes("@") &&
        allowedHosts.has(parsed.hostname.toLowerCase());
    } catch (_) {
      return false;
    }
  }

  /** Returns a canonical, explicitly allow-listed origin or an empty string. */
  function allowedOrigin(url) {
    if (!isAllowedURL(url)) return "";
    return new URL(url).origin;
  }

  /** Origins in protocol messages must be canonical (no slash, port, or credentials). */
  function isAllowedOrigin(origin) {
    if (typeof origin !== "string") return false;
    try {
      const parsed = new URL(origin);
      return parsed.origin === origin && allowedOrigins.has(origin) &&
        parsed.protocol === "https:" && !parsed.port && !parsed.username && !parsed.password;
    } catch (_) {
      return false;
    }
  }

  function isTranslationKind(kind) {
    return typeof kind === "string" && translationKinds.has(kind);
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

  function isPlainObject(value) {
    return Boolean(value) && typeof value === "object" && !Array.isArray(value);
  }

  /**
   * Checks the shared message budget without transforming its payload.  The
   * service worker repeats this check because page contexts are not a trust
   * boundary for native-messaging input.
   */
  function validateItems(items, textField = "text", allowEmpty = false) {
    if (!Array.isArray(items) || items.length < 1 || items.length > maxBatchItems) return false;
    let bytes = 0;
    for (const item of items) {
      if (!isPlainObject(item) || typeof item.id !== "string" || !item.id || utf8ByteLength(item.id) > 1024) return false;
      if (typeof item[textField] !== "string" || (!allowEmpty && !item[textField])) return false;
      bytes += utf8ByteLength(item[textField]);
      if (bytes > maxBatchBytes) return false;
    }
    return true;
  }

  function validateTranslationRequest(message) {
    return isPlainObject(message) && message.type === "translationRequest" &&
      message.version === protocolVersion && typeof message.requestId === "string" && message.requestId &&
      utf8ByteLength(message.requestId) <= 1024 && isAllowedOrigin(message.origin) &&
      isTranslationKind(message.kind) && isPlainObject(message.payload) &&
      message.payload.kind === message.kind && validateItems(message.payload.items);
  }

  function validateSettingsQuery(message) {
    return isPlainObject(message) && message.type === "settingsQuery" &&
      message.version === protocolVersion && isAllowedOrigin(message.origin) &&
      Object.keys(message).every((key) => ["type", "version", "origin"].includes(key));
  }

  function validateTranslationResponse(message) {
    if (!isPlainObject(message) || message.type !== "translationResult" || message.version !== protocolVersion ||
      typeof message.requestId !== "string" || !message.requestId ||
      !isAllowedOrigin(message.origin) || !isTranslationKind(message.kind)) return false;
    if (message.kind === "subtitle") {
      return typeof message.translation === "string" && message.translation.length > 0 &&
        utf8ByteLength(message.translation) <= maxBatchBytes &&
        (message.source === undefined || (typeof message.source === "string" &&
          utf8ByteLength(message.source) + utf8ByteLength(message.translation) <= maxBatchBytes));
    }
    return validateItems(message.items, "translation", true);
  }

  function validateExtensionSettings(message) {
    const settings = message?.settings;
    return isPlainObject(message) && message.type === "extensionSettings" &&
      message.version === protocolVersion && isAllowedOrigin(message.origin) && isPlainObject(settings) &&
      Object.keys(settings).every((key) => ["autoMode", "hoverMode", "hideOriginal"].includes(key)) &&
      ["autoMode", "hoverMode", "hideOriginal"].every((key) =>
        settings[key] === undefined || typeof settings[key] === "boolean");
  }

  function hasIgnoredHoverBoundary(target) {
    if (!target || typeof target.closest !== "function" || typeof target.querySelector !== "function") return true;
    return Boolean(target.closest(ignoredContainerSelector) || target.querySelector(ignoredContainerSelector));
  }

  function settingsRevokeAccess(previous, next) {
    const before = previous || {};
    const after = next || {};
    return (Boolean(before.autoMode) && !Boolean(after.autoMode)) ||
      (Boolean(before.hoverMode) && !Boolean(after.hoverMode));
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
    // Streaming caption renderers commonly replace a partial cue with a
    // longer version of the same cue. Treat that as a revision instead of
    // duplicating the stable prefix ("Hello" -> "Hello world").
    if (right.startsWith(left)) return right;
    if (left.startsWith(right)) return left;
    const maximumOverlap = Math.min(left.length, right.length);
    for (let overlap = maximumOverlap; overlap >= 2; overlap -= 1) {
      if (left.slice(-overlap) === right.slice(0, overlap)) {
        return normaliseCaption(`${left}${right.slice(overlap)}`);
      }
    }
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
    allowedHosts, allowedOrigins, maxBatchItems, maxBatchBytes, protocolVersion, translationKinds,
    ignoredContainerSelector,
    siteRules, utf8ByteLength, isAllowedURL, allowedOrigin, isAllowedOrigin, isTranslationKind,
    ruleForHost, packBatch, isPlainObject, validateItems, validateTranslationRequest,
    validateSettingsQuery, validateTranslationResponse, validateExtensionSettings,
    hasIgnoredHoverBoundary, settingsRevokeAccess,
    normaliseCaption, mergeCaption, splitCaptionLines
  };
  global.InvisibleTranslatorCore = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
