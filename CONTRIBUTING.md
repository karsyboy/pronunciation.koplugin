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
WikiPron, checks out that exact release tag, rebuilds the complete English
language pack, synchronizes `PLUGIN_VERSION`, and refreshes
the SHA-256 values of the finalized bundled database, converter, and G2P model
in `tools/build_release.py`.
WikiPron TSV inputs are discovered from the release and are not hash-pinned.

Then run the complete validation shown above. The release workflow performs the
same steps, commits `main.lua`, `tools/build_release.py`,
`data/en/pronunciations.sqlite3`, `data/en/readable.tsv`, `data/en/pack.tsv`,
`data/en/g2p.bin`, and `data/en/g2p.SOURCE.txt`, and publishes the
versioned archive. `PRAGMA user_version` is the database schema version, not the
plugin version.

## Build pronunciation language packs

The default command rebuilds the complete bundled English pack:

```sh
python3 tools/build_language_pack.py
```

The builder queries GitHub's latest-release API for
[WikiPron](https://github.com/CUNY-CL/wikipron), checks out that exact stable
tag, discovers all usable TSV/profile files, and prefers broad IPA data. If a
language has no broad file, available narrow IPA is used. The project
supplement is added only to English; CMUdict is not used. It also queries the
official MFA release catalog, chooses the newest stable compatible Pynini G2P model
for each requested language, downloads it, and packs it for the Lua runtime.

Build one or more optional packs by listing their language codes:

```sh
python3 tools/build_language_pack.py fr
python3 tools/build_language_pack.py fr de
```

Or build every usable base language in the release:

```sh
python3 tools/build_language_pack.py --all
```

Outputs use `data/<base-code>/pronunciations.sqlite3`, a generated
`readable.tsv` IPA-to-readable converter, an automatic `g2p.bin` when
available, provenance in `g2p.SOURCE.txt`, and a small `pack.tsv` sidecar used
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
  --generated-date 2026-09-10 \
  --no-g2p
```

`tools/build_database.py --language CODE` remains a backwards-compatible
spelling of the same all-in-one command.

Use `--sources-dir PATH` to relocate automatic checkouts, `--data-dir PATH` to
relocate pack outputs, or `--output PATH` for a single database. Network/API or
Git failures stop with an actionable error rather than silently using stale
WikiPron or MFA data. `--no-g2p` explicitly builds only database/readable
assets, while `--require-g2p` fails if MFA has no compatible model. A missing
published model is otherwise a warning and does not discard the useful
database pack. Exact downloaded MFA release archives are cached below the
selected `--sources-dir`; set `GITHUB_TOKEN` if anonymous API rate limits are
too restrictive.

The generated readable converter is derived independently for every language
from the selected WikiPron profiles. Its proportional segment-to-grapheme
alignment is deterministic and intentionally displayed as an approximation.

## Advanced G2P-only builds

The all-in-one database command is recommended. The lower-level model builder
can refresh models for packs that already exist; it also discovers and
downloads official archives automatically:

```sh
python3 tools/build_g2p_model.py \
  --language en
```

Build multiple installed language models with repeatable arguments:

```sh
python3 tools/build_g2p_model.py \
  --language en --language fr
```

Or refresh every installed pack for which a compatible model exists:

```sh
python3 tools/build_g2p_model.py --all
```

`--model-archive` and `--models-dir` remain available as deterministic local
overrides for development or offline rebuilds.

The selected model release, source hash, dimensions, packed format, and
conversion notes are in
[`data/en/g2p.SOURCE.txt`](data/en/g2p.SOURCE.txt). For other languages,
review and preserve the license carried by each selected upstream model. This
project-owned release-artifact integrity check is intentionally retained.
