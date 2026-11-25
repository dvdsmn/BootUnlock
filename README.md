# BootUnlock
A helper script that unlocks macOS'es encrypted APFS volumes before login

The idea behind this package was to leverage the standard system tools to overcome
the limitation of macOS.  A quick search on the Internet showed that similar tools
were created obviously by developers who are eager to write something up from
scratch.  However, good engineering requires critical thinking and if the problem
can be addressed using the existing tools, then this is the challenge worth
puzzling your head with.  The package is bash scripts around `diskutil`, plus one
small C program that talks to the System keychain.

## Building

Run "make" or "build/build.sh" (the result is the same): a package is going to be
created in the "out" directory.  Building requires the Xcode command-line tools,
because the keychain helper is compiled with clang; installing the resulting
package does not.

The build reads three settings from the environment:

| Setting | Default | Meaning |
|---|---|---|
| `ARCHS` | `x86_64 arm64` | Architectures of the helper.  `ARCHS=arm64 make` builds for Apple Silicon only. |
| `MIN_OS` | `10.15` | Oldest macOS the helper is built for. |
| `PKG_SIGN_IDENTITY` | none | A "Developer ID Installer" identity to sign the package with. |

A package you build yourself is unsigned.  It is installed as root, so build it,
compare the SHA-256 the build prints with the file you are about to open, and
install it in the same sitting.

Alternatively, if you do not want to build the package yourself, you can grab the
premade one from the [releases](../../releases) section here.

To install the package just open it in Finder and follow the installation prompts.

## Use case

The typical usage scenario is the following:

1. One adds a dedicated encrypted APFS volume to hold home directories for the
   normal users on the system (e.g. by going to the Disk Utility application and
   adding a volume over there as an administrator);
2. The newly created volume is manually mounted by the administrator;
3. Then the required home directories need to be moved over to that new volume
   (use Finder as an administrator and drag and drop the folders, this will
   ensure that all the necessary permissions and extended attributes are
   preserved -- you cannot easily copy over a home directory via the Terminal
   application, unfortunately);
4. Now, to modify the home directory for the required users, one need to open
   System Setting (or System Preferences in older macOS versions), find the
   "Users & Groups" section, and after right-clicking on a user account, select
   "Advanced Options ...": there the home directory can be changed to point to
   the new volume;
5. Finally, this is where BootUnlock comes in: to automatically unlock the newly
   created volume for home directories upon the user login, install BootUnlock
   and specify the password for the volume during the installation.

This approach allows you to easily upgrade macOS (or even run different versions
of macOS on different APFS volumes), yet have your user data intact and in one
place.  For example, you may want to trial a new beta of macOS by creating a new
APFS volume, installing the beta over there, then attach the volume with home
directories to that new installation, and update your account in the beta to use
the home directory on that volume: your home will be shared between two versions
of macOS with all the settings preserved.  There is a slight chance that the new
macOS version may make an incompatible change to the preferences which would not
be recognised by the older version, but I was running Yosemite, Big Sur, Catalina,
and Monterey -- switching between them regularly and did not experience any issues.

## How it works

Everything is installed into `/Library/PrivilegedHelperTools/au.com.openwall.BootUnlock`.

| Part | What it does | When it runs |
|---|---|---|
| `update.sh` | Enrolment.  Asks which encrypted volumes to unlock at startup and for their passphrases, checks each passphrase against its volume and stores it in the System keychain.  Removes the passphrase of a volume you unselect. | Started by the installer; run it again to change your choice and after every upgrade. |
| `helper.sh` | Unlocks the enrolled volumes that are locked. | Started by a launch daemon at startup and whenever a volume is mounted. |
| `BootUnlock` | The keychain helper: the only program the stored passphrases open for. | Called by the two scripts above. |
| `uninstall.sh` | Removes all of it, including the stored passphrases. | When you run it. |
| `common.sh`, `diskutil.xsl`, `ui-*` | Shared functions, the reader for `diskutil`'s volume list, the dialogs. | |

The helper script works for two minutes after its first run since startup, so a
disk that takes a while to appear is still unlocked, and afterwards whenever a
volume is mounted.  It gives up on a volume after three failed unlocks in a row
and leaves it alone until `update.sh` is run again: wrong passphrases are
rate-limited by macOS, and on some volumes their number is finite.

The log is `/var/log/BootUnlock.log`.  Administrators can read it, and it is
rotated by `newsyslog`.

## What to know before relying on it

- **The passphrases are only as safe as the startup disk.**  They are stored in
  the System keychain, which macOS can open without anybody typing a password.
  Whoever is root on the Mac, or can read an unencrypted startup disk, can read
  them.  Turn on FileVault for the startup disk, and use a passphrase for the
  volume that you use nowhere else.
- **Enrolled volumes are unlocked for everybody,** as soon as the Mac has
  started, not only for the user whose data is on them.
- **Each keychain entry opens for one build of the keychain helper only,** and
  that program refuses to work for anybody but root.  The entry trusts the
  helper by the hash of its code, which is why every upgrade needs `update.sh`
  to run again (the installer starts it).  `build/BootUnlock.c` explains the
  model in full.
- **Logging in does not wait for the unlock.**  If a home directory is on an
  enrolled volume and the login comes first, the login fails; try again a few
  seconds later.
- BootUnlock only touches the keychain entries it created.  If the System
  keychain already holds a passphrase for a volume (Time Machine keeps its own
  there, for example), BootUnlock leaves it alone and tells you.

## Uninstalling

    sudo /Library/PrivilegedHelperTools/au.com.openwall.BootUnlock/uninstall.sh

This stops and removes the launch daemon, removes the passphrases BootUnlock
stored in the System keychain, its state in `/var/db/BootUnlock`, the log and
its rotation rule, the installed files and the installer receipt.  The volumes
and their passphrases are not changed.

## Testing

| Command | What it does | Side effects |
|---|---|---|
| `make test` | Runs the scripts against stand-ins for `diskutil`, the keychain helper, the dialogs and `launchctl`, including volumes with hostile names. | None. |
| `tests/dry-run.sh` | Shows how the scripts read this Mac's real volume list and which volumes would be offered for enrolment. | None; three read-only queries. |
| `tests/keychain-test.sh` | Runs test builds of the real keychain helper against a scratch keychain, as a normal user. | Creates a scratch keychain file and removes it again; macOS lists it in your keychain search list in between. |
