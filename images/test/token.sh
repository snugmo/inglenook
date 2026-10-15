#!/usr/bin/env bash
# Hardware-token logins with systemd-homed and pam-u2f, using a software FIDO2
# authenticator (softfido.py) inside the VM. The VM gets no physical token, so this
# checks the image's wiring (PAM stack, sshd drop-in, packages, policy) and how
# homed, pam_systemd_home, pam_u2f and run0's polkit stack behave with a token
# that has a PIN. It does not prove anything about real YubiKey hardware.
#
# Needs KVM, OVMF, qemu and vhost-device-vsock, like smoke.sh. Builds the image
# unless IMAGE is set (an existing image ref).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$REPO/build/vm}
export WORK
vm=$HERE/vm.sh
PIN=1234

mkdir -p "$WORK"
[[ -f $WORK/key ]] || ssh-keygen -q -t ed25519 -N '' -C inglenook-test -f "$WORK/key"

"$vm" prep
ref=${IMAGE:-$(SSH_PUBKEY=$(cat "$WORK/key.pub") "$REPO/images/build.sh" | tee /dev/stderr | sed -n 's/^built //p')}
"$vm" install "$ref"
trap '"$vm" stop' EXIT
"$vm" start vsock
# root is reachable with $WORK/key (SMBIOS credential); the baked key is for `user`.
export SSH_USER=root
"$vm" wait

g() { "$vm" ssh "$@"; }
fail=0
check() { # description command-run-in-guest expected-output
  local got; got=$(g "$2" 2>&1 || true)
  if [[ $got == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$3'"; fail=1; fi
}
# Run a PAM service with the given replies; "ok" if authentication and the account check pass.
pam() { echo "python3 /var/tmp/token/pamtest.py $1 $2 ${3:-} >/dev/null 2>&1 && echo ok || echo refused"; }

tar -C "$HERE/token" -c . -C "$HERE" softfido.py | g 'mkdir -p /var/tmp/token && tar -x -C /var/tmp/token'
start_token() { g "systemctl stop softfido 2>/dev/null; modprobe uhid; systemd-run -q --unit=softfido python3 /var/tmp/token/softfido.py /var/tmp/token/state $* && sleep 2"; }

check "pam_systemd_home is in the PAM stack" 'grep -c pam_systemd_home /etc/pam.d/system-auth' 4
check "authselect keeps its other features" 'authselect current --raw | tr " " "\n" | grep -c "^with-"' 3
check "sshd asks userdb for authorized keys" 'sshd -T | grep -i "^authorizedkeyscommand " | cut -d" " -f2-' '/usr/bin/userdbctl ssh-authorized-keys %u'
check "sshd has no AuthenticationMethods restriction" 'sshd -T | grep -i "^authenticationmethods" | tr A-Z a-z' 'authenticationmethods any'

# --- a token without a PIN, a homed user with only that token ---
start_token
check "systemd sees the token" 'systemd-cryptenroll --fido2-device=list | grep -c "^/dev/hidraw"' 1
g "NEWPASSWORD=throwaway timeout 90 homectl create tok1 --storage=directory --shell=/bin/bash --fido2-device=auto --fido2-with-client-pin=no --fido2-with-user-presence=no </dev/null >/dev/null 2>&1; /var/tmp/token/nopw.sh tok1 >/dev/null 2>&1"
g "cat > /var/tmp/token/key.pub; homectl update tok1 --ssh-authorized-keys=@/var/tmp/token/key.pub </dev/null >/dev/null 2>&1" < "$WORK/key.pub"
check "homed user has no password, one FIDO2 token" 'homectl inspect tok1 | grep -E "Password OK|FIDO2 Token" | tr -s " " | tr "\n" ";"' ' Password OK: no (none set); FIDO2 Token: 1;'
check "console login with the token alone" "$(pam login tok1)" ok
check "run0 (polkit-1) login with the token alone" "$(pam polkit-1 tok1)" ok
g 'homectl deactivate tok1 </dev/null >/dev/null 2>&1 || true'
got=$(SSH_USER=tok1 "$vm" ssh 'id -un' 2>&1 || true)
[[ $got == tok1 ]] && echo "ok   ssh public-key login unlocks the home with the token" || { echo "FAIL ssh login as homed user: $got"; fail=1; }
g 'homectl deactivate tok1 </dev/null >/dev/null 2>&1 || true; systemctl stop softfido'
sleep 1
got=$(SSH_USER=tok1 "$vm" ssh 'id -un' 2>&1 || true)
[[ $got != tok1 ]] && echo "ok   no token, no ssh login (the token must be in the server)" || { echo "FAIL ssh login worked without the token"; fail=1; }

# --- the same token with a PIN, user verification needed ---
start_token --set-pin $PIN
check "token reports a PIN" 'systemd-cryptenroll --fido2-device=list | grep "^/dev/hidraw" | tr -s " " | cut -d" " -f5' ✓
g "systemd-run -q --unit=answerer /bin/sh /var/tmp/token/answerer.sh $PIN; rm -f /run/systemd/ask-password/*
NEWPASSWORD=throwaway timeout 90 homectl create tok2 --storage=directory --shell=/bin/bash --fido2-device=auto --fido2-with-client-pin=yes --fido2-with-user-presence=yes </dev/null >/dev/null 2>&1
/var/tmp/token/nopw.sh tok2 >/dev/null 2>&1; systemctl stop answerer"
check "PIN user has no password" 'homectl inspect tok2 | grep "Password OK" | tr -s " "' ' Password OK: no (none set)'
check "login with the right PIN" "$(pam login tok2 $PIN)" ok
g 'homectl deactivate tok2 </dev/null >/dev/null 2>&1 || true'
check "login refused with a wrong PIN" "$(pam login tok2 0000)" refused
check "login refused without a PIN" "$(pam login tok2)" refused
check "run0 (polkit-1) login with the right PIN" "$(pam polkit-1 tok2 $PIN)" ok

# --- a LUKS home (image file) unlocked by the PIN token, with a recovery key ---
# homectl create needs a password; the LUKS keyslot made from it outlives the record's hash
# (the volume still opens with it), so it is random and discarded, then the slot is wiped.
g "systemd-run -q --unit=answerer /bin/sh /var/tmp/token/answerer.sh $PIN; rm -f /run/systemd/ask-password/*
NEWPASSWORD=\$(head -c32 /dev/urandom | base64) timeout 120 homectl create tok3 --storage=luks --disk-size=1G --shell=/bin/bash --fido2-device=auto --fido2-with-client-pin=yes --fido2-with-user-presence=yes --recovery-key=yes </dev/null 2>&1 | grep -oE '[a-z]{8}(-[a-z]{8}){7}' > /var/tmp/token/rk
timeout 120 /var/tmp/token/nopw.sh tok3 >/dev/null 2>&1; systemctl stop answerer"
check "LUKS home: no password, token and recovery key" 'homectl inspect tok3 | grep -E "Storage|Password OK|FIDO2 Token|Recovery Key" | tr -s " " | tr "\n" ";"' ' Password OK: no (none set); Storage: luks (strong encryption); FIDO2 Token: 1;Recovery Key: 1;'
check "LUKS home: login with the right PIN" "$(pam login tok3 $PIN)" ok
g 'sleep 3; homectl deactivate tok3 </dev/null >/dev/null 2>&1 || true'
check "LUKS home: login refused with a wrong PIN" "$(pam login tok3 0000)" refused
g 'systemctl stop softfido; sleep 1'
check "LUKS home: recovery key unlocks it without the token" "python3 /var/tmp/token/pamtest.py login tok3 x \$(cat /var/tmp/token/rk) >/dev/null 2>&1 && echo ok || echo refused" ok
g 'sleep 3; homectl deactivate tok3 </dev/null >/dev/null 2>&1 || true'
check "LUKS home: no secret, no unlock" "$(pam login tok3)" refused
check "LUKS home: three keyslots (discarded password, recovery key, token)" 'L=$(losetup -fP --show -r /home/tok3.home); cryptsetup luksDump ${L}p1 | grep -c "^  [0-9]: luks2"; losetup -d $L' 3
check "LUKS home: the discarded password's slot can be wiped with the recovery key" 'L=$(losetup -fP --show /home/tok3.home); cat /var/tmp/token/rk | tr -d "\n" | cryptsetup luksKillSlot --key-file - ${L}p1 0; cryptsetup luksDump ${L}p1 | grep -c "^  [0-9]: luks2"; losetup -d $L' 2
start_token --set-pin $PIN
check "LUKS home: still unlocks with the token after the wipe" "$(pam login tok3 $PIN)" ok
g 'sleep 3; homectl deactivate tok3 </dev/null >/dev/null 2>&1 || true'

# --- pam-u2f on a plain /etc/passwd account ---
g "python3 /var/tmp/token/ptyrun.py $PIN pamu2fcfg -N -u user -o pam://inglenook -i pam://inglenook | tr -d '\r' | grep '^user:' > /var/tmp/token/u2f_keys
printf 'auth required pam_u2f.so authfile=/var/tmp/token/u2f_keys origin=pam://inglenook appid=pam://inglenook pinverification=1\naccount required pam_permit.so\n' > /etc/pam.d/u2ftest"
check "pam-u2f key registered for user" 'grep -c "^user:" /var/tmp/token/u2f_keys' 1
check "pam-u2f login with the right PIN" "$(pam u2ftest user $PIN)" ok
check "pam-u2f refused with a wrong PIN" "$(pam u2ftest user 0000)" refused
check "pam-u2f refused for an account without a key" "$(pam u2ftest root $PIN)" refused

# No new denials are expected from homed, pam_systemd_home, pam_u2f or the token device. The
# two in the token baseline come from answering `homectl create`'s PIN prompts through the
# ask-password queue (there is no tty in the test); a real console login uses PAM instead.
AVC_BASELINE_EXTRA="$HERE/selinux-denials.token.baseline" "$vm" new-avc || fail=1
exit $fail
