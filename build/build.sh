#!/bin/bash

# Name of the package.
NAME="BootUnlock"

# Once installed the identifier is used as the filename for a receipt files in /var/db/receipts/.
IDENTIFIER="au.com.openwall.$NAME"

# Package version number.
VERSION="1.3.4"

# The location to copy the contents of files.
INSTALL_LOCATION="/Library/PrivilegedHelperTools/$IDENTIFIER"

set -eu -o pipefail

WORK_DIR="${0%/*}"
[ -z "$WORK_DIR" -o "$WORK_DIR" == "$0" ] && WORK_DIR="$(pwd)" ||:

echo "WORK_DIR=$WORK_DIR"
mkdir -p "$WORK_DIR/../out" ||:

# pkgbuild need proper permissions on the source files
chmod 0755 "$WORK_DIR/../files/"*.sh
chmod 0644 "$WORK_DIR/../files/"*.xsl

# Build the "BootUnlock" keychain helper natively for both Apple Silicon and
# Intel Macs. It replaces lipo-thinning Apple's own /usr/bin/security (which
# only ships x86_64 and arm64e slices -- the arm64e one can't be re-signed by
# a third party and run without Rosetta) with a small program compiled for
# plain arm64/x86_64 that talks to the keychain itself.
#
# The helper is ad-hoc signed and, deliberately, no "-r" (designated
# requirement) is given to codesign.  Its default requirement for ad-hoc code
# is the binary's own code-directory hash ("cdhash"), so when files/update.sh
# registers the helper in the System keychain ACL (-T) the ACL pins this exact
# build.  An explicit 'identifier "..."' requirement would instead let any
# ad-hoc signed binary that claims the same identifier read the volume
# passphrases.  The trade-off: every rebuild changes the hash, so update.sh
# has to be re-run after upgrading the helper (postinstall does that).  The
# --prefix only keeps the identifier stable for logs and keychain dialogs.
clang -O2 -Wall \
	-arch x86_64 -arch arm64 \
	-framework Security -framework CoreFoundation \
	-o "$WORK_DIR/../files/$NAME" \
	"$WORK_DIR/BootUnlock.c"
codesign -f -s - "--prefix=${IDENTIFIER%$NAME}" "$WORK_DIR/../files/$NAME"
chmod 0755 "$WORK_DIR/../files/$NAME"

# Build package.
/usr/bin/pkgbuild \
	--identifier "$IDENTIFIER" \
	--version "$VERSION" \
	--install-location "$INSTALL_LOCATION" \
	--root "$WORK_DIR/../files" \
	--scripts "$WORK_DIR/../scripts" \
	"$WORK_DIR/../out/$NAME-$VERSION-dist.pkg"

/usr/bin/productbuild \
	--distribution "$WORK_DIR/Distribution.xml" \
	--package-path "$WORK_DIR/../out" \
        --resources "$WORK_DIR/../resources" \
	"$WORK_DIR/../out/$NAME-$VERSION.pkg"

rm "$WORK_DIR/../out/$NAME-$VERSION-dist.pkg"
