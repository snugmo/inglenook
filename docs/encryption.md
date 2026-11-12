# Disk encryption at boot

How the initrd unlocks the LUKS root, and what levers exist (and what are traps) for
changing the options it passes to `systemd-cryptsetup`. Hard-won from reading the
systemd 262 source and extracting the initrd; the no-TPM2 FIDO2 path (the `no-tpm`
image variant) and the TPM2-with-PIN path (the tpm2 variant's installer) at the bottom
are built. Line references are to the v262 source tree.

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
   `<options>` come from a **closed set** in `add_cryptsetup()` (line 70): `read-only`
   (if the root is not RW), `tpm2-device=auto` (if `efi_measured_os() > 0` —
   `efi-loader.c:309`: the `SYSTEMD_FORCE_MEASURE` env, the
   `systemd.tpm2_measured_os=` karg, or the `StubPcrKernelImage` stub variable) and the
   PCR measure flags. There is no karg or config file that adds to that set. Drop-ins
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
  from SMBIOS type 11** (`smbios_find_oem_string` in `boot.c:3079`, and only for
  `LOADER_LINUX` — type-1 — entries) — present in the test VMs (QEMU), absent on
  machines. The UKI's baked-in command line is part of the
  image, so it cannot carry a per-machine LUKS UUID. For *type-1* entries the
  per-machine carrier is the deployment's **BLS `options=` line** on the ESP:
  bootc writes it at install time (`install to-filesystem --karg=…`) and
  systemd-boot appends it to the UKI's static command line — the same path
  `vm.sh` uses to get `console=ttyS0` into the test VMs. But that is a
  permissive-chain story: a locked-down type-2 UKI entry has no such carrier at
  all (see the last section). The one exception is a **UKI addon**
  (`addonx64.efi.stub`, `ukify build --stub …`): the stub concatenates the
  addon's `.cmdline` to the UKI's own, and a signed addon passes Secure Boot
  like the UKI does. The addon's content is static (a file on the ESP), so it
  is still not a *per-machine* carrier — but it is the only kernel-argument
  channel a type-2 entry has, and it is what carries `console=` (the image's
  UKI has none: `console=ttyS0` on a machine without a UART starts a serial
  getty that fails and restarts every 10 seconds). The stick carries
  `loader/addons/serial-console.addon.efi` for its own boot, the installer
  copies it to the installed system's ESP on request, and the tests put it on
  every test ESP (docs/installer.md). `console=` only selects which consoles
  are shown and grants no privilege, which is what makes it safe to append to
  a locked-down command line.
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
- **A missing token delays, it does not gate, while any other method exists.** With
  `fido2-device=auto` and a `systemd-fido2` token in the header but no device, `attach`
  logs "Security token not present for unlocking volume …, please plug it in", then
  runs a 30-second udev monitor for the device; on timeout it logs "Timed out waiting
  for security device, …" and returns `-EAGAIN`, which the attach loop treats as
  "drop this method, try the next": the loop clears the token option and re-enters
  the chain (the configured/discovered key, then the empty password when
  `try-empty-password=true`, then an interactive prompt unless `headless`). Verified
  on 262.1 with an empty-key volume and an enrolled token: a cold boot without the
  key unlocks each volume ~30 s later (the two `module=crypt op=ctr` audit lines are
  ~34 s apart) and reaches the login. So a volume with an enrolled token is
  token-gated only when the token is its *sole* method — no empty keyslot, no TPM,
  no prompt (e.g. after the other keyslots are wiped). `headless` only disables the
  password/PIN prompts (ENOPKG); it does not skip the device monitor wait.
- **TPM2 never blocks.** In v262 any form of TPM2 attach failure is mangled to a
  non-fatal `-EAGAIN` ("Mangle error code: let's make any form of TPM2 failure
  non-fatal", cryptsetup.c ~2010) — no chip, no TPM2 token, PIN failure — and the
  retry loop continues to the next method. That is why a tpm2 root that loses its TPM
  still ends at the passphrase prompt.
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
- A **TPM2** keyslot (repart `Encrypt=tpm2`, `repart.c:~5849`) is keyed by the
  *base64-encoded TPM2 secret*, not by an empty string — so `try-empty-password`
  on such a volume is a guaranteed *failed* attempt that falls through to the
  TPM2/PIN/prompt paths, never an unlock.
- LUKS2 tokens (FIDO2, TPM2, PKCS#11) live in the volume's 1 MiB JSON header and
  **reference the keyslot they unlock**: in systemd 262 enrolling one adds a new
  keyslot holding the volume key keyed by a base64-encoded secret only the token
  can reconstruct (FIDO2: `HMAC-SHA256(internal key, salt)`; PKCS#11: the token's
  decrypted key — cryptenroll-{fido2,pkcs11}.c), and wipes none; the enrolled set
  is readable without unlocking: `dd if=<dev> bs=1M count=1 | grep '"type":"fido2"'`.
- That is what makes "install with an empty slot, enrol a token, wipe the empty
  slot" work: the new token slot can unlock the volume, so the empty slot can be
  wiped authorised by it — and the wipe must be authorised by **another** live slot
  than the one being wiped (cryptsetup refuses the latter).
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

## The no-TPM2 FIDO2 path

Install the root as LUKS2 with an **empty keyslot only** (repart `Encrypt=key-file`,
no key file — the documented empty-key default) and no TPM2 token. First boot is
hands-off (the empty slot); the first user then enrolls a FIDO2 token and wipes
the empty slot (end of this section). This is the **no-tpm** image variant
(`VARIANT=no-tpm images/build.sh`; the choice is recorded as an image label and
carried into the installer's addon, docs/installer.md).

**Locked-down boot leaves no kargs channel.** For a type-2 entry systemd-boot marks
the embedded command line `options_implied` (`boot.c:2526`) and passes nothing to the
PE (`call_image_start`, `boot.c:3077`: `options_initrd ?: options_implied ? NULL :
options`) — the stub boots with its own signed, measured command line. Even the QEMU test channel
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
load-path race (`unit_find_dropin_paths`, load-dropin.c:16 → `unit_file_find_dirs`,
dropin.c:144-176: the unit's own name, its template, and the type-level dir), so a
drop-in shipped in the image's initrd applies to gpt-auto's generated
`systemd-cryptsetup@root.service` — and a drop-in may clear and replace
`ExecStart=`.

**But one drop-in for all modes is not enough: the safe option sets are
mode-specific, and the two modes' sets are mutually exclusive.** The tempting
static superset (`tpm2-device=auto,tpm2-measure-pcr=…,fido2-device=auto,
try-empty-password=true`) breaks, because *measurement* and the token *plugins*
are exclusive: `use_token_plugins()` (cryptsetup.c:1401) returns false whenever
`tpm2-measure-pcr=`/`tpm2-measure-keyslot-nvpcr=` is set ("there's no way to
query the volume key when plugins are used"), which sends FIDO2 auto-discovery to
the **in-tree** path — and the in-tree path returns a **fatal** `-ENXIO` ("No
valid FIDO2 token data found") when the header has *no* FIDO2 token, whereas the
plugin path converts exactly that to `-EAGAIN` and falls through. `verb_attach`'s
retry loop continues only on `-EAGAIN` (`if (r != -EAGAIN) return r;`, line ~2686),
so a fresh no-TPM root (empty slot only, no token yet: the exact first-boot
state) fails its boot at the FIDO2 step. The superset also degrades a tpm2 root that
lost its TPM: today that ends at the passphrase prompt (a recovery key can still
answer), with the superset the in-tree FIDO2 `-ENXIO` kills the unit first.

**So the mode is a property of the image, and each variant carries its own static
options.** Two build variants (one build arg), one image per mode:

| variant | initrd drop-in | notes |
| --- | --- | --- |
| **tpm2** (the current default) | none — gpt-auto's unit stands as generated | byte-identical to today: measured UKI boot → `tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-measure-keyslot-nvpcr=yes` (`tpm2-measure-pcr=yes` = `TPM2_PCR_SYSTEM_IDENTITY`, PCR 15 in v262: the volume key and the NvPCR); non-measured boot → no TPM2 options, fail-closed as today. The TPM2 unlock is already the in-tree path today (the measure flags disable the plugins), so nothing moves. |
| **no-TPM LUKS** (new) | one file in the initrd, `ExecStart=` cleared and replaced (see below) | no TPM2/measure options, so `use_token_plugins()` stays true (the initrd ships `libcryptsetup-token-systemd-{fido2,pkcs11,tpm2}.so` and `libfido2`), and the *plugin* FIDO2 path is the one that runs. |

The no-TPM variant's drop-in (in the initrd,
`/usr/lib/systemd/system/systemd-cryptsetup@.service.d/` — the template's
drop-in directory, which applies to every instance, `root` included):

    [Service]
    ExecStart=
    ExecStart=/usr/bin/systemd-cryptsetup attach root /dev/gpt-auto-root-luks '' 'fido2-device=auto,try-empty-password=true'

State matrix of the no-TPM variant — one static line for the whole life of the
volume:

| state | what the attach does |
| --- | --- |
| **fresh** (empty slot only, no token) | the FIDO2 plugin finds no `systemd-fido2` metadata → `-ENXIO`/`-ENOENT`/`-ENOTUNIQ` → converted to `-EAGAIN` (cryptsetup-token-systemd-fido2.c:130) and dropped immediately (the 30-second monitor only starts when a token *is* in the header) → `try-empty-password` unlocks. Hands-off. |
| **enrolled, token present** | the plugin unlocks the volume key; the PIN comes through ask-password (the `cryptsetup.fido2-pin` credential, or the plymouth prompt). |
| **enrolled, token absent** | the plugin's device enumeration finds nothing (`FIDO_ERR_INTERNAL` → synthetic `-EAGAIN`) → the 30-second udev monitor for the device → on timeout `-EAGAIN` again → the attach loop drops the token method and `try-empty-password` unlocks with the empty key. The boot is ~30 s slower per volume, not failed; the volume is token-gated only once the empty keyslot is wiped. |
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

The install side of the no-TPM variant (docs/installer.md): the installer's repart
runs with `--seed=` set to the machine id it generates (every partition, LUKS and
filesystem UUID is derived from it), `Encrypt=key-file` appended to both the root
and the /var definitions with *no* `KeyFile=`/`--key-file=` (the documented
zero-length-key default), and opens both volumes with the empty password
(`try-empty-password=true`) for the install itself. The tpm2 variant differs only
in the `Encrypt=` values (`tpm2`) and the options the installer passes to its own
`systemd-cryptsetup attach` calls.

The installer can enrol a FIDO2 key into the volumes' LUKS2 headers while they are
still closed (before the install itself), with `systemd-cryptenroll --fido2-device=auto`
and the volume key fetched the same way the volume is sealed: `--unlock-empty` for
the no-TPM variant's empty-key root and /var, `--unlock-tpm2-device=auto` for the
TPM-sealed /var (both variants; its boot path, the initrd's /var unlock, already
tries `fido2-device=auto`). Each enrolment adds a keyslot and a `systemd-fido2`
token (see the LUKS2 facts); the existing keys (the TPM seal, the empty key) are
untouched, so the state after such an install is "enrolled, token present (or
absent at boot)" in the matrix above, never "fresh". At boot, a TPM-sealed volume
still unlocks from the TPM first, so the key there is the fallback for a lost
TPM; a volume with only the empty key (the no-TPM image; /var on the tpm2 image
when there is no TPM) boots without the key too, ~30 s slower per volume: the
token wait times out and the empty key unlocks, so the key is a fast path rather
than a gate. A volume becomes token-gated only when the token is its sole
method (the other keyslots wiped, below). The tpm2 variant's TPM-sealed *root*
is not offered: the unit gpt-auto
generates for it carries no FIDO2 option (a static drop-in cannot add one safely),
so an enrolled token would never be tried there.

Remaining open items:

- The drop-in couples the image to gpt-auto's device naming
  (`/dev/gpt-auto-root-luks`) and the volume name `root`; re-derive it at each
  systemd rebase (we pin the systemd version per release, so a rebase is the
  only thing that can drift it).
- **More than one FIDO2 token** (two keys enrolled) is unverified: the in-tree
  path tries tokens in turn, but the plugin path's `-ENOTUNIQ` → `-EAGAIN`
  conversion suggests libcryptsetup can signal "not unique" and bail to the
  next method instead of trying the second token. One key is the designed
  path; verify the plugin's iteration semantics before promising multiple.
- *Resolved* — the console on a type-2 entry: the `kernel-cmdline-extra`
  channel is type-1 only, but the serial console is a UKI addon on the ESP
  (see "Levers that do not work"), so a locked-down system gets `console=`
  without baking it into the UKI and without any test-only build flag.

If the installer did not enrol the key (or for a volume it could not offer),
the first user enrolls a token on the booted system
(`run0 systemd-cryptenroll --fido2-device=auto /dev/mapper/root`) and wipes
slot 0 through the token (the empty slot is the one being wiped, so its own
password cannot authorise the wipe — see the LUKS2 facts above). Every boot
after that is token-gated; the boot configuration never changes.

## TPM2 with a PIN (tpm2 variant)

The installer can protect the TPM seal with a PIN (docs/installer.md): the TPM
then refuses to release the volume key without it, so a copy of the disk alone
cannot unlock it and the PIN is asked at every boot. It is offered only on the
tpm2 variant, for an encrypted root, after the recovery key; the option values
are `yes` (Argon2id hardening of the PIN, the recommended one) and `direct`
(PBKDF2-HMAC-SHA256 with the token's salt, compatible with older systemd). The
PIN is never written anywhere on the machine.

**The PIN is bound after the volumes exist.** repart v262 has no
`--tpm2-with-pin`, so the seal the installer's repart writes is PIN-less. The
PIN is bound later, per volume, while the volumes are still closed (the
installer's step 6, after the recovery key is enrolled — that enrolment
unlocks through the PIN-less seal, which no longer exists after the wipe
below):

    NEWPIN=<pin> systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes \
        --wipe-slot=tpm2 --unlock-tpm2-device=auto --unlock-headless <part>

**The binding is a replacement, and the replacement is what makes it a
gate.** The sealing policy incorporates the PIN as a *constant*
`PolicyAuthValue` marker — the hash of the `TPM2_CC_PolicyAuthValue` command
code, not of the PIN value (`tpm2_calculate_policy_auth_value`,
tpm2-util.c:4890; the TPM side, `tpm2_policy_auth_value`) — so a PIN-bound
token has a different policy hash than the PIN-less one with the same PCR
set. The enrolment's `search_policy_hash` therefore does not find the existing
token: it seals a *new* keyslot for the new seal, and `--wipe-slot=tpm2`
deletes the PIN-less token and slot — `find_slots_by_mask` matches only TPM2
tokens, so a FIDO2 token and the recovery keyslot are left alone, and the
newly enrolled slot is kept (`wipe_except_slot`). The wipe is authorised with
the volume key `--unlock-tpm2-device=auto` fetched through the PIN-less seal:
no PIN is needed for the unlock, `$NEWPIN` feeds the new seal only. Keeping
both seals would defeat the point: at boot the PIN-less token would be found
first and would always win.

**The root needs no new unit: the in-tree path already handles the PIN.** The
measured-boot unit (gpt-auto; the tpm2 variant carries no drop-in) already has
`tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-measure-keyslot-nvpcr=yes` and no
`headless=`. The measure flags force the in-tree path (above), which scans the
header's TPM2 tokens in order (`find_tpm2_auto_data`) and takes each token's
flags from its own JSON — the boolean `tpm2-pin` field cryptenroll writes — so
a PIN-bound token prompts on its own; the attach `tpm2-pin=` option, which
only forces the flag, is not needed. `get_pin()` (cryptsetup-tpm2.c) resolves
the PIN in this order:

1. the `$PIN` environment variable;
2. the `cryptsetup.tpm2-pin` credential — the unit's drop-in
   (`credential.conf`) already carries `ImportCredential=cryptsetup.*`, and a
   boot can be handed the credential through SMBIOS type 11
   (`io.systemd.credential:cryptsetup.tpm2-pin=…`, the test VMs' channel), the
   kernel command line, or the loader's credentials directory;
3. ask-password. In the initrd the service has no tty (no `StandardInput` in
   the unit), so `ask_password_auto` (the flags are the unit's `headless=`,
   i.e. none here) goes credential → agent: the request lands on
   `/run/systemd/ask-password`. The keyring branch of `ask_password_auto` is
   *not* consulted on this path (it is restricted to callers that set
   `ASK_PASSWORD_NO_AGENT` and `ASK_PASSWORD_ACCEPT_CACHED`), so each
   PIN-bound volume is prompted once — root first, then /var, the same PIN
   twice — unless the credential is present. (The answers are stored in the
   uid-0 keyring under `tpm2-pin` with a 2.5-minute expiry, a side effect
   nothing in this flow reads; a wrong PIN re-asks through the same channel,
   up to 5 times per volume, and the loop clears `ASK_PASSWORD_ACCEPT_CACHED`
   after the first ask so a cached wrong answer is never retried.)

The agent needs a running watcher, and the initrd has none (the preset
disables everything; the stock `systemd-ask-password-console.service` has no
`[Install]` section and is normally pulled by its `.path`, a main-system
thing), so the image carries its own: `inglenook-ask-password.service`,
initrd-scoped (`ConditionPathExists=/etc/initrd-release`, stops at
switch-root), which runs `systemd-tty-ask-password-agent --watch --console`
and serves any ask-password request on the console. With a credential present
it is never invoked, so it is inert on boots that pass their secrets that
way; without one, it is the difference between a prompt and a hang (the agent
path creates the socket and waits forever for an answer nobody serves). On
the booted system the volumes are already active (the attach short-circuits,
above), so the PIN is never asked there.

**/var needed two changes.** The initrd's `var-mount` attached the volume with
`headless=`, which makes `get_pin` refuse to prompt (`ENOPKG`, after the
`$PIN` check); that flag is gone, and the service imports the
`cryptsetup.*` credentials the way the root's unit does (the mkosi-initrd
`credential.conf` covers the root). A PIN-less /var seal carries no
`USE_PIN`, so it never prompts — both changes are no-ops for those.

**What a forgotten PIN costs.** Five wrong PINs (or no answer) turns the
TPM2 method into `-EAGAIN` ("TPM2 PIN unlock failed, falling back to
traditional unlocking."), and the attach loop continues: the root (a recovery
keyslot, if one was created) ends at the passphrase prompt, answered by the
same console agent. The tpm2 image's /var is TPM2-only (no empty keyslot, no
recovery keyslot — the recovery key is enrolled into the root only), so a
forgotten PIN without a FIDO2 token on /var leaves it unbootable: the prompt
times out, the /var service fails, there is no switch-root, the root's
content is intact, and the volume is the loss. That is what the installer's
finishing notice points at (the recovery key for the root, a FIDO2 token for
/var, "if you have one").
