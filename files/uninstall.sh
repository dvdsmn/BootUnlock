#!/bin/bash
#
# Removes BootUnlock from this Mac: its launch daemon, the passphrases it
# stored in the System keychain, its state, its log, its files and its
# installer receipt.
#
# The volumes and their passphrases are not changed.  Volumes that are
# unlocked right now stay unlocked until they are ejected or the Mac restarts.
#
# It needs root and asks for administrator rights when started without.

set -u -o pipefail

case "${BASH_SOURCE[0]}" in
*/*) BOOTUNLOCK_DIR=${BASH_SOURCE[0]%/*} ;;
*) BOOTUNLOCK_DIR=. ;;
esac
BOOTUNLOCK_DIR=$(cd "$BOOTUNLOCK_DIR" && pwd -P)
LOG_TAG=uninstall
. "$BOOTUNLOCK_DIR/common.sh"

# Always the installed helper, wherever this script was started from: the
# keychain entries have to go before the helper that can remove them does.
HELPER=$INSTALL_LOCATION/BootUnlock

# Everything is inside one function, so bash has read the whole script before
# the script removes its own directory.
main() {
	local entries="" uuid label status=0

	if [ "$(id -u)" != 0 ]; then
		exec osascript "$BOOTUNLOCK_DIR/ui-elevate.applescript" "$BOOTUNLOCK_DIR/uninstall.sh" \
			"BootUnlock needs administrator privileges to remove itself and the passphrases it stored in the System keychain."
	fi

	echo "Stopping the launch daemon $IDENTIFIER"
	launchctl bootout "system/$IDENTIFIER" 2> /dev/null
	rm -f "$LAUNCH_DAEMON_PLIST"

	if [ -x "$HELPER" ] && entries=$("$HELPER" list); then
		while IFS=$'\t' read -r uuid label; do
			[[ $uuid =~ $UUID_RE ]] || continue
			if "$HELPER" delete "$uuid"; then
				echo "Removed the passphrase of '$label' ($uuid) from the System keychain"
			else
				echo "WARNING: could not remove the passphrase of '$label' ($uuid) from the System keychain"
				status=1
			fi
		done <<< "$entries"
	else
		echo "WARNING: the keychain helper $HELPER is missing or failed, so stored passphrases were not removed."
		echo "         Look in Keychain Access, System keychain, for entries of kind 'Encrypted Volume Password'"
		echo "         whose comment starts with 'Managed by BootUnlock'."
		status=1
	fi

	echo "Removing state, log rotation rule and log"
	rm -rf "$STATE_DIR"
	rm -f "$NEWSYSLOG_CONF" "$LOG_FILE" "$LOG_FILE".*

	echo "Forgetting the installer receipt"
	pkgutil --forget "$IDENTIFIER" > /dev/null 2>&1

	# INSTALL_LOCATION is a constant from common.sh, never a computed path.
	case $INSTALL_LOCATION in
	*/"$IDENTIFIER")
		echo "Removing $INSTALL_LOCATION"
		rm -rf "$INSTALL_LOCATION"
		;;
	*)
		echo "WARNING: unexpected install location '$INSTALL_LOCATION', not removed"
		status=1
		;;
	esac

	if [ "$status" -eq 0 ]; then
		echo "BootUnlock is removed."
	else
		echo "BootUnlock is removed, with the warnings above."
	fi
	echo "Entries stored by BootUnlock 1.3.3 or older carry no marker and are not removed by this script."
	return "$status"
}

main "$@"
exit $?
