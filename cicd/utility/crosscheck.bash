#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately.' Cumbersome and unnecessary here.

##	Purpose:
##		Cross-binding differential check: every shipped binding must agree with
##		every other, byte for byte, on the same inputs - not just each pass the
##		corpus on its own. The first binding listed is the reference (Rust); each
##		other binding's CLI is run over the conformance corpus (canonical `fmt` of
##		every input.shcl, plus every reads.tsv row replayed as a `get`/`count`/
##		`instances` call) and, when given, over an extra directory of fuzz-dumped
##		inputs (`fmt` only). stdout and exit code must both match the reference.
##		The dump's eol/ folder holds inputs with mixed line endings, each with a
##		write-ops script; each goes through `set --write`, the save that keeps
##		lines, and the file it leaves must match byte for byte. Its kept/ folder
##		is the same, over lines kept as written and edits near them, so a
##		binding that loses one where the reference refuses shows here.
##		With fewer than two bindings there is nothing to compare - prints a note
##		and exits 0, so it can stay wired into cicd from day one.
##	Syntax:
##		crosscheck.bash --corpus DIR [--extra DIR] [--min N] NAME|CLI [NAME|CLI ...]
##		  --corpus DIR  conformance corpus root (case dirs with input.shcl etc.)
##		  --extra DIR   also compare `fmt` over every *.shcl in this directory,
##		                and the keep save over every *.shcl in DIR/eol and
##		                DIR/kept, with its *.ops beside it. Either folder
##		                missing fails under SHCL_GATE_STRICT and is noted in
##		                SHCL_GATE_SKIPS otherwise
##		  --min N       fail unless at least N comparisons ran (default 1, so a
##		                collapsed corpus/dump can't pass on zero)
##		  NAME|CLI      binding name + its CLI path; first entry is the reference
##		CPU_CAP in the environment sets how many workers share the work (default
##		half the cores).
##	Exit: 0 all agree, 1 divergence, 2 usage/missing input or too few comparisons.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=crosscheck; testCounter=nKindBad

corpus=""; extra=""; bindings=(); declare -i minCompared=1
## A setter's note on a kept line it comments out has the local time in it,
## and the four runs are not in the same second.
export SHCL_TEST_CLOCK="2026-10-04 00:15:00 -420 PDT"
while (($#)); do case "$1" in
	--corpus)  corpus="${2:-}"; shift 2 ;;
	--extra)   extra="${2:-}"; shift 2 ;;
	--min)     minCompared="${2:-1}"; shift 2 ;;
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         bindings+=("$1"); shift ;;
esac; done

[[ -d "$corpus" ]] || { echo "crosscheck: no corpus dir: $corpus" >&2; exit 2; }
tmpDir="$(mktemp -d)"; trap 'rm -rf "$tmpDir"' EXIT
if ((${#bindings[@]} < 2)); then
	echo "crosscheck: ${#bindings[@]} binding(s) configured - differential comparison activates when a second binding arrives"
	exit 0
fi
for b in "${bindings[@]}"; do
	cli="${b#*|}"
	[[ -x "$cli" ]] || { echo "crosscheck: binding CLI not executable: $cli" >&2; exit 2; }
done

refName="${bindings[0]%%|*}"; refCli="${bindings[0]#*|}"
declare -i nCompared=0 nBad=0

##	Run one CLI invocation, leaving "<code>\n<stdout>" in runOut. stderr is
##	dropped: diagnostics wording is per-binding voice, not contract. stdout goes
##	through a file and a builtin read rather than $(...): a substitution strips
##	trailing newlines, so a dropped or doubled final one would be invisible, and
##	it would cost two more forks per launch on top of the CLI's own - there are
##	about eight thousand launches in a run.
runOut=""
fRun(){
	local cli="$1"; shift
	local rc=0
	"$cli" "$@" >"${tmpDir}/run.out" 2>/dev/null || rc=$?
	fReadOut "$rc"
}

##	Like fRun, but feeds a file to stdin (the `set` write-ops script).
fRunStdin(){
	local cli="$1" stdinFile="$2"; shift 2
	local rc=0
	"$cli" "$@" <"$stdinFile" >"${tmpDir}/run.out" 2>/dev/null || rc=$?
	fReadOut "$rc"
}

##	read -d '' takes the file whole, trailing newlines included, and returns 1
##	at EOF, which is the normal end here. A NUL in stdout ends the read early -
##	the same limit $(...) had, since a bash string cannot hold one.
fReadOut(){
	local out=""
	IFS= read -r -d '' out <"${tmpDir}/run.out" || true
	runOut="$1"$'\n'"${out}"
}

##	Compare every other binding against the reference for one stdin-fed call.
fCompareStdin(){
	local what="$1" stdinFile="$2"; shift 2
	local want got b name cli
	fRunStdin "$refCli" "$stdinFile" "$@"; want="${runOut}"
	for b in "${bindings[@]:1}"; do
		name="${b%%|*}"; cli="${b#*|}"
		fRunStdin "$cli" "$stdinFile" "$@"; got="${runOut}"
		nCompared+=1
		if [[ "$got" != "$want" ]]; then
			nBad+=1
			echo "DIVERGE ${what}: ${name} vs ${refName} (shcl $* <${stdinFile})"
			diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -12 || true
		fi
	done
}

##	Compare every other binding against the reference for one invocation.
fCompare(){
	local what="$1"; shift
	local want got b name cli
	fRun "$refCli" "$@"; want="${runOut}"
	for b in "${bindings[@]:1}"; do
		name="${b%%|*}"; cli="${b#*|}"
		fRun "$cli" "$@"; got="${runOut}"
		nCompared+=1
		if [[ "$got" != "$want" ]]; then
			nBad+=1
			echo "DIVERGE ${what}: ${name} vs ${refName} (shcl $*)"
			diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -12 || true
		fi
	done
}

##	Describe a tree so an in-place write can be compared by its side effects.
##	One sorted line per path: relative name, type, mode, link count, symlink
##	target, content. Anything the writer leaves behind (a stray temp file, a
##	replaced symlink, a widened mode) shows up as a diff. Into writeState, not
##	stdout: this runs once per binding per write, and a stat and a tr per path
##	plus the substitution around it were most of the write dimension's time.
##	A NUL in a file shows as <NUL>, where a substitution used to drop it.
writeState=""
fWriteState(){
	local root="$1" rel type mode links dest part content
	writeState=""
	while IFS=$'\t' read -r rel type mode links dest; do
		case "$type" in
			l) writeState+="${rel}"$'\t'"symlink -> ${dest}"$'\n' ;;
			d) writeState+="${rel}"$'\t'"directory mode=${mode}"$'\n' ;;
			f)
				content="" part=""
				while IFS= read -r -d '' part; do content+="${part}<NUL>"; done <"${root}/${rel}" || true
				content+="${part}"
				writeState+="${rel}"$'\t'"file mode=${mode} links=${links}"$'\t'"${content//$'\n'/|}"$'\n'
				;;
			*) writeState+="${rel}"$'\t'"type=${type} mode=${mode} links=${links}"$'\n' ;;
		esac
	done < <(find "$root" -mindepth 1 -printf '%P\t%y\t%m\t%n\t%l\n' | sort)
}

##	A fresh, empty root per binding per call, all made by one mkdir. The
##	counter keeps them apart, so nothing has to be removed first.
nRoots=0
fMakeRoots(){
	local kind="$1" b
	nRoots=$((nRoots + 1))
	roots=()
	for b in "${bindings[@]}"; do roots+=("${tmpDir}/${kind}${nRoots}-${b%%|*}"); done
	mkdir -p "${roots[@]}"
}

##	The write reads its edits from this file on stdin when it is set.
writeStdin=""
fRunWrite(){
	if [[ -n "$writeStdin" ]]; then fRunStdin "$1" "$writeStdin" "${@:2}"; else fRun "$@"; fi
}

##	Compare the filesystem side effects of an in-place write, not just stdout.
##	The writer publishes a new inode, so it can silently drop the target's mode
##	or replace a symlink with a regular file - neither of which a stdout compare
##	can see. fixture builds a fresh tree under $1 and echoes the path to pass the
##	CLI; every binding gets its own identical copy.
fCompareWrite(){
	local what="$1" fixture="$2"; shift 2
	local want got b name cli i=0
	fMakeRoots write
	"$fixture" "${roots[0]}"
	# The exit code rides along: a write that refuses leaves the tree alone, so
	# the state compare alone cannot tell a refusal from a no-op success.
	fRunWrite "$refCli" "$@" "$fixTarget"; fWriteState "${roots[0]}"; want="${runOut}${writeState}"
	for b in "${bindings[@]:1}"; do
		name="${b%%|*}"; cli="${b#*|}"; i=$((i + 1))
		"$fixture" "${roots[i]}"
		fRunWrite "$cli" "$@" "$fixTarget"; fWriteState "${roots[i]}"; got="${runOut}${writeState}"
		nCompared+=1
		if [[ "$got" != "$want" ]]; then
			nBad+=1
			echo "DIVERGE ${what}: ${name} vs ${refName} (shcl $* <fixture>)"
			diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -12 || true
		fi
	done
}

##	Same idea, for the one write property a fixture cannot set up in advance:
##	the temp file's name includes the writer's pid, so the decoy can only be
##	planted by the process that is about to become the CLI. `exec` from a
##	subshell hands the CLI that subshell's pid, so `$$` names the file it is
##	about to create. Writing through the decoy would leave `stolen` behind and
##	turn the target into a symlink; both show up in the state compare. The decoy
##	itself is removed before comparing, since its name holds a per-run pid.
fPlantRun(){
	local root="$1" cli="$2"; shift 2
	bash -c 'r="$1"; c="$2"; shift 2; ln -sfn "${r}/stolen" "${r}/.c.shcl.tmp$$.0"; exec "$c" "$@"' _ "$root" "$cli" "$@" >/dev/null 2>&1 || true
	find "$root" -maxdepth 1 -type l -name '.c.shcl.tmp*' -delete
}

fComparePlant(){
	local what="$1"; shift
	local want got b name cli i=0
	fMakeRoots plant
	fFixMode "${roots[0]}"
	fPlantRun "${roots[0]}" "$refCli" "$@" "$fixTarget"
	fWriteState "${roots[0]}"; want="${writeState}"
	for b in "${bindings[@]:1}"; do
		name="${b%%|*}"; cli="${b#*|}"; i=$((i + 1))
		fFixMode "${roots[i]}"
		fPlantRun "${roots[i]}" "$cli" "$@" "$fixTarget"
		fWriteState "${roots[i]}"; got="${writeState}"
		nCompared+=1
		if [[ "$got" != "$want" ]]; then
			nBad+=1
			echo "DIVERGE ${what}: ${name} vs ${refName} (shcl $* <fixture>)"
			diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -12 || true
		fi
	done
}

##	Fixtures for fCompareWrite. Each builds its tree and sets fixTarget to the
##	path to hand the CLI, rather than echoing it, which would cost a subshell
##	per binding per write. The unformatted spacing is deliberate: the write must actually
##	rewrite the file, or the checks below prove nothing.
fixTarget=""
fFixMode(){    printf 'a:  1\n' >"$1/c.shcl"; chmod 600 "$1/c.shcl"; fixTarget="$1/c.shcl"; }
fFixSymlink(){ mkdir -p "$1/real"; printf 'a:  1\n' >"$1/real/c.shcl"; ln -s real/c.shcl "$1/c.shcl"; fixTarget="$1/c.shcl"; }
fFixHardlink(){ printf 'a:  1\n' >"$1/c.shcl"; ln "$1/c.shcl" "$1/other.shcl"; fixTarget="$1/c.shcl"; }
##	A link to a file that is not there yet: the write must create the target
##	behind the link, not turn the link into a file.
fFixDangling(){ mkdir -p "$1/real"; ln -s real/c.shcl "$1/c.shcl"; fixTarget="$1/c.shcl"; }
##	Nothing at the path at all - the create case. The tree it leaves behind is
##	the whole point, so the fixture deliberately builds nothing.
fFixAbsent(){  fixTarget="$1/c.shcl"; }
##	The corpus case's own input, copied in so the write has something real to
##	refuse or rewrite. The fixture protocol takes only the root, so the source
##	arrives in caseSrc.
caseSrc=""
fFixCase(){    install -m 600 "$caseSrc" "$1/c.shcl"; fixTarget="$1/c.shcl"; }
##	A load that dropped a line canonical output cannot re-emit (a BOM-led one),
##	so the in-place write is the destructive case the save gate exists for.
fFixLost(){    printf 'a:  1\n\xef\xbb\xbfb: 2\n' >"$1/c.shcl"; chmod 600 "$1/c.shcl"; fixTarget="$1/c.shcl"; }

##	Map one reads.tsv row to a CLI call. Columns: query, type, expected, status,
##	optional level. expected/status are the corpus contract (each binding's own
##	conformance runner asserts those); here only binding-vs-binding agreement
##	matters, so the row is just a recipe for an invocation.
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
		load)         fCompare "load" check "${strictArg[@]}" "$input"
		              fCompare "fmt ${level:-standard}" fmt "${strictArg[@]}" "$input" ;;
		count)        fCompare "count ${query}" count "${strictArg[@]}" "$input" "$query" ;;
		instances)    fCompare "instances ${query}" instances "${strictArg[@]}" "$input" "$query" ;;
		children)     fCompare "children ${query}" children "${strictArg[@]}" "$input" "$query" ;;
		paths)        fCompare "paths" paths "${strictArg[@]}" "$input" ;;
		lost)         : ;;   ## no CLI surface; the in-place write below is what it reaches
		instance_paths|comments|schema) : ;; ## library only; the four runners pin it
		int'[]'|float'[]'|bool'[]'|datetime'[]'|string'[]')
		              fCompare "get ${query} ${type}" get "--${type%[]}" --array "${strictArg[@]}" "$input" "$query"
		              fCompare "get ${query} ${type} slots" get "--${type%[]}" --array --slots "${strictArg[@]}" "$input" "$query" ;;
		int|float|bool|datetime|string|raw|rawinfo)
		              fCompare "get ${query} ${type}" get "--${type}" "${strictArg[@]}" "$input" "$query"
		              # on-bad=error (exit-code differential; message goes to dropped stderr)
		              # and a default substitution (stdout differential) - the accessor
		              # policy surface, where hand-written ports diverge most easily.
		              fCompare "get ${query} ${type} on-bad=error" get "--${type}" --on-bad=error "${strictArg[@]}" "$input" "$query"
		              fCompare "get ${query} ${type} default" get "--${type}" "--default=<x>" "${strictArg[@]}" "$input" "$query" ;;
		## duration[@UNIT] and size[@UNIT][+decimal]: the unit a bare number
		## takes when its name gives none, and KB to TB in powers of 1000.
		duration*|size*)
		              local -a unitArg=()
		              local base="${type%%[@+]*}" rest="${type#"${type%%[@+]*}"}"
		              if [[ "$rest" == *+decimal ]]; then unitArg+=(--decimal); rest="${rest%+decimal}"; fi
		              if [[ "$rest" == @* ]]; then unitArg+=("--unit=${rest#@}"); fi
		              fCompare "get ${query} ${type}" get "--${base}" "${unitArg[@]}" "${strictArg[@]}" "$input" "$query"
		              fCompare "get ${query} ${type} on-bad=error" get "--${base}" "${unitArg[@]}" --on-bad=error "${strictArg[@]}" "$input" "$query"
		              fCompare "get ${query} ${type} default" get "--${base}" "${unitArg[@]}" "--default=<x>" "${strictArg[@]}" "$input" "$query" ;;
		## A row type with no arm used to fall through to `get --<type>`, which
		## every binding refuses the same way - so the row compared nothing.
		*)            echo "crosscheck: unknown reads.tsv type: ${type}" >&2; exit 2 ;;
	esac
}

##	bash variables cannot hold a NUL, so a captured stdout would drop it. read
##	-d '' stops at a NUL and returns 0 only when it found one, so this probes a
##	file for one with no fork.
fHasNul(){ IFS= read -r -d '' _ <"$1"; }

##	One corpus case, every dimension it has.
fCase(){
	local caseDir="$1"
	local input="${caseDir}input.shcl" caseName="${caseDir%/}"
	caseName="${caseName##*/}"
	fCompare "fmt ${caseName}" fmt "$input"
	# The lexical view and the 2.x rewrite: the tokenizer is the one reader
	# of a line's parts, so its spans are the finest-grained parity there is,
	# and migrate reads through the same tokenizer's 2.x flag. Both answers to
	# "was this written for 2.x" are compared: they take different arms, and
	# the default one refuses where the flag rewrites.
	fCompare "tokens ${caseName}" tokens "$input"
	fCompare "migrate ${caseName}" migrate "$input"
	fCompare "migrate --from-2x ${caseName}" migrate --from-2x "$input"
	# The save gate over real inputs: a case whose load dropped something must
	# refuse the in-place write and leave the file byte-identical, and one that
	# dropped nothing must rewrite it. Nothing else replays a corpus input
	# through --write, so a lost count that stops being kept goes unseen.
	caseSrc="$input"; fCompareWrite "fmt --write ${caseName}" fFixCase fmt --write
	# Write dimension: apply the case's ops script and compare canonical output.
	ops="${caseDir}write.ops"
	[[ -f "$ops" ]] && fCompareStdin "set ${caseName}" "$ops" set "$input"
	fKeepEdits "$input" "$caseName" 3
	# Bad-op dimension: each write-bad.ops line, applied alone, must produce the
	# same (empty) stdout and same nonzero exit in every binding.
	badops="${caseDir}write-bad.ops"
	if [[ -f "$badops" ]]; then
		badN=0
		while IFS= read -r bline || [[ -n "$bline" ]]; do
			[[ -z "$bline" || "$bline" == \#* ]] && continue
			badN=$((badN+1))
			printf '%s\n' "$bline" > "${tmpDir}/badop.line"
			fCompareStdin "set-bad ${caseName} line ${badN}" "${tmpDir}/badop.line" set "$input"
		done < "$badops"
	fi
	# Layered-load dimension: replay `fmt` with the case's layer*.shcl merged under
	# input.shcl (filename order = priority) plus any merge.sets --set overrides.
	if [[ -f "${caseDir}expected-merged.shcl" ]]; then
		layerArgs=()
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
		fCompare "merge ${caseName}" fmt "${layerArgs[@]}" "${setArgs[@]}" "$input"
	fi
	# Schema dimension: replay check --schema (codes + summary + exit are the contract).
	schema="${caseDir}schema.shcl"
	[[ -f "$schema" ]] && fCompare "check --schema ${caseName}" check "--schema=${schema}" "$input"
	# Generation dimension: replay init --schema (the generated starter is the
	# contract), both with the format footer and with --no-banner.
	initschema="${caseDir}init-schema.shcl"
	if [[ -f "$initschema" ]]; then
		fCompare "init ${caseName}" init "--schema=${initschema}"
		fCompare "init --no-banner ${caseName}" init --no-banner "--schema=${initschema}"
	fi
	tsv="${caseDir}reads.tsv"
	if [[ -f "$tsv" ]]; then
		while IFS= read -r row || [[ -n "$row" ]]; do
			[[ -z "$row" || "$row" == query$'\t'* ]] && continue
			fSplitTabs "$row"
			query="${cols[0]}"; type="${cols[1]}"; level="${cols[4]:-}"
			fReadRow "$input" "$query" "$type" "${level:-}"
		done < "$tsv"
	fi
}

##	The save that keeps lines over one input: a changed value, a new child and
##	a removal on the first few paths the reference reports, each compared as
##	set's output. The corpus goldens hold only the shapes somebody wrote down.
fKeepEdits(){
	local f="$1" label="$2" max="$3" p k=0
	while IFS= read -r p; do
		[[ -z "$p" ]] && continue
		k=$((k+1))
		if ((k > max)); then break; fi
		fCompare "set keep ${label} ${p}" set "--set=${p}=new text" "$f"
		fCompare "set keep-add ${label} ${p}" set "--set=${p}.kid=1" "$f"
		fCompare "set keep-remove ${label} ${p}" set "--remove=${p}" "$f"
	done < <("$refCli" paths "$f" 2>/dev/null || true)
}

##	One fuzz-dumped input.
fExtraFile(){
	local f="$1" reads
	fCompare "fmt ${f##*/}" fmt "$f"
	fCompare "tokens ${f##*/}" tokens "$f"
	fCompare "migrate ${f##*/}" migrate "$f"
	fCompare "migrate --from-2x ${f##*/}" migrate --from-2x "$f"
	# The save gate over the soup as well: whether a load counted anything
	# lost is the one parse result no read can show, and the corpus alone
	# holds only the shapes somebody thought to pin.
	caseSrc="$f"; fCompareWrite "fmt --write ${f##*/}" fFixCase fmt --write
	fKeepEdits "$f" "${f##*/}" 1
	# Derived reads.tsv (the reference dumps one per input, paths it knows exist):
	# replay the accessor rows too, so the fuzz set covers reads, not just fmt.
	reads="${f%.shcl}.reads.tsv"
	if [[ -f "$reads" ]]; then
		while IFS=$'\t' read -r query type _expected _status level _rest || [[ -n "$query" ]]; do
			[[ -z "$query" || "$query" == "query" ]] && continue
			fReadRow "$f" "$query" "$type" "${level:-}"
		done < "$reads"
	fi
}

##	One input with mixed line endings and its edits. The keep save ends each
##	line by a rule the reference's fuzz checks; this holds the other three to
##	the same bytes on disk, which a stdout compare would see only in part.
##	The kept/ folder goes through here too, with its own label.
fEolFile(){
	local f="$1" label="${2:-keep save}"
	caseSrc="$f"; writeStdin="${f%.shcl}.ops"
	fCompareWrite "${label} ${f##*/}" fFixCase set --write
	writeStdin=""
}

##	Everything that is not one input: the usage text, the fixture writes and the
##	float spelling.
fUsage(){
	# Usage surface: help/version/bare/unknown are the largest user-visible output
	# in the project and are hand-duplicated per CLI, so pin them here too.
	fCompare "usage help" help
	fCompare "usage help flag" --help
	fCompare "usage version" version
	fCompare "usage bare"
	fCompare "usage unknown" definitely-not-a-subcommand
	# The diagnostic code table and the per-subcommand help are hand-duplicated per
	# CLI the way the help text is, and both are long. Every code and every
	# subcommand is compared, since one entry going stale in one binding is the
	# exact shape a four-way diff exists to catch. The code list comes from the
	# reference's own listing, so a code added there is compared without a second
	# list to keep in step.
	fCompare "usage explain list" explain
	fCompare "usage explain unknown code" explain E999
	while read -r code; do
		fCompare "usage explain ${code}" explain "${code}"
	done < <("$refCli" explain | { grep -oE '^[EHV][0-9]+' || true ;})
	while read -r cmd; do
		fCompare "usage help ${cmd}" help "${cmd}"
		fCompare "usage ${cmd} --help" "${cmd}" --help
	done < <("$refCli" help | { grep -oE '^  shcl [a-z]+' || true ;} | awk '{print $2}' | sort -u)
	# about/donate have both spellings and the blank-line padding; bare help above
	# is the control, since it prints the same text with no padding.
	fCompare "usage about" about
	fCompare "usage about flag" --about
	fCompare "usage donate" donate
	fCompare "usage donate flag" --donate

	# In-place writes: the rename that makes them atomic also replaces the inode, so
	# these pin what the target keeps. Mode must survive (config files hold secrets)
	# and a symlinked config must be written through, not replaced. The hard-link
	# case pins the documented limitation: rename cannot preserve the other name.
	fCompareWrite "write keeps mode" fFixMode fmt --write
	fCompareWrite "write follows symlink" fFixSymlink fmt --write
	fCompareWrite "write creates behind a dangling symlink" fFixDangling set --write --set=a=1
	fCompareWrite "write breaks hard link" fFixHardlink fmt --write
	fComparePlant "write refuses a planted temp" fmt --write

	# The save gate, from the CLI side. Refusing leaves the file byte-identical, so
	# the tree compare is what sees it; --lossy is the only way past.
	fCompareWrite "write refuses to drop a line" fFixLost fmt --write
	fCompareWrite "write --lossy drops it anyway" fFixLost fmt --write --lossy
	fCompareWrite "set --write refuses to drop a line" fFixLost set --write --set a=2
	fCompareWrite "set --write --lossy drops it anyway" fFixLost set --write --lossy --set a=2
	fCompare "--lossy needs --write" fmt --lossy missing.shcl
	fCompare "--lossy is not valid for get" get --lossy missing.shcl a

	# `set --write --set` persists edits given as options and reads no ops from
	# stdin, so nothing here feeds one. The gates around it are pinned too: --layer
	# still cannot be written back anywhere, and --set stays ephemeral off 'set'.
	fCompareWrite "set --write applies --set" fFixMode set --write --set a=2
	fCompareWrite "set --write --set adds a path" fFixMode set --write --set b.c=hello
	fCompare "set --write rejects --layer" set --write --layer=missing.shcl missing.shcl
	fCompare "fmt --write rejects --set" fmt --write --set a=1 missing.shcl
	# `set --write` on a FILE that is not there yet creates it; `fmt --write` has
	# nothing to format and still refuses. The state compare covers the created
	# file's mode too, which is umask-derived and so must match across bindings.
	fCompareWrite "set --write creates a missing file" fFixAbsent set --write --set a=1
	fCompareWrite "fmt --write still refuses a missing file" fFixAbsent fmt --write

	# Float spelling: shortest-round-trip formatters may lawfully differ at a
	# power of two (a lopsided rounding interval) and on an exact tie between two
	# spellings of the shortest length. Every power of two, plus a fixed set of
	# random doubles built as exact m * 2^e so the text reads back to the double
	# it names, through a float write in each binding.
	awk 'BEGIN{
		## 2^e by exact halving and doubling from 1. `2 ^ e` is not a portable way
		## to reach a subnormal: gawk computes a negative power as 1/(2^1074),
		## which is 1/inf, so every subnormal row came out 0 and tested nothing.
		v = 1;
		for (e = 0; e <= 1023; e++) { pw[e] = v; v = v * 2 }
		v = 1;
		for (e = -1; e >= -1074; e--) { v = v / 2; pw[e] = v }
		for (e = -1074; e <= 1023; e++) printf "float\tp%d\t%.17g\n", e + 1074, pw[e];
		## A fixed integer generator rather than srand()/rand(), whose sequence
		## differs between awks - so the "fixed" random set was a different set on
		## every runner. Every product here stays under 2^53, so it is exact.
		s = 20260902;
		for (i = 0; i < 3000; i++) {
			s = (16807 * s) % 2147483647; a = s % 131072;
			s = (16807 * s) % 2147483647; b = s % 131072;
			s = (16807 * s) % 2147483647; c = s % 131072;
			s = (16807 * s) % 2147483647;
			m = (a * 131072 + b) * 131072 + c;
			e = (s % 1900) - 1000;
			printf "float\tr%d\t%.17g\n", i, m * pw[e];
		}
	}' > "${tmpDir}/floats.ops"
	fCompareStdin "float spelling" "${tmpDir}/floats.ops" set -

	# `set -` follows stdin, so the same spelling means two things and both are
	# pinned: the piped document when an option holds the edits, an empty base when
	# stdin is the ops script instead.
	printf 'int\tx\t7\n' >"${tmpDir}/emptybase.ops"
	fCompareStdin "set - reads the piped document" project/conformance/044-write-literal/input.shcl set - --set b=2
	fCompareStdin "set - is an empty base for ops" "${tmpDir}/emptybase.ops" set -

	# --set-literal takes value syntax, so the same text reads as an array where
	# --set stores one quoted string; the pair is compared to pin that difference.
	# The rejections are the parser's own, so they have to agree with it.
	fCompareWrite "set --write applies --set-literal" fFixMode set --write --set-literal 'a=80, 443'
	fCompare "set --set-literal array" set --set-literal 'a=80, 443' project/conformance/044-write-literal/input.shcl
	fCompare "set --set quotes the same text" set --set 'a=80, 443' project/conformance/044-write-literal/input.shcl
	fCompare "set --set-literal keeps a quoted element" set --set-literal 'a="x, y", z' project/conformance/044-write-literal/input.shcl
	fCompare "set --set-literal rejects an open quote" set --set-literal 'a="oops' project/conformance/044-write-literal/input.shcl
	fCompare "set --set-literal wants PATH=VALUE" set --set-literal noequals project/conformance/044-write-literal/input.shcl
}

##	The work, as units a worker takes whole: the usage block, each corpus case
##	and each fuzz input. Most of the run is CLI start-up, Python's above all, and
##	nothing is shared between units but the read-only inputs, so the units go
##	round-robin to CPU_CAP background workers, half the cores by default. Each
##	worker has its own scratch directory and leaves its counts in a file there;
##	one with no counts file did not finish, and fails the run.
units=(usage)
## The usage block always compares, so the floor at the end cannot see a
## corpus with no case in it.
caseDirs=("$corpus"/*/)
[[ -d "${caseDirs[0]}" ]] || { echo "crosscheck: no case directories under ${corpus}" >&2; exit 2; }
for caseDir in "${caseDirs[@]}"; do
	## A case directory with no input.shcl is a mistake, not a non-case.
	[[ -f "${caseDir}input.shcl" ]] || { echo "crosscheck: ${caseDir} has no input.shcl" >&2; exit 2; }
	# NUL-bearing cases (e.g. the merge-key NUL case) are pinned by the native
	# conformance runners instead; skip them here, out loud.
	if fHasNul "${caseDir}input.shcl"; then
		caseName="${caseDir%/}"
		echo "crosscheck: skipping ${caseName##*/} (NUL in input; native runners pin it)"
		continue
	fi
	units+=("case|${caseDir}")
done
if [[ -n "$extra" && -d "$extra" ]]; then
	declare -i nExtra=0
	for f in "$extra"/*.shcl; do
		[[ -e "$f" ]] || continue
		nExtra+=1
		# Same NUL limitation as the corpus loop; silently skip (a dump can be large).
		if fHasNul "$f"; then continue; fi
		units+=("extra|${f}")
	done
	if ((nExtra == 0)); then
		echo "crosscheck: --extra ${extra} matched no *.shcl (empty fuzz dump?)" >&2
		exit 2
	fi
	## The fuzz dump writes both folders, so one that is not there is a dump that
	## stopped writing it, and the keep saves it holds go unchecked.
	for kind in eol kept; do
		if [[ ! -d "${extra}/${kind}" ]]; then
			if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
				echo "crosscheck: ${extra} has no ${kind}/ folder (keep-save dump missing?), and the gate requires it" >&2
				exit 2
			fi
			echo "crosscheck: skipping the ${kind}/ keep saves (no ${extra}/${kind})"
			echo "crosscheck ${kind}" >> "${SHCL_GATE_SKIPS:-/dev/null}"
			continue
		fi
		nExtra=0
		for f in "${extra}/${kind}"/*.shcl; do
			[[ -e "$f" ]] || continue
			[[ -f "${f%.shcl}.ops" ]] || { echo "crosscheck: ${f} has no .ops beside it" >&2; exit 2; }
			nExtra+=1
			units+=("${kind}|${f}")
		done
		if ((nExtra == 0)); then
			echo "crosscheck: ${extra}/${kind} matched no *.shcl (empty keep-save dump?)" >&2
			exit 2
		fi
	done
fi

##	Divergences are counted per kind of unit too, since each kind is a test.
fWorker(){
	local k="$1" i=0 u before
	local -A kindBad=([usage]=0 [case]=0 [extra]=0 [eol]=0 [kept]=0)
	tmpDir="${tmpDir}/w${k}"
	mkdir "$tmpDir"
	for u in "${units[@]}"; do
		if ((i % nWorkers == k)); then
			before="${nBad}"
			case "$u" in
				usage)    fUsage ;;
				case\|*)  fCase "${u#*|}" ;;
				extra\|*) fExtraFile "${u#*|}" ;;
				eol\|*)   fEolFile "${u#*|}" ;;
				kept\|*)  fEolFile "${u#*|}" "kept lines" ;;
			esac
			kindBad[${u%%|*}]=$((kindBad[${u%%|*}] + nBad - before))
		fi
		i=$((i + 1))
	done
	echo "${kindBad[usage]} ${kindBad[case]} ${kindBad[extra]} ${kindBad[eol]} ${kindBad[kept]}" >"${tmpDir}/kinds"
	echo "${nCompared} ${nBad}" >"${tmpDir}/counts"
}

## CPU_CAP from cicd.bash, or half the cores when run alone.
nWorkers="${CPU_CAP:-}"
if [[ ! "$nWorkers" =~ ^[1-9][0-9]*$ ]]; then nWorkers=$(( $(nproc) / 2 )); fi
if ((nWorkers < 1)); then nWorkers=1; fi
if ((nWorkers > ${#units[@]})); then nWorkers=${#units[@]}; fi
pids=()
for ((k = 0; k < nWorkers; k++)); do
	fWorker "$k" >"${tmpDir}/w${k}.log" 2>&1 &
	pids+=("$!")
done
## Logs in worker order, so a run reads the same whichever worker ends first.
## A worker that did not finish fails every kind, since any of them was its.
declare -i nFailed=0 wCompared wBad wUsage wCase wExtra wEol wKept badUsage=0 badCase=0 badExtra=0 badEol=0 badKept=0 nKindBad=0
for k in "${!pids[@]}"; do
	wrc=0; wait "${pids[k]}" || wrc=$?
	cat "${tmpDir}/w${k}.log"
	if [[ -f "${tmpDir}/w${k}/counts" && -f "${tmpDir}/w${k}/kinds" ]]; then
		read -r wCompared wBad <"${tmpDir}/w${k}/counts"
		nCompared=$((nCompared + wCompared)); nBad=$((nBad + wBad))
		read -r wUsage wCase wExtra wEol wKept <"${tmpDir}/w${k}/kinds"
		badUsage=$((badUsage + wUsage)); badCase=$((badCase + wCase)); badExtra=$((badExtra + wExtra)); badEol=$((badEol + wEol)); badKept=$((badKept + wKept))
	else
		nFailed+=1
		badUsage+=1; badCase+=1; badExtra+=1; badEol+=1; badKept+=1
		echo "crosscheck: worker ${k} ended at exit ${wrc} without finishing" >&2
	fi
done
fTest EjsGuy8 usage and option behavior
nKindBad+=badUsage
fTest EjsGuy9 corpus cases agree
nKindBad+=badCase
## The comparison floor is this test's too, or its line read ok on a run that
## then refused for comparing too little.
if ((nCompared < minCompared)); then nKindBad+=1; fi
fTest EjsGuyA fuzz inputs agree
nKindBad+=badExtra
[[ -n "$extra" ]] || fTestSkip
fTest ErUF4nK mixed line-ending keep saves agree
nKindBad+=badEol
[[ -n "$extra" && -d "${extra}/eol" ]] || fTestSkip
fTest EreXO4J kept lines under edits agree
nKindBad+=badKept
[[ -n "$extra" && -d "${extra}/kept" ]] || fTestSkip
fTestEnd
if ((nFailed)); then exit 2; fi

if ((nBad)); then
	echo "crosscheck: ${nBad}/${nCompared} comparison(s) diverged"
	exit 1
fi
if ((nCompared < minCompared)); then
	echo "crosscheck: only ${nCompared} comparison(s), need at least ${minCompared} (corpus/dump collapsed?)" >&2
	exit 2
fi
echo "crosscheck: ${#bindings[@]} bindings agree on ${nCompared} comparison(s)"


##	Script history:
##		- 20260712: Created.
##		- 20260721: Preserve trailing newlines in compares; zero-comparison and
##		               empty-extra floors; keep the last reads.tsv row when the
##		               file has no trailing newline; skip NUL-bearing inputs (bash
##		               can't hold a NUL; native runners pin those).
##		- 20260724: Layered-load dimension (fmt with --layer/--set) for cases
##		               with expected-merged.shcl; generation dimension (init
##		               --schema) for cases with init-schema.shcl.
##		- 20260726: In-place write dimension: compare the tree an in-place write
##		               leaves behind (mode, symlink, link count, content), not
##		               just stdout. Also made the DIVERGE diff non-fatal - under
##		               pipefail its nonzero status was aborting the run, so only
##		               the first divergence ever printed and the summary never did.
##		- 20260804: Pin `set --write --set` (edits as options, no ops on stdin)
##		               and the two gates that bound it; then `--set-literal`
##		               beside `--set` on the same text, so the data-vs-syntax
##		               split cannot drift.
##		- 20260829: One fork per CLI launch instead of three (stdout through a
##		               file and a builtin read), and no forks at all for the NUL
##		               probe and the case names.
##		- 20260922: The work split into units (each case, each fuzz input, the
##		               usage block) that CPU_CAP background workers take in
##		               turn. 229 s to 25 s at 16 workers.
##		- 20260926: A corpus with no case directory exits 2 on its own check.
##		- 20261001: Keep saves over the fuzz dump's mixed line-ending inputs,
##		               compared on disk.
##		- 20261003: The same over the dump's kept/ folder: kept lines and the
##		               edits near them, so the save gate on kept lines is held
##		               in every binding.
##		- 20261004: An --extra dump with no eol/ or kept/ fails a strict run,
##		               and is noted in SHCL_GATE_SKIPS otherwise.
