1.3.3.1
-------

Numbered below 1.3.4 on purpose: this is 1.3.3 plus the changes below, and it
should not be confused with a later upstream release.

Upgrading from 1.3.3 or older: the passphrases stored by older versions cannot
be read by the new keychain helper and are not recognised as BootUnlock's.
Remove them in Keychain Access (System keychain, kind "Encrypted Volume
Password") before enrolling the volumes again, or update.sh will report that an
entry it did not create is in the way.

Who can read the stored passphrases:

- The keychain helper is now ad-hoc signed with codesign's default designated
  requirement (the binary's own cdhash) instead of an explicit "identifier"
  requirement.  Previously any ad-hoc signed binary claiming the identifier
  au.com.openwall.BootUnlock satisfied the System keychain ACL and could read
  the volume passphrases;
- Pinning the build is not enough, since a copy of the same build satisfies
  the ACL wherever it is and whoever runs it.  The helper therefore refuses to
  work for anybody but root, and it is signed with the hardened runtime, so the
  root check cannot be bypassed by loading foreign code into a copy of it
  (DYLD_INSERT_LIBRARIES);
- The helper now stores the passphrases itself, reading them from standard
  input, and gives each entry an ACL that trusts only the helper.  update.sh no
  longer calls "sudo security add-generic-password -w PASSPHRASE", which put
  the passphrase into the process list and into sudo's log;
- The helper never prompts.  When an entry does not open for it (after an
  upgrade, typically) it says so, and helper.sh logs that instead of "could
  not find the secret";
- The helper only reads, replaces and removes entries it created.  Entries of
  the same kind made by macOS (Time Machine) are left alone.

Volume names are untrusted input:

- diskutil.xsl prints the fixed fields first and the name last, and the scripts
  validate the UUID and the device identifier.  A volume name containing
  colons or line breaks could make the helper script ask for another volume's
  passphrase and try it on a device chosen by the name;
- The dialogs get volume names as arguments of static script files.  They used
  to be pasted into JavaScript and AppleScript source, where a crafted name was
  executed as root during the enrolment.

Installation:

- The package declares arm64 (hostArchitectures).  Without that the installer
  evaluates the package and runs its scripts under Rosetta 2 on Apple Silicon;
- postinstall starts the enrolment in the background and returns.  It used to
  wait for it, and the installer terminates scripts after ten minutes;
- postinstall replaces a loaded launch daemon with "launchctl bootout" and
  "bootstrap" instead of the legacy "load", and a daemon that cannot be loaded
  right away no longer aborts the installation;
- Removed the "preinstall" check for the Xcode command-line tools.  Since
  1.3.3 the helper is compiled when the package is built, so nothing at
  install time needs them any more (building the package still does);
- Added uninstall.sh, which also removes the stored passphrases.

Unlocking:

- The launch daemon runs the helper script at load (RunAtLoad) as well as on
  mount, and for two minutes after its first run since startup the script
  keeps looking for enrolled volumes that are not attached yet.  A locked
  volume showing up does not cause a mount event;
- After three failed unlocks in a row a volume is left alone until update.sh
  is run again (issue #21).  The retry with a hexadecimal passphrase is gone:
  update.sh only stores passphrases it has verified as typed;
- update.sh preselects the enrolled volumes, keeps those whose stored
  passphrase still fits without asking again, and removes the passphrase of a
  volume that is unselected.  "Skip" skips that volume instead of ending the
  script, and it ends by saying what is enrolled;
- The volumes macOS is running from are recognised again.  On macOS 11 and
  newer the root file system is a snapshot, which the old check never matched,
  so the system volumes were offered for enrolment;
- The log is readable by administrators only, is rotated by newsyslog and no
  longer gets the whole mount table on every mount event.

Build:

- build.sh uses the system's tools by absolute path, stages an explicit list
  of files instead of packaging whatever lies in files/, takes the helper's
  architectures and deployment target from ARCHS and MIN_OS, can sign the
  package (PKG_SIGN_IDENTITY), and prints the hashes of what it built;
- "make test" runs the scripts against stand-ins for diskutil, the keychain
  and the dialogs.

1.3.3
-----

- Replaced the lipo-thinned copy of /usr/bin/security with a small native
  helper (build/BootUnlock.c) built for arm64 and x86_64, so the helper no
  longer needs Rosetta on Apple Silicon Macs.

1.3.2
-----

- Fixed a typo introduced with the previous change to fix an infinite loop.

1.3.1
-----

- Fixed a bug where the installation script went into the infinite loop asking
  the user for volume's password with no way to cancel the activity;
- Hopefully, addressed an issue where the installation script was not waiting
  for Xcode's installation to complete.

1.3.0
-----

- Added support for ARM-based Macs (e.g. Macbook Pro M2);
- Added the "preinstall" script with a check and a conditional installation of
  the Xcode command-line tools;
- changed the way BootUnlock binary is created from /usr/sbin/security, now
  the lipo tool is used to extract the x86_64 part from the universal Mach-O
  binary.  This allows running it with a adhoc signature on the ARM-based Macs.

1.2.1
-----

- Improved debugging output;
- Replaced "grep" and "cut" with "sed" to avoid "grep" triggering an early exit;
- Removed "RunAtLoad" in the service definition, so the helper script is
  triggered only on "mount" events;

1.2.0
-----
- Replaced some calls to "osascript" where AppleScript was hitting new security
  measures introduced in Catalina with JXA (Javascript for Apps).  This should
  enable the package to work on Catalina.

1.1.0
-----
- Switched to (Semantic Versioning)[https://semver.org/] for the package
- Changed the trigger for launching the helper script, now it will be triggered
  on the "mount" event when a new volume is detected.  This allows to eject and
  re-insert the external encrypted APFS volumes and should help with the volumes
  that take a bit of time to be available for macOS to use.
- Cosmetic fixes in the 'postinstall' script.

1.0
---
- Initial release
