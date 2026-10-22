#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' config.bash's arrays, of which only TOOL_PINS and the CTR_ settings are read here.
#  shellcheck disable=2329  ## 'This function is never invoked.' fJob calls them by name.

##	Purpose:
##		Static analysis of the C and C++ code:
##		- gcc's -fanalyzer over the C CLI and every C test program. It spends
##		  its budget deep in the parse, so it reaches little of shcl.h past
##		  that: a leak and a null dereference planted in library calls, and in
##		  main.c's own code a few calls down from main, went unseen with gcc
##		  14 and 15. At its default depth main.c ran out of 14 GB.
##		- the clang static analyzer over the same files, which saw both.
##		- clang-tidy's clang-analyzer-* and bugprone-* checks over the C++
##		  veneer smoke, from the compile database gen-compdb.bash writes, with
##		  shcl.hpp and shcl.h in the header filter.
##		With --ctu, the clang analyzer in its cross-file mode instead. Every
##		program here is one translation unit with the whole library in it, so
##		this splits each one the way a program using the header is built: its
##		own code in one file, and in the other the library, compiled with
##		whatever the program defines before the include. The analyzer follows
##		each call into the library across that line. The programs that reach
##		into the library's own types and static functions can't be split, and
##		are listed. That's the C CLI, the corpus runner, mem_bounds and the C++
##		veneer smoke, so no C++ is left for this. A bait only the cross-file
##		mode sees proves it reaches.
##		Any finding fails. A false one is suppressed at its line with the reason
##		beside it: SHCL_VOLATILE_OWNER_BEGIN/END or SHCL_ANALYZER_SKIP in C, and
##		NOLINT(check) for clang-tidy. Each tool first has to report a planted
##		leak and null dereference, so one gone blind can't pass as clean:
##		-fsyntax-only turns -fanalyzer off, -O1 folds a leak away before it
##		looks, and gcc prints a finding as error: under -Werror.
##		The tools are the majors TOOL_PINS names, and they run in the build
##		image. On a box without them this starts that image and runs in it,
##		building it first if it isn't here. The hosted gate installs them.
##	Syntax:
##		analyze-c.bash [--ctu]
##		CPU_CAP in the environment caps the jobs (default half the cores).
##	Exit: 0 = clean, 1 = a finding, or a tool that missed its bait,
##	      2 = could not run.
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
testWhere=analyze-c; testCounter=nBad; nBad=0

ctu=0
for arg in "$@"; do
	case "${arg}" in
		--ctu) ctu=1 ;;
		*) echo "analyze-c: unknown option: ${arg} (see the header)" >&2; exit 2 ;;
	esac
done

cap="${CPU_CAP:-}"
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || cap=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
((cap > 0)) || cap=1
## config.bash expands the cap while it loads.
CPU_CAP="${cap}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../config.bash
source "${root}/cicd/config.bash"

## The binary for a tool at the major TOOL_PINS gives it, as NAME-MAJOR, or
## as BIN-MAJOR when the package is named for more than one binary.
fPinned(){  ## fPinned PIN [BIN]
	local pin rest
	for pin in "${TOOL_PINS[@]}"; do
		if [[ "${pin%%|*}" == "$1" ]]; then rest="${pin#*|}"; echo "${2:-$1}-${rest%%|*}"; return 0; fi
	done
	echo "analyze-c: TOOL_PINS has no $1" >&2; return 1
}
gccBin="$(fPinned gcc)" || exit 2
clangBin="$(fPinned clang)" || exit 2
tidyBin="$(fPinned clang-tidy)" || exit 2
extdefBin="$(fPinned clang-tools clang-extdef-mapping)" || exit 2

work="$(mktemp -d)"; trap 'fStopDescendants; rm -rf "${work}"' EXIT

## The build image, with this script run inside it, read only but for the
## scratch dir.
fInImage(){
	local rc=0
	# shellcheck source-path=SCRIPTDIR
	source "${here}/include/ctr-image.bash"
	fCtrRunSelf "${work}" "" "${root}/cicd/utility/analyze-c.bash" "$@" || rc=$?
	exit "${rc}"
}

skipping=0
missing=()
needed=("${clangBin}" "${tidyBin}" "${gccBin}")
if ((ctu)); then needed=("${clangBin}" "${extdefBin}"); fi
for t in "${needed[@]}"; do
	if ! command -v "${t}" >/dev/null 2>&1; then missing+=("${t}"); fi
done
## clang-tidy takes the C++ headers of the newest gcc it finds, and finds
## none where that gcc has no g++.
if ((! ctu)) && command -v "${clangBin}" >/dev/null 2>&1 && ! printf '#include <vector>\n' | "${clangBin}" -x c++ -std=c++17 -fsyntax-only - >/dev/null 2>&1; then
	missing+=("C++ headers for ${clangBin}")
fi
if ((${#missing[@]})); then
	if [[ -n "${SHCL_IN_IMAGE:-}" ]]; then echo "analyze-c: the build image has no ${missing[*]}" >&2; exit 2; fi
	# shellcheck source-path=SCRIPTDIR
	source "${here}/include/ctr-image.bash"
	whyNot="$(fCtrWhyNot)"
	if [[ -z "${whyNot}" ]]; then fInImage "$@"; fi
	## No tools and no way to the image: a skip here, a failure under the gate.
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then echo "analyze-c: no ${missing[*]}, and no build image, since ${whyNot}; the gate requires them" >&2; nBad=1
	else echo "analyze-c: skipping, no ${missing[*]}, and no build image, since ${whyNot}" >&2; echo analyze-c >> "${SHCL_GATE_SKIPS:-/dev/null}"; fi
	skipping=1
fi

## The C programs. No sanitizers, which add branches of their own, and -O0,
## since -O1 drops a malloc nothing reads before the analyzer sees the leak.
cFiles=(source/c/cmd/shcl/main.c source/c/tests/*.c)
cAnaFlags=(-std=c11 -O0 -g -Wall -Wextra -Werror -Isource/c)
## The default depth took 2 to 6.5 minutes a file at -O1, and ran out of
## memory at -O0. At 1 it missed a two-path leak, and 2 is the least that
## reports the bait.
gccDepth=(--param=analyzer-bb-explosion-factor=2)
tidyChecks='-*,clang-analyzer-*,bugprone-*'
## A header finding is reported only when its path matches this. It is
## anchored at the end, so the bait's copy under the scratch dir matches too.
tidyHeaders='source/c/shcl\.(h|hpp)$'
## --ctu: the programs that use the library's own types and static
## functions, so its code can't go in a file of its own.
ctuWhole=(source/c/cmd/shcl/main.c source/c/tests/conformance.c source/c/tests/mem_bounds.c)

## Jobs in the background, CAP at a time, each with its log and exit code in
## the scratch dir. GROUP is the test a job counts toward.
declare -i nLive=0
declare -A jobFailed=()
jobGroups=(); jobLabels=()
fJob(){  ## fJob GROUP LABEL COMMAND ARGS...
	if ((nLive >= cap)); then
		wait -n || true
		nLive=$((nLive - 1))
	fi
	local id="${#jobGroups[@]}"
	jobGroups+=("$1"); jobLabels+=("$2"); shift 2
	{ jrc=0; "$@" >"${work}/${id}.log" 2>&1 || jrc=$?; echo "${jrc}" >"${work}/${id}.rc"; } &
	nLive=$((nLive + 1))
}
## A clean job says nothing. A failed one prints its log, and one that died
## before it could write its code counts as failed.
fJobsWait(){
	local id jrc
	wait
	nLive=0
	for id in "${!jobGroups[@]}"; do
		jrc=""
		if [[ -f "${work}/${id}.rc" ]]; then read -r jrc <"${work}/${id}.rc"; fi
		if [[ "${jrc}" != 0 ]]; then
			jobFailed[${jobGroups[id]}]=1
			echo "analyze-c: ${jobLabels[id]}: exit ${jrc:-none}"
			sed 's/^/    /' "${work}/${id}.log"
		fi
	done
}

fGcc(){ "${gccBin}" "${cAnaFlags[@]}" -fanalyzer "$@" -c -o /dev/null; }
## One lane: its files one after another, and all of them run.
fGccLane(){
	local f rc=0
	for f in "$@"; do
		if ! fGcc "${gccDepth[@]}" "${f}"; then echo "analyze-c: gcc -fanalyzer: findings in ${f}"; rc=1; fi
	done
	return "${rc}"
}
## clang only takes a function defined in a header as a starting point when
## told to. The header is the same in every file, so main.c, which uses the
## library's own allocator, is the one run that does.
fClang(){
	local -a hdr=()
	if [[ "$1" == */main.c ]]; then hdr=(-Xclang -analyzer-opt-analyze-headers); fi
	"${clangBin}" --analyze --analyzer-output text -ferror-limit=0 "${cAnaFlags[@]}" -Xclang -analyzer-werror "${hdr[@]}" "$1" -o /dev/null
}
fTidy(){
	"${here}/gen-compdb.bash" "${work}/cdb"
	"${tidyBin}" --quiet -p "${work}/cdb" "--checks=${tidyChecks}" "--header-filter=${tidyHeaders}" "--warnings-as-errors=*" source/c/tests/veneer_smoke.cpp
}

## fCtuRun DIR LIB USE FLAGS...: USE under the analyzer's cross-file mode,
## with LIB's AST as the file the calls go to. The index only takes what LIB
## itself defines, not its headers. The static functions a program defines
## before the include are in both files, and each file uses only its own, so
## an unused one isn't a finding. The analyzer has to say it loaded the AST,
## or nothing crossed. The default gives a call into the other file a fraction
## of the budget a call in the same file gets; all gives it the same.
fCtuRun(){
	local dir="$1" lib="$2" use="$3" a
	local -a flags=("${@:4}" -Wno-unused-function) args=()
	mkdir -p "${dir}/ast"
	"${clangBin}" "${flags[@]}" -emit-ast "${lib}" -o "${dir}/ast/lib.ast" || { echo "analyze-c: ${lib##*/}: no AST"; return 1; }
	for a in "${clangBin}" "${flags[@]}" -c "${lib}"; do args+=("\"${a}\""); done
	printf '[{"directory": "%s", "file": "%s", "arguments": [%s]}]\n' "${root}" "${lib}" "$(IFS=,; echo "${args[*]}")" >"${dir}/compile_commands.json"
	"${extdefBin}" -p "${dir}" "${lib}" >"${dir}/defs.txt" || { echo "analyze-c: ${lib##*/}: no index"; return 1; }
	sed -E 's# /[^ ]+$# lib.ast#' "${dir}/defs.txt" >"${dir}/ast/externalDefMap.txt"
	if [[ ! -s "${dir}/ast/externalDefMap.txt" ]]; then echo "analyze-c: ${lib##*/}: the index is empty"; return 1; fi
	local rc=0
	"${clangBin}" --analyze --analyzer-output text -ferror-limit=0 "${flags[@]}" -Xclang -analyzer-werror \
		-Xclang -analyzer-config -Xclang experimental-enable-naive-ctu-analysis=true \
		-Xclang -analyzer-config -Xclang "ctu-dir=${dir}/ast" \
		-Xclang -analyzer-config -Xclang ctu-phase1-inlining=all \
		-Xclang -analyzer-config -Xclang display-ctu-progress=true \
		"${use}" -o /dev/null >"${dir}/out.txt" 2>&1 || rc=$?
	grep -v '^CTU loaded AST file' "${dir}/out.txt" || true
	if ! grep -q '^CTU loaded AST file' "${dir}/out.txt"; then echo "analyze-c: ${use##*/}: nothing loaded from the library's file"; return 1; fi
	return "${rc}"
}
## fCtuSplit SRC: SRC as its own code and the library's, then fCtuRun. The
## library half is SRC up to the include, then shcl.h's text in place of the
## include, since only the file itself counts. #line keeps the reports on the
## real files and lines.
fCtuSplit(){
	local src="$1" dir="${work}/ctu/${1##*/}" n
	mkdir -p "${dir}"
	n="$(grep -n -m1 -Fx '#include "shcl.h"' "${src}" | cut -d: -f1 || true)"
	if [[ -z "${n}" ]] || [[ "$(grep -c '^#define SHCL_IMPLEMENTATION$' "${src}")" != 1 ]]; then
		echo "analyze-c: ${src}: no one #define SHCL_IMPLEMENTATION and #include \"shcl.h\" to split it at"; return 1
	fi
	{ printf '#line 1 "%s"\n' "${src}"; head -n "$((n - 1))" "${src}"; printf '#line 1 "source/c/shcl.h"\n'; cat source/c/shcl.h; } >"${dir}/lib.c"
	{ printf '#line 1 "%s"\n' "${src}"; sed 's/^#define SHCL_IMPLEMENTATION$//' "${src}"; } >"${dir}/use.c"
	fCtuRun "${dir}" "${dir}/lib.c" "${dir}/use.c" "${cAnaFlags[@]}"
}

## The bait: a leak and a null dereference each, which every tool has to fail
## on and name. clang-tidy's sit in a header named like ours, so the header
## filter is proven too, with a use after move for bugprone-*.
mkdir -p "${work}/bait/source/c"
printf '%s\n' '#include <stdlib.h>' \
	'int bait_leak(int n);' \
	'int bait_leak(int n) { int *p = (int *)malloc(4 * sizeof *p); if (!p) return 0; p[0] = n; return p[0]; }' \
	'int bait_null(int n);' \
	'int bait_null(int n) { int *p = NULL; if (n > 0) p = &n; return *p; }' > "${work}/bait/bait.c"
printf '%s\n' '#include <utility>' '#include <vector>' \
	'inline int bait_null(int n) { int *p = nullptr; if (n > 1) p = &n; return *p; }' \
	'inline int bait_leak(int n) { int *p = new int(n); return *p; }' \
	'inline std::size_t bait_moved(std::vector<int> v) { std::vector<int> w = std::move(v); return v.size() + w.size(); }' > "${work}/bait/source/c/shcl.hpp"
printf '%s\n' '#include "source/c/shcl.hpp"' \
	'int main(int argc, char **) { return bait_null(argc) + bait_leak(argc) + static_cast<int>(bait_moved({1})); }' > "${work}/bait/bait.cpp"
## fBait TOOL LOG PATTERN... COMMAND...: the command fails, and its output
## matches every pattern. The patterns end at a lone --.
fBait(){
	local tool="$1" log="${work}/bait-$1.out" rc=0 pat ok=1
	local -a pats=()
	shift
	while [[ "$1" != -- ]]; do pats+=("$1"); shift; done
	shift
	"$@" >"${log}" 2>&1 || rc=$?
	if [[ "${rc}" == 0 ]]; then ok=0; fi
	for pat in "${pats[@]}"; do
		if ! grep -qE -- "${pat}" "${log}"; then ok=0; echo "analyze-c: ${tool} said nothing matching ${pat}"; fi
	done
	if ((ok)); then return 0; fi
	echo "analyze-c: ${tool} missed its bait (exit ${rc})"; sed 's/^/    /' "${log}"; return 1
}

## --ctu's bait: a leak and a null dereference that only show once a call
## is followed into the other file. The per-file pass has to miss both, or
## they prove nothing about the mode.
mkdir -p "${work}/ctubait"
printf '%s\n' '#include <stdlib.h>' \
	'int *bait_make(int n);' 'int *bait_make(int n) { int *p = (int *)malloc(4 * sizeof *p); if (!p) return 0; p[0] = n; return p; }' \
	'int bait_get(const int *p);' 'int bait_get(const int *p) { return *p; }' >"${work}/ctubait/lib.c"
printf '%s\n' '#include <stddef.h>' 'int *bait_make(int n);' 'int bait_get(const int *p);' \
	'int use_leak(int n);' 'int use_leak(int n) { int *p = bait_make(n); return p ? p[0] : 0; }' \
	'int use_null(int n);' 'int use_null(int n) { const int *q = NULL; if (n > 1) q = &n; return bait_get(q); }' >"${work}/ctubait/use.c"
fCtuBait(){
	if ! "${clangBin}" --analyze --analyzer-output text "${cAnaFlags[@]}" -Xclang -analyzer-werror "${work}/ctubait/use.c" -o /dev/null; then
		echo "analyze-c: the per-file pass saw the bait, which then proves nothing about the cross-file one"; return 1
	fi
	fBait ctu '\[unix\.Malloc\]' '\[core\.NullDereference\]' -- fCtuRun "${work}/ctubait/run" "${work}/ctubait/lib.c" "${work}/ctubait/use.c" "${cAnaFlags[@]}"
}

start="${SECONDS}"
if ((! skipping && ctu)); then
	fJob "ctu bait" "cross-file bait" fCtuBait
	ctuFiles=()
	for f in "${cFiles[@]}"; do
		whole=0
		for w in "${ctuWhole[@]}"; do
			if [[ "${f}" == "${w}" ]]; then whole=1; fi
		done
		if ((! whole)); then ctuFiles+=("${f}"); fi
	done
	for f in "${ctuFiles[@]}"; do fJob ctu "cross-file clang analyzer ${f##*/}" fCtuSplit "${f}"; done
	fJobsWait
elif ((! skipping)); then
	fJob "gcc bait" "gcc -fanalyzer bait" fBait gcc '\[-Werror=analyzer-malloc-leak\]' '\[-Werror=analyzer-null-dereference\]' -- \
		fGcc "${gccDepth[@]}" "${work}/bait/bait.c"
	fJob "clang bait" "clang analyzer bait" fBait clang '\[unix\.Malloc\]' '\[core\.NullDereference\]' -- \
		fClang "${work}/bait/bait.c"
	fJob "tidy bait" "clang-tidy bait" fBait clang-tidy \
		'shcl\.hpp:[0-9]+:[0-9]+: error: .*\[clang-analyzer-core\.NullDereference,-warnings-as-errors\]' \
		'\[clang-analyzer-cplusplus\.NewDeleteLeaks,-warnings-as-errors\]' \
		'\[bugprone-use-after-move,-warnings-as-errors\]' -- \
		"${tidyBin}" --quiet "--checks=${tidyChecks}" "--header-filter=${tidyHeaders}" "--warnings-as-errors=*" "${work}/bait/bait.cpp" -- -std=c++17 "-I${work}/bait"
	## gcc's analyzer takes 3 to 8 GB a file, so it gets two lanes whatever
	## the cap: four at once would want about 21 GB. Each file goes to the
	## lane with less work, the biggest first, weighed with the header,
	## which is most of what each one costs.
	hdrSize="$(wc -c <source/c/shcl.h)"
	laneFiles=("" ""); laneLoad=(0 0)
	while read -r size f; do
		k=0
		if ((laneLoad[1] < laneLoad[0])); then k=1; fi
		laneFiles[k]+="${f} "; laneLoad[k]=$((laneLoad[k] + size + hdrSize))
	done < <(for f in "${cFiles[@]}"; do printf '%s %s\n' "$(wc -c <"${f}")" "${f}"; done | sort -rn)
	for k in 0 1; do
		read -r -a lane <<<"${laneFiles[k]}"
		if ((${#lane[@]})); then fJob gcc "gcc -fanalyzer lane $((k + 1))" fGccLane "${lane[@]}"; fi
	done
	for f in "${cFiles[@]}"; do fJob clang "clang analyzer ${f##*/}" fClang "${f}"; done
	fJob tidy "clang-tidy veneer_smoke.cpp" fTidy
	fJobsWait
fi

## One verdict per test.
fJudge(){
	if ((skipping)); then fTestSkip; return 0; fi
	if [[ -n "${jobFailed[$1]:-}" ]]; then nBad=$((nBad + 1)); fi
}
if ((ctu)); then
	fTest Et9t3Ll the cross-file clang analyzer reports a planted leak and null dereference only it sees
	fJudge "ctu bait"
	fTest Et9t3PQ the cross-file clang analyzer over the C test programs that split
	fJudge ctu
	fTestEnd
	if ((nBad)); then exit 1; fi
	if ((! skipping)); then
		echo "analyze-c: OK: ${#ctuFiles[@]} C file(s) clean under the cross-file clang analyzer, ${#ctuWhole[@]} left whole, the bait caught ($((SECONDS - start)) s)"
	fi
	exit 0
fi
fTest Et09ats gcc -fanalyzer reports a planted leak and null dereference
fJudge "gcc bait"
fTest Et09att the clang analyzer reports a planted leak and null dereference
fJudge "clang bait"
fTest Et09atu clang-tidy reports planted bugs in a header the filter names
fJudge "tidy bait"
fTest Et09atv gcc -fanalyzer over the C CLI and the C test programs
fJudge gcc
fTest Et09atw the clang analyzer over the C CLI and the C test programs
fJudge clang
fTest Et09atx clang-tidy over the C++ veneer smoke
fJudge tidy
fTestEnd
if ((nBad)); then exit 1; fi
if ((! skipping)); then
	echo "analyze-c: OK: ${#cFiles[@]} C file(s) clean under gcc -fanalyzer and clang --analyze, the veneer smoke under clang-tidy, every tool caught its bait ($((SECONDS - start)) s)"
fi
exit 0


##	History:
##		- 2026-10-17 JC: Created.
##		- 2026-10-18 JC: The 3 bugprone checks that were off gate again, with each
##		  site suppressed at its line or filed.
##		- 2026-10-19 JC: --ctu, the cross-file clang analyzer, for --leakcheck.
##		- 2026-10-19 JC: The build image only when docker answers.
