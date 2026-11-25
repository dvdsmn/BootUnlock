#!/bin/bash
#
# Runs the real keychain helper against a scratch keychain, as a normal user.
#
# NOT part of "make test", because it is not side-effect free: it creates a
# keychain file in a temporary directory, which macOS adds to your keychain
# search list for the duration, and it removes both at the end.  It does not
# read or change your login keychain or the System keychain, needs no root and
# installs nothing.
#
# It answers what the stand-ins of tests/run.sh cannot: does the helper's
# keychain code work on this macOS, and does an entry really open for the
# build that created it and for no other?
#
# For that it compiles two test builds of the helper that use the scratch
# keychain instead of the System keychain and do not insist on root (see
# BOOTUNLOCK_TEST_KEYCHAIN in build/BootUnlock.c).  The two are the same code
# signed under different identifiers, which gives them different code hashes.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

TESTS=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$TESTS/.." && pwd -P)
WORK=$(mktemp -d -t BootUnlockKeychainTest)
KEYCHAIN="$WORK/scratch.keychain-db"
UUID1=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
UUID2=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB
TRICKY='p4ss phrase "quoted" \back $HOME it'"'"'s ü'

SEARCH_LIST_BEFORE=$(security list-keychains -d user)
cleanup() {
	security delete-keychain "$KEYCHAIN" > /dev/null 2>&1
	rm -rf "$WORK"
	if [ "$(security list-keychains -d user)" = "$SEARCH_LIST_BEFORE" ]; then
		echo "Keychain search list is as it was before the test."
	else
		echo "WARNING: the keychain search list changed.  It was:"
		echo "$SEARCH_LIST_BEFORE"
		echo "and is now:"
		security list-keychains -d user
	fi
}
trap cleanup EXIT

PASSED=0
FAILED=0
# expect DESCRIPTION EXPECTED ACTUAL
expect() {
	if [ "$2" = "$3" ]; then
		PASSED=$((PASSED + 1))
		printf '  ok    %s\n' "$1"
	else
		FAILED=$((FAILED + 1))
		printf '  FAIL  %s (expected [%s], got [%s])\n' "$1" "$2" "$3"
	fi
}

build() { # DIRECTORY IDENTIFIER-PREFIX
	mkdir -p "$WORK/$1"
	clang -O2 -Wall -Wextra "-DBOOTUNLOCK_TEST_KEYCHAIN=\"$KEYCHAIN\"" \
		-framework Security -framework CoreFoundation \
		-o "$WORK/$1/BootUnlock" "$ROOT/build/BootUnlock.c" || exit 1
	codesign -f -s - -o runtime "--prefix=$2" "$WORK/$1/BootUnlock" 2> /dev/null || exit 1
}
build mine au.com.openwall.
build other org.example.
MINE="$WORK/mine/BootUnlock"
OTHER="$WORK/other/BootUnlock"

security create-keychain -p scratch "$KEYCHAIN" || exit 1
security set-keychain-settings "$KEYCHAIN"

echo "Store, list, read"
printf '%s' "$TRICKY" | "$MINE" set "$UUID1" "Test volume"
expect "set succeeds" 0 "$?"
expect "list shows the entry" "$UUID1"$'\t'"Test volume" "$("$MINE" list)"
expect "get returns the passphrase byte for byte" "$TRICKY" "$("$MINE" get "$UUID1")"

echo "The entry opens for the build that made it only"
"$OTHER" get "$UUID1" > "$WORK/other.out" 2> "$WORK/other.err"
expect "a different build is refused with status 4, without a prompt" 4 "$?"
expect "and gets no passphrase" "" "$(cat "$WORK/other.out")"
cat "$WORK/other.err"

echo "Replace"
printf '%s' 'second' | "$MINE" set "$UUID1" "Renamed"
expect "set over an existing entry succeeds" 0 "$?"
expect "get returns the new passphrase" second "$("$MINE" get "$UUID1")"
expect "list shows the new label, once" "$UUID1"$'\t'"Renamed" "$("$MINE" list)"

echo "Entries BootUnlock did not create"
security add-generic-password -a "$UUID2" -s "$UUID2" -D "Encrypted Volume Password" -w not-a-real-secret "$KEYCHAIN"
printf '%s' 'x' | "$MINE" set "$UUID2" "Foreign" 2> /dev/null
expect "set refuses to replace a foreign entry (status 5)" 5 "$?"
"$MINE" get "$UUID2" > /dev/null 2>&1
expect "get does not see a foreign entry (status 1)" 1 "$?"
"$MINE" delete "$UUID2" > /dev/null 2>&1
expect "delete does not touch a foreign entry (status 1)" 1 "$?"
security find-generic-password -a "$UUID2" -s "$UUID2" "$KEYCHAIN" > /dev/null 2>&1
expect "the foreign entry is still there" 0 "$?"
expect "list does not show it" "$UUID1"$'\t'"Renamed" "$("$MINE" list)"

echo "Delete"
"$MINE" delete "$UUID1"
expect "delete succeeds" 0 "$?"
"$MINE" get "$UUID1" > /dev/null 2>&1
expect "get then reports no entry (status 1)" 1 "$?"
expect "list is empty" "" "$("$MINE" list)"

echo "Bad input"
"$MINE" get not-a-uuid > /dev/null 2>&1
expect "a malformed UUID is a usage error (status 2)" 2 "$?"
printf '' | "$MINE" set "$UUID1" "Empty" > /dev/null 2>&1
expect "an empty passphrase is a usage error (status 2)" 2 "$?"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
