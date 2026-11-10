# Part of Nerva (https://github.com/NervaLog/nerva): builds nerva-<version>-1.<arch>.rpm with
# rpmbuild -bb (v0.7.1, P284b; docs/briefs/v0.7.1.md, slice 5). Nothing is compiled: the release
# binary for the target is a build input, so the spec has no BuildRequires and one x86_64 machine
# builds both architectures (`--target aarch64`). It is driven by packages.py and, later, by
# release.yml, which pass:
#   --define "nerva_version 0.7.1"          the release (VERSION)
#   --define "nerva_bin /path/to/nerva"     the binary built for the target
#   --define "nerva_src /path/to/packaging/linux"   the unit files, examples and package-setup.sh
#   --define "nerva_root /path/to/repository"       LICENSE and NOTICE
# and the reproducibility macros (packages.py has the list). The package is unsigned.
# The scriptlets are the .deb's maintainer scripts, one file each: %pre is package-setup.sh (the
# user and the directories), %preun is package-prerm.sh (on removal only, disables the instances
# the operator enabled). No reload scriptlet: systemd's rpm file triggers run daemon-reload after
# a unit changes. A comment between sections would become part of the scriptlet above it.

# No debuginfo, no stripping, no brp scripts: the binary is prebuilt for a target this machine
# may not be, and the build must not change its bytes.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           nerva
Version:        %{nerva_version}
Release:        1
Summary:        Nerva, a research database with derived state maintained from one replicated log
License:        Apache-2.0
URL:            https://github.com/NervaLog/nerva
# The binary is static: nothing to compute, and rpmfc cannot read a foreign architecture's.
AutoReqProv:    no
Requires(pre):  shadow-utils coreutils glibc-common
Recommends:     systemd

%description
One static binary: a replica (nerva start), the JSON gateway (nerva api) and the tools around
them. The package installs the binary, the systemd units nerva@.service and nerva-api@.service,
and the example settings in /usr/share/nerva. It creates the system user nerva and the
directories /var/lib/nerva and /etc/nerva, and nothing more: it never formats, enables or starts
a replica, and removing it leaves /var/lib/nerva.

%prep

%build

%install
install -D -m 0755 %{nerva_bin} %{buildroot}/usr/bin/nerva
install -D -m 0644 %{nerva_src}/nerva@.service %{buildroot}/usr/lib/systemd/system/nerva@.service
install -D -m 0644 %{nerva_src}/nerva-api@.service %{buildroot}/usr/lib/systemd/system/nerva-api@.service
install -D -m 0644 %{nerva_src}/replica.env.example %{buildroot}/usr/share/nerva/replica.env.example
install -D -m 0644 %{nerva_src}/api.env.example %{buildroot}/usr/share/nerva/api.env.example
install -D -m 0644 %{nerva_root}/LICENSE %{buildroot}/usr/share/doc/nerva/LICENSE
install -D -m 0644 %{nerva_root}/NOTICE %{buildroot}/usr/share/doc/nerva/NOTICE

# package-setup.sh, the .deb's preinst: the user and the two directories, never any removal.
%pre -p /bin/sh
%(cat %{nerva_src}/package-setup.sh)

%preun -p /bin/sh
%(cat %{nerva_src}/package-prerm.sh)

%files
%attr(0755,root,root) /usr/bin/nerva
%attr(0644,root,root) /usr/lib/systemd/system/nerva@.service
%attr(0644,root,root) /usr/lib/systemd/system/nerva-api@.service
%dir %attr(0755,root,root) /usr/share/nerva
%attr(0644,root,root) /usr/share/nerva/replica.env.example
%attr(0644,root,root) /usr/share/nerva/api.env.example
%dir %attr(0755,root,root) /usr/share/doc/nerva
%license %attr(0644,root,root) /usr/share/doc/nerva/LICENSE
%attr(0644,root,root) /usr/share/doc/nerva/NOTICE
