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
##	Syntax:
##		sanitize-c.bash [CORPUS_DIR]
##		  CORPUS_DIR  conformance corpus root (default project/conformance)
##		CPU_CAP in the environment sets how many jobs run at once (default half
##		the cores).
##	Exit: 0 = clean, 1 = a program failed or a sanitizer reported, 2 = build failed.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
corpus="${1:-project/conformance}"
[[ -d "${corpus}" ]] || { echo "sanitize-c: no corpus dir: ${corpus}" >&2; exit 2; }

## -O1 keeps line numbers honest in a report; -fno-sanitize-recover makes every
## UBSan finding fatal instead of a note that scrolls past. 77 is no exit code
## any of these programs uses, so a sanitizer stop cannot be mistaken for the
## program's own verdict.
flags=(-O1 -g "-fsanitize=address,undefined" -fno-sanitize-recover=all -fno-omit-frame-pointer -Wall -Wextra -Werror -Isource/c)
export ASAN_OPTIONS="exitcode=77:${ASAN_OPTIONS:-}" UBSAN_OPTIONS="exitcode=77:print_stacktrace=1:${UBSAN_OPTIONS:-}"

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
## compiler, language standard, source, output.
fBuild(){ "$1" "-std=$2" "${flags[@]}" "$3" -o "$4" -lm -lpthread || { echo "sanitize-c: build failed: $3"; return 1; }; }

## Everything below runs as background jobs, CPU_CAP at a time: six sanitized
## compiles were half the gate, and the corpus pass was most of the rest, one
## CLI run after another. A job leaves its output in N.log and its exit code in
## N.rc, so one that died before it could write the code is a failure too.
cap="${CPU_CAP:-}"
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || cap=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
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
## they started, and names the ones that failed in `failed`.
fJobsWait(){
	local i jrc
	wait
	nLive=0
	failed=()
	for ((i = $1; i <= nJobs; i++)); do
		cat "${work}/${i}.log"
		jrc=""
		if [[ -f "${work}/${i}.rc" ]]; then read -r jrc <"${work}/${i}.rc"; fi
		if [[ -z "${jrc}" ]]; then failed+=("${jobNames[i]}: ended without a result")
		elif [[ "${jrc}" != 0 ]]; then failed+=("${jobNames[i]}: exit ${jrc}"); fi
	done
}

printf '%s\n' '#include <signal.h>' 'int main(void){ raise(SIGKILL); return 0; }' > "${work}/bait.c"
fJob "build conformance.c" fBuild cc c11 source/c/tests/conformance.c "${work}/conformance"
fJob "build oom_hook.c" fBuild cc c11 source/c/tests/oom_hook.c "${work}/oom_hook"
fJob "build oom_recover.c" fBuild cc c11 source/c/tests/oom_recover.c "${work}/oom_recover"
fJob "build mem_bounds.c" fBuild cc c11 source/c/tests/mem_bounds.c "${work}/mem_bounds"
fJob "build veneer_smoke.cpp" fBuild g++ c++17 source/c/tests/veneer_smoke.cpp "${work}/veneer_smoke"
fJob "build the CLI" fBuild cc c11 source/c/cmd/shcl/main.c "${work}/shcl"
fJob "build the bait" cc -O0 -o "${work}/bait" "${work}/bait.c"
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
		instances)    fCli instances "${strictArg[@]}" "$input" "$query" ;;
		children)     fCli children "${strictArg[@]}" "$input" "$query" ;;
		paths)        fCli paths "${strictArg[@]}" "$input" ;;
		lost)         : ;;   ## no CLI surface, like crosscheck.bash's own arm
		instance_paths|comments) : ;; ## library only, the same
		int'[]'|float'[]'|bool'[]'|datetime'[]'|string'[]')
		              fCli get "--${type%[]}" --array "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type%[]}" --array --slots "${strictArg[@]}" "$input" "$query" ;;
		int|float|bool|datetime|string|raw|rawinfo)
		              fCli get "--${type}" "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type}" --on-bad=error "${strictArg[@]}" "$input" "$query"
		              fCli get "--${type}" "--default=<x>" "${strictArg[@]}" "$input" "$query" ;;
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
## The OOM hook there longjmps out of a write, so every budget that trips it
## abandons a partly applied edit on purpose; that is the test, not a leak.
fJob oom_hook env "ASAN_OPTIONS=${ASAN_OPTIONS}:detect_leaks=0" "${work}/oom_hook"
## Its opposite: a parse or a validate that cannot allocate unwinds on its own
## and returns NULL, and leak detection stays ON, because giving back
## everything the half-built document held is half of what that is worth.
fJob oom_recover "${work}/oom_recover"
## The allocation bounds, under the same instrumentation.
fJob mem_bounds "${work}/mem_bounds"
## C++ owns the C handle, converts every value both ways, and frees a scratch
## document per tokenize, which is the kind of code a leak or double free hides in.
fJob veneer_smoke "${work}/veneer_smoke"
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
if ((nBad)); then
	echo "sanitize-c: ${nBad}/${nRuns} CLI run(s) stopped by a sanitizer" >&2; rc=1
elif ((rc == 0)); then
	echo "sanitize-c: OK: runner, oom_hook, oom_recover, mem_bounds, veneer_smoke and ${nRuns} CLI run(s) clean under ASan+UBSan"
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
