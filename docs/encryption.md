# Disk encryption at boot

How the initrd unlocks the LUKS root, and what levers exist (and what are traps) for
changing the options it passes to `systemd-cryptsetup`. Hard-won from reading the
systemd 262 source and extracting the initrd; the no-TPM2 FIDO2 path at the bottom is
proposed, not built.

## The init in the initrd is systemd

`init` in the initrd cpio is a **symlink to `/usr/lib/systemd/systemd`** — there is no
init script, no sysvinit. Everything before switch-root (modules, udev, LUKS unlock, the
composefs root mount) is ordinary systemd units, generators and udev rules running in
the initrd context. The stock `mkosi-initrd` template (what `Include=mkosi-initrd` in
`images/initrd/mkosi.conf` resolves to, from the installed mkosi package) supplies the
basic set: systemd, udev, the dm-crypt/tpm kernel modules, a `credential.conf` drop-in
for `systemd-cryptsetup@.service` (`ImportCredential=cryptsetup.*`) and one udev rule.
Anything the unlock path needs beyond that belongs there (AGENTS.md: dm-crypt, TPM,
FIDO2 libraries, HID modules), not in the installer addon.

## How the root gets unlocked

1. **udev names the device.** `13-dm-disk.rules` symlinks a plain DPT root to
   `/dev/gpt-auto-root`; `90-image-dissect.rules` symlinks a `crypto_LUKS` partition to
   `/dev/gpt-auto-root-luks`, and — once that partition is opened — creates
   `/dev/gpt-auto-root` from the opened CRYPT device whose `DM_NAME` is `root` (which
   the mount unit then waits for).
2. **gpt-auto-generator** (`/usr/lib/systemd/system-generators/`, run by PID 1 in the
   initrd) reads `root=` and generates `systemd-cryptsetup@root.service` with
   `ExecStart=/usr/bin/systemd-cryptsetup attach root /dev/gpt-auto-root-luks <keyfile>
   <options>` — the generator invokes the **absolute path** (meson's `bindir`), and the
   `<options>` come from a **closed set** in `add_cryptsetup()`: `read-only` (if the
   root is not RW), `tpm2-device=auto` (if `efi_measured_os() > 0`) and the PCR
   measure flags. There is no karg or config file that adds to that set. Drop-ins
   are different: they are collected for a unit regardless of which fragment won
   the load-path race, and a drop-in may add other `[Service]` keys (the
   template's `credential.conf` adds `ImportCredential=`) *and* clear and replace
   `ExecStart=` (drop-ins parse after the fragment; an empty `ExecStart=` resets
   the list, and the following line supplies a new one). That replacement is the
   lever the no-TPM2 path at the bottom uses.
3. **Unencrypted mode needs no configuration because the unit never activates.** The
   generated unit is `BindsTo=` the designator device; a non-encrypted root has no
   `crypto_LUKS` partition, so `/dev/gpt-auto-root-luks` never appears and the
   cryptsetup unit is simply never started (the `/dev/gpt-auto-root` symlink comes
   straight from the plain DPT partition).

## Levers that do not work

- `systemd.gpt_auto=0` disables the whole generator, **including the ESP mount**.
- `root=off`, or any value other than `gpt-auto`/`gpt-auto-force`/`dissect`/
  `dissect-force`, disables *all* root handling, including the `/sysroot` mount.
- `rootflags=` is appended to **both** the mount options and the cryptsetup options;
  it cannot carry `try-empty-password=` without breaking the mount.
- There is no per-machine kernel-argument carrier in the *static* layer: systemd-boot
  v262 has **no kargs.d**, and `io.systemd.boot.kernel-cmdline-extra` is read **only
  from SMBIOS type 11** (`smbios_find_oem_string` in `boot.c`) — present in the test
  VMs (QEMU), absent on machines. The UKI's baked-in command line is part of the
  image, so it cannot carry a per-machine LUKS UUID. For *type-1* entries the
  per-machine carrier is the deployment's **BLS `options=` line** on the ESP:
  bootc writes it at install time (`install to-filesystem --karg=…`) and
  systemd-boot appends it to the UKI's static command line — the same path
  `vm.sh` uses to get `console=ttyS0` into the test VMs. But that is a
  permissive-chain story: a locked-down type-2 UKI entry has no such carrier at
  all (see the last section).
- The initrd has no `/etc/crypttab`, so crypttab is not a carrier either (it is
  static, built into the image; the UUID is per-machine).

The levers that *do* work are in the next section.

## How systemd-cryptsetup unlocks (v259 and v262 behave the same)

Unlock order in `attach`: (1) a token — PKCS#11, FIDO2 or TPM2; (2) the configured or
discovered key; (3) the **empty password, only if** `try-empty-password=` is in the
options (a crypttab option since v246); (4) prompt the user.

- **FIDO2 is opt-in**: it needs `fido2-device=auto` in the options. It is not
  auto-detected even when a token is plugged in and a FIDO2 token is enrolled in the
  LUKS header.
- **The token gate is hard.** With `fido2-device=auto` and no token present it logs
  "Security token not present for unlocking volume …, please plug it in", waits the
  30-second token timeout, and the unit **fails** (ETIMEDOUT). It does not fall
  through to a password prompt (only `-EAGAIN` from a token plugin does). Once a FIDO2
  token is enrolled in a volume, a boot without the token is a hard failure — that is
  the intended fail-closed behaviour, but it must be planned for.
- **The empty password only works through the `try-empty-password=` flag** — it is
  never tried otherwise, and with no key, no token and no flag the unit simply prompts
  (which in the initrd is a hang: nothing answers the console).
- **`-` is not a key file for systemd-cryptsetup.** A non-absolute key-file path is
  logged and **ignored** (`key_file = NULL`), so `attach … -` does *not* read from
  stdin — the "hang on empty stdin" seen in the installer VM was actually the password
  prompt. Pass an absolute path, or nothing.

## LUKS2 facts that bit

- `luksFormat --key-file /dev/null` is **rejected** ("Nothing to read on input"); a
  **zero-byte regular file** works as a key file, for format and for open.
- LUKS2 tokens (FIDO2, TPM2, PKCS#11) live in the volume's 1 MiB JSON header,
  **independent of keyslots**. Enrolling a token adds no keyslot and wipes none, and
  the enrolled set is readable without unlocking: `dd if=<dev> bs=1M count=1 | grep
  '"type":"fido2"'`.
- That independence is what makes "install with an empty slot, enrol a token, wipe the
  empty slot" work. The wipe must be authorised by **another** live slot — cryptsetup
  refuses to authorise a wipe with the very slot being wiped.
- `systemd-repart` **can** make the empty-keyslot root natively: `Encrypt=key-file`
  (v247; also `key-file+tpm2`; a boolean `Encrypt=` maps to it), with the key from
  `KeyFile=` (v259, absolute path only, otherwise ignored) or the global
  `--key-file=` — and when **neither** is given, repart uses an *empty (zero-length)
  key* on purpose: the man page says this default is "useful for setting up encrypted
  partitions during early first boot that receive their user-supplied password only in
  a later setup step". A 0-byte key file is also accepted (`read_full_file_full` gives
  an empty iovec). repart then adds the keyslot, opens the volume with the *volume
  key* (not the passphrase), creates the filesystem, and deactivates — the partition
  is left closed on disk. The LUKS2 UUID is derived stably from the partition UUID.
  (`Encrypt=…` has no effect on a partition that already exists; the installer wipes
  first, so that does not apply.)
- The initrd already has what a FIDO2 unlock needs: `libfido2`, the `fido_id` udev
  helper (`60-fido-id.rules`), the cryptsetup token modules
  (`libcryptsetup-token-systemd-{fido2,pkcs11,tpm2}.so`), and plymouth for the PIN
  prompt.
- **Version skew**: an extracted initrd once said `systemd 259.9-1.fc44` while the
  image had `262-3.fc45` — a stale mkosi build, not a feature difference. If the
  initrd's systemd version does not match the image's, rebuild with a clean mkosi
  cache before chasing "missing feature" bugs.

## The no-TPM2 FIDO2 path (proposed, not built yet)

Install the root as LUKS2 with an **empty keyslot only** (repart `Encrypt=key-file`,
no key file — the documented empty-key default) and no TPM2 token. First boot is
hands-off (the empty slot); the first user then enrolls a FIDO2 token and wipes
the empty slot (end of this section).

**Locked-down boot leaves no kargs channel.** For a type-2 entry systemd-boot marks
the embedded command line `options_implied` and passes nothing to the PE
(`call_image_start`: `options_initrd ?: options_implied ? NULL : options`) — the
stub boots with its own signed, measured command line. Even the QEMU test channel
(`io.systemd.boot.kernel-cmdline-extra`) is gated to `LOADER_LINUX` (type-1)
entries, so a type-2 UKI has zero kargs injection points — on machines *and* in the
test VMs. A fixed LUKS2 UUID would not save a kargs scheme either: repart derives
the LUKS2 UUID deterministically from the partition UUID (HMAC-SHA256 of
`"luks-uuid"`), so pinning the partition UUID would make the UUID a build-time
constant — but `rd.luks.uuid=` then makes cryptsetup-generator *unconditionally*
write `systemd-cryptsetup@root.service` into the normal generator directory,
shadowing gpt-auto's `generator.late` copy in **every** mode with one static
options string, and (as shown below) no single static string is safe for all
modes.

**The static carrier that works is a drop-in.** A unit's drop-ins are collected
from *every* directory in the search path regardless of which fragment won the
load-path race (`unit_find_dropin_paths` → `unit_file_find_dirs`: the unit's own
name, its template, and the type-level dir), so a drop-in shipped in the image's
initrd applies to gpt-auto's generated `systemd-cryptsetup@root.service` — and a
drop-in may clear and replace `ExecStart=`.

**But one drop-in for all modes is not enough: the safe option sets are
mode-specific, and the two modes' sets are mutually exclusive.** The tempting
static superset (`tpm2-device=auto,tpm2-measure-pcr=…,fido2-device=auto,
try-empty-password=true`) breaks, because *measurement* and the token *plugins*
are exclusive: `use_token_plugins()` returns false whenever
`tpm2-measure-pcr=`/`tpm2-measure-keyslot-nvpcr=` is set ("there's no way to
query the volume key when plugins are used"), which sends FIDO2 auto-discovery to
the **in-tree** path — and the in-tree path returns a **fatal** `-ENXIO` ("No
valid FIDO2 token data found") when the header has *no* FIDO2 token, whereas the
plugin path converts exactly that to `-EAGAIN` and falls through. `verb_attach`'s
retry loop continues only on `-EAGAIN` (`if (r != -EAGAIN) return r;`) — so a
fresh no-TPM root (empty slot only, no token yet: the exact first-boot state)
fails its boot at the FIDO2 step. The superset also degrades a tpm2 root that
lost its TPM: today that ends at the passphrase prompt (a recovery key can still
answer), with the superset the in-tree FIDO2 `-ENXIO` kills the unit first.

**So the mode is a property of the image, and each variant carries its own static
options.** Two build variants (one build arg), one image per mode:

| variant | initrd drop-in | notes |
| --- | --- | --- |
| **tpm2** (the current default) | none — gpt-auto's unit stands as generated | byte-identical to today: measured UKI boot → `tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-measure-keyslot-nvpcr=yes` (`tpm2-measure-pcr=yes` = `TPM2_PCR_SYSTEM_IDENTITY`, PCR 15 in v262: the volume key and the NvPCR); non-measured boot → no TPM2 options, fail-closed as today. The TPM2 unlock is already the in-tree path today (the measure flags disable the plugins), so nothing moves. |
| **no-TPM LUKS** (new) | one file in the initrd, `ExecStart=` cleared and replaced (see below) | no TPM2/measure options, so `use_token_plugins()` stays true (the initrd ships `libcryptsetup-token-systemd-{fido2,pkcs11,tpm2}.so` and `libfido2`), and the *plugin* FIDO2 path is the one that runs. |

The no-TPM variant's drop-in (in the initrd,
`/usr/lib/systemd/system/systemd-cryptsetup@root.service.d/`):

    [Service]
    ExecStart=
    ExecStart=/usr/bin/systemd-cryptsetup attach root /dev/gpt-auto-root-luks '' 'fido2-device=auto,try-empty-password=true'

State matrix of the no-TPM variant — one static line for the whole life of the
volume:

| state | what the attach does |
| --- | --- |
| **fresh** (empty slot only, no token) | the FIDO2 plugin finds no `systemd-fido2` metadata → `-ENXIO`/`-ENOENT`/`-ENOTUNIQ` → converted to `-EAGAIN` and dropped immediately (the 30-second monitor only starts when a token *is* in the header) → `try-empty-password` unlocks. Hands-off. |
| **enrolled, token present** | the plugin unlocks the volume key; the PIN comes through ask-password (the `cryptsetup.fido2-pin` credential, or the plymouth prompt). |
| **enrolled, token absent** | the plugin's device enumeration finds nothing (`FIDO_ERR_INTERNAL` → synthetic `-EAGAIN`) → the 30-second udev monitor → the unit fails. Fail-closed, the intended behaviour. |
| **unencrypted install from this image** | no `crypto_LUKS` partition → gpt-auto generates no cryptsetup unit → the drop-in (with no fragment to attach to) is inert. |

A TPM machine running the no-TPM variant boots fine, but its volume key is
*not* measured (PCR 15 / NvPCR): measurement and the plugin path are mutually
exclusive, and the measure flags must stay out of this variant's line or the
fresh state dies. A measured token deployment would be an upstream feature
(measurement in the plugin path), not something a drop-in can add.

The booted system is a no-op either way: the generators re-run on the same
static command line, the same unit starts, and `attach` on an already-active
volume returns 0 ("Volume already active") before any token attempt. The
drop-in ships in the initrd only; the rootfs needs nothing.

The install side of the no-TPM variant: the installer's repart definition uses
`Encrypt=key-file` with *no* `KeyFile=`/`--key-file=` (the documented
zero-length-key default), skips the TPM2 cryptenroll, reads the derived LUKS2
UUID from the formatted partition, opens it with `systemd-cryptsetup attach`
(empty password), then `bootc install to-filesystem` as today.

Costs and open items:

- Two image variants to build and publish (a build arg to `build.sh`/the
  Containerfile); the installer stick is built from the variant matching the
  chosen install mode (it takes the image ref anyway).
- The drop-in couples the image to gpt-auto's device naming
  (`/dev/gpt-auto-root-luks`) and the volume name `root`; re-derive it at each
  systemd rebase (we pin the systemd version per release, so a rebase is the
  only thing that can drift it).
- **More than one FIDO2 token** (two keys enrolled) is unverified: the in-tree
  path tries tokens in turn, but the plugin path's `-ENOTUNIQ` → `-EAGAIN`
  conversion suggests libcryptsetup can signal "not unique" and bail to the
  next method instead of trying the second token. One key is the designed
  path; verify the plugin's iteration semantics before promising multiple.
- A type-2 entry also loses the QEMU `kernel-cmdline-extra` console channel
  (type-1 only), so locked-down *test* images need `console=` baked into the
  UKI (a test-only build flag) or the tests keep the permissive type-1 layout.
- `/var` in a no-TPM install — unencrypted, or its own attach options in
  `inglenook-var-mount` — is still undecided.
- The initrd's systemd (259 in the last extracted build) predates the image's
  (262) — a stale mkosi build; clean rebuild before implementing.

After first boot the first user enrolls a token on the booted system
(`run0 systemd-cryptenroll --fido2-device=auto /dev/mapper/root`) and wipes
slot 0 through the token (the empty slot is the one being wiped, so its own
password cannot authorise the wipe — see the LUKS2 facts above). Every boot
after that is token-gated; the boot configuration never changes.
