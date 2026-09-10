# Contributing

## Requirements

- Python 3.10 or newer
- Git
- Lua 5.1 and/or LuaJIT for runtime tests

The runtime is plain Lua plus per-language SQLite, readable-converter, and
optional G2P files. Python build tools use only the standard library.

## Test the project

Run these commands from the repository root:

```sh
luac5.1 -p main.lua ai.lua
luajit tests/test_plugin.lua
lua5.1 tests/test_plugin.lua
python3 tests/test_database.py
python3 tools/build_release.py
```

AI requests are mocked. Automated tests must never call paid live providers.
The release archive is written to `dist/` and is reproducible from identical
inputs.

## Important files

- `main.lua`: KOReader integration, lookup order, settings, and UI
- `ai.lua`: AI providers, requests, validation, and model discovery
- `tools/build_language_pack.py`: complete language-pack builder
- `tools/build_database.py`: database builder and compatible all-in-one entry
- `tools/build_g2p_model.py`: lower-level G2P-only builder
- `tests/`: Lua runtime and Python database/release coverage

## Build language packs

Build English, selected languages, or every available language:

```sh
python3 tools/build_language_pack.py
python3 tools/build_language_pack.py fr de
python3 tools/build_language_pack.py --all
```

The builder downloads the latest stable
[WikiPron](https://github.com/CUNY-CL/wikipron) release and a compatible
Montreal Forced Aligner Pynini model when available. Each pack is written to
`data/<base-code>/` and contains:

- `pronunciations.sqlite3`: sourced IPA records
- `readable.tsv`: IPA-to-readable conversion data
- `g2p.bin`: optional local generation model
- `pack.tsv`: runtime metadata
- `g2p.SOURCE.txt`: model provenance, when G2P is available

Regional profiles merge into one base-language pack. English-only supplemental
records are not added to other languages. Normal releases package only
`data/en/`, even when optional packs exist locally.

Useful options:

- `--no-g2p`: build only database and readable data
- `--require-g2p`: fail if no compatible model exists
- `--sources-dir PATH`: choose the download/cache directory
- `--data-dir PATH`: choose the language-pack output directory
- `--output PATH`: write one database to a custom location

Set `GITHUB_TOKEN` if anonymous GitHub API limits are too restrictive. Network,
API, and Git failures stop the build instead of silently using stale data.

### Offline or pinned builds

Pass a local WikiPron checkout and its provenance:

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

`tools/build_database.py --language CODE` remains compatible with the complete
language-pack workflow.

### G2P-only builds

Prefer the complete language-pack builder. To refresh only existing G2P files:

```sh
python3 tools/build_g2p_model.py --language en --language fr
python3 tools/build_g2p_model.py --all
```

Use `--model-archive` or `--models-dir` for pinned local model files. Preserve
the license and provenance of every added model.

## Prepare a release

1. Update `version` in `_meta.lua`.
2. Run `python3 tools/prepare_release.py`.
3. Run the complete test sequence above.
4. Commit and push the version change to `main`.

Preparation refreshes the bundled English pack, synchronizes the runtime
version, and updates the database, readable-data, and G2P hashes used by the
release validator. The release workflow repeats those checks, commits refreshed
artifacts when needed, and publishes the version tag and archive. `_meta.lua`
is the plugin-version source of truth; SQLite's `PRAGMA user_version` is only
the database schema version.

`python3 tools/build_release.py --print-version` prints the release version.
Use `--output PATH` to choose a different archive path.
