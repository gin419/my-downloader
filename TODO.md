# XDownloader — TODO / 待辦清單

> Created 2026-06-29 from the repo audit (`docs/repo-audit-2026-06-29.md`).
> This captures work we deliberately deferred, and the *intent* behind things
> we deleted during cleanup — so the problem isn't lost even though the artifact is gone.
>
> 本清單來自 2026-06-29 的代碼庫審計。記錄了我們刻意延後的工作，以及清理時刪掉的東西**原本要解決什麼問題**——
> 這樣即使檔案被刪了，問題本身也不會遺失。

---

## A. Deferred work / 延後的工作

### A1. Add a test target + seed unit tests  （測試）— P1
- **Problem / 問題:** ~3,500 lines of Swift, **zero tests** (`Package.swift` has no `.testTarget`). The most regression-prone logic is pure and trivially testable, and is exactly what we keep refactoring.
- **Do:** Add `.testTarget(name: "XDownloaderTests", …)` + `Tests/XDownloaderTests/`. Seed tests for the already-`internal` pure statics first (no refactor needed):
  - `CookieArgs.make(browser:file:)` — assert file path overrides browser; `.none` → `[]`.
  - `YtDlpService.buildArguments(…)` — snapshot the 4 format-selector branches + subtitle gate (carries a known yt-dlp bug workaround worth pinning).
  - Then widen `private` → `internal static` to cover `stripTrackingParams` (DownloadManager) and `FxTwitterService.sanitize`.
  - Extract a pure `cleanTitleStem(_:isImage:)` helper so the parseLine regex strips become testable.
- Then add a `swift test` step to `.github/workflows/build.yml` (CI currently only compiles, never tests).

### A2. Cookie-access state cleanup / refactor  （cookie 狀態收斂）— P3
- **Problem / 問題:** The same cookies file is tracked by 5 overlapping state vars; three methods call `stopAccessing` on freshly-resolved URLs that were never started (unbalanced no-op stops); `loadSettings` resolves the bookmark twice.
- **Do:** Collapse the 5 state vars to ~2 (keep `cookiesFileBookmarkData` + the scope); delete the unbalanced no-op stops (per-download `withScope` already guarantees paired start/stop); remove the redundant second resolve. Best done by extracting a small `CookieAccessManager` type (see A3).
- *Note:* the **one-line bug** in this area (stale `grantedCookiesURL` in `setCookiesFile`'s catch branch) was already fixed during this cleanup; this entry is only the larger structural tidy.

### A3. Break up the `DownloadManager` god object  （拆解 god object）— P3
- **Problem / 問題:** `DownloadManager.swift` is ~716 lines mixing process mgmt, cookie/bookmark lifecycle, queue persistence, UI state, and fallback orchestration.
- **Do:** Extract `CookieAccessManager` (cookie/bookmark lifecycle) and `QueueStore` (JSON queue persistence, mirroring `HistoryStore`). **Keep** the download/fallback orchestration in the manager — that is its legitimate core.

### A4. De-duplicate media-extension lists  （媒體副檔名清單去重）— P3
- **Problem / 問題:** Image/video/audio extension literals are duplicated across ~6 sites with **divergent contents** — a real latent bug. e.g. `YtDlpService.swift:111` is missing `gif`/`avif`; `GalleryDlService` `knownMedia` omits `mkv`/`m4v` that its own `isVideo` then tests (a dead branch).
- **Do:** Add a single `enum MediaExtensions { image/video/audio/all }` and replace the 6 literal lists. Also add `DownloadItem.recomputeMediaCategory()` for the 4 copy-pasted derivations. Inline the now-redundant `GalleryDlService.cookieArgs` pass-through wrapper.

### A5. Close the single-source-version TODO  （版本號單一來源）— P3  *(pre-existing TODO)*
- **Problem / 問題:** `build.sh` stamps the version from `git describe` only into the **built** bundle; `Resources/Info.plist` still carries a hand-edited version that any `swift run` path uses and that must be bumped by hand each release.
- **Do:** Replace `Info.plist` `CFBundleVersion`/`CFBundleShortVersionString` with a sentinel (`0.0.0`); make `build.sh` **hard-fail** when `git describe` finds no tag, so the tag is the only source of truth.

### A6. Add a CHANGELOG  （變更日誌）— P2
- **Problem / 問題:** 9 release tags (v1.0 … v1.4.2) but no `CHANGELOG.md`; history lives only in commit subjects.
- **Do:** Add `CHANGELOG.md` (Keep a Changelog format), back-filled from the tag-aligned commit subjects. Append one entry per release at tag time going forward.

### A7. CI / release hardening  （CI 強化）— P3
- **Problem / 問題:** CI never exercises `build.sh`/the `.app` bundle until a tag is pushed; no lint/format step; `release.yml` example uses a 2-segment tag (`v1.1`), contradicting the 3-segment SemVer convention.
- **Do:** Add a non-publishing bundle-smoke step (`fetch-depth: 0`, run `./build.sh`, assert binary + CFBundle keys). Add `swift format lint --strict --recursive Sources`. Update `release.yml` to a 3-segment example / tighten the tag glob to `v[0-9]+.[0-9]+.[0-9]+`.

---

## B. Intent behind deleted content / 已刪除內容背後的問題

> These artifacts were removed during cleanup. The *problem each one was solving* is recorded
> here so we can address it properly later.
> 以下檔案在清理時被刪除。它們**原本要解決的問題**記在這裡，方便日後正確地重做。

### B1. `scripts/verify-cookies-plan.sh` (deleted)
- **What it was solving / 原本要解決:** an end-to-end check that the cookie security-scope grant lifecycle is correct — resolve bookmark → `begin(granted)` → child process can actually read the cookies file → `end` (balanced start/stop).
- **Why deleted:** machine-generated throwaway — hardcoded a foreign machine's temp path (`/var/folders/.../grok-goal-…`), duplicated section headers, two "completed" markers, referenced by nothing.
- **Replacement TODO:** re-create this verification *properly* — fold it into the test target (**A1**) as a real test, or a clean idempotent CI script using repo-relative paths + `$(mktemp -d)`. **The need is real; only the script was junk.**

### B2. `make_icon.py` + `make_icon.swift` (left in place — your local dev files)
- **What they solve / 用途:** regenerate the app icon (the "Void Descent" design).
- **Status:** both are gitignored, untracked, local-only files (the shipped icon already lives in `Resources/AppIcon.icns`), so they don't pollute the repo for anyone cloning — I left them rather than delete your own files.
- **Optional / 可選:** they're redundant; if you want to keep one, prefer `make_icon.swift` (no Python/Pillow dependency) and delete `make_icon.py`. Your call — `rm` it whenever.

### B3. Branches `fix/ytdlp-format-fallback` & `docs/roadmap-cleanup` (deleted)
- **Status:** **nothing pending.** Verified their payloads already shipped in `main` (the `bv*+ba/b` format catch-all landed via PR #4; the roadmap line removals are already reflected). Both had `upstream: gone`. No unsolved problem.

### B4. Branch `fix/cookies-scope-grant` / commit `f1f3576` (abandoned)
- **Status:** **nothing pending.** Verified by per-file diff that it held nothing unique vs the canonical working-tree version — only older comments and a worse error string. Zero loss.

---

## C. Audit coverage gap / 審計覆蓋缺口

- During the audit, **2 verification batches failed** (StructuredOutput retry cap) in the **file-hygiene** and **code-smells** dimensions — a few specific findings in those two areas were dropped from the final 41.
- The dimensions are still well-covered (see P2/P3 above and `docs/repo-audit-2026-06-29.md`), but if we do a deep cleanup pass later, **re-run a focused audit on file-hygiene + code-smells** to catch anything missed.
