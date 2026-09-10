# Pronunciation Dictionary for KOReader

An English-first KOReader plugin for IPA and readable pronunciations. It uses
an offline sourced database first, with optional local G2P or AI generation for
words the database does not contain.

## Highlights

- Bundled English database with US and UK WikiPron pronunciations
- IPA, readable spelling, regional labels, and source attribution
- Automatic book-language detection and optional language packs
- Personal pronunciation overrides
- Predictable **Off**, **Local**, and **AI** generation modes
- Gemini, OpenAI, DeepSeek, Claude, and two custom AI providers

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

1. Download `pronunciation.koplugin-<version>.zip` from
   [Releases](https://github.com/karsyboy/pronunciation.koplugin/releases).
2. Extract it into `koreader/plugins/`.
3. Confirm `koreader/plugins/pronunciation.koplugin/main.lua` exists.
4. Restart KOReader.

> [!Note]
> You can replace the complete plugin directory when upgrading. KOReader stores settings and personal overrides separately.

## Use

- Tap **Pronunciation** in a dictionary result.
- Long-press **Pronunciation** to add or edit a personal override.
- Use **Search → Pronunciation lookup** to enter a word manually.

Settings are under **Search → Settings → Pronunciation settings**.

### Generated pronunciation

- **Off:** sourced database results and existing local derivation only.
- **Local:** also uses the selected language pack's `g2p.bin` model.
- **AI:** queries every selected AI provider and never falls back to Local.

### AI setup

1. Select one or more providers under **AI settings → Providers**.
2. Enter each provider's API key.
3. Open **Model**, fetch the models available to that key, and select one.
   Manual model entry is also available.
4. For a custom provider, enter its endpoint and choose the OpenAI-compatible
   or Anthropic request format.

Each selected provider runs independently. One provider failure does not hide another provider's result.

API keys stay in KOReader's pronunciation settings. They are never written to
pronunciation caches, logs, release files, or user-visible errors. Fetched model
lists remain in memory only for the current KOReader session.

### Language

**Pronunciation language** offers **Auto** and every installed language pack.
Auto uses the book's language metadata when available. AI requests include
that language tag even when no matching offline pack is installed.

## Lookup behavior

Personal overrides always win. The plugin then checks the selected sourced
database and valid local inflection derivations before using any generated
result. A cached generated result is reused before making a new Local or AI
request.

Generated caches are isolated by word, language, generation mode, provider,
model, and custom endpoint. **Clear cached pronunciations** removes Local and
AI results without deleting personal overrides.

## Optional language packs

Releases bundle English only. Build other packs with:

```sh
python3 tools/build_language_pack.py fr
python3 tools/build_language_pack.py fr de
python3 tools/build_language_pack.py --all
```

Copy the generated `data/<language-code>/` directory into the plugin's `data/`
directory and restart KOReader. Each pack contains sourced IPA, a readable
converter, and a local G2P model when a compatible MFA model exists.

## Limitations and licenses

Generated pronunciations are estimates, especially for names and invented
words. AI availability, behavior, cost, quotas, and privacy depend on the
configured provider. Offline sourced lookup continues working when AI is
unavailable.

- Plugin code: [MIT](LICENSE)
- WikiPron/Wiktionary data: CC BY-SA 4.0
- Montreal Forced Aligner English model: CC BY 4.0

See [`LICENSES.txt`](LICENSES.txt) for full attribution, provenance, hashes,
and modification notes.

Development and release instructions are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
