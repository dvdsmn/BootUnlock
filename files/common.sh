# Shared settings and functions of the BootUnlock scripts: helper.sh,
# update.sh, uninstall.sh and the installer's postinstall.
#
# This file is sourced, never executed.  The sourcing script sets
# BOOTUNLOCK_DIR (the directory the scripts live in) and LOG_TAG (its own
# name) first.

PATH=/sbin:/bin:/usr/sbin:/usr/bin

IDENTIFIER=au.com.openwall.BootUnlock
INSTALL_LOCATION=/Library/PrivilegedHelperTools/$IDENTIFIER
LAUNCH_DAEMON_PLIST=/Library/LaunchDaemons/$IDENTIFIER.plist
NEWSYSLOG_CONF=/etc/newsyslog.d/$IDENTIFIER.conf
LOG_FILE=/var/log/BootUnlock.log
STATE_DIR=/var/db/BootUnlock
HELPER=$BOOTUNLOCK_DIR/BootUnlock

# After this many failed unlocks in a row the helper leaves a volume alone
# until it is enrolled again.  Wrong passphrases are not free: FileVault
# rate-limits them, and on volumes whose keys the Secure Enclave guards the
# number of attempts is finite.
MAX_FAILURES=3
# Seconds to wait before retrying a volume whose unlock just failed.
RETRY_DELAY=15
# For this many seconds after its first run since startup, the helper keeps
# looking for enrolled volumes that are not there yet or still locked.  A
# locked volume showing up does not mount anything, so no mount event
# announces it.
BOOT_WINDOW=120
# Seconds between two looks during that window.
POLL_INTERVAL=3
# How often update.sh asks again after a passphrase that does not verify.
MAX_PASSPHRASE_TRIES=3

UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
DEVICE_RE='^disk[0-9]+s[0-9]+$'
ROLES_RE='^[A-Za-z0-9 ,_-]*$'
NUMBER_RE='^[0-9]+$'

log() {
	printf '%s %s[%d]: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_TAG" "$$" "$*"
}

# The log names volumes and their UUIDs: administrators may read it, others
# may not.  Same owner and mode as /var/log/system.log.
prepare_log() {
	if [ ! -e "$LOG_FILE" ]; then
		: > "$LOG_FILE"
	fi
	chown root:admin "$LOG_FILE"
	chmod 0640 "$LOG_FILE"
}

prepare_state() {
	mkdir -p "$STATE_DIR/failed"
	chown root:wheel "$STATE_DIR" "$STATE_DIR/failed"
	chmod 0700 "$STATE_DIR" "$STATE_DIR/failed"
}

# Prints one line per APFS volume: UUID:DEVICE:ENCRYPTED:LOCKED:ROLES:NAME
# (see diskutil.xsl).  Lines whose fixed fields do not look right are dropped,
# so callers can rely on the first four fields.  NAME is untrusted text.
list_volumes() {
	local plist uuid device encrypted locked roles name
	plist=$(diskutil apfs list -plist) || return 1
	printf '%s' "$plist" \
		| xsltproc --novalid --nonet "$BOOTUNLOCK_DIR/diskutil.xsl" - \
		| while IFS=: read -r uuid device encrypted locked roles name; do
			[[ $uuid =~ $UUID_RE ]] || continue
			[[ $device =~ $DEVICE_RE ]] || continue
			case $encrypted in true | false) ;; *) continue ;; esac
			case $locked in true | false) ;; *) continue ;; esac
			[[ $roles =~ $ROLES_RE ]] || roles=unknown
			printf '%s:%s:%s:%s:%s:%s\n' "$uuid" "$device" "$encrypted" "$locked" "$roles" "$name"
		done
}

# Prints the device identifiers of the volumes macOS is running from.  The
# root file system is a snapshot of the system volume (disk3s1s1 of disk3s1),
# so the snapshot suffix is cut off.
boot_devices() {
	local mount_point
	for mount_point in / /System/Volumes/Data; do
		df -l "$mount_point" 2> /dev/null \
			| sed -n 's|^/dev/\(disk[0-9][0-9]*s[0-9][0-9]*\).*|\1|p' || true
	done
}

# Sets FAIL_COUNT and FAIL_TIME (seconds since the epoch) for a volume UUID.
read_failures() {
	local file="$STATE_DIR/failed/$1" count="" time=""
	FAIL_COUNT=0
	FAIL_TIME=0
	if [ -r "$file" ]; then
		read -r count time < "$file" || true
		if [[ $count =~ $NUMBER_RE ]]; then FAIL_COUNT=$count; fi
		if [[ $time =~ $NUMBER_RE ]]; then FAIL_TIME=$time; fi
	fi
}

clear_failures() {
	rm -f "$STATE_DIR/failed/$1"
}
