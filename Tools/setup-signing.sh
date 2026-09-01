#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Creates a stable, self-signed code-signing identity named "Vorssaint Utils
# Signing" in a dedicated keychain. build.sh uses it automatically, giving every
# build the same code signature — so macOS keeps granted permissions
# (Accessibility, Screen Recording) across updates instead of re-prompting.
#
# This identity name keeps its original "Vorssaint Utils Signing" on purpose: it
# is the lookup key build.sh matches, and the released app's designated
# requirement is pinned to this exact certificate. Renaming it would change that
# requirement and drop every user's granted permissions. The name lives only in
# the keychain and codesign output, never in anything the app shows.
#
# Free, offline, and idempotent (re-running is a no-op once a usable identity exists).
# It does NOT replace Apple notarization: downloaded builds still show Gatekeeper's
# "unverified developer" prompt on first launch. It only stabilizes the identity.
#
# Maintainers: official releases use the protected release-signing environment.
# Run this only to get the same permission-preserving behavior for local builds.
set -euo pipefail

IDENTITY="Vorssaint Utils Signing"
KC="$HOME/Library/Keychains/vorssaint-signing.keychain-db"
KCPASS="vorssaint-signing"

# What makes this idempotent rather than merely quiet: whether codesign can sign
# with the identity, not whether one is listed. The unvalidated listing includes
# certificates that cannot sign, so a stale one reports "already installed" and
# the repair build.sh just asked for never happens. `find-identity -v` is not
# the fix — it asks whether the certificate is trusted, which a self-signed one
# never is, so it would delete and recreate a perfectly good identity on every
# single build. codesign is the only thing that answers the real question.
identity_can_sign() {
    security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY" || return 1
    # Unlock first: the keychain is locked again after every login, and a locked
    # one makes codesign raise a GUI password prompt instead of answering.
    if [[ -f "$KC" ]] && ! security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null; then
        return 1
    fi
    # Not `status`: zsh keeps that as a second name for $?, and it is read-only,
    # so declaring it local aborts the script on the first call.
    local probe signed=1
    probe="$(mktemp -d)"
    cp /bin/echo "$probe/probe"
    codesign --force --sign "$IDENTITY" "$probe/probe" >/dev/null 2>&1 && signed=0
    rm -rf "$probe"
    return $signed
}

if identity_can_sign; then
    echo "✓ Signing identity already installed."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -nodes \
    -subj "/CN=$IDENTITY/O=Vorssaint" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
# The PBE and MAC algorithms are named explicitly: the stock /usr/bin/openssl
# is LibreSSL, which rejects OpenSSL 3's -legacy flag, while OpenSSL 3's
# defaults (AES-256, PBKDF2) are newer than what security(1) imports reliably.
# These three are accepted by both and produce the same portable file.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:"$KCPASS" -name "$IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 || {
    echo "✗ openssl pkcs12 could not export the identity." >&2
    exit 1
}

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$KCPASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$KCPASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
EXISTING=$(security list-keychains -d user | sed 's/"//g' | xargs)
security list-keychains -d user -s "$KC" ${=EXISTING}

# Import succeeding is not evidence codesign can see it: read it back the same
# way build.sh looks it up, so a broken search list fails here and not as a
# silent ad-hoc fallback three builds later.
identity_can_sign || {
    echo "✗ Identity imported but codesign cannot sign with it; keychain search list may be off." >&2
    exit 1
}
echo "✓ Created signing identity '$IDENTITY'. Future ./build.sh runs use it automatically."
