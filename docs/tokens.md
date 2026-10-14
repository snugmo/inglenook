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
