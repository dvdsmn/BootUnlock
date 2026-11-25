/*
 * Test probe, not part of BootUnlock.  tests/run.sh asks the dynamic loader
 * to put this library into the keychain helper (DYLD_INSERT_LIBRARIES).  If
 * the loader agrees, the line below shows up and the test fails: foreign code
 * would then be running under the helper's trusted code hash.
 */
#include <stdio.h>

__attribute__((constructor)) static void injected(void) {
	fprintf(stderr, "INJECTED\n");
}
