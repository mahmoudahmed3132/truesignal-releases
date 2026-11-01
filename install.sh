#!/bin/sh
# Copyright (c) 2026 TrueSignal Deception. All rights reserved.
#
# TrueSignal node agent installer (spec §8).
#
#   curl -fsSL https://raw.githubusercontent.com/mahmoudahmed3132/truesignal-releases/main/install.sh \
#     | TS_NODE_KEY=tsk_… sh -s -- --hub https://hub.example.com
#
# Options:
#   --version X.Y.Z   CLI version (default: newest cli/vX.Y.Z release)
#   --sha256 HEX      also require this SHA-256 for the binary (pinning)
#   --hub URL         run `truesignal link URL` afterwards (needs TS_NODE_KEY)
#   --prefix DIR      install directory (default /usr/local/bin)
#   --base-url URL    release base URL (https:// or file://; for mirrors/tests)
#
# The binary is verified against the release's SHA256SUMS, against --sha256
# when given, and against its Sigstore bundle when cosign is installed.
# Everything runs inside main(), so a truncated download executes nothing.

set -eu

# Releases are downloaded from the public releases repository; they are built
# and signed in the (private) source repository, which the signature names.
RELEASES_REPO="mahmoudahmed3132/truesignal-releases"
SIGNER_REPO="mahmoudahmed3132/TrueSignal-Rewrite"
WORKFLOW="publish-cli.yml"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

say() { printf '%s\n' "truesignal-install: $*" >&2; }
die() { say "error: $*"; exit 1; }

fetch() { # url dest
	case "$1" in
	https://*)
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
		elif command -v wget >/dev/null 2>&1; then
			wget -q --https-only -O "$2" "$1"
		else
			die "curl or wget is required"
		fi
		;;
	file://*) cp "${1#file://}" "$2" ;;
	*) die "refusing non-https URL: $1" ;;
	esac
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		die "sha256sum or shasum is required"
	fi
}

latest_version() {
	api="https://api.github.com/repos/$RELEASES_REPO/releases?per_page=100"
	fetch "$api" "$TMP/releases.json"
	# Tags look like "cli/v3.1.0"; pick the highest stable one.
	v=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"cli\/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "$TMP/releases.json" |
		sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
	[ -n "$v" ] || die "no cli/vX.Y.Z release found in $RELEASES_REPO"
	printf '%s' "$v"
}

main() {
	VERSION="" PIN="" HUB="${TS_HUB_URL:-}" PREFIX="/usr/local/bin" BASE=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--sha256) PIN="${2:?}"; shift 2 ;;
		--hub) HUB="${2:?}"; shift 2 ;;
		--prefix) PREFIX="${2:?}"; shift 2 ;;
		--base-url) BASE="${2:?}"; shift 2 ;;
		-h | --help) sed -n '4,20p' "$0" 2>/dev/null || true; exit 0 ;;
		*) die "unknown option $1" ;;
		esac
	done

	case "$(uname -s)" in
	Linux) ;;
	*) die "only Linux is supported" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "unsupported architecture $(uname -m)" ;;
	esac
	if [ "$ARCH" != amd64 ]; then
		say "note: sensor images are linux/amd64; deploying sensors on $ARCH needs TS_ALLOW_NON_AMD64=true"
	fi

	if [ "$PREFIX" = /usr/local/bin ] && [ "$(id -u)" -ne 0 ]; then
		die "run as root (or pass --prefix to a writable directory)"
	fi
	case "$VERSION" in
	"" | [0-9]*.[0-9]*.[0-9]*) ;;
	*) die "--version must look like 3.0.0" ;;
	esac
	case "$PIN" in
	"") ;;
	*[!0-9a-f]* | ?) die "--sha256 must be 64 lowercase hex digits" ;;
	esac
	if [ -n "$PIN" ] && [ "${#PIN}" -ne 64 ]; then
		die "--sha256 must be 64 lowercase hex digits"
	fi

	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT INT TERM

	[ -n "$VERSION" ] || VERSION=$(latest_version)
	[ -n "$BASE" ] || BASE="https://github.com/$RELEASES_REPO/releases/download/cli/v$VERSION"
	ASSET="truesignal-linux-$ARCH"
	say "installing truesignal $VERSION ($ARCH) from $BASE"

	fetch "$BASE/$ASSET" "$TMP/$ASSET"
	fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"

	want=$(awk -v f="$ASSET" '$2 == f || $2 == "*"f {print $1}' "$TMP/SHA256SUMS")
	[ -n "$want" ] || die "$ASSET is not listed in SHA256SUMS"
	got=$(sha256 "$TMP/$ASSET")
	[ "$got" = "$want" ] || die "checksum mismatch for $ASSET (got $got, release says $want)"
	if [ -n "$PIN" ] && [ "$got" != "$PIN" ]; then
		die "checksum does not match --sha256 pin (got $got)"
	fi
	say "SHA-256 verified: $got"

	if command -v cosign >/dev/null 2>&1; then
		fetch "$BASE/$ASSET.sigstore.json" "$TMP/$ASSET.sigstore.json" || die "Sigstore bundle missing"
		cosign verify-blob --bundle "$TMP/$ASSET.sigstore.json" \
			--certificate-identity "https://github.com/$SIGNER_REPO/.github/workflows/$WORKFLOW@refs/tags/cli/v$VERSION" \
			--certificate-oidc-issuer "$OIDC_ISSUER" "$TMP/$ASSET" >/dev/null 2>&1 ||
			die "Sigstore signature verification FAILED"
		say "Sigstore signature verified"
	else
		say "cosign not found: Sigstore signature not checked (SHA-256 only)"
	fi

	mkdir -p "$PREFIX"
	install -m 0755 "$TMP/$ASSET" "$PREFIX/truesignal"
	say "installed $PREFIX/truesignal"

	if [ -n "$HUB" ]; then
		[ -n "${TS_NODE_KEY:-}" ] || die "--hub given but TS_NODE_KEY is not set"
		"$PREFIX/truesignal" link "$HUB"
	fi
}

main "$@"
