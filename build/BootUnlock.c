/*
 * BootUnlock keychain helper.
 *
 * Stores, reads and removes the passphrases of encrypted APFS volumes in the
 * System keychain on behalf of the BootUnlock scripts:
 *
 *   BootUnlock get UUID          print the passphrase of volume UUID
 *   BootUnlock set UUID LABEL    store the passphrase read from standard input
 *   BootUnlock delete UUID       remove the entry of volume UUID
 *   BootUnlock list              print "UUID<TAB>LABEL" for every entry
 *
 * Exit status: 0 success, 1 no such entry, 2 usage error, 3 not root,
 * 4 keychain error (explained on standard error), 5 an entry for the volume
 * exists that BootUnlock did not create.
 *
 * Security model
 * --------------
 * 1. Every entry carries an access control list that trusts exactly one
 *    program: this one.  "set" builds that list itself by asking for a
 *    reference to "the calling program", so no path or identifier that
 *    somebody else could claim is involved.  The binary is ad-hoc signed with
 *    codesign's default designated requirement, which is its own code
 *    directory hash, so the list pins this exact build (see build/build.sh).
 *    Every rebuild therefore needs a new enrolment (files/update.sh).
 *
 * 2. Pinning the build is not enough on its own: a copy of this build
 *    satisfies the access list wherever the copy lives and whoever runs it,
 *    and the build can be reproduced from the public source.  Two more
 *    measures close that gap, and both are required:
 *      - the program refuses to do anything unless it runs as root;
 *      - it is signed with the hardened runtime (build/build.sh), so the
 *        dynamic loader ignores DYLD_INSERT_LIBRARIES and other users cannot
 *        attach to it, which is how the root check could otherwise be
 *        bypassed inside a process that still carries the trusted hash.
 *
 * 3. It never asks the user anything.  Keychain user interaction is switched
 *    off, so a mismatch between this build and an entry is an error on
 *    standard error instead of a prompt nobody can answer at startup.
 *
 * 4. Passphrases travel over standard input and standard output only.  They
 *    never appear in an argument list, where other users (ps) and the sudo
 *    log could see them.
 *
 * 5. It only touches entries it created, recognised by ITEM_COMMENT.  macOS
 *    itself keeps entries of the same kind in the System keychain (Time
 *    Machine, for example) and those are left alone.
 *
 * The System keychain is a file-based keychain.  The only programming
 * interface that reaches a specific file-based keychain is the SecKeychain
 * family, which Apple has marked as deprecated since macOS 10.10 without
 * providing a replacement, hence the pragma below.
 */

#define __STDC_WANT_LIB_EXT1__ 1

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/*
 * Test builds only (tests/keychain-test.sh): BOOTUNLOCK_TEST_KEYCHAIN points
 * the helper at a scratch keychain and lifts the root requirement.  Such a
 * build has a different code hash than the shipped helper, so no real entry
 * trusts it.
 */
#ifdef BOOTUNLOCK_TEST_KEYCHAIN
#define KEYCHAIN_PATH BOOTUNLOCK_TEST_KEYCHAIN
#else
#define KEYCHAIN_PATH "/Library/Keychains/System.keychain"
#endif

/* The kind macOS itself uses for volume passphrases. */
#define ITEM_KIND "Encrypted Volume Password"
/* Marks the entries this program created. */
#define ITEM_COMMENT "Managed by BootUnlock (au.com.openwall.BootUnlock)"

#define MAX_PASSPHRASE 1024

enum {
	RC_OK = 0,
	RC_NOT_FOUND = 1,
	RC_USAGE = 2,
	RC_NOT_ROOT = 3,
	RC_KEYCHAIN = 4,
	RC_FOREIGN = 5
};

static int usage(void) {
	fprintf(stderr,
		"usage: BootUnlock get UUID\n"
		"       BootUnlock set UUID LABEL   (passphrase on standard input)\n"
		"       BootUnlock delete UUID\n"
		"       BootUnlock list\n");
	return RC_USAGE;
}

/* 8-4-4-4-12 hexadecimal digits, the form diskutil prints. */
static bool valid_uuid(const char *s) {
	if (strlen(s) != 36) {
		return false;
	}
	for (int i = 0; i < 36; i++) {
		if (i == 8 || i == 13 || i == 18 || i == 23) {
			if (s[i] != '-') {
				return false;
			}
		} else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= 'A' && s[i] <= 'F'))) {
			return false;
		}
	}
	return true;
}

static int keychain_error(const char *what, OSStatus status) {
	char text[256] = "no description available";
	CFStringRef message = SecCopyErrorMessageString(status, NULL);
	if (message) {
		CFStringGetCString(message, text, sizeof text, kCFStringEncodingUTF8);
		CFRelease(message);
	}
	fprintf(stderr, "BootUnlock: %s: %s (OSStatus %d)\n", what, text, (int)status);
	if (status == errSecInteractionNotAllowed || status == errSecAuthFailed) {
		fprintf(stderr,
			"BootUnlock: the keychain entry was created for a different build of this helper; "
			"run update.sh to enrol the volume again\n");
	}
	return RC_KEYCHAIN;
}

static CFStringRef cfstring(const char *s) {
	return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

/*
 * A query for generic passwords in the given keychain only.  With uuid, it is
 * narrowed to the entry of that volume; with managed, to entries this program
 * created.
 */
static CFMutableDictionaryRef new_query(SecKeychainRef keychain, CFStringRef uuid, bool managed) {
	CFMutableDictionaryRef query = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFArrayRef searchList = CFArrayCreate(kCFAllocatorDefault, (const void **)&keychain, 1, &kCFTypeArrayCallBacks);
	CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(query, kSecMatchSearchList, searchList);
	CFRelease(searchList);
	if (uuid) {
		CFDictionarySetValue(query, kSecAttrService, uuid);
		CFDictionarySetValue(query, kSecAttrAccount, uuid);
	}
	if (managed) {
		CFDictionarySetValue(query, kSecAttrDescription, CFSTR(ITEM_KIND));
		CFDictionarySetValue(query, kSecAttrComment, CFSTR(ITEM_COMMENT));
	}
	return query;
}

static int cmd_get(SecKeychainRef keychain, CFStringRef uuid) {
	CFMutableDictionaryRef query = new_query(keychain, uuid, true);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);

	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching(query, &result);
	CFRelease(query);
	if (status == errSecItemNotFound) {
		return RC_NOT_FOUND;
	}
	if (status != errSecSuccess || !result || CFGetTypeID(result) != CFDataGetTypeID()) {
		if (result) {
			CFRelease(result);
		}
		return keychain_error("cannot read the keychain entry", status);
	}

	CFDataRef data = (CFDataRef)result;
	size_t length = (size_t)CFDataGetLength(data);
	int rc = RC_OK;
	if (fwrite(CFDataGetBytePtr(data), 1, length, stdout) != length || fflush(stdout) != 0) {
		fprintf(stderr, "BootUnlock: cannot write the passphrase to standard output\n");
		rc = RC_KEYCHAIN;
	}
	CFRelease(result);
	return rc;
}

static int cmd_delete(SecKeychainRef keychain, CFStringRef uuid) {
	CFMutableDictionaryRef query = new_query(keychain, uuid, true);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
	CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);

	CFTypeRef item = NULL;
	OSStatus status = SecItemCopyMatching(query, &item);
	CFRelease(query);
	if (status == errSecItemNotFound) {
		return RC_NOT_FOUND;
	}
	if (status != errSecSuccess || !item) {
		return keychain_error("cannot find the keychain entry", status);
	}

	/* Delete that one item, rather than "whatever matches a query". */
	status = SecKeychainItemDelete((SecKeychainItemRef)item);
	CFRelease(item);
	if (status != errSecSuccess) {
		return keychain_error("cannot delete the keychain entry", status);
	}
	return RC_OK;
}

static void print_field(CFDictionaryRef attributes, CFStringRef key, char *buffer, size_t size) {
	buffer[0] = '\0';
	CFTypeRef value = CFDictionaryGetValue(attributes, key);
	if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
		if (!CFStringGetCString((CFStringRef)value, buffer, (CFIndex)size, kCFStringEncodingUTF8)) {
			buffer[0] = '\0';
		}
	}
}

static int cmd_list(SecKeychainRef keychain) {
	CFMutableDictionaryRef query = new_query(keychain, NULL, true);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitAll);
	CFDictionarySetValue(query, kSecReturnAttributes, kCFBooleanTrue);

	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching(query, &result);
	CFRelease(query);
	if (status == errSecItemNotFound) {
		return RC_OK;
	}
	if (status != errSecSuccess || !result || CFGetTypeID(result) != CFArrayGetTypeID()) {
		if (result) {
			CFRelease(result);
		}
		return keychain_error("cannot list the keychain entries", status);
	}

	CFArrayRef items = (CFArrayRef)result;
	for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
		CFTypeRef entry = CFArrayGetValueAtIndex(items, i);
		if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) {
			continue;
		}
		char uuid[64], label[1024];
		print_field((CFDictionaryRef)entry, kSecAttrAccount, uuid, sizeof uuid);
		print_field((CFDictionaryRef)entry, kSecAttrLabel, label, sizeof label);
		if (!valid_uuid(uuid)) {
			continue;
		}
		/* The label is a volume name: keep it on one line and in one field. */
		for (char *p = label; *p; p++) {
			if ((unsigned char)*p < 0x20 || *p == 0x7f) {
				*p = ' ';
			}
		}
		printf("%s\t%s\n", uuid, label);
	}
	CFRelease(result);
	return RC_OK;
}

static int cmd_set(SecKeychainRef keychain, CFStringRef uuid, const char *labelText) {
	unsigned char passphrase[MAX_PASSPHRASE + 1];
	int rc = RC_KEYCHAIN;
	OSStatus status;
	CFStringRef label = NULL;
	CFDataRef secret = NULL;
	SecTrustedApplicationRef self = NULL;
	CFArrayRef trusted = NULL;
	SecAccessRef access = NULL;
	CFMutableDictionaryRef item = NULL;

	size_t length = fread(passphrase, 1, sizeof passphrase, stdin);
	if (ferror(stdin) || length == 0 || length > MAX_PASSPHRASE) {
		fprintf(stderr, "BootUnlock: expected a passphrase of 1 to %d bytes on standard input\n", MAX_PASSPHRASE);
		rc = RC_USAGE;
		goto done;
	}

	label = cfstring(labelText);
	if (!label) {
		label = CFRetain(uuid);
	}

	/* The access list: this program and nothing else (NULL means "myself"). */
	status = SecTrustedApplicationCreateFromPath(NULL, &self);
	if (status != errSecSuccess || !self) {
		rc = keychain_error("cannot create a reference to this helper", status);
		goto done;
	}
	trusted = CFArrayCreate(kCFAllocatorDefault, (const void **)&self, 1, &kCFTypeArrayCallBacks);
	status = SecAccessCreate(label, trusted, &access);
	if (status != errSecSuccess || !access) {
		rc = keychain_error("cannot create the access control list", status);
		goto done;
	}

	/* Replace our own entry.  An existing access list cannot be changed without a prompt. */
	rc = cmd_delete(keychain, uuid);
	if (rc != RC_OK && rc != RC_NOT_FOUND) {
		goto done;
	}
	rc = RC_KEYCHAIN;

	secret = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, passphrase, (CFIndex)length, kCFAllocatorNull);
	item = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(item, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(item, kSecUseKeychain, keychain);
	CFDictionarySetValue(item, kSecAttrService, uuid);
	CFDictionarySetValue(item, kSecAttrAccount, uuid);
	CFDictionarySetValue(item, kSecAttrLabel, label);
	CFDictionarySetValue(item, kSecAttrDescription, CFSTR(ITEM_KIND));
	CFDictionarySetValue(item, kSecAttrComment, CFSTR(ITEM_COMMENT));
	CFDictionarySetValue(item, kSecAttrAccess, access);
	CFDictionarySetValue(item, kSecValueData, secret);

	status = SecItemAdd(item, NULL);
	if (status == errSecDuplicateItem) {
		fprintf(stderr,
			"BootUnlock: the keychain already holds an entry for this volume that BootUnlock did not create; "
			"it was left untouched\n");
		rc = RC_FOREIGN;
	} else if (status != errSecSuccess) {
		rc = keychain_error("cannot add the keychain entry", status);
	} else {
		rc = RC_OK;
	}

done:
	memset_s(passphrase, sizeof passphrase, 0, sizeof passphrase);
	if (item) CFRelease(item);
	if (secret) CFRelease(secret);
	if (access) CFRelease(access);
	if (trusted) CFRelease(trusted);
	if (self) CFRelease(self);
	if (label) CFRelease(label);
	return rc;
}

int main(int argc, char *argv[]) {
#ifndef BOOTUNLOCK_TEST_KEYCHAIN
	if (geteuid() != 0) {
		fprintf(stderr, "BootUnlock: this helper only works for root\n");
		return RC_NOT_ROOT;
	}
#endif

	const char *command = argc > 1 ? argv[1] : "";
	bool isGet = strcmp(command, "get") == 0 && argc == 3;
	bool isSet = strcmp(command, "set") == 0 && argc == 4;
	bool isDelete = strcmp(command, "delete") == 0 && argc == 3;
	bool isList = strcmp(command, "list") == 0 && argc == 2;
	if (!isGet && !isSet && !isDelete && !isList) {
		return usage();
	}
	if (!isList && !valid_uuid(argv[2])) {
		fprintf(stderr, "BootUnlock: not a volume UUID: %s\n", argv[2]);
		return RC_USAGE;
	}

	/* Never prompt: fail instead (see point 3 at the top of this file). */
	SecKeychainSetUserInteractionAllowed(false);

	SecKeychainRef keychain = NULL;
	OSStatus status = SecKeychainOpen(KEYCHAIN_PATH, &keychain);
	if (status != errSecSuccess || !keychain) {
		return keychain_error("cannot open " KEYCHAIN_PATH, status);
	}

	int rc;
	if (isList) {
		rc = cmd_list(keychain);
	} else {
		CFStringRef uuid = cfstring(argv[2]);
		if (isGet) {
			rc = cmd_get(keychain, uuid);
		} else if (isSet) {
			rc = cmd_set(keychain, uuid, argv[3]);
		} else {
			rc = cmd_delete(keychain, uuid);
		}
		CFRelease(uuid);
	}
	CFRelease(keychain);
	return rc;
}
