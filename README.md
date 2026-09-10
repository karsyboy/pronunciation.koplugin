# Pronunciation Dictionary for KOReader

English-first IPA and readable pronunciation lookup for KOReader, with
offline language packs and optional local or AI generation.

## Features

- One lazily opened offline database per base language (`data/en/`, `data/fr/`, …)
- Bundled English pack with US and UK pronunciations from WikiPron
- Automatic book-language detection and manual installed-pack selection
- Readable spellings, IPA, regional labels, and source attribution
- Optional local G2P estimates for unfamiliar names and invented words
- Optional low-token AI generation through one or more independently queried
  providers
- Personal pronunciation overrides

## Screenshots
<img src="./.resources/img1.png" width="45%" /> <img src="./.resources/img2.png" width="45%" />

## Install

### Method 1: Install via Storefront (Recommended)
If you use the Storefront plugin manager for KOReader, you can install and update Pronunciation directly on your device without connecting to a computer:

1. Open KOReader on your device.
2. Open the Tools menu (wrench icon / menu) and launch Storefront.
3. Search for or browse to Pronunciation in the plugin list. (You may have to set the filter to show zero stars)
4. Tap Install.
4. Restart KOReader when prompted.

> [!TIP]
> Storefront will automatically check for new Pronunciation releases and allow seamless, one-tap updates directly on your e-reader.

### Method 2: Manual Installation
1. Download `pronunciation.koplugin-<version>.zip` from the repository's
   Releases page.
2. Extract it into `koreader/plugins/`.
3. Confirm this path exists:

   ```text
   koreader/plugins/pronunciation.koplugin/main.lua
   ```

4. Restart KOReader.

> [!Note]
> You can replace the complete plugin directory when upgrading. KOReader stores settings and personal overrides separately.

## Use

- Open a dictionary result and tap **Pronunciation**.
- Long-press **Pronunciation** to add or edit a personal override.
- Use **Search → Pronunciation lookup** to enter a word manually.

Settings are under **Search → Settings → Pronunciation settings**:

- **Generated pronunciation** has three predictable modes:
  - **Off** uses only personal overrides, sourced language-pack records, and
    existing local inflection derivation.
  - **Local** additionally uses the selected pack's `g2p.bin` model.
  - **AI** queries every selected, usable AI provider. It never silently falls
    back to Local.
- **AI settings → Providers** supports selecting any combination of Google
  Gemini, OpenAI, DeepSeek, Anthropic Claude, and two custom API slots.
- **AI settings → API keys and models** configures each provider. Custom slots
  additionally accept an endpoint and OpenAI-compatible or Anthropic request
  format.
- **Pronunciation language** offers **Auto** plus every installed offline pack.
  Auto normalizes locales such as `en-US` or `fr-CA` to their base language
  and uses English when the requested pack is unavailable.
- **Clear cached pronunciations** removes local-G2P and AI results without
  deleting personal overrides.

API keys are stored in KOReader's persistent pronunciation settings. They are
not written to pronunciation caches, logs, release files, or error messages.
If AI mode has no selected provider with the required key/model/endpoint, the
lookup reports what must be configured.

## Lookup order

1. Personal override
2. The selected installed language pack (the bundled English pack contains
   US/UK WikiPron data plus the project supplement)
3. English inflection derived from a known base
4. A valid cached result for the selected generation mode
5. A newly generated Local G2P or AI result, according to the selected mode

Personal overrides return immediately. Current offline sourced data and valid
local derivations are checked before reusable generated cache entries, so pack
updates cannot be masked by stale estimates. Generated entries are labeled
`generated`, and readable text derived from IPA is labeled `approx.`
An installed foreign-language pack is not followed by an English-database
lookup or English G2P estimate merely because a word is absent from it.

AI cache entries are isolated by normalized word, language, provider, model,
custom endpoint/format fingerprint, and generator version. With several
providers selected, every provider is queried independently and each successful
IPA/readable pair is shown with its
provider and model. Disagreements are displayed rather than merged. One
provider's failure does not discard the others, and failures are not cached.

## Optional language packs

The normal release includes only the English pack. One command builds a
complete optional pack—database, readable converter, and an automatically
downloaded G2P model when MFA publishes a compatible one:

```sh
python3 tools/build_language_pack.py fr
python3 tools/build_language_pack.py fr de
python3 tools/build_language_pack.py --all
```

Each build also produces `readable.tsv`. English uses deterministic
English-specific phonetic mappings and syllabification; optional languages use
an independent mapping learned from that language's WikiPron spellings. No
model URL or archive path is required. Copy
the resulting complete `data/<language-code>/` directory into the
plugin's `data/` directory and restart KOReader. Packs use a common ISO 639-1
code when one exists and otherwise a stable ISO 639-3 code. Regional profiles
are merged into that base pack, so English is always `en`, never `en-US` or
`en-GB`.

## Data and licenses

- Plugin code: [MIT](LICENSE)
- WikiPron/Wiktionary records: CC BY-SA 4.0
- Montreal Forced Aligner English US ARPA model: CC BY 4.0

Full terms, attribution, release provenance, artifact hashes, and modifications are in
[`LICENSES.txt`](LICENSES.txt).

## Limitations

Only English is bundled by default. Optional packs always include sourced IPA
and a language-specific readable approximation. Local generation is available
when the official MFA catalog has a compatible model; languages without one
remain fully usable for database lookup and may use AI mode. The readable converter is learned from proportional IPA/spelling
alignments and is an aid rather than a phonological transliteration standard.
Spelling alone cannot determine an author's intended pronunciation,
especially for names and fictional words. Generated IPA and readable spellings
are estimates. Select **Generated pronunciation → Off** when only sourced and
existing non-generated results are wanted. AI availability, model behavior,
cost, quotas, and privacy are determined by the configured provider; normal
offline English lookup remains usable when AI is unavailable.

## Contributing

Build, test, database, model, and release instructions are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
