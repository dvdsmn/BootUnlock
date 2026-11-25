#!/bin/bash
#
# BootUnlock helper: unlocks the enrolled APFS volumes that are locked.
#
# launchd starts it as root when the daemon is loaded (at startup) and every
# time a filesystem is mounted.  Its output goes to /var/log/BootUnlock.log.
#
# What it never does: it never unlocks a volume that was not enrolled with
# update.sh, it never tries a volume more than MAX_FAILURES times in a row,
# and it never passes a passphrase as a command argument.

set -eu -o pipefail

case "${BASH_SOURCE[0]}" in
*/*) BOOTUNLOCK_DIR=${BASH_SOURCE[0]%/*} ;;
*) BOOTUNLOCK_DIR=. ;;
esac
BOOTUNLOCK_DIR=$(cd "$BOOTUNLOCK_DIR" && pwd -P)
LOG_TAG=helper
. "$BOOTUNLOCK_DIR/common.sh"

umask 077
trap 'rc=$?; if [ "$rc" -ne 0 ]; then log "exiting with status $rc"; fi' EXIT

prepare_state

# Volumes this run has given up on, as " UUID UUID ".
SKIP=" "
# Messages already logged by note() in this run.
NOTED=""

# Logs a message once per run, however often the polling loop comes by.
note() {
	case $NOTED in
	*"|$1|"*) ;;
	*)
		NOTED="$NOTED|$1|"
		log "$1"
		;;
	esac
}

# The window: on the first run since startup, keep looking for a while.
# The time of startup identifies "this boot"; the window begins at the first
# run rather than at startup, because with FileVault the daemon only starts
# after somebody has typed a password, however long that took.
FIRST_RUN=0
WINDOW_START=0
BOOT_ID=$(sysctl -n kern.boottime 2> /dev/null | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p') || BOOT_ID=""
if [ -n "$BOOT_ID" ]; then
	saved_boot=""
	saved_start=""
	if [ -r "$STATE_DIR/boot" ]; then
		read -r saved_boot saved_start < "$STATE_DIR/boot" || true
	fi
	if [ "$saved_boot" = "$BOOT_ID" ] && [[ $saved_start =~ $NUMBER_RE ]]; then
		WINDOW_START=$saved_start
	else
		FIRST_RUN=1
		WINDOW_START=$(date +%s)
		printf '%s %s\n' "$BOOT_ID" "$WINDOW_START" > "$STATE_DIR/boot"
		log "first run since startup; watching for enrolled volumes for $BOOT_WINDOW seconds"
	fi
fi
DEADLINE=$((WINDOW_START + BOOT_WINDOW))

# unlock_volume UUID DEVICE NAME
unlock_volume() {
	local uuid=$1 device=$2 name=$3 passphrase="" output="" rc=0 now failures

	read_failures "$uuid"
	if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
		if [ "$FIRST_RUN" = 1 ]; then
			note "volume '$name' ($uuid) stays locked: $FAIL_COUNT unlock attempts failed; run update.sh to enrol it again"
		fi
		SKIP="$SKIP$uuid "
		return 0
	fi
	now=$(date +%s)
	if [ $((now - FAIL_TIME)) -lt "$RETRY_DELAY" ]; then
		PENDING=1
		return 0
	fi

	passphrase=$("$HELPER" get "$uuid") || rc=$?
	if [ "$rc" -ne 0 ]; then
		if [ "$rc" -eq 1 ]; then
			log "volume '$name' ($uuid) is not enrolled any more"
		else
			log "ERROR: the keychain did not release the passphrase of volume '$name' ($uuid), helper status $rc; run update.sh to enrol the volume again"
		fi
		SKIP="$SKIP$uuid "
		return 0
	fi

	log "unlocking volume '$name' ($device, $uuid)"
	output=$(printf '%s' "$passphrase" | diskutil apfs unlock "$device" -stdinpassphrase 2>&1) || rc=$?
	passphrase=""
	output=${output//$'\n'/ / }
	if [ "$rc" -eq 0 ]; then
		clear_failures "$uuid"
		log "volume '$name' is unlocked: $output"
		return 0
	fi

	failures=$((FAIL_COUNT + 1))
	printf '%s %s\n' "$failures" "$(date +%s)" > "$STATE_DIR/failed/$uuid"
	log "ERROR: could not unlock volume '$name' (failure $failures of $MAX_FAILURES): $output"
	if [ "$failures" -ge "$MAX_FAILURES" ]; then
		log "volume '$name' ($uuid) is left alone from now on; run update.sh to enrol it again"
		SKIP="$SKIP$uuid "
	else
		PENDING=1
	fi
	return 0
}

# One look at the system.  Sets PENDING=1 when an enrolled volume is absent,
# or locked with attempts left.  Returns 1 when the system was not ready.
scan() {
	local enrolled volumes uuid label v_uuid device encrypted locked roles name found

	if ! enrolled=$("$HELPER" list); then
		note "the keychain helper cannot list the enrolled volumes (yet)"
		return 1
	fi
	if [ -z "$enrolled" ]; then
		return 0
	fi
	if ! volumes=$(list_volumes); then
		note "diskutil cannot list the APFS volumes (yet)"
		return 1
	fi

	MISSING=""
	while IFS=$'\t' read -r uuid label; do
		[[ $uuid =~ $UUID_RE ]] || continue
		case $SKIP in *" $uuid "*) continue ;; esac
		found=0
		while IFS=: read -r v_uuid device encrypted locked roles name; do
			[ "$v_uuid" = "$uuid" ] || continue
			found=1
			if [ "$locked" = true ]; then
				unlock_volume "$uuid" "$device" "${name:-$label}"
			fi
			break
		done <<< "$volumes"
		if [ "$found" = 0 ]; then
			PENDING=1
			MISSING="$MISSING '$label' ($uuid)"
		fi
	done <<< "$enrolled"
	return 0
}

WAITED=0
MISSING=""
while :; do
	PENDING=0
	scan || PENDING=1
	if [ "$PENDING" = 0 ] || [ "$(date +%s)" -ge "$DEADLINE" ]; then
		break
	fi
	WAITED=1
	sleep "$POLL_INTERVAL"
done

if [ "$WAITED" = 1 ] && [ "$PENDING" = 1 ]; then
	log "stopped watching; not attached or still locked:${MISSING:- see the messages above}"
fi
exit 0
