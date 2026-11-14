#!/usr/bin/env bash
# Triggers each refusal of quickstart_loop.sh from the real script, with a stand-in `nerva`
# (NRV-E0741: bad usage or setup, a format failure, a changed QUICKSTART.md; NRV-E0742: a replica
# or the gateway died). It starts no real cluster, but it needs ports 3001 to 3003 and 8080 free.
# Run from anywhere: scripts/quickstart_loop_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script=$here/quickstart_loop.sh
tmp=$(mktemp -d)
holder=
cleanup() { [ -z "$holder" ] || kill "$holder" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0

# The stand-in: SHIM_MODE picks the failure.
cat > "$tmp/nerva" <<'SHIM'
#!/usr/bin/env bash
case "$1:$SHIM_MODE" in
  format:format-fails) echo "error[NRV-E0706]: format: no space left on device"; exit 2 ;;
  format:*) : > "${@: -1}"; exit 0 ;;
  start:replica-dies) echo "error[NRV-E0007]: start: cannot listen: the address is in use"; exit 1 ;;
  start:*) echo listening; exec sleep 1000 ;;
  api:gateway-dies) echo "error[NRV-E0007]: api: cannot listen: the address is in use"; exit 1 ;;
  api:*) echo listening; exec sleep 1000 ;;
esac
SHIM
chmod +x "$tmp/nerva"

# expect <name> <exit> <text that must be in the output> <command...>
expect() {
  local name=$1 want=$2 text=$3 got out; shift 3
  out=$("$@" 2>&1); got=$?
  if [ "$got" != "$want" ] || ! printf '%s' "$out" | grep -qF -- "$text"; then
    echo "quickstart_loop_test: $name: want exit $want and '$text', got exit $got:" >&2
    printf '%s\n' "$out" >&2
    fail=1
  fi
}
# Nothing is left behind: no workdir content, no nerva stand-in running.
clean() {
  if [ -n "$(ls -A "$1" 2>/dev/null)" ]; then echo "quickstart_loop_test: $2: left $(ls "$1")" >&2; fail=1; fi
}

w=$tmp/w1
expect "no arguments" 2 "error[NRV-E0741]: quickstart_loop.sh: usage:" "$script"
expect "not a binary" 2 "error[NRV-E0741]" "$script" "$tmp/missing" 1 "$w"
expect "runs 0" 2 "runs must be a positive integer" "$script" "$tmp/nerva" 0 "$w"
expect "runs abc" 2 "error[NRV-E0741]" "$script" "$tmp/nerva" abc "$w"
expect "slow_s abc" 2 "slow_s must be a number" "$script" "$tmp/nerva" 1 "$w" abc
: > "$tmp/afile"
expect "workdir is a file" 2 "cannot use workdir" "$script" "$tmp/nerva" 1 "$tmp/afile"
clean "$w" "bad arguments"

# A changed page: a copy of the script beside a QUICKSTART.md that lost the gateway line.
mkdir -p "$tmp/c/scripts" "$tmp/c/docs"
cp "$script" "$tmp/c/scripts/"
grep -vF -- '--listen=127.0.0.1:8080' "$here/../docs/QUICKSTART.md" > "$tmp/c/docs/QUICKSTART.md"
expect "page changed" 2 "QUICKSTART.md changed" "$tmp/c/scripts/quickstart_loop.sh" "$tmp/nerva" 1 "$tmp/w2"
rm "$tmp/c/docs/QUICKSTART.md"
expect "page missing" 2 "docs/QUICKSTART.md not found" "$tmp/c/scripts/quickstart_loop.sh" "$tmp/nerva" 1 "$tmp/w2"
clean "$tmp/w2" "drift guard"

# A busy port.
python3 -I -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8080)); s.listen(1); time.sleep(600)' &
holder=$!
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null && break; sleep 0.1; done
expect "port busy" 2 "port 8080 is already in use" "$script" "$tmp/nerva" 1 "$tmp/w3"
kill "$holder"; wait "$holder" 2>/dev/null; holder=
clean "$tmp/w3" "busy port"

# Failures of the stand-in.
SHIM_MODE=format-fails expect "format fails" 2 "run 1: format of replica 0 failed: error[NRV-E0706]" \
  "$script" "$tmp/nerva" 1 "$tmp/w4"
clean "$tmp/w4" "format failure"
SHIM_MODE=replica-dies expect "replica dies" 3 "error[NRV-E0742]: quickstart_loop.sh: run 1: replica 0 did not start: error[NRV-E0007]" \
  "$script" "$tmp/nerva" 1 "$tmp/w5"
SHIM_MODE=replica-dies expect "kept logs named" 3 "logs of the runs kept" "$script" "$tmp/nerva" 1 "$tmp/w5"
SHIM_MODE=gateway-dies expect "gateway dies" 3 "error[NRV-E0742]: quickstart_loop.sh: run 1: gateway exited before listening: error[NRV-E0007]" \
  "$script" "$tmp/nerva" 1 "$tmp/w6"
for w in w5 w6; do
  n=$(ls -d "$tmp/$w"/loop.*/slow_1 2>/dev/null | wc -l)
  [ "$n" -ge 1 ] || { echo "quickstart_loop_test: $w: the logs were not kept" >&2; fail=1; }
done
if pgrep -f "$tmp/nerva" >/dev/null; then echo "quickstart_loop_test: a stand-in is still running" >&2; fail=1; fi

[ "$fail" = 0 ] && echo "quickstart_loop_test: ok"
exit "$fail"
