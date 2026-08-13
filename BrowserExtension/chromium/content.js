// @ts-check
(function startContentScript() {
  "use strict";
  const core = globalThis.InvisibleTranslatorCore;
  const api = globalThis.browser ?? globalThis.chrome;
  if (!core || !api || !core.isAllowedURL(location.href)) return;

  const rule = core.ruleForHost(location.hostname);
  if (!rule) return;
  const pendingRecordTTL = 30_000;
  const maximumPendingRecords = 256;
  const state = {
    autoMode: false,
    hoverMode: false,
    hideOriginal: false,
    observer: null,
    captionObserver: null,
    scanTimer: 0,
    requestCounter: 0,
    latestSubtitle: "",
    hoverTimer: 0,
    lastHoverTarget: null,
    records: new Map(),
    hoverHandler: null
  };

  function makeRequestId(prefix) {
    state.requestCounter += 1;
    return `${prefix}-${Date.now().toString(36)}-${state.requestCounter.toString(36)}`;
  }

  function findContentRoot() {
    for (const selector of rule.rootSelectors) {
      const root = document.querySelector(selector);
      if (root) return root;
    }
    return null;
  }

  function isIgnoredTextNode(node) {
    const parent = node.parentElement;
    if (!parent) return true;
    if (parent.closest("[data-invisible-translation], [data-invisible-translator-source]")) return true;
    return /^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA|INPUT|CODE|PRE|SVG)$/i.test(parent.tagName);
  }

  function candidateTextNodes(root) {
    const candidates = [];
    const seen = new Set();
    // Site rules restrict expensive traversal to known message/content areas.
    const containers = [];
    for (const selector of rule.textSelectors) {
      root.querySelectorAll(selector).forEach((element) => containers.push(element));
    }
    const scanRoots = containers.length ? containers : [root]; // generic fallback, still within content root
    for (const scanRoot of scanRoots) {
      const walker = document.createTreeWalker(scanRoot, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (seen.has(node) || isIgnoredTextNode(node)) continue;
        const text = node.data.replace(/\s+/g, " ").trim();
        if (text.length < 2) continue;
        seen.add(node);
        candidates.push({ node, text });
      }
    }
    return candidates;
  }

  function scheduleScan() {
    if (!state.autoMode || state.scanTimer) return;
    state.scanTimer = window.setTimeout(() => {
      state.scanTimer = 0;
      if (!state.autoMode) return;
      scanAndRequest();
    }, 180);
  }

  function pruneRecords(now = Date.now()) {
    for (const [id, record] of state.records) {
      if (now - record.createdAt > pendingRecordTTL || record.node && !record.node.isConnected || record.target && !record.target.isConnected) {
        state.records.delete(id);
      }
    }
    while (state.records.size > maximumPendingRecords) {
      const oldest = state.records.keys().next().value;
      if (oldest === undefined) break;
      state.records.delete(oldest);
    }
  }

  function requestTranslation(kind, items) {
    if ((kind === "page" || kind === "subtitle") && !state.autoMode) return;
    if (kind === "hover" && !state.hoverMode) return;
    const packed = core.packBatch(items);
    if (!packed.accepted.length) return;
    const requestId = makeRequestId(kind);
    const createdAt = Date.now();
    pruneRecords(createdAt);
    if (kind !== "subtitle") {
      for (const item of packed.accepted) {
        state.records.set(item.id, { ...item, createdAt, kind });
      }
      pruneRecords(createdAt);
    }
    const delivery = api.runtime.sendMessage({
      type: "translationRequest",
      requestId,
      payload: { kind, items: packed.accepted.map(({ id, text }) => ({ id, text })), settings: { hideOriginal: state.hideOriginal } }
    });
    if (delivery && typeof delivery.catch === "function") delivery.catch(() => undefined);
  }

  function scanAndRequest() {
    if (!state.autoMode) return;
    const root = findContentRoot();
    if (!root) return;
    const items = candidateTextNodes(root).map(({ node, text }) => ({ id: makeRequestId("text"), node, text }));
    requestTranslation("page", items);
  }

  function applyTextTranslation(record, translation) {
    if (!record?.node?.isConnected || !translation) return;
    const source = document.createElement("span");
    source.dataset.invisibleTranslatorSource = "true";
    source.textContent = record.text;
    if (state.hideOriginal) source.classList.add("invisible-translator-hidden-original");
    const result = document.createElement("span");
    result.dataset.invisibleTranslation = "true";
    result.textContent = translation;
    // Replacing only the text node preserves the surrounding link, emphasis,
    // font and other rich-text structure supplied by the website.
    record.node.replaceWith(source, result);
  }

  function subtitleContainer() {
    return document.querySelector("#movie_player .ytp-caption-window-container");
  }

  function observeYouTubeCaptions(root) {
    if (!location.hostname.endsWith("youtube.com")) return;
    const captions = subtitleContainer();
    if (!captions) return;
    const onCaptionChange = () => {
      if (!state.autoMode) return;
      const cue = core.normaliseCaption(captions.textContent || "");
      if (!cue || cue === state.latestSubtitle) return;
      state.latestSubtitle = core.mergeCaption(state.latestSubtitle, cue);
      requestTranslation("subtitle", [{ id: makeRequestId("subtitle"), text: state.latestSubtitle, caption: cue }]);
    };
    state.captionObserver?.disconnect();
    state.captionObserver = new MutationObserver(onCaptionChange);
    // Caption-only observer: never observes document/body.
    state.captionObserver.observe(captions, { subtree: true, childList: true, characterData: true });
    root.dataset.invisibleCaptionObserver = "true";
  }

  function showSubtitle(result) {
    const captions = subtitleContainer();
    if (!captions || !result?.translation) return;
    let overlay = captions.querySelector(".invisible-translator-subtitle");
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.className = "invisible-translator-subtitle";
      captions.append(overlay);
    }
    const source = core.splitCaptionLines(result.source || "").join("\n");
    const translation = core.splitCaptionLines(result.translation).join("\n");
    overlay.replaceChildren(
      document.createTextNode(source), document.createElement("br"),
      Object.assign(document.createElement("span"), { className: "invisible-translator-subtitle__translation", textContent: translation })
    );
  }

  function showHover(record, translation) {
    if (!record?.target?.isConnected || !translation) return;
    document.querySelector(".invisible-translator-hover")?.remove();
    const bubble = document.createElement("div");
    bubble.className = "invisible-translator-hover";
    bubble.dataset.invisibleTranslation = "true";
    bubble.textContent = translation;
    const rect = record.target.getBoundingClientRect();
    Object.assign(bubble.style, {
      position: "fixed", zIndex: "2147483647", maxWidth: "min(420px, 80vw)",
      background: "var(--invisible-translator-bg)", borderRadius: "6px", padding: "5px 8px",
      left: `${Math.max(8, rect.left)}px`, top: `${Math.min(window.innerHeight - 36, rect.bottom + 6)}px`, pointerEvents: "none"
    });
    document.documentElement.append(bubble);
    window.setTimeout(() => bubble.remove(), 4500);
  }

  function handleNativeResult(message) {
    if (message.error || !message.result) return;
    const result = message.result;
    if (result.kind === "subtitle") {
      showSubtitle(result);
      return;
    }
    for (const item of result.items || []) {
      const record = state.records.get(item.id);
      state.records.delete(item.id);
      if (result.kind === "hover") showHover(record, item.translation);
      else applyTextTranslation(record, item.translation);
    }
  }

  function startObserver() {
    const root = findContentRoot();
    if (!root || state.observer) return;
    state.observer = new MutationObserver(scheduleScan);
    // This is intentionally the content root rather than document/body.
    state.observer.observe(root, { subtree: true, childList: true, characterData: true });
    observeYouTubeCaptions(root);
    scheduleScan();
  }

  function setSettings(settings) {
    const next = settings || {};
    state.autoMode = Boolean(next.autoMode);
    state.hideOriginal = Boolean(next.hideOriginal);
    if (state.autoMode) startObserver();
    if (!state.autoMode) {
      window.clearTimeout(state.scanTimer);
      state.scanTimer = 0;
      state.observer?.disconnect();
      state.observer = null;
      state.captionObserver?.disconnect();
      state.captionObserver = null;
      for (const [id, record] of state.records) {
        if (record.kind === "page") state.records.delete(id);
      }
    }
    if (Boolean(next.hoverMode) && !state.hoverMode) startHoverTranslation();
    if (!Boolean(next.hoverMode) && state.hoverMode) stopHoverTranslation();
    state.hoverMode = Boolean(next.hoverMode);
  }

  function startHoverTranslation() {
    if (state.hoverHandler) return;
    state.hoverHandler = (event) => {
      const target = event.target instanceof Element ? event.target : null;
      if (!target || target === state.lastHoverTarget) return;
      state.lastHoverTarget = target;
      window.clearTimeout(state.hoverTimer);
      state.hoverTimer = window.setTimeout(() => {
        const text = (target.textContent || "").replace(/\s+/g, " ").trim();
        if (text.length >= 2 && core.utf8ByteLength(text) <= core.maxBatchBytes) {
          requestTranslation("hover", [{ id: makeRequestId("hover"), text, target }]);
        }
      }, 520);
    };
    document.addEventListener("pointermove", state.hoverHandler, { passive: true });
  }

  function stopHoverTranslation() {
    if (!state.hoverHandler) return;
    document.removeEventListener("pointermove", state.hoverHandler);
    state.hoverHandler = null;
    window.clearTimeout(state.hoverTimer);
    for (const [id, record] of state.records) {
      if (record.kind === "hover") state.records.delete(id);
    }
  }

  api.runtime.onMessage.addListener((message) => {
    if (message?.type === "nativeTranslationResult") handleNativeResult(message);
    if (message?.type === "extensionSettings") setSettings(message.settings);
  });
  window.addEventListener("popstate", () => {
    state.observer?.disconnect();
    state.observer = null;
    if (state.autoMode) startObserver();
  });
  // The native app explicitly enables auto/hover mode for each user-authorised
  // domain. Until then this script does not scan, observe, or send content.
})();
