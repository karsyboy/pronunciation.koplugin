# Pronunciation Dictionary for KOReader

Offline IPA and readable pronunciation lookup for KOReader.

## Features

- One lazily opened offline database per base language (`data/en/`, `data/fr/`, …)
- Bundled English pack with US and UK pronunciations from WikiPron
- Automatic book-language detection and manual installed-pack selection
- Readable spellings, IPA, regional labels, and source attribution
- Offline estimates for unfamiliar names and invented words
- Optional online fallback through Dictionary API and English Wiktionary
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

- **Online fallback** enables Dictionary API and Wiktionary lookup.
- **Generated fallback** enables the selected pack's unfamiliar-word model,
  when that language pack includes a compatible model.
- **Pronunciation language** offers **Auto** plus every installed offline pack.
  Auto normalizes locales such as `en-US` or `fr-CA` to their base language
  and uses English when the requested pack is unavailable.
- **Clear cached pronunciations** removes sourced and generated caches without deleting personal overrides.
>[!Note]
> Turning off online fallback can greatly increase the time it takes to generate a pronunciation.

## Lookup order

1. Personal override
2. The selected installed language pack (the bundled English pack contains
   US/UK WikiPron data plus the project supplement)
3. English inflection derived from a known base
4. A cached sourced result
5. Dictionary API and the English section of Wiktionary (English only)
6. The selected pack's cached or newly generated G2P estimate

Personal overrides return immediately. Current offline sourced data is checked
before reusable online or generated cache entries, so pack updates cannot be
masked by stale approximations. Generated entries are labeled `generated`, and
readable text derived from IPA is labeled `approx.`
An installed foreign-language pack is not followed by an English-database
lookup, English online lookup, or English G2P estimate merely because a word is
absent from it.

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
and a language-specific readable approximation. Generated fallback is added
when the official MFA catalog has a compatible model; languages without one
remain fully usable for database lookup. The readable converter is learned from proportional IPA/spelling
alignments and is an aid rather than a phonological transliteration standard.
Spelling alone cannot determine an author's intended pronunciation,
especially for names and fictional words. Generated IPA and readable spellings
are estimates. Disable **Generated fallback** when only sourced results are
wanted.

## Contributing

Build, test, database, model, and release instructions are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
