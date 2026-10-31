# The installer stick

A stick that installs Inglenook onto a disk of the machine it is plugged into. It boots
a root shell in the *initrd*, runs `inglenook-install`, and is not needed once the image
has been copied. Secure Boot must be off (the UKI and the addon are unsigned).

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
the stick or on an installed system, comes from this file on the ESP: the stub
appends the addon's cmdline to the UKI's. `console=` only selects which consoles are
shown and grants no privilege, which is what makes it safe in that role (a locked-down
system needs the addon signed like the UKI; here it is unsigned, with Secure Boot off).
The addon's own boot is what the installer's root shell and the tests read on the
serial; without it (real firmware adds no console of its own) the installer would have
no console at all.

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
   TPM-sealed root;
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
   can be enrolled later without an encrypt-in-place). The installer opens the root and
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
no-tpm one, `INSTALL_RECOVERY_KEY`, `INSTALL_CONSOLE=1|0`, `INSTALL_USER`,
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
- **On the first boot:** `systemd-homed-firstboot.service` (enabled in the image, drop-in
  `10-inglenook.conf`) runs `homectl firstboot`, which creates the account from the credential without
  asking, and the drop-in deletes the credential afterwards. The unit does not use
  `ConditionFirstBoot=`: the image ships an empty `/etc/machine-id`, which systemd treats as "not a first
  boot" (machine-id(5)) — though a stick install no longer relies on that: it writes the machine id
  itself, and the homed wizard runs while homed simply has no regular user yet. The home is a plain
  directory when the root is encrypted (it already is), homed's default (a LUKS image) when it is not.
- **Skipped in the installer:** the same service prompts on the console on the first boot (username and
  password; the account joins `wheel`). Nothing is stored anywhere before that. To add users later from an
  existing login: `homectl create <name> --member-of=wheel`.
- The installer also appends `<name>:524288:65536` to `/etc/subuid` and `/etc/subgid` (rootless podman).
- Without disk encryption the password sits on the unencrypted disk in `/etc/credstore` until the first
  boot deletes the file (and stays recoverable from free space); the installer warns about that.
- Tokens (FIDO2, PKCS#11) for the account: [tokens.md](tokens.md).

## Tests

- `images/test/installer-env.sh`: the addon on a stick without the image: root shell in the initrd,
  banner, every installer tool runs.
- `images/test/install-from-stick.sh`: the whole install onto a disk that holds old data, a first
  user, the stick pulled over QMP as soon as it is no longer needed, then the disk booted
  alone: the root and /var volumes are in the state the chosen `ENCRYPT=tpm2|luks|none`
  promises (TPM2 token, empty slot, or plain), /var is XFS, the serial-console addon
  is on the ESP (the console question is auto-answered by `INSTALL_YES=1`), the
  account exists, is in `wheel`, takes the password and not a wrong one, and the
  credential is gone. `luks`
  needs a stick made from the no-tpm image variant (the tpm2 installer refuses it), and
  that run also exercises the variant's FIDO2/empty-slot root unlock drop-in
  (docs/encryption.md), since the installed disk boots without a TPM.
- `images/test/install-safety.sh`: everything `inglenook-install` does before it erases: what it shows,
  the typed confirmation, bad sizes, a non-disk, and that the disk is byte-for-byte unchanged afterwards.

`images/test/serial-shell.py` and `serial-run.py` drive the root shell over the serial console. The
console shell is an interactive bash: a `!!` in a command is history expansion, so the installer prints
`ERROR:` / `WARNING:` and never `!!!`.

- **A security key (optional):** the installer asks whether to enrol a FIDO2 key for the user
  (`INSTALL_TOKEN=1|0` answers it). Enrolling needs homed running, which the initrd does not have, so
  the installer only leaves the user name in `/etc/inglenook/enroll-token`. On the first boot
  `inglenook-token-enroll.service` (after the homed wizard, before the login prompts, on the console)
  asks to insert the key and runs `homectl update <user> --fido2-device=auto --fido2-with-client-pin=yes
  --fido2-with-user-presence=yes`; homectl asks for the account password and the key's PIN (set one
  beforehand, `ykman fido access change-pin`). `s` skips; the marker is removed either way. One key
  only: each `--fido2-device=` replaces the account's keys (docs/tokens.md). The password keeps working.
  The test checks the marker and that the unit is enabled; the wizard itself was **not** driven end to
  end (the tests boot with `inglenook.tokenenroll=no`, as nobody answers the console).

## Not done yet

Swap, FIDO2 enrollment of the encrypted *volumes* during the install (the empty-slot
volumes accept a token at any time after first boot, `systemd-cryptenroll` with `run0`;
only the account's key is offered at the first boot), an unattended mode driven by a
config file, a PCR policy for the TPM keys, LVM (an addon if ever needed), and any test
on real hardware.
