.PHONY: all test clean

# Builds out/BootUnlock-<version>.pkg (see build/build.sh for the settings).
all:
	@build/build.sh

# Runs the scripts against stand-ins for diskutil, the keychain helper and the
# dialogs.  It touches no disk, no keychain and no launchd job.
test:
	@tests/run.sh

clean:
	rm -rf out
