# Grok Bot on Intel macOS

## Prefer the official Intel build (current)

As of **0.29.0** (2026-08-27), Cursor publishes a notarized Intel DMG. Use that instead of converting:

```text
https://downloads.cursor.com/sand/stable/darwin-x64/0.29.0/Grok_Bot_0.29.0_x64.dmg
```

Same file also exists under `downloads.cursor.com/grokbot/stable/darwin-x64/0.29.0/`. SHA-256:

```text
65d1759109ef1a8741a41cba042de223afb58f21538b08f4199682ad2747aed3
```

Latest version (update feed):

```bash
curl -sL "https://api2.cursor.sh/updates/api/update/darwin-x64/sand/0.0.0/stable"
# {"url":".../darwin/x64/Cursor-darwin-x64.zip","name":"0.29.0"}
```

Verified here: Developer ID `Anysphere Incorporated (DCNK4UB866)`, stapled notarization, Gatekeeper `accepted`. Launch showed main, GPU, renderer, local-exec daemon, and a ~1194×1056 window.

Apple silicon URL for the same version:

```text
https://downloads.cursor.com/sand/stable/darwin-arm64/0.29.0/Grok_Bot_0.29.0.dmg
```

---

## Convert an Apple-silicon `.app` when no Intel DMG exists

Recipe and script for turning an **Apple silicon** Grok Bot desktop app into an **Intel (`x86_64`)** app. Needed for 0.18.0 / 0.24.0, when `darwin-x64` returned HTTP 403.

This repository does **not** contain Grok Bot, Electron, or any Cursor/SpaceXAI native binaries. You must already have a licensed Grok Bot.app (and a Cursor.app used as a native-module donor).

Verified conversions:

| Piece | Version |
| --- | --- |
| Grok Bot | 0.18.0, 0.24.0 (`com.anysphere.sand`) |
| Electron | 42.1.0 (`NODE_MODULE_VERSION` / ABI **146**) |
| Host | Intel Mac (Xeon), macOS |
| Last converted | 0.24.0 on 2026-08-23 |

0.24.0 converted Intel: main, GPU, renderer, local-exec daemon, window, no Crashpad reports.

## What you need

- An Intel Mac
- A licensed **Grok Bot.app** (Apple silicon)
- **Cursor.app** installed (Intel). Several natives are proprietary N-API addons that ship in Cursor and are not on the public npm registry
- Xcode command-line tools (`clang`, `codesign`, `PlistBuddy`)
- `curl`, `python3`, `node` / `npx` (Node 20+ is fine)

Cursor is only a **binary donor**. The converted app still runs Grok Bot’s own `app.asar`.

## Quick start

```bash
git clone https://github.com/monomyth/grok-bot-intel-macos.git
cd grok-bot-intel-macos
chmod +x scripts/convert-grok-bot-intel.sh

./scripts/convert-grok-bot-intel.sh \
  --input  "/path/to/Grok Bot.app" \
  --output "$HOME/Desktop/Grok Bot.app"
```

Optional:

```text
--cursor /Applications/Cursor.app     # default
--work   /tmp/grokbot-intel-work      # keep intermediates
--keep-work
```

First launch may copy the app into `/Applications` (Squirrel). The result is **ad-hoc signed**. If Gatekeeper blocks a double-click, right-click the app → **Open**.

## What the conversion does

1. Read Electron’s version from the input app (`Electron Framework` `CFBundleVersion`).
2. Download official `electron-v<VER>-darwin-x64.zip` from the Electron GitHub releases.
3. Replace `Contents/MacOS/Grok Bot`, `Electron Framework.framework`, Mantle / ReactiveObjC / Squirrel, and the four Helper apps. Rename helpers to `Grok Bot Helper*` and restore Grok’s helper bundle IDs (`com.anysphere.sand.helper` and `.GPU` / `.Plugin` / `.Renderer`).
4. Extract `Contents/Resources/app.asar`.
5. Swap native addons (see table below).
6. Repack the asar, unpacking `*.node` plus `sand-op-launcher` / `sand-webauthn-signer`.
7. Write the new SHA-256 into `Info.plist` → `ElectronAsarIntegrity`.
8. Ad-hoc codesign inside-out with `entitlements.plist`.

`sand-op-launcher` and `sand-webauthn-signer` in 0.18.0 and 0.24.0 are already universal binaries; they are left as-is.

## Native modules

| Module | In arm64 app (0.18.0 / 0.24.0) | Intel source | Notes |
| --- | --- | --- | --- |
| `better-sqlite3` 12.6.2 (still in 0.24.0) | `build/Release/better_sqlite3.node` (V8 addon, not N-API) | [WiseLibs prebuild](https://github.com/WiseLibs/better-sqlite3/releases) `v12.12.0` `electron-v146-darwin-x64` | 12.6.2 has no ABI 146 prebuild and **does not compile** against Electron 42’s V8 (`External::Value` / `External::New` arity). 12.12.0 loads with the shipped 12.6.x JS. |
| `tree-sitter` 0.21.1 | `build/Release/tree_sitter_runtime_binding.node` | Cursor `cursor-agent-exec` (N-API, same version) | |
| `tree-sitter-bash` 0.21.0 | `prebuilds/darwin-arm64/` | Cursor `cursor-agent-exec` (N-API, same version) | Also written to `prebuilds/darwin-x64/` and `build/Release/` so `node-gyp-build` finds it. |
| `whichlang-node` 0.2.1 | optional dep `whichlang-node-darwin-arm64` | npm `whichlang-node-darwin-x64@0.2.1` plus Cursor’s `darwin-universal` | Loader lives in `dist/deps`; `NODE_PATH` is set to that folder. |
| `@anysphere/tree-chunk-napi` | `tree-chunk-napi.darwin-arm64.node` | Cursor `tree-chunk-napi.darwin-universal.node` (N-API) | Copied as both `darwin-universal` and `darwin-x64`. Not on public npm. |
| `cursor-proclist` | `build/Release/cursor_proclist.node` | Cursor `node_modules/cursor-proclist` (N-API) | |

N-API addons from Cursor’s Electron 39 build load in Electron 42. `better-sqlite3` is a classic V8 addon and **must** match ABI 146.

Grok Bot sets `NODE_PATH` to `app.asar/dist/deps` at process start. New platform packages (`whichlang-node-darwin-x64`, extra `.node` names) have to exist **inside the asar tree**, not only in `app.asar.unpacked`, or `require()` will miss them.

## Manual steps (same as the script)

Use these if you want to do it by hand.

### 1. Confirm the input is arm64

```bash
file "/path/to/Grok Bot.app/Contents/MacOS/Grok Bot"
plutil -p "/path/to/Grok Bot.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist" | grep CFBundleVersion
```

### 2. Download matching Electron x64

```bash
curl -L -o electron-v42.1.0-darwin-x64.zip \
  https://github.com/electron/electron/releases/download/v42.1.0/electron-v42.1.0-darwin-x64.zip
unzip electron-v42.1.0-darwin-x64.zip
```

Copy `Electron.app/Contents/Frameworks` over the Grok app’s Frameworks. Replace `Contents/MacOS/Grok Bot` with `Electron.app/Contents/MacOS/Electron`. Rename:

```text
Electron Helper.app              → Grok Bot Helper.app
Electron Helper (GPU).app        → Grok Bot Helper (GPU).app
Electron Helper (Plugin).app     → Grok Bot Helper (Plugin).app
Electron Helper (Renderer).app   → Grok Bot Helper (Renderer).app
```

Move each helper executable to the new name and set `CFBundleExecutable` / `CFBundleIdentifier` as in the script.

### 3. Fetch Intel natives

```bash
# better-sqlite3 for Electron ABI 146
curl -L -o bsql.tgz \
  https://github.com/WiseLibs/better-sqlite3/releases/download/v12.12.0/better-sqlite3-v12.12.0-electron-v146-darwin-x64.tar.gz

# whichlang
curl -L -o whichlang.tgz \
  https://registry.npmjs.org/whichlang-node-darwin-x64/-/whichlang-node-darwin-x64-0.2.1.tgz
```

Copy the Cursor paths listed in the table into the extracted asar’s `dist/deps/`.

### 4. Repack

```bash
npx @electron/asar extract "Grok Bot.app/Contents/Resources/app.asar" asar-src
# copy natives into asar-src/dist/deps/...
npx @electron/asar pack asar-src app.asar --unpack "{*.node,sand-op-launcher,sand-webauthn-signer}"
```

Put `app.asar` and `app.asar.unpacked` back under `Contents/Resources/`. Set:

```text
Info.plist → ElectronAsarIntegrity → Resources/app.asar → hash
```

to `shasum -a 256` of the new asar.

### 5. Sign

Sign crashpad, Electron Framework dylibs, the framework, Mantle / ReactiveObjC / Squirrel, helpers, unpacked `.node` files, then the main executable and the `.app`, using `entitlements.plist`.

Do **not** run:

```bash
Electron -e "console.log(process.versions)"
```

Plain Electron treats `-e …` as an **app path**. That produces:

```text
Unable to find Electron app at /…/console.log(JSON.stringify(process.versions,null,2))
```

If you need Electron’s versions, use:

```bash
ELECTRON_RUN_AS_NODE=1 Electron.app/Contents/MacOS/Electron -p "JSON.stringify(process.versions)"
```

## After conversion

```bash
file "Grok Bot.app/Contents/MacOS/Grok Bot"
# Mach-O 64-bit executable x86_64

codesign --verify --verbose=2 "Grok Bot.app"
open "Grok Bot.app"
```

Expect a renderer process (`Grok Bot Helper (Renderer)`), a `local-exec-daemon`, and a window. The original arm64 app can be kept as a backup (for example `Grok Bot.arm64.bak.app`).

Auto-update may later try to fetch an official build. If that build is arm64-only, the app will break on Intel again; prefer an official Intel download if Cursor publishes one.

## License

The scripts and docs in this repo are MIT (see `LICENSE`).

Grok Bot, Cursor, and their native addons are property of SpaceXAI / Anysphere. This project only documents how to retarget a copy you already have. Do not upload `.app` bundles or `.node` files from those products to GitHub.
