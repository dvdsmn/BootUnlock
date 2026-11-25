#!/bin/bash
#
# Builds out/BootUnlock-<version>.pkg and leaves a copy of the signed keychain
# helper in out/BootUnlock for inspection and for "make test".
#
# Settings, taken from the environment:
#   ARCHS              architectures of the helper, default "x86_64 arm64"
#   MIN_OS             oldest macOS the helper is built for, default 10.15
#   PKG_SIGN_IDENTITY  "Developer ID Installer: ..." identity to sign the
#                      package with; unset builds an unsigned package
#
# An unsigned package can be replaced by anything able to write to out/, and
# it is installed as root.  Build it, compare the SHA-256 printed at the end
# with the file you are about to open, and install it in the same sitting.

set -eu -o pipefail

# Only the system's tools, whatever the caller's PATH says.  /usr/bin/clang
# still resolves to the Xcode or Command Line Tools selected by xcode-select.
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Name of the package.
NAME="BootUnlock"

# Once installed the identifier is used as the filename for a receipt files in /var/db/receipts/.
IDENTIFIER="au.com.openwall.$NAME"

# Package version number.  The only place it is written down.
#
# This fork is numbered 1.3.3.x: newer than upstream's 1.3.3 it is based on,
# and older than a future upstream 1.3.4, so the two cannot be confused.
VERSION="1.3.3.1"

# The location to copy the contents of files.
INSTALL_LOCATION="/Library/PrivilegedHelperTools/$IDENTIFIER"

ARCHS="${ARCHS:-x86_64 arm64}"
MIN_OS="${MIN_OS:-10.15}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-}"

case "$0" in
*/*) WORK_DIR=${0%/*} ;;
*) WORK_DIR=. ;;
esac
ROOT=$(cd "$WORK_DIR/.." && pwd -P)
OUT="$ROOT/out"

ARCH_FLAGS=()
HOST_ARCHS=""
for arch in $ARCHS; do
	case $arch in
	arm64 | x86_64) ;;
	*)
		echo "build.sh: unsupported architecture '$arch' in ARCHS (use arm64 and/or x86_64)" >&2
		exit 2
		;;
	esac
	ARCH_FLAGS+=(-arch "$arch")
	HOST_ARCHS="$HOST_ARCHS${HOST_ARCHS:+,}$arch"
done
if [ -z "$HOST_ARCHS" ]; then
	echo "build.sh: ARCHS is empty" >&2
	exit 2
fi

mkdir -p "$OUT"
STAGE=$(mktemp -d "$OUT/stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/payload" "$STAGE/scripts" "$STAGE/packages"

# The payload is an explicit list, copied with explicit modes, so nothing that
# merely happens to lie in files/ ends up in a package that installs as root.
install -m 0755 "$ROOT/files/helper.sh" "$ROOT/files/update.sh" "$ROOT/files/uninstall.sh" "$STAGE/payload/"
install -m 0644 "$ROOT/files/common.sh" "$ROOT/files/diskutil.xsl" \
	"$ROOT/files/ui-choose.js" "$ROOT/files/ui-passphrase.js" \
	"$ROOT/files/ui-alert.applescript" "$ROOT/files/ui-elevate.applescript" "$STAGE/payload/"
install -m 0755 "$ROOT/scripts/postinstall" "$STAGE/scripts/"

# The keychain helper (build/BootUnlock.c explains its security model).
#
# It is ad-hoc signed ("-s -") and, deliberately, no "-r" (designated
# requirement) is given to codesign.  The default requirement of ad-hoc code
# is the binary's own code directory hash ("cdhash"), and that is what the
# helper records in the access list of the keychain entries it creates: the
# entries open for this exact build only.  An explicit 'identifier "..."'
# requirement would let any ad-hoc signed binary that claims the identifier
# read the passphrases.  The price: every build has a different hash, so
# update.sh has to run again after every upgrade (the installer starts it).
#
# "-o runtime" turns on the hardened runtime.  Without it, anybody could load
# their own code into a copy of the helper (DYLD_INSERT_LIBRARIES) and act
# under its trusted hash, which would defeat the helper's root check.
#
# "--prefix" only gives the helper a readable identifier in logs.
/usr/bin/clang -O2 -Wall -Wextra \
	"${ARCH_FLAGS[@]}" \
	"-mmacosx-version-min=$MIN_OS" \
	-framework Security -framework CoreFoundation \
	-o "$STAGE/payload/$NAME" \
	"$ROOT/build/BootUnlock.c"
/usr/bin/codesign -f -s - -o runtime "--prefix=${IDENTIFIER%$NAME}" "$STAGE/payload/$NAME"
chmod 0755 "$STAGE/payload/$NAME"

# hostArchitectures has to name arm64, or the installer evaluates the package
# and runs its scripts under Rosetta 2 on Apple Silicon (see productbuild(1)).
sed -e "s/@VERSION@/$VERSION/g" -e "s/@HOST_ARCHS@/$HOST_ARCHS/g" -e "s/@MIN_OS@/$MIN_OS/g" \
	"$ROOT/build/Distribution.xml" > "$STAGE/Distribution.xml"

# Build package.
/usr/bin/pkgbuild \
	--identifier "$IDENTIFIER" \
	--version "$VERSION" \
	--install-location "$INSTALL_LOCATION" \
	--root "$STAGE/payload" \
	--scripts "$STAGE/scripts" \
	"$STAGE/packages/$NAME-$VERSION-dist.pkg"

SIGN_ARGS=()
if [ -n "$PKG_SIGN_IDENTITY" ]; then
	SIGN_ARGS=(--sign "$PKG_SIGN_IDENTITY")
fi
/usr/bin/productbuild \
	--distribution "$STAGE/Distribution.xml" \
	--package-path "$STAGE/packages" \
	--resources "$ROOT/resources" \
	${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
	"$OUT/$NAME-$VERSION.pkg"

cp "$STAGE/payload/$NAME" "$OUT/$NAME"

echo
echo "Package:  $OUT/$NAME-$VERSION.pkg"
echo "SHA-256:  $(shasum -a 256 "$OUT/$NAME-$VERSION.pkg" | cut -d' ' -f1)"
if [ -n "$PKG_SIGN_IDENTITY" ]; then
	echo "Signed:   $PKG_SIGN_IDENTITY"
else
	echo "Signed:   no (see the note at the top of build/build.sh)"
fi
echo "Helper:   $HOST_ARCHS, macOS $MIN_OS or newer, code hashes the keychain entries will trust:"
for arch in $ARCHS; do
	echo "          $arch $(/usr/bin/codesign -d -vvv --arch "$arch" "$OUT/$NAME" 2>&1 | sed -n 's/^CDHash=//p')"
done
