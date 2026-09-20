# Model manifest, integrity and lifecycle

The three on-device models are **never bundled in the app**. After install, the app downloads (or
imports) them, verifies them, and activates them (PRD §12). Checksums are verified before any model
is used (PRD §18).

- **Source of truth:** `ModelManifest.v1` in `Models/ModelManifest.swift`, compiled into the app. There is no remote manifest.
- **Mirror:** `Scripts/model_manifest.json`, read by the developer scripts. `ModelsTests` fails if the two differ in any key or value.
- **Code:** `Models/`. `ModelManager` is the app-facing API. `ModelDownloadManager` owns the on-disk store, and `ModelIntegrity` does the hashing.

## Pinned packs

| Pack id | Role | Display name | Licence | Pack revision¹ |
|---|---|---|---|---|
| `whisper-base.en` | asr | Speech recognition | MIT | `e01e970685c7f145` |
| `nemotron-3-nano-4b-q4_k_m` | llm | Language model | NVIDIA Nemotron Open Model License | `10686bb1f7ee339c` |
| `kokoro-82m` | tts | Voice | Apache-2.0 | `d6bf05800f79c50d` |

| File (pack) | Source repository @ revision | Bytes | SHA-256 |
|---|---|---|---|
| `ggml-base.en.bin` (whisper-base.en) | [`ggerganov/whisper.cpp`](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin) @ `5359861c739e955e79d9a303bcbc70fb988958b1` | 147,964,211 | `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` |
| `ggml-silero-v6.2.0.bin` (whisper-base.en; Silero VAD, MIT) | [`ggml-org/whisper-vad`](https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin) @ `9ffd54a1e1ee413ddf265af9913beaf518d1639b` | 885,098 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` |
| `NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf` (nemotron-3-nano-4b-q4_k_m) | [`nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF`](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF/resolve/1260a7780236524372acab3fdff3da563b611a2c/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf) @ `1260a7780236524372acab3fdff3da563b611a2c` | 2,837,072,864 | `be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2` |
| `kokoro-v1_0.safetensors` (kokoro-82m) | [`mlx-community/Kokoro-82M-bf16`](https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/a71e4d38b236d968966a2002c4c895dbd12b1c3c/kokoro-v1_0.safetensors) @ `a71e4d38b236d968966a2002c4c895dbd12b1c3c` | 327,115,152 | `4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8` |
| `af_heart.safetensors` (kokoro-82m; remote path `voices/af_heart.safetensors`) | [`mlx-community/Kokoro-82M-bf16`](https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/a71e4d38b236d968966a2002c4c895dbd12b1c3c/voices/af_heart.safetensors) @ `a71e4d38b236d968966a2002c4c895dbd12b1c3c` | 522,320 | `2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094` |

The total is 3,313,559,645 bytes (about 3.3 GB). Every pack requires app ≥ 1.0.0, iOS ≥ 18.0 and at
least 7.5 GB of physical memory. `manifestVersion` is 1.

¹ **Pack revision.** This is a content-derived identifier: the first 16 hex characters of a SHA-256
over the pack id, the role, and each file's name, size and SHA-256. It names the directory
`<root>/<packID>/<revision>/`.
- It changes whenever any pinned content changes.
- It does not change for cosmetic edits: display name, licence text, or a mirror URL.
- `ModelsTests` pins the values above, so an accidental change to the formula (which would make
  every install look like a different revision) fails the build.

### Device requirements

`ModelManager.deviceRequirements()` and `ModelPack.checkRequirements(on:)` return a typed
`DeviceRequirementResult`: either `.supported`, or `.unsupported` with `DeviceRequirementIssue`
values, each carrying a short user-facing message.

**Memory is compared in decimal gigabytes (10⁹ bytes) of `ProcessInfo.physicalMemory`.** Here is why:
- An "8 GB" iPhone reports usable memory after firmware carve-outs, a little under 8 GiB (about
  7.4, 7.7 GiB, i.e. roughly 8.0, 8.3 × 10⁹ bytes).
- Read as GiB, the 7.5 threshold could reject the very iPhone 15 Pro the pins target.
- Read as 10⁹ bytes, every 8 GB-class iPhone passes, and 6 GB-class devices (≤ 6.44 × 10⁹) fail.

The iOS version is only checked on iOS. The Mac development path (unit tests, `agent-eval`) is exempt.

## Storage layout

```
<root>/                                  Application Support/Models (ModelStorageLayout.defaultRoot)
  .partial/<sha256>.part                 resumable downloads, content-addressed
  .trash/                                packs being deleted (emptied on launch)
  .intents.json                          which packs the user asked to install / paused
  <packID>/active.json                   activation record: the one revision runtimes may use
  <packID>/<revision>/<filename>         verified files, one directory per pinned content set
  <packID>/<revision>/.integrity.json    IntegrityRecord per file
```

- **Why Application Support and not Caches:** the system never purges it behind the app's back.
- **Backup:** the root and pack directories set `isExcludedFromBackup`, because every file can be
  downloaded again.
- **Data protection (iOS):** directories, partial files, imported files and records use
  `FileProtectionType.completeUntilFirstUserAuthentication`. Downloads and model loads keep working
  while the phone is locked.
- **Record files** (`active.json`, `.integrity.json`, `.intents.json`) are written atomically:
  a uniquely named temporary file in the same directory, then `fsync`, then `rename(2)`. A reader
  always sees either the old complete file or the new one. Temporary files left behind by a crash
  are removed at the next activation or launch.

## Download pipeline (`ModelDownloadManager.install`)

1. **Plan.** Files that already pass the integrity policy are skipped. Only missing bytes count:
   partials resume, and a complete file already in its revision directory is verified in place
   instead of downloaded.
2. **Free space.** The check requires the bytes still to download plus a 512 MB margin. iOS uses
   `volumeAvailableCapacityForImportantUsage`; otherwise, or when that is unavailable,
   `volumeAvailableCapacity`. Space reserved by other running installs is subtracted. A shortfall
   throws `insufficientStorage(required:available:)` before any request is made.
3. **Transfer.** The file is written to `.partial/<sha256>.part` through a `URLSessionDataDelegate`
   that streams each chunk to a `FileHandle` (constant memory; `fsync` every 64 MB and at the end).
   The request carries `Range: bytes=N-` from the partial's size and `Accept-Encoding: identity`.
   Redirects (Hugging Face → CDN) must stay HTTPS and keep those headers. Responses are handled as
   follows:

   | Response | Handling |
   |---|---|
   | `206` | Appended, after checking that `Content-Range` starts at N and its total equals the pinned size. |
   | `200` to a range request | The server ignored the range: truncate to zero and restart. |
   | `416` | Re-validate. A partial of exactly the pinned size is complete (the hash decides). Anything else restarts from zero, once; a second `416` fails with `rangeNotSatisfiable`. |
   | Mismatched `Content-Range` | Restart from zero, once. |
   | Announced size ≠ pin, or more bytes than pinned | `sizeMismatch`; the partial is deleted. |
   | Other `4xx` | Fail immediately. |

4. **Retries.** Timeouts, lost or absent connections, DNS failures, HTTP 408/429/5xx and truncated
   bodies are retried with exponential backoff: 1 s, doubling, capped at 30 s, ±20 % jitter. The
   limit is up to 5 retries without new bytes. An attempt that makes progress starts a new streak.
   A hard cap of 50 attempts applies per file.
5. **Verify and move.** Size check, then a streaming SHA-256. On a mismatch the partial is
   **deleted** and `checksumMismatch` is thrown; a retry starts from zero. On a match the file is
   moved atomically (`rename(2)`, same volume) into the revision directory, and its
   `IntegrityRecord` is written.
6. **Activate.** When every file of the pack is in place, `active.json` is rewritten atomically. It
   is the single commit point: until it names a revision, runtimes never see that revision.
   `activate` also re-checks that every file is present at its pinned size.

**Stopping and deleting:**
- **Pause and cancel** stop the transfer and **keep the partial**. The next install resumes it.
  Cancelling the calling task behaves like `cancel`.
- **Delete** detaches `<packID>/` with one `rename` into `.trash` (so the pack disappears
  atomically), removes it, and removes the pack's partials.

**Progress.** Each event carries phase (downloading or verifying), file and pack bytes, and
bytes per second. Events go to `progressUpdates()` (an `AsyncStream`) and to an optional per-call
handler.

## Integrity policy (`ModelIntegrity`)

1. **Install.** Every file gets a full streaming SHA-256 (CryptoKit, 4 MB chunks, cancellable,
   progress, constant memory) and a size check *before* it enters a revision directory. Nothing
   else can put a file there.
2. **Record.** A successful full verification records `{sha256, bytes, fileNumber (inode),
   modificationDate, verifiedAt, appVersion}`, where `appVersion` is the marketing version plus
   build. The file's size, inode and mtime are also compared before and after hashing, so a file
   that changes during the hash is rejected.
3. **Before each load.** `verifiedFileURL` runs `quickCheck`, a single `stat`. The file must exist
   with the pinned size, and its size, inode and mtime must be unchanged since the record, under
   the same pin.
4. **Full re-hash** runs when there is no record, the metadata changed, the app build changed, or
   the last full verification is older than **7 days**. The age is configurable
   (`ModelDownloadManager.Configuration.integrityMaximumAge`). A record dated more than a day in
   the future (the clock moved back) also counts as expired. The periodic re-hash is what catches
   silent corruption that leaves metadata untouched.
5. **Runtimes** only ever receive URLs from `ModelManager.verifiedFileURL(pack:file:)` or
   `verifiedFileURLs(for:)`. Those return only files of the manifest-pinned revision that passed
   steps 3, 4. A failure marks the pack `.corrupt`, and it must be re-downloaded.

## Updates, rollback, and never silently swapping model families

- **Pinned revisions only.** A new app version with new pins yields a new pack revision and a new
  directory. The previously active revision stays on disk and active until the new one is fully
  verified and activated. It is then kept as the rollback target (`active.json` → `previous`), and
  any older revision directories are removed.
- **`ModelDownloadManager.rollback(packID:)`** re-verifies the previous revision's files, then
  swaps `active` and `previous` atomically, so a rollback can itself be undone.
- **Never silently swap model families.** `ModelManager` treats a pack as installed only when
  `active.json` matches the manifest pack exactly: same pack id, same role, same revision, and the
  same file names, sizes and SHA-256 values. Cases that do not match:

  | Case | What happens |
  |---|---|
  | Same pack and role, other content | Never loaded. Reported as `ModelPackStatus.staleRevision`; state `notInstalled` until the pinned revision is installed. |
  | Another role (a family swap) | Never used; logged as `familyMismatch`. |
  | Unknown pack directories or files | Ignored: never activated or loaded, and never deleted. |
  | Pinned revision is the rollback target | Re-activated automatically after verification (for example, when an older build was reinstalled). Not silent: it is the exact pinned content of the same family, and it is logged. |

## Launch reconciliation (`ModelManager.reconcileOnLaunch`)

1. Prepare the store: backup exclusion and protection, empty `.trash`, delete partials whose
   SHA-256 no manifest file references, and delete temporary files from interrupted writes.
2. For each manifest pack:
   - If the active revision matches the pins, quick-check it. If the policy requires, re-hash it
     fully (state `verifying`). The result is `installed`, or `corrupt` when files are missing or
     damaged.
   - Otherwise, apply the family rules above.
   - Count partial downloads (`downloadedBytes`).
3. Re-queue installs that were running when the app stopped, using the persisted intents. Paused
   packs stay paused.

## Offline import (no network)

Models can be provisioned from local files. This covers a developer sideload, Finder file sharing,
or enterprise provisioning.

```swift
// ModelManager (manifest-aware)
static var defaultImportDirectory: URL   // Documents/ModelImport/
func importLocalFile(_ sourceURL: URL, pack packID: String, file filename: String,
                     removeSource: Bool = true,
                     progress: ModelDownloadManager.ProgressHandler? = nil) async throws -> ActivationRecord?
func importPendingFiles(from directory: URL = ModelManager.defaultImportDirectory,
                        removeSources: Bool = true) async -> [String: Result<ModelImportOutcome, any Error>]

// ModelDownloadManager (takes the pack's pins; it does not know the manifest)
func importLocalFile(_ sourceURL: URL, pack: ModelPack, file filename: String,
                     removeSource: Bool = true, progress handler: ProgressHandler? = nil) async throws -> ActivationRecord?
```

**What an import accepts:**
- The file must be a pinned file of that pack, and a regular file (not a symbolic link).
- Its size must match, and a full streaming SHA-256 must match the manifest.

**What happens to the file:**
- It then takes the download's path: `.partial` → atomic rename into the revision directory →
  integrity record.
- With `removeSource` (the default) on the same volume, the file is **moved, never copied**, so a
  2.8 GB model is not duplicated. It is hashed where it lies, then renamed; rename preserves its
  inode, size and mtime, so the record stays valid.
- Otherwise (`removeSource: false`, or another volume) it is copied (an APFS clone when possible)
  and the copy is verified.
- On any mismatch the **source is left untouched** and a typed error is thrown: `unknownFile`,
  `invalidImportSource`, `sizeMismatch` or `checksumMismatch`.
- When the last missing file of a pack arrives, the pack is activated exactly like an install and
  the `ActivationRecord` is returned. Until then the result is `nil`.

**Directory scans.** `importPendingFiles` imports every file whose name is a manifest filename.
Anything else (other files, hidden files, folders) is ignored: never imported, activated or
deleted. Rejected files stay where they are, and their errors are reported per filename.

**Getting files onto a device:**
- **Developer sideload.** Use a development-signed build, then call
  `importPendingFiles()` at launch after `reconcileOnLaunch()`:

  ```
  xcrun devicectl device copy to --device <UDID> \
    --domain-type appDataContainer --domain-identifier com.mouhamadmamane.voiceagent \
    --source ModelCache/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf \
    --destination Documents/ModelImport/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf
  ```

- **Finder file sharing.** This requires `UIFileSharingEnabled` = YES and
  `LSSupportsOpeningDocumentsInPlace` in the app's Info.plist. `App/project.yml` currently sets
  file sharing to NO.
- **Enterprise provisioning.** Place the files in the app's `Documents/ModelImport/` by any
  mechanism, then call `importPendingFiles()`.

## UI binding

`ModelManager` is an actor. Snapshots come from
`statusUpdates(bufferingPolicy: = .bufferingNewest(1))`, an `AsyncStream<[ModelPackStatus]>`. It
yields the current snapshot at once, then one snapshot per change. A main-actor `@Observable`
view model assigns each snapshot to a property. Pass `.unbounded` to observe every transition
(diagnostics, tests).

**`ModelPackStatus`** carries `displayName`, `role`, `license`, `totalBytes`, `downloadedBytes`,
`state`, `fractionCompleted`, `staleRevision` and `errorMessage` (one short sentence).

**`ModelPackState`** has these cases:
- `notInstalled`
- `queued`
- `downloading(progress)`
- `paused(downloadedBytes:)`
- `verifying(progress)`
- `installed(revision:)`
- `failed(ModelFailureReason)`
- `corrupt`

**Actions:**
- `install`, `installAll`, `startInstall`, `pause`, `resume`, `cancel`, `delete`, `redownload`
- `storageUsage()`: bytes per pack, split into active, inactive and partial, plus free space
- `deviceRequirements()`

Installs run one at a time, in request order.

## Privacy

The Models module logs only
`PrivacySafeLogger.log(.download(model:status:bytes:))`, which carries three things:
- `model`: the pack's role label (`asr`, `llm`, `tts`).
- `status`: a closed status vocabulary (`started`, `resumed`, `retrying`, `verified`,
  `checksumMismatch`, `activated`, `rolledBack`, `imported`, …).
- `bytes`: a byte count.

No URLs, file names, paths or pack ids are logged. A unit test enforces this.

## Commands

```sh
Scripts/download_models.sh              # dev Macs: fetch every pinned file into ModelCache/ (idempotent, resumable)
Scripts/download_models.sh --pack kokoro-82m
Scripts/download_models.sh --list
Scripts/verify_models.sh                # full size + SHA-256 check of ModelCache/ (exit 1 on any mismatch)
MODEL_CACHE_DIR=/path Scripts/verify_models.sh
swift build --target Models
swift test --filter ModelsTests
```

**`download_models.sh`** reads the JSON with python3 (standard library only):
- It downloads with `curl -L --fail --retry 5 -C -` into `ModelCache/.partial/`, verifies size and
  `shasum -a 256`, then moves the file into place.
- Files already verified are skipped. `ModelCache/.verified/<file>` stamps the SHA-256, size, mtime
  and inode.
- A file present but not yet verified is hashed once, not downloaded again.
- A truncated file is resumed; a corrupt one is downloaded again.

**Updating a pin** takes four steps:
1. Edit `ModelManifest.v1` **and** `Scripts/model_manifest.json`.
2. Update the pack-revision values in `ModelManifestTests.packRevisionsAreStableAndContentDerived`
   and in this document.
3. Run `Scripts/download_models.sh --pack <id>` and `Scripts/verify_models.sh`.
4. Run the tests.
