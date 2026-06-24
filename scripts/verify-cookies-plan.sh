#!/bin/bash
set -euo pipefail
SCRATCH=${SCRATCH:-/var/folders/38/dj7s1z852kqbpvzm3g5qmq2r0000gn/T/grok-goal-9944274945b3/implementer}
mkdir -p "$SCRATCH"

echo "=== 1. Grep five source files for key cookie features (including scope guarantee) ===" | tee "$SCRATCH/verify-grep.txt"
grep -n 'cookiesFilePath\|CookieArgs\.make\|beginAccessingCookiesFile\|setCookiesFile\|clearCookiesFile\|cookiesFileBookmarkData\|activeCookieScopes\|endCookiesScope' \
  Sources/XDownloader/ViewModels/DownloadManager.swift \
  Sources/XDownloader/Views/SettingsView.swift \
  Sources/XDownloader/Services/YtDlpService.swift \
  Sources/XDownloader/Services/GalleryDlService.swift \
  Sources/XDownloader/Models/DownloadEnums.swift | tee -a "$SCRATCH/verify-grep.txt" || true

echo "=== 2. swift build -> build.log ===" 
swift build 2>&1 | tee "$SCRATCH/build.log"
echo "EXIT=$?" >> "$SCRATCH/build.log"

echo "=== binary strings for shipped code (proof of compiled symbols) ===" >> "$SCRATCH/cookie-args-example.txt"
strings .build/debug/XDownloader 2>/dev/null | grep -E 'beginAccessingCookiesFile|activeCookieScopes|endCookiesScope|cookiesFileBookmarkData|_bookmarkForDeinit' | head -5 >> "$SCRATCH/cookie-args-example.txt" || echo 'strings not found or binary not present' >> "$SCRATCH/cookie-args-example.txt"

echo "=== 3. arg simulation using REAL source code -> cookie-args-example.txt ==="
# Extract the exact shipped implementation from source files (exercises real CookieArgs.make)
sed -n '/^enum CookieBrowser:/,/^}/p' Sources/XDownloader/Models/DownloadEnums.swift > /tmp/real_cookie_enums.swift
sed -n '/^enum CookieArgs {/,/^}/p' Sources/XDownloader/Models/DownloadEnums.swift >> /tmp/real_cookie_enums.swift
cat > /tmp/real-verify-args.swift << 'REALTEST'
$(cat /tmp/real_cookie_enums.swift)
let cases: [(String, CookieBrowser, String?)] = [
  ("file precedence", .safari, "/tmp/cookies.txt"),
  ("browser fallback (no regression)", .safari, nil),
]
for (d, b, f) in cases { 
  print("\(d): \(CookieArgs.make(browser: b, file: f))") 
}
REALTEST
# Note: the heredoc above substitutes the extracted real source at runtime of script
# To make it actual compile of real, we use cat with the extracted
cat > /tmp/real-verify-args.swift << EOF
$(cat /tmp/real_cookie_enums.swift)

let cases: [(String, CookieBrowser, String?)] = [
  ("file precedence", .safari, "/tmp/cookies.txt"),
  ("browser fallback (no regression)", .safari, nil),
]
for (d, b, f) in cases { 
  print("\(d): \(CookieArgs.make(browser: b, file: f))") 
}
EOF
swift /tmp/real-verify-args.swift | tee "$SCRATCH/cookie-args-example.txt"
echo "Note: above executed the exact CookieArgs.make body extracted from Sources/XDownloader/Models/DownloadEnums.swift" >> "$SCRATCH/cookie-args-example.txt"

echo "=== 4. Settings guidance extract -> settings-cookies-verif.txt ==="
sed -n '60,85p' Sources/XDownloader/Views/SettingsView.swift | tee "$SCRATCH/settings-cookies-verif.txt"

echo "=== verify script completed successfully ==="
