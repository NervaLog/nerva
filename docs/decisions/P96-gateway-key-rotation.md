---
id: P96
date: 2026-10-06
area: "Milestone 3: positioned reads and the first views"
---

# A gateway accepts a second key during a rotation: `NERVA_KEY_NEXT`

`nerva api` and `nerva view` had one key (`NERVA_KEY`), so changing it meant restarting every
gateway and every caller at once. Now a gateway may also be given `NERVA_KEY_NEXT`, and accepts
`X-Nerva-Key` equal to either. A rotation is three restarts, none of them urgent: give every
gateway the new key as `NERVA_KEY_NEXT`; move every caller to the new key; then make the new key
`NERVA_KEY` and unset `NERVA_KEY_NEXT`. Keys are not otherwise structured, so the rules stay
NERVA_KEY's: each set key is non-empty, and the next key differs from the current one (equal keys
would mean the rotation was misconfigured). A `NERVA_KEY_NEXT` that is set but empty is refused
rather than read as unset, for the same reason. The gateway exits at start on a key it cannot
use, with a message that names the variable and never the key.
- **One function, both gateways.** `http_connection.key_accepted(keys, candidate)` decides for
  both, so they cannot drift. It hashes the candidate against both keys and compares each digest
  in constant time (`key_matches`, #10), with no early return: when no next key is set it
  compares against the current key twice. The time taken does not tell which key matched, nor
  whether a rotation is under way.
- **Limits in one place.** README's new "Limits" section gathers every limit a caller can hit
  (body and memory per request, connections, deadlines, documents, views' per-op budgets,
  client sessions), each checked against the constant in the code, and says that the replicas'
  network must be private: replicas do not yet authenticate each other (NV-3 part B, #102).
- **An oversized body stays `400`.** A `Content-Length` over 4 MiB answers
  `400 {"error":"body too large"}`, as it has since the gateway's start, rather than `413`: the
  owner chose not to change what callers already handle. `413` remains the answer for a request
  that is too complex or too large to commit, which a caller can split.
