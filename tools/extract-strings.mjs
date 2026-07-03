#!/usr/bin/env node
// Syncs Resources/Localizable.xcstrings with the user-facing string literals found
// in Sources/**/*.swift (§10.5). Keys are the English strings themselves — the
// convention SwiftUI's LocalizedStringKey (Text/Button/TextField/…) and
// String(localized:) both resolve natively. Interpolations become %@ / %lld
// format keys, matching what the runtime looks up.
//
// Usage: node tools/extract-strings.mjs
// Deterministic: keys are sorted; existing translations are preserved; keys that
// disappeared from the code are dropped.

import { readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const catalogPath = join(repoRoot, "Resources", "Localizable.xcstrings");

// Call sites whose first string-literal argument is a localization key.
const PREFIXES = [
  'Text("',
  'Button("',
  'TextField("',
  'SecureField("',
  'Label("',
  'Toggle("',
  '.navigationTitle("',
  '.alert("',
  'SharePreview("',
  'String(localized: "',
  'LocalizedStringKey("',
];

// Heuristic: interpolated expressions that are integers use %lld (SwiftUI's own
// convention); everything else is %@. A wrong guess just falls back to English.
function specifier(expr) {
  const trimmed = expr.trim();
  if (/\.count\b/.test(trimmed)) return "%lld";
  if (/^\d+$/.test(trimmed)) return "%lld";
  if (/^\w*([Cc]ount|[Ii]ndex|[Ii]dx|[Mm]onths|[Dd]ays|[Ss]econds)\w*$/.test(trimmed)) return "%lld";
  return "%@";
}

// Parse a Swift string literal starting at src[i] === '"'. Returns
// { end, key } where key has escapes resolved and interpolations replaced with
// format specifiers — or null when it isn't a simple single-line literal.
function parseLiteral(src, i) {
  if (src[i] !== '"') return null;
  let j = i + 1;
  let key = "";
  while (j < src.length) {
    const c = src[j];
    if (c === "\\") {
      const next = src[j + 1];
      if (next === "(") {
        // interpolation — scan to the matching paren (tracking nested strings)
        let depth = 1;
        let k = j + 2;
        let expr = "";
        while (k < src.length && depth > 0) {
          if (src[k] === '"') {
            const inner = parseLiteral(src, k);
            if (!inner) return null;
            expr += src.slice(k, inner.end);
            k = inner.end;
            continue;
          }
          if (src[k] === "(") depth++;
          if (src[k] === ")") depth--;
          if (depth > 0) expr += src[k];
          k++;
        }
        key += specifier(expr);
        j = k;
        continue;
      }
      if (next === "n") key += "\n";
      else if (next === "t") key += "\t";
      else if (next === '"') key += '"';
      else if (next === "\\") key += "\\";
      else key += next;
      j += 2;
      continue;
    }
    if (c === '"') return { end: j + 1, key };
    if (c === "\n") return null;
    key += c;
    j++;
  }
  return null;
}

const files = execSync(`find "${join(repoRoot, "Sources")}" -name '*.swift'`, { encoding: "utf8" })
  .trim()
  .split("\n");

const keys = new Set();
for (const file of files) {
  const src = readFileSync(file, "utf8");
  for (const prefix of PREFIXES) {
    let idx = 0;
    while ((idx = src.indexOf(prefix, idx)) !== -1) {
      const litStart = idx + prefix.length - 1; // position of the opening quote
      const parsed = parseLiteral(src, litStart);
      idx = idx + prefix.length;
      if (!parsed) continue;
      const key = parsed.key;
      // Skip empty keys and obvious non-UI content (pure symbols/format strings).
      if (!key || /^[\s%@lld:.\-/]*$/.test(key)) continue;
      keys.add(key);
    }
  }
}

let catalog = { sourceLanguage: "en", strings: {}, version: "1.0" };
try {
  catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
} catch {
  // first run — start fresh
}

const strings = {};
for (const key of [...keys].sort()) {
  const existing = catalog.strings?.[key];
  strings[key] = existing ?? { extractionState: "manual" };
  if (!strings[key].extractionState) strings[key].extractionState = "manual";
}

const output = {
  sourceLanguage: "en",
  strings,
  version: "1.0",
};
writeFileSync(catalogPath, JSON.stringify(output, null, 2) + "\n");
console.log(`Localizable.xcstrings: ${Object.keys(strings).length} keys`);
