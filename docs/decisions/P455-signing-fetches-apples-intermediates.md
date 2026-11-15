---
id: P455
date: 2026-11-14
area: Releases
amends: P343
---

# Mac signing fetches Apple's Developer ID intermediates; the .p12 need not hold them

**Decision.** `mac-sign.yml` downloads Apple's Developer ID G2 and Developer ID CA intermediate
certificates from `https://www.apple.com/certificateauthority/` in a step of its own (no secret in
its environment, system tools only), `mac_ca.sh fetch`, and checks each against a SHA-256 pinned in
that script. `mac_keychain.sh create` imports both into the temporary keychain before it counts
identities. The owner's .p12 holds the Developer ID Application certificate and its key only.
P343's setup, which had the owner add the G2 intermediate to the .p12, no longer applies.

**Reason.** Apple's certificate export usually leaves the intermediate out, and without it the
identity has no chain: `security find-identity -v` counts none and the run ends in NRV-E1121
(issue #454). Zigbox made the same change (Zigbox/zigbox#153). The files are public, so the pin, not
secrecy, is what protects: a changed or forged file is refused (NRV-E1165) and never imported. A
step of its own keeps curl from running beside the secrets. New codes: NRV-E1165 (fetch and pin),
NRV-E1166 (the keychain script was given no intermediates).

**Cost.** Signing needs `www.apple.com` to answer. When Apple reissues an intermediate, a pull
request must change the pin (the G2 certificate is valid until 2031, the older CA until 2027-02).
Re-wrapping the .p12 was checked: it passes a file to `openssl pkcs12 -export`, not a pipe, so
LibreSSL's double read of `-in` (Zigbox's other fix) does not apply.
