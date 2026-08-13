// The service worker is a transport only. It never fetches, stores credentials,
// or selects a cloud provider. The native host owns translation policy and keys.
const api = globalThis.browser ?? globalThis.chrome;
const nativeHostName = "com.on1ymyse1f.InvisibleTranslator";
const portsByRequest = new Map();
const pendingRequestTTL = 30_000;
const maximumPendingRequests = 128;
let nativePort = null;

function prunePendingRequests(now = Date.now()) {
  for (const [requestId, record] of portsByRequest) {
    if (now - record.createdAt > pendingRequestTTL) portsByRequest.delete(requestId);
  }
  while (portsByRequest.size >= maximumPendingRequests) {
    const oldest = portsByRequest.keys().next().value;
    if (oldest === undefined) break;
    portsByRequest.delete(oldest);
  }
}

function allowedOrigin(sender) {
  try {
    const candidate = new URL(sender.origin || sender.url || "");
    return candidate.protocol === "https:" ? candidate.origin : "";
  } catch (_) {
    return "";
  }
}

function deliver(tabId, message) {
  if (!Number.isInteger(tabId)) return;
  const delivery = api.tabs.sendMessage(tabId, message);
  if (delivery && typeof delivery.catch === "function") delivery.catch(() => undefined);
}

function ensureNativePort() {
  if (nativePort) return nativePort;
  try {
    nativePort = api.runtime.connectNative(nativeHostName);
    nativePort.onMessage.addListener((message) => {
      if (message?.type === "extensionSettings") {
        api.tabs.query({}).then((tabs) => tabs.forEach((tab) => deliver(tab.id, message))).catch(() => undefined);
        return;
      }
      const record = portsByRequest.get(message?.requestId);
      if (!record) return;
      portsByRequest.delete(message.requestId);
      deliver(record.tabId, { type: "nativeTranslationResult", requestId: message.requestId, result: message });
    });
    nativePort.onDisconnect.addListener(() => {
      const error = api.runtime.lastError?.message || "Native companion is unavailable.";
      for (const [requestId, record] of portsByRequest) {
        deliver(record.tabId, { type: "nativeTranslationResult", requestId, error });
      }
      portsByRequest.clear();
      nativePort = null;
    });
  } catch (_) {
    nativePort = null;
  }
  return nativePort;
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "translationRequest") {
    const port = ensureNativePort();
    const tabId = sender.tab?.id;
    if (!port || !Number.isInteger(tabId)) {
      sendResponse({ accepted: false, error: "Open the macOS app and enable this website first." });
      return false;
    }
    prunePendingRequests();
    portsByRequest.set(message.requestId, { tabId, createdAt: Date.now() });
    port.postMessage({
      type: "translationRequest",
      requestId: message.requestId,
      origin: allowedOrigin(sender),
      payload: message.payload
    });
    sendResponse({ accepted: true });
    return false;
  }
  if (message?.type === "extensionSettings") {
    api.tabs.query({}).then((tabs) => tabs.forEach((tab) => deliver(tab.id, message))).catch(() => undefined);
  }
  return false;
});
