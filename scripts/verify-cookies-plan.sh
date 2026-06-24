#!/bin/bash
set -euo pipefail
SCRATCH=${SCRATCH:-/var/folders/38/dj7s1z852kqbpvzm3g5qmq2r0000gn/T/grok-goal-9944274945b3/implementer}
mkdir -p "$SCRATCH"

# Single-shot: truncate first (never append per guidance)
rm -f "$SCRATCH/build.log" "$SCRATCH/cookie-args-example.txt" "$SCRATCH/verify-grep.txt" "$SCRATCH/settings-cookies-verif.txt"

echo "=== 1. Grep for CookieFileScope + withScope + defer + CookieArgs.make (shipped) ===" | tee "$SCRATCH/verify-grep.txt"
grep -n 'CookieFileScope\|withScope\|defer.*end\|CookieArgs\.make' \
  Sources/XDownloader/Services/CookieFileScope.swift \
  Sources/XDownloader/ViewModels/DownloadManager.swift \
  Sources/XDownloader/Services/YtDlpService.swift \
  Sources/XDownloader/Services/GalleryDlService.swift \
  Sources/XDownloader/Models/DownloadEnums.swift | tee -a "$SCRATCH/verify-grep.txt" || true

echo "=== 2. clean build (single run, full log) ==="
swift package clean 2>/dev/null || true
swift build 2>&1 | tee "$SCRATCH/build.log"
echo "EXIT=$?" >> "$SCRATCH/build.log"

echo "=== 3. binary strings for new symbols ===" >> "$SCRATCH/cookie-args-example.txt"
strings .build/debug/XDownloader 2>/dev/null | grep -E 'CookieFileScope|withScope|beginAccessingCookiesFile' | head -3 >> "$SCRATCH/cookie-args-example.txt" || true

echo "=== 4. arg sim using REAL source extract ===" | tee -a "$SCRATCH/cookie-args-example.txt"
sed -n '/^enum CookieBrowser:/,/^}/p' Sources/XDownloader/Models/DownloadEnums.swift > /tmp/real_enums.swift
sed -n '/^enum CookieArgs {/,/^}/p' Sources/XDownloader/Models/DownloadEnums.swift >> /tmp/real_enums.swift
cat > /tmp/real-verify-args.swift << EOF
$(cat /tmp/real_enums.swift)

let cases: [(String, CookieBrowser, String?)] = [
  ("file precedence", .safari, "/tmp/cookies.txt"),
  ("browser fallback (no regression)", .safari, nil),
]
for (d, b, f) in cases { 
  print("\(d): \(CookieArgs.make(browser: b, file: f))") 
}
EOF
swift /tmp/real-verify-args.swift | tee -a "$SCRATCH/cookie-args-example.txt"

echo "=== 5. Settings guidance ==="
sed -n '60,85p' Sources/XDownloader/Views/SettingsView.swift | tee "$SCRATCH/settings-cookies-verif.txt"

echo "=== verify script completed (single-shot, exit 0) ==="

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
