#!/usr/bin/env bash

##	Purpose:
##		Prove every binding still parses a document far larger than anything the
##		corpus holds. The corpus is 56 small cases and the fuzz set is smaller
##		still, so nothing else in the pipeline would notice a parser going
##		quadratic, a buffer that only grows wrong past a few megabytes, or a
##		memory profile that puts a real config out of reach on a modest machine.
##		Generates one document, formats it through every binding, and requires
##		them to agree byte for byte on the result - then checks the reference's
##		own invariants at that scale and gates wall clock and peak memory.
##		A slow binding can get a smaller copy of the document; the limits
##		table below says which.
##	Syntax:
##		largedoc.bash [--mib N] [--keep] NAME|CLI [NAME|CLI ...]
##		  --mib N   document size to generate, in MiB (default 100)
##		  --keep    leave the working directory behind for inspection
##		  NAME|CLI  binding label and its CLI path; the first is the reference
##		The runs overlap as far as free memory and CPU_CAP allow (see below).
##	Exit: 0 = all bindings agree and stay inside their limits, 1 = they do not.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/largedoc-gen.bash"   ## largedoc_gen()
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=largedoc; testCounter=nBad

mib=100
keep=0
bindings=()
while (($#)); do case "$1" in
	--mib)    mib="$2"; shift 2 ;;
	--keep)   keep=1; shift ;;
	-h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##	\{0,1\}//'; exit 0 ;;
	-*)       echo "largedoc: unknown option: $1" >&2; exit 2 ;;
	*)        bindings+=("$1"); shift ;;
esac; done

((${#bindings[@]})) || { echo "largedoc: no bindings given" >&2; exit 2; }
if ! [[ "${mib}" =~ ^[1-9][0-9]*$ ]]; then echo "largedoc: --mib wants a positive integer" >&2; exit 2; fi

## Per-binding ceilings, "name|seconds per input MiB|peak RSS MiB per input MiB|
## peak RSS MiB floor|largest document in MiB". Expressed per-MiB so they follow
## --mib instead of being pinned to one size; the floor is the runtime's own
## footprint, which does not scale with the input and at one or two MiB is most
## of what is measured.
## The last field caps a slow binding's document, which is generated the same
## way at the smaller size and checked against the reference's output for it.
## Python at 100 MiB was the whole gate's critical path, two minutes and more;
## 16 MiB still shows a quadratic parse or a buffer that grows wrong. Empty means
## the full --mib. The reference always runs the full size.
## Time carries wide headroom - the pipeline runs the reference unoptimized (about
## six times slower than a release build), and a shared CI runner is slower again;
## the target is a growth-rate regression, not a stopwatch. Memory is held much
## closer, since peak RSS barely moves between machines or build profiles.
## Measured at 100 MiB on a workstation: rust 0.53 s/MiB and 21 MiB/MiB, go 0.08
## and 33-41 (concurrent GC moves it run to run, so its ceiling carries more
## slack), c 0.04 and 30, python 1.11 and 47.
limits=(
	"rust|3.00|32|16|"
	"go|1.00|55|24|"
	"c|1.00|45|8|"
	"python|4.00|65|48|16"
)

fLimit() {   ## $1 = binding name, $2 = field (2=secs, 3=rss, 4=rss floor, 5=max MiB); empty when unlisted
	local e
	for e in "${limits[@]}"; do [[ "${e%%|*}" == "$1" ]] && { cut -d'|' -f"$2" <<<"${e}"; return 0; }; done
	return 0   ## an unlisted binding is measured and reported, just not gated
}

work="$(mktemp -d "${TMPDIR:-/tmp}/shcl-largedoc.XXXXXX")"
((keep)) || trap 'rm -rf "${work}"' EXIT

## Room for the document plus every binding's formatted copy, since the runs
## overlap, with slack.
avail_kib="$(df -Pk "${work}" | awk 'NR==2{print $4}')"
## Two more for one capped size: its document and the reference's output for it.
need_kib=$(( mib * 1024 * (${#bindings[@]} + 4) ))
((avail_kib >= need_kib)) || {
	echo "largedoc: need ~$((need_kib/1024)) MiB free for ${work}, have $((avail_kib/1024)) MiB" >&2
	exit 1
}

doc="${work}/large.shcl"

## The generator lives in include/largedoc-gen.bash (the profiler workload is
## the same document at a smaller size).
echo "largedoc: generating ${mib} MiB -> ${doc}"
largedoc_gen "${mib}" > "${doc}"

actualMib=$(( $(stat -c%s "${doc}") / 1048576 ))
echo "largedoc: ${actualMib} MiB, $(grep -c '' "${doc}") lines"

refName="${bindings[0]%%|*}"
refCli="${bindings[0]#*|}"
refOut="${work}/out-${refName}.shcl"

## Which document each binding formats, its size, and the reference output it
## has to match. A capped size gets its own document and its own reference run.
declare -A docOf=() mibOf=() refOutOf=()
smallSizes=()
for entry in "${bindings[@]}"; do
	name="${entry%%|*}"
	docOf["${name}"]="${doc}"; mibOf["${name}"]="${actualMib}"; refOutOf["${name}"]="${refOut}"
	[[ "${name}" == "${refName}" ]] && continue
	maxMib="$(fLimit "${name}" 5)"
	if [[ -n "${maxMib}" ]] && ((maxMib < mib)); then
		small="${work}/large-${maxMib}.shcl"
		if ! [[ -f "${small}" ]]; then
			echo "largedoc: generating ${maxMib} MiB for ${name} -> ${small}"
			largedoc_gen "${maxMib}" > "${small}"
			smallSizes+=("${maxMib}")
		fi
		docOf["${name}"]="${small}"
		mibOf["${name}"]=$(( $(stat -c%s "${small}") / 1048576 ))
		refOutOf["${name}"]="${work}/ref-${maxMib}.shcl"
	fi
done

## Wall clock and peak RSS for one run. VmHWM is the kernel's own high-water
## mark and only ever climbs, so sampling it is exact up to the last sample.
## The poll is builtins only - a read of /proc and a timed read on a fd that
## never delivers, as the sleep - so twenty samples a second cost no forks.
## Sets runSecs/runRssMib/runRc.
exec {tickFd}<> <(:)
fRunMeasured() {
	local out="$1"; shift
	local pid hwm=0 key val t0 t1
	t0="$(date +%s.%N)"
	"$@" > "${out}" 2>"${out}.err" & pid=$!
	while kill -0 "${pid}" 2>/dev/null; do
		while read -r key val _; do
			[[ "${key}" == "VmHWM:" ]] && ((val > hwm)) && hwm="${val}"
		done < "/proc/${pid}/status" 2>/dev/null || true
		read -rt 0.05 -u "${tickFd}" _ || true
	done
	runRc=0; wait "${pid}" || runRc=$?
	t1="$(date +%s.%N)"
	runSecs="$(awk -v a="${t0}" -v b="${t1}" 'BEGIN{printf "%.1f", b-a}')"
	runRssMib=$(( hwm / 1024 ))
}

## The runs overlap. Each binding's own run, plus the reference's three
## invariant reads below, are jobs, and a job starts only while the memory
## ceilings of everything running fit in what the machine has free, less a
## reserve, and CPU_CAP allows it. The ceilings are the limits above, so a run
## that would push past its share already fails the gate. One job may always
## run, so a small machine goes one at a time, as it always did. Two of the
## reads need the reference's output and join the queue once it exists.
declare -A cliOf=() ceilMib=() jobOf=() jobMib=()
maxCeil=0
for entry in "${bindings[@]}"; do
	name="${entry%%|*}"; cliOf["${name}"]="${entry#*|}"
	ceilMib["${name}"]=0
	for e in "${limits[@]}"; do
		IFS='|' read -r lName _ lRss lFloor <<<"${e}"
		if [[ "${lName}" == "${name}" ]]; then ceilMib["${name}"]=$((lRss * ${mibOf[${name}]} + lFloor)); fi
	done
	if ((ceilMib["${name}"] > maxCeil)); then maxCeil=${ceilMib["${name}"]}; fi
done
## An unlisted binding is not gated, so it is budgeted as the largest listed.
for name in "${!ceilMib[@]}"; do
	if ((ceilMib["${name}"] == 0)); then ceilMib["${name}"]=${maxCeil}; fi
done
budgetMib=$(( $(awk '/^MemAvailable:/{print int($2 / 1024)}' /proc/meminfo) - 2048 ))
cap="${CPU_CAP:-}"
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || cap=$(( $(nproc) / 2 ))
((cap > 0)) || cap=1

fJobRun() {
	case "$1" in
		fmt\|*)
			local name="${1#fmt|}"
			fRunMeasured "${work}/out-${name}.shcl" "${cliOf[${name}]}" fmt "${docOf[${name}]}"
			echo "${runSecs} ${runRssMib} ${runRc}" > "${work}/res-${name}"
			;;
		## The reference's output for a capped binding's smaller document.
		ref\|*)
			local size="${1#ref|}"
			"${refCli}" fmt "${work}/large-${size}.shcl" > "${work}/ref-${size}.shcl" 2>/dev/null || true
			;;
		## The generator promises a document nothing in it merges into and that
		## loads clean; the profiler's numbers depend on it. A hint per unit once
		## made the profile measure stderr.
		check)
			"${refCli}" check "${doc}" 2>/dev/null | tail -1 > "${work}/res-check" || true
			;;
		fixpoint)
			if "${refCli}" fmt "${refOut}" 2>/dev/null | cmp -s - "${refOut}"; then
				echo yes > "${work}/res-fixpoint"
			else
				echo no > "${work}/res-fixpoint"
			fi
			;;
		wide)
			"${refCli}" get --int --array "${refOut}" wide 2>/dev/null | grep -c '' > "${work}/res-wide" || true
			;;
	esac
}

queue=()
for entry in "${bindings[@]}"; do
	name="${entry%%|*}"
	## A missing CLI is reported in the table; there is nothing to run.
	if [[ -r "${cliOf[${name}]}" ]]; then queue+=("fmt|${name}"); fi
done
for size in "${smallSizes[@]}"; do queue+=("ref|${size}"); done
queue+=(check)
declare -i nLive=0 usedMib=0
while ((${#queue[@]} || nLive)); do
	while ((${#queue[@]})); do
		job="${queue[0]}"
		need=${ceilMib["${refName}"]}
		if [[ "${job}" == fmt\|* ]]; then need=${ceilMib["${job#fmt|}"]}; fi
		if ((nLive > 0 && (nLive >= cap || usedMib + need > budgetMib))); then break; fi
		fJobRun "${job}" &
		jobOf[$!]="${job}"; jobMib[$!]="${need}"
		nLive+=1; usedMib+=need
		queue=("${queue[@]:1}")
	done
	donePid=""
	wait -n -p donePid || true
	if [[ -z "${donePid}" ]]; then break; fi
	nLive+=-1; usedMib+=-${jobMib[${donePid}]}
	if [[ "${jobOf[${donePid}]}" == "fmt|${refName}" && -s "${refOut}" ]]; then queue+=(fixpoint wide); fi
done

## The table's two kinds of failure are two tests, agreement and the limits,
## and each invariant below is one more.
rc=0
declare -i nBad=0 agreeBad=0 limitBad=0
printf '\n%-8s %8s %10s   %s\n' "binding" "secs" "peak MiB" "result"

for entry in "${bindings[@]}"; do
	name="${entry%%|*}"; cli="${entry#*|}"
	[[ -r "${cli}" ]] || { printf '%-8s %8s %10s   MISSING: %s\n' "${name}" - - "${cli}"; rc=1; agreeBad+=1; continue; }

	out="${work}/out-${name}.shcl"
	runSecs=- runRssMib=- runRc=""
	if [[ -f "${work}/res-${name}" ]]; then read -r runSecs runRssMib runRc < "${work}/res-${name}"; fi
	note=""
	if [[ -z "${runRc}" ]]; then
		note="FAILED: the run left no result"
		rc=1; agreeBad+=1
	elif [[ "${runRc}" != 0 ]]; then
		note="FAILED (exit ${runRc}): $(head -c 200 "${out}.err" | tr '\n' ' ')"
		rc=1; agreeBad+=1
	else
		ownMib="${mibOf[${name}]}"
		against="${refOutOf[${name}]}"
		sum="$(sha256sum "${out}" | cut -d' ' -f1)"
		sizeNote=""
		((ownMib == actualMib)) || sizeNote=" at ${ownMib} MiB"
		if [[ "${name}" == "${refName}" ]]; then note="reference"
		## Empty agrees with empty, the same hole the invariants below guard.
		elif ! [[ -s "${against}" ]]; then note="FAILED: ${refName} wrote nothing${sizeNote}"; rc=1; agreeBad+=1
		elif [[ "${sum}" == "$(sha256sum "${against}" | cut -d' ' -f1)" ]]; then note="agrees${sizeNote}"
		else note="DIFFERS from ${refName}${sizeNote}"; rc=1; agreeBad+=1
		fi

		maxSecs="$(fLimit "${name}" 2)"
		if [[ -n "${maxSecs}" ]]; then
			maxRss="$(fLimit "${name}" 3)"; rssFloor="$(fLimit "${name}" 4)"
			if awk -v s="${runSecs}" -v m="${maxSecs}" -v n="${ownMib}" 'BEGIN{exit !(s > m*n)}'; then
				note="${note}; TOO SLOW (over $(awk -v m="${maxSecs}" -v n="${ownMib}" 'BEGIN{printf "%.0f", m*n}')s)"; rc=1; limitBad+=1
			fi
			if ((runRssMib > maxRss * ownMib + rssFloor)); then
				note="${note}; TOO BIG (over $((maxRss * ownMib + rssFloor)) MiB)"; rc=1; limitBad+=1
			fi
		fi
	fi
	printf '%-8s %8s %10s   %s\n' "${name}" "${runSecs}" "${runRssMib}" "${note}"
done
echo
fTest EnPl0qG bindings agree on the large document
nBad+=agreeBad
fTest Eqbhfd2 bindings within their time and memory limits
nBad+=limitBad

## Reference-only invariants at this scale, from the reads above. Formatting has
## to be a fixpoint, and a long array has to read back whole - a stale buffer
## pointer after growth is a defect this project has actually shipped, and no
## small case can see it.
fixpoint=""; summary=""; wideCount=0
if [[ -s "${refOut}" ]]; then
	if [[ -f "${work}/res-fixpoint" ]]; then read -r fixpoint < "${work}/res-fixpoint"; fi
	if [[ -f "${work}/res-check" ]]; then IFS= read -r summary < "${work}/res-check" || true; fi
	if [[ -f "${work}/res-wide" ]]; then read -r wideCount < "${work}/res-wide"; fi
else
	## Empty output agrees with empty output, so every binding would pass above.
	echo "largedoc: FAILED: the reference wrote nothing, so no invariant could be checked" >&2; rc=1
fi
fTest EnPl0qH fmt is a fixpoint on the large document
if [[ "${fixpoint}" == yes ]]; then
	echo "largedoc: fmt is a fixpoint at ${actualMib} MiB"
else
	echo "largedoc: FAILED: fmt is not a fixpoint at ${actualMib} MiB" >&2; rc=1; nBad+=1
fi
fTest Eojtm8u the generated document loads with no diagnostics
if [[ "${summary}" == "ok (0 diagnostic(s))" ]]; then
	echo "largedoc: the generated document loads with no diagnostics"
else
	echo "largedoc: FAILED: the generated document does not load clean: ${summary}" >&2; rc=1; nBad+=1
fi
fTest EnPl0qI a long array reads back whole
if [[ "${wideCount}" == 20000 ]]; then
	echo "largedoc: long array read back whole (${wideCount} elements)"
else
	echo "largedoc: FAILED: long array read back ${wideCount} of 20000 elements" >&2; rc=1; nBad+=1
fi
fTestEnd

echo
if ((rc == 0)); then echo "largedoc: OK (${#bindings[@]} binding(s) agree at ${actualMib} MiB)"
else echo "largedoc: FAILED" >&2; fi
((keep)) && echo "largedoc: kept ${work}"
exit "${rc}"


##	History:
##		- 2026-08-19 JC: Created. Nothing else in the pipeline runs a document
##		  bigger than a few kilobytes, so growth-rate and buffer-growth defects
##		  had no gate at all.
##		- 2026-08-29 JC: Generator moved to include/largedoc-gen.bash; the memory
##		  poll no longer forks per sample.
##		- 2026-09-22 JC: The bindings and the invariant reads run at once, as far
##		  as their memory ceilings fit in free memory. 188 s to 132 s here.
##		- 2026-09-25 JC: Python formats a 16 MiB document, checked against the
##		  reference's output for it. At 100 MiB it was the gate's critical path.
