#!/usr/bin/env bash
# The apt and dnf repositories in the R2 bucket (docs/releases/packages.md, "`repos-ready`",
# "`repos`"; docs/ERRORS.md, NRV-E1139 to NRV-E1157). Each refusal prints one coded block,
# `error[<code>]: package_repos.sh: <what>` with a cause and a fix line, and exits 1.
#
#   package_repos.sh ready <tag> <published>   bind the draft's packages in a signed manifest
#                                              (steps 1 to 3 of `publish`, then the binding); with
#                                              <published> true it writes nothing
#   package_repos.sh publish <tag>             put pending packages, regenerate and sign both
#                                              channels, upload, check what is served
#   package_repos.sh refresh                   publish without a tag, then the 45-day check; with
#                                              RPM_KEY (`exclude <Key ID>` or `restore <Key ID>`, the
#                                              owner only) it first marks that key's rpms
#   package_repos.sh fresh                     stable's served InRelease has 10 days of Valid-Until
#                                              left (writes nothing, reads no secret)
#   package_repos.sh served [<tag>]            what packages.nerva.pro serves equals the bucket
#   package_repos.sh verify-manifest <file> <generation>   verify one manifest object exactly as a
#                                              reader would and print the signed text (no bucket)
#   package_repos.sh sums-verify <tag>         the release's SHA256SUMS.asc verifies against its
#                                              SHA256SUMS under packaging/keys/ (no secret; P417c)
#   package_repos.sh cleanup                   kill gpg-agent, remove the temporary directories
#
# Environment: R2_ENDPOINT, R2_BUCKET (empty: NRV-E1139), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (read by
# r2.py only), PACKAGES_BASE_URL, RPM_KEY, TRIGGERING_ACTOR, PACKAGE_REPOS_OWNER (the refresh's rpm_key), REPO_SIGNING_KEY, REPO_SIGNING_PASSPHRASE, optionally REPO_SIGNING_KEY_NEXT and
# REPO_SIGNING_PASSPHRASE_NEXT (a rotation), GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA (the commit
# `publish-ready` checked), and for `ready` MAC_ATTEMPT and GITHUB_RUN_ATTEMPT. No secret is ever in
# an argument: key and passphrase travel through stdin, a 0600 file and gpg-agent. SOURCE_DATE_EPOCH
# is refused: `Release` carries the run's own clock (P376).
#
# GITHUB_OUTPUT: a failing run writes `code=<NRV code>` to it, for the workflow's alarm job.
#
# Testing overrides, refused (NRV-E1139) when GITHUB_ACTIONS is set: PACKAGE_KEYS_DIR (packaging/keys), R2_PY (r2.py),
# PACKAGE_REPOS_FREE_KIB (the free disk, instead of df), PACKAGE_REPOS_SERVED_WAIT=<interval>:<total>, PACKAGE_REPOS_CLOCK (a command printing the seconds)
# (seconds, instead of 10:120, for the served retries), PACKAGE_REPOS_KILL_AT=<point>[:<n>] (kill -9
# at the nth pass through a named point, for the idempotence table).
set -euo pipefail
{ set +x; } 2>/dev/null

where=package_repos.sh
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
keys_dir=${PACKAGE_KEYS_DIR:-packaging/keys}
r2_py=${R2_PY:-$here/r2.py}
tmp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
W=$tmp_root/package-repos
export GNUPGHOME=$tmp_root/package-repos.gnupg
export LC_ALL=C

limit_entries=2000
limit_bytes=$((4 * 1024 * 1024 * 1024))
tag_re='^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
channels=(stable rc)
arches=(amd64 arm64)

# ---- diagnostics ---------------------------------------------------------------------------

block() { printf 'error[%s]: %s: %s\n  cause  %s\n  fix    %s\n' "$1" "$where" "$2" "$3" "$4"; }
# The step's `code` output (the first one wins): the alarm job names the failure with it.
CODE_SET=0
set_code() {
  [ "$CODE_SET" = 0 ] || return 0
  CODE_SET=1
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "code=$1" >>"$GITHUB_OUTPUT"; fi
}
refuse() { set_code "$1"; block "$@" >&2; echo "::error::$1 $2" >&2; exit 1; }
# A fault the run reports at its end, after it has finished everything else.
defer() { block "$@" >>"$W/deferred"; echo "$1" >>"$W/deferred.codes"; }
# An assertion of the script's own bounds: a bug in it, never the operator's input.
bug() {
  printf 'bug[NRV-B0006]: %s: %s\n  cause  a loop of the script ran past its own bound\n  fix    Report it; the script'"'"'s bound or its input is wrong\n' "$where" "$1" >&2
  echo "::error::NRV-B0006 $1" >&2; exit 70
}
notice() { echo "::notice::$*" >&2; }
junk() { echo "$1" >>"$W/junk"; notice "noted: $1"; }

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  for v in PACKAGE_KEYS_DIR R2_PY PACKAGE_REPOS_FREE_KIB PACKAGE_REPOS_SERVED_WAIT PACKAGE_REPOS_CLOCK PACKAGE_REPOS_KILL_AT; do
    if [ -n "${!v:-}" ]; then
      set_code NRV-E1139
      block NRV-E1139 "$v is set on a runner" "$v exists for the tests only" \
        "Remove $v from the workflow's environment" >&2
      echo "::error::NRV-E1139 $v is set on a runner" >&2
      exit 1
    fi
  done
fi

# A failure r2.py reported itself (it prints its own coded block) still names its code.
exit_code() {
  local rc=$?
  if [ "$rc" != 0 ] && [ "$CODE_SET" = 0 ] && [ -s "${W:-/nonexistent}/r2.codes" ]; then
    set_code "$(tail -n1 "$W/r2.codes")"
  fi
}
trap exit_code EXIT

kill_point() {
  local want=${PACKAGE_REPOS_KILL_AT:-} name n=1
  name=${want%%:*}
  [ -n "$want" ] || return 0
  [ "$name" = "$1" ] || return 0
  [ "$want" = "$name" ] || n=${want##*:}
  echo "$1" >>"$W/kill.count"
  if [ "$(grep -c -x -e "$1" "$W/kill.count")" -ge "$n" ]; then kill -9 $$; fi
}

# ---- the environment, the pinned keys --------------------------------------------------------

e1139() { refuse NRV-E1139 "$1" "$2" "${3:-Complete the environment, pin the current key, or list exactly the keys in packaging/keys/, then run again}"; }

need_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || e1139 "the environment lacks $v" "package-repos's secrets and variables reach only this step, through env:"
  done
}

tool_is() { # <tool> <the first line its --version starts with>
  local got
  got=$("$1" --version 2>&1 | head -n1)
  case $got in "$2" | "$2"[!0-9.]*) ;; *) e1139 "$1 reads '$got', not '$2'" "the pinned tools were not installed on this runner" ;; esac
}

need_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null || e1139 "$t is not installed" "the pinned tools were not installed on this runner"
  done
  if [[ " $* " == *" python3 "* ]]; then
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' ||
      e1139 "python3 is older than 3.12" "r2.py is pinned to the runner's Python 3.12"
  fi
  for t in "$@"; do
    case $t in
      apt-ftparchive) tool_is apt-ftparchive "apt 2.8.4" ;;
      createrepo_c) tool_is createrepo_c "Version: 0.17.3" ;;
      rpmsign) tool_is rpmsign "RPM version 4.18.2" ;;
    esac
  done
  if [[ " $* " == *" gpg "* ]]; then
    gpg --version | head -n1 | grep -q ' 2\.4\.' ||
      e1139 "gpg is not 2.4.x" "the signing commands are pinned to gpg 2.4"
  fi
}

FP_CURRENT=; FP_NEXT=; FP_PREVIOUS=
read_fingerprints() {
  local f=$keys_dir/fingerprints role fpr rest
  [ -f "$f" ] || e1139 "$f is missing" "the pinned fingerprints are part of the repository"
  while read -r role fpr rest || [ -n "$role" ]; do
    case "$role" in ''|'#'*) continue ;; esac
    [[ $fpr =~ ^[0-9A-F]{40}$ && -z $rest ]] || e1139 "$f has a malformed line" "each line is a role and a 40-hex fingerprint"
    case "$role" in
      current) [ -z "$FP_CURRENT" ] || e1139 "$f lists current twice" "one current key"; FP_CURRENT=$fpr ;;
      next) [ -z "$FP_NEXT" ] || e1139 "$f lists next twice" "one next key"; FP_NEXT=$fpr ;;
      previous) [ -z "$FP_PREVIOUS" ] || e1139 "$f lists previous twice" "one previous key"; FP_PREVIOUS=$fpr ;;
      *) e1139 "$f has the role $role" "the roles are current, next and previous" ;;
    esac
  done <"$f"
  [ -n "$FP_CURRENT" ] || e1139 "$f has no current key" "the job signs with the current key"
}

listed_fprs() { printf '%s\n' "$FP_CURRENT" "$FP_NEXT" "$FP_PREVIOUS" | grep -v '^$' | sort; }

# The fingerprints of the primary keys a file holds, sorted.
primaries_of() {
  gpg --batch --show-keys --with-colons "$1" 2>/dev/null |
    awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}' | sort
}

# The key file holds exactly the listed keys; the keyring gpgv reads is made from it.
build_keyring() {
  local want have
  [ -f "$keys_dir/nerva-release.asc" ] || e1139 "$keys_dir/nerva-release.asc is missing" "the public keys are part of the repository"
  want=$(listed_fprs); have=$(primaries_of "$keys_dir/nerva-release.asc")
  [ "$want" = "$have" ] || e1139 "$keys_dir/nerva-release.asc does not hold exactly the keys fingerprints lists" \
    "listed: $want; in the file: $have"
  gpg --batch --dearmor <"$keys_dir/nerva-release.asc" >"$W/ring.gpg"
  # `current` or `next` shown revoked or expired is not a key to sign with (no expiry is the model). A
  # revoked `previous` stays: its rpms are handled by "Excluding the rpms of one key".
  have=$(gpg --batch --show-keys --with-colons "$keys_dir/nerva-release.asc" 2>/dev/null |
    awk -F: -v keep="$FP_CURRENT $FP_NEXT" '$1=="pub" {st=$2; next} $1=="fpr" && st != "" {
      if (index(keep, $10) && (st=="r" || st=="e")) print $10 " " st; st=""}' | tr '\n' ';')
  [ -z "$have" ] || e1139 "$keys_dir/nerva-release.asc holds the current or next key revoked or expired ($have)" \
    "the one key has no expiry, so a revocation or an expiry is a finding"
}

secret_primaries() { gpg --batch --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="sec"{p=1;next} $1=="fpr"&&p{print $10;p=0}'; }

setup_keys() {
  local got fpr grip
  need_env REPO_SIGNING_KEY REPO_SIGNING_PASSPHRASE
  read_fingerprints
  rm -rf "$GNUPGHOME"; mkdir -m 700 "$GNUPGHOME"
  build_keyring
  (umask 077; printf '%s' "$REPO_SIGNING_PASSPHRASE" >"$GNUPGHOME/passphrase")
  printf 'pinentry-mode loopback\npassphrase-file %s/passphrase\n' "$GNUPGHOME" >"$GNUPGHOME/gpg.conf"
  printf 'allow-loopback-pinentry\nallow-preset-passphrase\ndefault-cache-ttl 7200\nmax-cache-ttl 7200\n' >"$GNUPGHOME/gpg-agent.conf"
  printf '%s' "$REPO_SIGNING_KEY" | gpg --batch --import >/dev/null 2>&1 ||
    e1139 "REPO_SIGNING_KEY does not import" "the secret must be one armored secret key"
  got=$(secret_primaries)
  [ "$got" = "$FP_CURRENT" ] || e1139 "the signing key is not the current pinned key" \
    "fingerprint $got, but packaging/keys/fingerprints has current $FP_CURRENT"
  SIGN_U=(-u "$FP_CURRENT")
  if [ -n "$FP_NEXT" ] || [ -n "${REPO_SIGNING_KEY_NEXT:-}" ]; then
    need_env REPO_SIGNING_KEY_NEXT REPO_SIGNING_PASSPHRASE_NEXT
    [ -n "$FP_NEXT" ] || e1139 "REPO_SIGNING_KEY_NEXT is set but fingerprints lists no next key" "list it as next first"
    printf '%s' "$REPO_SIGNING_KEY_NEXT" | gpg --batch --import >/dev/null 2>&1 ||
      e1139 "REPO_SIGNING_KEY_NEXT does not import" "the secret must be one armored secret key"
    [ "$(secret_primaries | grep -vx "$FP_CURRENT")" = "$FP_NEXT" ] ||
      e1139 "the next signing key is not the next pinned key" "packaging/keys/fingerprints has next $FP_NEXT"
    grip=$(gpg --batch --list-secret-keys --with-colons --with-keygrip "$FP_NEXT" | awk -F: '$1=="grp"{print $10;exit}')
    printf '%s' "$REPO_SIGNING_PASSPHRASE_NEXT" |
      "$(gpgconf --list-dirs libexecdir)/gpg-preset-passphrase" --preset "$grip" ||
      e1139 "the next key's passphrase was not accepted by gpg-agent" "check REPO_SIGNING_PASSPHRASE_NEXT"
    SIGN_U_BOTH=(-u "$FP_CURRENT" -u "$FP_NEXT")
  else
    SIGN_U_BOTH=("${SIGN_U[@]}")
  fi
}

sign_clear() { gpg --batch --yes --digest-algo SHA512 --clearsign "${@:3}" -o "$2" "$1" 2>"$W/gpg.err" || sign_failed "$1"; }
sign_detach() { gpg --batch --yes --digest-algo SHA512 --detach-sign --armor "${@:3}" -o "$2" "$1" 2>"$W/gpg.err" || sign_failed "$1"; }
# gpg's own last line (it prints no secret) is part of the cause: the key or passphrase is not the only way signing fails.
sign_failed() {
  local why
  why=$(tail -n1 "$W/gpg.err" 2>/dev/null | tr -d '\r' | cut -c1-200) || why=
  refuse NRV-E1144 "signing $(basename "$1") failed" "gpg refused the key or its passphrase${why:+ (gpg: $why)}" \
    "Check the signing key and the package's NEVRA and payload against the release's file, then run again"
}

# ---- the bucket ------------------------------------------------------------------------------

r2() {
  local rc=0
  python3 -I "$r2_py" "$@" 2>"$W/r2.last" || rc=$?
  cat "$W/r2.last" >&2
  # only the last call's code: a status the script handled itself must not name a later failure
  grep -o 'NRV-[EWB][0-9]\{4\}' "$W/r2.last" | head -n1 >"$W/r2.codes" || true
  return "$rc"
}
# A call whose every status but the listed ones ends the run (r2.py has printed its coded message).
r2need() { local rc=0; r2 "$@" || rc=$?; [ "$rc" = 0 ] || exit 1; }

sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { stat -c %s "$1"; }
mkey() { printf 'manifest/%010d.asc' "$1"; }

# ---- the manifest ------------------------------------------------------------------------------

SIG_FPRS=; sig_why=
# check_sigs <status-file> <min> <max> <kind> [<must>]: every VALIDSIG of a gpgv status file passes the
# pinned check of "The manifest" (12 fields; $3, the signing key, is the primary and listed; RSA;
# SHA-512; class 01 for a clearsigned file, 00 for a detached signature), the signer's role may sign
# that <kind> (manifest: current, previous; inrelease and releasegpg: current, next; repomd: current),
# no signer twice, no bad statuses, and between <min> and <max> signatures. <must> lists fingerprints
# that must all be among the signers. The fingerprints go to SIG_FPRS, and the reason of a refusal
# to sig_why.
check_sigs() {
  local out n line allowed class must f
  sig_why=; SIG_FPRS=
  case $4 in
    manifest) allowed="$FP_CURRENT $FP_PREVIOUS"; class=01 ;;
    inrelease) allowed="$FP_CURRENT $FP_NEXT"; class=01 ;;
    releasegpg) allowed="$FP_CURRENT $FP_NEXT"; class=00 ;;
    repomd) allowed="$FP_CURRENT"; class=00 ;;
    *) echo "check_sigs: unknown kind '$4'" >&2; exit 2 ;;
  esac
  must=${5:-}
  if grep -q -E '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY)' "$1"; then sig_why="bad signature status"; return 1; fi
  out=$(awk -v allowed=" $allowed " -v class="$class" '
    $2 == "VALIDSIG" {
      if (NF != 12) { print "ERR a VALIDSIG line is not 12 fields"; exit }
      if ($3 != $12) { print "ERR signed by a subkey, but this key model has none"; exit }
      if (index(allowed, " " $3 " ") == 0) { print "ERR signed by a key whose role may not sign this file"; exit }
      if ($9 != 1) { print "ERR the signature is not RSA"; exit }
      if ($10 != 10) { print "ERR the signature digest is not SHA-512"; exit }
      if ($11 != class) { print "ERR the signature class is not " class; exit }
      print "OK " $3
    }' "$1")
  n=0
  while read -r line; do
    [ -n "$line" ] || continue
    case $line in
      "OK "*)
        case " $SIG_FPRS" in *" ${line#OK} "*) sig_why="signed twice by one key"; return 1 ;; esac
        n=$((n + 1)); SIG_FPRS+="${line#OK } " ;;
      *) sig_why=${line#ERR }; return 1 ;;
    esac
  done <<<"$out"
  if [ "$n" -lt "$2" ] || [ "$n" -gt "$3" ]; then sig_why="$n valid signatures, not $2 to $3"; return 1; fi
  for f in $must; do
    case " $SIG_FPRS" in *" $f "*) ;; *) sig_why="not signed by $f"; return 1 ;; esac
  done
}

vm_why=
# verify_manifest <file> <generation>: 0 and the signed text in $W/body when it verifies; 1 and
# $vm_why when it does not. Strict, as the spec says: one signed block and nothing else, one VALIDSIG by
# a listed primary key, and only what gpgv printed is parsed.
verify_manifest() {
  local f=$1 gen=$2
  vm_why=
  if [ ! -s "$f" ]; then vm_why=empty; return 1; fi
  if [ "$(head -n1 "$f")" != "-----BEGIN PGP SIGNED MESSAGE-----" ]; then vm_why="text before the signed block"; return 1; fi
  if [ "$(tail -n1 "$f")" != "-----END PGP SIGNATURE-----" ] || [ "$(tail -c1 "$f" | od -An -c | tr -d ' ')" != '\n' ]; then
    vm_why="text after the signature"; return 1
  fi
  if [ "$(grep -c -x -e '-----BEGIN PGP SIGNED MESSAGE-----' "$f" || true)" != 1 ] ||
     [ "$(grep -c -x -e '-----BEGIN PGP SIGNATURE-----' "$f" || true)" != 1 ] ||
     [ "$(grep -c -x -e '-----END PGP SIGNATURE-----' "$f" || true)" != 1 ]; then
    vm_why="not exactly one signed block"; return 1
  fi
  if grep -q $'\r' "$f"; then vm_why="carriage return"; return 1; fi
  if ! gpgv --keyring "$W/ring.gpg" --status-fd 3 --output "$W/body.raw" "$f" 3>"$W/status" 2>/dev/null; then
    vm_why="signature does not verify"; return 1
  fi
  check_sigs "$W/status" 1 1 manifest || { vm_why=$sig_why; return 1; }
  rm -rf "$W/p"; mkdir "$W/p"
  if ! awk -v gen="$gen" -v dir="$W/p" '
    function bad(m) { print m > "/dev/stderr"; exit 1 }
    function hex(s, n) { return length(s) == n && s ~ /^[0-9a-f]+$/ }
    function pkey(k) { return k !~ /\.\./ && k ~ /^(apt\/pool\/main\/n\/nerva|rpm\/(stable|rc)\/packages)\/[A-Za-z0-9._+-]+$/ }
    function ikey(k) { return k ~ /^(apt\/dists\/(stable|rc)\/(InRelease|Release|Release\.gpg|main\/binary-(amd64|arm64)\/Packages(\.gz)?)|rpm\/(stable|rc)\/repodata\/repomd\.xml(\.asc)?)$/ }
    NR == 1 { if ($0 != "nerva-packages manifest 4") bad("version line"); next }
    NR == 2 { if ($0 !~ /^generation [0-9]+$/ || $2 + 0 != gen + 0) bad("generation line"); next }
    NR == 3 { if ($0 != "state writing" && $0 != "state complete") bad("state line"); print $2 > (dir "/state"); next }
    NR > 10000 { bad("too long") }
    $1 == "package" && phase == 0 {
      if (NF != 8 || !pkey($5) || ($5 <= prev && prev != "")) bad("package line " NR)
      if ($2 != "pending" && $2 != "published" && $2 != "excluded") bad("package state " NR)
      if (!(hex($3, 64) && $4 ~ /^[0-9]+$/) && !($2 == "pending" && $3 == "-" && $4 == "-" && $5 ~ /^rpm\//)) bad("package hash " NR)
      if (!hex($6, 64) || $7 !~ /^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$/ || !hex($8, 40)) bad("package fields " NR)
      prev = $5; printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7, $8 > (dir "/pk"); next
    }
    $1 == "index" && phase <= 1 {
      if (phase == 0) { phase = 1; prev = "" }
      if (NF != 3 || !hex($2, 64) || !ikey($3) || ($3 <= prev && prev != "")) bad("index line " NR)
      prev = $3; printf "%s\t%s\n", $2, $3 > (dir "/ix"); next
    }
    $1 == "index-was" && phase <= 2 {
      if (phase < 2) { phase = 2; prev = "" }
      if (NF != 3 || !hex($2, 64) || !ikey($3) || ($3 <= prev && prev != "")) bad("index-was line " NR)
      prev = $3; printf "%s\t%s\n", $2, $3 > (dir "/iw"); next
    }
    { bad("unknown line " NR ": " $1) }
    END { if (NR < 3) bad("short") }
  ' "$W/body.raw" 2>"$W/awk.err"; then
    vm_why="body: $(head -n1 "$W/awk.err")"; return 1
  fi
  touch "$W/p/pk" "$W/p/ix" "$W/p/iw"
  cp "$W/body.raw" "$W/body"
  return 0
}

load_parsed() { cp "$W/p/pk" "$W/pk"; cp "$W/p/ix" "$W/ix"; cp "$W/p/iw" "$W/iw"; cp "$W/p/state" "$W/state"; }

CUR_GEN=0
# The highest generation that verifies, loaded into $W/pk, ix, iw and state.
find_current() {
  local rc=0 k g n=0 any=0
  : >"$W/pk"; : >"$W/ix"; : >"$W/iw"; echo complete >"$W/state"
  r2 list manifest/ >"$W/mlist" || rc=$?
  case $rc in
    0) ;;
    5) refuse NRV-E1142 "manifest/ lists past r2.py's page bound" "the prefix is flooded" \
         "Find who changed the bucket outside the pipeline, restore the listed object or remove the unlisted one, then run again" ;;
    *) exit 1 ;;
  esac
  cut -f1 "$W/mlist" | sort -r >"$W/mkeys"
  CUR_GEN=0
  [ -s "$W/mkeys" ] || return 0
  while read -r k; do
    any=1
    if [[ $k =~ ^manifest/([0-9]{10})\.asc$ ]]; then
      g=$((10#${BASH_REMATCH[1]}))
      rc=0; r2 get "$k" "$W/m.asc" || rc=$?
      if [ "$rc" = 0 ] && verify_manifest "$W/m.asc" "$g"; then
        load_parsed; CUR_GEN=$g; return 0
      fi
      [ "$rc" -le 2 ] || exit 1
      junk "object $k does not verify (${vm_why:-gone})"
    else
      junk "object $k is not a manifest name"
    fi
    n=$((n + 1))
    [ "$n" -lt 50 ] || refuse NRV-E1142 "manifest/ holds 50 objects that do not verify" "the prefix is flooded" \
      "Find who changed the bucket outside the pipeline, restore the listed object or remove the unlisted one, then run again"
  done <"$W/mkeys"
  [ "$any" = 1 ] && refuse NRV-E1142 "manifest/ holds objects but none verifies" \
    "this pipeline verifies every manifest before it puts it: the bucket token wrote there, or packaging/keys/ lost a key that signed them" \
    "Find who changed the bucket outside the pipeline, restore the listed object or remove the unlisted one, then run again"
}

manifest_text() { # <generation> <state>
  printf 'nerva-packages manifest 4\ngeneration %s\nstate %s\n' "$1" "$2"
  sort -t$'\t' -k4,4 "$W/pk" | awk -F'\t' '{printf "package %s %s %s %s %s %s %s\n", $1,$2,$3,$4,$5,$6,$7}'
  sort -t$'\t' -k2,2 "$W/ix" | awk -F'\t' '{printf "index %s %s\n", $1, $2}'
  sort -t$'\t' -k2,2 "$W/iw" | awk -F'\t' '{printf "index-was %s %s\n", $1, $2}'
}

# write_manifest <state>: sign the next generation, verify it as a reader would, and put it at the
# first free name above the current one.
write_manifest() {
  local st=$1 g tries=0 rc
  kill_point before_manifest
  g=$((CUR_GEN + 1))
  while :; do
    tries=$((tries + 1))
    [ "$tries" -le 60 ] || refuse NRV-E1142 "manifest/ has no free name within 60 above generation $CUR_GEN" "the prefix is flooded" \
      "Find who changed the bucket outside the pipeline, restore the listed object or remove the unlisted one, then run again"
    manifest_text "$g" "$st" >"$W/mnew.txt"
    sign_clear "$W/mnew.txt" "$W/mnew.asc" "${SIGN_U[@]}"
    verify_manifest "$W/mnew.asc" "$g" || refuse NRV-E1144 "the manifest just signed does not verify ($vm_why)" "the signing key and the pinned key differ" \
      "Check the signing key and the package's NEVRA and payload against the release's file, then run again"
    rc=0; r2 put-new "$(mkey "$g")" "$W/mnew.asc" || rc=$?
    case $rc in
      0) CUR_GEN=$g; echo "$st" >"$W/state"; note_written "$(mkey "$g")" "$(sha_of "$W/mnew.asc")"; return 0 ;;
      3) rc=0; r2 get "$(mkey "$g")" "$W/m.asc" || rc=$?
         [ "$rc" -le 2 ] || exit 1
         if [ "$rc" = 0 ] && verify_manifest "$W/m.asc" "$g"; then
           refuse NRV-E1147 "a manifest that verifies holds $(mkey "$g"), the name this run wanted" \
             "another writer ran at once, outside the concurrency group nerva-packages-bucket" \
             "Stop the other writer, make sure every bucket writer runs in the nerva-packages-bucket group, then run again"
         fi
         junk "object $(mkey "$g") is taken by something that does not verify"
         g=$((g + 1)) ;;
      *) exit 1 ;;
    esac
  done
}

# ---- GitHub ----------------------------------------------------------------------------------

e1155() { defer NRV-E1155 "$1" "GitHub did not answer, or refused (the network, an outage, a rate limit)" "Run again once GitHub answers; the entries stay pending until then"; }
e1155_now() { refuse NRV-E1155 "$1" "GitHub did not answer, or refused (the network, an outage, a rate limit)" "Run again once GitHub answers; the entries stay pending until then"; }

# rel_fetch <tag>: $W/rel.<tag> holds `R draft|published` and `A id name` lines, empty when the
# release does not exist. Returns 1 when GitHub failed.
rel_fetch() {
  local out=$W/rel.$1
  [[ $1 =~ $tag_re ]] || return 1
  [ -f "$out" ] && return 0
  if ! gh api --paginate "repos/$GITHUB_REPOSITORY/releases" --jq \
    ".[] | select(.tag_name==\"$1\") | (if .draft then \"R draft\" else \"R published\" end), (.assets[] | \"A \\(.id) \\(.name)\")" \
    >"$out.part" 2>/dev/null; then
    rm -f "$out.part"; return 1
  fi
  mv "$out.part" "$out"
}
rel_state() { awk '$1=="R"{print $2; f=1} END{if(!f) print "absent"}' "$W/rel.$1"; }
rel_asset_id() { awk -v n="$2" '$1=="A" && $3==n{print $2; exit}' "$W/rel.$1"; }
rel_download() { # <tag> <name> <file>
  local id; id=$(rel_asset_id "$1" "$2")
  [ -n "$id" ] || return 2
  gh api -H "Accept: application/octet-stream" "repos/$GITHUB_REPOSITORY/releases/assets/$id" >"$3" 2>/dev/null || return 1
}

# SHA256SUMS.asc (P417c, amending P417b): the draft's SHA256SUMS, signed detached and armored by the
# release key (the one key of P392), so a download is checked against the sums and the sums against
# packaging/keys/nerva-release.asc. The pinned check is the Release.gpg one (current or next key,
# RSA, SHA-512, class 00).
sums_check() { # <sig> <data>
  gpgv --keyring "$W/ring.gpg" --status-fd 3 "$1" "$2" 3>"$W/sums.status" 2>/dev/null || true
  check_sigs "$W/sums.status" 1 1 releasegpg
}
e1165() { refuse NRV-E1165 "$1" "$2" "A SHA256SUMS.asc already on the draft is never replaced: delete that asset (gh release delete-asset <tag> SHA256SUMS.asc), then run repos-ready again to sign the sums; or delete the draft and run release.yml again"; }
# P417e: a release tagged in pre_p417_tags (v0.7.1, published before P417 merged) with no .debug and no
# SHA256SUMS.asc asset is the pre-P417 set: nine lines in SHA256SUMS, no signature. Needs rel_fetch. The same
# test is release_check.sh publish-ready's.
legacy_release() { # <tag>
  grep -qxF "$1" "$here/pre_p417_tags" &&
    ! awk '$1=="A" && ($3 ~ /^nerva-.*\.debug$/ || $3=="SHA256SUMS.asc") {f=1} END{exit !f}' "$W/rel.$1"
}
sums_sign() { # <tag>: reads and writes $W/draft; uploads SHA256SUMS.asc when the draft has none
  local tag=$1 rc=0
  rel_download "$tag" SHA256SUMS.asc "$W/draft/SHA256SUMS.asc" || rc=$?
  case $rc in
    0) sums_check "$W/draft/SHA256SUMS.asc" "$W/draft/SHA256SUMS" ||
         e1165 "the draft's SHA256SUMS.asc does not verify against its SHA256SUMS ($sig_why)" "an earlier run signed other sums, or the file was replaced"
       return 0 ;;
    2) ;;
    *) e1155_now "downloading SHA256SUMS.asc failed" ;;
  esac
  sign_detach "$W/draft/SHA256SUMS" "$W/draft/SHA256SUMS.asc" "${SIGN_U[@]}"
  sums_check "$W/draft/SHA256SUMS.asc" "$W/draft/SHA256SUMS" ||
    e1165 "SHA256SUMS.asc, just signed, does not verify under packaging/keys/ ($sig_why)" "the signing key and the pinned key file disagree"
  gh release upload "$tag" "$W/draft/SHA256SUMS.asc" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 ||
    e1155_now "uploading SHA256SUMS.asc to the draft failed"
}

# sums-verify <tag>: the release's SHA256SUMS.asc verifies against its SHA256SUMS under packaging/keys/
# alone. No secret: the publish job runs it.
cmd_sums_verify() {
  local tag=$1 name rc
  [[ $tag =~ $tag_re ]] || e1139 "the tag $tag is not a version tag" "sums-verify takes vX.Y.Z or vX.Y.Z-rc.N"
  need_env GH_TOKEN GITHUB_REPOSITORY
  need_tools gpg gpgv gh
  mkdir -p "$W/draft"; read_fingerprints; rm -rf "$GNUPGHOME"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --dearmor <"$keys_dir/nerva-release.asc" >"$W/ring.gpg"
  rel_fetch "$tag" || e1155_now "reading the release $tag failed"
  if legacy_release "$tag"; then notice "$tag is the pre-P417 set: its SHA256SUMS is not signed"; return 0; fi
  for name in SHA256SUMS SHA256SUMS.asc; do
    rc=0; rel_download "$tag" "$name" "$W/draft/$name" || rc=$?
    case $rc in 0) ;; 2) e1165 "the release $tag has no $name" "SHA256SUMS is signed by repos-ready before the release is published" ;; *) e1155_now "downloading $name failed" ;; esac
  done
  sums_check "$W/draft/SHA256SUMS.asc" "$W/draft/SHA256SUMS" ||
    e1165 "SHA256SUMS.asc of $tag does not verify against its SHA256SUMS ($sig_why)" "the sums or the signature were replaced"
}

filever() { local v=${1#v}; printf '%s' "${v/-rc./.rc.}"; }
# The files SHA256SUMS lists (P417e): four tarballs, four packages, the two Linux .debug files and the
# bill of materials; the pre-P417 set has no .debug.
sums_names() { # <tag> <legacy 0|1>
  local t=$1
  printf '%s\n' "nerva-$t-x86_64-linux.tar.gz" "nerva-$t-aarch64-linux.tar.gz" "nerva-$t-x86_64-macos.tar.gz" \
    "nerva-$t-aarch64-macos.tar.gz" "nerva-$t.cdx.json"
  [ "$2" = 1 ] || printf '%s\n' "nerva-$t-x86_64-linux.debug" "nerva-$t-aarch64-linux.debug"
  package_names "$t"
}
package_names() { # <tag>: the release's four package names
  local fv; fv=$(filever "$1")
  printf '%s\n' "nerva_${fv}-1_amd64.deb" "nerva_${fv}-1_arm64.deb" "nerva-${fv}-1.x86_64.rpm" "nerva-${fv}-1.aarch64.rpm"
}
deb_key() { printf 'apt/pool/main/n/nerva/%s' "$1"; }
rpm_key() { printf 'rpm/%s/packages/%s' "$1" "$2"; }
is_candidate() { [[ $1 == *-rc.* || $1 == *.rc.* ]]; }

# ---- the bucket against the manifest ---------------------------------------------------------

REPLACEABLE=()
replaceable_names() {
  local c a
  REPLACEABLE=()
  for c in "${channels[@]}"; do
    for a in "${arches[@]}"; do REPLACEABLE+=("apt/dists/$c/main/binary-$a/Packages" "apt/dists/$c/main/binary-$a/Packages.gz"); done
    REPLACEABLE+=("apt/dists/$c/Release" "apt/dists/$c/Release.gpg" "apt/dists/$c/InRelease" "rpm/$c/repodata/repomd.xml.asc" "rpm/$c/repodata/repomd.xml")
  done
}

e1142_fix="Find who changed the bucket outside the pipeline, restore the listed object or remove the unlisted one, then run again"
e1142_now() { refuse NRV-E1142 "$1" "$2" "$e1142_fix"; }

# Steps 3 of `repos`: refusals before any write, and the notes.
bucket_check() { # <with-bounds: 0|1> [noprobe: write nothing]
  local st sha size key src tag rc head_out prefix n bytes
  n=$(wc -l <"$W/pk"); bytes=$(awk -F'\t' '$3 != "-" {s += $3} END {print s + 0}' "$W/pk")
  if [ "$n" -gt "$limit_entries" ] || [ "$bytes" -gt "$limit_bytes" ]; then
    e1142_now "the manifest holds $n entries and $bytes bytes, over the bound of $limit_entries and 4 GiB" \
      "a pruning policy or indexes built without downloading the packages needs a decision"
  fi
  # A HEAD of every published object: a locked object cannot change, so this is enough.
  while IFS=$'\t' read -r st sha size key src tag _; do
    [ "$st" = published ] || continue
    rc=0; head_out=$(r2 head "$key") || rc=$?
    case $rc in 0) ;; 2) e1142_now "the listed object $key is missing" "the locks make that impossible, so the locks have failed" ;; *) exit 1 ;; esac
    [ "$head_out" = "$(printf '%s\t%s' "$size" "$sha")" ] ||
      e1142_now "the listed object $key differs from its entry" "its size or x-amz-meta-sha256 is not what the manifest records"
  done <"$W/pk"
  # The locks: re-put the current manifest over itself, and one listed object under each other prefix.
  if [ "${2:-}" != noprobe ]; then
    if [ "$CUR_GEN" -gt 0 ]; then probe_lock "$(mkey "$CUR_GEN")"; fi
    for prefix in apt/pool/ rpm/stable/packages/ rpm/rc/packages/; do
      key=$(awk -F'\t' -v p="$prefix" '$1 == "published" && index($4, p) == 1 {print $4; exit}' "$W/pk")
      [ -z "$key" ] || probe_lock "$key"
    done
  fi
  # Objects no entry lists, and a candidate under stable.
  for prefix in apt/pool/ rpm/stable/packages/ rpm/rc/packages/; do
    rc=0; r2 list "$prefix" >"$W/plist" || rc=$?
    case $rc in 0) ;; 5) junk "listing $prefix reached r2.py's page bound" ;; *) exit 1 ;; esac
    while IFS=$'\t' read -r key size; do
      if [ "$prefix" = rpm/stable/packages/ ] && is_candidate "$key"; then
        e1142_now "$key, a candidate, is under rpm/stable/" "stable holds releases only"
      fi
      awk -F'\t' -v k="$key" '$4 == k {f = 1} END {exit !f}' "$W/pk" || junk "unlisted object $key under $prefix"
    done <"$W/plist"
  done
  index_check
}

probe_lock() {
  local rc=0
  r2 get "$1" "$W/probe.bin" || rc=$?
  [ "$rc" = 0 ] || e1142_now "the listed object $1 cannot be read" "the locks make that impossible, so the locks have failed"
  rc=0; r2 probe-locked "$1" "$W/probe.bin" || rc=$?
  case $rc in
    0) ;;
    4) refuse NRV-E1149 "R2 accepted an overwrite of $1" "the bucket lock rule on that prefix is gone" "Add the bucket lock rule in Cloudflare, then run again" ;;
    *) exit 1 ;;
  esac
}

# The replaceable names against the hashes the manifest accepts; $W/found holds `hash name` of every
# name read, $W/accepted the ones whose hash the manifest accepts.
index_check() {
  local name rc h st want
  replaceable_names
  : >"$W/found"; : >"$W/accepted"
  st=$(cat "$W/state")
  for name in "${REPLACEABLE[@]}"; do
    rc=0; r2 get-lenient "$name" "$W/idx.bin" 2>"$W/get.err" || rc=$?
    want=$(awk -F'\t' -v k="$name" '$2 == k {print $1}' "$W/ix")
    if [ "$rc" = 4 ]; then # replaceable: lying metadata is junk the run overwrites, never a stop
      junk "index $name does not match its own x-amz-meta-sha256"
      continue
    fi
    if [ "$rc" = 2 ]; then
      [ -z "$want" ] || junk "index $name is missing though the manifest lists it"
      continue
    fi
    [ "$rc" = 0 ] || { cat "$W/get.err" >&2; exit 1; }
    h=$(sha_of "$W/idx.bin")
    printf '%s\t%s\n' "$h" "$name" >>"$W/found"
    if [ "$h" = "$want" ] || { [ "$st" = writing ] && awk -F'\t' -v k="$name" -v h="$h" '$2 == k && $1 == h {f = 1} END {exit !f}' "$W/iw"; }; then
      printf '%s\t%s\n' "$h" "$name" >>"$W/accepted"
    else
      junk "index $name has the hash $h, which the manifest does not accept"
    fi
  done
}

disk_check() {
  local need free bytes
  bytes=$(awk -F'\t' '$3 != "-" {s += $3} END {print s + 0}' "$W/pk")
  need=$(((2 * bytes + 2 * 1024 * 1024 * 1024) / 1024))
  free=${PACKAGE_REPOS_FREE_KIB:-$(df -Pk "$W" | awk 'NR==2{print $4}')}
  [ "$free" -ge "$need" ] || refuse NRV-E1156 "the runner has $free KiB free and the run needs $need KiB" \
    "step 5 holds every package on disk" "Install the index tools or free disk on the runner, then run again"
}

# ---- served ------------------------------------------------------------------------------------

e1145() { refuse NRV-E1145 "$1" "packages.nerva.pro does not serve what the bucket holds" "Check what serves packages.nerva.pro in Cloudflare, then run served again"; }

# served_same <path> <want-sha256> <what a difference says>: what packages.nerva.pro serves at <path>
# hashes to <want>. No query string and no cache-busting header: users get what the edge gives. A
# difference is retried every 10 seconds until 2 minutes have passed on the clock (P376), then refused
# (NRV-E1145). The bound is elapsed time, not attempts: each curl is capped by the time left, so a
# stalled edge ends here, inside repos-ready's timeout, and never in a timeout that names no code.
# PACKAGE_REPOS_CLOCK names a command that prints the seconds (tests only).
served_now() { if [ -n "${PACKAGE_REPOS_CLOCK:-}" ]; then "$PACKAGE_REPOS_CLOCK"; else date +%s; fi; }
served_same() {
  local wait=${PACKAGE_REPOS_SERVED_WAIT:-10:120} iv total start left why
  iv=${wait%%:*}; total=${wait##*:}
  start=$(served_now)
  while :; do
    left=$((total - ($(served_now) - start)))
    [ "$left" -ge 1 ] || [ "$total" = 0 ] || e1145 "$1 ${why:-is not served}"
    [ "$left" -ge 1 ] || left=1
    [ "$left" -le 60 ] || left=60
    if curl -fsS --max-time "$left" -o "$W/sv.served" "${PACKAGES_BASE_URL%/}/$1" 2>/dev/null; then
      [ "$(sha_of "$W/sv.served")" != "$2" ] || return 0
      why=$3
    else
      why="is not served"
    fi
    [ "$(( $(served_now) - start + iv ))" -le "$total" ] || e1145 "$1 $why"
    sleep "$iv"
  done
}

# Everything this run put or replaced, `<key> <sha256>`, checked over HTTPS by served_written.
note_written() { printf '%s %s\n' "$1" "$2" >>"$W/written"; }
served_written() {
  local key want
  [ -s "$W/written" ] || return 0
  while read -r key want; do
    served_same "$key" "$want" "is served with other bytes than this run uploaded"
  done <"$W/written"
  : >"$W/written"
}

served_manifest() {
  [ "$CUR_GEN" -gt 0 ] || return 0
  r2need get "$(mkey "$CUR_GEN")" "$W/sv.bucket"
  served_same "$(mkey "$CUR_GEN")" "$(sha_of "$W/sv.bucket")" "is served with other bytes than the bucket's"
}

served_all() { # <tag or empty>
  local c name key st sha size src tag
  served_manifest
  for c in "${channels[@]}"; do
    for name in "apt/dists/$c/InRelease" "rpm/$c/repodata/repomd.xml"; do
      r2need get "$name" "$W/sv.bucket"
      served_same "$name" "$(sha_of "$W/sv.bucket")" "is served with other bytes than the bucket's"
    done
  done
  [ -n "$1" ] || return 0
  while IFS=$'\t' read -r st sha size key src tag _; do
    [ "$tag" = "$1" ] && [ "$st" = published ] || continue
    served_same "$key" "$sha" "is served with another SHA-256 than the manifest's"
  done <"$W/pk"
}

# ---- ready -------------------------------------------------------------------------------------

e1140() { refuse NRV-E1140 "$1" "$2" "Make the release's packages and SHA256SUMS agree, then run again"; }

# The draft's assets changed: its old entries may be replaced only when none of them is published
# and no object of the tag exists at any of their names (a key the new set no longer wants included).
tag_untouched() { # <tag>
  local key rc
  ! awk -F'\t' -v t="$1" '$6 == t && $1 == "published" {f = 1} END {exit !f}' "$W/pk" || return 1
  while read -r key; do
    rc=0; r2 head "$key" >/dev/null || rc=$?
    case $rc in 0) return 1 ;; 2) ;; *) exit 1 ;; esac
  done < <(awk -F'\t' -v t="$1" '$6 == t {print $4}' "$W/pk")
}

cmd_ready() {
  local tag=$1 published=$2 names n draft_ids ids2 name want got key src entry changed=0 exist
  [[ $tag =~ $tag_re ]] || e1139 "the tag $tag is not a version tag" "ready takes vX.Y.Z or vX.Y.Z-rc.N"
  case $published in true|false) ;; *) e1139 "published must be true or false" "ready takes the guard's finding" ;; esac
  need_env PACKAGES_BASE_URL GH_TOKEN GITHUB_REPOSITORY GITHUB_SHA R2_ENDPOINT R2_BUCKET
  [[ $GITHUB_SHA =~ ^[0-9a-f]{40}$ ]] || e1139 "GITHUB_SHA is not a commit" "ready records the commit publish-ready checked"
  need_tools gpg gpgv python3 gh curl jq sha256sum
  mkdir -p "$W"; setup_keys
  find_current
  if [ "$published" = true ]; then bucket_check 1 noprobe; else bucket_check 1; fi
  served_manifest
  if [ "$published" = true ]; then notice "a dispatch for a published release binds nothing"; finish; return; fi
  [ "${MAC_ATTEMPT:-}" = "${GITHUB_RUN_ATTEMPT:-unset}" ] ||
    refuse NRV-E1153 "repos-ready ran in attempt ${GITHUB_RUN_ATTEMPT:-unset}, but the approved mac job ran in ${MAC_ATTEMPT:-none}" \
      "a re-run that does not re-run mac keeps mac's old output, and the draft may have changed since the approval" \
      "Re-run all jobs, so the approved mac job is the one that runs"
  rel_fetch "$tag" || e1155_now "reading the release $tag failed"
  [ "$(rel_state "$tag")" = draft ] || refuse NRV-E1148 "the release $tag does not read draft though guard saw a draft" \
    "it was published or deleted since" "Restore the asset the approved run bound, or release a new version, then run again"
  draft_ids=$(awk '$1=="A"{print $2, $3}' "$W/rel.$tag" | sort)
  # exactly four packages, and every file SHA256SUMS lists, matching it (P417e)
  names=$(package_names "$tag" | sort)
  [ "$(awk '$1=="A" && $3 ~ /^nerva[_-].*\.(deb|rpm)$/ {print $3}' "$W/rel.$tag" | sort)" = "$names" ] ||
    e1140 "the draft does not hold exactly the four packages" "expected $names"
  mkdir -p "$W/draft"
  local rc=0; rel_download "$tag" SHA256SUMS "$W/draft/SHA256SUMS" || rc=$?
  case $rc in 0) ;; 2) e1140 "the draft has no SHA256SUMS" "expected SHA256SUMS" ;; *) e1155_now "downloading SHA256SUMS failed" ;; esac
  legacy=0; legacy_release "$tag" && legacy=1
  listed_want=$(sums_names "$tag" "$legacy" | sort)
  # each line is what sha256sum writes: 64 hex digits, two spaces or a space and a star, one file name
  ! grep -q $'\r' "$W/draft/SHA256SUMS" ||
    e1140 "SHA256SUMS has CRLF line endings, which sha256sum -c does not read" "every line ends in a bare newline"
  ! grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9._+-]+$|^[0-9a-f]{64} \*[A-Za-z0-9._+-]+$' "$W/draft/SHA256SUMS" ||
    e1140 "SHA256SUMS has a line that sha256sum -c would not read" "every line is a 64-digit hash, two spaces (or a space and a star) and one file name of letters, digits and . _ + - only, and nothing else"
  listed=$(awk '{n = $2; sub(/^\*/, "", n); print n}' "$W/draft/SHA256SUMS" | sort)
  [ "$listed" = "$listed_want" ] || e1140 "SHA256SUMS does not list exactly the files of the release ($(diff <(echo "$listed_want") <(echo "$listed") | tr '\n' ' '))" \
    "a line is missing, extra, repeated or malformed"
  while read -r name; do
    want=$(awk -v n="$name" '$2 == n || $2 == "*" n {print $1}' "$W/draft/SHA256SUMS" | head -n1)
    [[ $want =~ ^[0-9a-f]{64}$ && ! $want =~ ^0+$ ]] || e1140 "SHA256SUMS has no real hash for $name" "every listed file has a 64-digit hash that is not zero"
    rc=0; rel_download "$tag" "$name" "$W/draft/$name" || rc=$?
    case $rc in 0) ;; 2) e1140 "the draft has no $name, which SHA256SUMS lists" "every listed file is on the draft" ;; *) e1155_now "downloading $name failed" ;; esac
    got=$(sha_of "$W/draft/$name")
    [ "$got" = "$want" ] || e1140 "$name does not match SHA256SUMS" "the file hashes to $got, SHA256SUMS says $want"
  done <<<"$listed_want"
  rel_forget "$tag"
  rel_fetch "$tag" || e1155_now "reading the release $tag again failed"
  [ "$(rel_state "$tag")" = draft ] || refuse NRV-E1148 "the release $tag was published while its packages were read" \
    "the bytes read may not be what the owner approved" "Restore the asset the approved run bound, or release a new version, then run again"
  ids2=$(awk '$1=="A"{print $2, $3}' "$W/rel.$tag" | sort)
  [ "$draft_ids" = "$ids2" ] || refuse NRV-E1148 "the draft's assets changed while they were read" \
    "the bytes read may not be what the owner approved" "Restore the asset the approved run bound, or release a new version, then run again"
  if [ "$legacy" = 1 ]; then notice "$tag is the pre-P417 set: SHA256SUMS is not signed"; else sums_sign "$tag"; fi
  # the entries this tag wants
  : >"$W/want"
  for name in $names; do
    src=$(sha_of "$W/draft/$name")
    case $name in
      *.deb) printf '%s\t%s\t%s\n' "$(deb_key "$name")" "$src" "$(size_of "$W/draft/$name")" >>"$W/want" ;;
      *.rpm) printf '%s\t%s\t-\n' "$(rpm_key rc "$name")" "$src" >>"$W/want"
             is_candidate "$tag" || printf '%s\t%s\t-\n' "$(rpm_key stable "$name")" "$src" >>"$W/want" ;;
    esac
  done
  # any object at these names, or a differing entry
  while IFS=$'\t' read -r key src size; do
    entry=$(awk -F'\t' -v k="$key" '$4 == k {print $5}' "$W/pk")
    rc=0; r2 head "$key" >/dev/null || rc=$?
    case $rc in 0) exist=1 ;; 2) exist=0 ;; *) exit 1 ;; esac
    if [ -n "$entry" ]; then
      [ "$entry" = "$src" ] && continue
      tag_untouched "$tag" && { changed=1; continue; }
      refuse NRV-E1141 "$key is already listed with other content, or an object of $tag already exists in the bucket" "published packages are never replaced" \
        "Published packages are not replaced: release a new version under a new name"
    fi
    if [ "$exist" = 1 ]; then
      e1142_now "an object is already at $key, which the manifest does not list" "the bucket was written outside the pipeline"
    fi
  done <"$W/want"
  # Replace or add the tag's entries.
  if [ "$changed" = 1 ]; then
    awk -F'\t' -v t="$tag" '$6 != t' "$W/pk" >"$W/pk.new"; mv "$W/pk.new" "$W/pk"
  fi
  local added=0
  while IFS=$'\t' read -r key src size; do
    awk -F'\t' -v k="$key" '$4 == k {f = 1} END {exit !f}' "$W/pk" && continue
    if [ "$size" = - ]; then printf 'pending\t-\t-\t%s\t%s\t%s\t%s\n' "$key" "$src" "$tag" "$GITHUB_SHA" >>"$W/pk"
    else printf 'pending\t%s\t%s\t%s\t%s\t%s\t%s\n' "$src" "$size" "$key" "$src" "$tag" "$GITHUB_SHA" >>"$W/pk"; fi
    added=1
  done <"$W/want"
  if [ "$added" = 1 ]; then
    write_manifest "$(cat "$W/state")"
    served_written
    kill_point ready_manifest
  else
    notice "the tag already has its entries"
  fi
  finish
}

rel_forget() { rm -f "$W/rel.$1"; }

# Print everything deferred, and end red if there was any. The junk notes become NRV-E1142.
finish() {
  local rc=0
  if [ -s "$W/junk" ]; then
    defer NRV-E1142 "the bucket does not match its manifest: $(wc -l <"$W/junk" | tr -d ' ') object(s) noted" \
      "$(tr '\n' ';' <"$W/junk" | cut -c1-1500)" "$e1142_fix"
  fi
  if [ -s "$W/deferred" ]; then cat "$W/deferred" >&2; rc=1; fi
  [ "$rc" = 0 ] || { set_code "$(head -n1 "$W/deferred.codes")"; exit 1; }
}

# ---- publish -----------------------------------------------------------------------------------

# $W/ready: keys of the pending entries whose object exists with the entry's hash.
published_now() { awk -F'\t' '$1 == "published"' "$W/pk" | wc -l; }

set_entry() { # <key> <state> <sha> <size>
  awk -F'\t' -v OFS='\t' -v k="$1" -v s="$2" -v h="$3" -v z="$4" '$4 == k {$1 = s; $2 = h; $3 = z} {print}' "$W/pk" >"$W/pk.new"
  mv "$W/pk.new" "$W/pk"
}
entry_field() { awk -F'\t' -v k="$1" -v n="$2" '$4 == k {print $n}' "$W/pk"; }

obj_state() { # <key> -> prints `absent` or the object's sha256 (x-amz-meta-sha256); exits on a hard failure
  local rc=0 out
  out=$(r2 head "$1") || rc=$?
  case $rc in 0) printf '%s' "${out#*$'\t'}" ;; 2) printf absent ;; *) exit 1 ;; esac
}

# Never trust an object for being there: download it and hash the bytes. 0 the bytes are <want>,
# 1 they are not (r2.py's metadata check included), 2 no such object; the file is left only on 0.
verify_obj() { # <key> <want-sha> <file>
  local rc=0
  rm -f "$3"; mkdir -p "$(dirname "$3")"
  r2 get-lenient "$1" "$3" 2>"$W/get.err" || rc=$?
  case $rc in
    0) [ "$(sha_of "$3")" = "$2" ] || { rm -f "$3"; return 1; }; echo "$1" >>"$W/ok" ;;
    2) return 2 ;;
    4) rm -f "$3"; return 1 ;;
    *) cat "$W/get.err" >&2; exit 1 ;;
  esac
}

put_object() { # <key> <file> <sha>: put-new; a taken name is adopted only with the same bytes
  local rc=0 cur
  r2 put-new "$1" "$2" || rc=$?
  case $rc in
    0) echo "$1" >>"$W/ok"; note_written "$1" "$3"; return 0 ;;
    3) cur=$(obj_state "$1")
       if [ "$cur" = "$3" ]; then
         rc=0; verify_obj "$1" "$3" "$W/adopt.bin" || rc=$?
         [ "$rc" != 0 ] || return 0
       fi
       junk "object $1 exists with other content than its entry"; return 1 ;;
    *) exit 1 ;;
  esac
}

e1161() { refuse NRV-E1161 "$1" "$2" "Fix it, then re-run. It is a finding until explained"; }

key_id_of() { printf '%s' "${1: -16}" | tr 'A-F' 'a-f'; }

RPMDB=
# A scratch rpm database holding the pinned key file's keys, and nothing else.
rpm_scratch() {
  local want have
  [ -z "$RPMDB" ] || return 0
  RPMDB=$W/rpmdb
  rm -rf "$RPMDB"; mkdir -p "$RPMDB"
  rpmdb --initdb --dbpath "$RPMDB" >/dev/null 2>&1 </dev/null || e1161 "the scratch rpm database could not be made" "rpmdb --initdb failed"
  rpmkeys --dbpath "$RPMDB" --import "$keys_dir/nerva-release.asc" >/dev/null 2>&1 </dev/null ||
    e1161 "the pinned key file did not import into the scratch rpm database" "rpmkeys --import refused packaging/keys/nerva-release.asc"
  want=$(listed_fprs | wc -l)
  have=$(rpm --dbpath "$RPMDB" -qa 'gpg-pubkey*' 2>/dev/null | wc -l)
  [ "$have" = "$want" ] || e1161 "the scratch rpm database holds $have keys, not the $want listed" \
    "the key file and fingerprints disagree"
}

# verify_rpm <file>: step 4's check of the exact bytes about to be recorded or put (and 5b's again).
verify_rpm() {
  local f=$1 name out sig kid by
  name=${f##*/}
  rpm_scratch
  sig=$(rpm -qp --qf '%{RSAHEADER:pgpsig}\n' "$f" 2>/dev/null </dev/null) || sig=
  by=; [[ $sig =~ Key\ ID\ ([0-9a-f]{16})$ ]] && by=" (signed by the Key ID ${BASH_REMATCH[1]})"
  out=$(rpmkeys --dbpath "$RPMDB" -K "$f" 2>&1 </dev/null) ||
    e1161 "$name does not verify under rpmkeys$by: $(printf '%s' "$out" | head -c 200 | tr '\n' ' ')" \
      "its signature, digests or key are not what packaging/keys/ pins"
  case $out in *"digests signatures OK"*) ;; *)
    e1161 "$name does not verify under rpmkeys$by: $(printf '%s' "$out" | head -c 200 | tr '\n' ' ')" \
      "rpmkeys did not report digests signatures OK" ;;
  esac
  [[ $sig =~ ^RSA/SHA512,\ .*,\ Key\ ID\ ([0-9a-f]{16})$ ]] ||
    e1161 "$name carries the signature '$sig', not RSA/SHA512 with a Key ID" "rpm reads its header signature otherwise than the pin"
  kid=${BASH_REMATCH[1]}
  [ "$kid" = "$(key_id_of "$FP_CURRENT")" ] || { [ -n "$FP_PREVIOUS" ] && [ "$kid" = "$(key_id_of "$FP_PREVIOUS")" ]; } ||
    e1161 "$name is signed by the Key ID $kid, which is not current's or previous's" \
      "its key left fingerprints, or a run signed it with another key"
}

sign_rpm() { # <file>: rpmsign in place, then the NEVRA and payload digest check
  local f=$1 before after
  before=$(rpm -qp --qf '%{NEVRA} %{PAYLOADDIGEST}' "$f" 2>/dev/null) || before=
  rpmsign --addsign --define "_gpg_name $FP_CURRENT" --define "_gpg_path $GNUPGHOME" \
    --define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase" \
    --define "_gpg_digest_algo sha512" "$f" >/dev/null 2>&1 </dev/null || sign_failed "$f"
  after=$(rpm -qp --qf '%{NEVRA} %{PAYLOADDIGEST}' "$f" 2>/dev/null) || after=
  [ -n "$before" ] && [ "$before" = "$after" ] ||
    refuse NRV-E1144 "the signed $(basename "$f") differs from the release's file in NEVRA or payload" "before: $before; after: $after" \
      "Check the signing key and the package's NEVRA and payload against the release's file, then run again"
  rpm -qp --qf '%{RSAHEADER:pgpsig}' "$f" 2>/dev/null | grep -qi "${FP_CURRENT: -16}" ||
    refuse NRV-E1144 "the signed $(basename "$f") carries no signature by the current key" "rpmsign did not sign it" \
      "Check the signing key and the package's NEVRA and payload against the release's file, then run again"
}

# Step 4 for one pending entry's tag file.
put_pending() {
  local tag key base file rc st recorded sha srcsha size obj
  : >"$W/pending.keys"
  awk -F'\t' '$1 == "pending" {print $4}' "$W/pk" >"$W/pending.keys"
  while read -r key; do
    [ "$(entry_field "$key" 1)" = pending ] || continue
    tag=$(entry_field "$key" 6); srcsha=$(entry_field "$key" 5); sha=$(entry_field "$key" 2)
    base=${key##*/}
    obj=$(obj_state "$key")
    if [ "$obj" != absent ]; then
      if [ "$sha" != - ] && [ "$obj" = "$sha" ]; then
        rc=0; verify_obj "$key" "$sha" "$W/adopt.bin" || rc=$?
        [ "$rc" != 0 ] || continue
      fi
      junk "object $key exists with other content than its entry"; continue
    fi
    # The release must read published.
    if ! rel_fetch "$tag"; then e1155 "reading the release $tag failed; its entries stay pending"; GH_FAILED_TAGS+=" $tag"; continue; fi
    st=$(rel_state "$tag")
    if [ "$st" != published ]; then notice "the release $tag reads $st: its entries stay pending"; NOT_PUBLIC_TAGS+=" $tag"; continue; fi
    case $key in
      apt/*) fetch_source "$tag" "$base" "$srcsha" "$W/dl/$base" || continue
             put_object "$key" "$W/dl/$base" "$srcsha" && kill_point deb_put ;;
      rpm/*) put_rpm "$key" "$tag" "$base" "$srcsha" || continue ;;
    esac
  done <"$W/pending.keys"
}

GH_FAILED_TAGS=; NOT_PUBLIC_TAGS=
fetch_source() { # <tag> <name> <source-sha> <file>
  local rc=0
  mkdir -p "$W/dl"
  rel_download "$1" "$2" "$4" || rc=$?
  case $rc in
    0) ;;
    2) defer NRV-E1148 "the release $1 has no asset $2" "the approved run bound it" "Restore the asset the approved run bound, or release a new version, then run again"; return 1 ;;
    *) e1155 "downloading $2 from $1 failed"; GH_FAILED_TAGS+=" $1"; return 1 ;;
  esac
  if [ "$(sha_of "$4")" != "$3" ]; then
    defer NRV-E1148 "$2 of $1 is not what the approved run bound" "its SHA-256 differs from the manifest's source-sha256" \
      "Restore the asset the approved run bound, or release a new version, then run again"
    return 1
  fi
}

put_rpm() { # <key> <tag> <base> <source-sha>
  local key=$1 tag=$2 base=$3 srcsha=$4 c k sha size have="" obj
  local keys=() recorded=-
  for c in rc stable; do
    k=$(rpm_key "$c" "$base")
    [ -n "$(entry_field "$k" 1)" ] && keys+=("$k")
  done
  # a recorded hash, and an object that already holds it
  for k in "${keys[@]}"; do
    sha=$(entry_field "$k" 2)
    [ "$sha" = - ] || recorded=$sha
  done
  if [ "$recorded" != - ]; then
    for k in "${keys[@]}"; do
      obj=$(obj_state "$k")
      [ "$obj" = "$recorded" ] || continue
      mkdir -p "$W/dl"
      if verify_obj "$k" "$recorded" "$W/dl/copy.rpm"; then have=$k; break; fi
      junk "object $k exists with other content than its entry"
    done
    if [ -n "$have" ]; then
      verify_rpm "$W/dl/copy.rpm"
      for k in "${keys[@]}"; do
        [ "$k" != "$have" ] || continue
        [ "$(obj_state "$k")" = absent ] || continue
        put_object "$k" "$W/dl/copy.rpm" "$recorded" || true
        kill_point rpm_put
      done
      return 0
    fi
  fi
  fetch_source "$tag" "$base" "$srcsha" "$W/dl/$base" || return 1
  sign_rpm "$W/dl/$base"
  verify_rpm "$W/dl/$base"
  sha=$(sha_of "$W/dl/$base"); size=$(size_of "$W/dl/$base")
  for k in "${keys[@]}"; do set_entry "$k" pending "$sha" "$size"; done
  write_manifest "$(cat "$W/state")"
  kill_point rpm_manifest
  for k in "${keys[@]}"; do
    put_object "$k" "$W/dl/$base" "$sha" || true
    kill_point rpm_put
  done
}

# Which entries are in a channel's index: stable takes releases, rc everything.
channel_has() { # <channel> <key> <tag>
  [ "$1" = rc ] || ! is_candidate "$3"
}

make_indexes() {
  local c a key st sha size src tag f now stage rc d dts drift
  rm -rf "$W/stage" "$W/pk.files"; mkdir -p "$W/stage" "$W/pk.files"
  now=$(date -u +%s)
  # every package on disk (published entries and the pending ones about to be)
  while IFS=$'\t' read -r st sha size key src tag _; do
    [ "$st" != excluded ] || continue
    [ "$st" = published ] || [ "$(obj_state "$key")" = "$sha" ] || continue
    [ "$sha" != - ] || continue
    mkdir -p "$W/pk.files/$(dirname "$key")"
    rc=0; verify_obj "$key" "$sha" "$W/pk.files/$key" || rc=$?
    [ "$rc" = 0 ] || { junk "object $key differs from its entry"; continue; }
    touch -d @0 "$W/pk.files/$key" # createrepo_c records mtimes: the same packages give the same repodata names
  done <"$W/pk"
  for c in "${channels[@]}"; do
    stage=$W/stage/apt/$c
    mkdir -p "$stage/pool/main/n/nerva"
    while IFS=$'\t' read -r st sha size key src tag _; do
      [[ $key == apt/* ]] || continue
      [ -f "$W/pk.files/$key" ] || continue
      channel_has "$c" "$key" "$tag" || continue
      ln "$W/pk.files/$key" "$stage/pool/main/n/nerva/${key##*/}"
    done <"$W/pk"
    (
      cd "$stage"
      for a in "${arches[@]}"; do
        mkdir -p "dists/$c/main/binary-$a"
        apt-ftparchive -a "$a" packages pool/main/n/nerva >"dists/$c/main/binary-$a/Packages" 2>/dev/null
        gzip -9nc "dists/$c/main/binary-$a/Packages" >"dists/$c/main/binary-$a/Packages.gz"
      done
      case $c in stable) label=Nerva ;; *) label="Nerva candidates" ;; esac
      apt-ftparchive -o APT::FTPArchive::Release::Origin=Nerva -o "APT::FTPArchive::Release::Label=$label" \
        -o "APT::FTPArchive::Release::Suite=$c" -o "APT::FTPArchive::Release::Codename=nerva-$c" \
        -o "APT::FTPArchive::Release::Architectures=amd64 arm64" -o APT::FTPArchive::Release::Components=main \
        -o APT::FTPArchive::Release::Acquire-By-Hash=yes -o APT::FTPArchive::Release::ValidTime=1814400 \
        release "dists/$c" >"dists/$c/Release" 2>/dev/null
    ) || refuse NRV-E1156 "apt-ftparchive failed for $c" "the index tool refused its input" "Install the index tools or free disk on the runner, then run again"
    # `Date` is the run's own clock (P376): a Release dated elsewhere is a run that must not sign
    d=$(sed -n 's/^Date: //p' "$stage/dists/$c/Release" | head -n1)
    # an empty date would parse as today's midnight, so it is refused as undated
    if [ -n "$d" ]; then dts=$(date -u -d "$d" +%s 2>/dev/null) || dts=0; else dts=0; fi
    drift=$(( $(date -u +%s) - dts )); [ "$drift" -ge 0 ] || drift=$((-drift))
    [ "$drift" -le 600 ] || refuse NRV-E1156 "Release of $c is dated '$d', $drift seconds from the run's clock" \
      "apt-ftparchive was given a clock of its own (SOURCE_DATE_EPOCH or a wrapper)" \
      "Install the index tools or free disk on the runner, then run again"
    for a in "${arches[@]}"; do
      local d=$stage/dists/$c/main/binary-$a
      mkdir -p "$d/by-hash/SHA256"
      for f in Packages Packages.gz; do cp "$d/$f" "$d/by-hash/SHA256/$(sha_of "$d/$f")"; done
    done
    sign_clear "$stage/dists/$c/Release" "$stage/dists/$c/InRelease" "${SIGN_U_BOTH[@]}"
    sign_detach "$stage/dists/$c/Release" "$stage/dists/$c/Release.gpg" "${SIGN_U_BOTH[@]}"
    # dnf
    stage=$W/stage/rpm/$c
    mkdir -p "$stage/packages"
    while IFS=$'\t' read -r st sha size key src tag _; do
      [[ $key == rpm/$c/* ]] && [ -f "$W/pk.files/$key" ] || continue
      ln "$W/pk.files/$key" "$stage/packages/${key##*/}"
    done <"$W/pk"
    createrepo_c --general-compress-type=gz --checksum=sha256 --no-database --revision "$now" "$stage" >/dev/null 2>&1 ||
      refuse NRV-E1156 "createrepo_c failed for $c" "the index tool refused its input" "Install the index tools or free disk on the runner, then run again"
    sign_detach "$stage/repodata/repomd.xml" "$stage/repodata/repomd.xml.asc" -u "$FP_CURRENT"
  done
}

# the local file of each replaceable name, in $W/stage
stage_file() {
  case $1 in
    apt/dists/*) echo "$W/stage/apt/$(echo "$1" | cut -d/ -f3)/${1#apt/}" ;;
    rpm/*) echo "$W/stage/$1" ;;
  esac
}

content_named() {
  local c a d f
  for c in "${channels[@]}"; do
    for a in "${arches[@]}"; do
      d=$W/stage/apt/$c/dists/$c/main/binary-$a/by-hash/SHA256
      for f in "$d"/*; do printf 'apt/dists/%s/main/binary-%s/by-hash/SHA256/%s\t%s\n' "$c" "$a" "${f##*/}" "$f"; done
    done
    for f in "$W/stage/rpm/$c/repodata/"*.xml.gz; do printf 'rpm/%s/repodata/%s\t%s\n' "$c" "${f##*/}" "$f"; done
  done
}

upload_indexes() {
  local key file rc name n=0
  while IFS=$'\t' read -r key file; do
    rc=0; r2 put-new "$key" "$file" || rc=$?
    case $rc in 0) note_written "$key" "$(sha_of "$file")" ;; 3)
        rc=0; verify_obj "$key" "$(sha_of "$file")" "$W/idx.bin" || rc=$?
        if [ "$rc" != 0 ]; then
          junk "content-named object $key holds other bytes than its name says"
          r2need put "$key" "$file"
          note_written "$key" "$(sha_of "$file")"
        fi ;;
      *) exit 1 ;;
    esac
    n=$((n + 1)); [ "$n" -lt 10000 ] || bug "more than 10000 content-named objects"
  done < <(content_named)
  kill_point content_named
  replaceable_names
  local c a order=()
  for c in "${channels[@]}"; do
    for a in "${arches[@]}"; do order+=("apt/dists/$c/main/binary-$a/Packages" "apt/dists/$c/main/binary-$a/Packages.gz"); done
    order+=("apt/dists/$c/Release" "apt/dists/$c/Release.gpg" "apt/dists/$c/InRelease")
  done
  for c in "${channels[@]}"; do order+=("rpm/$c/repodata/repomd.xml.asc" "rpm/$c/repodata/repomd.xml"); done
  for name in "${order[@]}"; do
    r2need put "$name" "$(stage_file "$name")"
    note_written "$name" "$(sha_of "$(stage_file "$name")")"
    kill_point index_put
  done
}

# ---- verify before upload (step 5b) ------------------------------------------------------------

# The run's own indexes, against the public key file alone: a GNUPGHOME with no secret and no agent.
verify_before_upload() {
  local vh=$W/verify c d f want must
  rm -rf "$vh"; mkdir -m 700 "$vh"
  want=$(( ${#SIGN_U_BOTH[@]} / 2 ))
  must=$FP_CURRENT; [ "$want" = 2 ] && must="$FP_CURRENT $FP_NEXT"
  for c in "${channels[@]}"; do
    d=$W/stage/apt/$c/dists/$c
    GNUPGHOME=$vh gpgv --keyring "$W/ring.gpg" --status-fd 3 --output "$W/v.out" "$d/InRelease" 3>"$W/v.st" 2>/dev/null ||
      e1161 "InRelease of $c does not verify under packaging/keys/ alone" "the signing key and the pinned key file disagree"
    check_sigs "$W/v.st" "$want" "$want" inrelease "$must" || e1161 "InRelease of $c fails the pinned check: $sig_why" "the signing key and the pinned key file disagree"
    cmp -s "$W/v.out" "$d/Release" || e1161 "the text of InRelease of $c differs from its Release" "the signature covers other text than Release"
    GNUPGHOME=$vh gpgv --keyring "$W/ring.gpg" --status-fd 3 "$d/Release.gpg" "$d/Release" 3>"$W/v.st" 2>/dev/null ||
      e1161 "Release.gpg of $c does not verify under packaging/keys/ alone" "the signing key and the pinned key file disagree"
    check_sigs "$W/v.st" "$want" "$want" releasegpg "$must" || e1161 "Release.gpg of $c fails the pinned check: $sig_why" "the signing key and the pinned key file disagree"
    f=$W/stage/rpm/$c/repodata
    GNUPGHOME=$vh gpgv --keyring "$W/ring.gpg" --status-fd 3 "$f/repomd.xml.asc" "$f/repomd.xml" 3>"$W/v.st" 2>/dev/null ||
      e1161 "repomd.xml.asc of $c does not verify under packaging/keys/ alone" "the signing key and the pinned key file disagree"
    check_sigs "$W/v.st" 1 1 repomd || e1161 "repomd.xml.asc of $c fails the pinned check: $sig_why" "the signing key and the pinned key file disagree"
  done
  rm -rf "$vh"
  for f in "$W"/stage/rpm/*/packages/*.rpm; do
    [ -f "$f" ] || continue
    verify_rpm "$f"
  done
}

# ---- excluding the rpms of one key (slice 2b) ---------------------------------------------------

RPM_ACT=; RPM_KEYID=
# The refresh's rpm_key input: owner only, and one of `exclude <Key ID>`, `restore <Key ID>`. Before any write.
rpm_key_input() {
  [ -n "${RPM_KEY:-}" ] || return 0
  # The runner sets GITHUB_TRIGGERING_ACTOR and a workflow's env: cannot override it; TRIGGERING_ACTOR
  # (what the workflow passes) is read only where the runner's is unset. Logins compare case-insensitively.
  local actor=${GITHUB_TRIGGERING_ACTOR:-${TRIGGERING_ACTOR:-}}
  [ -n "${PACKAGE_REPOS_OWNER:-}" ] && [ -n "$actor" ] && [ "${actor,,}" = "${PACKAGE_REPOS_OWNER,,}" ] ||
    e1139 "rpm_key is for the owner (PACKAGE_REPOS_OWNER); ${actor:-nobody} is not" \
      "it removes packages from the indexes, and only the owner decides that" \
      "Ask the owner to dispatch it, or leave rpm_key empty"
  [[ $RPM_KEY =~ ^(exclude|restore)\ ([0-9a-fA-F]{16})$ ]] ||
    e1139 "rpm_key is not 'exclude <Key ID>' or 'restore <Key ID>' with a 16-hex Key ID" "the input is that and nothing else" \
      "Dispatch it with exclude or restore and a 16-hex Key ID"
  RPM_ACT=${BASH_REMATCH[1]}
  RPM_KEYID=$(printf '%s' "${BASH_REMATCH[2]}" | tr 'A-F' 'a-f')
}

# The Key ID that signed an entry's rpm, read from the bucket's bytes (cached by hash).
entry_kid() { # <key> <sha> -> $KID
  local f=$W/kid.$2 sig rc=0
  KID=
  if [ -f "$f" ]; then KID=$(cat "$f"); return 0; fi
  mkdir -p "$W/kx"
  verify_obj "$1" "$2" "$W/kx/rpm" || rc=$?
  [ "$rc" = 0 ] || e1142_now "the listed object $1 cannot be read with its hash" "the locks make that impossible, so the locks have failed"
  sig=$(rpm -qp --qf '%{RSAHEADER:pgpsig}\n' "$W/kx/rpm" 2>/dev/null </dev/null) || sig=
  KID=$(printf '%s' "$sig" | sed -n 's/.*Key ID \([0-9a-f]\{16\}\)$/\1/p')
  echo "$KID" >"$f"
}

# The refusals that need the entries (NRV-E1139), before any write.
rpm_key_scan() {
  local st sha size key n=0 want rev
  [ -n "$RPM_ACT" ] || return 0
  if [ "$RPM_ACT" = exclude ]; then
    if [ "$RPM_KEYID" = "$(key_id_of "$FP_CURRENT")" ] || { [ -n "$FP_NEXT" ] && [ "$RPM_KEYID" = "$(key_id_of "$FP_NEXT")" ]; }; then
      e1139 "rpm_key excludes the Key ID $RPM_KEYID of the current or next key" "that would drop every rpm the job signs" \
        "Exclude only the Key ID of a key that left fingerprints or was revoked"
    fi
    want=published
  else
    want=excluded
    if [ "$RPM_KEYID" != "$(key_id_of "$FP_CURRENT")" ] && { [ -z "$FP_PREVIOUS" ] || [ "$RPM_KEYID" != "$(key_id_of "$FP_PREVIOUS")" ]; }; then
      e1139 "rpm_key restores the Key ID $RPM_KEYID, which is neither current's nor previous's" \
        "step 5b would refuse those rpms (NRV-E1161) and the bucket could not be published" \
        "Restore undoes a mistaken exclusion of a key still pinned; release a patch version instead"
    fi
    rev=$(gpg --batch --show-keys --with-colons "$keys_dir/nerva-release.asc" 2>/dev/null |
      awk -F: '$1=="pub" {st=$2; next} $1=="fpr" && st=="r" {print tolower(substr($10, 25))} $1=="fpr" {st=""}' | grep -cx "$RPM_KEYID" || true)
    [ "$rev" = 0 ] || e1139 "rpm_key restores the Key ID $RPM_KEYID of a revoked key" \
      "rpm 6 refuses its signatures once a host has the revocation, so a published revocation is final" \
      "Restore undoes a mistaken exclusion only; release a patch version instead"
  fi
  while IFS=$'\t' read -r st sha size key _; do
    [ "$st" = "$want" ] && [[ $key == rpm/* ]] || continue
    entry_kid "$key" "$sha"
    if [ "$KID" = "$RPM_KEYID" ]; then n=$((n + 1)); fi
  done <"$W/pk"
  [ "$n" -gt 0 ] || e1139 "rpm_key $RPM_ACT $RPM_KEYID: no $want rpm is signed by that Key ID" \
    "an exclusion names published rpms and a restoration excluded ones" \
    "Read the Key ID from the NRV-E1161 message, or from rpm -qp"
}

# Mark (or unmark) the rpms of the key, in one manifest generation, after step 4.
rpm_key_apply() {
  local st sha size key changed=0 from to
  [ -n "$RPM_ACT" ] || return 0
  if [ "$RPM_ACT" = exclude ]; then from=published to=excluded; else from=excluded to=published; fi
  while IFS=$'\t' read -r st sha size key _; do
    [ "$st" = "$from" ] && [[ $key == rpm/* ]] || continue
    entry_kid "$key" "$sha"
    [ "$KID" = "$RPM_KEYID" ] || continue
    notice "$RPM_ACT: $key (Key ID $KID)"
    set_entry "$key" "$to" "$sha" "$size"
    changed=1
  done < <(cat "$W/pk")
  if [ "$changed" = 1 ]; then write_manifest "$(cat "$W/state")"; fi
}

cmd_publish() { # <tag or empty> <refresh: 0|1>
  local tag=$1 refresh=$2 st sha size key name h was age
  need_env PACKAGES_BASE_URL GH_TOKEN GITHUB_REPOSITORY R2_ENDPOINT R2_BUCKET
  [ -z "$tag" ] || [[ $tag =~ $tag_re ]] || e1139 "the tag $tag is not a version tag" "publish takes vX.Y.Z or vX.Y.Z-rc.N"
  if [ "$refresh" = 1 ]; then rpm_key_input; fi
  need_tools gpg gpgv python3 gh curl jq sha256sum rpm rpmsign rpmkeys rpmdb apt-ftparchive createrepo_c gzip
  mkdir -p "$W/dl"; setup_keys
  find_current
  bucket_check 1
  disk_check
  if [ -n "$tag" ] && ! awk -F'\t' -v t="$tag" '$6 == t {f = 1} END {exit !f}' "$W/pk"; then
    refuse NRV-E1148 "the manifest has no entry for $tag" "nothing was bound by an approved run" \
      "Restore the asset the approved run bound, or release a new version, then run again"
  fi
  rpm_key_scan
  kill_point checked
  put_pending
  rpm_key_apply
  # promote what is complete: a pending entry whose object exists with its hash
  while IFS=$'\t' read -r st sha size key _; do
    [ "$st" = pending ] && [ "$sha" != - ] || continue
    [ "$(obj_state "$key")" = "$sha" ] || continue
    # the HEAD says what the uploader chose to say: the bytes must be the entry's (P368b)
    grep -qxF "$key" "$W/ok" || verify_obj "$key" "$sha" "$W/adopt.bin" || continue
    set_entry "$key" published "$sha" "$size"
  done < <(cat "$W/pk")
  make_indexes
  verify_before_upload
  # index lines: the new hashes; index-was: what was found and accepted, else the previous index hash
  : >"$W/ix.new"; : >"$W/iw.new"
  replaceable_names
  for name in "${REPLACEABLE[@]}"; do
    h=$(sha_of "$(stage_file "$name")")
    printf '%s\t%s\n' "$h" "$name" >>"$W/ix.new"
    was=$(awk -F'\t' -v k="$name" '$2 == k {print $1}' "$W/accepted")
    [ -n "$was" ] || was=$(awk -F'\t' -v k="$name" '$2 == k {print $1}' "$W/ix")
    [ -z "$was" ] || printf '%s\t%s\n' "$was" "$name" >>"$W/iw.new"
  done
  mv "$W/ix.new" "$W/ix"; mv "$W/iw.new" "$W/iw"
  write_manifest writing
  kill_point writing_manifest
  upload_indexes
  kill_point indexes_uploaded
  served_all "$tag"
  served_written
  kill_point served
  write_manifest complete
  served_written
  if [ "$refresh" = 1 ]; then
    age=$(refresh_age) || e1155_now "reading the date of main's newest commit failed"
    if [ "$age" -gt 45 ]; then
      defer NRV-E1150 "the repository has had no commit for $age days; GitHub disables this schedule at 60" \
        "the signatures expire 21 days after the last refresh" \
        "Run package_repos.sh refresh to re-sign; make a commit to this repository if it has been idle for 45 days"
    fi
  fi
  if [ -n "$tag" ] && awk -F'\t' -v t="$tag" '$6 == t && $1 == "pending" {f = 1} END {exit !f}' "$W/pk"; then
    if [ -n "$GH_FAILED_TAGS" ] && [[ " $GH_FAILED_TAGS " == *" $tag "* ]]; then :; else
      defer NRV-E1148 "an entry of $tag is still pending" "its release reads $(rel_state "$tag" 2>/dev/null || echo unknown) or its bytes differ from what was bound" \
        "Restore the asset the approved run bound, or release a new version, then run again"
    fi
  fi
  finish
}

refresh_age() {
  local d
  d=$(gh api "repos/$GITHUB_REPOSITORY/commits/main" --jq .commit.committer.date 2>/dev/null) || return 1
  d=$(date -u -d "$d" +%s) || return 1
  echo $(( ($(date -u +%s) - d) / 86400 ))
}

cmd_served() {
  need_env PACKAGES_BASE_URL
  need_tools gpg gpgv python3 curl
  mkdir -p "$W"; read_fingerprints; rm -rf "$GNUPGHOME"; mkdir -m 700 "$GNUPGHOME"; build_keyring
  find_current
  served_all "${1:-}"
  finish
}

# `fresh`: stable's served InRelease verifies under the pinned keys and has at least 10 days of
# Valid-Until left (P376; it was 7). The same check the daily watch and ci.yml's repos-fresh make. Under
# the one-key model there is no key expiry to check (NRV-E1160 is retired). Writes nothing.
cmd_fresh() {
  local until ts days
  need_env PACKAGES_BASE_URL
  need_tools gpg gpgv curl
  mkdir -p "$W"; read_fingerprints; rm -rf "$GNUPGHOME"; mkdir -m 700 "$GNUPGHOME"; build_keyring
  curl -fsS --max-time 60 --retry 2 -o "$W/fresh.InRelease" "${PACKAGES_BASE_URL%/}/apt/dists/stable/InRelease" 2>/dev/null ||
    refuse NRV-E1150 "stable's InRelease is not served" "packages.nerva.pro does not answer for apt/dists/stable/InRelease" \
      "Run package_repos.sh refresh to re-sign; make a commit to this repository if it has been idle for 45 days"
  # shellcheck disable=SC2015
  gpgv --keyring "$W/ring.gpg" --status-fd 3 --output "$W/fresh.Release" "$W/fresh.InRelease" 3>"$W/fresh.st" 2>/dev/null &&
    check_sigs "$W/fresh.st" 1 2 inrelease "$FP_CURRENT" ||
    refuse NRV-E1150 "stable's served InRelease does not verify under packaging/keys/ (${sig_why:-gpgv refused it})" \
      "its signature is bad, or it was signed by a key the pin does not list" \
      "Run package_repos.sh refresh to re-sign; make a commit to this repository if it has been idle for 45 days"
  until=$(sed -n 's/^Valid-Until: //p' "$W/fresh.Release" | head -n1)
  { [ -n "$until" ] && ts=$(date -u -d "$until" +%s 2>/dev/null); } ||
    refuse NRV-E1150 "stable's InRelease has no readable Valid-Until ('$until')" "Release is generated with Valid-Until" \
      "Run package_repos.sh refresh to re-sign; make a commit to this repository if it has been idle for 45 days"
  days=$(( (ts - $(date -u +%s)) / 86400 ))
  if [ "$((ts - $(date -u +%s)))" -lt $((10 * 86400)) ]; then
    refuse NRV-E1150 "stable's InRelease is valid for $days more days, not the 10 the weekly refresh keeps" \
      "the signatures expire 21 days after the last refresh, and a refresh is missing" \
      "Run package_repos.sh refresh to re-sign; make a commit to this repository if it has been idle for 45 days"
  fi
  notice "stable's InRelease is valid for $days more days"
}

cmd_verify_manifest() {
  need_tools gpg gpgv
  mkdir -p "$W"; read_fingerprints; rm -rf "$GNUPGHOME"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --dearmor <"$keys_dir/nerva-release.asc" >"$W/ring.gpg"
  verify_manifest "$1" "$2" || { echo "does not verify: $vm_why" >&2; exit 1; }
  cat "$W/body"
}

# verify-sig <kind> <signature> [<data>]: gpgv and the pinned check on one file (the tests' door to
# check_sigs, as verify-manifest is for manifests). Kinds: inrelease, releasegpg, repomd.
cmd_verify_sig() {
  local kind=$1 sig=$2 data=${3:-}
  need_tools gpg gpgv
  mkdir -p "$W"; read_fingerprints; rm -rf "$GNUPGHOME"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --dearmor <"$keys_dir/nerva-release.asc" >"$W/ring.gpg"
  if [ -n "$data" ]; then
    gpgv --keyring "$W/ring.gpg" --status-fd 3 "$sig" "$data" 3>"$W/status" 2>/dev/null || true
  else
    gpgv --keyring "$W/ring.gpg" --status-fd 3 --output /dev/null "$sig" 3>"$W/status" 2>/dev/null || true
  fi
  check_sigs "$W/status" 1 2 "$kind" || { echo "does not verify: ${sig_why}" >&2; exit 1; }
}

cmd_cleanup() {
  if [ -d "$GNUPGHOME" ]; then gpgconf --kill all 2>/dev/null || true; fi
  rm -rf "$GNUPGHOME" "$W"
}

main() {
  local cmd=${1:-}
  case $cmd in
    cleanup) cmd_cleanup; return ;;
  esac
  rm -rf "$W"; mkdir -p "$W"; : >"$W/junk"; : >"$W/deferred"; : >"$W/deferred.codes"; : >"$W/ok"; : >"$W/written"
  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    e1139 "SOURCE_DATE_EPOCH is set" "Release carries the run's own clock, and a fixed date would make the signatures look fresh"
  fi
  case $cmd in
    ready) [ $# = 3 ] || usage; cmd_ready "$2" "$3" ;;
    publish) [ $# = 2 ] || usage; cmd_publish "$2" 0 ;;
    refresh) [ $# = 1 ] || usage; cmd_publish "" 1 ;;
    fresh) [ $# = 1 ] || usage; cmd_fresh ;;
    served) cmd_served "${2:-}" ;;
    verify-manifest) [ $# = 3 ] || usage; cmd_verify_manifest "$2" "$3" ;;
    sums-verify) [ $# = 2 ] || usage; cmd_sums_verify "$2" ;;
    verify-sig) [ $# = 3 ] || [ $# = 4 ] || usage; cmd_verify_sig "$2" "$3" "${4:-}" ;;
    *) usage ;;
  esac
}
usage() { echo "usage: package_repos.sh ready <tag> <published> | publish <tag> | refresh | fresh | served [<tag>] | verify-manifest <file> <generation> | sums-verify <tag> | cleanup" >&2; exit 64; }

main "$@"
