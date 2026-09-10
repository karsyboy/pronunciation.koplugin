# Contributing

## Build and test

Runtime files are plain Lua plus per-language SQLite/readable-converter packs
and optional per-language G2P models. Build tools require Python 3.10 or newer and Git; they use
only the Python standard library.

```sh
luac5.1 -p main.lua
luajit tests/test_plugin.lua
lua5.1 tests/test_plugin.lua
python3 tests/test_database.py
python3 tools/build_release.py
```

The release builder validates versions, the bundled English database's schema,
metadata and final SHA-256, the readable converter and G2P model SHA-256,
required licenses, and
archive contents. Output is `dist/pronunciation.koplugin-<version>.zip`, using
the semantic version in `_meta.lua`. Repeated builds from identical inputs are
byte-identical. `--output PATH` selects another archive path;
`--print-version` prints the validated version.

## Prepare and publish a release

`_meta.lua` is the source of truth for the plugin version. Change its `version`
and run:

```sh
python3 tools/prepare_release.py
```

Preparation resolves the latest stable, non-prerelease GitHub Release from
WikiPron, checks out that exact release tag, rebuilds only the English database
and readable converter, synchronizes `PLUGIN_VERSION`, and refreshes
the SHA-256 of the finalized bundled database in `tools/build_release.py`.
WikiPron TSV inputs are discovered from the release and are not hash-pinned.

Then run the complete validation shown above. The release workflow performs the
same steps, commits `main.lua`, `tools/build_release.py`,
`data/en/pronunciations.sqlite3`, `data/en/readable.tsv`, and
`data/en/pack.tsv`, and publishes the
versioned archive. `PRAGMA user_version` is the database schema version, not the
plugin version.

## Build pronunciation language packs

The default command rebuilds the bundled English pack:

```sh
python3 tools/build_database.py
```

The builder queries GitHub's latest-release API for
[WikiPron](https://github.com/CUNY-CL/wikipron), checks out that exact stable
tag, discovers all usable TSV/profile files, and prefers broad IPA data. If a
language has no broad file, available narrow IPA is used. The project
supplement is added only to English; CMUdict is not used.

Build one or more optional packs with repeatable `--language` arguments:

```sh
python3 tools/build_database.py --language fr
python3 tools/build_database.py --language fr --language de
```

Or build every usable base language in the release:

```sh
python3 tools/build_database.py --all
```

Outputs use `data/<base-code>/pronunciations.sqlite3`, a generated
`readable.tsv` IPA-to-readable converter, and a small `pack.tsv` sidecar used
for lazy runtime discovery. Locale variants and WikiPron dialect
profiles merge into one base-language pack. ISO 639-1 is preferred where it
exists; otherwise the WikiPron ISO 639-3 code is used. A normal plugin release
still packages only `data/en/`, regardless of optional packs in a developer's
local `data/` directory.

For a deterministic offline build, provide the WikiPron release TSV directory,
its language metadata, release/tag, and commit provenance:

```sh
python3 tools/build_database.py \
  --language en \
  --wikipron-root /path/to/wikipron/data/scrape/tsv \
  --wikipron-languages /path/to/wikipron/data/scrape/lib/languages.json \
  --wikipron-release v2.2.0 \
  --wikipron-revision d282e848a211ea31cfd730f0ced8bc8cdab9e83d \
  --generated-date 2026-09-10
```

Use `--sources-dir PATH` to relocate automatic checkouts, `--data-dir PATH` to
relocate pack outputs, or `--output PATH` for a single database. Network/API or
Git failures stop with an actionable error rather than silently using stale
WikiPron data.

The generated readable converter is derived independently for every language
from the selected WikiPron profiles. Its proportional segment-to-grapheme
alignment is deterministic and intentionally displayed as an approximation.

## Rebuild the G2P model

The model builder writes `g2p.bin` and `g2p.SOURCE.txt` inside each matching
base-language directory and records the model in `pack.tsv`. A single English
archive remains backward compatible:

```sh
python3 tools/build_g2p_model.py \
  --model-archive /path/to/english_us_arpa.zip
```

Build multiple language models by pairing repeatable arguments:

```sh
python3 tools/build_g2p_model.py \
  --language en --model-archive /path/to/english_us_arpa.zip \
  --language fr --model-archive /path/to/french_mfa.zip
```

Or name archives by base code (`en.zip`, `fr.zip`, …) and build the directory:

```sh
python3 tools/build_g2p_model.py --all --models-dir /path/to/model-archives
```

The pinned model download, source hash, dimensions, packed format, and
conversion notes are in
[`data/en/g2p.SOURCE.txt`](data/en/g2p.SOURCE.txt). For other languages,
review and preserve the license carried by each selected upstream model. This
project-owned release-artifact integrity check is intentionally retained.
