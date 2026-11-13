---
id: P331
date: 2026-11-11
area: Releases
amends: P295
---

# The .deb's Maintainer carries the project's email address

`packaging/linux/build-deb.sh` writes `Maintainer: The Nerva authors <nerva@nerva.pro>`.

**Reason.** P295 left the field as a URL, which Debian policy 5.6.2 does not accept (it wants an
email address), because the repository named no contact address (#307). The owner has given one:
`nerva@nerva.pro`.

**Cost.** The address receives whatever tools mail to a package's maintainer. The rpm spec has no
`Packager` or `Vendor` field, so it is unchanged.
