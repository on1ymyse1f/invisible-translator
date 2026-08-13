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
    pendingRequests: new Map(),
    generation: 0,
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
    return Boolean(parent.closest(core.ignoredContainerSelector));
  }

  function candidateTextNodes(root) {
    const candidates = [];
    const seen = new Set();
    // Site rules restrict expensive traversal to known message/content areas.
    const containers = [];
    for (const selector of rule.textSelectors) {
      root.querySelectorAll(selector).forEach((element) => containers.push(element));
    }
    // Fail closed when a known site's message/content rule no longer matches.
    // Falling back to the whole root can include an unsent composer draft.
    for (const scanRoot of containers) {
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
    for (const [requestId, record] of state.pendingRequests) {
      if (now - record.createdAt > pendingRecordTTL || record.generation !== state.generation) {
        state.pendingRequests.delete(requestId);
        for (const [itemId, itemRecord] of state.records) {
          if (itemRecord.requestId === requestId) state.records.delete(itemId);
        }
      }
    }
  }

  function invalidateRequests() {
    state.generation += 1;
    state.records.clear();
    state.pendingRequests.clear();
  }

  function requestTranslation(kind, items) {
    if ((kind === "page" || kind === "subtitle") && !state.autoMode) return;
    if (kind === "hover" && !state.hoverMode) return;
    const packed = core.packBatch(items);
    if (!packed.accepted.length) return;
    const requestId = makeRequestId(kind);
    const createdAt = Date.now();
    pruneRecords(createdAt);
    const origin = core.allowedOrigin(location.href);
    const message = {
      type: "translationRequest",
      version: core.protocolVersion,
      requestId,
      origin,
      kind,
      payload: { kind, items: packed.accepted.map(({ id, text }) => ({ id, text })) }
    };
    // The content side enforces the same shape/budget that the worker repeats
    // before data reaches native messaging.
    if (!core.validateTranslationRequest(message)) return;
    state.pendingRequests.set(requestId, { kind, origin, createdAt, generation: state.generation });
    if (kind !== "subtitle") {
      for (const item of packed.accepted) {
        state.records.set(item.id, { ...item, createdAt, kind, requestId, generation: state.generation });
      }
      pruneRecords(createdAt);
    }
    const delivery = api.runtime.sendMessage(message);
    if (delivery && typeof delivery.catch === "function") delivery.catch(() => undefined);
  }

  function requestSettingsBootstrap() {
    const message = {
      type: "settingsQuery",
      version: core.protocolVersion,
      origin: core.allowedOrigin(location.href)
    };
    // This message contains no page text, selection, title, URL path or DOM
    // identifier. It can only ask the native app about the current exact
    // allow-listed origin.
    if (!core.validateSettingsQuery(message)) return;
    const delivery = api.runtime.sendMessage(message);
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
    if (!message || message.type !== "nativeTranslationResult" ||
      message.version !== core.protocolVersion || !core.validateTranslationResponse(message.result) ||
      message.requestId !== message.result.requestId || message.origin !== message.result.origin ||
      message.kind !== message.result.kind) return;
    const request = state.pendingRequests.get(message.requestId);
    if (!request || request.generation !== state.generation ||
      request.origin !== message.origin || request.kind !== message.kind ||
      Date.now() - request.createdAt > pendingRecordTTL) return;
    state.pendingRequests.delete(message.requestId);
    const result = message.result;
    if (result.kind === "subtitle") {
      showSubtitle(result);
      return;
    }
    for (const item of result.items || []) {
      const record = state.records.get(item.id);
      state.records.delete(item.id);
      if (!record || record.requestId !== message.requestId || record.generation !== state.generation) continue;
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
    const previous = {
      autoMode: state.autoMode,
      hoverMode: state.hoverMode
    };
    if (core.settingsRevokeAccess(previous, next)) {
      // A late native result must never modify the page after the user or App
      // revokes this origin's automatic/hover permission.
      invalidateRequests();
    }
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
      if (core.hasIgnoredHoverBoundary(target) || target === state.lastHoverTarget) return;
      state.lastHoverTarget = target;
      window.clearTimeout(state.hoverTimer);
      state.hoverTimer = window.setTimeout(() => {
        if (!target.isConnected || core.hasIgnoredHoverBoundary(target)) return;
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
    if (message?.type === "extensionSettings" && core.validateExtensionSettings(message) &&
      message.origin === core.allowedOrigin(location.href)) setSettings(message.settings);
  });
  window.addEventListener("popstate", () => {
    invalidateRequests();
    state.observer?.disconnect();
    state.observer = null;
    if (state.autoMode) startObserver();
  });
  // The native app explicitly enables auto/hover mode for each user-authorised
  // domain. Until then this script does not scan, observe, or send content.
  requestSettingsBootstrap();
})();
