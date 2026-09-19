#!/usr/bin/env bash
# Verifies ModelCache/ against Scripts/model_manifest.json: every pinned file must exist with its
# exact byte size and SHA-256 (`shasum -a 256`, always a full hash). Files the manifest does not list
# are reported and ignored. Exit status 0 only when every selected file matches.
#
#   Scripts/verify_models.sh                 every pack
#   Scripts/verify_models.sh --pack <id>     only that pack (repeatable)
#
# MODEL_CACHE_DIR overrides the directory. A successful check refreshes the stamp that lets
# Scripts/download_models.sh skip the file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/Scripts/model_manifest.json"
CACHE="${MODEL_CACHE_DIR:-$ROOT/ModelCache}"
STAMPS="$CACHE/.verified"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

PACKS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack) [[ $# -ge 2 ]] || die "--pack needs a pack id"; PACKS+=("$2"); shift 2 ;;
    --pack=*) PACKS+=("${1#--pack=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

for tool in python3 shasum; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ -d "$CACHE" ]] || die "no model cache at $CACHE (run Scripts/download_models.sh)"

# "pack<TAB>filename<TAB>bytes<TAB>sha256" for the selected packs; "all" lists every filename.
manifest_rows() { # mode [pack ids...]
  python3 - "$MANIFEST" "$@" <<'PY'
import json, re, sys
path, mode, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(path, encoding="utf-8") as handle:
    packs = json.load(handle)["packs"]
known = [pack["id"] for pack in packs]
unknown = [pack_id for pack_id in wanted if pack_id not in known]
if unknown:
    sys.exit("unknown pack id: %s (known: %s)" % (", ".join(unknown), ", ".join(known)))
for pack in packs:
    for item in pack["files"]:
        name = item["filename"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name) or name.startswith("."):
            sys.exit("unsafe filename in manifest: %r" % name)
        if mode == "all":
            print(name)
        elif not wanted or pack["id"] in wanted:
            print("\t".join([pack["id"], name, str(int(item["bytes"])), item["sha256"]]))
PY
}

file_size() { python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_size)' "$1"; }
fingerprint() { python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print("%d %d %d" % (s.st_size, s.st_mtime_ns, s.st_ino))' "$1"; }

ROWS="$(manifest_rows selected ${PACKS[@]+"${PACKS[@]}"})"
ALL_NAMES="$(manifest_rows all)"

printf 'Verifying %s\n' "$CACHE"
FAILED=0
CHECKED=0
while IFS=$'\t' read -r pack name size sha; do
  [[ -n "$name" ]] || continue
  CHECKED=$((CHECKED + 1))
  path="$CACHE/$name"
  if [[ ! -f "$path" ]]; then
    printf '  FAIL  %-40s missing (%s)\n' "$name" "$pack"
    FAILED=$((FAILED + 1))
    continue
  fi
  have="$(file_size "$path")"
  if [[ "$have" != "$size" ]]; then
    printf '  FAIL  %-40s %s bytes, expected %s\n' "$name" "$have" "$size"
    rm -f "$STAMPS/$name"
    FAILED=$((FAILED + 1))
    continue
  fi
  got="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$got" != "$sha" ]]; then
    printf '  FAIL  %-40s SHA-256 %s, expected %s\n' "$name" "$got" "$sha"
    rm -f "$STAMPS/$name"
    FAILED=$((FAILED + 1))
    continue
  fi
  mkdir -p "$STAMPS"
  printf '%s %s\n' "$sha" "$(fingerprint "$path")" > "$STAMPS/$name"
  printf '  OK    %-40s %12s bytes  sha256 %s\n' "$name" "$size" "$sha"
done <<< "$ROWS"

for path in "$CACHE"/*; do
  [[ -f "$path" ]] || continue
  name="$(basename "$path")"
  if ! grep -qxF "$name" <<< "$ALL_NAMES"; then
    printf '  note  %-40s not in the manifest (ignored)\n' "$name"
  fi
done

if [[ $FAILED -gt 0 ]]; then
  printf '%d of %d file(s) failed verification. Run Scripts/download_models.sh to repair.\n' "$FAILED" "$CHECKED"
  exit 1
fi
printf 'All %d file(s) match the manifest.\n' "$CHECKED"
