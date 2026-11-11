---
id: P342
date: 2026-11-11
area: Releases
amends: P339
---

# install.sh --uninstall refuses while units run, and keeps the instance links a package uses

**Decision.**
1. `install.sh --uninstall` runs the NRV-E1118 check (and NRV-E1102, failing closed, when `systemctl list-units` errors) before it removes `/usr/local/bin/nerva`, through the same function as `--upgrade` (`refuse_if_running`). It applies when `/usr/local/bin/nerva` exists: the replicas that restart would run a package's `/usr/bin/nerva`, possibly another release (#292), or none. Also with `--dry-run`.
2. When a package's `/usr/bin/nerva` exists, `--uninstall` does not disable the `nerva@*` and `nerva-api@*` enable links; it prints `keep <unit>`. The package's units serve the same instances, so the links are not dangling, and disabling them left the cluster down at the next boot (#340). Without a package, links are removed as before.
3. NRV-W1101's fix line says the same as NRV-W1102's: keep one install, stop the replicas, uninstall, start them, `systemctl enable` any instance not enabled. NRV-W1102 no longer says `--uninstall` disables the instances.

**Why.** #340, from the re-review of #339. Option 2 over a warning: a warning is easy to miss and the harm is a silent boot failure; keeping the links is the smaller change to the operator's state.

**Cost.** `--uninstall` over running replicas needs them stopped first. A host with both installs that really wants the instances off must `systemctl disable` them itself.
