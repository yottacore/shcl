#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately.' Cumbersome and unnecessary here.

##	Purpose:
##		The migration gate: for every corpus input and every fuzz-dumped
##		document, the current parser's reading of `migrate`'s output equals the
##		2.x parser's reading of the original. Read, not canonical text: the two
##		emitters spell a value differently on purpose (single quotes for a
##		backslash, no `\'`), so the trees are compared through the reads - the
##		path list, the instance count at every path, and each instance's
##		string array, raw body and info string. The 2.x side is a build of the
##		last pre-cut dev commit, pinned below by hash and built into its own
##		gitignored target the way the pre-push gate builds, so the comparison
##		never rests on whatever `shcl` is on PATH. The 2.x build also reads the
##		migrated text, which has to give the tree it read from the original: a
##		spelling 2.x reads differently is what makes a second run change a file.
##
##		Compared is what 2.x read cleanly. A line it kept as malformed may read
##		as a binding now, which is a gain, not a migration; a bracket array it
##		counted lost was refused by 2.x itself; a dropped line of any kind says
##		nothing. So those lines come out of the document first, and the rest is
##		compared, as long as 2.x then reads it cleanly. Two more kinds of line
##		come out the same way: a fence label holding a `#`, which 2.x ran to
##		the end of the line and which ends at the `#` now, with no quoting to
##		spell it; and a carriage return in the middle of a line, which 2.x kept
##		as content and which is a blank at a piece's edge now. Each is asserted
##		on a corpus case, so the list cannot rot.
##
##		A compared document also has to migrate at exit 0, and a document whose
##		only unclean lines are bracket arrays has to be refused over exactly
##		that many lost lines. The corpus half has its own floor, since the fuzz
##		dump alone can meet the overall one, and so does the fuzz half, since the
##		corpus alone can meet it too.
##	Syntax:
##		check-migrate.bash [--corpus DIR] [--iters N] [--min N] [--min-corpus N] [--min-fuzz N]
##		  --corpus DIR  conformance corpus root (default project/conformance)
##		  --iters N     fuzz iterations to dump (default 2000)
##		  --min N       fail unless at least N documents were compared (default 100)
##		  --min-corpus N  and at least N of them corpus cases (default 80)
##		  --min-fuzz N  and at least N of them fuzz-dumped (default 200)
##	Exit: 0 = every compared document equal, 1 = a divergence, 2 = usage or a build failure.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=check-migrate; testCounter=nBad

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
corpus="${root}/project/conformance"; declare -i iters=2000 minCompared=100 minCorpus=80 minFuzz=200
while (($#)); do case "$1" in
	--corpus)  corpus="${2:-}"; shift 2 ;;
	--iters)   iters="${2:-2000}"; shift 2 ;;
	--min)     minCompared="${2:-100}"; shift 2 ;;
	--min-corpus) minCorpus="${2:-80}"; shift 2 ;;
	--min-fuzz) minFuzz="${2:-200}"; shift 2 ;;
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         echo "check-migrate: unknown argument: $1" >&2; exit 2 ;;
esac; done
[[ -d "${corpus}" ]] || { echo "check-migrate: no corpus dir: ${corpus}" >&2; exit 2; }

##	The last dev commit before the lexical cut: the funnel merge.
pin="7be348d0de309ead4cba9f2fa28650b48b320519"
if ! git -C "${root}" cat-file -e "${pin}^{commit}" 2>/dev/null; then
	## A shallow clone (the hosted runner) has no history; a full sha can still
	## be fetched on its own.
	git -C "${root}" fetch --depth=1 origin "${pin}" >/dev/null 2>&1 || true
	git -C "${root}" cat-file -e "${pin}^{commit}" 2>/dev/null \
		|| { echo "check-migrate: the pinned 2.x commit ${pin:0:12} is not in this clone" >&2; exit 2; }
fi

tmpDir="$(mktemp -d)"; tree=""
fCleanup(){
	if [[ -n "${tree}" ]]; then git -C "${root}" worktree remove --force "${tree}" >/dev/null 2>&1 || true; fi
	git -C "${root}" worktree prune >/dev/null 2>&1 || true
	rm -rf "${tmpDir}"
}
trap fCleanup EXIT

##	Build the 2.x CLI once per pin; the target dir keeps it across runs.
oldTarget="${root}/source/rust/target-migrate"
oldCli="${oldTarget}/debug/shcl"
if [[ ! -x "${oldCli}" || "$(cat "${oldTarget}/.pin" 2>/dev/null || true)" != "${pin}" ]]; then
	echo "check-migrate: building the 2.x reference at ${pin:0:12}"
	tree="$(mktemp -d "${TMPDIR:-/tmp}/shcl-migrate.XXXXXX")"
	git -C "${root}" worktree add --detach "${tree}" "${pin}" >/dev/null 2>&1 \
		|| { echo "check-migrate: cannot check ${pin:0:12} out" >&2; exit 2; }
	mkdir -p "${oldTarget}"
	ln -s "${oldTarget}" "${tree}/source/rust/target"
	( cd "${tree}/source/rust" && cargo build --quiet ) || { echo "check-migrate: the 2.x build failed" >&2; exit 2; }
	printf '%s\n' "${pin}" > "${oldTarget}/.pin"
	fCleanup; tree=""; tmpDir="$(mktemp -d)"
fi
newCli="${root}/source/rust/target/debug/shcl"
[[ -x "${newCli}" ]] || ( cd "${root}/source/rust" && cargo build --quiet )

##	The soup, from the current fuzz generator.
dump="${tmpDir}/dump"; mkdir -p "${dump}"
( cd "${root}/source/rust" && SHCL_FUZZ_DUMP="${dump}" SHCL_FUZZ_ITERS="${iters}" SHCL_FUZZ_DUMP_MAX=500 \
	cargo test --quiet --test fuzz_smoke mutated_inputs >/dev/null 2>&1 ) || { echo "check-migrate: the fuzz dump failed" >&2; exit 2; }
##	A test filter that matches nothing passes and writes nothing, and the corpus
##	alone meets the overall floor, so an empty dump has to be caught here.
nDumped="$(find "${dump}" -maxdepth 1 -name '*.shcl' | wc -l)"
((nDumped > 0)) || { echo "check-migrate: the fuzz dump wrote no documents" >&2; exit 2; }

##	The lines 2.x did not read cleanly, by number. A line is clean when every
##	code 2.x reports on it binds the line: E001 (field kept), E005 (fence
##	unterminated, body kept), E015 (repaired), E017 (kept literally), the two
##	hints, and E019 as a hint, which is the `name:[x]` sugar read as `name: x`.
##	E019 as an error is the bracket array. Read from what 2.x's `check` printed,
##	so one run of it serves every question asked of the same bytes.
fCheck2x(){ "${oldCli}" check "$1" 2>/dev/null || true; }
fUnclean2x(){
	awk '$1 == "line" {
		if ($4 ~ /^(E001|E005|E015|E017|H001|H002)$/ || ($4 == "E019" && $3 == "Hint:")) next
		sub(/:$/, "", $2); print $2 }'
}

##	The string array goes through `--slots`, one status and one line per element.
##	2.x prints an element holding a line break as it is, over several lines, and
##	the current CLI escapes it onto one. The 2.x side is put back together at each
##	status and escaped by the CLI's rule, so the two compare element by element.
fOneLine2x(){ awk '
	function put() { if (!have) return; if (v ~ /[\n\r]/) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); gsub(/\n/, "\\n", v); gsub(/\r/, "\\r", v); gsub(/\t/, "\\t", v); v = "\"" v "\"" } print s "\t" v }
	/^(Good|Empty|NotFound|BadType|Multiple)\t/ { put(); i = index($0, "\t"); s = substr($0, 1, i - 1); v = substr($0, i + 1); have = 1; next }
	{ v = v "\n" $0 }
	END { put() }'; }

##	A quoted name as the current CLI spells it: an invisible character is a
##	\u escape now, and 2.x wrote it as it is. The name is the same either way,
##	so only the 2.x side's paths are respelled. The list is `invisible` in the
##	bindings.
fSpellNames2x(){ python3 -c '
import sys
hide = set(range(0x00, 0x09)) | set(range(0x0B, 0x20)) | set(range(0x7F, 0xA0)) \
	| {0x061C, 0x200B, 0x200E, 0x200F, 0xFEFF} | set(range(0x2028, 0x202F)) \
	| set(range(0x2060, 0x2065)) | set(range(0x2066, 0x206A))
text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
sys.stdout.buffer.write("".join("\\u%04X" % ord(c) if ord(c) in hide and c != "\n" else c for c in text).encode("utf-8", "surrogateescape"))
'; }

##	Everything a tree is, read through one CLI: the paths, the count at each,
##	and per instance the string array, the raw body and the info string, with
##	the exit codes, one line per read. A path holding a tab cannot ride the
##	loop; those are left to the native runners.
fReadTree(){
	local cli="$1" doc="$2" p n i q rc spell=cat
	if [[ "${cli}" == "${oldCli}" ]]; then spell=fSpellNames2x; fi
	rc=0; "${cli}" paths "${doc}" > "${tmpDir}/paths" 2>/dev/null || rc=$?
	"${spell}" < "${tmpDir}/paths"
	((rc == 0)) || echo "paths exit ${rc}"
	while IFS= read -r p; do
		[[ -n "${p}" && "${p}" != *$'\t'* ]] || continue
		n="$("${cli}" count "${doc}" "${p}" 2>/dev/null || true)"
		echo "count $("${spell}" <<<"${p}") = ${n}"
		[[ "${n}" =~ ^[0-9]+$ ]] || continue
		for ((i = 0; i < n; i++)); do
			q="${p}[#${i}]"
			rc=0; "${cli}" get --string --array --slots "${doc}" "${q}" > "${tmpDir}/array" 2>/dev/null || rc=$?
			if [[ "${cli}" == "${oldCli}" ]]; then fOneLine2x < "${tmpDir}/array"; else cat "${tmpDir}/array"; fi
			[[ "${rc}" == 0 ]] || echo "string exit ${rc}"
			"${cli}" get --raw "${doc}" "${q}" 2>/dev/null || echo "raw exit $?"
			"${cli}" get --rawinfo "${doc}" "${q}" 2>/dev/null || echo "rawinfo exit $?"
		done
	done < <("${cli}" paths "${doc}" 2>/dev/null || true)
}

##	One read answers differently by decision rather than by migration: the info
##	string of an empty binding was BadType in 2.x and is Empty now, matching the
##	raw-content read on the same node. The two reads sit next to each other in
##	the tree above, so the 2.x side's answer is brought forward here rather than
##	dropping the info string from the comparison entirely.
##	Each read prints its (empty) value before its status line, so the raw status
##	sits two lines back.
fAge2xReads(){ awk '$0 == "rawinfo exit 4" && prev == "" && prev2 == "raw exit 2" { $0 = "rawinfo exit 2" } { print; prev2 = prev; prev = $0 }'; }

##	A NUL-bearing document cannot ride a command substitution; the native
##	runners pin those.
fHasNul(){ IFS= read -r -d '' _ <"$1"; }

##	A 2.x fence label carrying a `#` has no spelling here at all: the `#` opens
##	the line's comment now, and nothing quotes a label. So `migrate` leaves the
##	line as written and the reading differs by design. Matched on the text
##	rather than by file name, because a fuzz document's number moves every time
##	the corpus grows.
fInfoHashLabel(){ grep -qE '(```|~~~)[^#]*#' "$1"; }

##	A carriage return with more text after it on its line. At a piece's edge it
##	was content to 2.x and is trimmed now; in the middle of a piece it reads the
##	same either way, and the corpus pins that, so matching loosely costs little.
fCrMidLine(){ grep -q $'\r[^\r]' "$1"; }

##	An indent 2.x placed and the current rules do not. A decrease has to return
##	to the exact column of an ancestor now, so a tab followed by a space-tab, or
##	by two spaces, bound in 2.x and is `E012` here. `migrate` rewrites spellings
##	and not layout, so the line is left as written and the reading differs by
##	design. Nothing is damaged quietly: a load that dropped the line makes
##	`migrate --write` and `fmt --write` refuse at exit 7. Asked of the current
##	parser rather than matched on the text, since what counts is the column the
##	indent lands on and not which characters spell it.
fUnplaced(){
	{ "${newCli}" check "$1" 2>/dev/null || true; } | awk '$1 == "line" && $4 == "E012" { sub(/:$/, "", $2); print $2 }'
}

##	Takes out every line above, until 2.x reads what is left cleanly. Fails
##	when nothing is left, or when taking lines out keeps turning up more. The
##	first round has the same bytes as the source, so it takes the source's
##	2.x check as given rather than running it again.
fTrim(){
	local src="$1" dst="$2" check2x="$3" lines round
	cp "${src}" "${dst}"
	for round in 1 2 3 4; do
		((round == 1)) || check2x="$(fCheck2x "${dst}")"
		lines="$( { fUnclean2x <<<"${check2x}"
			fUnplaced "${dst}"
			grep -anE '(```|~~~)[^#]*#' "${dst}" | cut -d: -f1
			grep -an $'\r[^\r]' "${dst}" | cut -d: -f1; } | sort -un)"
		if [[ -z "${lines}" ]]; then [[ -s "${dst}" ]]; return; fi
		sed "${lines//$'\n'/d;}d" "${dst}" > "${dst}.next"
		mv "${dst}.next" "${dst}"
	done
	return 1
}

declare -i nCompared=0 nCorpus=0 nTrimmed=0 nSkipped=0 nBad=0 nLostChecked=0
fTest Eq5YPgP corpus and fuzz documents migrate to the tree 2.x read
for f in "${corpus}"/*/input.shcl "${dump}"/*.shcl; do
	[[ -f "${f}" ]] || continue
	name="${f%/input.shcl}"; name="${name##*/}"
	if fHasNul "${f}"; then nSkipped+=1; continue; fi
	## Every document here is a 2.x file by construction, which is exactly what
	## migrate cannot read off the text: without the flag it leaves the pieces
	## the two rule sets disagree on and refuses.
	## When the one thing wrong with the file under 2.x is bracket arrays,
	## migrate has to refuse over each of them and nothing else.
	check2x="$(fCheck2x "${f}")"
	unclean="$(fUnclean2x <<<"${check2x}" | sort -un)"
	arrays="$(awk '$1 == "line" && $3 == "Error:" && $4 == "E019" { sub(/:$/, "", $2); print $2 }' <<<"${check2x}" | sort -un)"
	if [[ -n "${unclean}" && "${unclean}" == "${arrays}" ]]; then
		wantLost="$(wc -l <<<"${unclean}")"
		gotLost="$({ "${newCli}" migrate --from-2x "${f}" 2>&1 >/dev/null || true; } \
			| sed -n 's/.*: \([0-9][0-9]*\) line(s) bound a value under 2\.x.*/\1/p')"
		nLostChecked+=1
		if [[ "${gotLost:-0}" != "${wantLost}" ]]; then
			nBad+=1
			echo "check-migrate: DIVERGE ${name}: 2.x refused ${wantLost} bracket array(s), migrate counted ${gotLost:-0} lost"
		fi
	fi
	if ! fTrim "${f}" "${tmpDir}/original.shcl" "${check2x}"; then nSkipped+=1; continue; fi
	cmp -s "${f}" "${tmpDir}/original.shcl" || nTrimmed+=1
	f="${tmpDir}/original.shcl"
	rc=0; "${newCli}" migrate --from-2x "${f}" > "${tmpDir}/migrated.shcl" 2>/dev/null || rc=$?
	if ((rc != 0)); then
		nBad+=1
		echo "check-migrate: DIVERGE ${name}: 2.x read it cleanly, and migrate exited ${rc}"
	fi
	old="$(fReadTree "${oldCli}" "${f}")"
	want="$(fAge2xReads <<<"${old}")"
	got="$(fReadTree "${newCli}" "${tmpDir}/migrated.shcl")"
	nCompared+=1; [[ "${name}" == fuzz_* ]] || nCorpus+=1
	if [[ "${want}" != "${got}" ]]; then
		nBad+=1
		echo "check-migrate: DIVERGE ${name}: the 2.x reads of the original and the current reads of the migrated text differ"
		diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | head -12 || true
	fi
	old2="$(fReadTree "${oldCli}" "${tmpDir}/migrated.shcl")"
	if [[ "${old}" != "${old2}" ]]; then
		nBad+=1
		echo "check-migrate: DIVERGE ${name}: the 2.x reads of the original and of the migrated text differ"
		diff <(printf '%s\n' "${old}") <(printf '%s\n' "${old2}") | head -12 || true
	fi
done

##	Each named case has to keep carrying its shape, or the exception is stale.
fTest EpUIoZd 068 still carries a fence label holding a hash
fInfoHashLabel "${corpus}/068-info-hash-spellings/input.shcl" 2>/dev/null \
	|| { echo "check-migrate: 068-info-hash-spellings no longer carries a fence label holding a #" >&2; nBad+=1; }
fTest EpUIoZe 094 still carries a mid-line carriage return
fCrMidLine "${corpus}/094-unicode-space/input.shcl" 2>/dev/null \
	|| { echo "check-migrate: 094-unicode-space no longer carries a mid-line carriage return" >&2; nBad+=1; }
##	The third has no corpus case - a new one shifts the fuzz seed set, which
##	costs a gate round - so it is checked against a document built here: 2.x
##	reads both elements, the current parser places only the first, and the write
##	half refuses rather than dropping the second quietly.
printf 'list:\n\t* one\n \t* two\n' > "${tmpDir}/indent.shcl"
fTest EqRiIDw the loose-indent exception fires on a space before a tab
[[ "$(fUnplaced "${tmpDir}/indent.shcl")" == 3 ]] \
	|| { echo "check-migrate: the loose-indent exception no longer fires on a space before a tab" >&2; nBad+=1; }
fTest EqRiIDx 2.x reads both elements of the loose-indent document
[[ "$("${oldCli}" get --string --array "${tmpDir}/indent.shcl" list 2>/dev/null | wc -l)" == 2 ]] \
	|| { echo "check-migrate: 2.x no longer reads both elements of the loose-indent document" >&2; nBad+=1; }
fTest EqRiIDy a rewrite of the loose-indent document is refused at 7
indentRc=0
"${newCli}" migrate --from-2x --write "${tmpDir}/indent.shcl" >/dev/null 2>&1 || indentRc=$?
((indentRc == 7)) \
	|| { echo "check-migrate: a rewrite of the loose-indent document exited ${indentRc}, not the refusal 7" >&2; nBad+=1; }
fTestEnd
if ((nCompared < minCompared || nCorpus < minCorpus || nCompared - nCorpus < minFuzz)); then
	echo "check-migrate: only ${nCompared} document(s) compared, ${nCorpus} of them corpus cases and $((nCompared - nCorpus)) fuzz-dumped; need ${minCompared}, ${minCorpus} and ${minFuzz} (${nSkipped} skipped)" >&2
	exit 2
fi
if ((nBad)); then
	echo "check-migrate: ${nBad} divergence(s) over ${nCompared} document(s) (${nSkipped} skipped)" >&2
	exit 1
fi
echo "check-migrate: OK: ${nCompared} document(s) migrate to the tree 2.x read, ${nCorpus} corpus cases, $((nCompared - nCorpus)) fuzz-dumped and ${nTrimmed} with lines taken out first; ${nLostChecked} lost count(s) match; ${nSkipped} skipped"

##	History:
##		2026-09-08  Created with the 3.0 lexical cut, pinned on the funnel merge.
##		2026-09-15  The 2.x build reads the migrated text too.
##		2026-09-16  Lines 2.x could not read come out rather than the whole
##		            document; exit code, lost count and a corpus floor checked.
##		2026-09-18  A floor for the fuzz half and an empty dump refused, after a
##		            dump that wrote nothing passed on the corpus alone.
##		2026-09-20  An indent the current parser places nowhere comes out too, and
##		            the exception is checked against a document built here.
