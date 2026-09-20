#!/usr/bin/env bash
# Fetches and verifies every pinned third-party runtime. Idempotent; pass --force to rebuild.
#
#   Vendor/Frameworks/whisper.xcframework  official whisper.cpp v1.9.4 (build b5130) release asset
#   Vendor/Frameworks/llama.xcframework    official llama.cpp b11046 device + macOS slices, plus an
#                                          iOS-simulator slice built from the same tag with the
#                                          official build-xcframework.sh (the release omits it)
#   Vendor/Packages/MisakiSwift            mlalma/MisakiSwift 1.0.6   + Vendor/Patches (packaging only)
#   Vendor/Packages/kokoro-ios             mlalma/kokoro-ios 1.0.11   + Vendor/Patches (packaging only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

WHISPER_TAG="b5130"            # == whisper.cpp v1.9.4
WHISPER_ZIP_SHA256="033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
LLAMA_TAG="b11046"
LLAMA_COMMIT="60081bb2b5b3294165a4d67c5cbeebe74c868014"
LLAMA_ZIP_SHA256="b6c46399c1fc2c027951049b4f7ba6f3e00c28dbeeb68fde85817d100dd49938"
MISAKI_TAG="1.0.6"
MISAKI_COMMIT="6835a1ce4a8854075c89f18ff75c74b13ef58e15"
KOKORO_TAG="1.0.11"
KOKORO_COMMIT="4d6d1d8ff8cd012014180c9cd4cf0151e7682354"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in curl shasum unzip git cmake xcrun xcodebuild; do
  command -v "$tool" >/dev/null || die "$tool is required (see docs/setup/README.md)"
done

mkdir -p "$VENDOR/Downloads" "$VENDOR/Frameworks" "$VENDOR/Packages" "$VENDOR/src"

fetch_verified() { # url dest sha256
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
    return 0
  fi
  log "Downloading $(basename "$dest")"
  curl -L --fail --retry 5 -C - -o "$dest" "$url"
  local got; got="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
  [[ "$got" == "$sha" ]] || { rm -f "$dest"; die "SHA-256 mismatch for $dest: $got"; }
}

# --- whisper.cpp --------------------------------------------------------------------------------
WHISPER_ZIP="$VENDOR/Downloads/whisper-$WHISPER_TAG-xcframework.zip"
fetch_verified "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_TAG/whisper-$WHISPER_TAG-xcframework.zip" \
  "$WHISPER_ZIP" "$WHISPER_ZIP_SHA256"
if [[ $FORCE == 1 || ! -d "$VENDOR/Frameworks/whisper.xcframework" ]]; then
  log "Installing whisper.xcframework"
  rm -rf "$VENDOR/Frameworks/whisper.xcframework" "$VENDOR/src/whisper-unzip"
  unzip -q "$WHISPER_ZIP" -d "$VENDOR/src/whisper-unzip"
  mv "$VENDOR/src/whisper-unzip/build-apple/whisper.xcframework" "$VENDOR/Frameworks/"
  rm -rf "$VENDOR/src/whisper-unzip"
fi

# --- llama.cpp ----------------------------------------------------------------------------------
LLAMA_ZIP="$VENDOR/Downloads/llama-$LLAMA_TAG-xcframework.zip"
fetch_verified "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-xcframework.zip" \
  "$LLAMA_ZIP" "$LLAMA_ZIP_SHA256"
if [[ $FORCE == 1 || ! -d "$VENDOR/Frameworks/llama.xcframework/ios-arm64_x86_64-simulator" ]]; then
  log "Preparing llama.cpp $LLAMA_TAG source for the iOS-simulator slice"
  if [[ ! -d "$VENDOR/src/llama.cpp/.git" ]]; then
    git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$VENDOR/src/llama.cpp"
  fi
  got="$(git -C "$VENDOR/src/llama.cpp" rev-parse HEAD)"
  [[ "$got" == "$LLAMA_COMMIT" ]] || die "llama.cpp checkout is $got, expected $LLAMA_COMMIT"
  if [[ $FORCE == 1 || ! -d "$VENDOR/src/llama.cpp/build-apple/llama.xcframework/ios-arm64_x86_64-simulator" ]]; then
    log "Building llama.cpp iOS-simulator slice (official build-xcframework.sh ios-sim)"
    (cd "$VENDOR/src/llama.cpp" && ./build-xcframework.sh ios-sim)
  fi
  log "Merging official device/macOS slices with the simulator slice"
  rm -rf "$VENDOR/src/llama-unzip" "$VENDOR/Frameworks/llama.xcframework"
  unzip -q "$LLAMA_ZIP" -d "$VENDOR/src/llama-unzip"
  OFFICIAL="$VENDOR/src/llama-unzip/build-apple/llama.xcframework"
  SIM="$VENDOR/src/llama.cpp/build-apple/llama.xcframework/ios-arm64_x86_64-simulator"
  xcrun xcodebuild -create-xcframework \
    -framework "$OFFICIAL/ios-arm64/llama.framework" -debug-symbols "$OFFICIAL/ios-arm64/dSYMs/llama.dSYM" \
    -framework "$OFFICIAL/macos-arm64_x86_64/llama.framework" -debug-symbols "$OFFICIAL/macos-arm64_x86_64/dSYMs/llama.dSYM" \
    -framework "$SIM/llama.framework" -debug-symbols "$SIM/dSYMs/llama.dSYM" \
    -output "$VENDOR/Frameworks/llama.xcframework"
  rm -rf "$VENDOR/src/llama-unzip"
fi

# --- KokoroSwift + MisakiSwift (packaging patch) ------------------------------------------------
checkout_patched() { # name url tag commit patch
  local name="$1" url="$2" tag="$3" commit="$4" patch="$5"
  local dir="$VENDOR/Packages/$name"
  if [[ $FORCE == 1 ]]; then rm -rf "$dir"; fi
  if [[ ! -d "$dir/.git" ]]; then
    log "Checking out $name $tag"
    git clone -q --branch "$tag" "$url" "$dir"
    local got; got="$(git -C "$dir" rev-parse HEAD)"
    [[ "$got" == "$commit" ]] || die "$name checkout is $got, expected $commit"
    log "Applying $(basename "$patch")"
    git -C "$dir" apply --index "$patch"
  fi
}
checkout_patched MisakiSwift https://github.com/mlalma/MisakiSwift.git "$MISAKI_TAG" "$MISAKI_COMMIT" \
  "$VENDOR/Patches/MisakiSwift-1.0.6-resource-bundle.patch"
checkout_patched kokoro-ios https://github.com/mlalma/kokoro-ios.git "$KOKORO_TAG" "$KOKORO_COMMIT" \
  "$VENDOR/Patches/kokoro-ios-1.0.11-resource-bundle.patch"

log "Dependencies ready"
ls -1 "$VENDOR/Frameworks" "$VENDOR/Packages"
