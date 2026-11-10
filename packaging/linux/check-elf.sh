# Part of Nerva (https://github.com/NervaLog/nerva): sourced by build-deb.sh and build-rpm.sh
# (v0.7.1, P295). check_elf <script> <file> <machine>: refuses, with NRV-E1110, a file that is not
# an ELF executable for <machine> (x86_64 or aarch64), reading the header as install.sh's
# elf_machine does (so an emulator that would run a foreign binary cannot hide the mismatch).
check_elf() {
    magic=$(od -An -tx1 -N4 "$2" | tr -d ' \n')
    found=
    if [ "$magic" = 7f454c46 ]; then
        case "$(od -An -tx1 -j18 -N2 "$2" | tr -d ' \n')" in
            3e00) found=x86_64 ;;
            b700) found=aarch64 ;;
            *) found=unknown ;;
        esac
    fi
    if [ "$found" != "$3" ]; then
        printf 'error[NRV-E1110]: %s: %s is %s, and the package is for %s\n' "$1" "$2" \
            "${found:+for }${found:-not an ELF executable}" "$3" >&2
        echo "  cause  The binary given to the package build is not the one built for the package's architecture" >&2
        echo "  fix    build nerva for the package's target (zig build -Drelease -Dtarget=<arch>-linux) and pass that file" >&2
        exit 2
    fi
}
