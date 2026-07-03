#!/usr/bin/env node
// Fills the non-English languages of Resources/Localizable.xcstrings via the
// Gemini API (§10.5). Idempotent: only keys MISSING a target language are sent
// (pass --force to re-translate everything). Output is deterministic — keys and
// languages are written in sorted order, so reruns produce no churn.
//
//   node tools/translate.mjs [--force]
//
// NEW LANGUAGE: add its code to LANGS below and rerun.
//
// API key: env GEMINI_API_KEY, falling back to ../.translate.env at the workspace
// root (OUTSIDE this repo — the repo is public; the key must never be committed).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const LANGS = [
  { code: "ru", name: "Russian" },
  { code: "zh-Hans", name: "Simplified Chinese" },
];

const MODEL = process.env.GEMINI_MODEL || "gemini-3-flash-preview";
const BATCH_SIZE = 25;
const FORCE = process.argv.includes("--force");

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const catalogPath = join(repoRoot, "Resources", "Localizable.xcstrings");

function apiKey() {
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY.trim();
  const envFile = join(repoRoot, "..", ".translate.env");
  if (existsSync(envFile)) {
    for (const line of readFileSync(envFile, "utf8").split("\n")) {
      const match = line.match(/^\s*GEMINI_API_KEY\s*=\s*(.+)\s*$/);
      if (match) return match[1].trim();
    }
  }
  console.error("No GEMINI_API_KEY in the environment and no ../.translate.env found.");
  process.exit(1);
}

const GLOSSARY = `You translate UI strings for "Klic", a messenger app.
Rules:
- "Klic" is a product name — NEVER translate or transliterate it.
- Preserve format placeholders EXACTLY as-is: %@, %lld, %1$@, etc. Keep their order unless grammar demands reordering (positional forms allowed).
- Keep the translation short and natural for mobile UI.
- Russian: informal-but-polite register (address the user as «вы», lowercase), the tone used by popular messengers.
- Simplified Chinese (zh-Hans): concise standard app vocabulary.
- Do not add quotes, comments, or trailing whitespace.
- Punctuation and capitalization should follow the target language's UI conventions.`;

async function translateBatch(key, langName, entries) {
  const body = {
    contents: [
      {
        role: "user",
        parts: [
          {
            text:
              `${GLOSSARY}\n\nTranslate the following JSON object's values from English to ${langName}. ` +
              `Return ONLY a JSON object with the SAME keys and translated values.\n\n` +
              JSON.stringify(Object.fromEntries(entries.map((k) => [k, k])), null, 2),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.2,
      responseMimeType: "application/json",
    },
  };

  // Rate limits (429) back off and retry — free-tier RPM caps are easy to hit.
  let data;
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": key,
        },
        body: JSON.stringify(body),
      }
    );
    if (res.status === 429 && attempt < 6) {
      const text = await res.text();
      const delay = Number(text.match(/"retryDelay"\s*:\s*"(\d+)/)?.[1] ?? 0) || 20 + attempt * 10;
      console.log(`  429 — retrying in ${delay}s`);
      await new Promise((resolve) => setTimeout(resolve, delay * 1000));
      continue;
    }
    if (!res.ok) {
      throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
    }
    data = await res.json();
    break;
  }
  const text = data.candidates?.[0]?.content?.parts?.map((p) => p.text).join("") ?? "";
  const parsed = JSON.parse(text);
  const out = {};
  for (const k of entries) {
    if (typeof parsed[k] === "string" && parsed[k].length > 0) out[k] = parsed[k];
  }
  return out;
}

function sortedObject(obj) {
  return Object.fromEntries(Object.entries(obj).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

const key = apiKey();
const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
const allKeys = Object.keys(catalog.strings).sort();

for (const lang of LANGS) {
  const missing = allKeys.filter((k) => {
    const unit = catalog.strings[k].localizations?.[lang.code]?.stringUnit;
    return FORCE || !unit || !unit.value || unit.state === "needs_review";
  });
  console.log(`${lang.code}: ${missing.length} of ${allKeys.length} keys to translate`);

  for (let i = 0; i < missing.length; i += BATCH_SIZE) {
    const batch = missing.slice(i, i + BATCH_SIZE);
    let translated;
    try {
      translated = await translateBatch(key, lang.name, batch);
    } catch (error) {
      console.error(`  batch ${i / BATCH_SIZE + 1} failed: ${error.message}`);
      continue;
    }
    for (const [k, value] of Object.entries(translated)) {
      catalog.strings[k].localizations ??= {};
      catalog.strings[k].localizations[lang.code] = {
        stringUnit: { state: "translated", value },
      };
    }
    console.log(`  ${Math.min(i + BATCH_SIZE, missing.length)}/${missing.length}`);
  }
}

// Deterministic output: sorted keys, sorted language maps.
const strings = {};
for (const k of allKeys) {
  const entry = catalog.strings[k];
  if (entry.localizations) entry.localizations = sortedObject(entry.localizations);
  strings[k] = entry;
}
writeFileSync(
  catalogPath,
  JSON.stringify({ sourceLanguage: "en", strings, version: "1.0" }, null, 2) + "\n"
);
console.log("done");
