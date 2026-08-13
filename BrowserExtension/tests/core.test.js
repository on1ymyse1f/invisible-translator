const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const core = require("../chromium/core.js");

test("only declared HTTPS sites are allowed", () => {
  assert.equal(core.isAllowedURL("https://chatgpt.com/c/123"), true);
  assert.equal(core.isAllowedURL("https://www.youtube.com/watch?v=123"), true);
  assert.equal(core.isAllowedURL("https://evil-chatgpt.com/"), false);
  assert.equal(core.isAllowedURL("https://chatgpt.com:8443/c/123"), false);
  assert.equal(core.isAllowedURL("https://chatgpt.com:443/c/123"), false);
  assert.equal(core.isAllowedURL("https://user@chatgpt.com/c/123"), false);
  assert.equal(core.isAllowedURL("https://chatgpt.com.evil.example/"), false);
  assert.equal(core.isAllowedURL("http://chatgpt.com/"), false);
  assert.equal(core.isAllowedURL("https://example.com/"), false);
  assert.equal(core.isAllowedOrigin("https://chatgpt.com"), true);
  assert.equal(core.isAllowedOrigin("https://chatgpt.com/"), false);
});

test("versioned request and response validation rejects mismatched protocol shapes", () => {
  const request = {
    type: "translationRequest", version: 1, requestId: "req-1", origin: "https://claude.ai", kind: "page",
    payload: { kind: "page", items: [{ id: "one", text: "hello" }] }
  };
  assert.equal(core.validateTranslationRequest(request), true);
  assert.equal(core.validateTranslationRequest({ ...request, version: 2 }), false);
  assert.equal(core.validateTranslationRequest({ ...request, origin: "https://claude.ai:443" }), false);
  assert.equal(core.validateTranslationRequest({ ...request, payload: { ...request.payload, kind: "hover" } }), false);
  assert.equal(core.validateTranslationRequest({ ...request, payload: { kind: "page", items: Array.from({ length: 65 }, (_, i) => ({ id: String(i), text: "x" })) } }), false);

  const response = {
    type: "translationResult", version: 1, requestId: "req-1", origin: "https://claude.ai", kind: "page",
    items: [{ id: "one", translation: "你好" }]
  };
  assert.equal(core.validateTranslationResponse(response), true);
  assert.equal(core.validateTranslationResponse({ ...response, type: "extensionSettings" }), false);
  assert.equal(core.validateTranslationResponse({ ...response, kind: "unknown" }), false);
  assert.equal(core.validateTranslationResponse({
    ...response,
    items: Array.from({ length: 65 }, (_, i) => ({ id: String(i), translation: "x" }))
  }), false);
  assert.equal(core.validateTranslationResponse({
    ...response, items: [{ id: "one", translation: "译".repeat(128 * 1024) }]
  }), false);
  assert.equal(core.validateExtensionSettings({
    type: "extensionSettings", version: 1, origin: "https://claude.ai", settings: { autoMode: true }
  }), true);
  assert.equal(core.validateExtensionSettings({
    type: "extensionSettings", version: 1, origin: "https://claude.ai", settings: { autoMode: "yes" }
  }), false);
  assert.equal(core.validateExtensionSettings({
    type: "extensionSettings", version: 1, origin: "https://claude.ai", settings: { autoMode: false, text: "no" }
  }), false);
  assert.equal(core.validateSettingsQuery({
    type: "settingsQuery", version: 1, origin: "https://claude.ai"
  }), true);
  assert.equal(core.validateSettingsQuery({
    type: "settingsQuery", version: 1, origin: "https://claude.ai", text: "must not cross bootstrap"
  }), false);
});

test("batch packer applies both item and UTF-8 budgets without truncating", () => {
  const chinese = "翻".repeat(128 * 1024);
  const output = core.packBatch([{ id: "a", text: "one" }, { id: "b", text: chinese }]);
  assert.deepEqual(output.accepted.map((item) => item.id), ["a"]);
  assert.deepEqual(output.deferred.map((item) => item.id), ["b"]);
  const many = Array.from({ length: 66 }, (_, index) => ({ id: String(index), text: "a" }));
  assert.equal(core.packBatch(many).accepted.length, 64);
});

test("caption merge and line split keep existing content and favour boundaries", () => {
  assert.equal(core.mergeCaption("Hello", "world."), "Hello world.");
  assert.equal(core.mergeCaption("Hello", "Hello world."), "Hello world.");
  assert.equal(core.mergeCaption("The quick brown", "brown fox"), "The quick brown fox");
  assert.equal(core.mergeCaption("字幕", "字幕"), "字幕");
  const lines = core.splitCaptionLines("One sentence. Another sentence that is deliberately long.", 18);
  assert.equal(lines.length > 1, true);
  assert.equal(lines.join(" ").includes("Another"), true);
});

test("revoking either browser mode invalidates in-flight page data", () => {
  assert.equal(core.settingsRevokeAccess(
    { autoMode: true, hoverMode: true },
    { autoMode: false, hoverMode: true }
  ), true);
  assert.equal(core.settingsRevokeAccess(
    { autoMode: false, hoverMode: true },
    { autoMode: false, hoverMode: false }
  ), true);
  assert.equal(core.settingsRevokeAccess(
    { autoMode: false, hoverMode: false },
    { autoMode: true, hoverMode: false }
  ), false);
});

test("rules select only the supported families", () => {
  assert.equal(core.ruleForHost("claude.ai").rootSelectors.includes("main"), true);
  assert.deepEqual(
    core.ruleForHost("x.com").textSelectors,
    ["article [data-testid='tweetText']"]
  );
  assert.equal(core.ruleForHost("example.com"), null);
  assert.equal(core.maxBatchBytes, 256 * 1024);
  assert.match(core.ignoredContainerSelector, /contenteditable/);
  assert.match(core.ignoredContainerSelector, /role='textbox'/);
});

test("hover fails closed for ignored self, ancestors, descendants, and incomplete targets", () => {
  const safe = { closest: () => null, querySelector: () => null };
  const ignoredSelfOrAncestor = { closest: () => ({ tagName: "TEXTAREA" }), querySelector: () => null };
  const ignoredDescendant = { closest: () => null, querySelector: () => ({ role: "textbox" }) };
  assert.equal(core.hasIgnoredHoverBoundary(safe), false);
  assert.equal(core.hasIgnoredHoverBoundary(ignoredSelfOrAncestor), true);
  assert.equal(core.hasIgnoredHoverBoundary(ignoredDescendant), true);
  assert.equal(core.hasIgnoredHoverBoundary({ closest: () => null }), true);
});

test("manifest cannot run on broad hosts and the bridge has no network primitive", () => {
  const root = path.join(__dirname, "..");
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "chromium", "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.permissions.includes("nativeMessaging"), true);
  assert.equal(manifest.permissions.includes("webNavigation"), true);
  assert.equal(manifest.permissions.includes("storage"), false);
  for (const pattern of [...manifest.host_permissions, ...manifest.content_scripts[0].matches]) {
    assert.match(pattern, /^https:\/\/(chatgpt\.com|chat\.openai\.com|claude\.ai|x\.com|twitter\.com|www\.youtube\.com|youtube\.com)\/\*$/);
  }
  const worker = fs.readFileSync(path.join(root, "chromium", "service-worker.js"), "utf8");
  const content = fs.readFileSync(path.join(root, "chromium", "content.js"), "utf8");
  assert.doesNotMatch(worker, /\bfetch\s*\(|XMLHttpRequest|WebSocket/);
  assert.match(worker, /import "\.\/core\.js"/);
  assert.match(worker, /documentId/);
  assert.match(worker, /onHistoryStateUpdated/);
  assert.match(worker, /message\.origin !== record\.origin \|\| message\.kind !== record\.kind/);
  assert.match(worker, /sendNativeMessage/);
  assert.match(worker, /action\.onClicked/);
  assert.doesNotMatch(worker, /connectNative/);
  assert.match(worker, /core\.validateSettingsQuery\(message\)/);
  assert.match(worker, /binding\.frameId !== 0/);
  assert.match(worker, /nativeMessage\.origin !== binding\.origin/);
  assert.match(worker, /nativeMessage\?\.type === "nativeError" && nativeMessage\.code === "notAuthorized"/);
  assert.doesNotMatch(worker, /api\.runtime\.onMessage[\s\S]*message\?\.type === "extensionSettings"/);
  assert.doesNotMatch(content, /containers\.length\s*\?\s*containers\s*:\s*\[root\]/);
  assert.match(content, /core\.hasIgnoredHoverBoundary\(target\)/);
  assert.match(content, /requestSettingsBootstrap\(\)/);
});
