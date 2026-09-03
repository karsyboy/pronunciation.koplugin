# Contributing

## Build and test

Runtime files are plain Lua plus the bundled SQLite database and G2P model.
Build tools require Python 3.10 or newer and Git. The Python tools use only the
standard library.

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

## Prepare a release locally

`_meta.lua` is the source of truth for the plugin version. To reproduce the
automated release process locally:

1. Change only `version` in `_meta.lua`.

2. Prepare all generated release inputs:

   ```sh
   python3 tools/prepare_release.py
   ```

   This fetches the latest CMUdict and WikiPron revisions, rebuilds
   `data/pronunciations.sqlite3`, synchronizes `PLUGIN_VERSION` in `main.lua`,
   refreshes the WikiPron manifest hashes, and updates `DATABASE_SHA256` in
   `tools/build_release.py`. The database builder reads its version directly
   from `_meta.lua`.

3. Run the complete validation and release build:

   ```sh
   luac5.1 -p main.lua
   luajit tests/test_plugin.lua
   lua5.1 tests/test_plugin.lua
   python3 tests/test_database.py
   python3 tools/build_release.py
   ```

The generated archive should be
`dist/pronunciation.koplugin-<version>.zip`. Do not change SQLite's
`PRAGMA user_version` during a normal plugin release: it identifies the database
schema version, not the plugin version.

## Publish a release

Change only the version in `_meta.lua` and push it to `main`. If no GitHub
Release exists for `v<version>`, the release workflow automatically:

1. Fetches the latest CMUdict and WikiPron revisions.
2. Synchronizes the runtime version and rebuilds the pronunciation database.
3. Refreshes source and database integrity hashes.
4. Runs the Lua and Python regression checks.
5. Builds the versioned plugin archive.
6. Commits the generated release inputs back to `main`.
7. Tags that generated commit and publishes the GitHub Release.

The workflow can also be started manually on `main` to retry an unpublished
version. The repository must permit GitHub Actions to write contents so the
generated release commit can be pushed.

## Rebuild the pronunciation database

From the repository root, run:

```sh
python3 tools/build_database.py
```

The builder automatically clones the latest
[CMUdict](https://github.com/cmusphinx/cmudict) and
[WikiPron](https://github.com/CUNY-CL/wikipron) sources into the ignored
`pronunciation-sources/` directory. On later runs it updates both checkouts to
their latest upstream revisions. It records the exact commit IDs in the
database and refreshes the hashes for the allowlisted WikiPron files in
`data/wikipron_sources.tsv`.

To put the downloaded sources elsewhere, pass `--sources-dir PATH`:

```sh
python3 tools/build_database.py \
  --sources-dir /path/to/pronunciation-sources
```

For an offline or reproducible build, provide existing checkouts and their
exact revisions instead:

```sh
python3 tools/build_database.py \
  --cmudict /path/to/cmudict/cmudict.dict \
  --cmudict-revision 74790861f652b15e4ac49015a90074ad62a27690 \
  --wikipron-root /path/to/wikipron/data/scrape/tsv \
  --wikipron-revision d282e848a211ea31cfd730f0ced8bc8cdab9e83d \
  --generated-date 2026-08-28
```

The manifest remains the allowlist for distributable broad-IPA TSVs. Add a row
to `data/wikipron_sources.tsv` before including another WikiPron source.

## Rebuild the G2P model

```sh
python3 tools/build_g2p_model.py \
  --model-archive /path/to/english_us_arpa.zip
```

The pinned download, source hash, model dimensions, packed format, and
conversion notes are in
[`data/mfa_english_g2p.SOURCE.txt`](data/mfa_english_g2p.SOURCE.txt).
