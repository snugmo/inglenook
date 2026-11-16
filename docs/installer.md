# The installer stick

A stick that installs Inglenook onto a disk of the machine it is plugged into. It boots
a root shell in the *initrd* — one per console, so it works whichever terminal the user
is on: the keyboard console always, the serial one whenever the machine has a serial
port — then `inglenook-install`. It is not needed once the image has
been copied. Secure Boot must be off (the UKI and the addon are unsigned).

## What the stick is

ONE FAT32 partition (any partition type, or no partition table; firmware boots
`\EFI\BOOT\BOOTX64.EFI` from any FAT volume), built by `images/installer/stick.sh <image-ref>`
without root or loop devices (`sfdisk`, `mkfs.vfat`, mtools). The same tree can be extracted
onto any FAT32 drive (`build/installer/tree`).

```
/EFI/BOOT/BOOTX64.EFI                   systemd-boot (the removable-media path)
/EFI/Linux/inglenook.efi                the image's own UKI, unmodified
/loader/addons/10-installer.addon.efi   the installer (below)
/loader/addons/serial-console.addon.efi console= for the stick's own boot (below);
                                        the installer copies it to the installed
                                        system's ESP on request
/inglenook/image.oci.tar.000, .001 ...  the image: `skopeo copy` oci-archive, split in 1 GiB parts (FAT32)
/inglenook/SHA256SUMS                   checked before anything is touched
/inglenook/target-imgref                where updates come from (a registry, not this stick)
/inglenook/prepare-root.conf            the image's own ostree config, which bootc reads
/inglenook/accounts                     the image's user and group names (one per line): the first user's name must not be one of them
```

The installer is a UKI **addon** (`images/installer/build-addon.sh`): `.cmdline` is
`rd.systemd.unit=inglenook-installer.target`, so the boot initrd's systemd never switches
root; `.initrd` is a userspace-only cpio overlay (no kernel modules, no `.uname`, works with
any kernel). The overlay is the packages of `images/installer/mkosi.conf` minus every file
the boot initrd already has (`overlay.py`; a shared file that differs is an error), plus
`images/installer/rootfs`. Everything of ours is under `/usr/installer` (units are reached
by symlinks from `/usr/lib/systemd/system`). `exclude-packages.txt` keeps packages that are
only dependencies (podman, for bootc) out of the overlay. The installed system never has the
addon, and the boot initrd stays small: **anything an installed system needs to unlock and
mount its disks (dm-crypt, TPM, FIDO2 libraries, HID modules) belongs in the boot initrd
(`images/initrd/mkosi.conf`), not here.** Hardware support the installer needs beyond that
(modules) would be another addon with a `.uname`.

`build-addon.sh` also writes `/usr/installer/variant` into the overlay: the **image
variant** (`tpm2` or `no-tpm`) the stick was built from. It comes from the image's
`io.github.snugmo.inglenook.variant` label (set by `images/build.sh` from its `VARIANT`
build arg; `stick.sh` reads the label and refuses an explicit override that contradicts
it, since the marker must match the variant drop-in that is already in the image's
initrd — a mismatch would install a system that cannot boot).

The **serial-console addon** (`images/addons/serial-console.sh`, a `ukify build` on
`addonx64.efi.stub`) carries `console=tty0 console=ttyS0,115200n8`. The image's UKI
deliberately has no `console=` argument (`console=ttyS0` on a machine without a UART
starts a serial getty that fails and restarts every 10 seconds), and a locked-down
(Secure Boot, type-2) UKI accepts no other kernel arguments — so a serial console, on
the stick or on an installed system, comes from this file on the ESP: systemd-stub
appends the addon's cmdline to the UKI's, and `console=` only selects consoles,
granting no privilege, which is what makes that safe (the addon is unsigned, like
the image's UKI). The addon's boot is what the tests read on the serial. The
installer runs one root shell per console — `inglenook-shell` on `/dev/tty0`,
`inglenook-shell-serial` on `/dev/ttyS0`, each starting whenever its tty node exists
and bound to it with `TTYPath=`: a shell on `/dev/console` alone would lose the
screen the moment the addon selects the serial (it is the *last* `console=`). The
serial shell is gated on the node, not on the addon (the addon only redirects the
kernel's console output; `ConditionKernelCommandLine` would be the wrong tool —
it matches whole words and whole `key=value` assignments, never a glob). The
target `Wants` both shells rather than requiring them, so a console that cannot
be opened never blocks the boot target. With the addon the kernel's own output
goes to the serial only: the two consoles show different things, by design (the
units' comments carry the full reasoning).

## Making the USB drive

`images/installer/stick.sh <image-ref>` writes `build/installer/stick.img`, a complete
raw disk image (a GPT with one FAT32 partition, sized to the image content plus 300 MiB
in whole GiB — 5 GiB today; `STICK_SIZE=` and `PTYPE=` override) that is written byte
for byte to the drive:

```
sudo dd if=build/installer/stick.img of=/dev/sdX bs=4M conv=fsync
```

`/dev/sdX` is the whole drive (check with `lsblk`; the dd erases everything on it) and
must be at least as big as the image (anything larger just leaves an unused tail).
`sync` when dd says done, then pull it out. The tree alone can also be copied onto
any FAT32 drive (`build/installer/tree`, mtools or a mounted volume) — the firmware
boots the ESP's fallback path from any FAT partition — but the stick image is the
tested shape.

The drive is then used as described in [Using it](#using-it): Secure Boot off, boot
it, `inglenook-install` (the banner on the console points to it). A machine without
a TPM gets the plain-root options of the tpm2 image; with a TPM, the sealed root
(and the optional PIN, [below](#the-tpm-pin-tpm2-variant)).

## The two image variants

Both images carry the whole installer; they differ in what an encrypted root means and
in one initrd file:

| | **tpm2** (the default) | **no-tpm** |
| --- | --- | --- |
| encrypted root | LUKS2, key sealed to the machine's TPM (`Encrypt=tpm2`) | LUKS2, an **empty key slot** (`Encrypt=key-file`, no key file): unlocks hands-off with the empty password, a FIDO2 token or recovery key can be enrolled later |
| root options | `INSTALL_ENCRYPT=tpm2` (sealed, needs a TPM) or `none` (plain) | `INSTALL_ENCRYPT=luks` (empty slot) or `none` (plain) |
| no TPM present | the tpm2 image offers a plain (unencrypted) root | the same: a plain root (`none`); the empty-slot mode does not need a TPM, so it is the default |
| initrd unlock of an encrypted root | gpt-auto's generated unit as-is (TPM2 options on a measured boot, docs/encryption.md) | one drop-in (`images/initrd/no-tpm/`, added to the initrd only in this variant) replaces gpt-auto's `ExecStart=` with `fido2-device=auto,try-empty-password=true` — the documented no-TPM2 path in docs/encryption.md |
| /var | LUKS2 either way (below) | LUKS2 either way (below) |

## Using it

Boot the stick (the console shows a banner), then run `inglenook-install`. It:

1. finds the image on any vfat volume (`/inglenook/image.oci.tar.000`) and checks `SHA256SUMS`;
2. lists the disks (not the stick), then shows the chosen one in full (`lsblk`, signatures,
   a hint if it looks like Windows, LUKS or an earlier Inglenook). A disk with anything on it
   is erased only after you type its device name; an empty one after a yes. Disks with mounted
   filesystems are refused;
3. asks for the root size (default 50G, the most that leaves room for /var on this disk;
   the rest of the disk becomes /var);
4. asks how to encrypt, per the variant (above): TPM-sealed or plain on the tpm2 image,
   empty-slot LUKS or plain on the no-tpm image, with a recovery key offered for the
   TPM-sealed root, a TPM PIN offered for the TPM seal (below), and (below) whether a
   FIDO2 key should unlock the volumes too;
5. asks for the **first user** (below), because root is locked and there is no other account, so
   without one nobody could log in;
6. asks whether the installed system gets a **serial console** (default no): the stick's
   serial-console addon (above), copied to the system's ESP after the install; deleting
   the file from the ESP turns it off again;
7. does the whole job, all in the initrd: wipes the disk, partitions it with
   `systemd-repart` from `/usr/installer/repart.d/` (`00-esp.conf`, `10-root.conf`,
   `60-var.conf`: the committed definitions carry the shape of each partition; the
   installer appends the chosen root size and `Encrypt=` to its copies), with
   `--seed=` set to the **machine id it generates** — every partition, LUKS and filesystem
   UUID on the disk is a deterministic function of that one value (HMAC-SHA256, see the
   systemd-repart man page). `/var` is all the space after the root, XFS on LUKS2
   (sealed to the TPM when there is one, an empty key slot otherwise — there is no
   unencrypted mode: an empty key is easier to manage than no layer, and a FIDO2 token
   can be enrolled later without an encrypt-in-place). If a FIDO2 key was asked for
   (below), it is enrolled into the volumes' LUKS2 headers right after partitioning,
   while they are still closed. The installer then opens the root and
   /var, and **/var doubles as the scratch space**: it unpacks the image from the stick
   into /var, says the stick is no longer needed, runs `bootc install to-filesystem`
   straight from the initrd (no container), writes the machine id into the new system
   (the deployment's `/etc`, so the first boot is not a first boot: no machine-id
   commit, no disk-encryption wizard — the volumes already have the keys decided
   here), adds a firmware boot entry (`efibootmgr`, non-fatal), empties /var again,
   unmounts everything and asks for the stick to be unplugged before the reboot.
   Because the machine id is written before the first boot, the initrd's /var safety
   net (which makes the partition on a system installed *before* this installer, or by
   plain `bootc install`) finds the partition already there and has nothing to do.

Questions whose answer is in the environment are not asked (`INSTALL_DISK`,
`INSTALL_ROOT_SIZE`, `INSTALL_ENCRYPT=tpm2|none` on the tpm2 variant, `luks|none` on the
no-tpm one, `INSTALL_RECOVERY_KEY`, `INSTALL_TPM2_PIN=yes|direct|0` (a PIN for
the TPM seal, below; the value is in `INSTALL_TPM2_PIN_VALUE`),
`INSTALL_FIDO2=1|0` (a security key for the
encrypted volumes, below), `INSTALL_TOKEN=1|0` (a FIDO2 key for the first
user, enrolled at the first boot, below), `INSTALL_CONSOLE=1|0`, `INSTALL_USER`,
`INSTALL_REALNAME`, `INSTALL_USER_PASSWORD`, `INSTALL_NO_USER=1`, `INSTALL_YES=1`
(answers yes to every yes/no question, including the console one), `INSTALL_NO_REBOOT=1`,
`INSTALL_TARGET_IMGREF`, `INSTALL_IMAGE_DIR`); the tests use that.

Measured in QEMU: about 45 s for the install itself; the image copy lives on the target
disk's own /var, so the RAM footprint is only the decompression.

## The first user

A fresh install has a locked root account and no regular account at all, so the installer sets up one
systemd-homed account:

- **In the installer:** username, full name (optional) and a password (twice, at least 8 characters).
  After `bootc install` it writes a `home.create.<name>` credential, a homed JSON user record, into the
  new system's `/etc/credstore` (that is under `/state/deploy/<digest>/etc` on the root, so it is on the
  encrypted volume, mode 0600, SELinux-labeled with `setfiles` like the initrd does). The record is in
  the `wheel` group (so `run0` works), has `/bin/bash` as shell, and holds the password hash plus the
  password itself in its `secret` section: homed needs the secret to create the home.
- **On the first boot:** `systemd-homed-firstboot.service` (enabled in the image) runs
  `homectl firstboot`, which creates the account from the credential without asking, and the drop-in
  (`10-inglenook.conf`) deletes the `home.create.*` file afterwards. The drop-in clears
  `ConditionFirstBoot=` — on an installed system the machine id is already initialized on the first
  real boot (the installer wrote it), so the condition is never true; clearing it also keeps
  `systemd-firstboot.service`, which would prompt for a root password, from ever running — and
  instead runs when no user record exists (an `ExecCondition` on the `*.identity` files in
  `/var/lib/systemd/home` — not "the directory is empty": homed keeps its signing keys there).
  Without a credential (an install that skipped the first user) it prompts on the console for one
  (username and password; the account joins `wheel`). To add users later from an existing login:
  `homectl create <name> --member-of=wheel`. The home is a plain directory when the root is
  encrypted (it already is), homed's default (a LUKS image) when it is not.
- The installer also appends `<name>:524288:65536` to `/etc/subuid` and `/etc/subgid` (rootless podman).
- Without disk encryption the password sits on the unencrypted disk in `/etc/credstore` until the first
  boot deletes the file (and stays recoverable from free space); the installer warns about that.
- Tokens (FIDO2, PKCS#11) for the account: [tokens.md](tokens.md).

## FIDO2 keys for the encrypted volumes

The installer can also make a FIDO2 security key (a YubiKey ...) unlock the
encrypted volumes at boot, at the same time as the TPM (or the empty key) is set
up. After the question in step 4 (above) it happens in step 7, when the volumes
exist and are still closed: the installer waits for the key — a short poll when
unattended (`INSTALL_YES=1`), until it is inserted or `skip` is typed otherwise —
and runs `systemd-cryptenroll --fido2-device=auto` on each volume it is offered
for: `--unlock-tpm2-device=auto` on the TPM-sealed /var, `--unlock-empty` on the
empty-key volumes. The key's PIN, when it has one, is asked through ask-password (keystrokes
would split between readers), so the installer stops the console shells and
agent and starts a replacement agent on the script's own TTY (the default
binds to /dev/console — with the serial addon, the serial port); the services
come back after the enrolment - unattended, only when a key actually shows up,
so an install without one keeps the consoles up the whole time.

What the key ends up unlocking is fixed by the boot path, so the installer only
offers it where the boot path would actually try it:

| volume | tpm2 image | no-tpm image |
| --- | --- | --- |
| root | never (a TPM-sealed root boots from the TPM only: gpt-auto's generated unit carries no FIDO2 option, and a static drop-in cannot add one safely — docs/encryption.md) | the empty-key root (the variant's initrd drop-in tries `fido2-device=auto`) |
| /var | yes (the initrd's /var unlock already tries `fido2-device=auto`) | yes |

Each enrolment adds one `systemd-fido2` token and one keyslot to the volume's
1 MiB JSON header (docs/encryption.md for the mechanism); the existing keys
(the TPM seal, or the empty key) are untouched and keep working, so the key is
a fast path rather than a gate: a TPM-sealed /var still unlocks from the TPM
first (no delay without the key; the key is the fallback for a lost TPM), and
an empty-key volume (the no-tpm root, or /var on a TPM-less machine) boots
without the key too: the initrd waits up to 30 s per volume and then the
empty key unlocks (docs/encryption.md). To make the key the *only* way to
unlock a volume later,
wipe the other keyslots from the booted system (docs/encryption.md).
`INSTALL_FIDO2=1|0` answers the question; with `1` and no key in hand the
installer warns and continues without it.

## The TPM PIN (tpm2 variant)

On the tpm2 image, for an encrypted root, the installer can protect the TPM
seal with a PIN (the question after the recovery key, step 4 above;
`INSTALL_TPM2_PIN=yes|direct|0` answers it — `yes` = Argon2id, `direct` =
PBKDF2 — the value is in `INSTALL_TPM2_PIN_VALUE`): the TPM then refuses to
release the volume key without the PIN, so a copy of the disk alone cannot
unlock it and the PIN is asked at every boot. The PIN is written into no file
on the machine; it is carried by the TPM's policy alone.

Asked for, the installer binds it in step 7, while the volumes are still
closed: per volume it re-issues the TPM2 seal with the PIN (a FIDO2 token and
the recovery keyslot survive the wipe) and opens the volumes with the PIN in
the `PIN` environment variable (its own attach is headless — no prompt
channel by design). The finishing notice points at what a lost PIN costs.
The mechanism (the binding is a replacement; the seal stays PCR-less) and
the boot side (the `cryptsetup.tpm2-pin` credential or the initrd's
ask-password agent: root first, then /var, the same PIN twice) are in
docs/encryption.md, with the cost of a forgotten PIN: the root falls back
to the recovery key (if one was created), but the tpm2 image's /var is
TPM2-only, so a forgotten PIN without a FIDO2 token on /var leaves it
unbootable — the volume, not the system, is the loss.

## Tests

- `images/test/installer-env.sh`: the addon on a stick without the image: root shell in the initrd
  (one on the keyboard console, one on the serial, each bound to its own tty), banner, every
  installer tool runs.
- `images/test/install-from-stick.sh`: the whole install onto a disk that holds old data, a first
  user, the stick pulled over QMP as soon as it is no longer needed, then the disk booted
  alone: a shell on each console before and after the FIDO2 section (serial while the
  stick's addon is on it); root and /var in the state the chosen `ENCRYPT=tpm2|luks|none`
  promises (TPM2 token, empty slot, or plain), /var is XFS, the serial-console addon on
  the ESP (auto-answered by `INSTALL_YES=1`), the account in `wheel` takes the password
  and not a wrong one, and the credential is gone. `luks` needs the no-tpm stick (the
  tpm2 installer refuses it); that run also exercises the variant's
  FIDO2/empty-slot root unlock drop-in (docs/encryption.md), since the installed disk
  boots without a TPM. With `FIDO2=1` the question is answered yes but no key is
  present: it warns and continues, and the test checks that nothing was enrolled.
- `images/test/install-fido2.sh`: the FIDO2 key on the LUKS volumes, end to end: boot a
  disk installed by install-from-stick, enrol a software FIDO2 token (softfido.py in the
  booted system) into the volumes' LUKS2 headers, and reboot without the token: on the
  no-tpm image (`ENCRYPT=luks`) the boot still reaches a login (the wait times out,
  above; the test checks the gap between the two unlock audit lines); on the tpm2 image
  (`ENCRYPT=tpm2`) the TPM unlocks /var first, so no delay. The installer's own
  enrolment (the volumes still closed in the initrd) needs a FIDO2 device in the initrd,
  which has no python3, so that path is only covered by the no-key run (above).
- `images/test/install-safety.sh`: everything `inglenook-install` does before it erases: what it shows,
  the typed confirmation, bad sizes, a non-disk, and that the disk is byte-for-byte unchanged afterwards.

`images/test/serial-shell.py` and `serial-run.py` drive the root shell over the serial console. The
console shell is an interactive bash: a `!!` in a command is history expansion, so the installer prints
`ERROR:` / `WARNING:` and never `!!!`.

- **A security key (optional):** the installer asks whether to enrol a FIDO2 key for the user
  (`INSTALL_TOKEN=1|0` answers it). Enrolling needs homed running, which the initrd does not have, so
  the installer only leaves the user name in `/etc/inglenook/enroll-token`. On the first boot
  `inglenook-token-enroll.service` (after the homed wizard, before the login prompts, on the console)
  asks to insert the key, and - through systemd-ask-password, which owns the console while it runs -
  for the account password (passed to homectl in `$PASSWORD`) and the key's PIN (set one beforehand,
  `ykman fido access change-pin`), which it pre-seeds as the `home.token-pin` credential homectl's
  FIDO2 code reads before it would ask (a wrong pre-seeded PIN locks the token instead of
  re-prompting; the wizard then asks again and the key needs an unplug/reinsert), and runs
  `homectl update <user> --fido2-device=auto --fido2-with-client-pin=yes
  --fido2-with-user-presence=yes`. `s` skips; the marker is removed either way. One key
  only: each `--fido2-device=` replaces the account's keys (docs/tokens.md). The password keeps working.
  The test checks the marker and that the unit is enabled; the wizard itself was **not** driven end to
  end (the tests boot with `inglenook.tokenenroll=no`, as nobody answers the console).

## Not done yet

**Unattended mode driven by a config file** — the whole flow already runs from
`INSTALL_*` environment variables (the tests use them); a file on the stick
(e.g. `/inglenook/install.conf`) mapped to them would let a machine boot from
the stick and install itself, then reboot into the new system. Open question:
creating the first user needs the plain password (homed refuses a hash alone,
gotcha 25), so the unattended flow carries it on the stick until first boot.

**Progress feedback inside the long steps** — every step gets a `say` line
before it; `bootc install` (several minutes) and the image copy are silent
while they run.

**The destructive confirmation in the systemd-ask-password idiom** — the wipe
confirmation is a plain `read`; the `-e` uppercase-`YES` pattern (as in the
other scripts) is more robust (it also works if the installer is backgrounded)
and consistent with the first-boot wizard. By extension: the `ask`/`yes_no`
questions.

**The FIDO2 console blackout** — the console shells are stopped for the whole
FIDO2 section (in an interactive install, including the wait for the key): the
installer's own `read` and cryptenroll's ask-password would otherwise share
the console with the parent shell, and the keystrokes would split between
readers. b041a64 already fixed the prompt channel (a replacement ask-password
agent on the script's TTY); what remains is the blackout itself.

**Upstream: homed's `perMachine: null`** — a record without the field breaks
`homectl update --fido2-device=`; the installer works around it by injecting
`perMachine: []` into the first user's credential. A candidate for
`docs/upstream/`.

**Testing the interactive path** — every test answers through the environment;
the typed prompts are only exercised for refusals (install-safety.sh). A
serial-driven run that types the real flow (disk choice, confirmation,
questions) would close the gap (`serial-shell.py` is the tool).

Smaller / open-ended: Swap, a PCR policy for the TPM keys, LVM (an addon if
ever needed), and any test on real hardware. (FIDO2 keys for the *volumes*
are offered by the installer, above; the account's key is offered at the
first boot.)
