---
id: N39
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# No application-specific code in Nerva: the first gateway is removed.

Owner's direction: the dog-fooding application uses releases and the generic API, and no
application-specific code or mention remains in Nerva. Removed: the gateway that spoke that
application's ledger protocol (with its key-value routes), the two views written for it, the
differential tests against its reference implementation (which included a copy of that
implementation), their build step and CI step, the `LEDGER_KEY` fallback, and the integration
guide, which now lives with the application. Kept, as general pieces: chunked documents
(`documents.zig`, used by the catalog; the id derivation's domain strings changed, which is safe
because nothing is deployed), and everything the gateway taught (one request per connection
N37, chunk ids N12/N13/N25). The application keeps its own rules on its side, on top of
`nerva api`: transactions with reads at the version seen, chunking its larger values, and
declared views where they fit. Decisions N6–N20, N24–N26 and N28–N29 are marked superseded and
keep their numbers; GOALS-1.0 and the worklog describe the workload instead of naming it.
