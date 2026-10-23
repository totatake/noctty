// The copy buttons copy constants from install.js, not the text on the page,
// so nothing else notices when the two drift apart. Pin every button to the
// command shown beside it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { INSTALL_COMMANDS } from "../install.js";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const indexHtml = readFileSync(join(siteDir, "index.html"), "utf8");

const shownText = (html) =>
  html
    .replace(/<wbr\s*\/?>/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&gt;/g, ">")
    .replace(/&lt;/g, "<")
    .replace(/&amp;/g, "&")
    .trim();

test("every copy button copies the command shown beside it", () => {
  const pairs = [
    ...indexHtml.matchAll(
      /<div class="nc-cmd">[\s\S]*?<code>([\s\S]*?)<\/code>\s*<button[^>]*data-nc-copy="([^"]+)"/g,
    ),
  ];
  assert.ok(
    pairs.length >= 4,
    `expected the hero and install copy buttons, found ${pairs.length}`,
  );
  const used = new Set();
  for (const [, code, key] of pairs) {
    assert.ok(
      key in INSTALL_COMMANDS,
      `no install command for data-nc-copy="${key}"`,
    );
    assert.equal(
      shownText(code),
      INSTALL_COMMANDS[key],
      `the ${key} button copies something else`,
    );
    used.add(key);
  }
  assert.deepEqual([...used].sort(), Object.keys(INSTALL_COMMANDS).sort());
});

test("every copy button sits next to a command", () => {
  const buttons = [...indexHtml.matchAll(/data-nc-copy="([^"]+)"/g)].length;
  const paired = [
    ...indexHtml.matchAll(
      /<code>[\s\S]*?<\/code>\s*<button[^>]*data-nc-copy=/g,
    ),
  ].length;
  assert.equal(paired, buttons);
});
