#!/bin/bash
#
# Offline tests of BootUnlock ("make test").
#
# The scripts from files/ and scripts/ are copied into a temporary sandbox.
# In the copy of common.sh the settings point into the sandbox, and PATH puts a
# directory of stand-ins first: diskutil, osascript, launchctl, pkgutil, id,
# chown, df, sysctl and stat.  The keychain helper is a stand-in too, with a
# directory of files as its keychain.  The stand-ins record how they were
# called, which is what the tests look at.
#
# So this touches no disk, no keychain, no launchd job and shows no dialog.
# What it cannot tell: whether the real diskutil, the real System keychain,
# launchd and the installer behave the way the stand-ins assume.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

TESTS=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$TESTS/.." && pwd -P)
# The scripts resolve symbolic links in their own location, and the temporary
# directory is reached through one (/var is /private/var), hence "pwd -P".
SANDBOX=$(cd "$(mktemp -d -t BootUnlockTests)" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT

SB="$SANDBOX/sb"
APP="$SB/Library/PrivilegedHelperTools/au.com.openwall.BootUnlock"

EXT=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
OTHER=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB
SECRET='ext s3cret "quoted" $HOME'

PASSED=0
FAILED=0
ok() {
	PASSED=$((PASSED + 1))
	printf '  ok    %s\n' "$1"
}
no() {
	FAILED=$((FAILED + 1))
	printf '  FAIL  %s\n' "$1"
}
# check DESCRIPTION COMMAND [ARGUMENT ...]
check() {
	local description=$1
	shift
	if "$@" > /dev/null 2>&1; then ok "$description"; else no "$description"; fi
}
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
count_is() { [ "$(grep -cF -- "$2" "$1")" = "$3" ]; }
section() { printf '\n%s\n' "$1"; }

# --- the sandbox -------------------------------------------------------------

# setup [BOOT_WINDOW [RETRY_DELAY]]
setup() {
	local window=${1:-4} retry=${2:-0}
	rm -rf "$SB"
	mkdir -p "$APP" "$SB/stubs" "$SB/keychain" "$SB/volumes" "$SB/etc/newsyslog.d" "$SB/LaunchDaemons" "$SB/cwd"
	cp "$ROOT"/files/* "$APP/"
	sed -e "s|^PATH=.*|PATH=$SB/stubs:/usr/bin:/bin:/usr/sbin:/sbin|" \
		-e "s|^INSTALL_LOCATION=.*|INSTALL_LOCATION=$APP|" \
		-e "s|^LAUNCH_DAEMON_PLIST=.*|LAUNCH_DAEMON_PLIST=$SB/LaunchDaemons/\$IDENTIFIER.plist|" \
		-e "s|^NEWSYSLOG_CONF=.*|NEWSYSLOG_CONF=$SB/etc/newsyslog.d/\$IDENTIFIER.conf|" \
		-e "s|^LOG_FILE=.*|LOG_FILE=$SB/log|" \
		-e "s|^STATE_DIR=.*|STATE_DIR=$SB/state|" \
		-e "s|^BOOT_WINDOW=.*|BOOT_WINDOW=$window|" \
		-e "s|^POLL_INTERVAL=.*|POLL_INTERVAL=1|" \
		-e "s|^RETRY_DELAY=.*|RETRY_DELAY=$retry|" \
		"$ROOT/files/common.sh" > "$APP/common.sh"
	: > "$SB/calls.log"
	: > "$SB/stdin.log"
	: > "$SB/alerts.log"
	: > "$SB/osascript.queue"
	: > "$SB/log"
	echo 1000 > "$SB/boottime"
	# By default the helper is past its startup window: one look, no waiting.
	mkdir -p "$SB/state/failed"
	echo "1000 1" > "$SB/state/boot"

	cat > "$SB/stubs/diskutil" << EOF
#!/bin/bash
printf 'diskutil %s\n' "\$*" >> "$SB/calls.log"
case "\$1 \$2" in
"apfs list")
	if [ -s "$SB/fixture.queue" ]; then
		head -1 "$SB/fixture.queue" > "$SB/fixture.current"
		tail -n +2 "$SB/fixture.queue" > "$SB/fixture.queue.new"
		mv "$SB/fixture.queue.new" "$SB/fixture.queue"
	fi
	fixture=\$(cat "$SB/fixture.current")
	if [ "\$fixture" = FAIL ]; then echo "diskutil: not ready" >&2; exit 1; fi
	cat "\$fixture"
	;;
"apfs unlock")
	given=\$(cat)
	printf 'unlock %s | %s | stdin=%s\n' "\$3" "\$*" "\$given" >> "$SB/stdin.log"
	if [ -e "$SB/volumes/\$3" ] && [ "\$given" = "\$(cat "$SB/volumes/\$3")" ]; then
		echo "Unlocked and mounted APFS Volume"
		exit 0
	fi
	echo "Error unlocking APFS Volume: wrong passphrase" >&2
	exit 1
	;;
esac
EOF
	cat > "$APP/BootUnlock" << EOF
#!/bin/bash
printf 'BootUnlock %s\n' "\$*" >> "$SB/calls.log"
K="$SB/keychain"
case \$1 in
list)
	[ -e "$SB/helper.list-fails" ] && exit 4
	for f in "\$K"/*.label; do
		[ -e "\$f" ] || continue
		u=\${f##*/}
		printf '%s\t%s\n' "\${u%.label}" "\$(cat "\$f")"
	done
	;;
get)
	[ -e "\$K/\$2.pass" ] || exit 1
	if [ -e "\$K/\$2.deny" ]; then echo "BootUnlock: access denied (stand-in)" >&2; exit 4; fi
	cat "\$K/\$2.pass"
	;;
set)
	[ -e "\$K/\$2.foreign" ] && exit 5
	cat > "\$K/\$2.pass"
	printf '%s' "\$3" > "\$K/\$2.label"
	rm -f "\$K/\$2.deny"
	;;
delete)
	[ -e "\$K/\$2.pass" ] || exit 1
	rm -f "\$K/\$2.pass" "\$K/\$2.label" "\$K/\$2.deny"
	;;
esac
EOF
	cat > "$SB/stubs/osascript" << EOF
#!/bin/bash
{ printf 'osascript'; printf ' [%s]' "\$@"; printf '\n'; } >> "$SB/calls.log"
case "\$*" in
*ui-alert.applescript*) printf '%s\n' "\$*" >> "$SB/alerts.log"; exit 0 ;;
*ui-elevate.applescript*) printf 'ELEVATE %s\n' "\$*" >> "$SB/alerts.log"; exit 0 ;;
esac
head -1 "$SB/osascript.queue"
tail -n +2 "$SB/osascript.queue" > "$SB/osascript.queue.new"
mv "$SB/osascript.queue.new" "$SB/osascript.queue"
EOF
	cat > "$SB/stubs/launchctl" << EOF
#!/bin/bash
printf 'launchctl %s\n' "\$*" >> "$SB/calls.log"
case \$1 in
print) [ -e "$SB/launchd.loaded" ] ;;
bootout) rm -f "$SB/launchd.loaded" ;;
bootstrap) : > "$SB/launchd.loaded" ;;
esac
EOF
	cat > "$SB/stubs/df" << EOF
#!/bin/bash
echo "Filesystem 512-blocks Used Available Capacity Mounted on"
case "\$*" in
*Data*) echo "/dev/disk3s5 1 1 1 1% /System/Volumes/Data" ;;
*) echo "/dev/disk3s1s1 1 1 1 1% /" ;;
esac
EOF
	printf '#!/bin/bash\nprintf "pkgutil %%s\\n" "$*" >> "%s/calls.log"\n' "$SB" > "$SB/stubs/pkgutil"
	printf '#!/bin/bash\necho "{ sec = $(cat "%s/boottime"), usec = 0 } Wed Nov 25 10:00:00 2026"\n' "$SB" > "$SB/stubs/sysctl"
	printf '#!/bin/bash\ncat "%s/console-user" 2>/dev/null || echo root\n' "$SB" > "$SB/stubs/stat"
	printf '#!/bin/bash\nif [ "${1:-}" = -u ]; then cat "%s/uid" 2>/dev/null || echo 0; else /usr/bin/id "$@"; fi\n' "$SB" > "$SB/stubs/id"
	printf '#!/bin/bash\nexit 0\n' > "$SB/stubs/chown"
	chmod 0755 "$SB/stubs/"* "$APP/BootUnlock"
}

# volume UUID DEVICE ENCRYPTED LOCKED ROLE NAME: one <dict> of the plist.
# NAME is XML text, so "&#10;" is a line break inside a name.
volume() {
	printf '<dict><key>APFSVolumeUUID</key><string>%s</string><key>DeviceIdentifier</key><string>%s</string><key>Encryption</key><%s/><key>Locked</key><%s/><key>Name</key><string>%s</string><key>Roles</key><array>%s</array></dict>\n' \
		"$1" "$2" "$3" "$4" "$6" "${5:+<string>$5</string>}"
}
# plist FILE: wraps the <dict>s on standard input into "diskutil apfs list -plist" output.
plist() {
	{
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
			'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
			'<plist version="1.0"><dict><key>Containers</key><array><dict>' \
			'<key>ContainerReference</key><string>disk9</string>' \
			'<key>PhysicalStores</key><array><dict><key>DeviceIdentifier</key><string>disk0s2</string></dict></array>' \
			'<key>Volumes</key><array>'
		cat
		printf '%s\n' '</array></dict></array></dict></plist>'
	} > "$1"
}
system_volumes() {
	volume 11111111-1111-1111-1111-111111111111 disk3s1 true false System "Macintosh HD"
	volume 22222222-2222-2222-2222-222222222222 disk3s5 true false Data "Data"
	volume 33333333-3333-3333-3333-333333333333 disk3s2 false false Preboot "Preboot"
}
# fixtures: basic (EXT and Other locked), absent (EXT not attached), hostile (crafted names).
fixtures() {
	{
		system_volumes
		volume "$EXT" disk5s1 true true "" "EXT"
		volume "$OTHER" disk5s2 true true "" "Other"
		volume 44444444-4444-4444-4444-444444444444 disk7s1 true true Backup "Time Machine"
		volume 55555555-5555-5555-5555-555555555555 disk3s7 true false "" "Home"
	} | plist "$SB/basic.plist"
	{
		# A diskutil that reports no roles: the boot volumes are then told apart by device.
		volume 11111111-1111-1111-1111-111111111111 disk3s1 true false "" "Macintosh HD"
		volume 22222222-2222-2222-2222-222222222222 disk3s5 true false "" "Data"
		volume "$EXT" disk5s1 true true "" "EXT"
	} | plist "$SB/noroles.plist"
	{
		system_volumes
		volume "$OTHER" disk5s2 true true "" "Other"
	} | plist "$SB/absent.plist"
	{
		system_volumes
		volume "$EXT" disk5s1 true true "" "EXT"
		volume "$OTHER" disk6s1 true true "" "Colon:$EXT:disk9s9"
		volume CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC disk6s2 true true "" "Newline:$EXT:disk9s9:true:true&#10;Tail"
		volume DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD disk6s3 true true "" 'x"]; var proof = "executed"; ["'
		volume EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE disk6s4 true true "" 'it'"'"'s $(touch PWNED) `touch PWNED2`'
		volume not-a-uuid disk6s5 true true "" "Bad UUID"
		volume FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF 'disk7s1; touch PWNED3' true true "" "Bad device"
	} | plist "$SB/hostile.plist"
	echo "$SB/basic.plist" > "$SB/fixture.current"
	printf '%s' "$SECRET" > "$SB/volumes/disk5s1"
	printf '%s' 'other-secret' > "$SB/volumes/disk5s2"
	printf '%s' 'hostile-secret' > "$SB/volumes/disk6s4"
}
use_fixture() { echo "$SB/$1.plist" > "$SB/fixture.current"; }
enrol() { # UUID LABEL PASSPHRASE
	printf '%s' "$3" > "$SB/keychain/$1.pass"
	printf '%s' "$2" > "$SB/keychain/$1.label"
}
answers() { printf '%s\n' "$@" > "$SB/osascript.queue"; }
run_helper() { (cd "$SB/cwd" && /bin/bash "$APP/helper.sh" >> "$SB/log" 2>&1); }
run_update() { (cd "$SB/cwd" && /bin/bash "$APP/update.sh" > /dev/null 2>&1); }
no_secret_in_arguments() {
	hasnt "$SB/calls.log" "$SECRET" && hasnt "$SB/calls.log" 'other-secret' \
		&& hasnt "$SB/calls.log" 'hostile-secret' && hasnt "$SB/calls.log" 'wrong-guess'
}
nothing_executed() { [ -z "$(find "$SB" "$ROOT/files" -name 'PWNED*' 2> /dev/null)" ]; }

# --- syntax --------------------------------------------------------------------

section "Syntax"
for script in build/build.sh files/common.sh files/helper.sh files/update.sh files/uninstall.sh scripts/postinstall tests/run.sh tests/keychain-test.sh tests/dry-run.sh; do
	check "bash parses $script" /bin/bash -n "$ROOT/$script"
done
mkdir -p "$SANDBOX/osa"
check "ui-choose.js compiles" osacompile -l JavaScript -o "$SANDBOX/osa/choose.scpt" "$ROOT/files/ui-choose.js"
check "ui-passphrase.js compiles" osacompile -l JavaScript -o "$SANDBOX/osa/passphrase.scpt" "$ROOT/files/ui-passphrase.js"
check "ui-alert.applescript compiles" osacompile -o "$SANDBOX/osa/alert.scpt" "$ROOT/files/ui-alert.applescript"
check "ui-elevate.applescript compiles" osacompile -o "$SANDBOX/osa/elevate.scpt" "$ROOT/files/ui-elevate.applescript"
printf 'function run(argv) { return JSON.stringify(argv) }\n' > "$SANDBOX/osa/echo.js"
check "the real osascript hands hostile text to a script file as plain arguments" \
	test "$(/usr/bin/osascript -l JavaScript "$SANDBOX/osa/echo.js" '-dash' 'x"]; evil(); ["' 2> /dev/null)" = '["-dash","x\"]; evil(); [\""]'

# --- volume list ---------------------------------------------------------------

section "Volume list (diskutil.xsl and list_volumes)"
setup
fixtures
use_fixture hostile
(
	BOOTUNLOCK_DIR=$APP
	LOG_TAG=test
	. "$APP/common.sh"
	cd "$SB/cwd" && list_volumes
) > "$SB/listed" 2> "$SB/listed.err"
cat > "$SB/expected" << EOF
11111111-1111-1111-1111-111111111111:disk3s1:true:false:System:Macintosh HD
22222222-2222-2222-2222-222222222222:disk3s5:true:false:Data:Data
33333333-3333-3333-3333-333333333333:disk3s2:false:false:Preboot:Preboot
$EXT:disk5s1:true:true::EXT
$OTHER:disk6s1:true:true::Colon:$EXT:disk9s9
CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC:disk6s2:true:true::Newline:$EXT:disk9s9:true:true Tail
DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD:disk6s3:true:true::x"]; var proof = "executed"; ["
EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE:disk6s4:true:true::it's \$(touch PWNED) \`touch PWNED2\`
EOF
check "crafted names cannot add fields or lines; malformed UUID and device are dropped" diff "$SB/expected" "$SB/listed"
check "xsltproc needed neither the network nor the DTD" test ! -s "$SB/listed.err"

# --- helper.sh -----------------------------------------------------------------

section "helper.sh"
setup
fixtures
run_helper
check "nothing enrolled: diskutil is not even asked" hasnt "$SB/calls.log" "diskutil"

setup
fixtures
enrol "$EXT" EXT "$SECRET"
run_helper
check "enrolled and locked: unlocked by device, passphrase on standard input" \
	has "$SB/stdin.log" "unlock disk5s1 | apfs unlock disk5s1 -stdinpassphrase | stdin=$SECRET"
check "only the enrolled volume is touched" count_is "$SB/stdin.log" "unlock " 1
check "the log reports it" has "$SB/log" "volume 'EXT' is unlocked"
check "no passphrase in any argument list" no_secret_in_arguments

setup
fixtures
use_fixture hostile
enrol "$EXT" EXT "$SECRET"
run_helper
check "crafted names: exactly one unlock, of the real device" count_is "$SB/stdin.log" "unlock " 1
check "crafted names: the device a name asked for is never used" hasnt "$SB/stdin.log" "disk9s9 |"
check "crafted names: nothing was executed" nothing_executed

setup 4 0
fixtures
enrol "$EXT" EXT wrong-guess
rm -f "$SB/state/boot"
run_helper
run_helper
run_helper
check "wrong stored passphrase: three attempts, then never again" count_is "$SB/stdin.log" "unlock disk5s1" 3
check "the log says the volume is left alone" has "$SB/log" "is left alone from now on"
check "the failure count survives between runs" test "$(cut -d' ' -f1 "$SB/state/failed/$EXT")" = 3

setup
fixtures
enrol "$EXT" EXT "$SECRET"
: > "$SB/keychain/$EXT.deny"
run_helper
check "keychain refuses the helper: reported as such, not as a missing entry" has "$SB/log" "did not release the passphrase"
check "keychain refuses the helper: no unlock attempt" count_is "$SB/stdin.log" "unlock " 0

setup 6 0
fixtures
enrol "$EXT" EXT "$SECRET"
rm -f "$SB/state/boot"
printf '%s\n' FAIL "$SB/absent.plist" "$SB/absent.plist" "$SB/basic.plist" > "$SB/fixture.queue"
run_helper
check "first run since startup: waits for diskutil and for a volume that shows up late" \
	has "$SB/stdin.log" "unlock disk5s1 | apfs unlock disk5s1 -stdinpassphrase | stdin=$SECRET"
check "the wait is logged once" count_is "$SB/log" "diskutil cannot list the APFS volumes" 1

setup
fixtures
use_fixture absent
enrol "$EXT" EXT "$SECRET"
started=$(date +%s)
run_helper
check "later runs: an absent volume is not waited for" test $(($(date +%s) - started)) -le 2
check "later runs: one look only" count_is "$SB/calls.log" "diskutil apfs list" 1

# --- update.sh -----------------------------------------------------------------

section "update.sh"
setup
fixtures
answers "OK 0" "$SECRET"
run_update
check "offers EXT and Other" has "$SB/calls.log" "[0] [disk5s1 > EXT] [0] [disk5s2 > Other]"
check "offers an ordinary encrypted volume in the startup disk's container (a home volume)" \
	has "$SB/calls.log" "[0] [disk3s7 > Home]"
check "does not offer the system and data volumes" hasnt "$SB/calls.log" "Macintosh HD"
check "does not offer a volume with a role (Time Machine)" hasnt "$SB/calls.log" "Time Machine"
check "runs the static chooser file, with labels as arguments" \
	has "$SB/calls.log" "osascript [-l] [JavaScript] [$APP/ui-choose.js] [0] [disk5s1 > EXT]"
check "checks the passphrase against the volume without unlocking it" \
	has "$SB/stdin.log" "unlock disk5s1 | apfs unlock disk5s1 -stdinpassphrase -verify -user $EXT | stdin=$SECRET"
check "stores the passphrase through the helper's standard input" test "$(cat "$SB/keychain/$EXT.pass")" = "$SECRET"
check "does not enrol the volume that was not chosen" test ! -e "$SB/keychain/$OTHER.pass"
check "no passphrase in any argument list" no_secret_in_arguments
check "no sudo and no /usr/bin/security anywhere" hasnt "$APP/update.sh" "security "
check "ends by telling the user what is enrolled" has "$SB/alerts.log" "BootUnlock unlocks these volumes at startup"

setup
fixtures
use_fixture noroles
answers "CANCEL"
run_update
check "without role information the volumes macOS runs from are still left out" \
	test "$(grep -c 'ui-choose.js' "$SB/calls.log")" = 1 -a "$(grep -c 'Macintosh HD\|> Data' "$SB/calls.log")" = 0

setup
fixtures
answers "OK 0" wrong-guess wrong-guess wrong-guess "$SECRET"
run_update
check "wrong passphrase: asks three times, then gives up" count_is "$SB/stdin.log" "unlock disk5s1" 3
check "wrong passphrase: nothing is stored" test ! -e "$SB/keychain/$EXT.pass"
check "wrong passphrase: still not in any argument list" no_secret_in_arguments

setup
fixtures
answers "OK 0 1" "" other-secret
run_update
check "Skip on one volume carries on with the next" test "$(cat "$SB/keychain/$OTHER.pass" 2> /dev/null)" = other-secret
check "the skipped volume is not enrolled" test ! -e "$SB/keychain/$EXT.pass"

setup
fixtures
enrol "$EXT" EXT "$SECRET"
answers "OK"
run_update
check "an enrolled volume is preselected in the chooser" has "$SB/calls.log" "[1] [disk5s1 > EXT]"
check "unselecting a volume removes its passphrase" test ! -e "$SB/keychain/$EXT.pass"
check "the summary then says nothing is enrolled" has "$SB/alerts.log" "No volume is enrolled"

setup
fixtures
enrol "$EXT" EXT "$SECRET"
answers "CANCEL"
run_update
check "Cancel changes nothing" test "$(cat "$SB/keychain/$EXT.pass")" = "$SECRET"

setup
fixtures
enrol "$EXT" EXT "$SECRET"
echo "3 1" > "$SB/state/failed/$EXT"
answers "OK 0" "must-not-be-asked"
run_update
check "an enrolled volume whose passphrase still fits is kept without asking" has "$SB/osascript.queue" "must-not-be-asked"
check "re-running the enrolment lifts the helper's suspension" test ! -e "$SB/state/failed/$EXT"

setup
fixtures
enrol "$EXT" EXT "$SECRET"
: > "$SB/keychain/$EXT.deny"
answers "OK 0" "$SECRET"
run_update
check "after an upgrade (entry unreadable) it asks again and stores afresh" \
	test "$(cat "$SB/keychain/$EXT.pass")" = "$SECRET" -a ! -e "$SB/keychain/$EXT.deny"

setup
fixtures
: > "$SB/keychain/$EXT.foreign"
answers "OK 0" "$SECRET"
run_update
check "an entry BootUnlock did not create is left alone and explained" has "$SB/alerts.log" "BootUnlock did not create"

setup
fixtures
use_fixture hostile
answers "OK 4" hostile-secret
run_update
check "crafted names reach the dialogs as arguments, verbatim" \
	has "$SB/calls.log" '[disk6s3 > x"]; var proof = "executed"; ["]'
check "a volume with a crafted name can still be enrolled" test "$(cat "$SB/keychain/EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE.pass" 2> /dev/null)" = hostile-secret
check "its name is stored as the label, verbatim" \
	test "$(cat "$SB/keychain/EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE.label" 2> /dev/null)" = 'it'"'"'s $(touch PWNED) `touch PWNED2`'
check "crafted names: nothing was executed" nothing_executed

setup
fixtures
echo 501 > "$SB/uid"
run_update
check "without root it asks for administrator rights and does nothing else" \
	test "$(grep -c . "$SB/calls.log")" = 1 -a "$(grep -c "ELEVATE $APP/ui-elevate.applescript $APP/update.sh" "$SB/alerts.log")" = 1

# --- uninstall.sh ----------------------------------------------------------------

section "uninstall.sh"
setup
fixtures
enrol "$EXT" EXT "$SECRET"
enrol "$OTHER" Other other-secret
: > "$SB/LaunchDaemons/au.com.openwall.BootUnlock.plist"
: > "$SB/etc/newsyslog.d/au.com.openwall.BootUnlock.conf"
: > "$SB/log.0.bz2"
: > "$SB/launchd.loaded"
(cd "$SB/cwd" && /bin/bash "$APP/uninstall.sh" > "$SB/uninstall.out" 2>&1)
check "stops the daemon" has "$SB/calls.log" "launchctl bootout system/au.com.openwall.BootUnlock"
check "removes every stored passphrase" test -z "$(ls "$SB/keychain")"
check "removes the daemon definition, rotation rule, log, archives and state" \
	test ! -e "$SB/LaunchDaemons/au.com.openwall.BootUnlock.plist" -a ! -e "$SB/etc/newsyslog.d/au.com.openwall.BootUnlock.conf" \
	-a ! -e "$SB/log" -a ! -e "$SB/log.0.bz2" -a ! -e "$SB/state"
check "forgets the installer receipt" has "$SB/calls.log" "pkgutil --forget au.com.openwall.BootUnlock"
check "removes the installed files" test ! -e "$APP"
check "leaves everything else alone" test -d "$SB/stubs" -a -d "$SB/volumes"
check "reports success" has "$SB/uninstall.out" "BootUnlock is removed."

# --- postinstall -----------------------------------------------------------------

section "postinstall"
setup
fixtures
sed "s|^BOOTUNLOCK_DIR=.*|BOOTUNLOCK_DIR=$APP|" "$ROOT/scripts/postinstall" > "$SB/postinstall"
: > "$SB/launchd.loaded"
echo someone > "$SB/console-user"
answers "CANCEL"
started=$(date +%s)
(cd "$SB/cwd" && /bin/bash "$SB/postinstall" > /dev/null 2>&1)
status=$?
check "exits successfully" test "$status" = 0
check "returns without waiting for the enrolment" test $(($(date +%s) - started)) -le 3
check "the daemon definition is a valid property list" plutil -lint "$SB/LaunchDaemons/au.com.openwall.BootUnlock.plist"
check "the daemon runs helper.sh at load and on mount" \
	test "$(plutil -extract Program raw "$SB/LaunchDaemons/au.com.openwall.BootUnlock.plist")" = "$APP/helper.sh" \
	-a "$(plutil -extract RunAtLoad raw "$SB/LaunchDaemons/au.com.openwall.BootUnlock.plist")" = true \
	-a "$(plutil -extract StartOnMount raw "$SB/LaunchDaemons/au.com.openwall.BootUnlock.plist")" = true
check "an old daemon is removed before the new one is loaded" \
	test "$(grep -n -E 'launchctl (bootout|bootstrap)' "$SB/calls.log" | cut -d' ' -f2 | tr '\n' ' ')" = "bootout bootstrap "
check "the helper is executable by its owner only" test "$(/usr/bin/stat -f %Lp "$APP/BootUnlock")" = 100
check "the log is not readable by everybody" test "$(/usr/bin/stat -f %Lp "$SB/log")" = 640
check "the log rotation rule is installed" has "$SB/etc/newsyslog.d/au.com.openwall.BootUnlock.conf" "$SB/log"
for _ in 1 2 3 4 5 6; do
	if has "$SB/log" "update["; then break; fi
	sleep 0.5
done
check "the enrolment was started in the background" has "$SB/log" "update["
sleep 1
chmod 0755 "$APP/BootUnlock"

setup
fixtures
sed "s|^BOOTUNLOCK_DIR=.*|BOOTUNLOCK_DIR=$APP|" "$ROOT/scripts/postinstall" > "$SB/postinstall"
(cd "$SB/cwd" && /bin/bash "$SB/postinstall" > /dev/null 2>&1)
check "nobody at the screen: no enrolment, and the log says how to start it" has "$SB/log" "nobody is logged in at the screen"
chmod 0755 "$APP/BootUnlock"

# --- the built helper and package ---------------------------------------------------

section "Built helper and package (out/, from \"make\")"
if [ -x "$ROOT/out/BootUnlock" ]; then
	"$ROOT/out/BootUnlock" list > "$SANDBOX/helper.out" 2>&1
	check "the helper refuses to work for a user who is not root (exit status 3)" test "$?" = 3
	check "the helper is signed with the hardened runtime" \
		sh -c "codesign -d -vvv '$ROOT/out/BootUnlock' 2>&1 | grep -q 'flags=.*runtime'"
	check "its designated requirement is its code hash, not an identifier" \
		sh -c "codesign -d --requirements - '$ROOT/out/BootUnlock' 2>&1 | grep -q '^# designated => cdhash' && ! codesign -d --requirements - '$ROOT/out/BootUnlock' 2>&1 | grep -q 'identifier \"'"
	mkdir -p "$SANDBOX/inject"
	if clang -dynamiclib -o "$SANDBOX/inject/probe.dylib" "$TESTS/inject-probe.c" 2> /dev/null; then
		cp "$ROOT/out/BootUnlock" "$SANDBOX/inject/soft"
		codesign -f -s - "$SANDBOX/inject/soft" 2> /dev/null
		DYLD_INSERT_LIBRARIES="$SANDBOX/inject/probe.dylib" "$SANDBOX/inject/soft" list > "$SANDBOX/inject/soft.out" 2>&1
		check "control: without the hardened runtime a foreign library does get in" has "$SANDBOX/inject/soft.out" INJECTED
		DYLD_INSERT_LIBRARIES="$SANDBOX/inject/probe.dylib" "$ROOT/out/BootUnlock" list > "$SANDBOX/inject/hard.out" 2>&1
		check "the shipped helper ignores DYLD_INSERT_LIBRARIES" hasnt "$SANDBOX/inject/hard.out" INJECTED
	else
		no "could not compile the injection probe"
	fi
else
	printf '  skip  no out/BootUnlock; run "make" first\n'
fi

PKG=$(ls "$ROOT"/out/BootUnlock-*.pkg 2> /dev/null | head -1)
if [ -n "$PKG" ]; then
	pkgutil --expand-full "$PKG" "$SANDBOX/pkg" > /dev/null 2>&1
	check "the package declares arm64, so the installer does not need Rosetta" \
		grep -q 'hostArchitectures="[^"]*arm64' "$SANDBOX/pkg/Distribution"
	check "the package contains exactly the expected payload" \
		test "$(cd "$SANDBOX"/pkg/*.pkg/Payload && ls | tr '\n' ' ')" = "BootUnlock common.sh diskutil.xsl helper.sh ui-alert.applescript ui-choose.js ui-elevate.applescript ui-passphrase.js uninstall.sh update.sh "
	check "the packaged scripts are the ones in files/ and scripts/" \
		sh -c "for f in common.sh diskutil.xsl helper.sh update.sh uninstall.sh ui-choose.js ui-passphrase.js ui-alert.applescript ui-elevate.applescript; do cmp -s '$SANDBOX'/pkg/*.pkg/Payload/\$f '$ROOT'/files/\$f || exit 1; done; cmp -s '$SANDBOX'/pkg/*.pkg/Scripts/postinstall '$ROOT/scripts/postinstall'"
	check "the packaged helper is out/BootUnlock" cmp -s "$SANDBOX"/pkg/*.pkg/Payload/BootUnlock "$ROOT/out/BootUnlock"
	check "everything installs as root:wheel and nothing is writable by group or others" \
		sh -c "lsbom -p MUG '$SANDBOX'/pkg/*.pkg/Bom | awk '\$2 != \"root\" || \$3 != \"wheel\" || substr(\$1, 6, 1) == \"w\" || substr(\$1, 9, 1) == \"w\" { bad = 1 } END { exit bad }'"
else
	printf '  skip  no package in out/; run "make" first\n'
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
