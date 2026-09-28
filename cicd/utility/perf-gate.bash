#!/usr/bin/env bash

##	Purpose:
##		Fail when the read, write or malformed-input path stops being linear.
##		Two rounds running, a fix that was correct made bulk writes 4.5x slower
##		and absent-path defaults 140x slower, and both reached dev because
##		nothing had a number to fail on. A third round found a plain text file
##		parsing in quadratic time, and a fourth the did-you-mean suggestion
##		quadratic in name length. Each workload is timed against the same
##		binding's parse-only baseline on the same machine, so the gate carries
##		no wall-clock constant and does not care how fast the runner is:
##		applying the ops, refusing every line, or suggesting a name for every
##		unknown field, must stay small beside reading a well-formed document
##		of the same size. A per-op index rebuild, a scan of every sibling, a
##		rewalk of the retained lines, or a full edit-distance table per name
##		pair breaks that ratio by more than an order of magnitude.
##	Syntax:
##		perf-gate.bash [--keys N] [--factor F] NAME|CLI [NAME|CLI ...]
##		  --keys N    flat keys in the generated document (default 40000)
##		  --factor F  allowed multiple of the baseline (default 3)
##	Exit: 0 = every workload within budget, 1 = over budget, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

## Read by the include: one status line per test, with its test ID.
# shellcheck disable=SC2034
testWhere="perf-gate" testCounter="nBad"
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/include/test-id.bash"

declare -i keys=40000 factor=3 nBad=0
bindings=()
while (($#)); do case "$1" in
	--keys)    keys="${2:-40000}"; shift 2 ;;
	--factor)  factor="${2:-3}"; shift 2 ;;
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         bindings+=("$1"); shift ;;
esac; done
((${#bindings[@]})) || { echo "perf-gate: no bindings given" >&2; exit 2; }
for b in "${bindings[@]}"; do
	cli="${b#*|}"
	[[ -x "${cli}" ]] || { echo "perf-gate: binding CLI not executable: ${cli}" >&2; exit 2; }
done

tmpDir="$(mktemp -d)"; trap 'rm -rf "${tmpDir}"' EXIT
doc="${tmpDir}/doc.shcl"
awk -v n="${keys}" 'BEGIN{ for (i = 0; i < n; i++) printf "k%d: %d\n", i, i }' > "${doc}"
: > "${tmpDir}/base.ops"
## Every existing key rewritten: the writer's own path, nothing else.
awk -v n="${keys}" 'BEGIN{ for (i = 0; i < n; i++) printf "int\tk%d\t%d\n", i, i + 1 }' > "${tmpDir}/writes.ops"
## The save that keeps lines, on a file that is not canonical, so it lines the
## edited text up against the source: two parses and several passes over the
## text, which is why it gets half the keys. Every key is rewritten.
keepDoc="${tmpDir}/keep.shcl"
awk -v n="$((keys / 2))" 'BEGIN{ for (i = 0; i < n; i++) printf "k%d:  %d\n", i, i }' > "${keepDoc}"
awk -v n="$((keys / 2))" 'BEGIN{ for (i = 0; i < n; i++) printf "int\tk%d\t%d\n", i, i + 1 }' > "${tmpDir}/keeps.ops"
## Paths that do not resolve: the set-if-absent half, which is where the
## whole-index rebuild hid.
awk 'BEGIN{ for (i = 0; i < 1000; i++) printf "int-default\tnew%d\t%d\n", i, i }' > "${tmpDir}/defaults.ops"
## Every existing key looked up and left alone. set-if-absent on a path that
## already resolves is a path read and nothing else, which is the only way to
## drive one lookup per key through a single process. Without an index that
## outlives the parse this is a sibling scan per key, so it goes quadratic.
awk -v n="${keys}" 'BEGIN{ for (i = 0; i < n; i++) printf "int-default\tk%d\t0\n", i }' > "${tmpDir}/reads.ops"
## The same line count with no colon on any line. Every line is refused and
## retained as trivia, and the retained list must not be rewalked per line.
badDoc="${tmpDir}/bad.shcl"
awk -v n="${keys}" 'BEGIN{ for (i = 0; i < n; i++) print "no colon here" }' > "${badDoc}"
## Unknown fields with long names against a schema of long names, all one
## length so the length prefilter rejects nothing: every pair must cost time
## linear in the length, not the full table. 30 x 30 pairs at 800 characters
## is 2 s to 90 s across the bindings with a full table and well under their
## baselines with a banded one.
sugSchema="${tmpDir}/sug-schema.shcl"; sugDoc="${tmpDir}/sug.shcl"
awk 'BEGIN{ pad = sprintf("%794s", ""); gsub(/ /, "x", pad); for (i = 0; i < 30; i++) printf "field: s%05d%s\n", i, pad }' > "${sugSchema}"
awk 'BEGIN{ pad = sprintf("%794s", ""); gsub(/ /, "x", pad); for (i = 0; i < 30; i++) printf "u%05d%s: 1\n", i, pad }' > "${sugDoc}"
## A fragment that mounts itself by two paths, against a document nesting
## sixty levels deep with one unknown field at the bottom. The unknown-field
## sweep has to decide that chain by descending the mounts, and a matcher that
## walks both mounts at every level is 2^60 there; one that remembers a
## (fragment, depth) it has already failed is linear. The same document with
## no unknown field never enters the matcher, so that shape proves nothing.
recSchema="${tmpDir}/rec-schema.shcl"; recDoc="${tmpDir}/rec.shcl"
printf 'fragment: f\n\tfield: child\n\t\tinherits: f\n\tfield: child.child\n\t\tinherits: f\nfield: root\n\tinherits: f\n' > "${recSchema}"
awk 'BEGIN{ print "root:"; for (i = 1; i <= 60; i++) { for (j = 0; j < i; j++) printf "\t"; print "child:" }
	for (j = 0; j <= 60; j++) printf "\t"; print "unknown: 1" }' > "${recDoc}"
## Sixteen thousand fragments none of the document uses, against one line that
## fails one declared constraint. Nothing here is about the document: the whole
## cost is building the schema, where a duplicate check that scans every
## fragment already recorded is quadratic in the count and a per-mount lookup
## pays the scan again.
fragSchema="${tmpDir}/frag-schema.shcl"; fragDoc="${tmpDir}/frag.shcl"
awk 'BEGIN{ print "field: a"; print "\ttype: int"
	for (i = 0; i < 16000; i++) printf "fragment: f%d\n\tfield: x%d\n\t\ttype: int\n", i, i }' > "${fragSchema}"
printf 'a: x\n' > "${fragDoc}"
## The unknown-field sweep's two element-wise matchers, one workload each. Both
## used to scan their whole list per document node, so the cost was the document
## times the schema. `stars` is the star-bearing paths, which cannot live in the
## exact-chain hash; `mounts` is the general matcher, reached once a fragment is
## mounted anywhere. Two things the shape depends on: the document names sit at
## the END of the schema's list, because a name near the front ends the scan
## early and hides most of it, and each instance is one dotted line, because the
## block spelling costs three times the parse for the same chains. The trailing
## unknown field is what makes `check` exit 6.
starSchema="${tmpDir}/star-schema.shcl"; starDoc="${tmpDir}/star.shcl"
awk 'BEGIN{ for (i = 0; i < 16000; i++) printf "field: s%d.*.leaf\n", i }' > "${starSchema}"
awk 'BEGIN{ for (i = 12000; i < 16000; i++) printf "s%d.inst.leaf: 1\n", i; print "zz: 1" }' > "${starDoc}"
mountSchema="${tmpDir}/mount-schema.shcl"; mountDoc="${tmpDir}/mount.shcl"
awk 'BEGIN{ print "fragment: f"; print "\tfield: leaf"
	for (i = 0; i < 16000; i++) printf "field: m%d\n\tinherits: f\n", i }' > "${mountSchema}"
awk 'BEGIN{ for (i = 12000; i < 16000; i++) printf "m%d.leaf: 1\n", i; print "zz: 1" }' > "${mountDoc}"
## A quoted `[value]` selector per line, each naming a new instance. On a miss
## the parser scanned every same-name sibling before the keyed create lookup
## answered the same question, so the quoted spelling was quadratic in siblings
## where the bare one and the block form were not (20260918b item 9). Half the
## key count keeps the old code's run under two minutes in the slowest binding.
selDoc="${tmpDir}/sel.shcl"
awk -v n="$((keys / 2))" 'BEGIN{ for (i = 0; i < n; i++) printf "srv[\"host %d\"].port: %d\n", i, i }' > "${selDoc}"
## Every document name unknown and none close to a schema name, the case the
## did-you-mean exists for. Each unknown field was compared with every sibling,
## and the list held one copy per schema field, so the section's 4000 fields
## put 4000 copies of `sec` beside the 4000 top-level names (20260918b item 10).
## The names are pseudo-random letters, all eight long, since a length filter
## alone must not be enough to pass; a Park-Miller step keeps them the same on
## every awk.
unkSchema="${tmpDir}/unk-schema.shcl"; unkDoc="${tmpDir}/unk.shcl"
awk 'function nm(   s, k) { s = ""; for (k = 0; k < 8; k++) { x = (x * 16807) % 2147483647; s = s sprintf("%c", 97 + x % 26) } return s }
	BEGIN { x = 1; for (i = 0; i < 4000; i++) printf "field: %s\nfield: sec.%s\n", nm(), nm() }' > "${unkSchema}"
awk 'function nm(   s, k) { s = ""; for (k = 0; k < 8; k++) { x = (x * 16807) % 2147483647; s = s sprintf("%c", 97 + x % 26) } return s }
	BEGIN { x = 7; for (i = 0; i < 4000; i++) printf "%s: 1\n", nm() }' > "${unkDoc}"

## Every child of one parent taken out by a single `*` path. Each target was
## dropped on its own, rebuilding the parent's whole child list once per target,
## so the cost was the target count times the sibling count and both of those
## are the document. The second group is what survives, so the run has something
## to print. Half again the key count: C's budget is the baseline-plus-250 floor
## rather than the 3x, and at the plain key count the old code cleared it by only
## 40 percent, which a faster machine would erase. At half again it is 3x over.
rmDoc="${tmpDir}/rm.shcl"
awk -v n="$((keys + keys / 2))" 'BEGIN{ print "grp:"; for (i = 0; i < n; i++) printf "\tf%d: %d\n", i, i
	print "keep:"; for (j = 0; j < 4; j++) printf "\tz%d: 1\n", j }' > "${rmDoc}"
printf 'remove\tgrp.*\n' > "${tmpDir}/removes.ops"

## Raw blocks side by side under one parent. Each raw node rescanned the whole
## run to learn whether an empty sibling of its name sat above it, the one case
## where its fence has to leave the binding line, so formatting was quadratic
## in raw siblings (20260725 item 27). No other shape here puts more than one
## raw block under a parent. Half the key count keeps the lines at twice the
## baseline's, which the linear walk formats well under the parse.
rawDoc="${tmpDir}/raws.shcl"
awk -v n="$((keys / 2))" 'BEGIN{ print "p:"; for (i = 0; i < n; i++) printf "\tr%d:\n\t\t~~~\n\t\tline %d\n\t\t~~~\n", i, i }' > "${rawDoc}"

## Two flat documents of the same names, so every name in the higher layer
## overrides a leaf below. Collecting the replaced leaf's comments scanned every
## base child once per overridden name, which is quadratic when the two files
## name the same keys (20260918b item 58). Half the key count keeps the old
## code's run inside the timeout in the slowest binding.
mergeBase="${tmpDir}/merge-base.shcl"; mergeOver="${tmpDir}/merge-over.shcl"
awk -v n="$((keys / 2))" 'BEGIN{ for (i = 0; i < n; i++) printf "k%d: %d\n", i, i }' > "${mergeBase}"
awk -v n="$((keys / 2))" 'BEGIN{ for (i = 0; i < n; i++) printf "k%d: %d\n", i, i + 1 }' > "${mergeOver}"

##	A run that never comes back is a failure, not a wait. Without this a binding
##	that stopped terminating hung the gate until whatever was running it gave up,
##	and on hosted CI that is the job's own timeout with no workload named. The cap
##	is deliberately far above any budget: a merely slow run still finishes, prints
##	its number and fails on the number, which is the more useful report. Only a
##	hang reaches this. The self-test below lowers it to a second.
declare -i runSecs=300
fRun(){ timeout -k 5 "${runSecs}" "$@"; }

##	Milliseconds for one run of $2 (an ops file, a document when $3 is
##	"check", or a document validated against ${sugSchema} when $3 is
##	"suggest") through CLI $1, best of two so a scheduling hiccup does not
##	fail the gate.
##	The exit code and the size of what came out are checked too: the timer used
##	to discard both, so a CLI that printed a usage error and exited 1 was inside
##	every budget and the gate reported OK. A run that did not do the work is a
##	failure, not a fast one.
fTimeMs(){
	local cli="$1" input="$2" mode="${3:-set}" want="${4:-1}" best=0 ms start end rc lines
	for _ in 1 2; do
		start="$(date +%s%N)"
		rc=0
		if [[ "${mode}" == check ]]; then
			fRun "${cli}" check "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == suggest ]]; then
			fRun "${cli}" check --schema "${sugSchema}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == recurse ]]; then
			fRun "${cli}" check --schema "${recSchema}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == frags ]]; then
			fRun "${cli}" check --schema "${fragSchema}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == stars ]]; then
			fRun "${cli}" check --schema "${starSchema}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == mounts ]]; then
			fRun "${cli}" check --schema "${mountSchema}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == selectors ]]; then
			fRun "${cli}" check "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == unknowns ]]; then
			fRun "${cli}" check --schema "${unkSchema}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == merge ]]; then
			fRun "${cli}" fmt --layer "${mergeBase}" "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == raws ]]; then
			fRun "${cli}" fmt "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == removes ]]; then
			fRun "${cli}" set "${input}" < "${tmpDir}/removes.ops" > "${tmpDir}/out" 2>/dev/null || rc=$?
		elif [[ "${mode}" == keeps ]]; then
			fRun "${cli}" set "${input}" < "${tmpDir}/keeps.ops" > "${tmpDir}/out" 2>/dev/null || rc=$?
		else
			fRun "${cli}" set "${doc}" < "${input}" > "${tmpDir}/out" 2>/dev/null || rc=$?
		fi
		end="$(date +%s%N)"
		##	124 is timeout's own TERM, 137 the KILL five seconds behind it.
		if ((rc == 124 || rc == 137)); then
			echo "perf-gate: ${cli##*/}: ${mode} run was still going after ${runSecs} s" >&2
			printf '%s' -1; return
		fi
		##	`check` on a document with diagnostics exits 6; everything else here
		##	succeeds. Anything else means the run did no work.
		local wantRc=0
		case "${mode}" in check|suggest|recurse|frags|stars|mounts|unknowns) wantRc=6 ;; esac
		if ((rc != wantRc)); then
			echo "perf-gate: ${cli##*/}: ${mode} run exited ${rc}, expected ${wantRc} - it did not do the work" >&2
			printf '%s' -1; return
		fi
		lines="$(wc -l < "${tmpDir}/out")"
		if ((lines < want)); then
			echo "perf-gate: ${cli##*/}: ${mode} run printed ${lines} line(s), expected at least ${want}" >&2
			printf '%s' -1; return
		fi
		ms=$(( (end - start) / 1000000 ))
		if ((best == 0 || ms < best)); then best="${ms}"; fi
	done
	printf '%s' "${best}"
}

##	The three checks inside fTimeMs are the gate's own guards: a run that exits
##	wrong, one that prints too little, and one that never comes back are all
##	failures rather than fast times. The first two went in after a CLI that
##	printed a usage error and exited 1 sat inside every budget and the gate
##	reported OK. Three bait CLIs keep them honest, so the next tidy-up cannot
##	delete a check without this saying so.
##	stderr is dropped: the message they print is the point, not the noise.
## It prints its line too, so this bait fails on the exit code alone.
printf '#!/bin/sh\necho x\nexit 1\n' > "${tmpDir}/bait-rc"
printf '#!/bin/sh\nexit 0\n' > "${tmpDir}/bait-quiet"
chmod +x "${tmpDir}/bait-rc" "${tmpDir}/bait-quiet"
fTest EpHGoa1 self-test-exit-code
got="$(fTimeMs "${tmpDir}/bait-rc" "${tmpDir}/base.ops" set 1 2>/dev/null)"
[[ "${got}" == "-1" ]] || { echo "perf-gate: self-test: a CLI exiting 1 was timed as ${got} ms, not refused" >&2; nBad+=1; }
fTest EqMEejQ self-test-quiet
got="$(fTimeMs "${tmpDir}/bait-quiet" "${tmpDir}/base.ops" set 1 2>/dev/null)"
[[ "${got}" == "-1" ]] || { echo "perf-gate: self-test: a CLI printing nothing was timed as ${got} ms, not refused" >&2; nBad+=1; }
## The cap comes down for the hang, since nobody is waiting out the real one.
## It prints its line and exits 0 eventually, so the other two guards have
## nothing to say about it and only the cap can refuse it.
fTest EqMEejR self-test-hang
printf '#!/bin/sh\nsleep 30\necho x\n' > "${tmpDir}/bait-hang"
chmod +x "${tmpDir}/bait-hang"
declare -i capWas="${runSecs}"
runSecs=1
got="$(fTimeMs "${tmpDir}/bait-hang" "${tmpDir}/base.ops" set 1 2>/dev/null)"
runSecs="${capWas}"
[[ "${got}" == "-1" ]] || { echo "perf-gate: self-test: a CLI that never returned was timed as ${got} ms, not refused" >&2; nBad+=1; }
## A gate whose own guards are down judges nothing after them.
if ((nBad)); then fTestEnd; exit 1; fi

##	Every `set` run prints the whole document, so the line count is the key
##	count; `check` prints one line per diagnostic plus a summary. A binding
##	whose baseline would not run has no budget, and sits out the workloads.
fTest Er6H1r6 baseline
declare -A baseOf=() budgetOf=()
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	baseMs="$(fTimeMs "${cli}" "${tmpDir}/base.ops" set "${keys}")"
	if ((baseMs < 0)); then nBad+=1; continue; fi
	## A floor, so a binding fast enough to come near the clock's resolution is
	## not judged on noise.
	budget=$(( baseMs * factor ))
	floor=$(( baseMs + 250 ))
	if ((budget < floor)); then budget="${floor}"; fi
	baseOf["${name}"]="${baseMs}"; budgetOf["${name}"]="${budget}"
done

## One test per workload, run by every binding before its line goes out.
workloads=(
	'EoTIbbt|writes'
	'EqvA7Zp|keeps'
	'EoTIbbu|defaults'
	'EoUsQuG|reads'
	'EoewZ3Y|badlines'
	'EojmbYO|suggest'
	'Ep3Shkv|recurse'
	'EpHDKev|frags'
	'EqAMPEH|stars'
	'EqAMPEI|mounts'
	'EqLlDoG|selectors'
	'EqLprWy|unknowns'
	'EqMO8fB|merge'
	'EqR8jEH|removes'
	'Er207Yg|raws'
)
for row in "${workloads[@]}"; do
	IFS='|' read -r tid w <<<"${row}"
	fTest "${tid}" "${w}"
	times=""
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		[[ -n "${budgetOf[${name}]:-}" ]] || continue
		budget="${budgetOf[${name}]}"; baseMs="${baseOf[${name}]}"
		if [[ "${w}" == keeps ]]; then
			## Three parses by design, the source, the edited text and the
			## reload check, against a one-parse baseline, so the row ran at up
			## to 85 percent of its budget in Python. Half again more room;
			## anything worse than linear still blows through it (20260926
			## idea 4).
			budget=$(( budget * 3 / 2 ))
			ms="$(fTimeMs "${cli}" "${keepDoc}" keeps "$((keys / 2))")"
		elif [[ "${w}" == badlines ]]; then
			ms="$(fTimeMs "${cli}" "${badDoc}" check 2)"
		elif [[ "${w}" == suggest ]]; then
			ms="$(fTimeMs "${cli}" "${sugDoc}" suggest 2)"
		elif [[ "${w}" == recurse ]]; then
			ms="$(fTimeMs "${cli}" "${recDoc}" recurse 2)"
		elif [[ "${w}" == frags ]]; then
			ms="$(fTimeMs "${cli}" "${fragDoc}" frags 2)"
		elif [[ "${w}" == stars ]]; then
			ms="$(fTimeMs "${cli}" "${starDoc}" stars 2)"
		elif [[ "${w}" == mounts ]]; then
			ms="$(fTimeMs "${cli}" "${mountDoc}" mounts 2)"
		elif [[ "${w}" == selectors ]]; then
			ms="$(fTimeMs "${cli}" "${selDoc}" selectors 1)"
		elif [[ "${w}" == unknowns ]]; then
			ms="$(fTimeMs "${cli}" "${unkDoc}" unknowns 4000)"
		elif [[ "${w}" == merge ]]; then
			ms="$(fTimeMs "${cli}" "${mergeOver}" merge "$((keys / 2))")"
		elif [[ "${w}" == removes ]]; then
			ms="$(fTimeMs "${cli}" "${rmDoc}" removes 6)"
		elif [[ "${w}" == raws ]]; then
			ms="$(fTimeMs "${cli}" "${rawDoc}" raws "$((keys * 2))")"
		else
			ms="$(fTimeMs "${cli}" "${tmpDir}/${w}.ops" set "${keys}")"
		fi
		if ((ms < 0)); then
			nBad+=1
		elif ((ms > budget)); then
			echo "perf-gate: ${name}: ${w} took ${ms} ms against a ${budget} ms budget (parse-only baseline ${baseMs} ms)" >&2
			nBad+=1
		else
			times+="${times:+, }${name} ${ms}/${budget} ms"
		fi
	done
	## The timings ride on the status line, as time against budget.
	# shellcheck disable=SC2034
	testName="${w}${times:+: ${times}}"
done

##	A count where the clock only drifts: the write calls for the refused-lines
##	document, at most four per line. Rust's stderr has no buffer, and writeln!
##	straight to it made eleven per diagnostic, which put badlines at up to seven
##	times its baseline on the hosted runner and failed the gate there now and
##	then.
fTest EqomByC write-counts
if command -v strace >/dev/null 2>&1; then
	counts=""
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		fRun strace -f -c -e trace=write,writev -o "${tmpDir}/strace" "${cli}" check "${badDoc}" >/dev/null 2>&1 || true
		calls="$(awk '$NF == "total" { print $4 }' "${tmpDir}/strace" 2>/dev/null || true)"
		if [[ ! "${calls}" =~ ^[0-9]+$ ]]; then
			echo "perf-gate: ${name}: strace gave no write count for badlines" >&2
			nBad+=1
		elif ((calls > keys * 4)); then
			echo "perf-gate: ${name}: badlines made ${calls} write calls for ${keys} refused lines, more than four a line" >&2
			nBad+=1
		else
			counts+="${counts:+, }${name} ${calls}"
		fi
	done
	# shellcheck disable=SC2034
	testName="write-counts${counts:+: badlines, ${keys} lines: ${counts}}"
elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
	echo "perf-gate: strace is missing, and the gate requires it" >&2
	nBad+=1
else
	echo "perf-gate: write counts SKIPPED - no strace"
	echo perf-gate-strace >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
fi
fTestEnd

if ((nBad)); then
	echo "perf-gate: ${nBad} workload(s) over budget" >&2
	exit 1
fi
echo "perf-gate: OK: ${keys} keys, ${#bindings[@]} binding(s) within ${factor}x their own parse baseline"

##	History:
##		2026-08-30  Created after two superlinear write regressions reached dev
##		            in consecutive rounds with no numeric gate to catch them.
##		2026-09-01  badlines workload: a document of refused lines, which went
##		            quadratic through the retained-trivia list.
##		2026-09-02  suggest workload: long unknown names against long schema names,
##		            which cost a full edit-distance table per pair.
##		2026-09-05  recurse workload: an unknown field deep under a fragment that
##		            mounts itself twice, which doubled the chain walk per level.
##		2026-09-08  frags workload: a schema of many unused fragments, whose
##		            duplicate check scanned every fragment already recorded.
##		2026-09-08  Self-test over the timer's own two guards, so a tidy-up cannot
##		            delete one and leave the gate reporting OK on a CLI that failed.
##		2026-09-17  stars and mounts workloads: the unknown-field sweep's two
##		            element-wise matchers, each scanning its whole list per node.
##		2026-09-19  merge workload: two flat files naming the same keys, whose
##		            override arm scanned every base child per name.
##		2026-09-19  selectors workload: quoted `[value]` selectors, each a new
##		            instance, which scanned every sibling on the create path.
##		2026-09-19  unknowns workload: every name unknown, which compared each with
##		            every sibling, one copy per schema field.
##		2026-09-19  Every run is capped at five minutes, so a binding that stops
##		            terminating fails this gate instead of hanging it.
##		2026-09-20  removes workload: every child of one parent taken out by one
##		            path, which rebuilt that child list once per target.
##		2026-09-24  Write calls counted for badlines, since Rust's unbuffered
##		            stderr made the clock flaky on the hosted runner.
##		2026-09-26  raws workload: raw blocks side by side, each of which
##		            rescanned its whole sibling run in the emitter.
