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

### Changing credentials after creation does not work for token-only homes (systemd 262, tested)

- `homectl update` of a token-only LUKS home asks for a password; if it is active instead, the keyslot sync
  fails with "Required key not available". The recovery key as `PASSWORD=` fails too ("Invalid argument").
- With a password still in the record, `homectl update --fido2-device=` **replaces** the enrolled token
  (the old one stops working) instead of adding a second one.
- A recovery key added by `homectl update --recovery-key=yes` is stored in the record but gets **no LUKS
  keyslot**, so it cannot unlock the volume (`cryptsetup` rejects it). Only a recovery key made by
  `homectl create` works.
- Merging a second token's `fido2HmacCredential`/`fido2HmacSalt` into the record by hand is accepted but
  creates no keyslot for it: only the token with a slot still logs in.
- `systemd-cryptenroll` on the image would add LUKS slots, but homed unlocks only with the secrets of its
  own record, so those slots are not used by it.
- Consequence for the design: decide the credentials when the home is created (token, recovery key), and
  for a second token or a later recovery key plan to re-create the home or keep a password in the record.
  Not tried: `--fido2-device=` more than once, `homectl passwd`/password-based flows to resync slots,
  LUKS homes on the XFS `/var` variant, ssh login to a LUKS home.

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
