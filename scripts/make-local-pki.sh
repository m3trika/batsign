#!/bin/sh
# Generates the private PKI for BatSign's "Fully Local" HTTPS installer.
#
# Why: the installer used to download the public backloop.dev certificate pack.
# Its private key is public and it is valid for 10 years, which iOS rejects for
# TLS servers (825-day limit), so installs got stuck on "Ready" / "Installing".
# This script replaces it with a private CA that only you control.
#
#   CA   : EC P-256, name-constrained to $HOST (it cannot vouch for any other
#          site), kept OUTSIDE the repo and OUTSIDE the IPA.
#   Leaf : EC P-256, SAN = $HOST, serverAuth, CA:FALSE, 365 days by default.
#
# $HOST is a name under backloop.dev, whose public DNS answers 127.0.0.1 for any
# subdomain, so iOS ends up talking to the server running inside BatSign.
# Only the NAME is used; nothing is downloaded from backloop.dev.
#
# Output (default deps/, bundled into the app by the Makefile):
#   server.crt                 leaf certificate (PEM)
#   server.pem                 leaf private key (PEM). Ships inside the app; it
#                              can only impersonate $HOST to devices that trust
#                              YOUR CA, so do not share your IPA or CA profile.
#   commonName.txt             $HOST
#   BatSignLocalCA.crt / .cer  public CA certificate (PEM / DER)
#   BatSignLocalCA.mobileconfig  profile that installs the CA (public data only)
#
# Re-running with an existing CA is a RENEWAL: a new leaf under the same CA, so
# the phone keeps trusting it. Never commit, bundle or share ca.key.
#
# Usage: scripts/make-local-pki.sh [--out DIR] [--pki-dir DIR] [--leaf-days N] [--ephemeral]
#   --ephemeral  throw-away CA whose key is destroyed after issuing the leaf.
#   BATSIGN_CA_KEY / BATSIGN_CA_CERT  paths of an existing CA (e.g. from CI secrets).
#   BATSIGN_LOCAL_HOST                override the hostname (default batsign.backloop.dev).
set -eu

OUT="deps"
PKI_DIR="${BATSIGN_PKI_DIR:-$HOME/.batsign-pki}"
LEAF_DAYS=365
EPHEMERAL=0
HOST="${BATSIGN_LOCAL_HOST:-batsign.backloop.dev}"
CA_DAYS=1825
MAX_LEAF_DAYS=825

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --pki-dir) PKI_DIR="$2"; shift 2 ;;
    --leaf-days) LEAF_DAYS="$2"; shift 2 ;;
    --ephemeral) EPHEMERAL=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "$LEAF_DAYS" -le "$MAX_LEAF_DAYS" ] 2>/dev/null || { echo "ERROR: --leaf-days must be an integer <= $MAX_LEAF_DAYS" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077

CA_KEY="${BATSIGN_CA_KEY:-}"
CA_CRT="${BATSIGN_CA_CERT:-}"
if [ -z "$CA_KEY" ]; then
  if [ "$EPHEMERAL" = 1 ]; then
    CA_KEY="$TMP/ca.key"; CA_CRT="$TMP/ca.crt"
  else
    mkdir -p "$PKI_DIR"; chmod 700 "$PKI_DIR"
    CA_KEY="$PKI_DIR/ca.key"; CA_CRT="$PKI_DIR/ca.crt"
  fi
fi

if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CRT" ]; then
  echo "==> Creating a new private CA (name-constrained to $HOST)"
  openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$CA_KEY"
  cat > "$TMP/ca.ext" <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
nameConstraints=critical,permitted;DNS:$HOST
EOF
  openssl req -new -key "$CA_KEY" -subj "/O=BatSign Local/CN=BatSign Local Installer CA" -out "$TMP/ca.csr"
  openssl x509 -req -in "$TMP/ca.csr" -signkey "$CA_KEY" -days "$CA_DAYS" -sha256 -extfile "$TMP/ca.ext" -out "$CA_CRT" 2>/dev/null
  chmod 600 "$CA_KEY"
else
  echo "==> Reusing the existing CA (renewal; the phone keeps trusting it)"
  openssl x509 -in "$CA_CRT" -noout -checkend $((86400 * 30)) >/dev/null \
    || { echo "ERROR: the CA expires within 30 days or has expired; make a new one (the phone must re-trust it)" >&2; exit 1; }
  openssl x509 -in "$CA_CRT" -noout -text | grep -q "DNS:$HOST" \
    || { echo "ERROR: the existing CA is not constrained to $HOST" >&2; exit 1; }
fi

echo "==> Issuing a leaf for $HOST ($LEAF_DAYS days)"
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$TMP/server.pem"
openssl req -new -key "$TMP/server.pem" -subj "/O=BatSign Local/CN=$HOST" -out "$TMP/server.csr"
cat > "$TMP/leaf.ext" <<EOF
subjectAltName=DNS:$HOST
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
authorityKeyIdentifier=keyid
subjectKeyIdentifier=hash
EOF
openssl x509 -req -in "$TMP/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial -CAserial "$TMP/ca.srl" \
  -days "$LEAF_DAYS" -sha256 -extfile "$TMP/leaf.ext" -out "$TMP/server.crt" 2>/dev/null

echo "==> Verifying"
openssl verify -CAfile "$CA_CRT" -purpose sslserver -verify_hostname "$HOST" "$TMP/server.crt" >/dev/null \
  || { echo "ERROR: the leaf does not verify against the CA for $HOST" >&2; exit 1; }
openssl x509 -in "$TMP/server.crt" -noout -text > "$TMP/leaf.txt"
grep -q "CA:FALSE" "$TMP/leaf.txt" && grep -q "TLS Web Server Authentication" "$TMP/leaf.txt" \
  && grep -q "DNS:$HOST" "$TMP/leaf.txt" || { echo "ERROR: wrong leaf extensions" >&2; exit 1; }
[ "$(openssl x509 -in "$TMP/server.crt" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$TMP/server.pem" -pubout | openssl sha256)" ] \
  || { echo "ERROR: the leaf key does not match the leaf certificate" >&2; exit 1; }
openssl x509 -in "$CA_CRT" -noout -checkend $((86400 * LEAF_DAYS)) >/dev/null \
  || { echo "ERROR: the CA expires before the leaf would; use fewer --leaf-days or a new CA" >&2; exit 1; }

mkdir -p "$OUT"
cp "$TMP/server.crt" "$OUT/server.crt"
cp "$TMP/server.pem" "$OUT/server.pem"
printf '%s\n' "$HOST" > "$OUT/commonName.txt"
cp "$CA_CRT" "$OUT/BatSignLocalCA.crt"
openssl x509 -in "$CA_CRT" -outform DER -out "$OUT/BatSignLocalCA.cer"

CA_B64="$(openssl base64 -A -in "$OUT/BatSignLocalCA.cer")"
CA_FP="$(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 | cut -d= -f2)"
# Stable UUIDs derived from the CA, so a renewal produces an identical profile.
UUID_SRC="$(openssl x509 -in "$CA_CRT" -outform DER | openssl sha256 | awk '{print $NF}')"
fmt_uuid() { printf '%s' "$1" | cut -c1-32 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/' | tr 'a-f' 'A-F'; }
CA_UUID="$(fmt_uuid "$UUID_SRC")"
PROFILE_UUID="$(fmt_uuid "$(printf 'profile-%s' "$UUID_SRC" | openssl sha256 | awk '{print $NF}')")"

cat > "$OUT/BatSignLocalCA.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadCertificateFileName</key>
			<string>BatSignLocalCA.cer</string>
			<key>PayloadContent</key>
			<data>$CA_B64</data>
			<key>PayloadDescription</key>
			<string>Trusts certificates for $HOST only (the CA is name-constrained to that host).</string>
			<key>PayloadDisplayName</key>
			<string>BatSign Local Installer CA</string>
			<key>PayloadIdentifier</key>
			<string>app.batsign.localca.cert.$CA_UUID</string>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadUUID</key>
			<string>$CA_UUID</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>Lets BatSign install apps over local HTTPS ($HOST). CA SHA-256: $CA_FP</string>
	<key>PayloadDisplayName</key>
	<string>BatSign Local Installer CA</string>
	<key>PayloadIdentifier</key>
	<string>app.batsign.localca.$PROFILE_UUID</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>$PROFILE_UUID</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
EOF
if command -v plutil >/dev/null 2>&1; then plutil -lint "$OUT/BatSignLocalCA.mobileconfig" >/dev/null; fi
chmod 644 "$OUT"/*

if ls "$OUT" | grep -qi 'ca\.key'; then echo "ERROR: a CA key ended up in $OUT" >&2; exit 1; fi

echo "OK  CA SHA-256   : $CA_FP"
echo "OK  leaf SHA-256 : $(openssl x509 -in "$OUT/server.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
echo "OK  leaf expires : $(openssl x509 -in "$OUT/server.crt" -noout -enddate | cut -d= -f2)"
if [ "$EPHEMERAL" = 1 ] && [ -z "${BATSIGN_CA_KEY:-}" ]; then
  echo "OK  ephemeral CA key destroyed (the next build needs a new CA, re-trusted on the phone)"
else
  echo "OK  CA key kept at $CA_KEY (never commit or bundle it)"
fi
echo "OK  staged in $OUT"
