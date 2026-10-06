---
id: P100
date: 2026-10-06
area: "Milestone 3: positioned reads and the first views"
amends: N33
---

# Gateways accept a second key, `NERVA_KEY_NEXT`, so keys rotate without refusing anyone

N33 keyed `nerva api` by `X-Nerva-Key` from `NERVA_KEY` alone (and `nerva view` followed it), so
changing the key meant a moment where every client holding the other one was refused. INF-1
asked to rotate keys with no such moment.
- **The rule:** when `NERVA_KEY_NEXT` is set and not empty, both gateways accept a request whose
  `X-Nerva-Key` matches either key. An empty `NERVA_KEY_NEXT` counts as unset. `NERVA_KEY` is still
  required. A rotation is three restarts of each gateway: add `NERVA_KEY_NEXT`, move clients to
  it, then make it `NERVA_KEY` alone.
- **Timing:** `keys_match` always compares the request's key with both keys, each in constant
  time (both hashed, the digests compared), whether or not a next key is set. So the time
  says neither whether nor which key matched. Keys are never logged; a gateway logs at start
  that it accepts both, and warns when `NERVA_KEY_NEXT` equals `NERVA_KEY` or is only whitespace
  (whitespace is a key like any other, but almost certainly a mistake).
- **Why not more keys, or a key file:** two keys are what one rotation needs, and environment
  variables are how the gateways take their secret today. A list would add parsing and limits
  for no case anyone has asked for.
- **What it costs:** during a rotation two secrets open the gateway, so a leaked old key stays
  valid until the last restart. Each request costs one more hash.
