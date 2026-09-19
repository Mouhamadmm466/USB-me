#!/usr/bin/env bash
# Downloads the pinned model files listed in Scripts/model_manifest.json into ModelCache/ for
# development on a Mac (text-agent evaluation, benchmarks). The iOS app never bundles these files;
# it downloads them after install with Models/ModelDownloadManager.
#
#   Scripts/download_models.sh                 every pack
#   Scripts/download_models.sh --pack <id>     only that pack (repeatable)
#   Scripts/download_models.sh --list          list the packs and exit
#
# Idempotent. For each file:
#   - present and verified by an earlier run (stamp matches its size, mtime, inode and pin): skipped;
#   - present but not yet verified: byte size + `shasum -a 256` checked, then stamped and skipped;
#   - otherwise downloaded to ModelCache/.partial/<file>.part with `curl -L --fail --retry 5 -C -`
#     (an interrupted run resumes), checked the same way, then moved into place.
# A file that fails verification is never left under its final name.
# MODEL_CACHE_DIR overrides the destination directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/Scripts/model_manifest.json"
CACHE="${MODEL_CACHE_DIR:-$ROOT/ModelCache}"
PARTIAL="$CACHE/.partial"
STAMPS="$CACHE/.verified"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

PACKS=()
LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack) [[ $# -ge 2 ]] || die "--pack needs a pack id"; PACKS+=("$2"); shift 2 ;;
    --pack=*) PACKS+=("${1#--pack=}"); shift ;;
    --list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

for tool in python3 curl shasum; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

# Prints "pack<TAB>filename<TAB>url<TAB>bytes<TAB>sha256" per selected file (python3 stdlib only).
manifest_rows() {
  python3 - "$MANIFEST" ${PACKS[@]+"${PACKS[@]}"} <<'PY'
import json, re, sys
path, wanted = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8") as handle:
    packs = json.load(handle)["packs"]
known = [pack["id"] for pack in packs]
unknown = [pack_id for pack_id in wanted if pack_id not in known]
if unknown:
    sys.exit("unknown pack id: %s (known: %s)" % (", ".join(unknown), ", ".join(known)))
for pack in packs:
    if wanted and pack["id"] not in wanted:
        continue
    for item in pack["files"]:
        name, url, size, sha = item["filename"], item["sourceURL"], int(item["bytes"]), item["sha256"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name) or name.startswith("."):
            sys.exit("unsafe filename in manifest: %r" % name)
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            sys.exit("invalid sha256 for %s" % name)
        if not url.startswith("https://") or item["revision"] not in url or size <= 0:
            sys.exit("%s must have a positive size and an https URL pinned to its revision" % name)
        print("\t".join([pack["id"], name, url, str(size), sha]))
PY
}

list_packs() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
print("manifestVersion %d" % manifest["manifestVersion"])
for pack in manifest["packs"]:
    total = sum(int(item["bytes"]) for item in pack["files"])
    print("  %-28s %-4s %-18s %2d file(s) %8.1f MB  %s" % (
        pack["id"], pack["role"], pack["displayName"], len(pack["files"]), total / 1e6, pack["license"]))
PY
}

file_size() { python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_size)' "$1"; }
fingerprint() { python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print("%d %d %d" % (s.st_size, s.st_mtime_ns, s.st_ino))' "$1"; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
human() { awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1000 && i < 5) { b /= 1000; i++ } if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'; }

# A stamp records "<sha256> <size> <mtime_ns> <inode>" after a full SHA-256 check.
is_stamped() { # path sha
  local stamp="$STAMPS/$(basename "$1")"
  [[ -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$2 $(fingerprint "$1")" ]]
}
write_stamp() { # path sha
  mkdir -p "$STAMPS"
  printf '%s %s\n' "$2" "$(fingerprint "$1")" > "$STAMPS/$(basename "$1")"
}

SKIPPED=0
VERIFIED=0
DOWNLOADED=0

fetch_file() { # pack name url size sha
  local pack="$1" name="$2" url="$3" size="$4" sha="$5"
  local dest="$CACHE/$name" part="$PARTIAL/$name.part"

  if [[ -f "$dest" ]]; then
    if is_stamped "$dest" "$sha"; then
      note "$name: already verified, skipped"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    local have
    have="$(file_size "$dest")"
    if [[ "$have" == "$size" ]]; then
      note "$name: present, checking SHA-256 ($(human "$size"))"
      if [[ "$(sha256_of "$dest")" == "$sha" ]]; then
        write_stamp "$dest" "$sha"
        note "$name: verified, skipped download"
        VERIFIED=$((VERIFIED + 1))
        return 0
      fi
      note "$name: SHA-256 mismatch, downloading again"
      rm -f "$dest"
    elif (( have < size )); then
      note "$name: incomplete ($have of $size bytes), resuming"
      mkdir -p "$PARTIAL"
      mv -f "$dest" "$part"
    else
      note "$name: larger than pinned ($have > $size bytes), downloading again"
      rm -f "$dest"
    fi
  fi
  rm -f "$STAMPS/$name"

  mkdir -p "$PARTIAL"
  if [[ -f "$part" ]] && (( $(file_size "$part") > size )); then
    rm -f "$part"
  fi
  if [[ ! -f "$part" ]] || (( $(file_size "$part") < size )); then
    log "Downloading $name ($(human "$size")) for $pack"
    local status=0
    curl -L --fail --retry 5 -C - --proto '=https' --proto-redir '=https' --connect-timeout 30 \
      --progress-bar -o "$part" "$url" </dev/null || status=$?
    if [[ $status -eq 33 ]]; then # the server refused to resume: start over once
      note "$name: server cannot resume, restarting from zero"
      rm -f "$part"
      status=0
      curl -L --fail --retry 5 --proto '=https' --proto-redir '=https' --connect-timeout 30 \
        --progress-bar -o "$part" "$url" </dev/null || status=$?
    fi
    [[ $status -eq 0 ]] || die "$name: curl failed (exit $status); run again to resume"
  fi

  local got_size got_sha
  got_size="$(file_size "$part")"
  if [[ "$got_size" != "$size" ]]; then
    rm -f "$part"
    die "$name: size is $got_size bytes, expected $size (partial discarded)"
  fi
  got_sha="$(sha256_of "$part")"
  if [[ "$got_sha" != "$sha" ]]; then
    rm -f "$part"
    die "$name: SHA-256 is $got_sha, expected $sha (partial discarded)"
  fi
  mv -f "$part" "$dest"
  write_stamp "$dest" "$sha"
  note "$name: downloaded, size and SHA-256 verified"
  DOWNLOADED=$((DOWNLOADED + 1))
}

if [[ $LIST -eq 1 ]]; then
  list_packs
  exit 0
fi

ROWS="$(manifest_rows)"
mkdir -p "$CACHE"
log "Model cache: $CACHE"
while IFS=$'\t' read -r pack name url size sha; do
  [[ -n "$name" ]] || continue
  fetch_file "$pack" "$name" "$url" "$size" "$sha"
done <<< "$ROWS"
rmdir "$PARTIAL" 2>/dev/null || true

log "Done: $SKIPPED already verified, $VERIFIED verified now, $DOWNLOADED downloaded"
