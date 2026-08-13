const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const core = require("../chromium/core.js");

test("only declared HTTPS sites are allowed", () => {
  assert.equal(core.isAllowedURL("https://chatgpt.com/c/123"), true);
  assert.equal(core.isAllowedURL("https://www.youtube.com/watch?v=123"), true);
  assert.equal(core.isAllowedURL("https://evil-chatgpt.com/"), false);
  assert.equal(core.isAllowedURL("http://chatgpt.com/"), false);
  assert.equal(core.isAllowedURL("https://example.com/"), false);
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
  assert.equal(core.mergeCaption("字幕", "字幕"), "字幕");
  const lines = core.splitCaptionLines("One sentence. Another sentence that is deliberately long.", 18);
  assert.equal(lines.length > 1, true);
  assert.equal(lines.join(" ").includes("Another"), true);
});

test("rules select only the supported families", () => {
  assert.equal(core.ruleForHost("claude.ai").rootSelectors.includes("main"), true);
  assert.equal(core.ruleForHost("example.com"), null);
  assert.equal(core.maxBatchBytes, 256 * 1024);
});

test("manifest cannot run on broad hosts and the bridge has no network primitive", () => {
  const root = path.join(__dirname, "..");
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "chromium", "manifest.json"), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.permissions.includes("nativeMessaging"), true);
  assert.equal(manifest.permissions.includes("storage"), false);
  for (const pattern of [...manifest.host_permissions, ...manifest.content_scripts[0].matches]) {
    assert.match(pattern, /^https:\/\/(chatgpt\.com|chat\.openai\.com|claude\.ai|x\.com|twitter\.com|www\.youtube\.com|youtube\.com)\/\*$/);
  }
  const worker = fs.readFileSync(path.join(root, "chromium", "service-worker.js"), "utf8");
  assert.doesNotMatch(worker, /\bfetch\s*\(|XMLHttpRequest|WebSocket/);
});
