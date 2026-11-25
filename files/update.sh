#!/bin/bash
#
# BootUnlock enrolment: choose which encrypted APFS volumes are unlocked at
# startup, and store their passphrases in the System keychain.
#
# Run it whenever the choice changes, and after every upgrade of BootUnlock
# (the keychain entries only open for the exact helper build that made them).
# It needs root and asks for administrator rights when started without.
#
# Volume names are untrusted text.  They reach the dialogs as arguments of the
# static ui-*.js / ui-*.applescript files and are never pasted into script
# source.  Passphrases reach diskutil and the keychain helper on standard
# input and are never passed as arguments.

set -eu -o pipefail

case "${BASH_SOURCE[0]}" in
*/*) BOOTUNLOCK_DIR=${BASH_SOURCE[0]%/*} ;;
*) BOOTUNLOCK_DIR=. ;;
esac
BOOTUNLOCK_DIR=$(cd "$BOOTUNLOCK_DIR" && pwd -P)
LOG_TAG=update
. "$BOOTUNLOCK_DIR/common.sh"

if [ "$(id -u)" != 0 ]; then
	exec osascript "$BOOTUNLOCK_DIR/ui-elevate.applescript" "$BOOTUNLOCK_DIR/update.sh" \
		"BootUnlock needs administrator privileges to read the volume list and to update the System keychain."
fi

umask 077
prepare_log
prepare_state
printf 'BootUnlock: messages go to %s\n' "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1
log "started"

# alert critical|informational MESSAGE
alert() {
	osascript "$BOOTUNLOCK_DIR/ui-alert.applescript" "$1" "$2" > /dev/null 2>&1 || true
}

ENROLLED=""

refresh_enrolled() {
	ENROLLED=$("$HELPER" list)
}

is_enrolled() {
	case $'\n'"$ENROLLED" in
	*$'\n'"$1"$'\t'*) return 0 ;;
	esac
	return 1
}

# Tells the user what BootUnlock will do from now on.  $1 is an optional
# first sentence.
summary() {
	local text=${1:-} uuid label lines="" names="" nl=$'\n'
	refresh_enrolled || true
	while IFS=$'\t' read -r uuid label; do
		[[ $uuid =~ $UUID_RE ]] || continue
		lines="$lines$nl- ${label:-unnamed volume} ($uuid)"
		names="$names '${label:-unnamed volume}' ($uuid)"
	done <<< "$ENROLLED"
	if [ -n "$text" ]; then
		text="$text$nl$nl"
	fi
	if [ -n "$lines" ]; then
		text="${text}BootUnlock unlocks these volumes at startup:$lines"
	else
		text="${text}No volume is enrolled, so BootUnlock does not unlock anything at startup."
	fi
	text="$text$nl${nl}To change this, run $BOOTUNLOCK_DIR/update.sh again.  Details are in $LOG_FILE."
	log "enrolled now:${names:- none}"
	alert informational "$text"
}

# True when the stored passphrase of an enrolled volume can still be read by
# this helper build and still fits the volume.
stored_passphrase_works() {
	local uuid=$1 device=$2 passphrase
	passphrase=$("$HELPER" get "$uuid" 2> /dev/null) || return 1
	printf '%s' "$passphrase" | diskutil apfs unlock "$device" -stdinpassphrase -verify -user "$uuid" > /dev/null 2>&1
}

# enrol UUID DEVICE NAME: asks for the passphrase, checks it against the
# volume without unlocking it, stores it and reads it back.
enrol() {
	local uuid=$1 device=$2 name=$3 passphrase="" tries=0 rc

	while [ "$tries" -lt "$MAX_PASSPHRASE_TRIES" ]; do
		tries=$((tries + 1))
		passphrase=$(osascript -l JavaScript "$BOOTUNLOCK_DIR/ui-passphrase.js" \
			"Passphrase of volume \"$name\" ($device).  It is checked against the volume and then stored in the System keychain.") || passphrase=""
		if [ -z "$passphrase" ]; then
			log "volume '$name' ($uuid): skipped, nothing stored"
			return 1
		fi

		if printf '%s' "$passphrase" | diskutil apfs unlock "$device" -stdinpassphrase -verify -user "$uuid"; then
			rc=0
			printf '%s' "$passphrase" | "$HELPER" set "$uuid" "$name" || rc=$?
			if [ "$rc" -eq 0 ] && [ "$("$HELPER" get "$uuid")" = "$passphrase" ]; then
				passphrase=""
				clear_failures "$uuid"
				log "volume '$name' ($uuid): enrolled"
				return 0
			fi
			passphrase=""
			if [ "$rc" -eq 5 ]; then
				log "ERROR: volume '$name' ($uuid): the System keychain holds an entry BootUnlock did not create"
				alert critical "The System keychain already holds a passphrase for volume \"$name\" that BootUnlock did not create (macOS itself or another program may be using it).  BootUnlock left it untouched and will not unlock this volume.

If you are sure the entry is not needed, remove it in Keychain Access (System keychain, search for $uuid) and run update.sh again."
			else
				log "ERROR: volume '$name' ($uuid): the passphrase could not be stored and read back (helper status $rc)"
				alert critical "BootUnlock could not store the passphrase of volume \"$name\" in the System keychain.  Details are in $LOG_FILE."
			fi
			return 1
		fi

		passphrase=""
		log "volume '$name' ($uuid): passphrase not accepted (attempt $tries of $MAX_PASSPHRASE_TRIES)"
		alert critical "That passphrase does not fit volume \"$name\" (attempt $tries of $MAX_PASSPHRASE_TRIES)."
	done

	log "volume '$name' ($uuid): giving up after $MAX_PASSPHRASE_TRIES wrong passphrases"
	return 1
}

if ! VOLUMES=$(list_volumes); then
	log "ERROR: diskutil could not list the APFS volumes"
	alert critical "BootUnlock could not read the list of APFS volumes.  Details are in $LOG_FILE."
	exit 1
fi
if ! refresh_enrolled; then
	log "ERROR: the keychain helper could not list the enrolled volumes"
	alert critical "BootUnlock could not read the System keychain.  Details are in $LOG_FILE."
	exit 1
fi
BOOT_DEVICES=$(boot_devices)

# The candidates: encrypted volumes with no special role that macOS is not
# running from.  macOS unlocks its own system and data volumes itself.
C_UUID=()
C_DEVICE=()
C_NAME=()
C_ENROLLED=()
N=0
while IFS=: read -r uuid device encrypted locked roles name; do
	[ -n "$uuid" ] || continue
	[ "$encrypted" = true ] || continue
	[ -z "$roles" ] || continue
	case $'\n'"$BOOT_DEVICES"$'\n' in *$'\n'"$device"$'\n'*) continue ;; esac
	C_UUID[N]=$uuid
	C_DEVICE[N]=$device
	C_NAME[N]=${name:-unnamed volume}
	if is_enrolled "$uuid"; then C_ENROLLED[N]=1; else C_ENROLLED[N]=0; fi
	N=$((N + 1))
done <<< "$VOLUMES"

if [ "$N" -eq 0 ]; then
	log "no encrypted APFS volume to offer"
	summary "No encrypted APFS volume is attached, other than the ones macOS is running from.  Attach the volume and run update.sh again."
	exit 0
fi

CHOOSER_ARGS=()
for ((i = 0; i < N; i++)); do
	CHOOSER_ARGS+=("${C_ENROLLED[i]}" "${C_DEVICE[i]} > ${C_NAME[i]}")
done
CHOICE=$(osascript -l JavaScript "$BOOTUNLOCK_DIR/ui-choose.js" "${CHOOSER_ARGS[@]}") || CHOICE=CANCEL
CHOICE_RE='^OK( [0-9]+)*$'
if ! [[ $CHOICE =~ $CHOICE_RE ]]; then
	log "cancelled, nothing changed"
	summary "Nothing was changed."
	exit 0
fi

SELECTED=()
for ((i = 0; i < N; i++)); do SELECTED[i]=0; done
for index in ${CHOICE#OK}; do
	if [ "$index" -lt "$N" ]; then SELECTED[index]=1; fi
done

for ((i = 0; i < N; i++)); do
	uuid=${C_UUID[i]}
	device=${C_DEVICE[i]}
	name=${C_NAME[i]}

	if [ "${SELECTED[i]}" != 1 ]; then
		if [ "${C_ENROLLED[i]}" = 1 ]; then
			if "$HELPER" delete "$uuid"; then
				log "volume '$name' ($uuid): no longer enrolled, passphrase removed from the System keychain"
			else
				log "ERROR: volume '$name' ($uuid): its passphrase could not be removed from the System keychain"
			fi
			clear_failures "$uuid"
		fi
		continue
	fi

	if [ "${C_ENROLLED[i]}" = 1 ] && stored_passphrase_works "$uuid" "$device"; then
		clear_failures "$uuid"
		log "volume '$name' ($uuid): already enrolled, stored passphrase still fits"
		continue
	fi
	enrol "$uuid" "$device" "$name" || true
done

summary ""
log "finished"
