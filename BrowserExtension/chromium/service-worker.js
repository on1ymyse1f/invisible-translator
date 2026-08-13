// The service worker is a transport only. It never fetches, stores credentials,
// or selects a cloud provider. The signed native companion owns translation
// policy and keys. Every page-originated field is checked before it crosses the
// native-messaging boundary.
import "./core.js";

const api = globalThis.browser ?? globalThis.chrome;
const core = globalThis.InvisibleTranslatorCore;
const nativeHostName = "com.on1ymyse1f.InvisibleTranslator";
const pendingByRequest = new Map();
const frameGenerations = new Map();
const currentDocuments = new Map();
const pendingRequestTTL = 30_000;
const maximumPendingRequests = 128;

function frameKey(tabId, frameId) {
  return `${tabId}:${frameId}`;
}

function generationFor(tabId, frameId) {
  return frameGenerations.get(frameKey(tabId, frameId)) || 0;
}

function discardPending(predicate) {
  for (const [requestId, record] of pendingByRequest) {
    if (predicate(record)) pendingByRequest.delete(requestId);
  }
}

function prunePendingRequests(now = Date.now()) {
  discardPending((record) => now - record.createdAt > pendingRequestTTL);
  while (pendingByRequest.size >= maximumPendingRequests) {
    const oldest = pendingByRequest.keys().next().value;
    if (oldest === undefined) break;
    pendingByRequest.delete(oldest);
  }
}

function senderBinding(sender) {
  const tabId = sender.tab?.id;
  const frameId = sender.frameId;
  const documentId = sender.documentId;
  const url = sender.url || "";
  const origin = core.allowedOrigin(url);
  if (!Number.isInteger(tabId) || !Number.isInteger(frameId) ||
    typeof documentId !== "string" || !documentId || !origin) return null;
  return { tabId, frameId, documentId, url, origin, generation: generationFor(tabId, frameId) };
}

function deliver(record, message) {
  if (!record || !Number.isInteger(record.tabId)) return;
  const options = { frameId: record.frameId };
  // documentId prevents a late result reaching a replacement document in the
  // same frame on Chromium versions that support it.
  if (record.documentId) options.documentId = record.documentId;
  const delivery = api.tabs.sendMessage(record.tabId, message, options);
  if (delivery && typeof delivery.catch === "function") delivery.catch(() => undefined);
}

function currentBindingMatches(record) {
  const key = frameKey(record.tabId, record.frameId);
  const current = currentDocuments.get(key);
  return record.generation === generationFor(record.tabId, record.frameId) &&
    (!current || (current.documentId === record.documentId && current.origin === record.origin));
}

function matchingAuthorisedTabs(origin) {
  return api.tabs.query({}).then((tabs) => tabs.filter((tab) =>
    Number.isInteger(tab.id) && core.allowedOrigin(tab.url || "") === origin));
}

function broadcastSettingsFromNative(message) {
  if (!core.validateExtensionSettings(message)) return;
  matchingAuthorisedTabs(message.origin)
    .then((tabs) => tabs.forEach((tab) => {
      deliver({ tabId: tab.id, frameId: 0 }, {
        type: "extensionSettings",
        version: core.protocolVersion,
        origin: message.origin,
        settings: message.settings
      });
    }))
    .catch(() => undefined);
}

function handleNativeMessage(message) {
  if (message?.type === "extensionSettings") {
    broadcastSettingsFromNative(message);
    return true;
  }
  prunePendingRequests();
  if (!core.validateTranslationResponse(message)) return false;
  const record = pendingByRequest.get(message.requestId);
  if (!record || !currentBindingMatches(record) ||
    message.origin !== record.origin || message.kind !== record.kind) return false;
  pendingByRequest.delete(message.requestId);
  deliver(record, {
    type: "nativeTranslationResult",
    version: core.protocolVersion,
    requestId: message.requestId,
    origin: message.origin,
    kind: message.kind,
    result: message
  });
  return true;
}

// One request launches one short-lived host process. A persistent native port
// is deliberately avoided, so this does not pin a helper process in memory
// while no translation is taking place.
function sendNativeMessageOnce(message) {
  if (globalThis.browser) {
    return api.runtime.sendNativeMessage(nativeHostName, message);
  }
  return new Promise((resolve, reject) => {
    try {
      api.runtime.sendNativeMessage(nativeHostName, message, (response) => {
        const error = api.runtime.lastError;
        if (error) reject(new Error("Native companion is unavailable."));
        else resolve(response);
      });
    } catch (_) {
      reject(new Error("Native companion is unavailable."));
    }
  });
}

function invalidateFrameForNavigation(details) {
  if (!Number.isInteger(details.tabId) || !Number.isInteger(details.frameId)) return;
  const key = frameKey(details.tabId, details.frameId);
  frameGenerations.set(key, generationFor(details.tabId, details.frameId) + 1);
  const origin = core.allowedOrigin(details.url || "");
  currentDocuments.set(key, { documentId: details.documentId || "", origin });
  discardPending((record) => record.tabId === details.tabId && record.frameId === details.frameId);
}

api.webNavigation.onCommitted.addListener(invalidateFrameForNavigation);
api.webNavigation.onHistoryStateUpdated.addListener(invalidateFrameForNavigation);

api.tabs.onRemoved.addListener((tabId) => {
  discardPending((record) => record.tabId === tabId);
  for (const key of currentDocuments.keys()) {
    if (key.startsWith(`${tabId}:`)) currentDocuments.delete(key);
  }
  for (const key of frameGenerations.keys()) {
    if (key.startsWith(`${tabId}:`)) frameGenerations.delete(key);
  }
});

// Loading an unpacked extension never grants a website capability. The user
// must click the toolbar action, and the native app must return settings for
// that exact canonical origin. A missing host or denied origin changes
// nothing, so automatic and hover translation remain off.
api.action.onClicked.addListener((tab) => {
  const origin = core.allowedOrigin(tab?.url || "");
  if (!origin) return;
  sendNativeMessageOnce({
    type: "settingsRequest",
    version: core.protocolVersion,
    origin
  }).then((message) => {
    if (message?.origin === origin) handleNativeMessage(message);
  }).catch(() => undefined);
});

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (core.validateSettingsQuery(message)) {
    const binding = senderBinding(sender);
    // Content scripts run only in the top frame. Requiring its document ID,
    // canonical origin and current navigation generation prevents a late
    // settings reply from enabling a replacement document.
    if (!binding || binding.frameId !== 0 || message.origin !== binding.origin) {
      sendResponse({ accepted: false, error: "The settings query did not come from an authorised document." });
      return false;
    }
    sendNativeMessageOnce({
      type: "settingsRequest",
      version: core.protocolVersion,
      origin: binding.origin
    }).then((nativeMessage) => {
      if (!currentBindingMatches(binding) || !core.validateExtensionSettings(nativeMessage) ||
        nativeMessage.origin !== binding.origin) return;
      deliver(binding, {
        type: "extensionSettings",
        version: core.protocolVersion,
        origin: binding.origin,
        settings: nativeMessage.settings
      });
    }).catch(() => undefined);
    sendResponse({ accepted: true });
    return false;
  }
  if (!core.validateTranslationRequest(message)) return false;
  const binding = senderBinding(sender);
  if (!binding || message.origin !== binding.origin) {
    sendResponse({ accepted: false, error: "The request did not come from an authorised document." });
    return false;
  }
  prunePendingRequests();
  if (pendingByRequest.has(message.requestId)) {
    sendResponse({ accepted: false, error: "Duplicate translation request." });
    return false;
  }
  const record = { ...binding, requestId: message.requestId, kind: message.kind, createdAt: Date.now() };
  pendingByRequest.set(message.requestId, record);
  sendNativeMessageOnce({
    type: "translationRequest",
    version: core.protocolVersion,
    requestId: record.requestId,
    origin: record.origin,
    kind: record.kind,
    payload: message.payload
  }).then((nativeMessage) => {
    if (nativeMessage?.type === "nativeError" && nativeMessage.code === "notAuthorized") {
      // App-side revocation is authoritative. One already in-flight batch may
      // receive this content-free rejection; immediately disable both modes in
      // that exact document so no later page text crosses the bridge.
      pendingByRequest.delete(record.requestId);
      if (currentBindingMatches(record)) {
        deliver(record, {
          type: "extensionSettings",
          version: core.protocolVersion,
          origin: record.origin,
          settings: { autoMode: false, hoverMode: false, hideOriginal: false }
        });
      }
      return;
    }
    if (!handleNativeMessage(nativeMessage)) pendingByRequest.delete(record.requestId);
  }).catch(() => {
    pendingByRequest.delete(record.requestId);
  });
  sendResponse({ accepted: true });
  return false;
});
