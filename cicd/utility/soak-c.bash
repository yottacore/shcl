#!/usr/bin/env bash

##	Purpose:
##		The C soak under heaptrack, for --leakcheck. source/c/tests/soak.c loops
##		load, read, set, save, merge and validate over the corpus and fails when
##		glibc's count of the heap in use at round 2N is past round N by more
##		than its margin. It's a plain build, since heaptrack and ASan can't
##		share one. heaptrack's data and its printed report go in
##		cicd/artifacts/soak/, beside the soak's own table, for a look at what
##		grew. A bait build that keeps one document growing for the whole run
##		has to fail first, so a soak gone blind can't pass.
##		heaptrack is the version TOOL_PINS names and runs in the build image.
##		On a box without it this starts that image and runs in it, building it
##		first if it isn't here.
##	Syntax:
##		soak-c.bash
##	Exit: 0 = clean, 1 = the heap grew or the bait went unseen, 2 = could not run.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"
cd "${root}"
# shellcheck source-path=SCRIPTDIR
source "${here}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${here}/include/stop-descendants.bash"
testWhere=soak-c; testCounter=nBad; nBad=0

if (($#)); then echo "soak-c: takes no arguments (see the header)" >&2; exit 2; fi

art="${root}/cicd/artifacts/soak"
work="$(mktemp -d)"; trap 'fStopDescendants; rm -rf "${work}"' EXIT

skipping=0
missing=()
for t in heaptrack heaptrack_print cc; do
	if ! command -v "${t}" >/dev/null 2>&1; then missing+=("${t}"); fi
done
if ((${#missing[@]})); then
	if [[ -n "${SHCL_IN_IMAGE:-}" ]]; then echo "soak-c: the build image has no ${missing[*]}" >&2; exit 2; fi
	# shellcheck source-path=SCRIPTDIR
	source "${here}/include/ctr-image.bash"
	whyNot="$(fCtrWhyNot)"
	if [[ -z "${whyNot}" ]]; then
		## The cap the run in the image takes.
		CPU_CAP="${CPU_CAP:-1}"
		# shellcheck source-path=SCRIPTDIR
		# shellcheck source=../config.bash
		source "${root}/cicd/config.bash"
		# shellcheck source-path=SCRIPTDIR
		source "${here}/include/ctr-image.bash"
		rc=0; fCtrRunSelf "${work}" "${art}" "${root}/cicd/utility/soak-c.bash" || rc=$?
		exit "${rc}"
	fi
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then echo "soak-c: no ${missing[*]}, and no build image, since ${whyNot}; the gate requires them" >&2; nBad=1
	else echo "soak-c: skipping, no ${missing[*]}, and no build image, since ${whyNot}" >&2; echo soak-c >> "${SHCL_GATE_SKIPS:-/dev/null}"; fi
	skipping=1
fi

## -O1 and frame pointers, so heaptrack's stacks name the calls.
soakFlags=(-std=c11 -O1 -g -fno-omit-frame-pointer -Wall -Wextra -Werror -Isource/c)
start="${SECONDS}"
baitOk=0; soakOk=0; reportOk=0
if ((! skipping)); then
	mkdir -p "${art}" "${work}/saves"
	cc "${soakFlags[@]}" source/c/tests/soak.c -o "${work}/soak" -lm || { echo "soak-c: build failed" >&2; exit 2; }
	cc "${soakFlags[@]}" -DSHCL_SOAK_BAIT source/c/tests/soak.c -o "${work}/bait" -lm || { echo "soak-c: the bait's build failed" >&2; exit 2; }

	brc=0; "${work}/bait" project/conformance "${work}/saves" >"${work}/bait.out" 2>&1 || brc=$?
	if [[ "${brc}" == 1 ]] && grep -q 'FAIL soak: the heap grew' "${work}/bait.out"; then baitOk=1
	else echo "soak-c: the soak missed the bait's growing document (exit ${brc})"; sed 's/^/    /' "${work}/bait.out"; fi

	rm -f "${art}"/c-heaptrack.* "${art}/c-soak.txt"
	src=0
	SHCL_SOAK_REPORT="${art}/c-soak.txt" heaptrack -o "${art}/c-heaptrack" "${work}/soak" project/conformance "${work}/saves" >"${work}/soak.out" 2>&1 || src=$?
	## The soak's own status line, and its failure if it has one.
	grep -E '^(ok|FAIL|skip) +[0-9A-Za-z]{7} c |^FAIL soak' "${work}/soak.out" || true
	if [[ "${src}" == 0 ]]; then soakOk=1
	else echo "soak-c: the soak under heaptrack exited ${src}"; sed 's/^/    /' "${work}/soak.out"; fi

	data=("${art}"/c-heaptrack.*)
	if [[ -f "${data[0]}" ]] && heaptrack_print "${data[0]}" >"${art}/c-heaptrack.txt" 2>"${work}/print.err" \
		&& grep -q '^peak heap memory consumption:' "${art}/c-heaptrack.txt" && grep -q '^total memory leaked:' "${art}/c-heaptrack.txt"; then
		reportOk=1
	else
		echo "soak-c: heaptrack left no report it could read"; sed 's/^/    /' "${work}/print.err" 2>/dev/null || true
	fi
fi

fJudge(){
	if ((skipping)); then fTestSkip; return 0; fi
	if (($1 == 0)); then nBad=$((nBad + 1)); fi
}
fTest Et9t3ED the C soak fails on a document that grows every round
fJudge "${baitOk}"
fTest Et9t3I4 heaptrack writes a report of the C soak
fJudge "${reportOk}"
fTestEnd
## The soak's own line is soak.c's, Et9t3AU, so only its exit counts here.
if ((nBad)) || ((! skipping && ! soakOk)); then exit 1; fi
if ((! skipping)); then
	echo "soak-c: OK: the heap held steady over the corpus rounds, the bait was caught, and heaptrack's report is in cicd/artifacts/soak/ ($((SECONDS - start)) s)"
fi
exit 0


##	History:
##		- 2026-10-19 JC: Created.
##		- 2026-10-19 JC: The build image only when docker answers.
