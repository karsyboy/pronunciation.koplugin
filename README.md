# KOReader Pronunciation Dictionary 0.5.0

Offline-first IPA and readable pronunciation lookup for KOReader, including jailbroken Kindles.

## KOReader compatibility

The plugin supports all three KOReader dictionary-popup extension systems that have existed since June 2022:

- KOReader v2022.06-v2024.04 use the original popup callback and a chaining compatibility shim.
- KOReader v2024.05-v2026.03 use the legacy `DictButtonsReady` event.
- KOReader v2026.07 and newer use `ReaderDictionary:addToDictButtons()`.

On newer versions, Pronunciation is registered as a conditional runtime button. It therefore appears even if KOReader already has a saved/customized dictionary-button layout.

The button looks up the text that originally opened the dictionary popup, not a dictionary result's normalized headword. The plugin reads KOReader's query field first and falls back to the result field only for older or customized builds that do not expose the query field.

## Lookup order

1. Personal override
2. Exact bundled CMUdict and multilingual WikiPron entries
3. Locally cached sourced results
4. English morphological derivation from a known English base form
5. Free Dictionary API and sourced IPA from the English section of Wiktionary
6. Language-aware generated fallback, clearly labeled and scored below sourced IPA
7. Manual override

Online results from both providers are merged and cached. US/UK and other regional labels are retained when the provider supplies enough information to identify them.

Generated results never replace a sourced result. Generation is completely self-contained: it does not execute an external phonemizer, install native libraries, or depend on a platform-specific binary. A compact CMU Flite US-English letter-to-sound model is interpreted directly in Lua and handles arbitrary Latin-script spellings, including unfamiliar names and invented or fantasy words. These results are estimates—the spelling alone cannot reveal an author's intended pronunciation.

In **Auto** mode, a word-specific language hint is preferred, followed by the current book's metadata language. If no matching portable backend is bundled, the final fallback is explicitly labeled US English. The generated-language menu contains only **Auto** and **US English**; choosing US English bypasses automatic language hints. Generated caches include this choice, so an estimate made in one book cannot leak into another language context.

The bundled generator is US English. Auto mode is retained so additional ordinary model data can be added later without changing the setting or cache format; unsupported language hints currently use the clearly labeled US-English estimate.

## Pronunciation display

- Bundled entries contain stress-aware General American IPA converted from CMUdict ARPABET.
- Bundled Basque entries contain exact broad IPA mined by WikiPron from Wiktionary and are labeled `Basque`.
- Bundled readable spellings are syllabified and place primary emphasis in uppercase, for example `ih-PIT-uh-mee`.
- Online readable spellings are generated from IPA and explicitly labeled `approx.`.
- Automatically derived plurals, possessives, past forms, and gerunds are labeled as derived and receive a lower confidence score.
- Spelling-to-IPA estimates are labeled `generated`, identify their language or region, and receive the lowest confidence scores.
- The bundled US-English decision trees infer ARPABET first, preserving enough phone information for readable output and English inflection handling.

## Install

Copy this complete directory to:

```text
koreader/plugins/pronunciation.koplugin/
```

Restart KOReader and open a book. The dictionary popup should contain a **Pronunciation** button. Long-press that button to create or edit a personal override.

When upgrading, copy the complete plugin directory, including the rebuilt `data/pronunciations.sqlite3`. Cached results from older schemas are cleared automatically; personal overrides are retained.

## Offline data

The exact-pronunciation database is built from the CMU Pronouncing Dictionary, WikiPron's Basque broad-IPA TSV, the curated supplement in `data/supplemental.tsv`, and origin-only hints in `data/language_hints.tsv`. Exact revisions and the WikiPron input SHA-256 are recorded in the database `metadata` table.

Rebuild it with:

```sh
python3 tools/build_database.py \
  --cmudict /path/to/cmudict.dict \
  --cmudict-revision 74790861f652b15e4ac49015a90074ad62a27690 \
  --wikipron /path/to/wikipron/data/scrape/tsv/eus_latn_broad.tsv eus Basque \
  --wikipron-revision d282e848a211ea31cfd730f0ced8bc8cdab9e83d
```

WikiPron inputs are repeatable: add another `--wikipron TSV CODE NAME` argument for each language. These records remain sourced pronunciations and always outrank generated estimates.

## Portable generated-pronunciation data

The general out-of-vocabulary backend is `data/cmu_flite_lts.bin`, a compact re-encoding of CMU Flite's US-English letter-to-sound decision trees. It is data, not an executable, and the runtime interpreter is ordinary Lua compatible with old KOReader/Kindle builds.

Rebuild it from the pinned upstream revision:

```sh
git clone https://github.com/festvox/flite.git /path/to/flite
git -C /path/to/flite checkout 6c9f20dc915b17f5619340069889db0aa007fcdc
python3 tools/build_lts_model.py --flite /path/to/flite
```

Input hashes, the exact revision, and the repeatable command are recorded in `data/cmu_flite_lts.SOURCE.txt`. A future language can be distributed as another compact model plus a language definition, or as a small reviewed rule module for languages with sufficiently regular spelling. It must include provenance, licensing, and regression fixtures.

## Validation

From the plugin directory:

```sh
luajit tests/test_plugin.lua
python3 tests/test_database.py
```

The Lua suite covers old/new button registration, query-word selection, saved-layout behavior, IPA-only inflection derivation, foreign-language derivation guards, readable generation, English-only IPA parsing, etymology hints, book-language routing, language-aware cache keys, single-connection offline lookup, and portable unfamiliar-word generation. The database suite also verifies the compact LTS model's format, provenance, hash, and size.

## Data licensing

Plugin code is MIT licensed. CMUdict retains its BSD-3-Clause terms. WikiPron-derived records came from English Wiktionary and are distributed under CC BY-SA 4.0. The portable English decision trees and the adapted Lua interpreter retain CMU Flite's permissive license. Exact revisions, hashes, attribution, modifications, and applicable terms are recorded in `LICENSES.txt`, `data/cmu_flite_lts.SOURCE.txt`, and the database metadata.

## Limitations

CMUdict and the portable LTS model are General American resources, and the currently bundled WikiPron addition is not a complete multilingual dictionary. Language selection uses a user preference, explicit bundled hints, Wiktionary etymology markup, or book metadata; none can determine an author's intended pronunciation for an invented name. Unsupported book languages fall back to a clearly labeled US-English adaptation. Generated IPA and readable spellings are aids, not authoritative transcriptions; leave **Generated fallback** disabled if only sourced results are desired.
