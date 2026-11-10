# Jepsen harness checklist

Run this on your own diff before the first review of any change under `tests/jepsen/` (P250).
Each item names the pull request whose review found it. Say in the PR which items the change touched.

## Harness failure or Nerva finding

- [ ] A harness throw, an unreadable reply or a probe that failed is `:unknown` (NRV-E0607), never
      `:valid? false`, and never NRV-E0604 or a Nerva issue. Only a gateway or replica seen not
      running is a finding. (#244, #238)
- [ ] A real finding in another checker outranks a harness `:unknown`; `:unknown` never composes to
      `true`. (#244)
- [ ] Every unresolved key, unread record or zero-fault run is `:unknown`, not valid. (#239, #242)
- [ ] Only a 409 is Nerva's refusal; 413, 503 and a missing status are the gateway's. (#239)

## Every exit, stop and teardown path

- [ ] `InterruptedException` is rethrown, not caught by a bare `Exception` handler (check
      `act-on-node!` and every new `try`). (#244)
- [ ] Teardown, umount and cleanup run in `finally`, are bounded, and a throw in one step does not
      skip the next. (#244, #242)
- [ ] A shell script's stop budget is the sum of its steps, and the unit's `TimeoutStopSec` and the
      texts that quote the number agree with it. (#249)
- [ ] A fault that throws after acting has already queued its victims for recovery. (#242)

## Isolation

- [ ] One gateway's or node's error does not drop another's `:dead` or `:pending` result: `try`
      per gateway, per node. (#244, #238)
- [ ] A kill or cut acts on, and records, only what was running; `pause` too. A reused pid is not
      a running gateway. (#238, #244)

## Final phase

- [ ] The final start, heal and recover judge all nodes, after the replicas and network are back;
      list generators in the order they must run. (#238, #244, #242)
- [ ] A final op that never ran or never completed is `:expected` or `:incomplete`, not a pass;
      count completions, not invocations. (#238, #244, #242)
- [ ] A new fault is added to `final-start?`. (#244, #242)

## Teeth and canaries

- [ ] Every new check has a test that fails on the previous code, and a hosted teeth run that
      can fail (a blind canary proves nothing). Quote what it caught. (#239)
      Say which checker can fail it: `lose-unfsynced-writes`'s `:lazyfs` checker judges the fault,
      not Nerva's durability, unless `--lazyfs-strict-sync`. The hosted canary (LazyFS on a minority
      of nodes, P242j) runs with it: its teeth are `:lazyfs` `:valid? false` with `:lost-bytes` above 0
      (stock LazyFS keeps O_DSYNC writes unsynced); a minority loss is repaired by VSR, so it cannot
      fail `:keys`, and it does not test Nerva's durability. The `:keys` checker's teeth (lost acknowledged
      records; `:warnings [:unsynced-bytes-lost]`, `:scopes {:all n}`, n at least 1, the first fault is
      `:all`) need `--lazyfs-all-nodes`, the R1 host only. (#242)
- [ ] An input check that reads options agrees with the parser: tools.cli keeps the last of a
      repeated option, so only the last `--nemesis` counts. (#262)
- [ ] A fixture uses the code and shape of the wire (NRV-E0203, not a guess). (#239)

## Bounds

- [ ] Every wait, poll, scan and retry has a limit and a named total (`10 s plus one probe round`,
      not `10 s`). A wait on the single nemesis worker is short. (#238, #239, #242)
- [ ] A catch-up or settle gate also holds when it is called with no nodes. (#242)

## Evidence

- [ ] Read a hosted run's verdict from `results.edn` in the `jepsen-store` artifact (top-level
      `:valid?`, `:final-starts`/`:expected`, the faults that happened), not from the job colour.
      (#244, #239, #242)
- [ ] The PR description is true of the final diff: test counts, files, error codes, "Not
      verified". It is updated after each fix round. (#239, #244)
- [ ] A new failure has its NRV code and a `docs/ERRORS.md` entry with the right blame. (#238, #244)
