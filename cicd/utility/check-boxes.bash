#!/usr/bin/env bash

##	Purpose:
##		Runs a release build on the test box that runs it natively, over the
##		same CLI cases the other release checks use, and it has to give the
##		same stdout, stderr and exit code as the Linux release built from the
##		same source (2026102419263412).
##		Each box is held through the VM state helper's wrap, which takes the
##		shared host lock and puts a VM back the way it was found. The box gets
##		a work folder of its own under its temp root, removed after.
##		A box that isn't there, or no helper, is a SKIP, and the rest go on.
##	Syntax:
##		check-boxes.bash LINUX_BIN BOX|SSH_TARGET|BIN...
##		  LINUX_BIN         the native release build, run here for the answers
##		  BOX               the box's name in the host lock
##		  SSH_TARGET        user@host for ssh
##		  BIN               the release build that box runs; empty when none
##		  SHCL_VM_STATE     the VM state helper (default claude_vm-state.bash in
##		                    the synced util tree, then on PATH)
##		  SHCL_BOX_WAIT     seconds to wait for a box another session holds
##		                    (default 900)
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

self="$(realpath -- "${BASH_SOURCE[0]}")"
meDir="$(dirname -- "${self}")"
root="$(cd -- "${meDir}/../.." && pwd)"
sshOpts=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)

##	The box half, plain sh for FreeBSD's sh and macOS's bash 3.2. Makes
##	${HOST_TEMP:-${TMPDIR:-/tmp}}/shcl/<stamp>_<NNN>, unpacks stdin there, runs
##	the cases at low priority, sends the outputs back, and removes the folder.
fBoxScript(){ cat <<'EOF'
base="${HOST_TEMP:-${TMPDIR:-/tmp}}"; base="${base%/}/shcl"
mkdir -p "${base}" || exit 90
stamp="$(date +%Y%m%d-%H%M%S)"; n=1
while :; do
	w="${base}/${stamp}_$(printf '%03d' "${n}")"
	mkdir "${w}" 2>/dev/null && break
	n=$((n + 1)); [ "${n}" -le 999 ] || exit 90
done
gone(){
	case "${w}" in *..*|*//*) return 0 ;; "${base}"/*_[0-9][0-9][0-9]) ;; *) return 0 ;; esac
	[ -d "${w}" ] && [ ! -h "${w}" ] && rm -rf -- "${w}"
}
trap gone EXIT
cd "${w}" && tar -xf - && [ -f run.sh ] || exit 91
env -i PATH=/usr/bin:/bin HOME=/ nice -n 19 sh run.sh > rc.lst 2> /dev/null
tar -cf - rc.lst o
EOF
}

##	The same as check-freebsd's, so the two runs differ only by the build.
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

##	--on-box runs inside wrap, so the lock is held only while the box works.
##	It leaves a status file: ran, or skip and why.
if [[ "${1:-}" == --on-box ]]; then
	(($# == 4)) || exit 2
	target="$2"; inTar="$3"; outDir="$4"
	if ! ssh "${sshOpts[@]}" "${target}" true < /dev/null > /dev/null 2>&1; then
		echo "skip ssh to ${target} did not answer" > "${outDir}/status"; exit 0
	fi
	rc=0; boxCmd="$(fBoxScript)"; boxCmd="${boxCmd//\'/\'\\\'\'}"
	# shellcheck disable=SC2029  ## the box half is meant to be expanded here
	ssh "${sshOpts[@]}" "${target}" "sh -c '${boxCmd}'" < "${inTar}" > "${outDir}/out.tar" 2> "${outDir}/ssh.err" || rc=$?
	if ((rc)); then echo "fail the box exited ${rc}: $(tail -n 2 "${outDir}/ssh.err" | tr '\n' ' ')" > "${outDir}/status"
	else echo ran > "${outDir}/status"; fi
	exit 0
fi

testWhere=check-boxes; testCounter=nBad
declare -i nBad=0 nRan=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/corpus-cases.bash"

fBad(){ echo "check-boxes: $1" >&2; nBad+=1 ;}
case "${1:-}" in -h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${self}" | sed 's/^##	\{0,1\}//'; exit 0 ;; esac
(($# >= 1)) || { echo "usage: check-boxes.bash LINUX_BIN BOX|SSH_TARGET|BIN..." >&2; exit 2 ;}
linBin="$(realpath -- "$1")"; shift
[[ -f "${linBin}" ]] || { echo "check-boxes: no such file: ${linBin}" >&2; exit 2 ;}
for row in "$@"; do
	IFS='|' read -r box target bin <<< "${row}"
	[[ "${box}" =~ ^[A-Za-z0-9._-]+$ && -n "${target}" ]] || { echo "check-boxes: not BOX|SSH_TARGET|BIN: ${row}" >&2; exit 2 ;}
done

vmState="${SHCL_VM_STATE:-${HOME}/synced/0-0/common/exec/util/linux/bash/claude_vm-state.bash}"
[[ -x "${vmState}" ]] || vmState="$(command -v claude_vm-state.bash || true)"
boxWait="${SHCL_BOX_WAIT:-900}"
[[ "${boxWait}" =~ ^[0-9]+$ ]] || boxWait=900

startDir="${PWD}"
work="$(mktemp -d)"; trap 'rm -rf -- "${work}"' EXIT
cd "${work}"
mkdir -p g/c
for d in "${root}"/project/conformance/*/; do cp -r "${d%/}" g/c/; done
fCases > g/cases.tsv
nCases="$(wc -l < g/cases.tsv)"
fDriver > g/run.sh
cp -r g h
cp "${linBin}" h/shcl
( cd h && env -i PATH=/usr/bin:/bin HOME=/ sh run.sh > rc.lst 2> /dev/null ) || fBad "the host run of the CLI cases failed"

fTest Etfwju5 each test box runs its release build like the Linux one
for row in "$@"; do
	IFS='|' read -r box target bin <<< "${row}"
	[[ -z "${bin}" || "${bin}" == /* ]] || bin="${startDir}/${bin}"
	b="b_${box}"; mkdir -p "${b}/g" "${b}/back"
	if [[ ! -f "${bin}" ]]; then echo "SKIP ${box}: no release build for it"; continue; fi
	if [[ -z "${vmState}" ]]; then echo "SKIP ${box}: no claude_vm-state.bash, so no host lock"; continue; fi
	cp -r g/. "${b}/g/"; cp "${bin}" "${b}/g/shcl"
	tar -C "${b}/g" --format=pax -cf "${b}/in.tar" .
	SECONDS=0; wrapRc=0
	"${vmState}" wrap "${box}" --wait "${boxWait}" -- "${self}" --on-box "${target}" "${work}/${b}/in.tar" "${work}/${b}" < /dev/null > "${b}/wrap.out" 2>&1 || wrapRc=$?
	status="$(cat -- "${b}/status" 2>/dev/null || true)"
	case "${status}" in
		ran) ;;
		skip\ *) echo "SKIP ${box}: ${status#skip }"; continue ;;
		fail\ *) fBad "${box}: ${status#fail }"; continue ;;
		*) echo "SKIP ${box}: not taken or not up (wrap exited ${wrapRc}: $(tail -n 1 "${b}/wrap.out"))"; continue ;;
	esac
	((wrapRc == 0)) || echo "check-boxes: ${box}: wrap exited ${wrapRc} after the run: $(tail -n 1 "${b}/wrap.out")" >&2
	if ! tar -C "${b}/back" -xf "${b}/out.tar" 2>/dev/null; then fBad "${box}: nothing came back"; continue; fi
	nRan+=1
	nGot="$(grep -c ' rc ' "${b}/back/rc.lst" 2>/dev/null || true)"
	((nGot == nCases)) || fBad "${box}: ${nGot:-0} of ${nCases} CLI runs came back"
	diffIds="$( { diff h/rc.lst "${b}/back/rc.lst" | sed -n 's/^[<>] \([0-9]*\) rc .*/\1/p' || true
		diff -rq h/o "${b}/back/o" 2>/dev/null | grep -oE '[0-9]+\.[oe]( |$)' | sed 's/\.[oe] *$//'; } | sort -un || true)"
	nDiff=0; [[ -z "${diffIds}" ]] || nDiff="$(wc -l <<< "${diffIds}")"
	awk -F'\t' 'NR == FNR { bad[$1] = 1; next } ($1 in bad) && shown++ < 5 { $1 = "    differs: " $1; print }' OFS=' ' - g/cases.tsv <<< "${diffIds}" >&2
	if ((nDiff)); then fBad "${box}: ${nDiff} of ${nCases} CLI runs differ from the Linux build"
	else echo "PASS ${box}: ${nCases} CLI runs, same bytes and exit codes as the Linux build (${SECONDS} s)"; fi
done
if ((nRan == 0 && nBad == 0)); then fTestSkip; fi
fTestEnd

if ((nBad)); then
	echo "check-boxes: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-boxes: OK"

##	History:
##		2026-10-24  Created, for 2026102419263412.
