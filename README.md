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
  falling back to the bundled English model when no matching model is installed.
- **Pronunciation language** offers **Auto** plus every installed offline pack.
  Auto normalizes locales such as `en-US` or `fr-CA` to their base language
  and uses English when the requested pack is unavailable.
- **Clear cached pronunciations** removes sourced and generated caches without deleting personal overrides.
>[!Note]
> Turning off online fallback can greatly increase the time it takes to generate a pronunciation.

## Lookup order

1. Personal override
2. Cached sourced or generated result
3. The selected installed language pack (the bundled English pack contains
   US/UK WikiPron data plus the project supplement)
4. English inflection derived from a known base
5. Dictionary API and the English section of Wiktionary
6. The selected pack's G2P estimate, or the clearly labeled bundled
   US-English G2P estimate when that pack has no model

Personal overrides and cached results return immediately. On a cache miss,
sourced results take priority over generated estimates. Generated entries are
labeled `generated`, and readable text derived from IPA is labeled `approx.`
An installed foreign-language pack is not followed by an English-database
lookup merely because a word is absent from it.

## Optional language packs

The normal release includes only `data/en/pronunciations.sqlite3`. Developers
can build any language discovered in the selected WikiPron release:

```sh
python3 tools/build_database.py --language fr
python3 tools/build_database.py --language fr --language de
python3 tools/build_database.py --all
```

Each build also produces `readable.tsv`, a deterministic, language-specific
IPA-to-readable mapping learned from that language's WikiPron spellings. Copy
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

Only English is bundled by default. Optional packs include sourced IPA and a
language-specific readable approximation; generated fallback for such a pack
requires installing a separately built MFA/Pynini model in the same language
directory. The readable converter is learned from proportional IPA/spelling
alignments and is an aid rather than a phonological transliteration standard.
Spelling alone cannot determine an author's intended pronunciation,
especially for names and fictional words. Generated IPA and readable spellings
are estimates. Disable **Generated fallback** when only sourced results are
wanted.

## Contributing

Build, test, database, model, and release instructions are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
