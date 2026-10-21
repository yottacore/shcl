#!/usr/bin/env bash

##	Purpose:
##		The windows-x86_64 release links mingw-w64's runtime and zig's mingw and
##		compiler-rt, which no other tested build has. This runs it under wine
##		over the same CLI cases the CPU floor check uses, and it has to give the
##		same stdout, stderr and exit code as the Linux release built from the
##		same source (2026101921290754). The cases run in parallel under one
##		wineserver, since a wine start costs about 0.15 s.
##	Syntax:
##		check-win-release.bash LINUX_BIN WIN_BIN
##		  LINUX_BIN   the native release build, run here for the answers
##		  WIN_BIN     the windows-x86_64 release build
##		  CPU_CAP     parallel runs (default half the cores)
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
testWhere=check-win-release; testCounter=nBad
declare -i nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/corpus-cases.bash"

fBad(){ echo "check-win-release: $1" >&2; nBad+=1 ;}
case "${1:-}" in -h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed 's/^##	\{0,1\}//'; exit 0 ;; esac
(($# == 2)) || { echo "usage: check-win-release.bash LINUX_BIN WIN_BIN" >&2; exit 2 ;}
linBin="$(realpath -- "$1")"; winBin="$(realpath -- "$2")"
for f in "${linBin}" "${winBin}"; do [[ -f "${f}" ]] || { echo "check-win-release: no such file: ${f}" >&2; exit 2 ;}; done
jobs="${CPU_CAP:-$(( $(nproc) / 2 ))}"; ((jobs >= 1)) || jobs=1

##	fRunAll TAG CMD... -> TAG/N.o, TAG/N.e and TAG/N.rc for each case
fRunAll(){
	local tag="$1" j; shift
	mkdir -p "${tag}"
	for ((j = 0; j < jobs; j++)); do
		awk -v j="${j}" -v m="${jobs}" 'NR % m == j' cases.tsv | while IFS=$'\t' read -r n rest; do
			IFS=$'\t' read -ra a <<< "${rest}"
			rc=0; timeout 60 "$@" "${a[@]}" > "${tag}/${n}.o" 2> "${tag}/${n}.e" < /dev/null || rc=$?
			echo "${rc}" > "${tag}/${n}.rc"
		done &
	done
	wait
}

missing=""
for t in wine wineserver wineboot timeout; do command -v "${t}" >/dev/null 2>&1 || missing+=" ${t}"; done
if [[ -z "${missing}" ]]; then
	work="$(mktemp -d)"
	##	With no /run/user/UID, as in the image, wine 10 falls back to a server dir
	##	under TMPDIR and aborts with "free(): invalid pointer" when TMPDIR is set.
	unset TMPDIR
	##	A prefix of its own, no display so nothing opens a window, and no mono or
	##	gecko install prompts.
	export WINEPREFIX="${work}/wp" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
	unset DISPLAY WAYLAND_DISPLAY
	trap 'wineserver -k >/dev/null 2>&1 || true; rm -rf "${work}"' EXIT
	cd "${work}"
	mkdir c && for d in "${root}"/project/conformance/*/; do cp -r "${d%/}" c/; done
	cp "${winBin}" shcl.exe
	fCases > cases.tsv
	nCases="$(wc -l < cases.tsv)"

	fTest EtIZEst wine starts the windows-x86_64 release
	##	The server first: -p fails once wineboot has started one of its own.
	mkdir -p "${WINEPREFIX}"
	wineserver -p 120 || fBad "wineserver exited $?"
	wineboot -i > wineboot.out 2>&1 || fBad "wineboot exited $? ($(tail -n 2 wineboot.out | tr '\n' ' '))"
	want="$("${linBin}" --version 2>&1 || true)"
	got="$(timeout 60 wine ./shcl.exe --version 2>&1 | tr -d '\r' || true)"
	[[ -n "${want}" && "${got}" == "${want}" ]] || fBad "wine ./shcl.exe --version gave ${got@Q}, the Linux build ${want@Q}"

	fTest EtIZEvy the windows-x86_64 release runs the CLI cases like the Linux one
	SECONDS=0
	fRunAll lin "${linBin}"
	fRunAll win wine ./shcl.exe
	##	The OS words its own errors, "File not found." on windows, so only the
	##	code in `(os error N)` is compared.
	find lin win -name '*.e' -size +0 -exec sed -i -E 's/: [^:]+ \(os error ([0-9]+)\)/: (os error \1)/' {} +
	nDiff=0; nGot=0; shown=0
	while IFS=$'\t' read -r n rest; do
		[[ -f "win/${n}.rc" ]] && nGot=$((nGot + 1))
		for x in o e rc; do
			if ! cmp -s "lin/${n}.${x}" "win/${n}.${x}"; then
				nDiff=$((nDiff + 1))
				if ((shown < 5)); then shown=$((shown + 1)); echo "    differs: ${n} ${rest//$'\t'/ }" >&2; fi
				break
			fi
		done
	done < cases.tsv
	((nGot == nCases)) || fBad "${nGot} of ${nCases} CLI runs came back under wine"
	if ((nDiff)); then fBad "${nDiff} of ${nCases} CLI runs differ from the Linux build"
	else echo "check-win-release: ${nCases} CLI runs under wine, same bytes and exit codes as the Linux build (${SECONDS} s, ${jobs} at a time)"; fi
else
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then fBad "needs${missing}, and the gate requires it"; fi
	echo "check-win-release: skipping (no ${missing# })"
	echo check-win-release >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkipBlock
fi
fTestEnd

if ((nBad)); then
	echo "check-win-release: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-win-release: OK"

##	History:
##		2026-10-20  Created, for 2026101921290754.
