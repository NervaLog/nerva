---
id: P489
date: 2026-11-18
area: Releases
---

# An import removes its staging file only if it created it

**Decision.** `import_run` removes `<path>.importing` after a failed pass 2 only when
`command_import` has set `created`, which it does once `Storage.init`'s exclusive create has
succeeded. A create that loses (`error.PathAlreadyExists`) is refused with NRV-E0814 and removes
nothing. A `linkat` that loses to an import that finished first is the same refusal.

**Why.** Two processes can both pass the existence checks while they verify their inputs. The loser
used to unlink the path, which was the winner's file (#488).

**Cost.** `Storage.init` can fail after it has created the file (the allocation: no space; a lost
lock is a panic, not an error). It reports that as the same errors as before the create, so this
invocation cannot tell, and the file is left; the log says it may be left and should be removed
if no import of the path is running (NRV-E0706's row says the same). Removing it anyway could
delete another import's file, which is the bug. NRV-E0814 is new rather than NRV-E0806, because
E0806 says an import did not finish, and the other may be running. A `linkat` that loses to a
file already at `<path>` is NRV-E0004, naming `<path>`, since that file need not come from an
import.

**Known hazard, not fixed here.** NRV-E0806's hint ("remove `<path>.importing`") is wrong while
the import that owns it still runs: another import can then create a new staging file, and the
first links it by name as `<path>` (#78's failure). It predates this decision: #491.
