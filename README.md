# Pronunciation for KOReader

Offline-first IPA and readable pronunciation lookup for KOReader, including
jailbroken Kindles.

## Features

- Exact bundled US/UK English pronunciations from CMUdict and WikiPron.
- A bundled US-English G2P model for unfamiliar names and invented words.
- Optional sourced online lookup through Dictionary API and English Wiktionary.
- Readable spellings, stress, regional labels, and source attribution.
- Personal overrides and bounded local caches.
- No external executable, native library, or network connection for offline use.

## Install

1. Download `pronunciation.koplugin-<version>.zip` from the repository's
   Releases page.
2. Extract it into `koreader/plugins/`.
3. Confirm this path exists:

   ```text
   koreader/plugins/pronunciation.koplugin/main.lua
   ```

4. Restart KOReader.

Open a dictionary result and tap **Pronunciation**. Long-press the button to add
or edit an override. To enter a word manually, use **Search → Pronunciation
lookup**. Settings are under **Tools → Pronunciation dictionary**:

- **Online fallback** enables Dictionary API and Wiktionary lookup.
- **Generated fallback** enables the bundled unfamiliar-word model.
- **Generated language** offers **Auto** or **US English**.
- **Clear cached pronunciations** removes sourced and generated caches without
  deleting personal overrides.

Upgrades can replace the complete plugin directory. KOReader stores settings
and overrides separately.

## Lookup order

1. Personal override
2. Bundled CMUdict and US/UK WikiPron data
3. Cached sourced result
4. English inflection derived from a known base
5. Dictionary API and the English section of Wiktionary
6. Bundled US-English G2P estimate

Sourced results always outrank generated estimates. Generated entries are
labeled `generated`, and readable text derived from IPA is labeled
`approx.`. A loading popup is painted before database, model, or network work
starts.

The plugin uses the word that opened KOReader's dictionary popup. It falls back
to the displayed dictionary headword only on older/custom builds that do not
provide the original query.

## Build and test

Runtime files are plain Lua plus the bundled SQLite database and G2P model.
Build tools require Python 3.10 or newer and use only the standard library.

```sh
luac5.1 -p main.lua
luajit tests/test_plugin.lua
lua5.1 tests/test_plugin.lua
python3 tests/test_database.py
python3 tools/build_release.py
```

The release builder validates versions, database integrity and metadata, source
manifests, model hashes, required licenses, and archive contents. Output is
`dist/pronunciation.koplugin-<version>.zip`, using the semantic version in
`_meta.lua`. Repeated builds from the same inputs are byte-identical. Pass
`--output PATH` to select an explicit name, or `--print-version` to print the
validated version without building an archive.

### Publish a release

Pushing a change to `_meta.lua` on `main` starts the release workflow. If no
GitHub Release exists for `v<version>`, the workflow runs the Lua and Python
checks, builds the versioned archive, creates that tag, and publishes the
archive. It can also be run manually on `main` to retry an unpublished version.

Before merging a version bump, update `_meta.lua`, `main.lua`, and
`tools/build_database.py`, rebuild the bundled database, and update its expected
hash in `tools/build_release.py`. The release builder rejects version or hash
mismatches.

### Rebuild the pronunciation database

Provide CMUdict and a WikiPron checkout at the pinned revisions:

```sh
python3 tools/build_database.py \
  --cmudict /path/to/cmudict.dict \
  --cmudict-revision 74790861f652b15e4ac49015a90074ad62a27690 \
  --wikipron-root /path/to/wikipron/data/scrape/tsv \
  --wikipron-revision d282e848a211ea31cfd730f0ced8bc8cdab9e83d \
  --generated-date 2026-08-28
```

`data/wikipron_sources.tsv` is the allowlist for packaged broad-IPA TSVs and
their SHA-256 hashes. Add a row there to add another distributable source.

### Rebuild the G2P model

```sh
python3 tools/build_g2p_model.py \
  --model-archive /path/to/english_us_arpa.zip
```

The pinned download, source hash, model dimensions, packed format, and
conversion notes are in
[`data/mfa_english_g2p.SOURCE.txt`](data/mfa_english_g2p.SOURCE.txt).

## Data and licenses

- Plugin code: [MIT](LICENSE)
- CMUdict: BSD-3-Clause
- WikiPron/Wiktionary records: CC BY-SA 4.0
- Montreal Forced Aligner English US ARPA model: CC BY 4.0

Full terms, attribution, revisions, hashes, and modifications are in
[`LICENSES.txt`](LICENSES.txt).

## Limitations

The bundled exact data covers US and UK English; the generated model is US
English. Spelling alone cannot determine an author's intended pronunciation,
especially for names and fictional words. Generated IPA and readable spellings
are estimates. Disable **Generated fallback** when only sourced results are
wanted.
