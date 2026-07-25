#!/usr/bin/env bash
# Developer ID code signing + notarization for XDownloader releases.
#
# Signs XDownloader.app with our Developer ID (hardened runtime + timestamp +
# entitlements), submits it to Apple's notary service, and staples the ticket —
# so users are NOT Gatekeeper-blocked ("Apple could not verify…") and the app
# opens with a normal double-click.
#
# Adapted from mynah-app/scripts/sign-notarize.sh, with two XDownloader-specific
# differences:
#   1. XDownloader embeds Sparkle.framework, whose nested code (XPC services,
#      Autoupdate, Updater.app, the framework binary) must be re-signed with OUR
#      Developer ID inside-out BEFORE the outer app — so everything lands under
#      team 5KGJ4RW2K5 and library validation passes without disabling it.
#   2. Signing/notarization run in CI, so the credentials come from GitHub
#      Secrets: the cert is imported into a temporary keychain by the workflow,
#      and notarytool authenticates with an App Store Connect API key (--key /
#      --key-id / --issuer) instead of a stored --keychain-profile. A local
#      keychain-profile fallback is kept for dev testing.
#
# Subcommands:
#   scripts/sign-notarize.sh preflight            # detect identity + notary creds
#   scripts/sign-notarize.sh sign     build/XDownloader.app   # sign only
#   scripts/sign-notarize.sh notarize build/XDownloader.app   # notarize + staple
#   scripts/sign-notarize.sh verify   build/XDownloader.app   # audit a bundle
#
# Environment (all optional unless noted):
#   CODESIGN_IDENTITY            Signing identity. Default: the first
#                               "Developer ID Application: …" in the keychain.
#                               Set to "-" to force an ad-hoc signature (skips
#                               Developer ID entirely; build.sh uses this path).
#   Notary credentials — pick ONE of the two schemes:
#     (a) App Store Connect API key (CI / preferred):
#         APP_STORE_CONNECT_KEY_ID       the key's Key ID
#         APP_STORE_CONNECT_ISSUER_ID    the issuer UUID
#         APP_STORE_CONNECT_KEY_PATH     path to the .p8 on disk, OR
#         APP_STORE_CONNECT_KEY_BASE64   base64 of the .p8 (decoded to a temp
#                                        file, chmod 600, removed on exit)
#     (b) Stored keychain profile (local dev fallback):
#         NOTARY_KEYCHAIN_PROFILE        name from `notarytool store-credentials`
#
# One-time local setup for the keychain-profile fallback:
#   xcrun notarytool store-credentials "xdownloader-notary" \
#     --key /path/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
#   NOTARY_KEYCHAIN_PROFILE=xdownloader-notary scripts/sign-notarize.sh notarize build/XDownloader.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="${XDOWNLOADER_ENTITLEMENTS:-$ROOT/Resources/XDownloader.entitlements}"
BUNDLE_ID="com.gin.xdownloader"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

# --- identity -----------------------------------------------------------------

detect_identity() {
  # `|| true`: a no-match grep under `set -o pipefail` must not abort the script.
  { security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"'; } || true
}

# Resolve the identity to sign with: honour CODESIGN_IDENTITY when set (including
# "-" for ad-hoc), otherwise auto-detect a Developer ID Application cert.
resolve_identity() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    printf '%s' "$CODESIGN_IDENTITY"
  else
    detect_identity
  fi
}

# --- Sparkle inside-out signing -----------------------------------------------

# Re-sign Sparkle.framework's nested code with OUR Developer ID, hardened runtime
# + secure timestamp, inside-out (deepest first, framework last). This follows
# Sparkle's official "signing outside of Xcode" recipe. Signing each nested
# bundle also signs its main executable; we never pass --deep. Preserving the
# Downloader.xpc entitlements matches Sparkle's recipe (it may carry
# network.client in some builds); the other components are signed plainly, which
# drops Autoupdate's com.apple.application-identifier entitlement — that is only
# meaningful for sandboxed / App Store builds and would mismatch our team prefix.
sign_sparkle() {
  local fw="$1" id="$2"
  local v="$fw/Versions/B"
  [ -d "$fw" ] || { warn "no Sparkle.framework at: $fw"; exit 1; }
  log "re-signing Sparkle nested code with: $id"

  if [ -d "$v/XPCServices/Downloader.xpc" ]; then
    codesign --force --options runtime --timestamp \
      --preserve-metadata=entitlements \
      --sign "$id" "$v/XPCServices/Downloader.xpc"
  fi
  if [ -d "$v/XPCServices/Installer.xpc" ]; then
    codesign --force --options runtime --timestamp \
      --sign "$id" "$v/XPCServices/Installer.xpc"
  fi
  if [ -f "$v/Autoupdate" ]; then
    codesign --force --options runtime --timestamp \
      --sign "$id" "$v/Autoupdate"
  fi
  if [ -d "$v/Updater.app" ]; then
    codesign --force --options runtime --timestamp \
      --sign "$id" "$v/Updater.app"
  fi
  # The framework binary / bundle LAST, so it seals the freshly-signed nested code.
  codesign --force --options runtime --timestamp --sign "$id" "$fw"
}

# --- sign ---------------------------------------------------------------------

sign_app() {
  local app="$1"
  [ -d "$app" ] || { warn "no such app: $app"; exit 1; }
  local id; id="$(resolve_identity)"

  if [ "$id" = "-" ]; then
    # Ad-hoc path (no Developer ID available / explicitly requested). Matches the
    # historical build.sh fallback: sign just the main executable, ad-hoc. Keeps
    # build.yml green with no secrets.
    log "ad-hoc signing (no Developer ID): $app"
    codesign --force -s - "$app/Contents/MacOS/XDownloader"
    return 0
  fi
  [ -n "$id" ] || { warn "no Developer ID Application cert — run 'preflight'"; exit 3; }
  [ -f "$ENTITLEMENTS" ] || { warn "missing entitlements: $ENTITLEMENTS"; exit 1; }

  # 1) Nested Sparkle first (inside-out).
  local fw="$app/Contents/Frameworks/Sparkle.framework"
  sign_sparkle "$fw" "$id"

  # 2) The main app LAST, with hardened runtime + timestamp + entitlements.
  # Signing the bundle signs Contents/MacOS/XDownloader and seals resources +
  # the embedded (already-signed) framework by reference. No --deep, so the
  # framework signatures above are preserved, not overwritten.
  log "signing main app with: $id"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" \
    --sign "$id" "$app"

  codesign --verify --strict --verbose=2 "$app"
  log "signed (valid on disk). Notarize next: sign-notarize.sh notarize $app"
}

# --- notary credential plumbing ----------------------------------------------

# Populate the NOTARY_ARGS array with the right notarytool authentication flags.
# Prefers the App Store Connect API key; falls back to a stored keychain profile.
# A .p8 supplied as base64 is decoded to a temp file removed on script exit.
NOTARY_ARGS=()
_TMP_KEY_DIR=""
cleanup_tmp_key() { [ -n "$_TMP_KEY_DIR" ] && rm -rf "$_TMP_KEY_DIR" || true; }
trap cleanup_tmp_key EXIT

resolve_notary_creds() {
  local key_path="${APP_STORE_CONNECT_KEY_PATH:-}"
  if [ -z "$key_path" ] && [ -n "${APP_STORE_CONNECT_KEY_BASE64:-}" ]; then
    # `mktemp -d` gives a private 0700 dir; the key lives inside it with a real
    # ".p8" name (notarytool wants that extension). Write the file BEFORE chmod —
    # chmod on a not-yet-created path fails under `set -e`, which was the bug
    # that failed the first v1.8.0 release. The whole dir is removed on exit.
    _TMP_KEY_DIR="$(mktemp -d -t ascp8)"
    key_path="$_TMP_KEY_DIR/AuthKey.p8"
    printf '%s' "$APP_STORE_CONNECT_KEY_BASE64" | base64 --decode > "$key_path"
    chmod 600 "$key_path"
  fi

  if [ -n "$key_path" ] \
     && [ -n "${APP_STORE_CONNECT_KEY_ID:-}" ] \
     && [ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]; then
    [ -f "$key_path" ] || { warn "API key file not found: $key_path"; exit 1; }
    NOTARY_ARGS=(--key "$key_path" \
                 --key-id "$APP_STORE_CONNECT_KEY_ID" \
                 --issuer "$APP_STORE_CONNECT_ISSUER_ID")
    log "notary auth: App Store Connect API key ($APP_STORE_CONNECT_KEY_ID)"
  elif [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    log "notary auth: keychain profile '$NOTARY_KEYCHAIN_PROFILE'"
  else
    warn "no notary credentials — set APP_STORE_CONNECT_KEY_ID/ISSUER_ID + KEY_PATH|KEY_BASE64,"
    warn "or NOTARY_KEYCHAIN_PROFILE for the local fallback."
    exit 3
  fi
}

# --- notarize -----------------------------------------------------------------

notarize_app() {
  local app="$1"
  [ -d "$app" ] || { warn "no such app: $app"; exit 1; }
  resolve_notary_creds

  # notarytool only accepts zip/pkg/dmg — a bare .app must be submitted as a
  # ditto zip. --keepParent keeps the .app as the top entry; the ticket is then
  # stapled to the .app bundle itself (NOT the zip).
  local nzip="${app%.app}-notarize.zip"
  rm -f "$nzip"
  log "zipping for notary submission: $nzip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$nzip"

  log "submitting to notary (this can take a few minutes)…"
  xcrun notarytool submit "$nzip" "${NOTARY_ARGS[@]}" --wait
  rm -f "$nzip"

  log "stapling ticket to $app"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  log "notarized + stapled: $app"
}

# --- verify -------------------------------------------------------------------

verify_app() {
  local app="$1"
  [ -e "$app" ] || { warn "no such target: $app"; exit 1; }
  local rc=0

  log "codesign --verify --strict --deep --verbose=2"
  codesign --verify --strict --deep --verbose=2 "$app" || { warn "codesign verify FAILED"; rc=1; }

  log "gatekeeper assessment (spctl -a -t exec -vv)"
  # Expected to REJECT as 'unnotarized' until the notary ticket is stapled; that
  # does not mean the on-disk signature is bad.
  spctl -a -t exec -vv "$app" || warn "spctl not accepted (expected until notarized + stapled)"

  log "stapler validate"
  xcrun stapler validate "$app" 2>&1 || warn "no stapled ticket (expected until notarized)"

  return $rc
}

# --- preflight ----------------------------------------------------------------

preflight() {
  local ok=1
  local id; id="$(resolve_identity)"
  if [ -n "$id" ] && [ "$id" != "-" ]; then
    log "signing identity: $id"
  else
    warn "no 'Developer ID Application' cert (set CODESIGN_IDENTITY or import one)"; ok=0
  fi

  if [ -n "${APP_STORE_CONNECT_KEY_ID:-}" ] \
     && [ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ] \
     && { [ -n "${APP_STORE_CONNECT_KEY_PATH:-}" ] || [ -n "${APP_STORE_CONNECT_KEY_BASE64:-}" ]; }; then
    log "notary creds: App Store Connect API key ($APP_STORE_CONNECT_KEY_ID)"
  elif [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    log "notary creds: keychain profile '$NOTARY_KEYCHAIN_PROFILE'"
  else
    warn "no notary credentials (API key env or NOTARY_KEYCHAIN_PROFILE)"; ok=0
  fi

  [ -f "$ENTITLEMENTS" ] && log "entitlements: $ENTITLEMENTS" || { warn "missing entitlements: $ENTITLEMENTS"; ok=0; }

  if [ "$ok" = 1 ]; then
    log "READY to sign + notarize."
  else
    warn "NOT fully ready — see the notes at the top of this script."
    return 3
  fi
}

case "${1:-preflight}" in
  preflight) preflight ;;
  sign)      sign_app     "${2:?usage: sign-notarize.sh sign <path.app>}" ;;
  notarize)  notarize_app "${2:?usage: sign-notarize.sh notarize <path.app>}" ;;
  verify)    verify_app   "${2:?usage: sign-notarize.sh verify <path.app>}" ;;
  *) echo "usage: $0 {preflight|sign <app>|notarize <app>|verify <app>}" >&2; exit 64 ;;
esac
