#!/bin/sh
# answerer.sh REPLY: answer every password prompt in the ask-password queue with REPLY
while :; do
  for f in /run/systemd/ask-password/ask.*; do
    [ -e "$f" ] || continue
    s=$(sed -n 's/^Socket=//p' "$f")
    echo "answering: $(sed -n 's/^Message=//p' "$f")"
    printf '%s' "$1" | /usr/lib/systemd/systemd-reply-password 1 "$s" || true
    rm -f "$f"
  done
  sleep 0.5
done
