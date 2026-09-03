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

## Prepare a version bump

The plugin version is intentionally recorded in the metadata, runtime, database
builder, and bundled database. All four must agree before a release can be
built.

1. Set the same semantic version in these three source files:

   - `version` in `_meta.lua`
   - `PLUGIN_VERSION` in `main.lua`
   - `PLUGIN_VERSION` in `tools/build_database.py`

2. Rebuild `data/pronunciations.sqlite3` using the command in
   [Rebuild the pronunciation database](#rebuild-the-pronunciation-database).
   By default, this fetches the latest pronunciation sources and writes their
   exact revisions and the new plugin version into the database metadata.

3. Calculate the rebuilt database's SHA-256 hash:

   ```sh
   sha256sum data/pronunciations.sqlite3
   ```

4. Replace `DATABASE_SHA256` in `tools/build_release.py` with that hash.

5. Run the complete validation and release build:

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

Pushing a change to `_meta.lua` on `main` starts the release workflow. If no
GitHub Release exists for `v<version>`, the workflow runs the Lua and Python
checks, builds the versioned archive, creates that tag, and publishes the
archive. It can also be run manually on `main` to retry an unpublished version.

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
