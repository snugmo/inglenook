# Hardware-token logins (FIDO2 with PIN first)

How users sign in with a hardware key on this image, what was tested and what was not.
The tests (`images/test/token.sh`) use a software FIDO2 authenticator
(`images/test/softfido.py`) in the QEMU VM; **no real YubiKey has been tried yet**.

## What the image provides

- `systemd-homed` in the PAM stack: the Containerfile runs `authselect select … with-systemd-homed`
  (the base's other features stay), so `pam_systemd_home` is in `system-auth`/`password-auth`.
  That covers the console login, `run0` (polkit's `polkit-1` stack) and sshd.
- `pam-u2f` and `pamu2fcfg` for FIDO2 keys on plain `/etc/passwd` accounts. The authselect feature
  `with-pam-u2f` is **off**: turning it on makes every plain account need a key mapping.
- `/etc/ssh/sshd_config.d/20-systemd-homed.conf`: `AuthorizedKeysCommand userdbctl ssh-authorized-keys %u`
  (keys come from the homed record). Do not add `AuthenticationMethods publickey,password`: it locks out
  root and every token-only user.
- `libfido2` (systemd's FIDO2 support is compiled in), `opensc`/`pcsc-lite` for PIV/PKCS#11.

## A token-only homed user

`homectl create` always asks for a password, so the user is created with a throwaway one and the
password is removed afterwards:

```
# token plugged in; --fido2-with-client-pin=yes needs the token's PIN to be set first
NEWPASSWORD=throwaway homectl create alice --storage=directory --fido2-device=auto \
    --fido2-with-client-pin=yes --fido2-with-user-presence=yes
```

then re-sign the record without `privileged.hashedPassword` (`images/test/token/nopw.sh` does it: drops the
hash and the signature and bumps `lastChangeUSec`, then `homectl update --identity=`). `homectl inspect`
then says `Password OK: no (none set)`. Keep a second token or `--recovery-key=yes`: a lost token
locks the account. `$PIN` is not honoured by `homectl create`; in scripts answer the ask-password queue
(`images/test/token/answerer.sh`).

## Results (software token, permissive SELinux)

| Path | Result |
|---|---|
| homed FIDO2, no PIN | works; the record's `fido2HmacSalt` holds a hash of the token-derived secret, so plain directory homes need no password |
| homed FIDO2, PIN + presence | right PIN logs in; wrong PIN rejected (the token counts retries); no PIN refused |
| homed PKCS#11 (SoftHSM) | works with RSA-2048 and EC P-256 (systemd 262 has ECDH; the key needs `CKA_DERIVE`); not part of `token.sh` |
| `polkit-1` (run0) | same as the login stack, with homed users and with pam-u2f |
| pam-u2f on a plain account | works with `pinverification=1`; wrong/missing PIN and unmapped accounts are refused |
| ssh `ecdsa-sk` key | works with the token, `device not found` without it; not part of `token.sh` |
| SELinux | no denials from homed, pam_u2f or the token devices |

## LUKS homes (`--storage=luks`)

The homed default. Each home is a sparse image file `/home/<user>.home` (GPT, then LUKS2, then btrfs); the
record is in `/var/lib/systemd/home/<user>.identity`. The token is then also what unlocks the data: homed
adds one LUKS keyslot per credential (the FIDO2 hmac-secret is the passphrase), another for a recovery key.
`token.sh` checks all of the following with the software token.

- **Create** like a directory home with `--recovery-key=yes` (printed once, save it; or
  `--recovery-key-file=`), `--disk-size=` (the default is 85% of free space) and `--auto-resize-mode=off`
  if the size must stay fixed (the default, `shrink-and-grow`, shrank a 1G home to 274M at logout and
  grows it again at login). The password needs `NEWPASSWORD` and passes homed's quality check (a
  base64 random string does, `pw1` does not). Strip the password from the record with `nopw.sh`.
- **The password keyslot outlives the record's hash.** After `nopw.sh` homed refuses the password, but the
  LUKS volume still opens with it (`cryptsetup open --test-passphrase`), so anyone with the image file and
  that password bypasses the token. Create with a random password you discard, then wipe slot 0 while the
  home is inactive: `cryptsetup luksKillSlot --key-file <recovery key> /dev/loopNp1 0` (attach with
  `losetup -fP`; the key file must not end in a newline). cryptsetup will not authorize a wipe with the
  slot's own passphrase ("No key available with this passphrase"), so another slot is needed: the
  recovery key made at creation. homed keeps working with the token and recovery slots.
- Token + PIN unlocks; wrong PIN is refused; the recovery key unlocks without the token (PAM asks the PIN
  first, then "Try again with password"); no secret, no unlock.

### Several tokens, a recovery key, and changing them later (systemd 262, tested; code read at v262)

homed rewrites **all** LUKS keyslots at once (`home_passwd_luks`): it adds a slot for every password it
currently holds, then destroys every other slot. So:

- **Several tokens work, but only when all are plugged in and given in one command**:
  `homectl create … --fido2-device=/dev/hidraw0 --fido2-device=/dev/hidraw1 --recovery-key=yes` gives four
  slots (password, recovery key, two tokens); each token, and the recovery key, unlocks the home alone.
  `--fido2-device=` is repeatable, but each use drops the record's existing tokens, so
  `homectl update --fido2-device=B` alone **replaces** A with B (A stops working). Re-list every token
  to keep it (`--fido2-device=A --fido2-device=B`).
- **A recovery key or second token can be added later, with conditions**: the record must still hold a
  hashed password and its plaintext must be supplied (`PASSWORD=`), and all tokens must be plugged in.
  `homectl update m2 --fido2-device=A --fido2-device=B --recovery-key=yes` took a 2-slot home to 4 slots
  and the recovery key opened it.
- **`homectl update --recovery-key=yes` on its own does not touch the keyslots.** The record gets the
  hashed key, the LUKS header gets nothing, so the key cannot unlock the volume. In `homectl.c`
  `and_change_password` is true only for `--fido2-device`/`--pkcs11-token-uri`, not `--recovery-key`;
  yet the homectl man page's own example is `homectl update emily --recovery-key=yes`. Looks like an
  upstream bug (not reported by us; upstream issues not checked). Workaround: pass a token option in the
  same command.
- **A record with no hashed password cannot have its keyslots changed**: the sync refuses ("User record
  has no hashed passwords"). That is the state `nopw.sh` leaves, hence "Required key not available" on an
  active home and "Invalid argument" with the recovery key as `PASSWORD=`. Every recovery key in the
  record needs its plaintext at each sync too ("Missing plaintext recovery key"). So with a
  token-only home, plan to put a temporary hashed password back (and type the recovery key) to change
  credentials. Not tested.
- **Adding or changing a token needs every enrolled token plugged in** (tested): with token B unplugged,
  a sync (`homectl passwd`) fails with "Resource temporarily unavailable" and changes nothing (still 3
  slots). A token can instead be **dropped on purpose**: `homectl update --fido2-device=A --fido2-device=C`
  with B unplugged succeeded; afterwards A and C unlock the home alone, B no longer does, and the slot
  count stayed 3. That is the path for a lost or stolen key.
- **Recovery key plus password at a sync**: with both in the record, `PASSWORD=<password>` is not enough;
  homectl prompts for the recovery key ("Recovery key incorrect or not sufficient, please try again")
  and the update then goes through when the key is answered (2 → 4 slots, two tokens). In scripts, answer
  the ask-password queue as the tests do.
- **`systemd-cryptenroll` refuses**: "LUKS2 volume is managed by systemd-homed, please use homectl to
  enroll tokens." A slot added by `cryptsetup luksAddKey` instead would be unknown to homed (it only
  tries the passwords of its record) and the next sync destroys it.
- Not tried: LUKS homes on the XFS `/var` variant, ssh login to a LUKS home, `homectl passwd` flows.

## Limits to know before relying on it

- **ssh to a homed user needs the token in the server.** The public-key login only works because homed
  unlocks the home with the token plugged into the machine being logged into; without it the login
  fails ("Security token not inserted, please enter password"). A token in the ssh client does not
  help, and a PIN-protected homed token cannot work for ssh pubkey logins at all (no prompt). For
  remote machines use `sk-` ssh keys on a plain account, or a home that is already unlocked.
- Real tokens: untested. Differences to check on hardware: PIN retry lockout, touch prompts, `uv`
  (built-in verification) tokens, PIV through OpenSC/ykcs11 for homed's PKCS#11 route
  (`homectl --pkcs11-token-uri=list` trips on SoftHSM's extra uninitialised slot; name the token
  by URI there).
- Enforcing SELinux and confined users are untested.
- `softfido.py` pre-flight detail (found the hard way): systemd probes a credential with an
  assertion with `up=false` and no PIN; a token must answer that without asking for the PIN, as real
  ones do, otherwise `homectl create --fido2-with-client-pin=yes` loops on PIN prompts.
