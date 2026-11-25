#!/bin/bash
#
# Shows what BootUnlock would see on this Mac, and changes nothing.
#
# It runs three read-only system queries as the current user, no root:
#   diskutil apfs list -plist    the APFS volumes
#   df -l / /System/Volumes/Data which devices macOS is running from
#   sysctl -n kern.boottime      the time of the last startup
# and prints how the scripts in files/ interpret the answers: the volume list,
# and which volumes update.sh would offer for enrolment.
#
# Use it before installing: the offline tests (tests/run.sh) rest on
# assumptions about the output of these commands, and this checks them
# against the real thing.

set -u

TESTS=$(cd "$(dirname "$0")" && pwd -P)
BOOTUNLOCK_DIR=$(cd "$TESTS/../files" && pwd -P)
LOG_TAG=dry-run
. "$BOOTUNLOCK_DIR/common.sh"

echo "== Volumes as BootUnlock reads them (UUID:DEVICE:ENCRYPTED:LOCKED:ROLES:NAME) =="
if ! VOLUMES=$(list_volumes); then
	echo "PROBLEM: diskutil or xsltproc failed"
	exit 1
fi
printf '%s\n' "$VOLUMES"
RAW=$(diskutil apfs list -plist | grep -c '<key>APFSVolumeUUID</key>')
READ=$(printf '%s\n' "$VOLUMES" | grep -c .)
echo "diskutil reports $RAW volumes, BootUnlock read $READ"
if [ "$RAW" != "$READ" ]; then
	echo "PROBLEM: the numbers differ, so some volume was not understood"
fi

echo
echo "== Devices macOS is running from (never offered) =="
BOOT_DEVICES=$(boot_devices)
printf '%s\n' "${BOOT_DEVICES:-PROBLEM: none found}"

echo
echo "== Volumes update.sh would offer for enrolment =="
OFFERED=0
while IFS=: read -r uuid device encrypted locked roles name; do
	[ -n "$uuid" ] || continue
	[ "$encrypted" = true ] || continue
	[ -z "$roles" ] || continue
	case $'\n'"$BOOT_DEVICES"$'\n' in *$'\n'"$device"$'\n'*) continue ;; esac
	OFFERED=$((OFFERED + 1))
	printf '%s > %s   (%s, %s)\n' "$device" "${name:-unnamed volume}" "$uuid" "$([ "$locked" = true ] && echo locked || echo unlocked)"
done <<< "$VOLUMES"
if [ "$OFFERED" -eq 0 ]; then
	echo "(none)"
fi

echo
echo "== Startup time as helper.sh reads it =="
BOOT_ID=$(sysctl -n kern.boottime 2> /dev/null | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')
if [[ $BOOT_ID =~ $NUMBER_RE ]]; then
	echo "$BOOT_ID ($(date -r "$BOOT_ID"))"
else
	echo "PROBLEM: could not read it from: $(sysctl -n kern.boottime 2>&1)"
fi
