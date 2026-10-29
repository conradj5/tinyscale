# shellcheck shell=bash
# Expected executable-format properties per GOOS/GOARCH. Requires common.sh.

# elf_expect GOARCH: print "CLASS DATA MACHINE" as reported by `readelf -h`,
# fields separated by '|'. Returns 1 for unknown architectures.
elf_expect() {
	case "$1" in
	amd64) echo 'ELF64|little endian|Advanced Micro Devices X86-64' ;;
	386) echo 'ELF32|little endian|Intel 80386' ;;
	arm64) echo 'ELF64|little endian|AArch64' ;;
	arm) echo 'ELF32|little endian|ARM' ;;
	riscv64) echo 'ELF64|little endian|RISC-V' ;;
	loong64) echo 'ELF64|little endian|LoongArch' ;;
	mips) echo 'ELF32|big endian|MIPS R3000' ;;
	mipsle) echo 'ELF32|little endian|MIPS R3000' ;;
	mips64) echo 'ELF64|big endian|MIPS R3000' ;;
	mips64le) echo 'ELF64|little endian|MIPS R3000' ;;
	ppc64) echo 'ELF64|big endian|PowerPC64' ;;
	ppc64le) echo 'ELF64|little endian|PowerPC64' ;;
	s390x) echo 'ELF64|big endian|IBM S/390' ;;
	*) return 1 ;;
	esac
}

# elf_osabi_expect GOOS: extended regex for readelf's "OS/ABI:" value.
# Go emits ELFOSABI_NONE ("UNIX - System V") for Linux; UPX may rewrite it to
# ELFOSABI_LINUX ("UNIX - GNU"), which is equally valid. FreeBSD uses
# ELFOSABI_FREEBSD. Other systems are identified by ELF notes, so print
# nothing (no OS/ABI check) for them.
elf_osabi_expect() {
	case "$1" in
	linux | android) echo '^UNIX - (System V|GNU)$' ;;
	freebsd) echo 'FreeBSD' ;;
	*) echo '' ;;
	esac
}

# file_regex FORMAT GOARCH: extended regex the `file` description must match.
file_regex() {
	local fmt="$1" arch="$2"
	case "$fmt" in
	macho)
		case "$arch" in
		arm64) echo '^Mach-O 64-bit (arm64|ARM64) executable' ;;
		amd64) echo '^Mach-O 64-bit x86_64 executable' ;;
		*) return 1 ;;
		esac
		;;
	pe)
		case "$arch" in
		amd64) echo '^PE32\+ executable.*x86-64' ;;
		arm64) echo '^PE32\+ executable.*Aarch64' ;;
		386) echo '^PE32 executable.*Intel (80386|i386)' ;;
		*) return 1 ;;
		esac
		;;
	elf) echo '^ELF ' ;;
	*) return 1 ;;
	esac
}

# host_goarch: the Go architecture name of the machine running this script.
host_goarch() {
	case "$(uname -m)" in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	armv7* | armv6* | armv5*) echo arm ;;
	i?86) echo 386 ;;
	riscv64) echo riscv64 ;;
	ppc64le) echo ppc64le ;;
	s390x) echo s390x ;;
	*) uname -m ;;
	esac
}

host_goos() {
	case "$(uname -s)" in
	Linux) echo linux ;;
	Darwin) echo darwin ;;
	FreeBSD) echo freebsd ;;
	*) uname -s | tr '[:upper:]' '[:lower:]' ;;
	esac
}
