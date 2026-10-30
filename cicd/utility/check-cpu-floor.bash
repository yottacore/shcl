#!/usr/bin/env bash

##	Purpose:
##		The x86_64 release builds have to run on plain x86-64 (v1), so the last
##		Core 2 Duo (Penryn) and the AMD Phenom II and Athlon II run them. Penryn
##		has SSSE3 and SSE4.1 but no POPCNT, and the AMD chips the other way
##		round, so v1 is the floor they share. Faster code is fine only behind a
##		run-time CPU check, never from the build target.
##
##		Two halves:
##		- Every binary named is disassembled and fails on any instruction past
##		  v1. This is what covers the Windows and FreeBSD builds, which can't be
##		  booted here.
##		- The --run binary, the Linux build, is booted under QEMU's full-system
##		  emulator as a Penryn and as a Phenom, with an initramfs holding busybox,
##		  the binary and its libraries. It runs the CLI over the conformance corpus
##		  and has to give the same bytes and exit codes as the same binary run on
##		  this host. Before that, a probe runs one instruction from each extension
##		  that tells the 2 CPUs apart from v2 and v3, and each has to trap or not
##		  as the real chip would, or the emulator isn't gating what the run relies
##		  on.
##	Syntax:
##		check-cpu-floor.bash [--run LINUX_BIN] BIN...
##		  BIN         x86_64 ELF or PE binaries to disassemble
##		  --run       also boot this one under the emulated CPUs
##		  SHCL_FLOOR_KERNEL   kernel to boot (default /boot/vmlinuz-$(uname -r));
##		                      it has to run on v1 itself, as Debian's does
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
testWhere=check-cpu-floor; testCounter=nBad
declare -i nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"

fBad(){ echo "check-cpu-floor: $1" >&2; nBad+=1 ;}
fUsage(){ echo "usage: check-cpu-floor.bash [--run LINUX_BIN] BIN..." >&2; exit 2 ;}

runBin=""; scanBins=()
while (($#)); do case "$1" in
	--run) (($# >= 2)) || fUsage; runBin="$2"; shift 2 ;;
	-h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed 's/^##	\{0,1\}//'; exit 0 ;;
	-*) fUsage ;;
	*) scanBins+=("$1"); shift ;;
esac; done
if [[ -n "${runBin}" && " ${scanBins[*]} " != *" ${runBin} "* ]]; then scanBins+=("${runBin}"); fi
((${#scanBins[@]})) || fUsage
for f in "${scanBins[@]}"; do [[ -f "${f}" ]] || { echo "check-cpu-floor: no such file: ${f}" >&2; exit 2 ;}; done

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

##	Instructions past v1, by extension. Mnemonics are objdump's AT&T ones.
##	tzcnt is left out on purpose: LLVM writes `rep bsf` for a count whose input
##	can't be zero, those bytes decode as tzcnt, and a CPU without BMI1 runs
##	them as bsf, which gives the same answer for a nonzero input. lzcnt has no
##	such use and does count, since an old CPU runs it as bsr and answers wrong
##	without trapping.
# shellcheck disable=SC2016  ## awk's own fields
scanAwk='
function ext(m) {
	if (m ~ /^v/ && m !~ /^ver[rw]$/)                                     return "AVX family"
	if (m ~ /^(addsubp[sd]|hadd|hsub|lddqu|movddup|movs[hl]dup|fisttp|monitor|mwait)/) return "SSE3"
	if (m ~ /^(pshufb|ph(add|sub)(w|d|sw)|pmaddubsw|pmulhrsw|psign[bwd]|pabs[bwd]|palignr)$/) return "SSSE3"
	if (m ~ /^(blendv?p[sd]|pblendvb|pblendw|dpp[sd]|extractps|insertps|movntdqa|mpsadbw|packusdw|pcmpeqq|pextr[bdq]|pinsr[bdq]|pmaxs[bd]|pmaxu[wd]|pmins[bd]|pminu[wd]|pmov[sz]x[bwd][wdq]|pmuldq|pmulld|ptest|round[ps][sd]|phminposuw)$/) return "SSE4.1"
	if (m ~ /^(pcmp[ei]str[im]|pcmpgtq|crc32[bwlq]?)$/)                   return "SSE4.2"
	if (m ~ /^(extrq|insertq|movnts[sd])$/)                               return "SSE4a"
	if (m ~ /^popcnt[wlq]?$/)                                             return "POPCNT"
	if (m ~ /^lzcnt[wlq]?$/)                                              return "LZCNT"
	if (m ~ /^(andn|bextr|blsi|blsmsk|blsr)[lq]?$/)                       return "BMI1"
	if (m ~ /^(bzhi|mulx|pdep|pext|rorx|sarx|shlx|shrx)[lq]?$/)           return "BMI2"
	if (m ~ /^(blcfill|blci|blcic|blcmsk|blcs|blsfill|blsic|t1mskc|tzmsk)[lq]?$/) return "TBM"
	if (m ~ /^movbe[wlq]?$/)                                              return "MOVBE"
	if (m ~ /^(adcx|adox)[lq]?$/)                                         return "ADX"
	if (m ~ /^(aes|pclmul|sha1|sha256|gf2p8)/)                            return "crypto"
	if (m ~ /^(rdrand|rdseed)/)                                           return "RDRAND"
	if (m ~ /^(femms|pavgusb|pf[a-z0-9]+|pi2f[dw]|pmulhrw|pswapd)$/)      return "3DNow"
	if (m ~ /^cmpxchg16b$/)                                               return "CX16"
	if (m ~ /^(lahf|sahf)$/)                                              return "LAHF-SAHF"
	if (m ~ /^(rdtscp|rdpid|xgetbv|xsave|xrstor|clflushopt|clwb|prefetchwt1)/) return "other"
	return ""
}
NF >= 2 && $1 ~ /^ *[0-9a-f]+:$/ {
	n = split($2, w, " ")
	i = 1
	while (i < n && w[i] ~ /^(rep|repz|repe|repnz|repne|lock|data16|addr32|notrack|bnd|[cdefgs]s|rex(\.[WRXB]+)?)$/) i++
	m = w[i]; e = ext(m)
	if (e == "" && $2 ~ /%[yz]mm|%k[0-7]/) e = "AVX family"
	if (e == "") next
	if (!(e in hits)) first[e] = $1 " " $2
	hits[e]++
}
END { for (e in hits) if (index(" " allow " ", " " e " ") == 0) printf "    %s: %d, first at %s\n", e, hits[e], first[e] }
'

fTest ddwpp no instruction past x86-64-v1 in any build
if ! command -v objdump >/dev/null 2>&1; then
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then fBad "objdump is missing, and the gate requires it"; fi
	echo "check-cpu-floor: skipping the scan (no objdump)"
	echo check-cpu-floor >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
else
	for f in "${scanBins[@]}"; do
		fmt="$(objdump -f "${f}" 2>/dev/null | sed -n 's/.*file format //p' || true)"
		##	Rust's Windows x86_64 targets turn on SSE3, CMPXCHG16B and LAHF/SAHF
		##	(rustc --print cfg shows them), and 64-bit Windows 8.1 and later need
		##	the last 2 to run at all. Penryn and Phenom have all 3.
		case "${fmt}" in
			elf64-x86-64) allow="" ;;
			pei-x86-64)   allow="SSE3 CX16 LAHF-SAHF" ;;
			*) fBad "${f}: not an x86_64 ELF or PE binary (${fmt:-unreadable})"; continue ;;
		esac
		objdump -d --no-show-raw-insn "${f}" > "${work}/dis" || { fBad "${f}: objdump failed"; continue ;}
		nInsn="$(grep -c $'^ *[0-9a-f]*:\t' "${work}/dis" || true)"
		##	A disassembly that came out empty would pass, so it has to be a real one.
		if ((nInsn < 1000)); then fBad "${f}: only ${nInsn} instructions disassembled"; continue; fi
		hits="$(awk -F'\t' -v allow="${allow}" "${scanAwk}" "${work}/dis" | sort)"
		if [[ -n "${hits}" ]]; then
			fBad "${f}: instructions past x86-64-v1:"$'\n'"${hits}"
		else
			echo "check-cpu-floor: ${f}: ${nInsn} instructions, none past v1${allow:+ (with ${allow// /, } allowed)}"
		fi
	done
fi

##	The extensions each emulated CPU must trap on, and must run, as the real
##	chip would. QEMU's TCG traps on these by CPUID bit. It doesn't for lzcnt or
##	tzcnt, which it runs as bsr and bsf on both, so only the scan sees those.
penrynTraps="popcnt sse42 avx bmi1 movbe"; penrynRuns="sse3 ssse3 sse41"
phenomTraps="ssse3 sse41 sse42 avx bmi1 movbe"; phenomRuns="sse3 popcnt"

fProbeSource(){ cat <<'EOF'
#include <string.h>
int main(int argc, char **argv) {
	unsigned long long r = 0, one = 1;
	const char *k = argc > 1 ? argv[1] : "";
	if (!strcmp(k, "sse3"))        __asm__ volatile("haddps %%xmm1, %%xmm0" ::: "xmm0");
	else if (!strcmp(k, "ssse3"))  __asm__ volatile("pshufb %%xmm1, %%xmm0" ::: "xmm0");
	else if (!strcmp(k, "sse41"))  __asm__ volatile("ptest %%xmm1, %%xmm0" ::: "cc");
	else if (!strcmp(k, "sse42"))  __asm__ volatile("crc32q %1, %0" : "+r"(r) : "r"(one));
	else if (!strcmp(k, "popcnt")) __asm__ volatile("popcntq %1, %0" : "=r"(r) : "r"(one));
	else if (!strcmp(k, "avx"))    __asm__ volatile("vxorps %%xmm0, %%xmm0, %%xmm0" ::: "xmm0");
	else if (!strcmp(k, "bmi1"))   __asm__ volatile("andnq %1, %1, %0" : "=r"(r) : "r"(one));
	else if (!strcmp(k, "movbe"))  __asm__ volatile("movbeq (%1), %0" : "=r"(r) : "r"(&one));
	else return 2;
	return (int)(r & 0);
}
EOF
}

##	Copies a binary's shared libraries into the image at the same paths, and
##	notes their dirs for the guest's LD_LIBRARY_PATH.
fCopyLibs(){
	local lib
	while read -r lib; do
		mkdir -p "${ir}${lib%/*}"
		cp -L "${lib}" "${ir}${lib}"
		echo "${lib%/*}" >> "${work}/libdirs"
	done < <(ldd "$1" 2>/dev/null | grep -oE '/[^ ]+' || true)
}

# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/corpus-cases.bash"

##	Busybox sh, the same script on the host and in the guest, so the two
##	lists differ only where the CPU made a difference. Globbing is off, since
##	reads hold wildcards. Applets go through busybox by name, because the host
##	side has only the image's bin on PATH.
fDriver(){ cat <<'EOF'
set -f
tab="$(printf '\t')"; IFS="${tab}"
busybox mkdir -p o
while read -r n rest; do
	set -- ${rest}
	shcl "$@" > "o/${n}.o" 2> "o/${n}.e" < /dev/null
	echo "${n} rc $?"
done < cases.tsv
IFS=' '; set +f
cd o && busybox md5sum *
EOF
}

fBoot(){   ## fBoot CPU -> ${work}/boot-CPU.log
	local cpu="$1" log="${work}/boot-$1.log"
	##	TCG, never KVM: under KVM the guest runs on this host's real CPU and
	##	nothing traps.
	timeout 1200 qemu-system-x86_64 -accel tcg -cpu "${cpu}" -smp 1 -m 768 \
		-display none -nodefaults -no-user-config -no-reboot -serial "file:${log}" \
		-kernel "${kernel}" -initrd "${work}/ir.cpio.gz" \
		-append "console=ttyS0 quiet panic=-1 rdinit=/init" < /dev/null > "${work}/qemu-${cpu}.out" 2>&1 \
		|| fBad "${cpu}: qemu exited $? ($(tail -n 2 "${work}/qemu-${cpu}.out" | tr '\n' ' '))"
	tr -d '\r' < "${log}" > "${log}.txt" 2>/dev/null || true
	grep -qx 'FLOOR done' "${log}.txt" 2>/dev/null \
		|| fBad "${cpu}: the guest never finished; last lines: $(tail -n 5 "${log}.txt" 2>/dev/null | tr '\n' '|')"
}

fControls(){   ## fControls CPU TRAPS RUNS
	local cpu="$1" k got
	for k in $2; do
		got="$(sed -n "s/^FLOOR probe ${k} //p" "${work}/boot-${cpu}.log.txt")"
		[[ "${got}" == 132 ]] || fBad "${cpu}: ${k} should trap (SIGILL, 132), got ${got:-nothing}; the emulator isn't gating it"
	done
	for k in $3; do
		got="$(sed -n "s/^FLOOR probe ${k} //p" "${work}/boot-${cpu}.log.txt")"
		[[ "${got}" == 0 ]] || fBad "${cpu}: ${k} should run, got ${got:-nothing}"
	done
}

fCompare(){   ## fCompare CPU
	local cpu="$1" log="${work}/boot-$1.log.txt" nGot nDiff nIll n
	nGot="$(sed -n 's/^FLOOR count //p' "${log}")"
	nIll="$(sed -n 's/^FLOOR sigill //p' "${log}")"
	nDiff="$(sed -n 's/^FLOOR ndiff //p' "${log}")"
	[[ "${nGot}" == "${nCases}" ]] || fBad "${cpu}: ${nGot:-no} CLI runs of ${nCases} came back"
	[[ "${nIll}" == 0 ]] || fBad "${cpu}: ${nIll:-?} CLI runs died of an illegal instruction"
	if [[ "${nDiff}" != 0 ]]; then
		fBad "${cpu}: ${nDiff:-?} CLI results differ from this host's"
		while read -r n; do
			echo "    $(grep -m1 "^${n}"$'\t' "${ir}/cases.tsv" | tr '\t' ' ')" >&2
		done < <(sed -n 's/^FLOOR diff //p' "${log}" | awk '{ if ($2 == "rc") print $1; else { sub(/\.[oe]$/, "", $2); print $2 } }' | sort -un | head -n 5)
	else
		echo "check-cpu-floor: ${cpu}: ${nGot} CLI runs, same bytes and exit codes as this host"
	fi
}

fTestEnd

missing=""
if [[ -n "${runBin}" ]]; then
	kernel="${SHCL_FLOOR_KERNEL:-/boot/vmlinuz-$(uname -r)}"
	for t in qemu-system-x86_64 busybox cc cpio gzip ldd; do command -v "${t}" >/dev/null 2>&1 || missing+=" ${t}"; done
	[[ -r "${kernel}" ]] || missing+=" readable ${kernel}"
	if [[ -z "${missing}" ]]; then
		fTest ddwpq Penryn traps on what it lacks
		ir="${work}/ir"
		mkdir -p "${ir}/bin" "${ir}/proc" "${ir}/dev" "${ir}/c"
		: > "${work}/libdirs"
		fProbeSource > "${work}/probe.c"
		cc -O0 -o "${ir}/bin/probe" "${work}/probe.c" || fBad "the probe did not build"
		cp "$(command -v busybox)" "${ir}/bin/busybox"
		cp "${runBin}" "${ir}/bin/shcl"
		for f in probe busybox shcl; do fCopyLibs "${ir}/bin/${f}"; done
		for d in "${root}"/project/conformance/*/; do cp -r "${d%/}" "${ir}/c/"; done
		fCases > "${ir}/cases.tsv"
		nCases="$(wc -l < "${ir}/cases.tsv")"
		fDriver > "${ir}/run.sh"
		##	The host's answers, from the same binary, script and relative paths.
		( cd "${ir}" && env -i PATH="${ir}/bin" HOME=/ "${ir}/bin/busybox" sh run.sh ) > "${ir}/exp.lst" \
			|| fBad "the host run of the CLI cases failed"
		##	A list missing its sums would compare exit codes alone.
		nSums="$(grep -c '\.[oe]$' "${ir}/exp.lst" || true)"
		((nSums == 2 * nCases)) || fBad "the host run summed ${nSums} outputs of $((2 * nCases))"
		rm -rf "${ir}/o"
		cat > "${ir}/init" <<EOF
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin HOME=/ LD_LIBRARY_PATH=$(sort -u "${work}/libdirs" | paste -sd: -)
mount -t proc proc /proc
mount -t devtmpfs dev /dev
echo "FLOOR model \$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
for k in sse3 ssse3 sse41 sse42 popcnt avx bmi1 movbe; do
	( probe "\${k}" ) > /dev/null 2>&1
	echo "FLOOR probe \${k} \$?"
done
cd / && sh run.sh > got.lst 2> /dev/null
echo "FLOOR count \$(grep -c ' rc ' got.lst)"
echo "FLOOR sigill \$(grep -c ' rc 132\$' got.lst)"
diff exp.lst got.lst | grep '^+[0-9a-f]' | head -n 50 | sed 's/^+/FLOOR diff /'
echo "FLOOR ndiff \$(diff exp.lst got.lst | grep -c '^+[0-9a-f]')"
echo "FLOOR done"
poweroff -f
EOF
		chmod +x "${ir}/init"
		( cd "${ir}" && find . | cpio -o -H newc --quiet ) | gzip -1 > "${work}/ir.cpio.gz"

		fBoot Penryn
		fControls Penryn "${penrynTraps}" "${penrynRuns}"
		fTest ddwpr Penryn runs the CLI cases like this host
		fCompare Penryn
		fTest ddwps Phenom traps on what it lacks
		fBoot phenom
		fControls phenom "${phenomTraps}" "${phenomRuns}"
		fTest ddwpt Phenom runs the CLI cases like this host
		fCompare phenom
	else
		if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then fBad "the emulated boot needs${missing}, and the gate requires it"; fi
		echo "check-cpu-floor: skipping the emulated boot (no ${missing# })"
		echo check-cpu-floor >> "${SHCL_GATE_SKIPS:-/dev/null}"
		fTestSkipBlock
	fi
fi
fTestEnd

if ((nBad)); then
	echo "check-cpu-floor: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-cpu-floor: OK"

##	History:
##		2026-10-13  Created, for the Core 2 Duo and Phenom II floor.
