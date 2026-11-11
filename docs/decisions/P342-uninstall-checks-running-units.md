---
id: P342
date: 2026-11-11
area: Releases
amends: P339
---

# install.sh --uninstall refuses while units run, and keeps the instance links a package uses

**Decision.**
1. `install.sh --uninstall` runs the NRV-E1118 check (and NRV-E1102, failing closed, when `systemctl list-units` errors) before it removes `/usr/local/bin/nerva`, through the same function as `--upgrade` (`refuse_if_running`). It applies when `/usr/local/bin/nerva` exists: the replicas that restart would run a package's `/usr/bin/nerva`, possibly another release (#292), or none. Also with `--dry-run`.
2. For each `nerva@*` and `nerva-api@*` enable link, `--uninstall` tests whether the package ships that link's template (`/usr/lib/systemd/system/nerva@.service` or `nerva-api@.service`; the binary is not the test, as a hand copy at `/usr/bin/nerva` serves no unit). If it does, the link is kept (`keep <unit>`) and, after the tarball's unit in `/etc/systemd/system` is removed and systemd reloaded, made again with `systemctl reenable` so that it points at the package's unit and not at a deleted file. Otherwise the link is disabled as before. Disabling the links left the cluster down at the next boot (#340).
3. NRV-W1101's fix line says the same as NRV-W1102's: keep one install, stop the replicas, uninstall, start them, enable any instance not enabled. The text names the actions and has no `systemctl <verb>`, which the maintainer-script guard in `tests/packaging/packages.py` refuses in `package-setup.sh`. NRV-E1111's fix line says that a tarball uninstall with no package installed yet removes the enabled instances. NRV-W1102 no longer says `--uninstall` disables the instances.

**Why.** #340, from the re-review of #339. Option 2 over a warning: a warning is easy to miss and the harm is a silent boot failure; keeping the links is the smaller change to the operator's state.

**Cost.** `--uninstall` over running replicas needs them stopped first. A host with both installs that really wants the instances off must `systemctl disable` them itself.
