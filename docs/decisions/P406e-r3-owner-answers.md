---
id: P406e
date: 2026-11-13
area: Testing
amends: P406
---

# The owner's answers on R3: four generic VMs, the bounds stand, no Fly data point

The owner answered the R3 brief's five questions on 2026-11-13:

1. **Hosts:** four generic VMs over SSH, which the owner provisions (option a). P406 stands.
2. **Repeatability:** 10% on ops/s, p50 and p99, p99.9 and max not checked. P406c stands.
3. **Refusal:** no override flag for NRV-E0723. P406d stands.
4. **Defaults:** `--cache-grid` and `--cache-rows` keep their defaults. R3 measures; any change is
   a decision after the table, in its own pull request.
5. **Fly data point:** dropped. The brief's slice 6 (the nightly's Machine run with the timeline)
   is removed; slice 7 keeps its number.

The reason (owner): Fly is not a priority now.

What it costs: R3 has no Fly data point, so the Fly p99 of 147 to 188 ms is explained on the
topology alone, by the same experiments, not placed on the Machine it was seen on. If it ever
matters, one dispatch of the harness with `--hosts=local` on that Machine would add it.
