#!/bin/bash
stopTracked() {
  local dir=$1 pid file tries
  for file in "$dir/pids" "$dir/fake.pid"; do
    [ -f "$file" ] || continue
    while read -r pid; do
      kill "$pid" 2> /dev/null
    done < "$file"
    while read -r pid; do
      tries=0
      while kill -0 "$pid" 2> /dev/null && [ $tries -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
      done
      kill -9 "$pid" 2> /dev/null
    done < "$file"
  done
  return 0
}

randomHex() { head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

freePort() {
  python3 -I -c '
import socket, sys
for port in range(int(sys.argv[1]), 65000):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        s.close()
        continue
    s.close()
    print(port)
    break
' "$((18500 + RANDOM % 3000))"
}

httpCode() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

waitFor401() {
  local url=$1 seconds=$2 i
  for ((i = 0; i < seconds; i++)); do
    [ "$(httpCode "$url")" = 401 ] && return 0
    sleep 1
  done
  return 1
}

chipName() {
  case "$(uname -m)" in
    arm64 | aarch64) echo aarch64 ;;
    *) echo amd64 ;;
  esac
}

checksumOf() { shasum -a 256 "$1" | awk '{ print $1 }'; }

secretHeader() { printf 'Authorization: Bearer %s\n' "$2" > "$1"; }

emails() {
  python3 -I -c '
import json, sys
def walk(x):
    if isinstance(x, dict):
        if "email" in x:
            yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
for e in walk(json.load(open(sys.argv[1]))):
    print(e["email"])
' "$1"
}

writeKeyProbes() {
  cat > "$1" <<EOF
o="-i \$HOME/.config/relaybar/hub_key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=\$HOME/.config/relaybar/known_hosts -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o ExitOnForwardFailure=yes"
hub=homeuser@$2
ssh \$o \$hub id 2> /dev/null < /dev/null
echo "rc=\$?"
ssh \$o -W 127.0.0.1:22 \$hub 2> /dev/null < /dev/null | head -c 20
ssh \$o -N -R 127.0.0.1:18317:127.0.0.1:22 \$hub 2> /dev/null < /dev/null
echo "remote=\$?"
timeout 8 ssh \$o -N -L 127.0.0.1:18318:127.0.0.1:8317 \$hub 2> /dev/null < /dev/null &
sleep 3
echo "local=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18318/v1/models)"
wait
timeout 4 ssh \$o -N -R /tmp/rb-probe.sock:127.0.0.1:22 \$hub 2> /dev/null < /dev/null
echo "unix=\$?"
true
EOF
}
