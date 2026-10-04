# Integrating Nerva with Botpike: instructions for a coding bot

You are a coding bot working in Botpike's repositories (mainly `Botpike/runtime`). This document
tells you how to put Nerva under the Botpike runtime, how to tell whether it works, and what not
to do. Read all of it before you start. Follow the target repository's own rules (`CLAUDE.md`,
`AGENTS.md`, README "Changes" entries) as well; where they are stricter, they win.

## Ground rules

- **This is dog-fooding, not a Botpike feature of Nerva.** Botpike is Nerva's first real user,
  chosen to find out where Nerva falls short. Do not ask for, or write, Botpike-specific
  behaviour inside Nerva. The boundary is the runtime's existing ledger protocol, which Nerva
  speaks through an adapter (`nerva ledgerd`), plus the two generic `Store` routes below. If
  something is missing, report the general gap (see "Reporting"); do not patch around it in
  Nerva.
- **No real money.** Nerva has had no external correctness review. Botpike's balances stay
  where they are: TigerBeetle in `Botpike/app`, or the runtime's own ledger. Never point
  `Botpike/app`'s money paths (`AGENTS.md` lists them) at Nerva, and never change them for this
  work.
- **Change behaviour in one place at a time.** Each phase below has an acceptance test that
  compares against what already exists. Do not start a phase before the previous one passes.
- **Nerva is a dependency, not code to edit.** Pin a commit, and report problems instead of
  forking.

## What is ready

| Piece | State | Phase |
|---|---|---|
| `nerva ledgerd`: the runtime's ledger protocol, all 17 routes of `ledger/ledgerd.py` | Ready. Replies are byte-identical to `ledgerd.py` (at runtime commit `23010ba`) over scripted and fuzzed requests. Two gateways racing on one ledger keep it balanced. **Never yet run under the runtime's Unison scenarios: that is your first job.** | 1 |
| `/v1/store/get`, `/v1/store/put`: the runtime's `Store` ability over HTTP | Ready on Nerva's side. Needs a small handler in `runtime.u`. | 2 |
| `nerva view`: `journal` (each line with its op), `spend` (agent rollup), and `as_of` reads of any ledger key at any op | Ready, read-only. | 3 |
| Approvals attributed to an identity; a claim lease replacing `$STATE/.lock` | **Not built.** Waiting on a human decision (Nerva `docs/DECISIONS.md` N30). Keep the runtime's lock. | — |

Nerva's own decision log is `docs/DECISIONS.md` in `topwombat/nerva`. N6–N30 cover everything
in this document; read them when a behaviour surprises you.

## Getting the binary

`topwombat/nerva` is private: CI that fetches it needs a read token for that repository. Ask
the owner for the token. Do not make the repository public, and do not copy its source into a
Botpike repository.

**Prefer a release.** Each `v*` tag publishes binaries for Linux and macOS (x86_64, aarch64) on
the repository's Releases page, once Nerva's CI has passed on that commit:
`nerva-<tag>-<target>.tar.gz` plus `SHA256SUMS`. Pin a tag and check the checksum. With a token
that can read the repository:

```bash
gh release download <tag> --repo topwombat/nerva --pattern 'nerva-<tag>-x86_64-linux.tar.gz' \
    --pattern SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

If no release exists yet, build at a pinned commit (use `main` at or after the commit that added this file, and record the
hash you used):

```bash
git clone https://github.com/topwombat/nerva && cd nerva && git checkout <pinned commit>
./zig/download.sh          # Zig 0.14.1 into ./zig (ziglang.org, falling back to PyPI)
./zig/zig build -Drelease  # zig-out/bin/nerva, a static binary (~20 MB); ~2 min
```

It runs on Linux (io_uring) and macOS, on x86_64 with AES or on aarch64. Inside Docker, the
default seccomp profile of recent Docker versions blocks io_uring. If `nerva start` fails there
with an io_uring or permission error, run that container with
`--security-opt seccomp=unconfined`, or run the replica outside the container.

## Running Nerva

A cluster is one or more replicas, each with one data file. One replica is enough for
development and CI. Use three when you want to test a replica crashing.

```bash
# Once. Cluster id 0 is reserved for Nerva's own tests: use any other id.
nerva format --cluster=1 --replica=0 --replica-count=1 --development 1_0.nerva   # ~1.1 GiB file

# The replica: ~850 MB resident with --development.
nerva start --addresses=3101 --development 1_0.nerva &

# The ledger gateway: one process per ledger id. Prints its port on stdout (useful with :0).
LEDGER_KEY=<key> nerva ledgerd --cluster=1 --addresses=3101 --ledger=1 --listen=127.0.0.1:8090 &

# Optional (phase 3): the read side, for every ledger. Prints its port on stdout.
LEDGER_KEY=<key> nerva view --cluster=1 --addresses=3101 --listen=127.0.0.1:8091 &
```

- `--development` relaxes Direct IO (needed on tmpfs and overlayfs) and uses small caches.
  Leave it on for CI.
- The key comes only from the `LEDGER_KEY` environment variable, never from a flag or a file in
  a repository. It is checked against `X-Ledger-Key`, exactly as `ledgerd.py` does.
- For three replicas, format `--replica=0..2 --replica-count=3`, and start each one with
  `--addresses=3101,3102,3103` (every replica gets every address, in replica order). Give the
  gateways and the view the same address list.
- State survives restarts of any process: the data file is the only state. To start from zero,
  format a new file. `/v1/admin/init` resets a ledger's balances but keeps its `Store` data.
- The gateway serves one request at a time and retries a transaction that conflicts with
  another gateway (up to 32 times, then `503 ledger busy`). Several gateways may serve the same
  ledger id.
- Each connection carries one request: replies say `Connection: close`, and a connection that
  sends nothing for 10 s is dropped. Any HTTP/1.1 client handles this; it means one waiting
  client cannot hold up the others.

Smoke test, in the runtime's wire format:

```bash
k=<key>; p() { curl -s -X POST -H "X-Ledger-Key: $k" --data-binary "$2" http://127.0.0.1:8090$1; echo; }
p /v1/admin/init $'amount=20000'
p /v1/reserve $'request_id=planner-1:0:0\nmemo_hex=6c6c6d\nestimate=3000'   # granted=true ... ok=true
p /v1/settle  $'request_id=planner-1:0:0\nactual=2500'                     # within=true ... ok=true
p /v1/summary ''   # summary=ledger: available 17500, held 0, settled 2500, prevented 0
```

## Phase 1: Nerva as the runtime's ledger service

Nothing in `runtime.u` changes. The runtime already has an HTTP ledger backend
(`brt backend <url> <key>`; runtime README, "The ledger protocol"), and its CI already runs every
scenario against `ledger/ledgerd.py` over HTTP. Run the same scenarios against `nerva ledgerd`
instead.

1. Start Nerva as above, with the gateway on `127.0.0.1:8090`.
2. `./brt backend http://127.0.0.1:8090 <key>`, then run what CI runs against `ledgerd.py`:
   `./demo.sh`, the crash-at-the-nth-request loop, `tests/race.sh`, `tests/overrun.sh`,
   `tests/limits.sh`, `tests/resubmit.sh`, `tests/badreplies.sh` (read `.github/workflows/`
   for the exact invocations).
3. Add a CI step beside the existing `ledgerd.py` step. It must not replace that step: the
   reference stays the reference.

**Acceptance:** the transcript matches the `ledgerd.py` transcript, line for line, after the
same normalization CI already applies (hashes and sizes). Every other script passes as it does
against `ledgerd.py`. In particular, the demo must end at
`ledger: available 5144, held 0, settled 52856, prevented 9440`. Run Highwayman
(`Botpike/highwayman`) against it if you can.

A difference is a Nerva bug until shown otherwise: report it (see "Reporting") with the route,
the request fields and both replies. Do not change the runtime to accommodate it.

## Phase 2: agent state in Nerva

The runtime keeps suspended agents (`<id>.cont`, `<id>.code`, `<id>.receipt`,
`<id>.receipt.sig`, and the staged `<id>.next.*`) as files, through one ability:

```unison
ability Store where
  get : Text -> Optional Bytes
  put : Text -> Bytes -> ()
```

Nerva serves exactly that ability:

```
POST /v1/store/get   name_hex=<hex of name>                       → found=true, value_hex=<hex> | found=false; ok=true
POST /v1/store/put   name_hex=<hex of name>, value_hex=<hex>      → ok=true
```

A put replaces the value. An empty value is a value. There is no delete (the ability has
none). Values may be up to 64 KiB and names up to 1024 bytes; anything larger is refused with
400. The runtime's suspends are 2–5 KB. Data is per ledger id (the gateway's `--ledger`), kept
apart from the ledger's balances.

Add a handler next to `Store.files`, using the runtime's existing `http.call`, `http.need` and
`http.needBool` (so a non-success or incomplete reply fails the command, as everywhere else).
A sketch to adapt, not tested code (there was no `ucm` where it was written):

```unison
Store.http : Backend -> Request {Store} a ->{IO, Exception} a
Store.http b = cases
  { r } -> r
  { Store.get name -> k } ->
    -- The signing keys never leave the machine: see below.
    if local name then handle k (localGet name) with Store.http b
    else
      lines = http.call b "/v1/store/get" [("name_hex", hex.encode name)]
      found = if http.needBool "/v1/store/get" "found" lines
        then Some (Bytes.fromHex (http.need "/v1/store/get" "value_hex" lines))
        else None
      handle k found with Store.http b
  { Store.put name bytes -> k } ->
    if local name then ... -- as Store.files
    else
      _ = http.call b "/v1/store/put" [("name_hex", hex.encode name), ("value_hex", Bytes.toHex bytes)]
      handle k () with Store.http b
```

Rules for the handler:

- **`daemon.key` and `daemon.pub` stay in local files.** The runtime reads its Ed25519 signing
  key through `Store` (`receipt.sign` reads `daemon.key`). Anyone holding the ledger key can read Nerva's
  store, so a signing key stored there would let them forge receipts. Route exactly those two
  names to `Store.files`, and check that a run leaves no `daemon.*` name in Nerva.
- Install `Store.http` only when an HTTP backend is configured, and keep `Store.files` as the
  default, as `backend.read` already does for the ledger.
- **Keep `$STATE/.lock` (runtime D43).** Nerva does not yet offer the claim lease that would
  replace it. Until it does, one run keeps one state directory, as now.
- Keep the staged suspend (`.next.*`, then the sequence advance, then the copy, runtime D34)
  unchanged. It is correct on top of these routes. Making suspend atomic is a later proposal,
  not part of this phase.

**Acceptance:** with the handler installed, every phase 1 check still passes with the same
transcript. `brt verify` and `brt bundle` still verify. A suspend made by one process, with its
state directory then deleted except for `daemon.key`, `daemon.pub` and `backend.url`, resumes
from Nerva in a fresh process. The crash-at-the-nth-request loop still recovers.

## Phase 3 (optional): reading history

`nerva view` answers reads, never writes. Possible uses, for example in the control room:

```
GET /v1/views/<ledger>/journal?min_op=latest   → op=<n>, line=<op>:<hex>…, ok=true
GET /v1/views/<ledger>/spend?min_op=latest     → op=<n>, rollup=<path hex>:<depth>:<own>:<subtree>:<settled>:<denied>…, ok=true
GET /v1/ledgers/<ledger>/as_of?op=<n>&key_hex=<hex of key>  → op=<n>, found=…, value_hex=…, ok=true
```

All three use `X-Ledger-Key`. Every journal line carries the op that wrote it, so "what was the
ledger when this was decided" is an `as_of` read at that op: for example, `available` at the
op of an `ALLOWANCE` line. Keys are the ledger's own (`available`, `held`, `hold.<id>`,
`done.<id>`, `seq.<agent>`; results are `result.<id>`). `min_op=<n>` and `as_of?op=<n>` wait up
to 10 s for the view to reach op `n`, then answer 504. The view rebuilds itself from the log
when it starts, so its first answer may take a moment on a large ledger.

`spend` is Botpike's agent rollup (own spend, subtree spend, settled and denied counts, depth),
computed from the runtime's request ids. Comparing it with `agent_spend_rollup` in
`Botpike/app` is a useful read-only check. Do not replace the app's rollup with it.

## Reporting

File findings as issues on `topwombat/nerva`, labelled `botpike`, one finding per issue:

- what you ran, the Nerva commit, and the runtime commit;
- for a protocol difference: the route, the request fields, the `ledgerd.py` reply and the
  `nerva ledgerd` reply;
- for a crash or hang: the replica's, gateway's or view's stderr (`--log-debug` for more);
- what the general gap is, if it is not a plain bug. "The runtime needs X" is a request;
  "Nerva cannot do Y, which any user doing Z needs" is a finding.

Do not file decisions that belong to people as bugs. These are open and owned by the Nerva and
Botpike owners: approval attribution and claim leases (N30), and whether balances ever move to
Nerva (GOALS-1.0, G8).

## What not to do

- Do not point real money at Nerva, or touch `Botpike/app`'s ledger, receipt or auth code.
- Do not remove the `ledgerd.py` CI step, the file backend, `Store.files` or `$STATE/.lock`.
- Do not put `daemon.key` (or any secret) in Nerva.
- Do not add Botpike-specific routes, fields or special cases to Nerva, and do not fork it.
- Do not commit the ledger key, the Nerva token or data files.
