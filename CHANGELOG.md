1.3.4
-----

- The BootUnlock helper is now ad-hoc signed with codesign's default
  designated requirement (the binary's own cdhash) instead of an explicit
  "identifier" requirement.  Previously any ad-hoc signed binary claiming the
  identifier au.com.openwall.BootUnlock satisfied the System keychain ACL and
  could read the volume passphrases; now only the exact installed build can.
  Because the hash changes with every build, update.sh must be re-run after
  upgrading the helper (the installer already does this at the end);
- update.sh now replaces an existing keychain entry instead of updating it in
  place with "-U", since changing the trusted application list of an existing
  item requires an interactive confirmation;
- Removed the "preinstall" check for the Xcode command-line tools.  Since
  1.3.3 the helper is compiled when the package is built, so nothing at
  install time needs them any more (building the package still does).

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
