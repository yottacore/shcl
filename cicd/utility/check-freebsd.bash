#!/usr/bin/env bash

##	Purpose:
##		The freebsd-x86_64 release links FreeBSD's own loader and libc, so no
##		Linux box runs it. This boots FreeBSD's official VM image under QEMU and
##		runs that build over the same CLI cases the CPU floor check uses, and it
##		has to give the same stdout, stderr and exit code as the Linux release
##		built from the same source (2026102022450000).
##		The image is pinned below by URL and sha256, fetched once into the
##		pipeline's cache and checked again on every run. The guest has no
##		network. Its first-boot cloud-init (nuageinit) reads a script off a FAT
##		disk QEMU makes from a folder, the build and cases come in on a raw tar
##		disk, and the outputs go back out on another.
##		KVM when /dev/kvm is usable, TCG otherwise.
##	Syntax:
##		check-freebsd.bash LINUX_BIN FREEBSD_BIN
##		  LINUX_BIN           the native release build, run here for the answers
##		  FREEBSD_BIN         the freebsd-x86_64 release build
##		  SHCL_FREEBSD_CACHE  where the image is kept (default
##		                      ~/.cache/shcl-cicd/freebsd; the pipeline's image
##		                      sets /cache/freebsd)
##		  SHCL_FREEBSD_ACCEL  tcg to leave KVM out
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
testWhere=check-freebsd; testCounter=nBad
declare -i nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/corpus-cases.bash"

##	A new release here needs both lines from its CHECKSUM.SHA256.
imgUrl="https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
imgSha256="e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f"
imgRelease="FreeBSD 15.1-RELEASE"

fBad(){ echo "check-freebsd: $1" >&2; nBad+=1 ;}
case "${1:-}" in -h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed 's/^##	\{0,1\}//'; exit 0 ;; esac
(($# == 2)) || { echo "usage: check-freebsd.bash LINUX_BIN FREEBSD_BIN" >&2; exit 2 ;}
linBin="$(realpath -- "$1")"; bsdBin="$(realpath -- "$2")"
for f in "${linBin}" "${bsdBin}"; do [[ -f "${f}" ]] || { echo "check-freebsd: no such file: ${f}" >&2; exit 2 ;}; done

cache="${SHCL_FREEBSD_CACHE:-${HOME}/.cache/shcl-cicd/freebsd}"
xzName="${imgUrl##*/}"; img="${cache}/${xzName%.xz}"

##	The unpacked image is kept, with a sum taken right after the download was
##	checked, and is checked against it each run. The download itself goes.
fImage(){
	[[ -f "${img}" && -f "${img}.sha256" ]] && ( cd "${cache}" && sha256sum -c --status "${img##*/}.sha256" ) && return 0
	mkdir -p "${cache}" || return 1
	local part="${cache}/${xzName}.part.$$"
	echo "check-freebsd: fetching ${xzName}, about 640 MB"
	curl -fsSL --retry 3 -o "${part}" "${imgUrl}" || { rm -f "${part}"; echo "check-freebsd: could not fetch ${imgUrl}" >&2; return 1 ;}
	if ! echo "${imgSha256}  ${part}" | sha256sum -c --status -; then
		rm -f "${part}"; fBad "${xzName} does not match its pinned sha256"; return 1
	fi
	if ! { xz -dc -T "${CPU_CAP:-2}" "${part}" > "${img}.part.$$" \
		&& ( cd "${cache}" && sha256sum "${img##*/}.part.$$" | sed "s/\.part\.$$\$//" > "${img##*/}.sha256.part.$$" ) \
		&& mv -f "${img}.part.$$" "${img}" && mv -f "${img}.sha256.part.$$" "${img}.sha256" ;}; then
		rm -f "${part}" "${img}.part.$$" "${img}.sha256.part.$$"; fBad "could not unpack ${xzName}"; return 1
	fi
	rm -f "${part}"
}

##	Plain sh, the same script here and in the guest, so the two runs differ
##	only by the build. Globbing is off, since reads hold wildcards.
fDriver(){ cat <<'EOF'
set -f
tab="$(printf '\t')"; IFS="${tab}"
mkdir -p o
while read -r n rest; do
	set -- ${rest}
	./shcl "$@" > "o/${n}.o" 2> "o/${n}.e" < /dev/null
	echo "${n} rc $?"
done < cases.tsv
EOF
}

##	nuageinit runs a user-data that starts with #! late in the first boot, as
##	root, with its output on the serial console. The disks are in the order
##	QEMU is given them below: the system, this one, the payload, the outputs.
fUserData(){ cat <<'EOF'
#!/bin/sh
echo "FBSD uname $(uname -sr)"
mkdir -p /root/w && cd /root/w && tar -xf /dev/vtbd2 && [ -f run.sh ] || echo "FBSD no payload on vtbd2"
sh run.sh > rc.lst 2> /dev/null
tar -cf /dev/vtbd3 rc.lst o || echo "FBSD could not write vtbd3"
echo "FBSD done"
poweroff
EOF
}

missing=""
for t in qemu-system-x86_64 curl xz tar sha256sum timeout; do command -v "${t}" >/dev/null 2>&1 || missing+=" ${t}"; done
fTest EtMgsNv the pinned FreeBSD image is in the cache and matches its sha256
haveImage=0
if [[ -n "${missing}" ]]; then
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then fBad "needs${missing}, and the gate requires it"; fi
	echo "check-freebsd: skipping (no ${missing# })"
	echo check-freebsd >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
elif fImage; then
	haveImage=1
elif ((nBad == 0)); then
	##	A fetch that failed, as against a sum that didn't match, which fImage
	##	has already counted.
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then fBad "no FreeBSD image, and the gate requires it"; fi
	echo "check-freebsd: skipping (no FreeBSD image)"
	echo check-freebsd >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
fi
if ((haveImage)); then
	work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
	cd "${work}"
	mkdir -p g/c ci
	for d in "${root}"/project/conformance/*/; do cp -r "${d%/}" g/c/; done
	fCases > g/cases.tsv
	nCases="$(wc -l < g/cases.tsv)"
	fDriver > g/run.sh
	cp -r g h
	cp "${bsdBin}" g/shcl; cp "${linBin}" h/shcl
	( cd h && env -i PATH=/usr/bin:/bin HOME=/ sh run.sh > rc.lst 2> /dev/null ) || fBad "the host run of the CLI cases failed"
	tar -C g --format=pax -cf in.tar .
	##	Sparse, and well over what the outputs take.
	truncate -s "$(( $(du -sb h | cut -f1) * 4 + 64 * 1024 * 1024 ))" out.img
	printf 'instance-id: shcl-check\n' > ci/meta-data
	fUserData > ci/user-data

	fTest EtMgrmj FreeBSD boots and runs the freebsd-x86_64 release
	accel=(-accel tcg -cpu max); how=TCG
	if [[ "${SHCL_FREEBSD_ACCEL:-}" != tcg && -r /dev/kvm && -w /dev/kvm ]]; then accel=(-accel kvm -cpu host); how=KVM; fi
	##	snapshot=on keeps the cached image and the FAT folder as they are.
	SECONDS=0
	timeout 900 qemu-system-x86_64 "${accel[@]}" -smp 2 -m 1024 \
		-display none -nodefaults -no-user-config -no-reboot -serial "file:${work}/boot.log" \
		-drive "if=virtio,format=qcow2,snapshot=on,file=${img}" \
		-drive "if=virtio,driver=vvfat,dir=${work}/ci,label=CIDATA,snapshot=on" \
		-drive "if=virtio,format=raw,readonly=on,file=${work}/in.tar" \
		-drive "if=virtio,format=raw,file=${work}/out.img" \
		< /dev/null > qemu.out 2>&1 \
		|| fBad "qemu exited $? ($(tail -n 2 qemu.out | tr '\n' ' '))"
	bootSecs="${SECONDS}"
	tr -d '\r' < boot.log > boot.txt 2>/dev/null || true
	got="$(sed -n 's/^FBSD uname //p' boot.txt)"
	[[ "${got}" == "${imgRelease}" ]] || fBad "the guest said it was ${got:-nothing}, not ${imgRelease}"
	sed -n 's/^FBSD \(no payload\|could not\)/check-freebsd: guest: &/p' boot.txt >&2
	grep -qx 'FBSD done' boot.txt || fBad "the guest never finished; last lines: $(tail -n 5 boot.txt | tr '\n' '|')"
	mkdir -p g/back
	tar -C g/back -xf out.img 2>/dev/null || fBad "nothing came back on the output disk"

	fTest EtMgs5P the freebsd-x86_64 release runs the CLI cases like the Linux one
	nGot="$(grep -c ' rc ' g/back/rc.lst 2>/dev/null || true)"
	((nGot == nCases)) || fBad "${nGot:-0} of ${nCases} CLI runs came back from FreeBSD"
	##	One pass each over the exit codes and the outputs, then the cases named.
	diffIds="$( { diff h/rc.lst g/back/rc.lst | sed -n 's/^[<>] \([0-9]*\) rc .*/\1/p' || true
		diff -rq h/o g/back/o 2>/dev/null | grep -oE '[0-9]+\.[oe]( |$)' | sed 's/\.[oe] *$//'; } | sort -un || true)"
	nDiff=0; [[ -z "${diffIds}" ]] || nDiff="$(wc -l <<< "${diffIds}")"
	awk -F'\t' 'NR == FNR { bad[$1] = 1; next } ($1 in bad) && shown++ < 5 { $1 = "    differs: " $1; print }' OFS=' ' - g/cases.tsv <<< "${diffIds}" >&2
	if ((nDiff)); then fBad "${nDiff} of ${nCases} CLI runs differ from the Linux build"
	else echo "check-freebsd: ${nCases} CLI runs under ${imgRelease}, same bytes and exit codes as the Linux build (${how}, ${bootSecs} s with the boot)"; fi
else
	fTestSkipBlock
fi
fTestEnd

if ((nBad)); then
	echo "check-freebsd: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-freebsd: OK"

##	History:
##		2026-10-21  Created, for 2026102022450000.
##		2026-10-21  The image's cache path comes from the image (2026102114300000).
