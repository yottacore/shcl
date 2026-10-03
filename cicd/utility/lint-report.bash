#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately.' Cumbersome and unnecessary here.
#  shellcheck disable=2086  ## 'Double quote to prevent word splitting.' OK for integer flags.

##	Purpose:
##		Surface warnings from the newest cicd run log. cicd tees each run to
##		cicd/artifacts/lint/run_<ts>.log (gitignored); this greps out the warning /
##		advisory lines so they can be addressed. Two modes: plain (print warnings
##		from the newest log) and --check (print only when that log is newer than the
##		one last recorded in a local marker, then record it - meant for a per-session
##		startup look that is a no-op until a new cicd run has happened). A log with
##		neither the done line nor an abort line reports INCOMPLETE and is not
##		recorded, so the next look reads it again.
##	Syntax:
##		lint-report.bash [--check] [--force] [--no-mark] [--dir DIR] [--file LOG]
##		  --check     gate on the .lint-seen marker; print SEEN and stop if not newer
##		  --force     with --check, report even if already seen
##		  --no-mark   with --check, do not update the marker
##		  --dir DIR   log directory (default: cicd/artifacts/lint next to this script)
##		  --file LOG  report on this log instead of the newest in DIR
##	Exit: 0 normal, 2 skip (no dir / no logs).
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dir="${meDir}/../artifacts/lint"        ## this script lives in cicd/utility -> cicd/artifacts/lint
file=""; check=0; force=0; noMark=0

while (($#)); do case "$1" in
	--check)    check=1; shift ;;
	--force)    force=1; shift ;;
	--no-mark)  noMark=1; shift ;;
	--dir)      dir="${2:-}"; shift 2 ;;
	--file)     file="${2:-}"; shift 2 ;;
	-h|--help)  grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*) echo "lint-report: unknown option: $1" >&2; exit 2 ;;
esac; done

fSkip() { echo "lint-report: $1" >&2; exit 2; }   ## 2 = non-fatal skip (matches the cicd profiler stage)

##	Newest run_<ts>[_role].log by timestamp - the role suffix, if gfs rotation added
##	one, is ignored (the timestamp is stable).
fNewest() {
	local d="$1" best="" newest="" f b t
	for f in "$d"/run_*.log; do
		[[ -e "$f" ]] || continue
		b="$(basename "$f")"; t="${b#run_}"; t="${t%%_*}"; t="${t%.log}"
		[[ "$t" > "$best" ]] && { best="$t"; newest="$f"; }
	done
	[[ -n "$newest" ]] || return 1
	printf '%s\t%s\n' "$best" "$newest"
}

if [[ -n "$file" ]]; then
	[[ -f "$file" ]] || fSkip "no such file: $file"
	log="$file"; b="$(basename "$file")"; ts="${b#run_}"; ts="${ts%%_*}"; ts="${ts%.log}"
else
	[[ -d "$dir" ]] || fSkip "no log dir: $dir"
	nb="$(fNewest "$dir")" || fSkip "no run logs in $dir"
	ts="${nb%%$'\t'*}"; log="${nb#*$'\t'}"
fi

##	How old the log is, in whichever unit reads plainest. Every line below names
##	the log and says nothing about when it ran, so SEEN and CLEAN look the same
##	whether the run behind them finished an hour ago or a fortnight ago - and a
##	stale one has been read as evidence that the tree is clean today.
fAge() {
	local secs=$(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
	if ((secs < 0)); then secs=0; fi
	if   ((secs < 5400));   then printf '%dm' $(( secs / 60 ))
	elif ((secs < 172800)); then printf '%dh' $(( secs / 3600 ))
	else                         printf '%dd' $(( secs / 86400 )); fi
}
age="$(fAge "$log")"

##	SEEN only when the marker names the newest log exactly. A marker ahead of every
##	log, from a --file run on an old log or a name that sorts high, used to silence
##	the gate for good. --file is not the newest log, so it never moves the marker.
marker="${dir}/.lint-seen"
if ((check)) && ((! force)) && [[ -z "$file" ]]; then
	seen=""; [[ -f "$marker" ]] && seen="$(tr -d '[:space:]' < "$marker" 2>/dev/null)"
	if [[ -n "$ts" && "$ts" == "$seen" ]]; then
		echo "SEEN $(basename "$log")  (nothing newer than $seen, ${age} old)"; exit 0
	fi
fi

##	A run is finished when its last line is the done line, or when it printed one of
##	the pipeline's two abort lines. Anything else is still running or was cut off.
##	The last line, not any line: a publish echoes the pre-push gate's nested run,
##	done line and all. An unfinished log never gets the marker, since a look taken
##	mid-run used to mark it seen and the warnings and abort that followed were
##	never shown.
lastLine="$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n 1 || true)"
finished=0
if [[ "$lastLine" == *"CI/CD: done."* ]] || grep -qE '^\[ FAILED: |CICD ABORTED' "$log" 2>/dev/null; then finished=1; fi

##	Record the marker now (before printing the body) so a caller that pipes stdout
##	to head/less and closes it early still records the look.
if ((check)) && ((! noMark)) && ((finished)) && [[ -z "$file" && "$ts" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
	printf '%s\n' "$ts" > "$marker" 2>/dev/null || echo "lint-report: could not write marker: $marker" >&2
fi

##	Distil warnings/advisories. rustc/clippy/cargo-deny all say "warning"; deny adds
##	RUSTSEC ids + vulnerable/unmaintained/yanked. Hard errors only appear in a failed
##	run's log (a passing run aborts on the first error). Drop the "0 warnings" noise,
##	govulncheck's clean-result prose (its "found N vulnerabilities in modules you
##	require, but your code doesn't appear to call" block is informational and prints
##	on every run), and the echoed command lines that carry the word: cppcheck's
##	`--enable=warning`, and clippy's `-D warnings`, which the pre-push gate's
##	nested run echoes during publish and which used to read as a finding.
warns="$(grep -inE 'warning|rustsec-|vulnerab|unmaintained|yanked' "$log" 2>/dev/null \
	| grep -viE 'generated 0 warnings|: 0 warnings|no warnings|0 warnings emitted' \
	| grep -viE 'no vulnerabilities found|affected by 0 vulnerabilities|this scan also found|appear to call|^[0-9]+:these vulnerabilities\.$|enable=warning|-D warnings' || true)"
if [[ -n "$warns" ]]; then n=$(printf '%s\n' "$warns" | grep -c .); else n=0; fi

##	A failed run is never CLEAN. Case-sensitive: each tool prints its failure one
##	way, and the lower-case words turn up in passing output. The pipeline stops
##	two ways: an unexpected error raises the ABORTED line, and a check that fails
##	on purpose prints `[ FAILED: ... ]` and exits.
errs="$(grep -nE '(^|[^[:alnum:]_-])error(\[|:)|\bSC[0-9]{4}\b|test result: FAILED|^--- FAIL|^FAIL\b|panicked at|^Traceback \(most recent call last\)|CICD ABORTED|^\[ FAILED: ' "$log" 2>/dev/null || true)"
if [[ -n "$errs" ]]; then e=$(printf '%s\n' "$errs" | grep -c .); else e=0; fi

tag="FLAG"; ((check)) && tag="NEW"
if ((e)); then
	echo "FAILED $(basename "$log")  (${e} error line(s), ${n} warning line(s), ${age} old)"
	echo
	printf '%s\n' "$errs"
	if ((n)); then echo; printf '%s\n' "$warns"; fi
elif ((! finished)); then
	echo "INCOMPLETE $(basename "$log")  (no done or abort line: still running, or cut off; ${n} warning line(s) so far, ${age} old)"
	if ((n)); then echo; printf '%s\n' "$warns"; fi
elif ((n)); then
	echo "${tag} $(basename "$log")  (${n} warning line(s), ${age} old)"
	echo
	printf '%s\n' "$warns"
else
	echo "CLEAN $(basename "$log")  (0 warnings, ${age} old)"
fi


##	Script history:
##		- 20260709: Created.
##		- 20260902: The echoed `-D warnings` of a nested clippy run is not a finding.
##		- 20260914: A failed run reports FAILED with its error lines. The marker
##		  moves only on the newest log, and SEEN needs an exact match.
##		- 20260919: Every line says how old the log is, so a report standing on a
##		  fortnight-old run reads as one.
##		- 20260919: `[ FAILED: ... ]` counts as a failure. A log with no done or
##		  abort line is INCOMPLETE and never marked seen.
