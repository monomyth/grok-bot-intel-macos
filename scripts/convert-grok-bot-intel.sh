#!/usr/bin/env bash
# Convert an Apple-silicon Grok Bot.app into an Intel (x86_64) app.
# Reproduces the 0.18.0 / Electron 42.1.0 conversion. Does not ship Grok Bot.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  convert-grok-bot-intel.sh --input "/path/to/Grok Bot.app" --output "/path/to/Grok Bot-intel.app"

Required:
  --input   Apple-silicon Grok Bot.app (your licensed copy)
  --output  Destination .app path (must not already exist)

Optional:
  --cursor  Cursor.app used as a source of N-API Intel natives
            (default: /Applications/Cursor.app)
  --work    Scratch directory (default: a unique dir under $TMPDIR)
  --keep-work
            Leave the scratch directory after success

Environment:
  CURSOR_APP   Same as --cursor
EOF
}

INPUT=""
OUTPUT=""
CURSOR_APP="${CURSOR_APP:-/Applications/Cursor.app}"
WORK=""
KEEP_WORK=0
APP_NAME="Grok Bot"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --cursor) CURSOR_APP="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 2
fi
if [[ ! -d "$INPUT" ]]; then
  echo "input app not found: $INPUT" >&2
  exit 1
fi
if [[ -e "$OUTPUT" ]]; then
  echo "output already exists: $OUTPUT" >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "this script must run on macOS" >&2
  exit 1
fi
if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "i386" ]]; then
  echo "warning: host arch is $(uname -m); this conversion targets Intel x86_64" >&2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
need curl
need ditto
need unzip
need python3
need npx
need codesign
need file
if [[ ! -x /usr/libexec/PlistBuddy ]]; then
  echo "missing /usr/libexec/PlistBuddy" >&2
  exit 1
fi

if [[ ! -d "$CURSOR_APP" ]]; then
  echo "Cursor.app not found at $CURSOR_APP" >&2
  echo "Intel copies of @anysphere/tree-chunk-napi, cursor-proclist, and tree-sitter come from Cursor." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/entitlements.plist"

if [[ -z "$WORK" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/grokbot-intel.XXXXXX")"
else
  mkdir -p "$WORK"
fi
if [[ "$KEEP_WORK" -eq 0 ]]; then
  trap 'rm -rf "$WORK"' EXIT
fi

echo "==> work dir: $WORK"

INPUT_BIN="$INPUT/Contents/MacOS/$APP_NAME"
if [[ ! -f "$INPUT_BIN" ]]; then
  # fall back to Info.plist executable name
  APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INPUT/Contents/Info.plist")"
  INPUT_BIN="$INPUT/Contents/MacOS/$APP_NAME"
fi

INPUT_ARCH="$(file -b "$INPUT_BIN")"
echo "==> input executable: $INPUT_ARCH"
if echo "$INPUT_ARCH" | grep -q 'x86_64' && ! echo "$INPUT_ARCH" | grep -q 'arm64'; then
  echo "input is already Intel-only; nothing to convert" >&2
  exit 1
fi

ELECTRON_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$INPUT/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist" 2>/dev/null \
    || true
)"
if [[ -z "$ELECTRON_VERSION" ]]; then
  echo "could not read Electron version from input app" >&2
  exit 1
fi
echo "==> Electron $ELECTRON_VERSION"

CURSOR_EXEC="$CURSOR_APP/Contents/Resources/app/extensions/cursor-agent-exec/dist/node_modules"
CURSOR_PROCLIST="$CURSOR_APP/Contents/Resources/app/node_modules/cursor-proclist/build/Release/cursor_proclist.node"
for f in \
  "$CURSOR_EXEC/tree-sitter/build/Release/tree_sitter_runtime_binding.node" \
  "$CURSOR_EXEC/tree-sitter-bash/build/Release/tree_sitter_bash_binding.node" \
  "$CURSOR_EXEC/@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-universal.node" \
  "$CURSOR_EXEC/whichlang-node/whichlang-node.darwin-universal.node" \
  "$CURSOR_PROCLIST"
do
  if [[ ! -f "$f" ]]; then
    echo "missing Cursor native: $f" >&2
    exit 1
  fi
done

echo "==> download Electron v${ELECTRON_VERSION} darwin-x64"
ELECTRON_ZIP="$WORK/electron-v${ELECTRON_VERSION}-darwin-x64.zip"
curl -L --fail --retry 3 -o "$ELECTRON_ZIP" \
  "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-x64.zip"
rm -rf "$WORK/Electron.app"
unzip -q "$ELECTRON_ZIP" -d "$WORK"
if [[ ! -d "$WORK/Electron.app" ]]; then
  echo "Electron.zip did not contain Electron.app" >&2
  exit 1
fi

echo "==> resolve Electron NODE_MODULE_VERSION"
ABI="$(npx --yes node-abi --target "$ELECTRON_VERSION" --runtime electron 2>/dev/null | tr -d '[:space:]' || true)"
if [[ ! "$ABI" =~ ^[0-9]+$ ]]; then
  # Electron 42.1.0 is ABI 146 (verified against official headers).
  if [[ "$ELECTRON_VERSION" == "42.1.0" ]]; then
    ABI=146
  else
    echo "could not determine Electron ABI for $ELECTRON_VERSION" >&2
    exit 1
  fi
fi
echo "==> Electron ABI $ABI"

echo "==> download better-sqlite3 prebuild (electron-v${ABI} darwin-x64)"
# 12.6.2 (shipped in Grok Bot 0.18.0) has no electron-v146 prebuild and will not
# compile against Electron 42's V8. 12.12.0 ships the matching ABI and loads
# with the existing 12.6.x JS.
BSQL_VER="12.12.0"
BSQL_TGZ="$WORK/better-sqlite3-prebuild.tar.gz"
curl -L --fail --retry 3 -o "$BSQL_TGZ" \
  "https://github.com/WiseLibs/better-sqlite3/releases/download/v${BSQL_VER}/better-sqlite3-v${BSQL_VER}-electron-v${ABI}-darwin-x64.tar.gz"
mkdir -p "$WORK/bsql-prebuild"
tar -xzf "$BSQL_TGZ" -C "$WORK/bsql-prebuild"
BSQL_NODE="$WORK/bsql-prebuild/build/Release/better_sqlite3.node"
if [[ ! -f "$BSQL_NODE" ]]; then
  echo "better-sqlite3 prebuild missing better_sqlite3.node" >&2
  exit 1
fi

echo "==> download whichlang-node-darwin-x64"
WHICH_TGZ="$WORK/whichlang-node-darwin-x64.tgz"
curl -L --fail -o "$WHICH_TGZ" \
  "https://registry.npmjs.org/whichlang-node-darwin-x64/-/whichlang-node-darwin-x64-0.2.1.tgz"
mkdir -p "$WORK/whichlang-node-darwin-x64"
tar -xzf "$WHICH_TGZ" -C "$WORK/whichlang-node-darwin-x64" --strip-components=1

echo "==> copy input app"
ditto "$INPUT" "$WORK/Grok Bot.app"
APP="$WORK/Grok Bot.app"

echo "==> replace Electron runtime with official x64 binaries"
rm -rf "$APP/Contents/_CodeSignature" "$APP/Contents/CodeResources"
rm -rf "$APP/Contents/Frameworks"
ditto "$WORK/Electron.app/Contents/Frameworks" "$APP/Contents/Frameworks"
rm -f "$APP/Contents/MacOS/$APP_NAME"
ditto "$WORK/Electron.app/Contents/MacOS/Electron" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

rename_helper() {
  local old_app="$1"
  local old_base="${old_app%.app}"
  local new_base="${old_base/Electron/$APP_NAME}"
  local new_app="${new_base}.app"
  local suffix="${old_base#Electron Helper}"
  local id_suffix=""
  case "$suffix" in
    "") id_suffix="" ;;
    " (GPU)") id_suffix=".GPU" ;;
    " (Plugin)") id_suffix=".Plugin" ;;
    " (Renderer)") id_suffix=".Renderer" ;;
    *) id_suffix=".$suffix" ;;
  esac
  mv "$old_app" "$new_app"
  if [[ -f "$new_app/Contents/MacOS/$old_base" ]]; then
    mv "$new_app/Contents/MacOS/$old_base" "$new_app/Contents/MacOS/$new_base"
    chmod +x "$new_app/Contents/MacOS/$new_base"
  fi
  local plist="$new_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $new_base" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $new_base" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $old_base" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $old_base" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $new_base" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $new_base" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.anysphere.sand.helper${id_suffix}" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.anysphere.sand.helper${id_suffix}" "$plist"
  rm -rf "$new_app/Contents/_CodeSignature"
}

(
  cd "$APP/Contents/Frameworks"
  for h in "Electron Helper.app" "Electron Helper (GPU).app" "Electron Helper (Plugin).app" "Electron Helper (Renderer).app"; do
    rename_helper "$h"
  done
)

echo "==> extract asar and inject Intel natives"
ASAR_IN="$APP/Contents/Resources/app.asar"
EXTRACT="$WORK/asar-src"
rm -rf "$EXTRACT"
npx --yes @electron/asar extract "$ASAR_IN" "$EXTRACT"
DEPS="$EXTRACT/dist/deps"

mkdir -p "$DEPS/better-sqlite3/build/Release"
cp -f "$BSQL_NODE" "$DEPS/better-sqlite3/build/Release/better_sqlite3.node"

mkdir -p "$DEPS/tree-sitter/build/Release"
cp -f "$CURSOR_EXEC/tree-sitter/build/Release/tree_sitter_runtime_binding.node" \
  "$DEPS/tree-sitter/build/Release/tree_sitter_runtime_binding.node"

mkdir -p "$DEPS/tree-sitter-bash/prebuilds/darwin-x64" "$DEPS/tree-sitter-bash/build/Release"
cp -f "$CURSOR_EXEC/tree-sitter-bash/build/Release/tree_sitter_bash_binding.node" \
  "$DEPS/tree-sitter-bash/prebuilds/darwin-x64/tree-sitter-bash.node"
cp -f "$CURSOR_EXEC/tree-sitter-bash/build/Release/tree_sitter_bash_binding.node" \
  "$DEPS/tree-sitter-bash/build/Release/tree_sitter_bash_binding.node"

mkdir -p "$DEPS/whichlang-node-darwin-x64"
cp -f "$WORK/whichlang-node-darwin-x64/package.json" "$DEPS/whichlang-node-darwin-x64/"
cp -f "$WORK/whichlang-node-darwin-x64/whichlang-node.darwin-x64.node" \
  "$DEPS/whichlang-node-darwin-x64/"
cp -f "$WORK/whichlang-node-darwin-x64/whichlang-node.darwin-x64.node" \
  "$DEPS/whichlang-node/whichlang-node.darwin-x64.node"
cp -f "$CURSOR_EXEC/whichlang-node/whichlang-node.darwin-universal.node" \
  "$DEPS/whichlang-node/whichlang-node.darwin-universal.node"

cp -f "$CURSOR_EXEC/@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-universal.node" \
  "$DEPS/@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-universal.node"
cp -f "$CURSOR_EXEC/@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-universal.node" \
  "$DEPS/@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-x64.node"

mkdir -p "$DEPS/cursor-proclist/build/Release"
cp -f "$CURSOR_PROCLIST" "$DEPS/cursor-proclist/build/Release/cursor_proclist.node"

python3 - <<PY
import json
from pathlib import Path
p = Path("$DEPS/runtime-deps-manifest.json")
if p.exists():
    d = json.loads(p.read_text())
    d["arch"] = "x64"
    copied = set(d.get("copied", []))
    copied.add("whichlang-node-darwin-x64")
    d["copied"] = sorted(copied)
    d["nodeFiles"] = [
        "@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-universal.node",
        "@anysphere/tree-chunk-napi/tree-chunk-napi.darwin-x64.node",
        "better-sqlite3/build/Release/better_sqlite3.node",
        "cursor-proclist/build/Release/cursor_proclist.node",
        "tree-sitter-bash/prebuilds/darwin-x64/tree-sitter-bash.node",
        "tree-sitter-bash/build/Release/tree_sitter_bash_binding.node",
        "tree-sitter/build/Release/tree_sitter_runtime_binding.node",
        "whichlang-node/whichlang-node.darwin-x64.node",
        "whichlang-node-darwin-x64/whichlang-node.darwin-x64.node",
    ]
    p.write_text(json.dumps(d, indent=2) + "\n")
PY

echo "==> repack asar (unpack native binaries)"
NEW_ASAR="$WORK/app.asar"
rm -f "$NEW_ASAR"
rm -rf "$WORK/app.asar.unpacked"
npx --yes @electron/asar pack "$EXTRACT" "$NEW_ASAR" \
  --unpack "{*.node,sand-op-launcher,sand-webauthn-signer}"
rm -rf "$APP/Contents/Resources/app.asar" "$APP/Contents/Resources/app.asar.unpacked"
ditto "$NEW_ASAR" "$APP/Contents/Resources/app.asar"
ditto "$WORK/app.asar.unpacked" "$APP/Contents/Resources/app.asar.unpacked"

HASH="$(shasum -a 256 "$APP/Contents/Resources/app.asar" | awk '{print $1}')"
echo "==> asar sha256 $HASH"
/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $HASH" \
  "$APP/Contents/Info.plist"

echo "==> ad-hoc codesign"
xattr -cr "$APP" || true
sign() { codesign --force --sign - --timestamp=none "$@"; }

sign "$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler"
for d in "$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/"*.dylib; do
  sign "$d"
done
sign "$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
sign "$APP/Contents/Frameworks/Electron Framework.framework"
for fw in Mantle ReactiveObjC Squirrel; do
  if [[ -x "$APP/Contents/Frameworks/$fw.framework/Versions/A/Resources/ShipIt" ]]; then
    sign "$APP/Contents/Frameworks/$fw.framework/Versions/A/Resources/ShipIt"
  fi
  sign "$APP/Contents/Frameworks/$fw.framework"
done
for h in "Grok Bot Helper" "Grok Bot Helper (GPU)" "Grok Bot Helper (Plugin)" "Grok Bot Helper (Renderer)"; do
  sign "$APP/Contents/Frameworks/${h}.app"
done
find "$APP/Contents/Resources/app.asar.unpacked" \( -name "*.node" -o -name "sand-*" \) -type f -print0 \
  | xargs -0 -n1 codesign --force --sign - --timestamp=none

if [[ -f "$ENTITLEMENTS" ]]; then
  sign --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/$APP_NAME"
  sign --entitlements "$ENTITLEMENTS" "$APP"
else
  sign "$APP/Contents/MacOS/$APP_NAME"
  sign "$APP"
fi

codesign --verify --verbose=2 "$APP"
file "$APP/Contents/MacOS/$APP_NAME" | grep -q x86_64

echo "==> write $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
ditto "$APP" "$OUTPUT"
xattr -cr "$OUTPUT" || true

echo
echo "Intel app written to:"
echo "  $OUTPUT"
echo
echo "First launch may copy itself into /Applications (Squirrel)."
echo "Ad-hoc signed: if Gatekeeper blocks it, right-click the app and choose Open."
echo "Do not launch the stock Electron.app with Node flags such as -e; that is not an app path."
