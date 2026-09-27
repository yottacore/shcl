#!/usr/bin/env bash

##	Purpose:
##		Build the C surface with every C compiler on this box, not just the
##		default one. The hosted runner's gcc is not this box's gcc, and the two
##		disagree about what -Wall -Wextra -Werror rejects: a round once went out
##		green here and red there, because gcc 13 saw a maybe-uninitialized the
##		local gcc 14 and 15 both missed. Cheap enough to run every time.
##	Syntax:
##		check-c-compilers.bash [ROOT]
##	Exit: 0 = every compiler present is happy, 1 = one refused, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=check-c-compilers; testCounter=nKindBad

repoDir="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -d "${repoDir}" ]] || { echo "check-c-compilers: no such directory: ${repoDir}" >&2; exit 2 ;}

tmpDir="$(mktemp -d)"; trap 'rm -rf "${tmpDir}"' EXIT
declare -i nBad=0 nRun=0

## Whatever is installed: the named versions plus the two default front ends.
compilers=()
for c in gcc-12 gcc-13 gcc-14 gcc-15 gcc-16 gcc clang; do
	command -v "${c}" >/dev/null 2>&1 && compilers+=("${c}")
done
((${#compilers[@]})) || { echo "check-c-compilers: no C compiler found" >&2; exit 2 ;}

## Under the gate a thin sweep is a failure, not a pass: the disagreement this
## exists for (gcc 12 and 13 against 14 and 15 over -Wclobbered) cannot show
## with one compiler, and a runner that lost one would otherwise report OK for
## good. Locally, what is installed is what is checked, and the summary says
## which. A thin sweep is noted in SHCL_GATE_SKIPS, so the run is not taken for
## a full gate.
declare -i nGcc=0
for c in "${compilers[@]}"; do
	if [[ "${c}" == gcc-* ]]; then nGcc+=1; fi
done
if ((nGcc < 2)) || [[ " ${compilers[*]} " != *" clang "* ]]; then
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		echo "check-c-compilers: the gate needs two versioned gccs and clang; found: ${compilers[*]}" >&2
		exit 1
	fi
	echo check-c-compilers >> "${SHCL_GATE_SKIPS:-/dev/null}"
fi

## Plain gcc is usually one of the versioned ones, and building it twice cost a
## sixth of the sweep. The first name for each binary is the one kept.
mapfile -t found < <(type -P "${compilers[@]}")
mapfile -t real < <(readlink -f -- "${found[@]}")
declare -A seen=()
kept=() same=()
for i in "${!compilers[@]}"; do
	if [[ -n "${seen[${real[i]}]:-}" ]]; then
		same+=("${compilers[i]} is ${seen[${real[i]}]}")
		continue
	fi
	seen[${real[i]}]="${compilers[i]}"
	kept+=("${compilers[i]}")
done
compilers=("${kept[@]}")

## Each build runs as a background job and says how it went in files named by
## its number, since a job cannot touch the parent's counters. The binary is
## named by the job's own pid, so no two builds write one file.
fBuild(){  ## fBuild CC OPT SRC [FLAG...]
	local cc="$1" opt="$2" src="$3" out
	shift 3
	if ! out="$("${cc}" -std=c11 "${opt}" "$@" -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -I"${repoDir}/source/c" \
		"${repoDir}/${src}" -o "${tmpDir}/out.${BASHPID}" -lm -lpthread 2>&1)"; then
		echo "check-c-compilers: ${cc} ${opt} ${*:+$* }refuses ${src}:" >&2
		## Not a pipe: head quits after 8 lines, and under pipefail the writer's
		## SIGPIPE on a long cascade ended the whole sweep.
		head -n 8 <<< "${out}" >&2
		return 1
	fi
	rm -f "${tmpDir}/out.${BASHPID}"
}

fRefuse(){  ## fRefuse CC SRC WANT - a build that must fail, and fail saying WANT
	local cc="$1" src="$2" want="$3" out
	if out="$("${cc}" -std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -I"${repoDir}/source/c" \
		"${src}" -o "${tmpDir}/out.${BASHPID}" -lm -lpthread 2>&1)"; then
		echo "check-c-compilers: ${cc} accepted ${src##*/}, which must not compile" >&2
		return 1
	elif ! grep -qF -- "${want}" <<< "${out}"; then
		## Refused for some other reason, so it proves nothing about the guard.
		echo "check-c-compilers: ${cc} refused ${src##*/} without saying \"${want}\":" >&2
		head -n 8 <<< "${out}" >&2
		return 1
	fi
}

## A job counts as passed only if it wrote its ok file, so one that dies
## without a word is a failure rather than a silent pass.
cap="${CPU_CAP:-}"
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || cap=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
((cap > 0)) || cap=1
## Each job belongs to a kind, which is one test: the same build on every
## compiler, and at every level where it is swept.
declare -i nLive=0
kind=""; jobKind=()
fJob(){  ## fJob FUNC ARGS... - run one check in the background, cap at a time
	if ((nLive >= cap)); then
		wait -n || true
		nLive=$((nLive - 1))
	fi
	nRun+=1
	jobKind[nRun]="${kind}"
	printf '%s ' "${@:2}" > "${tmpDir}/${nRun}.what"
	{ "$@" 2> "${tmpDir}/${nRun}.err" && : > "${tmpDir}/${nRun}.ok"; } &
	nLive=$((nLive + 1))
}

## The header sets the POSIX feature level, and glibc only honors that before
## the first system header. Its sentinel says so; without it the symptom is
## pages of implicit-declaration errors that never mention include order. The
## three builds above are the other half: they include the header first and
## must stay clean, so a guard that fired unconditionally would show up there.
cat > "${tmpDir}/order-bad.c" <<'EOF'
#include <stdio.h>
#define SHCL_IMPLEMENTATION
#include "shcl.h"
int main(void){ return 0; }
EOF

## Same flags the build and test stages use, so a disagreement here is a
## disagreement there.
for cc in "${compilers[@]}"; do
	for src in source/c/cmd/shcl/main.c source/c/tests/conformance.c source/c/tests/mem_bounds.c; do
		kind="${src##*/}"
		fJob fBuild "${cc}" -O2 "${src}"
	done
	## Most Linux consumers define _GNU_SOURCE, and glibc declares more under it,
	## so a static name in the header can collide with one of those functions.
	kind=gnu; fJob fBuild "${cc}" -O2 source/c/cmd/shcl/main.c -D_GNU_SOURCE
	## Distributions build with _FORTIFY_SOURCE on, and glibc then marks calls
	## such as fchown warn_unused_result, which a (void) cast does not silence.
	## That reached dev once and only the hosted runner said so, where the flag
	## is on by default and here it is not.
	kind=fortify; fJob fBuild "${cc}" -O2 source/c/cmd/shcl/main.c -D_FORTIFY_SOURCE=2
	kind=order; fJob fRefuse "${cc}" "${tmpDir}/order-bad.c" "included before any system header"
	## The two OOM tests get every level. Their shape is the one this gate was
	## written for - which locals a compiler thinks a setjmp's unwind can
	## clobber, and whether it gives the frame a pointer and saved xmm registers
	## at all - and gcc decides both per level, so -O2 alone proves one of five.
	## win-runners.bash sweeps the same five on windows for the same reason.
	for src in source/c/tests/oom_hook.c source/c/tests/oom_recover.c; do
		kind="${src##*/}"
		for opt in -O0 -O1 -O2 -Os -O3; do
			fJob fBuild "${cc}" "${opt}" "${src}"
		done
	done
done

wait
declare -A kindBad=()
for ((i = 1; i <= nRun; i++)); do
	if [[ ! -e "${tmpDir}/${i}.ok" ]]; then
		kindBad[${jobKind[i]}]=$(( ${kindBad[${jobKind[i]}]:-0} + 1 ))
		if [[ -s "${tmpDir}/${i}.err" ]]; then
			cat "${tmpDir}/${i}.err" >&2
		else
			echo "check-c-compilers: $(< "${tmpDir}/${i}.what")ended without a result" >&2
		fi
		nBad+=1
	fi
done
declare -i nKindBad=0
fTest EoXhawq main.c builds on every compiler
nKindBad+=${kindBad[main.c]:-0}
fTest EoXhawr conformance.c builds on every compiler
nKindBad+=${kindBad[conformance.c]:-0}
fTest EoezJiE mem_bounds.c builds on every compiler
nKindBad+=${kindBad[mem_bounds.c]:-0}
fTest Eptzmsi main.c builds with _GNU_SOURCE
nKindBad+=${kindBad[gnu]:-0}
fTest EqNHTSi main.c builds with _FORTIFY_SOURCE
nKindBad+=${kindBad[fortify]:-0}
fTest EqAMPEG the header after a system header is refused by name
nKindBad+=${kindBad[order]:-0}
fTest EoaFuVM oom_hook.c builds at every optimization level
nKindBad+=${kindBad[oom_hook.c]:-0}
fTest EoaFuVN oom_recover.c builds at every optimization level
nKindBad+=${kindBad[oom_recover.c]:-0}
fTestEnd

if ((nBad)); then
	echo "check-c-compilers: ${nBad} of ${nRun} build(s) failed" >&2
	exit 1
fi
echo "check-c-compilers: OK: ${nRun} build(s) across ${#compilers[@]} compiler(s) (${compilers[*]}${same[*]:+; ${same[*]}})"

##	History:
##		2026-08-31  Created, after gcc 13 on the hosted runner rejected what the
##		            local gcc 14 accepted.
##		2026-08-31  The two OOM tests, for -Wclobbered around the setjmp.
##		2026-09-05  A floor on the compiler set under SHCL_GATE_STRICT.
##		2026-09-08  The two OOM tests build at every optimization level, since
##		            the shape they exist for is one gcc decides per level.
##		2026-09-14  A build with _GNU_SOURCE defined. A long error cascade no
##		            longer ends the sweep.
##		2026-09-17  A build that must be refused: the header included after a
##		            system header, which has to name include order.
##		2026-09-21  Builds run in parallel, up to CPU_CAP at a time, and a name
##		            that resolves to a compiler already listed is built once.
