#!/usr/bin/env bash

#  shellcheck disable=2329  ## 'This function is never invoked.' fJob calls them by name.

##	Purpose:
##		Compile the C test programs, the C++ veneer smoke and the C CLI under the
##		address and undefined-behavior sanitizers, and run them over the corpus.
##		The optimized test line proves the output; this proves the memory behind
##		it. A read past a buffer, a NULL handed to a library call, or signed
##		overflow that happens not to change stdout passes every other gate and
##		fails here. The test programs run as they are; the CLI is driven the way
##		crosscheck.bash drives it, over every dimension the corpus has: fmt,
##		check, check --schema, tokens, migrate, the write-ops and bad-ops
##		scripts, the layered load, init --schema, every reads.tsv row as the CLI
##		call it names, and the in-place writes - fmt --write, migrate --write,
##		set --write, and a set --write that creates the file - on copies.
##		The veneer smoke runs once more under the thread sanitizer, since its
##		threads share one Document for reads.
##		LeakSanitizer reads lsan.supp beside this script, which may name
##		prebuilt libraries only, by library name. A leak in shcl's own code is
##		fixed, or the test that shows it turns detect_leaks off with a backlog
##		ID beside it. For a full leak stack, rerun the program with
##		ASAN_OPTIONS=fast_unwind_on_malloc=0.
##		--glibcxx-debug builds the veneer smoke alone, once more, with
##		libstdc++'s debug mode too, in a build dir of its own, since the mode
##		changes the ABI. It catches an iterator past its container's end, or
##		one a container's change made stale, which ASan and the assertions
##		mode let by. A bait that walks an iterator past the end has to stop
##		it. That one is for --leakcheck.
##	Syntax:
##		sanitize-c.bash [--glibcxx-debug] [CORPUS_DIR]
##		  CORPUS_DIR  conformance corpus root (default project/conformance)
##		CPU_CAP in the environment sets how many jobs run at once (default a
##		quarter of the cores).
##	Exit: 0 = clean, 1 = a program failed or a sanitizer reported, 2 = build failed.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=sanitize-c; testCounter=nJobBad
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/c-flags.bash"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
debugStl=0
if [[ "${1:-}" == --glibcxx-debug ]]; then debugStl=1; shift; fi
corpus="${1:-project/conformance}"
[[ -d "${corpus}" ]] || { echo "sanitize-c: no corpus dir: ${corpus}" >&2; exit 2; }

## The flags and the programs are in include/c-flags.bash. 77 is no exit code
## any of these programs uses, so a sanitizer stop cannot be mistaken for the
## program's own verdict. A leak exits 77 too.
export ASAN_OPTIONS="exitcode=77:${ASAN_OPTIONS:-}" UBSAN_OPTIONS="exitcode=77:print_stacktrace=1:${UBSAN_OPTIONS:-}"
export LSAN_OPTIONS="suppressions=${root}/cicd/utility/lsan.supp:${LSAN_OPTIONS:-}"

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
## compiler, language standard, source, output, then any extra flags.
fBuild(){
	local cc="$1" std="$2" src="$3" out="$4"; shift 4
	"${cc}" "-std=${std}" "${cSanFlags[@]}" "$@" "${src}" -o "${out}" -lm -lpthread || { echo "sanitize-c: build failed: ${src}"; return 1; }
}
## spec.md says threads can read one C++ Document at once, since each const
## member holds its lock; a member that skips it races in the smoke's threaded
## test (2026101612343301).
export TSAN_OPTIONS="exitcode=77:halt_on_error=1:${TSAN_OPTIONS:-}"
fBuildTsan(){ g++ -std=c++17 "${cTsanFlags[@]}" "$1" -o "$2" -lm -lpthread || { echo "sanitize-c: build failed: $1 under TSan"; return 1; }; }
## A suppression matches any frame in a leak's stack, so a wide one hides our
## own leaks. The bait leaks one block through a frame of its own, and has to
## be reported with the suppressions loaded. The pointer goes through a
## volatile global: a plain local is dropped by the optimizer, and one still
## in main's frame at exit is reachable, and either way LSan says nothing.
fLeakBait(){
	local rc=0
	"${work}/leakbait" >"${work}/leakbait.out" 2>&1 || rc=$?
	if [[ "${rc}" == 77 ]] && grep -q 'LeakSanitizer: detected memory leaks' "${work}/leakbait.out"; then return 0; fi
	echo "sanitize-c: LSan missed the bait's leak (exit ${rc})"; sed 's/^/    /' "${work}/leakbait.out"; return 1
}

## Everything below runs as background jobs, CPU_CAP at a time: six sanitized
## compiles were half the gate, and the corpus pass was most of the rest, one
## CLI run after another. A job leaves its output in N.log and its exit code in
## N.rc, so one that died before it could write the code is a failure too.
cap="${CPU_CAP:-}"
# shellcheck source-path=SCRIPTDIR
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || { source "$(dirname -- "${BASH_SOURCE[0]}")/include/cpu-cap.bash"; fCpuCap hard; cap="${CPU_CAP}"; }
((cap > 0)) || cap=1
declare -i nJobs=0 nLive=0
jobNames=()
fJob(){  ## fJob NAME COMMAND ARGS...
	if ((nLive >= cap)); then
		wait -n || true
		nLive=$((nLive - 1))
	fi
	nJobs+=1
	jobNames[nJobs]="$1"; shift
	{ jrc=0; "$@" >"${work}/${nJobs}.log" 2>&1 || jrc=$?; echo "${jrc}" >"${work}/${nJobs}.rc"; } &
	nLive=$((nLive + 1))
}
## Waits for all of them, then prints each log from job $1 on, in the order
## they started, and names the ones that failed in `failed` and `jobFailed`.
## The C runners print a status line per test of their own, which the runner
## stages already showed; here only this gate's lines are the tests. A runner's
## FAIL line stays, since a failure only the sanitizer sees has no other name.
declare -A jobFailed=()
fJobsWait(){
	local i jrc
	wait
	nLive=0
	failed=()
	for ((i = $1; i <= nJobs; i++)); do
		grep -vE '^(ok|skip) +[0-9A-Za-z-]{7} c(\+\+)? ' "${work}/${i}.log" || true
		jrc=""
		if [[ -f "${work}/${i}.rc" ]]; then read -r jrc <"${work}/${i}.rc"; fi
		if [[ -z "${jrc}" ]]; then failed+=("${jobNames[i]}: ended without a result"); jobFailed[${jobNames[i]}]=1
		elif [[ "${jrc}" != 0 ]]; then failed+=("${jobNames[i]}: exit ${jrc}"); jobFailed[${jobNames[i]}]=1; fi
	done
}

## --glibcxx-debug: the smoke and the bait, and nothing else.
if ((debugStl)); then
	dsDir="${work}/glibcxx-debug"; mkdir "${dsDir}"
	printf '%s\n' '#include <vector>' \
		'int main(int argc, char **) { std::vector<int> v(4, argc); auto it = v.begin() + 5; return it == v.end(); }' > "${dsDir}/bait.cpp"
	fDsBait(){
		local rc=0
		## The group's redirect takes the shell's own "Aborted" notice.
		{ "${dsDir}/bait" >"${dsDir}/bait.out" 2>&1 || rc=$?; } 2>/dev/null
		if ((rc > 128)) && grep -q 'Error: attempt to advance' "${dsDir}/bait.out"; then return 0; fi
		echo "sanitize-c: libstdc++'s debug mode let the bait's iterator past the end (exit ${rc})"; sed 's/^/    /' "${dsDir}/bait.out"; return 1
	}
	fJob "build veneer_smoke.cpp in debug mode" fBuild g++ c++17 source/c/tests/veneer_smoke.cpp "${dsDir}/veneer_smoke" "${cDebugStlFlags[@]}"
	fJob "build the debug-mode bait" fBuild g++ c++17 "${dsDir}/bait.cpp" "${dsDir}/bait" "${cDebugStlFlags[@]}"
	fJobsWait 1
	if ((${#failed[@]})); then printf 'sanitize-c: %s\n' "${failed[@]}" >&2; exit 2; fi
	firstRun=$((nJobs + 1))
	fJob "debug-mode bait" fDsBait
	fJob "veneer_smoke in debug mode" "${dsDir}/veneer_smoke"
	fJobsWait "${firstRun}"
	declare -i nJobBad=0
	fTest Et9t3Wv libstdc++ debug mode stops a planted iterator past the end
	if [[ -n "${jobFailed[debug-mode bait]:-}" ]]; then nJobBad+=1; fi
	fTest Et9t3ab veneer_smoke under libstdc++ debug mode, ASan and UBSan
	if [[ -n "${jobFailed[veneer_smoke in debug mode]:-}" ]]; then nJobBad+=1; fi
	fTestEnd
	if ((${#failed[@]})); then printf 'sanitize-c: %s\n' "${failed[@]}" >&2; exit 1; fi
	echo "sanitize-c: OK: veneer_smoke clean under libstdc++ debug mode, ASan and UBSan, the bait stopped"
	exit 0
fi

printf '%s\n' '#include <signal.h>' 'int main(void){ raise(SIGKILL); return 0; }' > "${work}/bait.c"
printf '%s\n' '#include <stdlib.h>' 'static void *volatile sink;' \
	'__attribute__((noinline)) static void drop(void) { sink = malloc(64); sink = NULL; }' \
	'int main(void) { drop(); return 0; }' > "${work}/leakbait.c"
for build in "${cSanBuilds[@]}"; do
	IFS='|' read -r bName bCc bStd bSrc bExtra <<<"${build}"
	read -r -a bExtraArgs <<<"${bExtra}"
	fJob "build ${bSrc##*/}" fBuild "${bCc}" "${bStd}" "${bSrc}" "${work}/${bName}" "${bExtraArgs[@]}"
done
fJob "build veneer_smoke.cpp under TSan" fBuildTsan source/c/tests/veneer_smoke.cpp "${work}/veneer_tsan"
fJob "build the bait" cc -O0 -o "${work}/bait" "${work}/bait.c"
fJob "build the leak bait" fBuild cc c11 "${work}/leakbait.c" "${work}/leakbait"
fJobsWait 1
if ((${#failed[@]})); then printf 'sanitize-c: %s\n' "${failed[@]}" >&2; exit 2; fi

## The CLI's own exit codes are the corpus contract, checked elsewhere; here only
## a sanitizer stop counts, with its report. Anything above 128 counts as well:
## the sanitizers exit 77 when they report, but an abort() or a fault they do not
## intercept kills the process instead, and a run that died that way used to be
## passed over as if the CLI had simply refused its arguments.
cliBin="${work}/shcl"
declare -i nRuns=0 nBad=0
fCli(){
	nRuns+=1
	"${cliBin}" "$@" >/dev/null 2>"${work}/stderr" || {
		local code=$?
		if ((code == 77 || code > 128)); then
			nBad+=1
			echo "sanitize-c: shcl $* (exit ${code})"
			sed 's/^/    /' "${work}/stderr"
		fi
	}
}
## Self-test for that, since the gate's own failure mode is silence: a CLI that
## aborted on every single input would have reported nothing but a clean count.
## SIGKILL rather than abort(), which is the realistic death here (ASan leaves
## 134), because it is the one signal that writes no core file. The group's
## redirect is for the shell's own "Killed" notice, which it prints after the
## wait and which would otherwise sit in the middle of a passing run.
{ cliBin="${work}/bait" fCli check /dev/null >/dev/null; } 2>/dev/null
((nBad == 1)) || { echo "sanitize-c: self-test: a CLI killed by a signal went uncounted" >&2; exit 2; }
nRuns=0; nBad=0
## One reads.tsv row as the CLI calls crosscheck.bash makes of it. Columns:
## query, type, expected, status, optional level; only the invocation matters
## here, so expected and status are not read.
##	Split a row on tabs, keeping empty fields. `IFS=$'\t' read` cannot: tab is
##	IFS whitespace whatever IFS is set to, so a leading or doubled tab
##	disappears and every column after it shifts - which silently turned the
##	top-level `children` row into a type nothing had an arm for.
fSplitTabs(){
	local rest="$1"
	cols=()
	while [[ "$rest" == *$'\t'* ]]; do cols+=("${rest%%$'\t'*}"); rest="${rest#*$'\t'}"; done
	cols+=("$rest")
}

fReadRow(){
	local input="$1" query="$2" type="$3" level="$4"
	local -a strictArg=()
	[[ -n "$level" ]] && strictArg=("--strictness=${level}")
	case "$type" in
		load)         fCli check "${strictArg[@]}" "$input"
		              fCli fmt "${strictArg[@]}" "$input" ;;
		count)        fCli count "${strictArg[@]}" "$input" "$query" ;;
		instances)    fCli instances "${strictArg[@]}" "$input" "$query"
		              fCli instances --paths "${strictArg[@]}" "$input" "$query"
		              fCli instances --json "${strictArg[@]}" "$input" "$query" ;;
		children)     fCli children "${strictArg[@]}" "$input" "$query"
		              fCli children --json "${strictArg[@]}" "$input" "$query" ;;
		paths)        fCli paths "${strictArg[@]}" "$input"
		              fCli paths --json "${strictArg[@]}" "$input" ;;
		lost)         : ;;   ## no CLI surface, like crosscheck.bash's own arm
		instance_paths|comments|schema) : ;; ## library only, the same
		int'[]'|float'[]'|bool'[]'|datetime'[]'|string'[]')
		              fCli get "--${type%[]}" --array "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type%[]}" --array --slots "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type%[]}" --array --json --slots "${strictArg[@]}" "$input" "$query" ;;
		int|float|bool|datetime|string|raw|rawinfo)
		              fCli get "--${type}" "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type}" --on-bad=error "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type}" "--default=<x>" "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type}" --json "${strictArg[@]}" "$input" "$query" ;;
		## duration[@UNIT] and size[@UNIT][+decimal], as crosscheck.bash reads them.
		duration*|size*)
		              local -a unitArg=()
		              local base="${type%%[@+]*}" rest="${type#"${type%%[@+]*}"}"
		              if [[ "$rest" == *+decimal ]]; then unitArg+=(--decimal); rest="${rest%+decimal}"; fi
		              if [[ "$rest" == @* ]]; then unitArg+=("--unit=${rest#@}"); fi
		              fCli get "--${base}" "${unitArg[@]}" "${strictArg[@]}" "$input" "$query"
		              fCli get "--${base}" "${unitArg[@]}" --on-bad=error "${strictArg[@]}" "$input" "$query"
		              fCli get "--${base}" "${unitArg[@]}" "--default=<x>" "${strictArg[@]}" "$input" "$query" ;;
		## A row type with no arm used to fall through to `get --<type>`, which
		## the CLI refuses at exit 1 - so the row ran nothing and the case still
		## counted as clean.
		*)            echo "sanitize-c: unknown reads.tsv type: ${type}" >&2; exit 2 ;;
	esac
}
##	Every CLI call one corpus case makes.
fCase(){
	local caseDir="$1"
	input="${caseDir}input.shcl"
	[[ -f "${input}" ]] || return 0
	fCli fmt "${input}"
	fCli paths --json "${input}"
	fCli check "${input}"
	if [[ -f "${caseDir}schema.shcl" ]]; then fCli check "--schema=${caseDir}schema.shcl" "${input}"; fi
	if [[ -f "${caseDir}write.ops" ]]; then fCli set "${input}" < "${caseDir}write.ops"; fi
	## Each bad op alone, as its own script.
	if [[ -f "${caseDir}write-bad.ops" ]]; then
		while IFS= read -r bline || [[ -n "$bline" ]]; do
			[[ -z "$bline" || "$bline" == \#* ]] && continue
			printf '%s\n' "$bline" > "${work}/badop.line"
			fCli set "${input}" < "${work}/badop.line"
		done < "${caseDir}write-bad.ops"
	fi
	## Layered load: layer*.shcl under the input (filename order = priority),
	## plus any merge.sets overrides.
	if [[ -f "${caseDir}expected-merged.shcl" ]]; then
		layerArgs=()
		## `continue` on the miss, not a trailing `&&`: an unmatched glob leaves
		## the pattern in $lf, the test fails, and a loop whose body ends on a
		## failed && list returns 1 - which kills the caller the day this loop
		## becomes the last thing in a function.
		for lf in "${caseDir}"layer*.shcl; do
			[[ -f "$lf" ]] || continue
			layerArgs+=("--layer=$lf")
		done
		setArgs=()
		if [[ -f "${caseDir}merge.sets" ]]; then
			while IFS= read -r sline || [[ -n "$sline" ]]; do
				[[ -z "$sline" || "$sline" == \#* ]] && continue
				setArgs+=("--set=$sline")
			done < "${caseDir}merge.sets"
		fi
		fCli fmt "${layerArgs[@]}" "${setArgs[@]}" "${input}"
	fi
	if [[ -f "${caseDir}init-schema.shcl" ]]; then
		fCli init "--schema=${caseDir}init-schema.shcl"
		fCli init --no-banner "--schema=${caseDir}init-schema.shcl"
	fi
	## The lexical spans, and a read under the 2.x rules. Both go through code no
	## other run here reaches.
	fCli tokens "${input}"
	fCli migrate "${input}"
	fCli migrate --check "${input}"
	## The write path: the temp file, the publish, the ops replay through it, and
	## the create. Every run above prints and touches nothing, so the whole file
	## tier was outside this gate. The copies are the gate's own.
	cp -- "${input}" "${work}/w.shcl"
	fCli fmt --write "${work}/w.shcl"
	cp -- "${input}" "${work}/w.shcl"
	## migrate --write refuses when the backup name is taken.
	rm -f "${work}"/w_backup_*
	fCli migrate --write --from-2x "${work}/w.shcl"
	if [[ -f "${caseDir}write.ops" ]]; then
		cp -- "${input}" "${work}/w.shcl"
		fCli set --write "${work}/w.shcl" < "${caseDir}write.ops"
		rm -f "${work}/new.shcl"
		fCli set --write "${work}/new.shcl" < "${caseDir}write.ops"
	fi
	if [[ -f "${caseDir}reads.tsv" ]]; then
		while IFS= read -r row || [[ -n "$row" ]]; do
			[[ -z "$row" || "$row" == query$'\t'* ]] && continue
			fSplitTabs "$row"
			query="${cols[0]}"; type="${cols[1]}"; level="${cols[4]:-}"
			fReadRow "${input}" "$query" "$type" "${level:-}"
		done < "${caseDir}reads.tsv"
	fi
}

##	One corpus pass, over every case whose index falls to worker $1. Its scratch
##	files are its own, and its counts go to a file, since it runs as a job.
fCliWorker(){
	local k="$1" i=0 caseDir
	local work="${work}/w${k}"
	mkdir "${work}"
	for caseDir in "${corpus}"/*/; do
		if ((i % cap == k)); then fCase "${caseDir}"; fi
		i=$((i + 1))
	done
	echo "${nRuns} ${nBad}" >"${work}/counts"
}

rc=0
firstRun=$((nJobs + 1))
fJob "conformance runner" "${work}/conformance" "${corpus}"
## The OOM hook there longjmps out of a write. Leak detection stays on, since
## what a cut-short call holds is given back, which the test's own block count
## checks as well.
fJob oom_hook "${work}/oom_hook"
## Its opposite: a parse or a validate that cannot allocate unwinds on its own
## and returns NULL, and leak detection stays ON, because giving back
## everything the half-built document held is half of what that is worth.
fJob oom_recover "${work}/oom_recover"
## The allocation bounds, under the same instrumentation.
fJob mem_bounds "${work}/mem_bounds"
## C++ owns the C handle, converts every value both ways, and frees a scratch
## document per tokenize, which is the kind of code a leak or double free hides in.
fJob veneer_smoke "${work}/veneer_smoke"
fJob veneer_tsan "${work}/veneer_tsan"
fJob "leak bait" fLeakBait
for ((k = 0; k < cap; k++)); do fJob "CLI pass ${k}" fCliWorker "${k}"; done
fJobsWait "${firstRun}"
if ((${#failed[@]})); then printf 'sanitize-c: %s\n' "${failed[@]}" >&2; rc=1; fi
declare -i wRuns wBad
for ((k = 0; k < cap; k++)); do
	if [[ -f "${work}/w${k}/counts" ]]; then
		read -r wRuns wBad <"${work}/w${k}/counts"
		nRuns=$((nRuns + wRuns)); nBad=$((nBad + wBad))
	fi
done
declare -i nJobBad=0 cliBad=0
for ((k = 0; k < cap; k++)); do
	if [[ -n "${jobFailed[CLI pass ${k}]:-}" ]]; then cliBad+=1; fi
done
fTest EoLqLse the corpus runner under ASan and UBSan
if [[ -n "${jobFailed[conformance runner]:-}" ]]; then nJobBad+=1; fi
fTest EoLqLsf oom_hook under ASan and UBSan
if [[ -n "${jobFailed[oom_hook]:-}" ]]; then nJobBad+=1; fi
fTest EoaFuVO oom_recover under ASan and UBSan
if [[ -n "${jobFailed[oom_recover]:-}" ]]; then nJobBad+=1; fi
fTest EoezJiF mem_bounds under ASan and UBSan
if [[ -n "${jobFailed[mem_bounds]:-}" ]]; then nJobBad+=1; fi
fTest EoSE8Nl veneer_smoke under ASan and UBSan
if [[ -n "${jobFailed[veneer_smoke]:-}" ]]; then nJobBad+=1; fi
fTest EstYPCw veneer_smoke under TSan
if [[ -n "${jobFailed[veneer_tsan]:-}" ]]; then nJobBad+=1; fi
fTest Et09atr LSan reports a planted leak with the suppressions loaded
if [[ -n "${jobFailed[leak bait]:-}" ]]; then nJobBad+=1; fi
fTest EoSE8Nm every corpus CLI run under ASan and UBSan
nJobBad=$((nJobBad + cliBad + nBad))
fTestEnd
if ((nBad)); then
	echo "sanitize-c: ${nBad}/${nRuns} CLI run(s) stopped by a sanitizer" >&2; rc=1
elif ((rc == 0)); then
	echo "sanitize-c: OK: runner, oom_hook, oom_recover, mem_bounds, veneer_smoke and ${nRuns} CLI run(s) clean under ASan+UBSan+LSan, veneer_smoke under TSan, the leak bait caught"
fi
exit "${rc}"


##	History:
##		- 2026-08-29 JC: Created. The first sanitized run found a NULL fwrite the
##		  optimized gate had been passing.
##		- 2026-08-30 JC: The CLI now covers reads.tsv, init --schema, the layered
##		  load and the bad-ops scripts, and the C++ veneer smoke runs too.
##		- 2026-09-17 JC: tokens, migrate and the four write paths added. The file
##		  tier had never run under the sanitizers.
##		- 2026-09-19 JC: A CLI run killed by a signal counts, not just a sanitizer
##		  stop at 77, and a bait that aborts proves the counting still works.
##		- 2026-09-22 JC: The builds, the test programs and the corpus pass run as
##		  jobs, CPU_CAP at a time. 91 s to 23 s at 16.
##		- 2026-10-16 JC: The veneer smoke under TSan as well, for its threaded
##		  reads of one Document.
##		- 2026-10-17 JC: Flags and programs from include/c-flags.bash, LSan
##		  suppressions file and a leak it has to catch, the arena's malloc
##		  mode and libstdc++ assertions, and oom_hook with leak detection on.
##		- 2026-10-19 JC: --glibcxx-debug, the veneer smoke in libstdc++'s debug mode.
