#!/usr/bin/env bash

##	Purpose:
##		Pin the tooling surface: the two wrappers, the one-liner's scope hygiene,
##		the packaging script's version handling, and the comparison worker's
##		argument handling. None of it is reachable from the corpus or the CLI
##		gate, and every row here is a defect a review round found.
##
##		Also scans the repo's own errexit scripts for the trap that has now bit
##		four times: a `grep` inside a command substitution whose result is
##		assigned. When it matches nothing the assignment fails, errexit kills
##		the script, and the check that would have printed the reason never runs.
##		A substitution ending in `|| true` is fine, which is the fix each time.
##	Syntax:
##		shell-regress.bash [--cli PATH]
##		  --cli PATH  the shcl binary the wrappers should resolve to
##		              (default source/rust/target/debug/shcl)
##	Exit: 0 = clean, 1 = a check failed, 2 = usage or missing input.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

## With GIT_DIR set, every scratch repo built below acts on the real one. The
## blocks that build one clear it again, so a block lifted out stays safe.
for gitVar in $(git rev-parse --local-env-vars 2>/dev/null || true); do unset "${gitVar}"; done

repoDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cli="${repoDir}/source/rust/target/debug/shcl"
while (($#)); do case "$1" in
	--cli)     cli="${2:-}"; shift 2 ;;
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         echo "shell-regress: unknown argument: $1" >&2; exit 2 ;;
esac; done
[[ -x "${cli}" ]] || { echo "shell-regress: no shcl binary at ${cli}" >&2; exit 2; }

tmpDir="$(mktemp -d)"; trap 'rm -rf "${tmpDir}"' EXIT
printf 'a: 1\n' > "${tmpDir}/t.shcl"
declare -i nBad=0
fBad(){ echo "shell-regress: $1" >&2; nBad+=1 ;}
testWhere=shell-regress; testCounter=nBad
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"

##	Is tool $1 here? Under the gate a missing one is a failure rather than a
##	skipped block: a runner that loses a tool would otherwise report OK forever.
##	Locally it stays a skip, since a working copy need not have every tool, and
##	is noted in SHCL_GATE_SKIPS so the run is not taken for a full gate.
fHave(){
	command -v "$1" > /dev/null 2>&1 && return 0
	[[ -n "${SHCL_GATE_STRICT:-}" ]] && fBad "$1 is missing and the gate requires it"
	echo "$1" >> "${SHCL_GATE_SKIPS:-/dev/null}"
	return 1
}
##	fHave for a file the rows read rather than a tool they run: $1 is the path,
##	$2 the package that ships it. A bare `[[ -r ]] && rows+=()` dropped half the
##	completion rows with nothing said, under the gate too (20260918b item 43).
fHaveFile(){
	[[ -r "$1" ]] && return 0
	[[ -n "${SHCL_GATE_STRICT:-}" ]] && fBad "$2 is missing ($1) and the gate requires it"
	echo "shell-regress: skipping the $2 rows (no $1)" >&2
	echo "$2" >> "${SHCL_GATE_SKIPS:-/dev/null}"
	return 1
}

fTest EoTJb0K 20260830-21-bash-wrapper-refuses-a-bad-shcl-bin
##	20260830 item 21: -x is true for a directory, so a directory passed as
##	SHCL_BIN got as far as being run.
out="$(SHCL_BIN="${tmpDir}" bash -c "source '${repoDir}/source/bash/shcl.bash'; shcl_get '${tmpDir}/t.shcl' a" 2>&1 || true)"
[[ "${out}" == *"not an executable file"* ]] || fBad "bash wrapper took a directory as SHCL_BIN: ${out@Q}"
out="$(SHCL_BIN="${tmpDir}/nope" bash -c "source '${repoDir}/source/bash/shcl.bash'; shcl_get '${tmpDir}/t.shcl' a" 2>&1 || true)"
[[ "${out}" == *"not an executable file"* ]] || fBad "bash wrapper took a missing SHCL_BIN: ${out@Q}"
out="$(SHCL_BIN="${cli}" bash -c "source '${repoDir}/source/bash/shcl.bash'; shcl_get '${tmpDir}/t.shcl' a" 2>&1 || true)"
[[ "${out}" == "1" ]] || fBad "bash wrapper did not read through a pinned SHCL_BIN: ${out@Q}"

fTest EoTJb0L bash-wrapper-ignores-an-inherited-cache
##	The private cache is not an interface: an inherited value would beat every
##	documented lookup step.
out="$(_SHCL_BIN=/nonexistent SHCL_BIN="${cli}" bash -c "source '${repoDir}/source/bash/shcl.bash'; shcl_get '${tmpDir}/t.shcl' a" 2>&1 || true)"
[[ "${out}" == "1" ]] || fBad "bash wrapper honored an inherited _SHCL_BIN: ${out@Q}"

fTest EqzwPFE 20260716-32-bash-wrapper-through-a-link
##	20260716 item 32: reached through a link, the wrapper looked for its
##	sibling binary beside the link. One link relative and one absolute, run and
##	sourced, with no SHCL_BIN: the stub beside the real file has to answer.
mkdir -p "${tmpDir}/blink/real" "${tmpDir}/blink/lnk"
cp "${repoDir}/source/bash/shcl.bash" "${tmpDir}/blink/real/"
printf '#!/bin/sh\necho "sibling $*"\n' > "${tmpDir}/blink/real/shcl"; chmod 755 "${tmpDir}/blink/real/shcl"
ln -s ../real/shcl.bash "${tmpDir}/blink/lnk/rel.bash"
ln -s "${tmpDir}/blink/lnk/rel.bash" "${tmpDir}/blink/abs.bash"
for via in lnk/rel.bash abs.bash; do
	out="$(env -u SHCL_BIN bash "${tmpDir}/blink/${via}" x 2>&1 || true)"
	[[ "${out}" == "sibling x" ]] || fBad "bash wrapper run through ${via} missed its sibling binary: ${out@Q}"
	# shellcheck disable=SC2016  ## the inner shell's own $1
	out="$(env -u SHCL_BIN bash -c 'source "$1"; shcl y' _ "${tmpDir}/blink/${via}" 2>&1 || true)"
	[[ "${out}" == "sibling y" ]] || fBad "bash wrapper sourced through ${via} missed its sibling binary: ${out@Q}"
done

fTest ErlisVv 20261003-16-bash-wrapper-in-an-install
##	20261003 item 16: every installer puts the wrappers in scripts/ with the
##	binary a level up, and the wrapper looked only beside itself, so with the
##	bin link off PATH it found nothing. PATH here has no shcl on it.
mkdir -p "${tmpDir}/inst/scripts"
cp "${repoDir}/source/bash/shcl.bash" "${repoDir}/source/powershell/shcl.ps1" "${tmpDir}/inst/scripts/"
printf '#!/bin/sh\necho "installed $*"\n' > "${tmpDir}/inst/shcl"; chmod 755 "${tmpDir}/inst/shcl"
out="$(env -u SHCL_BIN PATH=/usr/bin:/bin bash "${tmpDir}/inst/scripts/shcl.bash" x 2>&1 || true)"
[[ "${out}" == "installed x" ]] || fBad "bash wrapper in an install's scripts/ missed the binary a level up: ${out@Q}"

fTest ErlisYf 20261003-16-pwsh-wrapper-in-an-install
if fHave pwsh; then
	pwshExe="$(command -v pwsh)"
	out="$(env -u SHCL_BIN PATH=/usr/bin:/bin "${pwshExe}" -NoProfile -File "${tmpDir}/inst/scripts/shcl.ps1" x 2>&1 </dev/null || true)"
	[[ "${out}" == "installed x" ]] || fBad "pwsh wrapper in an install's scripts/ missed the binary a level up: ${out@Q}"
else
	fTestSkip
fi

fTest Ep11mJd 20260904-10-11-bash-completion-value-options
##	20260904 items 10 and 11: bash cuts `--opt=value` at the `=` before a
##	completion function runs, and the three value options added in 20260830b
##	were missing from the lists that skip a value, so the FILE slot went to
##	the value. Driven the way readline hands the words over, both with
##	bash-completion's word joining and with the completion's own fallback.
mkdir -p "${tmpDir}/comp" && touch "${tmpDir}/comp/alpha.shcl" "${tmpDir}/comp/beta.txt"
## The break characters readline splits a completion word at, which is bash's
## own default for COMP_WORDBREAKS less the whitespace.
compBreaks=$'"\'><=;|&(:'
fComplete(){
	## $1 = lib|bare, $2 = the command line as typed (a trailing space means a
	## fresh word). Prints COMPREPLY space-joined.
	## With the library, its file completer is replaced by a plain compgen: what
	## the lib half tests is the word joining, and _filedir's answer outside a
	## live readline session differs between bash-completion releases. The
	## words come back sorted, since compgen -f follows directory order.
	local setup=":"
	# shellcheck disable=SC2016  ## the ${cur} is for the inner bash
	[[ "$1" == lib ]] && setup='source /usr/share/bash-completion/bash_completion; _filedir(){ mapfile -t COMPREPLY < <(compgen -f -- "${cur}"); }'
	bash -c '
		'"${setup}"'; source '"'${repoDir}/source/completions/shcl.bash'"'
		line="$1"; brk="$2"; COMP_WORDS=()
		## Readline cuts every word at each character of COMP_WORDBREAKS and
		## hands the break over as a word of its own. Splitting at the first
		## `=` only, as this did, made `--set url=http://x` look like two words
		## where the shell gives six, and the row passed on code that lost the
		## FILE slot (20260918b item 15).
		for t in ${line}; do
			piece=""
			for (( k = 0; k < ${#t}; k++ )); do
				c="${t:k:1}"
				if [[ "${brk}" == *"${c}"* ]]; then
					[[ -n "${piece}" ]] && COMP_WORDS+=("${piece}")
					piece=""; COMP_WORDS+=("${c}")
				else
					piece+="${c}"
				fi
			done
			[[ -n "${piece}" ]] && COMP_WORDS+=("${piece}")
		done
		[[ "${line}" == *" " ]] && COMP_WORDS+=("")
		COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 )); COMP_LINE="${line}"; COMP_POINT=${#line}
		cd '"'${tmpDir}/comp'"'; COMPREPLY=(); _shcl; printf "%s\n" "${COMPREPLY[@]}" | sort | paste -sd" " | sed "s/^ $//"
	' _ "$2" "${compBreaks}" 2>/dev/null || true
}
compModes=(bare)
if fHaveFile /usr/share/bash-completion/bash_completion bash-completion; then compModes+=(lib); fi
for mode in "${compModes[@]}"; do
	out="$(fComplete "${mode}" "shcl check --strictness=st")"
	[[ "${out}" == "standard strict" ]] || fBad "bash completion (${mode}) on --strictness=st: ${out@Q}"
	out="$(fComplete "${mode}" "shcl check --strictness=")"
	[[ "${out}" == *standard* ]] || fBad "bash completion (${mode}) on --strictness=: ${out@Q}"
	out="$(fComplete "${mode}" "shcl check --strictness=standard al")"
	[[ "${out}" == "alpha.shcl" ]] || fBad "bash completion (${mode}) lost the FILE slot after --strictness=standard: ${out@Q}"
	out="$(fComplete "${mode}" "shcl get --on-bad=fl")"
	[[ "${out}" == "flag" ]] || fBad "bash completion (${mode}) on --on-bad=fl: ${out@Q}"
	out="$(fComplete "${mode}" "shcl fmt --schema=al")"
	[[ "${out}" == "alpha.shcl" ]] || fBad "bash completion (${mode}) on --schema=al: ${out@Q}"
	out="$(fComplete "${mode}" "shcl fmt --remove ")"
	[[ -z "${out}" ]] || fBad "bash completion (${mode}) offered files where --remove takes a PATH: ${out@Q}"
	out="$(fComplete "${mode}" "shcl fmt --remove x ")"
	[[ "${out}" == "alpha.shcl beta.txt" ]] || fBad "bash completion (${mode}) lost the FILE slot after --remove x: ${out@Q}"
	out="$(fComplete "${mode}" "shcl fmt --set-default=x=1 ")"
	[[ "${out}" == "alpha.shcl beta.txt" ]] || fBad "bash completion (${mode}) lost the FILE slot after --set-default=x=1: ${out@Q}"
	out="$(fComplete "${mode}" "shcl check --strictness st")"
	[[ "${out}" == "standard strict" ]] || fBad "bash completion (${mode}) on the space form: ${out@Q}"
	## 20260918b item 15: a value holding another `=` or a `:` is still one
	## word to the shell, and the FILE slot has to survive it.
	out="$(fComplete "${mode}" "shcl set --set a=1 ")"
	[[ "${out}" == "alpha.shcl beta.txt" ]] || fBad "bash completion (${mode}) lost the FILE slot after --set a=1: ${out@Q}"
	out="$(fComplete "${mode}" "shcl set --set url=http://x ")"
	[[ "${out}" == "alpha.shcl beta.txt" ]] || fBad "bash completion (${mode}) lost the FILE slot after a value holding a colon: ${out@Q}"
	out="$(fComplete "${mode}" "shcl get --default=a:b alpha.shcl ")"
	[[ -z "${out}" ]] || fBad "bash completion (${mode}) offered files for the PATH after --default=a:b: ${out@Q}"
	## A FILE of `-` fills the slot, and everything after `--` is a positional.
	out="$(fComplete "${mode}" "shcl fmt - ")"
	[[ -z "${out}" ]] || fBad "bash completion (${mode}) offered a second FILE after a FILE of -: ${out@Q}"
	out="$(fComplete "${mode}" "shcl fmt -- al")"
	[[ "${out}" == "alpha.shcl" ]] || fBad "bash completion (${mode}) lost the FILE slot after --: ${out@Q}"
done

fTest EpHNNhw 20260904-39-wrappers-match-the-binary
##	20260904 item 39: nothing had ever compared what the two wrappers hand back
##	against what the binary hands back. They are pass-through front ends, so
##	every row here is the same assertion - same stdout, same stderr, same exit
##	code - across four ways of calling them. Item 16 (the script form ending the
##	caller's shell) lived in that gap for a release.
{
	printf 'a: 1\nname: two words\nblk:\n\t~~~txt\n\tbody\n\n\t~~~\n-dash: 5\n' > "${tmpDir}/w.shcl"
	##	Dot-sourcing through a file, and splatting real argv into the function,
	##	so bash's quoting never has to survive a PowerShell -Command string.
	#  shellcheck disable=2016  ## PowerShell's own $variables.
	{
		echo ". '${repoDir}/source/powershell/shcl.ps1'"
		echo 'shcl @args'
		echo 'exit $LASTEXITCODE'
	} > "${tmpDir}/wdot.ps1"

	##	id | stdin (printf %b, '-' for none) | the arguments, one per field
	wrapRows=(
		'good|-|get|--int|%F%|a'
		'missing|-|get|--int|%F%|nope'
		'badtype|-|get|--int|%F%|name'
		'nofile|-|check|%M%'
		'usage|-|get|--nope|%F%|a'
		'stdin-fmt|a: 1\n|fmt|-'
		'stdin-ops|int\tb\t2\n|set|%F%'
		'raw-tail|-|get|--raw|%F%|blk'
		'space-arg|-|get|%F%|name'
		'dash-arg|-|get|--|%F%|-dash'
	)
	fRunWrapper(){  ## fRunWrapper MODE STDIN ARGS...
		local mode="$1" stdinSpec="$2"; shift 2
		local rc=0
		##	bashsrc keeps the wrapper's path out of $0, or the wrapper sees
		##	BASH_SOURCE[0] == $0 and runs as a script instead of being sourced.
		case "${mode}" in
			binary)   if [[ "${stdinSpec}" == - ]]; then "${cli}" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" </dev/null || rc=$?
			          else printf '%b' "${stdinSpec}" | "${cli}" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" || rc=$?; fi ;;
			bash)     if [[ "${stdinSpec}" == - ]]; then bash "${repoDir}/source/bash/shcl.bash" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" </dev/null || rc=$?
			          else printf '%b' "${stdinSpec}" | bash "${repoDir}/source/bash/shcl.bash" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" || rc=$?; fi ;;
			bashsrc)  if [[ "${stdinSpec}" == - ]]; then bash -c 'w="$1"; shift; source "$w"; shcl "$@"' bashsrc "${repoDir}/source/bash/shcl.bash" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" </dev/null || rc=$?
			          else printf '%b' "${stdinSpec}" | bash -c 'w="$1"; shift; source "$w"; shcl "$@"' bashsrc "${repoDir}/source/bash/shcl.bash" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" || rc=$?; fi ;;
			pwsh)     if [[ "${stdinSpec}" == - ]]; then pwsh -NoProfile -File "${repoDir}/source/powershell/shcl.ps1" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" </dev/null || rc=$?
			          else printf '%b' "${stdinSpec}" | pwsh -NoProfile -File "${repoDir}/source/powershell/shcl.ps1" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" || rc=$?; fi ;;
			pwshsrc)  if [[ "${stdinSpec}" == - ]]; then pwsh -NoProfile -File "${tmpDir}/wdot.ps1" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" </dev/null || rc=$?
			          else printf '%b' "${stdinSpec}" | pwsh -NoProfile -File "${tmpDir}/wdot.ps1" "$@" >"${tmpDir}/wo" 2>"${tmpDir}/we" || rc=$?; fi ;;
		esac
		printf 'rc=%s\n' "${rc}"
		printf -- '--out--\n'; cat "${tmpDir}/wo"
		printf -- '--err--\n'; cat "${tmpDir}/we"
	}

	wrapModes=(bash bashsrc)
	fHave pwsh >/dev/null 2>&1 && wrapModes+=(pwsh pwshsrc)
	export SHCL_BIN="${cli}"
	for row in "${wrapRows[@]}"; do
		IFS='|' read -r -a f <<<"${row}"
		id="${f[0]}"; stdinSpec="${f[1]}"
		args=("${f[@]:2}")
		for ((ai = 0; ai < ${#args[@]}; ai++)); do
			args[ai]="${args[ai]//%F%/${tmpDir}/w.shcl}"
			args[ai]="${args[ai]//%M%/${tmpDir}/not-there.shcl}"
		done
		want="$(fRunWrapper binary "${stdinSpec}" "${args[@]}")"
		for mode in "${wrapModes[@]}"; do
			##	The one documented difference: PowerShell eats a bare `--` before
			##	a dot-sourced function sees it, which the rows above this block
			##	pin on their own. Every other row goes through unchanged.
			[[ "${id}" == dash-arg && "${mode}" == pwshsrc ]] && continue
			got="$(fRunWrapper "${mode}" "${stdinSpec}" "${args[@]}")"
			[[ "${got}" == "${want}" ]] || fBad "wrapper ${mode} differs from the binary on ${id}: ${got@Q} against ${want@Q}"
		done
	done

	fTest ErJEygN 20260928-idea-3-bash-typed-helpers-match-the-binary
	##	Code review 20260928 idea 3 added shcl_duration and shcl_size. Each row
	##	calls a sourced typed helper and the binary on the same piped text.
	##	id | piped text | the helper call | the same thing on the binary
	bashHelperRows=(
		'int|a: 5|shcl_int - a|get --int - a'
		'float|a: 1.5|shcl_float - a|get --float - a'
		'bool|a: on|shcl_bool - a|get --bool - a'
		'datetime|a: 2026-09-28|shcl_datetime - a|get --datetime - a'
		'duration|t: 90s|shcl_duration - t|get --duration - t'
		'duration-unit|t: 3|shcl_duration --unit=s - t|get --duration --unit=s - t'
		'duration-bad|t: soon|shcl_duration - t|get --duration - t'
		'size|m: 2KB|shcl_size - m|get --size - m'
		'size-decimal|m: 2KB|shcl_size --decimal - m|get --size --decimal - m'
		'size-unit|m: 3|shcl_size --unit=MB - m|get --size --unit=MB - m'
	)
	for row in "${bashHelperRows[@]}"; do
		IFS='|' read -r hid piped hcall bcall <<<"${row}"
		read -r -a hargs <<<"${hcall}"
		read -r -a bargs <<<"${bcall}"
		hrc=0
		hout="$(printf '%s\n' "${piped}" | bash -c 'w="$1"; shift; source "$w"; "$@"' helpers "${repoDir}/source/bash/shcl.bash" "${hargs[@]}" 2>&1)" || hrc=$?
		brc=0
		bout="$(printf '%s\n' "${piped}" | "${cli}" "${bargs[@]}" 2>&1)" || brc=$?
		[[ "${hout}" == "${bout}" && "${hrc}" == "${brc}" ]] \
			|| fBad "bash helper ${hid} differs from the binary: ${hout@Q} rc=${hrc} against ${bout@Q} rc=${brc}"
	done

	fTest EqM3Y7s 20260918b-32-piped-helpers-match-the-binary
	##	20260918b item 32: the matrix above pipes into the script, where the
	##	binary inherits the process's stdin and a wrapper that drops $input
	##	looks fine. A typed helper is only reached from a PowerShell pipeline,
	##	and every one of them passed @args without $input, so `'a: 5' |
	##	shcl_fmt -` printed nothing at exit 0. The rows below build that
	##	pipeline inside PowerShell and hold each helper against the binary.
	if [[ " ${wrapModes[*]} " == *" pwshsrc "* ]]; then
		#  shellcheck disable=2016  ## PowerShell's own $variables.
		{
			echo ". '${repoDir}/source/powershell/shcl.ps1'"
			echo '$data = $args[0]; $fn = $args[1]'
			echo '$rest = @(); if ($args.Count -gt 2) { $rest = $args[2..($args.Count - 1)] }'
			echo 'if ($data -ne "") { $data | & $fn @rest } else { & $fn @rest }'
			echo 'exit $LASTEXITCODE'
		} > "${tmpDir}/whelp.ps1"
		##	id | piped text | the helper call | the same thing on the binary
		helperRows=(
			'fmt|a: 5|shcl_fmt -|fmt -'
			'int|a: 5|shcl_int - a|get --int - a'
			'array|a: 1, 2|shcl_array --int - a|get --array --int - a'
			'check|bad line|shcl_check -|check -'
			'count|a: 1|shcl_count - a|count - a'
			'duration|t: 3|shcl_duration --unit=s - t|get --duration --unit=s - t'
			'size|m: 2KB|shcl_size --decimal - m|get --size --decimal - m'
		)
		for row in "${helperRows[@]}"; do
			IFS='|' read -r hid piped hcall bcall <<<"${row}"
			read -r -a hargs <<<"${hcall}"
			read -r -a bargs <<<"${bcall}"
			hrc=0
			hout="$(pwsh -NoProfile -File "${tmpDir}/whelp.ps1" "${piped}" "${hargs[@]}" 2>&1)" || hrc=$?
			brc=0
			bout="$(printf '%s\n' "${piped}" | "${cli}" "${bargs[@]}" 2>&1)" || brc=$?
			[[ "${hout}" == "${bout}" && "${hrc}" == "${brc}" ]] \
				|| fBad "piped helper ${hid} differs from the binary: ${hout@Q} rc=${hrc} against ${bout@Q} rc=${brc}"
		done

		fTest EqnwIkT 20260923-9-10-ps1-encoding-and-script-stdin
		##	20260923 items 9 and 10. Windows PowerShell 5.1 pipes text in as
		##	us-ascii and decodes what comes back with the console's code page, so
		##	`'a: café' | shcl fmt -` gave `caf?` at exit 0. pwsh here defaults to
		##	UTF-8 for both, so the rows set the two to something else first. And
		##	the script form, run from a PowerShell pipeline, dropped its input.
		printf 'a: caf\xc3\xa9\n' > "${tmpDir}/cafe.shcl"
		#  shellcheck disable=2016  ## PowerShell's own $variables.
		{
			echo ". '${repoDir}/source/powershell/shcl.ps1'"
			echo '$cafe = "caf" + [char]0xe9'
			echo '$OutputEncoding = [System.Text.Encoding]::ASCII'
			echo '$r = "a: $cafe" | shcl get - a'
			echo '"piped=$($r -eq $cafe)"'
			echo '[Console]::OutputEncoding = [System.Text.Encoding]::Latin1'
			echo "\$r = shcl get '${tmpDir}/cafe.shcl' a"
			echo '"decoded=$($r -eq $cafe) restored=$([Console]::OutputEncoding.CodePage)"'
			echo "\$r = 'a: 5' | & '${repoDir}/source/powershell/shcl.ps1' get --int - a"
			echo '"script=$r rc=$LASTEXITCODE"'
			echo 'function f { $OutputEncoding = [System.Text.Encoding]::ASCII; $r = "a: $cafe" | shcl get - a; "scoped=$($r -eq $cafe)" }'
			echo 'f'
		} > "${tmpDir}/wenc.ps1"
		out="$(pwsh -NoProfile -File "${tmpDir}/wenc.ps1" </dev/null 2>&1 || true)"
		[[ "${out}" == *"piped=True"* ]] || fBad "shcl.ps1 pipes text in with the caller's \$OutputEncoding: ${out@Q}"
		[[ "${out}" == *"decoded=True restored=28591"* ]] \
			|| fBad "shcl.ps1 decodes output with the console's code page, or does not put it back: ${out@Q}"
		[[ "${out}" == *"script=5 rc=0"* ]] || fBad "shcl.ps1 run as a script drops pipeline input: ${out@Q}"
		[[ "${out}" == *"scoped=True"* ]] || fBad "shcl.ps1 pipes text in with a caller's own \$OutputEncoding: ${out@Q}"
		## 20260924 item 1: started by -File with stdin from outside PowerShell,
		## the script must hand the binary the bytes, not text PowerShell decoded.
		printf 'a: 1\n' > "${tmpDir}/wbyte.shcl"
		rc=0; printf 'string\tk\tx\377y\n' | pwsh -NoProfile -File "${repoDir}/source/powershell/shcl.ps1" set --write "${tmpDir}/wbyte.shcl" >/dev/null 2>&1 || rc=$?
		[[ "${rc}" == 8 && "$(cat "${tmpDir}/wbyte.shcl")" == "a: 1" ]] \
			|| fBad "shcl.ps1 run by -File saves stdin it re-encoded: rc ${rc}, file ${tmpDir}/wbyte.shcl"
		#  shellcheck disable=2016  ## The backticks are a fence.
		out="$(printf 'r: ```\n\tab\rcd\n```\n' | pwsh -NoProfile -File "${repoDir}/source/powershell/shcl.ps1" get --raw - r 2>&1 || true)"
		[[ "${out}" == *$'ab\rcd'* ]] || fBad "shcl.ps1 run by -File turns a CR in stdin into a line break: ${out@Q}"
	else
		fTestSkipBlock
	fi
	unset SHCL_BIN
}

fTest EpHMbJw 20260904-35-zsh-completion
##	20260904 item 35: the zsh completion had never been run by anything - only
##	its option table was diffed - and it did not parse at all. An apostrophe
##	inside a single-quoted description left a quote open for the rest of the
##	file, so every zsh user got a parse error instead of a completion. Driven
##	here with the completion helpers stubbed, so the answers are assertable.
if fHave zsh; then
	## Stubs record what each helper was offered rather than completing it.
	#  shellcheck disable=2016  ## zsh's own $variables, quoted so bash leaves them alone.
	cat > "${tmpDir}/zdrv.zsh" <<'ZEOF'
emulate -L zsh
typeset -ga OFFERED=()
_describe() { local -a a; eval "a=(\"\${${4:-cmds}[@]}\")"; local e; for e in "${a[@]}"; do OFFERED+=("${e%%:*}"); done }
_values()   { shift; OFFERED+=("$@") }
_files()    { OFFERED+=("<files>") }
compadd()   { local a; for a in "$@"; do [[ "$a" == -- ]] && continue; OFFERED+=("$a"); done }
compset()   { [[ "${words[CURRENT]}" == "${2}"* ]] }
typeset -ga words=(${=1})
[[ "$1" == *" " ]] && words+=("")
typeset -gi CURRENT=${#words}
source "${ZDRV_FILE}"
print -r -- "${(o)OFFERED[@]}"
ZEOF
	fZComplete(){ ZDRV_FILE="${repoDir}/source/completions/_shcl" zsh -f "${tmpDir}/zdrv.zsh" "$1" 2>&1 || true ;}

	##	It has to parse before any of the answers below mean anything.
	if ! out="$(zsh -n "${repoDir}/source/completions/_shcl" 2>&1)"; then
		fBad "the zsh completion does not parse: ${out@Q}"
	else
		out="$(fZComplete "shcl ")"
		[[ " ${out} " == *" get "* && " ${out} " == *" --donate "* ]] || fBad "zsh completion word 2: ${out@Q}"
		out="$(fZComplete "shcl check --strictness ")"
		[[ "${out}" == "1 2 3 loose standard strict" ]] || fBad "zsh completion on --strictness: ${out@Q}"
		out="$(fZComplete "shcl get --on-bad=")"
		[[ "${out}" == "default error flag" ]] || fBad "zsh completion on --on-bad=: ${out@Q}"
		out="$(fZComplete "shcl check --schema ")"
		[[ "${out}" == "<files>" ]] || fBad "zsh completion on --schema: ${out@Q}"
		out="$(fZComplete "shcl check ")"
		[[ "${out}" == "<files>" ]] || fBad "zsh completion lost the FILE slot: ${out@Q}"
		out="$(fZComplete "shcl fmt --set x=1 ")"
		[[ "${out}" == "<files>" ]] || fBad "zsh completion gave the FILE slot to a --set value: ${out@Q}"
		out="$(fZComplete "shcl check a.shcl ")"
		[[ -z "${out}" ]] || fBad "zsh completion offered files where a PATH goes: ${out@Q}"
		##	20260918b item 15: `-` is a FILE, and everything after `--` is a
		##	positional whatever it looks like.
		out="$(fZComplete "shcl check - ")"
		[[ -z "${out}" ]] || fBad "zsh completion offered a second FILE after a FILE of -: ${out@Q}"
		out="$(fZComplete "shcl check -- ")"
		[[ "${out}" == "<files>" ]] || fBad "zsh completion lost the FILE slot after --: ${out@Q}"
		##	`-w` is the only short option the CLI takes on a subcommand, and the
		##	comment in both completions says so. Offered where --write is and
		##	nowhere else; -h is informational and rides along everywhere.
		out="$(fZComplete "shcl fmt -")"
		[[ " ${out} " == *" -w "* ]] || fBad "zsh completion did not offer -w on fmt: ${out@Q}"
		for sub in get check init count instances children paths; do
			out="$(fZComplete "shcl ${sub} -")"
			[[ " ${out} " != *" -w "* ]] || fBad "zsh completion offered -w on ${sub}, which takes no --write"
			bad="$(tr ' ' '\n' <<<"${out}" | { grep -xE -- '-[A-Za-z]' || true ;} | { grep -vx -- '-h' || true ;})"
			[[ -z "${bad}" ]] || fBad "zsh completion offers a short option other than -w on ${sub}: ${bad@Q}"
		done
	fi
else
	echo "shell-regress: zsh not installed - zsh completion rows skipped"
	fTestSkip
fi

fTest Ep19Ax8 20260904-16-pwsh-bare-double-dash
if fHave pwsh; then
	##	20260904 item 16: PowerShell reads a bare `--` as its own token and drops
	##	it before a dot-sourced function sees its arguments; the quoted spelling
	##	is the documented way through. Both halves are pinned, so a PowerShell
	##	release that changes either shows up here.
	printf -- '-dash: 5\n' > "${tmpDir}/dash.shcl"
	out="$(pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${cli}'; shcl get -- '${tmpDir}/dash.shcl' '-dash'" 2>&1 || true)"
	[[ "${out}" == *"unknown option"* ]] || fBad "pwsh now hands a bare -- to the sourced function; the wrapper note is stale: ${out@Q}"
	out="$(pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${cli}'; shcl get '--' '${tmpDir}/dash.shcl' '-dash'" 2>&1 || true)"
	[[ "${out}" == "5" ]] || fBad "pwsh dot-sourced shcl did not take a quoted --: ${out@Q}"

	fTest EqM3Y7t 20260918b-35-pwsh-comma-split
	##	20260918b item 35: the second difference, documented the same way.
	##	PowerShell splits an unquoted `a,b` into an array for a function and
	##	not for a native command, so a bracket array with a comma in it is a
	##	usage error dot-sourced and works quoted.
	out="$(pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${cli}'; shcl set --set-literal=ports=[80,443] '${tmpDir}/w.shcl'" 2>&1 || true)"
	[[ "${out}" == *"usage"* || "${out}" == *"unknown"* || "${out}" == *"bad --set"* ]] \
		|| fBad "pwsh no longer splits an unquoted comma for a sourced function; the wrapper note is stale: ${out@Q}"
	out="$(pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${cli}'; shcl set '--set-literal=ports=[80,443]' '${tmpDir}/w.shcl'" 2>&1 || true)"
	[[ "${out}" == *"ports: [80, 443]"* ]] || fBad "pwsh dot-sourced shcl did not take a quoted comma value: ${out@Q}"

	fTest EqzwPFF 20260716-14-ps1-wrapper-refuses-a-bad-shcl-bin
	out="$(pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${tmpDir}'; shcl_get '${tmpDir}/t.shcl' a" 2>&1 || true)"
	[[ "${out}" == *"not executable"* ]] || fBad "PowerShell wrapper took a directory as SHCL_BIN: ${out@Q}"
	##	20260716 item 14: a file with no execute bit passed as the binary. pwsh
	##	hands such a file to the desktop opener, so a stand-in opener sits first
	##	on PATH and has to stay unused. Item 34: a pinned base name skipped the
	##	.exe fallback every other lookup step takes.
	mkdir -p "${tmpDir}/pwbin/opener" "${tmpDir}/pwbin/exe"
	printf '#!/bin/sh\necho opened >> "%s"\n' "${tmpDir}/pwbin/opened" > "${tmpDir}/pwbin/opener/xdg-open"
	printf '#!/bin/sh\necho plain\n' > "${tmpDir}/pwbin/plain"
	printf '#!/bin/sh\necho "exe $*"\n' > "${tmpDir}/pwbin/exe/x.exe"
	chmod 755 "${tmpDir}/pwbin/opener/xdg-open" "${tmpDir}/pwbin/exe/x.exe"; chmod 644 "${tmpDir}/pwbin/plain"
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY PATH="${tmpDir}/pwbin/opener:${PATH}" pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${tmpDir}/pwbin/plain'; shcl --version" 2>&1 </dev/null || true)"
	[[ "${out}" == *"not executable"* && ! -e "${tmpDir}/pwbin/opened" ]] || fBad "PowerShell wrapper took a file with no execute bit as SHCL_BIN: ${out@Q}"
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY PATH="${tmpDir}/pwbin/opener:${PATH}" pwsh -NoProfile -Command ". '${repoDir}/source/powershell/shcl.ps1'; \$env:SHCL_BIN = '${tmpDir}/pwbin/exe/x'; shcl a b" 2>&1 </dev/null || true)"
	[[ "${out}" == "exe a b" ]] || fBad "PowerShell wrapper did not take x.exe for SHCL_BIN=x: ${out@Q}"

	fTest ErD2LTv 20260928-item4-ps1-legacy-quotes
	##	20260928 item 4: Windows PowerShell 5.1 builds a native command line the
	##	old way, so an embedded quote never reached the binary and an empty
	##	argument was left out. The Legacy mode of 7 builds it the same way, so
	##	it stands in for 5.1 here. Each value goes in as --default and has to
	##	come back from a read of a missing path as it went in.
	#  shellcheck disable=2016,2028  ## PowerShell's own $variables and backslashes, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		printf '. %s\n' "'${repoDir}/source/powershell/shcl.ps1'"
		printf '$env:SHCL_BIN = %s\n' "'${cli}'"
		echo '$PSNativeCommandArgumentPassing = "Legacy"'
		echo '$q = [string][char]34'
		echo '$vals = @(($q + "q" + $q), ("a" + $q + "b"), "", "C:\a b\", ("p\" + $q + "q"), ("x " + $q + "y" + $q + " z"))'
		echo 'if ($vals.Count -ne 6) { "the value list has $($vals.Count) entries" }'
		echo 'foreach ($v in $vals) { $o = shcl get "--default=$v" $args[0] nope; if (($o -join "`n") -cne $v -or $LASTEXITCODE -ne 0) { "lost: [$v] came back [$($o -join "|")] rc $LASTEXITCODE" } }'
		echo '$o = shcl get --default "" $args[0] nope; if ($LASTEXITCODE -ne 0) { "lost: an empty argument, rc $LASTEXITCODE" }'
		echo '"done"'
	} > "${tmpDir}/legacy.ps1"
	printf 'a: 1\n' > "${tmpDir}/legacy.shcl"
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY pwsh -NoProfile -File "${tmpDir}/legacy.ps1" "${tmpDir}/legacy.shcl" 2>&1 </dev/null || true)"
	[[ "${out}" == "done" ]] || fBad "PowerShell wrapper under legacy argument passing: ${out@Q}"

	fTest ErkOqpb 20261003-item5-ps1-file-colon-args
	##	Code review 20261003 item 5: started by -File, PowerShell took a `-`-led
	##	argument with a colon apart before the script saw it, so
	##	`--set=url=http://x` reached the binary as two arguments and the read
	##	answered wrong at exit 0. A stub that prints its arguments stands in for
	##	the binary, then the real one runs the review's own case.
	#  shellcheck disable=2016  ## the stub's own $@ and $a.
	printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "${tmpDir}/argv.sh"; chmod +x "${tmpDir}/argv.sh"
	#  shellcheck disable=2016  ## PowerShell's own $true, passed as typed.
	colonArgs=(children x.shcl '--set=url=http://x' '-x:y' '-b:' c '-k:$true' '--z=1:2' -- -File '' 'a b')
	want="$("${tmpDir}/argv.sh" "${colonArgs[@]}")"
	got="$(SHCL_BIN="${tmpDir}/argv.sh" pwsh -NoProfile -File "${repoDir}/source/powershell/shcl.ps1" "${colonArgs[@]}" 2>&1 </dev/null || true)"
	[[ "${got}" == "${want}" ]] || fBad "shcl.ps1 run by -File changed its arguments: ${got@Q} against ${want@Q}"
	got="$(cd "${repoDir}/source/powershell" && SHCL_BIN="${tmpDir}/argv.sh" pwsh -NoProfile shcl.ps1 "${colonArgs[@]}" 2>&1 </dev/null || true)"
	[[ "${got}" == "${want}" ]] || fBad "shcl.ps1 run as pwsh's first word changed its arguments: ${got@Q} against ${want@Q}"
	printf 'site: a\nurl: b\n' > "${tmpDir}/colon.shcl"
	want="$("${cli}" children "${tmpDir}/colon.shcl" --set=url=http://x 2>&1)" || true
	got="$(SHCL_BIN="${cli}" pwsh -NoProfile -File "${repoDir}/source/powershell/shcl.ps1" children "${tmpDir}/colon.shcl" --set=url=http://x 2>&1 </dev/null || true)"
	[[ -n "${want}" && "${got}" == "${want}" ]] || fBad "shcl.ps1 run by -File: children with --set=url=http://x gave ${got@Q}, the binary ${want@Q}"

	fTest Ermwgw4 2026100408550401-ps1-session-colon-args
	##	Called from a session, an unquoted `-x:y` reached the binary as `y`. Each
	##	row wants what a direct call passes, where `-x: y` is two arguments. The
	##	last row is the fallback, where the caller's own parameter took `-q:1`.
	cat > "${tmpDir}/sesscolon.ps1" <<'PSEOF'
Set-StrictMode -Version Latest
$ps1 = $args[0]
$env:SHCL_BIN = $args[1]
. $ps1
function Test-Same([string]$Label, [object[]]$Got, [string[]]$Want) {
	if (($Got -join '|') -cne ($Want -join '|')) { "${Label}: [$($Got -join '|')] against [$($Want -join '|')]" }
}
function Invoke-Wrap { shcl @args }
function Invoke-Bound([string]$q) { $null = $q; shcl @args }
Test-Same 'dot-sourced' (shcl a -x:y -x: y -k:$true -n:1,2 -s:"a b" -e: -q --z:w '-x:' y) @('[a]', '[-x:y]', '[-x:]', '[y]', '[-k:True]', '[-n:1,2]', '[-s:a b]', '[-e:]', '[-q]', '[--z:w]', '[-x:]', '[y]')
Test-Same 'helper' (shcl_get f -x:y -x: y) @('[get]', '[f]', '[-x:y]', '[-x:]', '[y]')
Test-Same 'script' (& $ps1 a -x:y -x: y) @('[a]', '[-x:y]', '[-x:]', '[y]')
Test-Same 'wrapper' (Invoke-Wrap a -x:y -x: y) @('[a]', '[-x:y]', '[-x:]', '[y]')
Test-Same 'piped' ('in' | shcl a -x:y -x: y) @('[a]', '[-x:y]', '[-x:]', '[y]')
$got = shcl a -x:y `
	-x: y
Test-Same 'two lines' $got @('[a]', '[-x:y]', '[-x:]', '[y]')
Test-Same 'bound' (Invoke-Bound -q:1 -x: y) @('[-x:y]')
$PSNativeCommandArgumentPassing = 'Legacy'
Test-Same 'legacy' (shcl a -x:y -x: y -s:"a b") @('[a]', '[-x:y]', '[-x:]', '[y]', '[-s:a b]')
'done'
PSEOF
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY pwsh -NoProfile -File "${tmpDir}/sesscolon.ps1" "${repoDir}/source/powershell/shcl.ps1" "${tmpDir}/argv.sh" 2>&1 </dev/null || true)"
	[[ "${out}" == "done" ]] || fBad "shcl.ps1 from a session changed a colon argument: ${out@Q}"

	fTest EoUqEKW 20260830b-10-ps1-link-resolver
	##	20260830b item 10: the symlink resolver called a .NET 6 method that
	##	Windows PowerShell 5.1 does not have, unguarded and at load, so every
	##	dot-source on 5.1 hit it. An Env: item stands in for 5.1's method-less
	##	FileInfo. The link row is the other half: resolution still works where
	##	the method does exist.
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$ErrorActionPreference = "Stop"'
		sed -n '/^function _shcl_scriptdir/,/^}/p' "${repoDir}/source/powershell/shcl.ps1"
		echo 'try { $null = _shcl_scriptdir "Env:HOME"; Write-Output "resolved" } catch { Write-Output "threw" }'
	} > "${tmpDir}/scriptdir.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/scriptdir.ps1" 2>&1 || true)"
	[[ "${out}" == "resolved" ]] || fBad "PowerShell wrapper called a missing link resolver: ${out@Q}"
	mkdir -p "${tmpDir}/real" "${tmpDir}/lnk"
	cp "${repoDir}/source/powershell/shcl.ps1" "${tmpDir}/real/"
	ln -sf "${tmpDir}/real/shcl.ps1" "${tmpDir}/lnk/shcl.ps1"
	out="$(pwsh -NoProfile -Command ". '${tmpDir}/lnk/shcl.ps1'; Write-Output \"root=\$script:_SHCL_ROOT\"" 2>&1 || true)"
	[[ "${out}" == "root=${tmpDir}/real" ]] || fBad "PowerShell wrapper did not resolve its own symlink: ${out@Q}"

	fTest EoTJb0M 20260829-16-install-ps1-help-leaves-the-caller-alone
	##	20260829 item 16 and 20260830 item 8: the script used to end the caller's
	##	shell, and then to leave strict mode and its functions behind in it.
	##	Through a file rather than -Command, so the PowerShell keeps its own
	##	quoting instead of fighting bash's.
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo '$ErrorActionPreference = "Continue"'
		echo "& ([scriptblock]::Create((Get-Content '${repoDir}/install.ps1' -Raw))) -Help | Out-Null"
		echo 'Write-Output "eap=$ErrorActionPreference"'
		echo 'Write-Output ("fn=" + [bool](Get-Command Exit-Install -ErrorAction SilentlyContinue))'
		echo 'try { $null = @(1)[5]; Write-Output "strict=off" } catch { Write-Output "strict=on" }'
		echo 'Write-Output "alive"'
	} > "${tmpDir}/scope.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/scope.ps1" 2>&1 || true)"
	[[ "${out}" == *"alive"* ]]        || fBad "install.ps1 -Help did not return to the caller: ${out@Q}"
	[[ "${out}" == *"eap=Continue"* ]] || fBad "install.ps1 changed the caller's error preference: ${out@Q}"
	[[ "${out}" == *"fn=False"* ]]     || fBad "install.ps1 left its functions in the caller: ${out@Q}"
	[[ "${out}" == *"strict=off"* ]]   || fBad "install.ps1 left strict mode on in the caller: ${out@Q}"

	fTest Er1zTEe 20260819-21-install-ps1-help-version-refusal
	##	20260819 item 21 and 20260924c ideas 1 and 2: -Help prints the options
	##	itself, since the one-liner leaves no file for Get-Help to read; -Version
	##	names the installer; each run opens and ends on a blank line, a refusal
	##	included. The refusal is the not-Windows gate, which comes before any
	##	download.
	iver="$(sed -n "s/^\t\$installerVersion = '\(.*\)'$/\1/p" "${repoDir}/install.ps1")"
	fPs1(){ env -u DISPLAY LOCALAPPDATA="${tmpDir}/lad" pwsh -NoProfile -NonInteractive -File "${repoDir}/install.ps1" "$@" >"${tmpDir}/ps.out" 2>"${tmpDir}/ps.err" </dev/null ;}
	rc=0; fPs1 -Version || rc=$?
	if ! { [[ "${rc}" == 0 && -n "${iver}" ]] && cmp -s "${tmpDir}/ps.out" <(printf '\ninstall.ps1 %s\n\n' "${iver}"); }; then
		fBad "install.ps1 -Version (exit ${rc}): $(od -c "${tmpDir}/ps.out" | head -n 3)"
	fi
	rc=0; fPs1 -Help || rc=$?
	[[ "${rc}" == 0 && "$(head -c 60 "${tmpDir}/ps.out")" == $'\n'"install.ps1 ${iver} - shcl installer for Windows"* ]] \
		|| fBad "install.ps1 -Help does not open with its name and a blank line above (exit ${rc}): $(head -n 3 "${tmpDir}/ps.out")"
	for o in Release Target Uninstall Yes Version Help; do
		grep -qE "^    -${o} " "${tmpDir}/ps.out" || fBad "install.ps1 -Help does not list -${o}"
	done
	[[ "$(tail -c 2 "${tmpDir}/ps.out" | od -An -c | tr -d ' ')" == '\n\n' ]] || fBad "install.ps1 -Help does not end on a blank line"
	rc=0; fPs1 -Target user -Yes || rc=$?
	if ! { [[ "${rc}" == 1 ]] && cmp -s "${tmpDir}/ps.out" <(printf '\n') \
		&& cmp -s "${tmpDir}/ps.err" <(printf 'install.ps1: this installer is for Windows - on Linux, macOS or FreeBSD use install.bash, elsewhere build from source (see README.md)\n\n'); }; then
		fBad "install.ps1 does not open and end a refusal on a blank line (exit ${rc}): $(od -c "${tmpDir}/ps.out" "${tmpDir}/ps.err" | head -n 5)"
	fi

	fTest Eq8WEvQ 20260909-38-install-ps1-smoke-test-exit
	##	20260909 item 38: a smoke test binary that never started left
	##	$LASTEXITCODE at the 0 the last native command set, and the install went
	##	ahead. The stand-in cannot start because its interpreter is missing. It
	##	has the exec bit, since pwsh hands a file without one to the desktop
	##	opener.
	printf '#!/nonexistent/interp\n' > "${tmpDir}/nostart.exe"
	printf '#!/bin/sh\necho oops >&2\nexit 3\n' > "${tmpDir}/three.exe"
	printf '#!/bin/sh\necho "shcl 9.9.9"\n' > "${tmpDir}/good.exe"
	chmod 755 "${tmpDir}/nostart.exe" "${tmpDir}/three.exe" "${tmpDir}/good.exe"
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$ErrorActionPreference = "Stop"'
		sed -n '/^\tfunction Invoke-ShclSmoke/,/^\t}/p' "${repoDir}/install.ps1"
		echo "foreach (\$exe in 'nostart', 'three', 'good') {"
		echo '	& sh -c "exit 0"'
		echo "	\$r = Invoke-ShclSmoke \"${tmpDir}/\$exe.exe\""
		echo '	Write-Output "$exe=$($r.Code)"'
		echo '}'
	} > "${tmpDir}/smoke.ps1"
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY pwsh -NoProfile -File "${tmpDir}/smoke.ps1" 2>&1 || true)"
	[[ "${out}" == *"nostart=-1"* ]] || fBad "install.ps1 smoke test passed a binary that never started: ${out@Q}"
	[[ "${out}" == *"three=3"* ]]    || fBad "install.ps1 smoke test lost a nonzero exit: ${out@Q}"
	[[ "${out}" == *"good=0"* ]]     || fBad "install.ps1 smoke test failed a working binary: ${out@Q}"

	fTest EqL2dVA 20260918b-5-install-ps1-shadow-check
	##	20260918b item 5: on a first install nothing named shcl is on the
	##	session's PATH yet, and reading .Source off that nothing threw under
	##	strict mode after a good install, at exit 1. The three answers the
	##	bash twin gives: none, our own copy, someone else's copy first.
	mkdir -p "${tmpDir}/pshadow/ours" "${tmpDir}/pshadow/theirs" "${tmpDir}/pshadow/none"
	printf '#!/bin/sh\n' > "${tmpDir}/pshadow/ours/shcl"; printf '#!/bin/sh\n' > "${tmpDir}/pshadow/theirs/shcl"
	chmod 755 "${tmpDir}/pshadow/ours/shcl" "${tmpDir}/pshadow/theirs/shcl"
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$ErrorActionPreference = "Stop"'
		sed -n '/^\tfunction Get-ShclShadow/,/^\t}/p' "${repoDir}/install.ps1"
		echo "\$ours = '${tmpDir}/pshadow/ours/shcl'"
		echo "foreach (\$dirs in 'none', 'ours', 'theirs:ours') {"
		echo "	\$env:PATH = ((\$dirs -split ':') | ForEach-Object { '${tmpDir}/pshadow/' + \$_ }) -join ':'"
		echo '	try { $r = Get-ShclShadow $ours; Write-Output "$dirs=[$r]" } catch { Write-Output "$dirs=threw $_" }'
		echo '}'
	} > "${tmpDir}/shadow.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/shadow.ps1" 2>&1 || true)"
	[[ "${out}" == *"none=[]"* ]] || fBad "install.ps1 fails when no shcl is on PATH yet: ${out@Q}"
	[[ "${out}" == *"ours=[]"* ]] || fBad "install.ps1 called its own copy a shadow: ${out@Q}"
	[[ "${out}" == *"theirs:ours=[${tmpDir}/pshadow/theirs/shcl]"* ]] || fBad "install.ps1 did not see the copy shadowing it: ${out@Q}"

	fTest EqL2cyu 20260918b-36-install-ps1-no-response-status
	##	20260918b item 36: a request with no response at all (DNS, a refused
	##	port, a proxy) has no status, and reading one threw under strict mode,
	##	so the network-down message was never printed. A 403 still has to read
	##	as 403, or a rate limit goes back to looking like a dead network.
	python3 - "${tmpDir}/httpport" <<'SRVEOF' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
	def do_GET(self):
		self.send_response(403); self.send_header('Content-Length', '0'); self.end_headers()
	def log_message(self, *a):
		pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(s.server_address[1]))
s.serve_forever()
SRVEOF
	httpPid=$!
	for _ in {1..50}; do [[ -s "${tmpDir}/httpport" ]] && break; sleep 0.1; done
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$ErrorActionPreference = "Stop"'
		sed -n '/^\tfunction Get-HttpStatus/,/^\t}/p' "${repoDir}/install.ps1"
		echo "foreach (\$url in 'http://127.0.0.1:9/', 'http://127.0.0.1:$(cat "${tmpDir}/httpport" 2>/dev/null || true)/') {"
		echo '	try { $null = Invoke-RestMethod -Uri $url -UseBasicParsing; Write-Output "no error" } catch { try { Write-Output ("status=" + (Get-HttpStatus $_)) } catch { Write-Output "threw $_" } }'
		echo '}'
	} > "${tmpDir}/status.ps1"
	out="$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy pwsh -NoProfile -File "${tmpDir}/status.ps1" 2>&1 || true)"
	kill "${httpPid}" 2>/dev/null || true
	[[ "${out}" == *"status=0"* ]]   || fBad "install.ps1 cannot read a request that got no response: ${out@Q}"
	[[ "${out}" == *"status=403"* ]] || fBad "install.ps1 lost the status of a refused request: ${out@Q}"

	fTest EqL2bgG 20260918b-11-36-install-ps1-network-down
	##	20260918b items 11 and 36, end to end: the real script with only its
	##	Windows refusal cut out, every request sent to a proxy that is not
	##	there. An uninstall needs no release and must not wait on the API, and
	##	an install with the network down has to say so. The uninstall's PATH
	##	edit then fails for want of a registry; the rows are about what comes
	##	before it.
	#  shellcheck disable=2016  ## PowerShell's own $IsWindows, matched literally.
	sed '/-and -not \$IsWindows) {$/,/^\t}$/d' "${repoDir}/install.ps1" > "${tmpDir}/nogate.ps1"
	if (($(wc -l < "${repoDir}/install.ps1") - $(wc -l < "${tmpDir}/nogate.ps1") != 3)) || grep -q 'IsWindows' "${tmpDir}/nogate.ps1"; then
		fBad "install.ps1's Windows refusal is not the three-line block these rows cut out"
	fi
	fNoNetFile(){ local file="$1"; shift; env -u DISPLAY -u GITHUB_TOKEN -u NO_PROXY -u no_proxy PROCESSOR_ARCHITECTURE=AMD64 LOCALAPPDATA="${tmpDir}/lad" \
		HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
		pwsh -NoProfile -NonInteractive -File "${file}" "$@" 2>&1 </dev/null ;}
	fNoNet(){ fNoNetFile "${tmpDir}/nogate.ps1" "$@" ;}
	mkdir -p "${tmpDir}/lad/Programs/Shcl/code"
	printf 'x\n' > "${tmpDir}/lad/Programs/Shcl/shcl.exe"; printf 'x\n' > "${tmpDir}/lad/Programs/Shcl/code/lib.rs"
	out="$(fNoNet -Uninstall -Target user -Yes || true)"
	[[ "${out}" == *"removing shcl:"* ]] || fBad "install.ps1 -Uninstall needed the network before removing anything: ${out@Q}"
	[[ -e "${tmpDir}/lad/Programs/Shcl/shcl.exe" || -e "${tmpDir}/lad/Programs/Shcl/code/lib.rs" ]] \
		&& fBad "install.ps1 -Uninstall left its files with the network down"
	out="$(fNoNet -Target user -Yes || true)"
	[[ "${out}" == *"cannot fetch the stable release (none published yet, or network down)"* ]] \
		|| fBad "install.ps1 does not say the network is down: ${out@Q}"
	fTest EqzwPFG 20260830-8-install-ps1-under-iex
	##	20260830 item 8 and 20260829 item 16 under the documented `irm | iex`.
	##	The scriptblock row above is a child scope, which passed without the
	##	body's own scope, and it runs only -Help. Here the install fails on the
	##	network, and the caller keeps its session, its error preference and its
	##	strict mode, and gets none of the installer's functions. All in one
	##	block: at a file's top level iex sees the file as its caller, which a
	##	prompt does not.
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo '& {'
		echo '$ErrorActionPreference = "Continue"'
		echo "try { Get-Content -Raw -LiteralPath '${tmpDir}/nogate.ps1' | Invoke-Expression; Write-Output 'threw=no' } catch { Write-Output \"threw=\$_\" }"
		echo 'Write-Output "eap=$ErrorActionPreference"'
		echo 'Write-Output ("fn=" + [bool](Get-Command Exit-Install -ErrorAction SilentlyContinue))'
		echo 'try { $null = @(1)[5]; Write-Output "strict=off" } catch { Write-Output "strict=on" }'
		echo 'Write-Output "alive"'
		echo '}'
	} > "${tmpDir}/iex.ps1"
	out="$(fNoNetFile "${tmpDir}/iex.ps1" || true)"
	[[ "${out}" == *"alive"* ]]        || fBad "install.ps1 under iex ended the caller's session on a failure: ${out@Q}"
	[[ "${out}" == *"threw=install.ps1: cannot fetch the stable release"* ]] \
		|| fBad "install.ps1 under iex did not throw its failure to the caller: ${out@Q}"
	[[ "${out}" == *"eap=Continue"* ]] || fBad "install.ps1 under iex changed the caller's error preference: ${out@Q}"
	[[ "${out}" == *"fn=False"* ]]     || fBad "install.ps1 under iex left its functions in the caller: ${out@Q}"
	[[ "${out}" == *"strict=off"* ]]   || fBad "install.ps1 under iex left strict mode on in the caller: ${out@Q}"

	fTest EqqXKMK 20260924d-1-3-install-ps1-plan-line
	##	20260924d items 1 and 3: the plan line, from a fixed release list in
	##	place of the API. An inner [bool]$Version once took the release's
	##	$version, since names ignore case, and every install asked for
	##	shcl-True. Stable keeps the full release while dev takes the beta.
	printf '[{"tag_name":"v2.0.0","prerelease":false,"draft":false},{"tag_name":"v3.0.0-beta1","prerelease":true,"draft":false}]\n' > "${tmpDir}/rel.json"
	#  shellcheck disable=2016  ## PowerShell's own $Release, matched literally.
	sed "/^\tparam(\[string\]\$Release, /a\\
\tfunction Invoke-RestMethod { Get-Content -Raw -LiteralPath '${tmpDir}/rel.json' | ConvertFrom-Json }" "${tmpDir}/nogate.ps1" > "${tmpDir}/fakeapi.ps1"
	grep -q '^	function Invoke-RestMethod' "${tmpDir}/fakeapi.ps1" || fBad "install.ps1's inner param line moved; the fake API row found nowhere to go"
	for release in stable dev; do
		out="$(env -u DISPLAY PROCESSOR_ARCHITECTURE=AMD64 LOCALAPPDATA="${tmpDir}/lad" pwsh -NoProfile -NonInteractive -File "${tmpDir}/fakeapi.ps1" -Release "${release}" < /dev/null 2>&1 || true)"
		want="shcl 2.0.0 (stable, windows-x86_64)"; [[ "${release}" == dev ]] && want="shcl 3.0.0-beta1 (dev, windows-x86_64)"
		[[ "${out}" == *"${want}"* ]] || fBad "install.ps1 -Release ${release} planned the wrong install: ${out@Q}"
		##	20260924c idea 4: the plan names the release page it installs from.
		want="  from     https://github.com/yottacore/shcl/releases/tag/v2.0.0"; [[ "${release}" == dev ]] && want="${want%/*}/v3.0.0-beta1"
		[[ "${out}" == *"${want}"* ]] || fBad "install.ps1 -Release ${release} plan does not name its release page: ${out@Q}"
	done

	fTest Eqbtld2 20260921-idea6-install-ps1-uninstall-held-file
	##	20260921 idea 6: a file the uninstall could not remove, which a running
	##	shcl.exe causes on Windows, went unsaid, and the dir it kept was blamed
	##	on files the installer never wrote. A read-only dir stands in for the
	##	lock. The PATH entry waits for a clean second run, so this run gets as
	##	far as the message.
	mkdir -p "${tmpDir}/lad/Programs/Shcl/code"
	printf 'x\n' > "${tmpDir}/lad/Programs/Shcl/shcl.exe"; printf 'x\n' > "${tmpDir}/lad/Programs/Shcl/code/lib.rs"
	chmod 555 "${tmpDir}/lad/Programs/Shcl/code"
	out="$(fNoNet -Uninstall -Target user -Yes || true)"
	chmod 755 "${tmpDir}/lad/Programs/Shcl/code"
	[[ "${out}" == *"could not remove ${tmpDir}/lad/Programs/Shcl/code/lib.rs"* ]] \
		|| fBad "install.ps1 -Uninstall hid a file it could not remove: ${out@Q}"
	[[ "${out}" == *"did not put there"* ]] && fBad "install.ps1 -Uninstall blamed its own file on someone else: ${out@Q}"
	##	The other answers, from the function itself: a clean removal takes the
	##	dir, and a file nobody installed keeps it and says so. The dirs are
	##	named relative, which reads back written differently from the path
	##	given, as a short 8.3 name does on windows. A file that would not go
	##	was then counted as someone else's.
	mkdir -p "${tmpDir}/rmfile/clean/code" "${tmpDir}/rmfile/other/scripts" "${tmpDir}/rmfile/held/code"
	printf 'x\n' > "${tmpDir}/rmfile/clean/shcl.exe"; printf 'x\n' > "${tmpDir}/rmfile/clean/code/lib.rs"
	printf 'x\n' > "${tmpDir}/rmfile/other/shcl.exe"; printf 'x\n' > "${tmpDir}/rmfile/other/scripts/mine.txt"
	printf 'x\n' > "${tmpDir}/rmfile/held/shcl.exe"; printf 'x\n' > "${tmpDir}/rmfile/held/code/lib.rs"
	chmod 555 "${tmpDir}/rmfile/held/code"
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$ErrorActionPreference = "Stop"'
		sed -n '/^\tfunction Remove-ShclFile/,/^\t}/p' "${repoDir}/install.ps1"
		echo "Set-Location -LiteralPath '${tmpDir}/rmfile'"
		echo "foreach (\$dir in 'clean', 'other', 'held') {"
		echo '	$r = Remove-ShclFile -Dest $dir'
		echo '	Write-Output ("{0}: stuck=[{1}] foreign={2}" -f $dir, ($r.Stuck -join ","), $r.Foreign)'
		echo '}'
	} > "${tmpDir}/rmfile.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/rmfile.ps1" 2>&1 || true)"
	chmod 755 "${tmpDir}/rmfile/held/code"
	[[ "${out}" == *"held: stuck=[held/code/lib.rs] foreign=False"* ]] \
		|| fBad "install.ps1 -Uninstall called its own locked file someone else's: ${out@Q}"
	[[ "${out}" == *"clean: stuck=[] foreign=False"* && ! -e "${tmpDir}/rmfile/clean" ]] \
		|| fBad "install.ps1 -Uninstall did not remove a clean install whole: ${out@Q}"
	[[ "${out}" == *"other: stuck=[] foreign=True"* && -e "${tmpDir}/rmfile/other/scripts/mine.txt" && ! -e "${tmpDir}/rmfile/other/shcl.exe" ]] \
		|| fBad "install.ps1 -Uninstall mishandled a file it did not install: ${out@Q}"

	fTest Eq8WEvR 20260909-38-shclpath-fails-without-registry
	##	20260909 item 38: the setup's PATH script exited 0 when it could not
	##	write, so the setup's fallback message never showed. There is no
	##	registry here at all, which is a failure it must report.
	pwsh -NoProfile -File "${repoDir}/cicd/packaging/shclpath.ps1" -Dir /shcl-regress >/dev/null 2>&1 \
		&& fBad "shclpath.ps1 exited 0 with no registry to write"
else
	echo "shell-regress: pwsh not installed - PowerShell rows skipped"
	fTestSkipBlock
fi

fTest Eojt4B6 20260830b-12-system-install-modes
##	20260830b item 12: nothing set the modes on a system install, and sudo keeps
##	the caller's umask, so under 077 the tree and the launcher came out 0700 and
##	only root could run what had just been installed for everyone. 20260901b
##	item 16: the widening covered the install root alone, and a man1 directory
##	the installer had to create stayed root-only. The installer's own lay-down
##	step runs here on a staged payload, under that umask, into a sandbox whose
##	bin and man1 directories do not exist yet.
eval "$(sed -n '/^fWidenModes()/,/^}/p;/^fTopMissing()/,/^}/p;/^fLinkOwner()/,/^}/p;/^fLayDown()/,/^}/p' "${repoDir}/install.bash")"
(
	umask 077
	mkdir -p "${tmpDir}/stage/code" "${tmpDir}/stage/scripts" "${tmpDir}/stage/man" "${tmpDir}/stage/completions" "${tmpDir}/sys/usr/local/share"
	printf 'bin\n'  > "${tmpDir}/stage/shcl";      chmod 700 "${tmpDir}/stage/shcl"
	printf 'data\n' > "${tmpDir}/stage/code/lib.rs"
	printf 'data\n' > "${tmpDir}/stage/scripts/shcl.bash"
	printf 'man\n'  > "${tmpDir}/stage/man/shcl.1"
	printf 'comp\n' > "${tmpDir}/stage/completions/shcl.bash"
	## The installer's own globals, as the lifted function reads them.
	# shellcheck disable=SC2034
	asroot="" tmp="${tmpDir}/stage" dest="${tmpDir}/sys/opt/shcl" link="${tmpDir}/sys/usr/local/bin/shcl"
	# shellcheck disable=SC2034
	manlink="${tmpDir}/sys/usr/local/share/man/man1/shcl.1" target=system have_dropins=1 have_docs=1
	fLayDown
)
while IFS= read -r row; do
	case "${row}" in
		"755 d "*|"755 f ${tmpDir}/sys/opt/shcl/shcl"|"644 f "*|"777 l "*) ;;
		*) fBad "install.bash left a system install unreadable: ${row}" ;;
	esac
done < <(find "${tmpDir}/sys/opt" "${tmpDir}/sys/usr/local/bin" "${tmpDir}/sys/usr/local/share/man" -printf '%m %y %p\n' | sort)
[[ -L "${tmpDir}/sys/usr/local/share/man/man1/shcl.1" ]] || fBad "install.bash did not link the man page"

fTest EqL4FOi 20260918b-41-man-link-not-ours
##	20260918b item 41: the man link kept the older test, a symlink or nothing,
##	so a man1/shcl.1 linking to a stow or hand-built copy was repointed at ours
##	and the uninstall then deleted it as ours. A user install into a scratch
##	HOME, laid down by the lifted step, then removed by the real script, which
##	needs no network to uninstall.
nBadBefore="${nBad}"
(
	uhome="${tmpDir}/manhome"; mkdir -p "${uhome}/.local/share/man/man1" "${uhome}/stow"
	printf 'theirs\n' > "${uhome}/stow/shcl.1"
	ln -s "${uhome}/stow/shcl.1" "${uhome}/.local/share/man/man1/shcl.1"
	# shellcheck disable=SC2034
	asroot="" tmp="${tmpDir}/stage" dest="${uhome}/.local/share/shcl" link="${uhome}/.local/bin/shcl"
	# shellcheck disable=SC2034
	manlink="${uhome}/.local/share/man/man1/shcl.1" target=user have_dropins=1 have_docs=1
	man_note=""
	fLayDown
	[[ "$(readlink -- "${manlink}")" == "${uhome}/stow/shcl.1" ]] || fBad "install.bash repointed a man link that was not its own"
	[[ "${man_note:-}" == *"links to ${uhome}/stow/shcl.1"* ]] || fBad "install.bash left someone else's man link without saying so: ${man_note@Q}"
	HOME="${uhome}" bash "${repoDir}/install.bash" --uninstall --target=user --yes >/dev/null 2>&1 || fBad "install.bash --uninstall failed"
	[[ -L "${manlink}" && -e "${uhome}/stow/shcl.1" ]] || fBad "install.bash --uninstall removed a man link that was not its own"
	[[ -e "${dest}/shcl" ]] && fBad "install.bash --uninstall left its own binary"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))

fTest Er8AaLE 20260924d-idea2-uninstall-nothing-there
##	20260924d idea 2: --uninstall said "removed" in a home with no install.
nh="${tmpDir}/nothinghome"; mkdir -p "${nh}"
out="$(HOME="${nh}" bash "${repoDir}/install.bash" --uninstall --target=user --yes 2>&1 || true)"
[[ "${out}" == *"nothing to remove"* && "${out}" != *removed* ]] || fBad "install.bash --uninstall with nothing installed said: ${out@Q}"

fTest EonXwm8 20260901b-34-uninstall-globs-as-root
##	20260901b item 34: the uninstall's payload globs used to expand in the
##	unprivileged shell that called sudo, so a system tree only root could list
##	left them unexpanded - nothing was removed and the run then reported the
##	install directory as holding files it had not put there. The stand-in below
##	is what privilege buys: a directory the calling shell cannot read and the
##	command it runs can.
eval "$(sed -n '/^fRemoveLaidDown()/,/^}/p' "${repoDir}/install.bash")"
nBadBefore="${nBad}"
(
	udir="${tmpDir}/uninst"
	mkdir -p "${udir}/code" "${udir}/scripts" "${udir}/man" "${udir}/completions"
	printf 'x\n' > "${udir}/code/lib.rs"
	printf 'x\n' > "${udir}/scripts/shcl.bash"
	printf 'x\n' > "${udir}/man/shcl.1"
	printf 'x\n' > "${udir}/completions/shcl.bash"
	export SHCL_TEST_LOCKED="${udir}/code"
	cat > "${tmpDir}/asroot" <<-'EOS'
		#!/bin/bash
		chmod 700 "${SHCL_TEST_LOCKED}"
		"$@"; rc=$?
		[[ -d "${SHCL_TEST_LOCKED}" ]] && chmod 000 "${SHCL_TEST_LOCKED}"
		exit "${rc}"
	EOS
	chmod 755 "${tmpDir}/asroot"
	chmod 000 "${udir}/code"
	# shellcheck disable=SC2034  ## the lifted function's own global
	asroot="${tmpDir}/asroot"
	fRemoveLaidDown "${udir}"
	chmod 700 "${udir}/code" 2>/dev/null || true
	for d in code scripts man completions; do
		[[ -e "${udir}/${d}" ]] && fBad "install.bash uninstall left ${d} behind"
	done
	rmdir "${udir}" 2>/dev/null || fBad "install.bash uninstall did not empty the install directory"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))

fTest Eq8WEvS 20260909-38-uninstall-removes-only-its-files
##	20260909 item 38: the uninstall emptied code/ and scripts/ by glob, taking
##	files the installer never wrote, and left the staging file an interrupted
##	install drops.
nBadBefore="${nBad}"
(
	udir="${tmpDir}/uninst-mine"
	mkdir -p "${udir}/code" "${udir}/scripts" "${udir}/man" "${udir}/completions"
	for f in code/lib.rs code/shcl.go code/shcl.py code/shcl.h code/shcl.hpp scripts/shcl.bash scripts/shcl.ps1 man/shcl.1 completions/shcl.bash completions/_shcl .shcl.new; do
		printf 'x\n' > "${udir}/${f}"
	done
	printf 'mine\n' > "${udir}/code/local.rs"
	# shellcheck disable=SC2034  ## the lifted function's own global
	asroot=""
	fRemoveLaidDown "${udir}"
	[[ -f "${udir}/code/local.rs" ]] || fBad "install.bash uninstall deleted a file it never installed"
	[[ -e "${udir}/code/lib.rs" ]] && fBad "install.bash uninstall left an installed file behind"
	[[ -e "${udir}/.shcl.new" ]] && fBad "install.bash uninstall left the staging file behind"
	for d in scripts man completions; do
		[[ -e "${udir}/${d}" ]] && fBad "install.bash uninstall left ${d} behind"
	done
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))

fTest EonYwwy 20260901b-36-bin-link-owner
##	20260901b item 36: only a real file at the bin path was refused, so a
##	symlink to a cargo-built or hand-built copy was replaced with nothing said.
eval "$(sed -n '/^fLinkOwner()/,/^}/p' "${repoDir}/install.bash")"
nBadBefore="${nBad}"
(
	odir="${tmpDir}/owner"; mkdir -p "${odir}/dest" "${odir}/bin" "${odir}/other"
	printf 'x\n' > "${odir}/dest/shcl"; printf 'x\n' > "${odir}/other/shcl"
	[[ "$(fLinkOwner "${odir}/bin/shcl" "${odir}/dest")" == "free" ]] \
		|| fBad "install.bash refused a bin path with nothing at it"
	ln -s "${odir}/dest/shcl" "${odir}/bin/shcl"
	[[ "$(fLinkOwner "${odir}/bin/shcl" "${odir}/dest")" == "ours" ]] \
		|| fBad "install.bash refused its own link"
	ln -sfn "${odir}/other/shcl" "${odir}/bin/shcl"
	[[ "$(fLinkOwner "${odir}/bin/shcl" "${odir}/dest")" == "elsewhere ${odir}/other/shcl" ]] \
		|| fBad "install.bash would replace a symlink pointing somewhere else"
	rm -f "${odir}/bin/shcl"; printf 'x\n' > "${odir}/bin/shcl"
	[[ "$(fLinkOwner "${odir}/bin/shcl" "${odir}/dest")" == "file" ]] \
		|| fBad "install.bash would replace a real file at the bin path"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))

fTest EonZGyu 20260901b-37-shadowing-copy-seen
##	20260901b item 37: the receipt ran the link the installer had just written,
##	so another shcl earlier on PATH was invisible and the next one the user
##	typed was someone else's.
eval "$(sed -n '/^fShadowedBy()/,/^}/p' "${repoDir}/install.bash")"
nBadBefore="${nBad}"
(
	sdir="${tmpDir}/shadow"; mkdir -p "${sdir}/ours" "${sdir}/theirs"
	printf '#!/bin/sh\necho ours\n' > "${sdir}/ours/shcl"; chmod 755 "${sdir}/ours/shcl"
	printf '#!/bin/sh\necho theirs\n' > "${sdir}/theirs/shcl"; chmod 755 "${sdir}/theirs/shcl"
	PATH="${sdir}/ours:${PATH}" fShadowedBy "${sdir}/ours/shcl" >/dev/null \
		&& fBad "install.bash called its own copy a shadow"
	out="$(PATH="${sdir}/theirs:${sdir}/ours:${PATH}" fShadowedBy "${sdir}/ours/shcl" || true)"
	[[ "${out}" == "${sdir}/theirs/shcl" ]] \
		|| fBad "install.bash did not see the copy shadowing it: ${out@Q}"
	PATH="${sdir}/nowhere:/nonexistent" fShadowedBy "${sdir}/ours/shcl" >/dev/null \
		&& fBad "install.bash reported a shadow where there is no shcl at all"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))
##	The install.ps1 half was a source grep, and it passed while the check it
##	looked for threw on every first install (20260918b item 5). The pwsh block
##	runs Get-ShclShadow over the same three answers instead.
# grep -q 'Get-Command shcl -ErrorAction SilentlyContinue' "${repoDir}/install.ps1" \
# 	|| fBad "install.ps1 never asks what shcl resolves to on PATH"

fTest EonZtk8 20260901b-39-read-only-home-probed-first
##	20260901b item 39: a read-only HOME got through both downloads and then
##	failed on a raw mkdir error. The destinations are probed first, and the
##	probe has to walk up to whatever exists.
eval "$(sed -n '/^fNearestExisting()/,/^}/p' "${repoDir}/install.bash")"
nBadBefore="${nBad}"
(
	wdir="${tmpDir}/writable"; mkdir -p "${wdir}/home"
	[[ "$(fNearestExisting "${wdir}/home/.local/share/shcl")" == "${wdir}/home" ]] \
		|| fBad "install.bash did not walk up to the nearest existing directory"
	[[ "$(fNearestExisting "${wdir}/home")" == "${wdir}/home" ]] \
		|| fBad "install.bash did not accept a directory that is already there"
	chmod 500 "${wdir}/home"
	near="$(fNearestExisting "${wdir}/home/.local/share/shcl")"
	[[ -w "${near}" ]] && fBad "install.bash would have downloaded into a read-only home"
	chmod 700 "${wdir}/home"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))
# shellcheck disable=SC2016  ## install.bash's own $variable, matched literally
downloadLine="$( { grep -n 'downloading \${asset}' "${repoDir}/install.bash" || true; } | head -n1 | cut -d: -f1)"
probeLine="$( { grep -n 'is not writable' "${repoDir}/install.bash" || true; } | head -n1 | cut -d: -f1)"
if [[ -z "${downloadLine}" || -z "${probeLine}" ]] || ((probeLine >= downloadLine)); then
	fBad "install.bash downloads before it knows the destination can be written"
fi

fTest EqzwPFH 20260829-17-smoke-test-and-glibc-floors
##	20260829 item 17: the binary first ran after it was installed, so a box
##	below its glibc floor got a raw loader error over a broken install. The
##	lifted smoke step, on a stand-in failing the way the loader does, one the
##	temp dir cannot execute, and one that runs. It has to come before the
##	lay-down, which is the rest of the fix.
# shellcheck disable=SC2016  ## install.bash's own text, matched literally
smokeCode="$(sed -n '/^fDie() /p;/^case "\${osname}-\${arch}" in$/,/^esac$/p;/^smoke_status=0$/,/^fi$/p' "${repoDir}/install.bash")"
mkdir -p "${tmpDir}/smoke"
fSmoke(){   ## fSmoke EXIT [ARCH [OS]]: the lifted step on a stand-in that exits EXIT
	printf '#!/bin/sh\necho "shcl: version GLIBC_2.34 not found" >&2\nexit %s\n' "$1" > "${tmpDir}/smoke/shcl"
	chmod 755 "${tmpDir}/smoke/shcl"
	# shellcheck disable=SC2034  ## the lifted step's own globals
	( tmp="${tmpDir}/smoke" arch="${2:-x86_64}" osname="${3:-linux}"; eval "${smokeCode}"; echo "smoke passed" ) 2>&1 || true
}
out="$(fSmoke 127)"
[[ "${out}" == *"needs glibc 2.34 or newer"*"cargo install shcl"* && "${out}" != *"smoke passed"* ]] \
	|| fBad "install.bash does not stop on a binary below its glibc floor, naming the floor and cargo install: ${out@Q}"
##	20260830 item 42: the arm64 binary is built against an older glibc, and the
##	message named the x86_64 floor for both.
out="$(fSmoke 127 arm64)"
line="$(grep -F 'does not run here' <<<"${out}" || true)"
[[ "${line}" == *"needs glibc 2.30 or newer"* && "${line}" != *"2.34"* && "${out}" != *"smoke passed"* ]] \
	|| fBad "install.bash names the wrong glibc floor for arm64: ${out@Q}"
out="$(fSmoke 1 x86_64 freebsd)"
line="$(grep -F 'does not run here' <<<"${out}" || true)"
[[ "${line}" == *"freebsd-x86_64 binary"*"FreeBSD 14 or newer"* && "${line}" != *glibc* && "${line}" != *musl* ]] \
	|| fBad "install.bash names a Linux floor for the FreeBSD binary: ${out@Q}"
out="$(fSmoke 126)"
[[ "${out}" == *"noexec"* && "${out}" != *"smoke passed"* ]] || fBad "install.bash does not name a temp dir it cannot execute from: ${out@Q}"
out="$(fSmoke 0)"
[[ "${out}" == "smoke passed" ]] || fBad "install.bash stopped on a binary that runs: ${out@Q}"
smokeLine="$( { grep -n '^smoke_status=0$' "${repoDir}/install.bash" || true; } | head -n1 | cut -d: -f1)"
layLine="$( { grep -n '^fLayDown$' "${repoDir}/install.bash" || true; } | head -n1 | cut -d: -f1)"
if [[ -z "${smokeLine}" || -z "${layLine}" ]] || ((smokeLine >= layLine)); then
	fBad "install.bash does not run the binary before laying it down"
fi

fTest ErxeImU 2026100313461652-install-bash-macos-floor
##	The universal binary is built for macOS 13 and up, and dyld refuses it
##	below that with a raw abort. The lifted smoke step names that floor.
out="$(fSmoke 134 universal macos)"
line="$(grep -F 'does not run here' <<<"${out}" || true)"
[[ "${line}" == *"macos-universal binary"*"macOS 13 or newer"* && "${line}" != *glibc* && "${line}" != *musl* && "${out}" != *"smoke passed"* ]] \
	|| fBad "install.bash does not name the macOS floor for the macOS binary: ${out@Q}"

fTest EqzwPFI 20260829-19-uninstall-hint-under-one-liner
##	20260829 item 19: the uninstall hint printed $0, which under the one-liner
##	is a descriptor or `bash`. The three lifted lines, run each way a script
##	reaches bash: the pipe form and the stdin form get the documented one-liner,
##	and a file gets its own path.
rerunCode="$(grep -F -e 'rerun=' -e 'to remove it again: ' "${repoDir}/install.bash" || true)"
if [[ "$(grep -c . <<<"${rerunCode}")" != 3 ]]; then
	fBad "install.bash's uninstall hint is not the three lines this row lifts: ${rerunCode@Q}"
else
	printf 'target=user\n%s\n' "${rerunCode}" > "${tmpDir}/rerun.bash"
	oneLiner="bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)"
	grep -qF -- "${oneLiner}" "${repoDir}/README.md" || fBad "the README no longer documents the one-liner install.bash names: ${oneLiner}"
	out="$(bash <(cat "${tmpDir}/rerun.bash"))"
	[[ "${out}" == "to remove it again: ${oneLiner} --uninstall --target=user" ]] || fBad "install.bash's uninstall hint under the one-liner: ${out@Q}"
	out="$(cd "${tmpDir}" && bash < "${tmpDir}/rerun.bash")"
	[[ "${out}" == "to remove it again: ${oneLiner} --uninstall --target=user" ]] || fBad "install.bash's uninstall hint when piped: ${out@Q}"
	out="$(bash "${tmpDir}/rerun.bash")"
	[[ "${out}" == "to remove it again: ${tmpDir}/rerun.bash --uninstall --target=user" ]] || fBad "install.bash's uninstall hint from a file: ${out@Q}"
fi

fTest EqzwPFJ 20260803-21-system-link-in-a-bin-dir
##	20260803 item 21: a system install linked into an administrator's sbin,
##	which the user who ran the installer does not have on PATH.
# shellcheck disable=SC2016  ## install.bash's own text, matched literally
sysLink="$(sed -n '/^if \[\[ "\${target}" == "system" \]\]; then$/,/^else$/{s/^[[:space:]]*link="\(.*\)"$/\1/p}' "${repoDir}/install.bash")"
[[ "${sysLink}" == /*/bin/shcl ]] || fBad "install.bash links a system install at ${sysLink@Q}, not in a bin dir"

fTest Eonalqy 20260901b-40-fresh-clone-starts-on-dev
##	20260901b item 40: a fresh clone was left on main while contributing.md says
##	to branch from dev. The lifted function decides; an existing checkout or an
##	edited tree is left where it is.
eval "$(sed -n '/^fStartOnDev()/,/^}/p' "${repoDir}/install-dev.bash")"
nBadBefore="${nBad}"
(
	unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX GIT_CONFIG_COUNT
	gdir="${tmpDir}/devclone"; mkdir -p "${gdir}/origin"
	git -C "${gdir}/origin" init -q --initial-branch=main
	git -C "${gdir}/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
	git -C "${gdir}/origin" branch dev
	git clone -q --no-hardlinks "${gdir}/origin" "${gdir}/a" 2>/dev/null
	fStartOnDev "${gdir}/a"
	[[ "$(git -C "${gdir}/a" branch --show-current)" == "dev" ]] \
		|| fBad "install-dev.bash left a fresh clone on main"
	git clone -q --no-hardlinks "${gdir}/origin" "${gdir}/b" 2>/dev/null
	printf 'x\n' > "${gdir}/b/edited"
	git -C "${gdir}/b" add edited
	fStartOnDev "${gdir}/b"
	[[ "$(git -C "${gdir}/b" branch --show-current)" == "main" ]] \
		|| fBad "install-dev.bash moved a clone with work already in it"
	mkdir -p "${gdir}/mainonly"
	git -C "${gdir}/mainonly" init -q --initial-branch=main
	git -C "${gdir}/mainonly" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
	git clone -q --no-hardlinks "${gdir}/mainonly" "${gdir}/c" 2>/dev/null
	fStartOnDev "${gdir}/c"
	[[ "$(git -C "${gdir}/c" branch --show-current)" == "main" ]] \
		|| fBad "install-dev.bash moved a clone of a repo with no dev branch"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))

fTest Eonalqz 20260901b-41-rate-limit-named
##	20260901b item 41: an unauthenticated 403 is the API's rate limit and both
##	installers called it "none published yet, or network down". The status
##	itself comes from curl; what is checked here is what each status is called.
eval "$(sed -n '/^fApiFailure()/,/^}/p' "${repoDir}/install.bash")"
[[ "$(fApiFailure 403 stable)" == *"rate limit"* ]] || fBad "install.bash does not call a 403 a rate limit"
[[ "$(fApiFailure 429 stable)" == *"rate limit"* ]] || fBad "install.bash does not call a 429 a rate limit"
[[ "$(fApiFailure 401 stable)" == *"GITHUB_TOKEN"* ]] || fBad "install.bash does not blame the token for a 401"
[[ "$(fApiFailure 404 stable)" == *"none published yet"* ]] || fBad "install.bash calls a 404 a rate limit"
[[ "$(fApiFailure 000 dev)" == *"dev release"* ]] || fBad "install.bash does not name the channel when it cannot reach the API"
grep -q 'rate limit' "${repoDir}/install.bash" || fBad "install.bash does not name a rate limit"
grep -q 'rate limit' "${repoDir}/install.ps1"  || fBad "install.ps1 does not name a rate limit"
grep -q 'GITHUB_TOKEN' "${repoDir}/install.bash" || fBad "install.bash ignores GITHUB_TOKEN"
grep -q 'GITHUB_TOKEN' "${repoDir}/install.ps1"  || fBad "install.ps1 ignores GITHUB_TOKEN"

fTest EqL3dg0 20260918b-37-token-not-sent-on-downloads
##	20260918b item 37: the token rode on every download, and each release
##	download redirects to another host. curl drops the header there and wget
##	1.x sends it on. Two local https listeners, the first redirecting to the
##	second under another name, and install.bash's own fetch lines for each
##	tool: a download sends no token anywhere, the API calls send it.
if fHave openssl && fHave wget && fHave curl; then
	tdir="${tmpDir}/token"; mkdir -p "${tdir}"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' \
		-keyout "${tdir}/key.pem" -out "${tdir}/cert.pem" 2>/dev/null
	python3 - "${tdir}" <<'SRVEOF' &
import http.server, ssl, sys, threading
d = sys.argv[1]
def serve(name, redirect_to):
	class H(http.server.BaseHTTPRequestHandler):
		def do_GET(self):
			open(f'{d}/{name}.log', 'a').write(f'{self.path} auth={self.headers.get("Authorization")}\n')
			if redirect_to and self.path.startswith('/download'):
				self.send_response(302); self.send_header('Location', redirect_to() + self.path)
				self.send_header('Content-Length', '0'); self.end_headers()
				return
			if redirect_to and self.path.startswith('/tohttp'):
				self.send_response(302); self.send_header('Location', f'http://127.0.0.1:{plain.server_address[1]}' + self.path)
				self.send_header('Content-Length', '0'); self.end_headers()
				return
			self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'ok')
		def log_message(self, *a):
			pass
	srv = http.server.HTTPServer(('127.0.0.1', 0), H)
	if name != 'plain':
		ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(f'{d}/cert.pem', f'{d}/key.pem')
		srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
	return srv
plain = serve('plain', None)
threading.Thread(target=plain.serve_forever, daemon=True).start()
asset = serve('asset', None)
origin = serve('origin', lambda: f'https://localhost:{asset.server_address[1]}')
threading.Thread(target=asset.serve_forever, daemon=True).start()
open(f'{d}/port', 'w').write(str(origin.server_address[1]))
origin.serve_forever()
SRVEOF
	tokenPid=$!
	for _ in {1..50}; do [[ -s "${tdir}/port" ]] && break; sleep 0.1; done
	printf 'ca_certificate = %s\n' "${tdir}/cert.pem" > "${tdir}/wgetrc"
	for tool in curl wget; do
		defs="$(sed -n "/^\tfWget() { ${tool} /p;/^\tfWget() { local /p;/^\tfFetch() { /p;/^\tfFetchApi() { /p;/^\tfApiStatus() { ${tool} /p" "${repoDir}/install.bash" | { if [[ "${tool}" == curl ]]; then grep -v 'fWget\|() { wget '; else grep -v '() { curl '; fi; } || true)"
		(
			eval "${defs}"
			export GITHUB_TOKEN=regress-token CURL_CA_BUNDLE="${tdir}/cert.pem" WGETRC="${tdir}/wgetrc"
			url="https://127.0.0.1:$(cat "${tdir}/port")"
			fFetch "${url}/download/${tool}" "${tdir}/out-${tool}" || echo "fFetch failed" >> "${tdir}/${tool}.err"
			fFetchApi "${url}/api/${tool}" "${tdir}/api-${tool}" || echo "fFetchApi failed" >> "${tdir}/${tool}.err"
			[[ "$(fApiStatus "${url}/api/${tool}")" == "200" ]] || echo "fApiStatus failed" >> "${tdir}/${tool}.err"
		) 2>/dev/null
		[[ -s "${tdir}/${tool}.err" ]] && fBad "install.bash ${tool} arm did not complete its requests: $(tr '\n' ' ' < "${tdir}/${tool}.err")"
		grep -q "^/download/${tool} auth=None$" "${tdir}/asset.log" 2>/dev/null \
			|| fBad "install.bash's ${tool} download sent GITHUB_TOKEN to the host it was redirected to"
		grep -q "^/download/${tool} auth=None$" "${tdir}/origin.log" 2>/dev/null \
			|| fBad "install.bash's ${tool} download sent GITHUB_TOKEN"
		[[ "$(grep -c "^/api/${tool} auth=Bearer regress-token$" "${tdir}/origin.log" 2>/dev/null || true)" == "2" ]] \
			|| fBad "install.bash's ${tool} API calls did not both pass GITHUB_TOKEN"
	done
else
	fTestSkip
fi

fTest Er88Qfn 20260923-15-no-plain-http-redirect
##	20260923 item 15: wget's --https-only covers recursive downloads only, so
##	a download the server redirected to plain http went through at exit 0. The
##	same listeners, with the https one redirecting to a plain one: every fetch
##	line in both installers refuses it and leaves no file.
if [[ -n "${tokenPid:-}" ]]; then
	for inst in install.bash install-dev.bash; do
		for tool in curl wget; do
			defs="$(sed -n "/^\tfWget() { local /p;/^\tfFetch() { /p;/^\tfFetchApi() { /p" "${repoDir}/${inst}" | { if [[ "${tool}" == curl ]]; then grep -v 'fWget\|() { wget '; else grep -v '() { curl '; fi; } || true)"
			rc=0
			(
				eval "${defs}"
				CURL_CA_BUNDLE="${tdir}/cert.pem" WGETRC="${tdir}/wgetrc" fFetch "https://127.0.0.1:$(cat "${tdir}/port")/tohttp/${tool}" "${tdir}/http-${tool}"
			) 2>/dev/null || rc=$?
			((rc != 0)) || fBad "${inst}'s ${tool} fetch followed a redirect to plain http at exit 0"
			[[ ! -e "${tdir}/http-${tool}" ]] || fBad "${inst}'s ${tool} fetch left the plain-http download behind"
			rm -f "${tdir}/http-${tool}"
		done
	done
	kill "${tokenPid}" 2>/dev/null || true
else
	fTestSkip
fi

fTest Er8APUs 20260926-install-ps1-iex-in-a-script
##	Test-gap audit: install.ps1 piped into iex from inside a script took the
##	caller for its own file, so a failure ran `exit` and ended the caller. On
##	Linux it refuses at once, which is the failure used here.
if fHave pwsh; then
	printf '%s\n' "try { Get-Content '${repoDir}/install.ps1' -Raw | iex } catch { 'caught' }" "'after'" > "${tmpDir}/iexcaller.ps1"
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY pwsh -NoProfile -File "${tmpDir}/iexcaller.ps1" 2>/dev/null || true)"
	[[ "${out}" == *caught*after* ]] || fBad "install.ps1 under iex in a script ended the caller: ${out@Q}"
else
	fTestSkip
fi

fTest EqRQpEm 20260920-idea8-install-ps1-sums-line-anchored
##	20260920 idea 8: install.ps1 matched the asset name anywhere in a sums line
##	and took the first hit, where install.bash anchors it at the end. No name a
##	cut produces today contains another, but a per-asset sidecar would, and the
##	answer would then be a hash off the wrong line. Both lines are lifted from
##	the shipped file so the check cannot drift from it.
if fHave pwsh; then
	sdir="${tmpDir}/psums"; mkdir -p "${sdir}"
	{
		printf '%064d  shcl-9.9.9-windows-x86_64.exe.sha256\n' 1
		printf '%064d  shcl-9.9.9-windows-x86_64.exe\n' 2
		printf '%064d  shcl-9.9.9-dropins.tar.gz.sha256\n' 3
		printf '%064d  shcl-9.9.9-dropins.tar.gz\n' 4
	} > "${sdir}/sums.txt"
	# shellcheck disable=SC2016  ## PowerShell variable names, matched literally
	sumLines="$(sed -n '/\$want = (Get-Content/p;/\$wantSrc = (Get-Content/p' "${repoDir}/install.ps1")"
	sumCount="$(grep -c . <<<"${sumLines}" || true)"
	[[ "${sumCount}" == 2 ]] || fBad "install.ps1's two sums lines could not be lifted: got ${sumCount}"
	out="$(pwsh -NoProfile -Command "\$sums = '${sdir}/sums.txt'; \$asset = 'shcl-9.9.9-windows-x86_64.exe'; \$dropins = 'shcl-9.9.9-dropins.tar.gz'
${sumLines}
Write-Output \"\$want \$wantSrc\"" 2>&1 || true)"
	[[ "${out}" == "$(printf '%064d %064d' 2 4)" ]] \
		|| fBad "install.ps1 takes a checksum off a sums line that merely contains the asset name: ${out@Q}"
else
	fTestSkip
fi

fTest EqL6XhI 20260918b-42-publish-flags-not-read-in-message
##	20260918b item 42: the publish script matched -h and -v anywhere in its
##	joined arguments, so `--message "pass -v through to rar"` printed the
##	banner and exited 0 having published nothing. Run from a directory that is
##	not a repo, so the run can only reach the refusal that comes before any
##	write. A stub rar stands in, since the script checks for one first.
nBadBefore="${nBad}"
(
	pdir="${tmpDir}/publish"; mkdir -p "${pdir}/bin" "${pdir}/work"
	printf '#!/bin/sh\nexit 0\n' > "${pdir}/bin/rar"; chmod 755 "${pdir}/bin/rar"
	fPublish(){ (cd "${pdir}/work" && PATH="${pdir}/bin:${PATH}" bash "${repoDir}/cicd/utility/n8git_backup-and-publish" "$@" 2>&1) ;}
	rc=0; out="$(fPublish --quiet --message "pass -v through to rar")" || rc=$?
	[[ "${rc}" != 0 && "${out}" == *"Not in git project base directory"* ]] \
		|| fBad "n8git_backup-and-publish took a -v inside --message for a version request: rc=${rc} ${out@Q}"
	rc=0; out="$(fPublish -m "document the -h flag")" || rc=$?
	[[ "${rc}" != 0 && "${out}" == *"Not in git project base directory"* ]] \
		|| fBad "n8git_backup-and-publish took a -h inside -m for a help request: rc=${rc} ${out@Q}"
	rc=0; out="$(fPublish --message x -v)" || rc=$?
	[[ "${rc}" == 0 && "${out}" == *"Copyright"* ]] || fBad "n8git_backup-and-publish no longer answers a real -v: rc=${rc} ${out@Q}"
	exit $((nBad - nBadBefore))
) || nBad=$((nBad + 1))

fTest Eonfke8 20260901b-46-wrapper-header-width
##	20260901b item 46: the PowerShell wrapper's header ran one line out to 126
##	columns where its bash twin wraps. Comment lines only - the code in both
##	has a couple of long ones on purpose.
for wrapper in source/bash/shcl.bash source/powershell/shcl.ps1; do
	long="$(awk '/^#{2}/ && length > 100 { print NR": "length }' "${repoDir}/${wrapper}")"
	[[ -z "${long}" ]] || fBad "${wrapper}: header comment runs past 100 columns at ${long//$'\n'/, }"
done

fTest EqzwPFK 20260901b-18-on-path-trailing-slash
##	20260901b item 18: the "not on your PATH" note compared strings against
##	`:dir:`, so a PATH element written with a trailing slash was not seen. Both
##	installers have the helper; install-dev.bash's reads the PATH as it was
##	before the script put its tool dirs in front.
for inst in install.bash install-dev.bash; do
	eval "$(sed -n '/^fOnPath()/,/^}/p' "${repoDir}/${inst}")"
	nBadBefore="${nBad}"
	(
		# shellcheck disable=SC2030,SC2034  ## the subshell keeps this PATH to itself; orig_path is install-dev.bash's
		PATH="/usr/bin:${tmpDir}/pbin/:/bin" orig_path="/usr/bin:${tmpDir}/pbin/:/bin"
		fOnPath "${tmpDir}/pbin"  || fBad "${inst}: a PATH element with a trailing slash was not seen"
		fOnPath "${tmpDir}/pbin/" || fBad "${inst}: a directory asked for with a trailing slash was not seen"
		fOnPath "${tmpDir}/pbi"   && fBad "${inst}: a PATH prefix was taken for the directory"
		fOnPath "${tmpDir}/pbin/x" && fBad "${inst}: a deeper directory was taken for a PATH element"
		exit $((nBad - nBadBefore))
	) || nBad=$((nBad + 1))
done

fTest EojtStM 20260901b-17-sign-release-refusals
##	20260901b item 17: sign-release.bash wrote the signature first and checked
##	the key after, so a run with the wrong key failed and left a .sig behind
##	that looked finished; and nothing checked the sums file's name against the
##	version, or its entries against the files. A throwaway key stands in for
##	the wrong one, and every refusal must leave no .sig.
if fHave openssl; then
	sver="$(sed -n '/^version *= *"/{ s/^version *= *"\(.*\)".*/\1/p; q; }' "${repoDir}/source/rust/Cargo.toml")"
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${tmpDir}/wrong.pem" 2>/dev/null
	fSignRun(){   ## fSignRun DIR: run the signer on DIR with the throwaway key; stderr in signOut
		signOut="$(bash "${repoDir}/cicd/utility/sign-release.bash" --key "${tmpDir}/wrong.pem" --dir "$1" --no-tag-check 2>&1 || true)"
	}
	## Right name, right sums, wrong key: refused on the key, nothing written.
	mkdir -p "${tmpDir}/sign1"; printf 'bin\n' > "${tmpDir}/sign1/shcl-${sver}-linux-x86_64"
	(cd "${tmpDir}/sign1" && sha256sum "shcl-${sver}-linux-x86_64" > "shcl-${sver}-sha256sums.txt")
	fSignRun "${tmpDir}/sign1"
	[[ "${signOut}" == *"not this key"* ]] || fBad "sign-release.bash did not refuse the wrong key: ${signOut@Q}"
	[[ ! -e "${tmpDir}/sign1/shcl-${sver}-sha256sums.txt.sig" ]] || fBad "sign-release.bash left a .sig behind after refusing the key"
	## Stale sums: an entry that no longer matches its file.
	mkdir -p "${tmpDir}/sign2"; cp "${tmpDir}/sign1/"* "${tmpDir}/sign2/"; printf 'rebuilt\n' > "${tmpDir}/sign2/shcl-${sver}-linux-x86_64"
	fSignRun "${tmpDir}/sign2"
	[[ "${signOut}" == *"does not match the files"* ]] || fBad "sign-release.bash signed a stale sums file: ${signOut@Q}"
	[[ ! -e "${tmpDir}/sign2/shcl-${sver}-sha256sums.txt.sig" ]] || fBad "sign-release.bash left a .sig behind after a stale sums file"
	## A sums file from another version.
	mkdir -p "${tmpDir}/sign3"; printf 'bin\n' > "${tmpDir}/sign3/shcl-0.0.1-linux-x86_64"
	(cd "${tmpDir}/sign3" && sha256sum "shcl-0.0.1-linux-x86_64" > "shcl-0.0.1-sha256sums.txt")
	fSignRun "${tmpDir}/sign3"
	[[ "${signOut}" == *"is not the sums file for ${sver}"* ]] || fBad "sign-release.bash signed a sums file for another version: ${signOut@Q}"
	[[ ! -e "${tmpDir}/sign3/shcl-0.0.1-sha256sums.txt.sig" ]] || fBad "sign-release.bash left a .sig behind after a misnamed sums file"
	## 20260909 item 26: each key copy was checked only if it could be read, so
	## a tree with none of them signed at rc 0. The script is copied into a tree
	## holding only the version, and the key is then the right one by default.
	mkdir -p "${tmpDir}/signtree/cicd/utility" "${tmpDir}/signtree/source/rust" "${tmpDir}/sign4"
	cp "${repoDir}/cicd/utility/sign-release.bash" "${tmpDir}/signtree/cicd/utility/"
	cp "${repoDir}/source/rust/Cargo.toml" "${tmpDir}/signtree/source/rust/"
	cp "${tmpDir}/sign1/"* "${tmpDir}/sign4/"
	signOut="$(bash "${tmpDir}/signtree/cicd/utility/sign-release.bash" --key "${tmpDir}/wrong.pem" --dir "${tmpDir}/sign4" --no-tag-check 2>&1 || true)"
	[[ "${signOut}" == *"cannot read shcl-signing.pub"* ]] || fBad "sign-release.bash signed with no key copy to check against: ${signOut@Q}"
	[[ ! -e "${tmpDir}/sign4/shcl-${sver}-sha256sums.txt.sig" ]] || fBad "sign-release.bash left a .sig behind with no key copy to check against"
	fTest Er20EK2 20260829-34-sign-release-tag-check
	##	20260829 item 34: nothing held the tag against the crate version, so a
	##	mistyped tag signed assets no download URL names. The same tree as a
	##	repository: untagged and wrongly tagged are refused on the tag, and the
	##	right tag beside the Go module's gets past it to the key copies.
	git -C "${tmpDir}/signtree" init -q
	git -C "${tmpDir}/signtree" add -A
	git -C "${tmpDir}/signtree" -c user.name=t -c user.email=t@t commit -q -m t
	fSignTag(){   ## fSignTag: run the signer in that tree with the tag check on; stderr in signOut
		signOut="$(bash "${tmpDir}/signtree/cicd/utility/sign-release.bash" --key "${tmpDir}/wrong.pem" --dir "${tmpDir}/sign4" 2>&1 || true)"
	}
	fSignTag
	[[ "${signOut}" == *"HEAD is not tagged v${sver} "* ]] || fBad "sign-release.bash signed off an untagged HEAD: ${signOut@Q}"
	git -C "${tmpDir}/signtree" tag "v${sver}.1"
	fSignTag
	[[ "${signOut}" == *"HEAD is not tagged v${sver} "* ]] || fBad "sign-release.bash took v${sver}.1 for v${sver}: ${signOut@Q}"
	git -C "${tmpDir}/signtree" tag "source/go/v${sver}"; git -C "${tmpDir}/signtree" tag "v${sver}"
	fSignTag
	[[ "${signOut}" == *"cannot read shcl-signing.pub"* ]] || fBad "sign-release.bash refused HEAD at its v${sver} tag: ${signOut@Q}"
	[[ ! -e "${tmpDir}/sign4/shcl-${sver}-sha256sums.txt.sig" ]] || fBad "sign-release.bash left a .sig behind after a tag refusal"
	fTest EqzwPFL 20260829-24-sign-release-without-xxd
	##	20260829 item 24: the modulus check piped through xxd, and a box
	##	without it ended the run with nothing said. Every key copy in this tree
	##	holds the throwaway key, so the run gets past them to the signature, on
	##	a PATH with every tool here but xxd. The modulus is written without
	##	the script's own round trip, and a wrong one still has to be refused.
	skey="${tmpDir}/signkey"
	mkdir -p "${skey}/cicd/utility" "${skey}/source/rust" "${tmpDir}/sign5" "${tmpDir}/noxxd"
	cp "${repoDir}/cicd/utility/sign-release.bash" "${skey}/cicd/utility/"
	cp "${repoDir}/source/rust/Cargo.toml" "${skey}/source/rust/"
	cp "${tmpDir}/sign1/"* "${tmpDir}/sign5/"
	openssl pkey -in "${tmpDir}/wrong.pem" -pubout -out "${skey}/shcl-signing.pub" 2>/dev/null
	printf "readonly SIGNING_KEY='%s'\n" "$(cat "${skey}/shcl-signing.pub")" > "${skey}/install.bash"
	smod="$(openssl rsa -pubin -in "${skey}/shcl-signing.pub" -modulus -noout 2>/dev/null | sed 's/^Modulus=//' || true)"
	smod="$(python3 -c 'import base64, sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "${smod}" || true)"
	for f in /usr/bin/* /bin/*; do
		if [[ -x "${f}" && "${f##*/}" != xxd ]]; then ln -sf "${f}" "${tmpDir}/noxxd/" 2>/dev/null || true; fi
	done
	fSignNoXxd(){ signOut="$(PATH="${tmpDir}/noxxd" "${BASH}" "${skey}/cicd/utility/sign-release.bash" --key "${tmpDir}/wrong.pem" --dir "${tmpDir}/sign5" --no-tag-check 2>&1 || true)" ;}
	# shellcheck disable=SC2016  ## install.ps1's own variable name
	printf '$signingModulus = '"'%s'"'\n' "${smod}" > "${skey}/install.ps1"
	fSignNoXxd
	[[ "${signOut}" == *"signed  shcl-${sver}-sha256sums.txt"* && -e "${tmpDir}/sign5/shcl-${sver}-sha256sums.txt.sig" ]] \
		|| fBad "sign-release.bash did not sign with xxd off the PATH: ${signOut@Q}"
	# shellcheck disable=SC2016  ## install.ps1's own variable name
	printf '$signingModulus = '"'%s'"'\n' "x${smod}" > "${skey}/install.ps1"
	fSignNoXxd
	[[ "${signOut}" == *"install.ps1 has a different key"* ]] || fBad "sign-release.bash with xxd off the PATH did not refuse a wrong modulus: ${signOut@Q}"
	fTest Er1zTEf 20260725-37-installers-check-the-signature
	##	20260725 item 37: nothing in the sums file is trusted until its signature
	##	checks out against the key the installer has. Each installer's check,
	##	lifted by text and given the throwaway key: the file it signed passes, and
	##	the same file with one byte changed is refused.
	mkdir -p "${tmpDir}/sigchk"
	printf 'abc  shcl-9.9.9-linux-x86_64\n' > "${tmpDir}/sigchk/sums"
	openssl dgst -sha256 -sign "${tmpDir}/wrong.pem" -out "${tmpDir}/sigchk/sums.sig" "${tmpDir}/sigchk/sums"
	printf 'abd  shcl-9.9.9-linux-x86_64\n' > "${tmpDir}/sigchk/forged"
	# shellcheck disable=SC2016  ## install.bash's own text, matched literally
	sigCode="$(sed -n '/^fDie() /p;/^printf .%s\\n. "\${SIGNING_KEY}" > /,/refusing to install"$/p' "${repoDir}/install.bash")"
	fSigBash(){   ## fSigBash SUMS: the lifted check on SUMS against the throwaway signature
		cp "$1" "${tmpDir}/sigchk/sums.in"
		# shellcheck disable=SC2034  ## the lifted step's own globals
		( SIGNING_KEY="$(openssl pkey -in "${tmpDir}/wrong.pem" -pubout)" tmp="${tmpDir}/sigchk/run"; mkdir -p "${tmp}"
			cp "${tmpDir}/sigchk/sums.in" "${tmp}/sums"; cp "${tmpDir}/sigchk/sums.sig" "${tmp}/sums.sig"
			eval "${sigCode}"; echo "verified" ) 2>&1 || true
	}
	if [[ "$(grep -c . <<<"${sigCode}")" != 4 ]]; then
		fBad "install.bash's signature check is not the lines this row lifts: ${sigCode@Q}"
	else
		out="$(fSigBash "${tmpDir}/sigchk/sums")"
		[[ "${out}" == "verified" ]] || fBad "install.bash refused a sums file its key signed: ${out@Q}"
		out="$(fSigBash "${tmpDir}/sigchk/forged")"
		[[ "${out}" == *"signature check failed on sha256sums - refusing to install"* && "${out}" != *verified* ]] \
			|| fBad "install.bash took a sums file its signature does not cover: ${out@Q}"
	fi
	if fHave pwsh; then
		#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
		{
			echo "\$signingModulus = '${smod}'"
			echo "\$signingExponent = 'AQAB'"
			sed -n '/^\tfunction Test-ReleaseSignature/,/^\t}/p' "${repoDir}/install.ps1"
			echo "Write-Output ('good=' + (Test-ReleaseSignature -Path '${tmpDir}/sigchk/sums' -SignaturePath '${tmpDir}/sigchk/sums.sig'))"
			echo "Write-Output ('forged=' + (Test-ReleaseSignature -Path '${tmpDir}/sigchk/forged' -SignaturePath '${tmpDir}/sigchk/sums.sig'))"
		} > "${tmpDir}/sigchk/check.ps1"
		out="$(pwsh -NoProfile -File "${tmpDir}/sigchk/check.ps1" 2>&1 || true)"
		[[ "${out}" == *"good=True"* ]]    || fBad "install.ps1 refused a sums file its key signed: ${out@Q}"
		[[ "${out}" == *"forged=False"* ]] || fBad "install.ps1 took a sums file its signature does not cover: ${out@Q}"
	fi
else
	echo "shell-regress: openssl not installed - signing rows skipped"
	fTestSkipBlock
fi

fTest ErsrmzS 2026100411093274-release-table-from-names
##	2026100411093274: the downloads table for a release's notes. OS rows in a
##	fixed order, arch columns, an empty cell where nothing was built, one
##	universal macOS build in both columns, and anything else under the table.
rtUrl="https://github.com/yottacore/shcl/releases/download/v3.0.0-beta1"
rtOut="$(printf '%s\n' shcl-3.0.0-beta1-windows-x86_64-setup.exe shcl-3.0.0-beta1-linux-x86_64.rpm \
	shcl-3.0.0-beta1-linux-x86_64 shcl-3.0.0-beta1-linux-x86_64.deb shcl-3.0.0-beta1-windows-x86_64.exe \
	shcl-3.0.0-beta1-freebsd-x86_64 shcl-3.0.0-beta1-macos-universal shcl-3.0.0-beta1-linux-arm64 \
	shcl-3.0.0-beta1-sha256sums.txt shcl-3.0.0-beta1-sha256sums.txt.sig shcl-3.0.0-beta1-plan9-x86_64 '' \
	| bash "${repoDir}/cicd/utility/release-table.bash" v3.0.0-beta1 --names - 2>&1 || true)"
rtWant="$(cat <<EOF
| OS      | x86_64                                                                     | arm64
| :---    | :---                                                                       | :---
| Linux   | [binary][linux-x86_64], [.deb][linux-x86_64.deb], [.rpm][linux-x86_64.rpm] | [binary][linux-arm64]
| Windows | [binary][windows-x86_64.exe], [installer][windows-x86_64-setup.exe]        |
| macOS   | [binary][macos-universal]                                                  | [binary][macos-universal]
| FreeBSD | [binary][freebsd-x86_64]                                                   |

Other files: [shcl-3.0.0-beta1-sha256sums.txt], [shcl-3.0.0-beta1-sha256sums.txt.sig], [shcl-3.0.0-beta1-plan9-x86_64]

[windows-x86_64-setup.exe]: ${rtUrl}/shcl-3.0.0-beta1-windows-x86_64-setup.exe
[linux-x86_64.rpm]: ${rtUrl}/shcl-3.0.0-beta1-linux-x86_64.rpm
[linux-x86_64]: ${rtUrl}/shcl-3.0.0-beta1-linux-x86_64
[linux-x86_64.deb]: ${rtUrl}/shcl-3.0.0-beta1-linux-x86_64.deb
[windows-x86_64.exe]: ${rtUrl}/shcl-3.0.0-beta1-windows-x86_64.exe
[freebsd-x86_64]: ${rtUrl}/shcl-3.0.0-beta1-freebsd-x86_64
[macos-universal]: ${rtUrl}/shcl-3.0.0-beta1-macos-universal
[linux-arm64]: ${rtUrl}/shcl-3.0.0-beta1-linux-arm64
[shcl-3.0.0-beta1-sha256sums.txt]: ${rtUrl}/shcl-3.0.0-beta1-sha256sums.txt
[shcl-3.0.0-beta1-sha256sums.txt.sig]: ${rtUrl}/shcl-3.0.0-beta1-sha256sums.txt.sig
[shcl-3.0.0-beta1-plan9-x86_64]: ${rtUrl}/shcl-3.0.0-beta1-plan9-x86_64
EOF
)"
[[ "${rtOut}" == "${rtWant}" ]] || fBad "release-table.bash table differs from the fixture: $(diff <(printf '%s\n' "${rtWant}") <(printf '%s\n' "${rtOut}") || true)"

fTest Ersrn1M 2026100411093274-release-table-upload-names
##	A local name with a character GitHub rewrites links to the name the upload
##	gets. Two names that upload as one, a list with no platform build, and a
##	missing tag are refused.
mkdir -p "${tmpDir}/rt1" "${tmpDir}/rt2"
: > "${tmpDir}/rt1/shcl-3.0.0+b1-linux-x86_64"; : > "${tmpDir}/rt1/shcl-3.0.0+b1-sha256sums.txt"
rtOut="$(bash "${repoDir}/cicd/utility/release-table.bash" 'v3.0.0+b1' --dir "${tmpDir}/rt1" 2>&1 || true)"
[[ "${rtOut}" == *"[linux-x86_64]: https://github.com/yottacore/shcl/releases/download/v3.0.0+b1/shcl-3.0.0.b1-linux-x86_64"* ]] \
	|| fBad "release-table.bash did not link a rewritten local name as uploaded: ${rtOut@Q}"
[[ "${rtOut}" == *"Other files: [shcl-3.0.0.b1-sha256sums.txt]"* ]] || fBad "release-table.bash left the sums file out: ${rtOut@Q}"
: > "${tmpDir}/rt2/shcl-3.0.0-linux-x86_64"; : > "${tmpDir}/rt2/shcl-3.0.0-linux-x86_64~"; : > "${tmpDir}/rt2/shcl-3.0.0-linux-x86_64+"
rtRc=0; rtOut="$(bash "${repoDir}/cicd/utility/release-table.bash" v3.0.0 --dir "${tmpDir}/rt2" 2>&1)" || rtRc=$?
[[ "${rtRc}" == "1" && "${rtOut}" == *"two assets upload as shcl-3.0.0-linux-x86_64."* ]] || fBad "release-table.bash took two names that upload as one (rc ${rtRc}): ${rtOut@Q}"
rtRc=0; rtOut="$(printf 'shcl-3.0.0-sha256sums.txt\n' | bash "${repoDir}/cicd/utility/release-table.bash" v3.0.0 --names - 2>&1)" || rtRc=$?
[[ "${rtRc}" == "1" && "${rtOut}" == *"no platform downloads"* ]] || fBad "release-table.bash wrote a table with no platform build (rc ${rtRc}): ${rtOut@Q}"
rtRc=0; rtOut="$(bash "${repoDir}/cicd/utility/release-table.bash" --names /dev/null 2>&1)" || rtRc=$?
[[ "${rtRc}" == "2" ]] || fBad "release-table.bash ran with no tag (rc ${rtRc}): ${rtOut@Q}"

fTest ErxeImV 2026100313461652-release-table-stage6-names
##	Every binary stage 6 builds gets a cell, named the way stage 6 names it,
##	so a new target cannot drop to the "Other files" line unnoticed. macOS is
##	the universal binary, in both columns.
# shellcheck disable=SC2016  ## the inner shell's own variables
rtNames="$(CPU_CAP=1 bash -c 'set +u; source "$1"
	printf "shcl-3.0.0-%s\n" "${RELEASE_NATIVE_OSARCH}"
	for t in "${CROSS_TARGETS[@]}"; do
		rest="${t#*|}"; osarch="${rest%%|*}"; rest="${rest#*|}"; art="${rest%%|*}"
		ext=""; [[ "${art}" == *.exe ]] && ext=".exe"
		printf "shcl-3.0.0-%s%s\n" "${osarch}" "${ext}"
	done' _ "${repoDir}/cicd/config.bash")"
rtOut="$(bash "${repoDir}/cicd/utility/release-table.bash" v3.0.0 --names - <<<"${rtNames}" 2>&1 || true)"
[[ "$(grep -c . <<<"${rtNames}")" -ge 6 ]] || fBad "stage 6 lists fewer targets than it did: ${rtNames@Q}"
[[ "${rtOut}" != *"Other files"* ]] || fBad "release-table.bash left a stage 6 binary out of the table: ${rtOut@Q}"
macRow="$(grep -F '| macOS ' <<<"${rtOut}" || true)"
[[ "${macRow}" == "| macOS "*"| [binary][macos-universal] "*"| [binary][macos-universal]" ]] \
	|| fBad "release-table.bash has no macOS row with the universal binary in both columns: ${rtOut@Q}"

fTest Es1rCr5 2026100708240546-macos-build-names-the-sdk
##	2026100708240546: with no xcrun, rustc warned once per half that it found
##	no Apple SDK. The macOS command now hands it zig's darwin stubs through
##	SDKROOT, leaves it empty where xcrun exists, and keeps one already set.
##	cargo is a stub here that prints the SDKROOT it was given.
mkdir -p "${tmpDir}/macsdk/bin" "${tmpDir}/macsdk/xc"
cat > "${tmpDir}/macsdk/bin/zig" <<'EOF'
#!/bin/sh
echo '.{'
echo '    .lib_dir = "/zz/lib",'
EOF
printf '#!/bin/sh\nexit 0\n' > "${tmpDir}/macsdk/xc/xcrun"
chmod +x "${tmpDir}/macsdk/bin/zig" "${tmpDir}/macsdk/xc/xcrun"
# shellcheck disable=SC2016  ## the inner shell's own variables
macSdkRun='set +u; source "$1"; cargo(){ printf "[%s]" "${SDKROOT:-}"; }
	for t in "${CROSS_TARGETS[@]}"; do [[ "${t}" == *"|macos-universal|"* ]] || continue; eval "${t#*|*|*|}"; done'
macSdkOut="$(env -u SDKROOT PATH="${tmpDir}/macsdk/bin" CPU_CAP=1 "${BASH}" -c "${macSdkRun}" _ "${repoDir}/cicd/config.bash" 2>&1 || true)"
[[ "${macSdkOut}" == "[/zz/lib/libc/darwin]" ]] || fBad "the macOS build did not name zig's darwin stubs as SDKROOT with no xcrun: ${macSdkOut@Q}"
macSdkOut="$(env -u SDKROOT PATH="${tmpDir}/macsdk/bin:${tmpDir}/macsdk/xc" CPU_CAP=1 "${BASH}" -c "${macSdkRun}" _ "${repoDir}/cicd/config.bash" 2>&1 || true)"
[[ "${macSdkOut}" == "[]" ]] || fBad "the macOS build set SDKROOT where xcrun exists: ${macSdkOut@Q}"
macSdkOut="$(SDKROOT=/my/sdk PATH="${tmpDir}/macsdk/bin" CPU_CAP=1 "${BASH}" -c "${macSdkRun}" _ "${repoDir}/cicd/config.bash" 2>&1 || true)"
[[ "${macSdkOut}" == "[/my/sdk]" ]] || fBad "the macOS build dropped an SDKROOT already set: ${macSdkOut@Q}"

fTest EojuRVQ 20260901b-20-flame-report-partial-graphs
##	20260901b item 20: flame-report.py took any file with a sample count and one
##	frame for a whole flamegraph, so a profile cut off mid-write reported a
##	fraction of itself at exit 0 and recorded the marker; a row height other
##	than the constant it assumed double-counted; a non-UTF-8 file was a
##	traceback. Three frames are a whole graph; a graph missing the frame
##	between a leaf and the root, one cut off before its closing tag, and
##	random bytes must each skip at 2.
fFlame(){   ## fFlame FILE STEP FRAMES...: a flamegraph of 100 samples with rows STEP apart
	local file="$1" step="$2"; shift 2
	{
		printf '<svg total_samples="100">\n'
		printf '<title>all (100 samples, 100%%)</title><rect x="0" y="%s" fg:x="0" fg:w="100"/>\n' "$((step * 3))"
		for fr in "$@"; do
			IFS='|' read -r fname fx fy fw <<<"${fr}"
			printf '<title>%s (%s samples)</title><rect x="0" y="%s" fg:x="%s" fg:w="%s"/>\n' "${fname}" "${fw}" "$((step * fy))" "${fx}" "${fw}"
		done
		printf '</svg>\n'
	} > "${file}"
}
mkdir -p "${tmpDir}/flame"
fFlame "${tmpDir}/flame/flame_20260101-000000_whole.svg" 16 'shcl::Parser::parse|0|2|60' 'shcl::Document::to_canonical|60|2|40' 'shcl::scan_path|0|1|10'
fFlame "${tmpDir}/flame/flame_20260101-000000_tall.svg"  24 'shcl::Parser::parse|0|2|60' 'shcl::Document::to_canonical|60|2|40' 'shcl::scan_path|0|1|10'
fFlame "${tmpDir}/flame/flame_20260101-000000_gap.svg"   16 'shcl::Document::to_canonical|60|2|40' 'shcl::scan_path|0|1|10'
head -c 200 "${tmpDir}/flame/flame_20260101-000000_whole.svg" > "${tmpDir}/flame/flame_20260101-000000_cut.svg"
head -c 1000 /dev/urandom > "${tmpDir}/flame/flame_20260101-000000_junk.svg"
fFlameRun(){ flameRc=0; flameOut="$(python3 "${repoDir}/cicd/utility/flame-report.py" --file "$1" 2>&1)" || flameRc=$?; }
fFlameRun "${tmpDir}/flame/flame_20260101-000000_whole.svg"
[[ "${flameRc}" == 0 && "${flameOut}" == *"parse (tokenize/merge/diags) .:  60.0%"* ]] || fBad "flame-report.py misread a whole graph (rc ${flameRc}): ${flameOut@Q}"
fFlameRun "${tmpDir}/flame/flame_20260101-000000_tall.svg"
[[ "${flameRc}" == 0 && "${flameOut}" == *"parse (tokenize/merge/diags) .:  60.0%"* && "${flameOut}" == *"other ........................:   0.0%"* ]] || fBad "flame-report.py misread a graph with a different row height (rc ${flameRc}): ${flameOut@Q}"
for bad in gap cut junk; do
	fFlameRun "${tmpDir}/flame/flame_20260101-000000_${bad}.svg"
	[[ "${flameRc}" == 2 ]] || fBad "flame-report.py accepted a ${bad} graph (rc ${flameRc}): ${flameOut@Q}"
	[[ "${flameOut}" != *Traceback* ]] || fBad "flame-report.py tracebacked on a ${bad} graph"
done
fTest Eonbg2q 20260901b-43-flame-report-dropped-samples
##	20260901b item 43: the sampler drops a sample whose leaf is inside libc
##	rather than truncating it, so a third to half the profiled time never
##	reaches the graph and every percentage in the report is a share of what
##	survived. The profiler writes the two counts beside the SVG; the report has
##	to say them, and has to stay quiet where an older graph has no such file.
printf '640 1600\n' > "${tmpDir}/flame/flame_20260101-000000_whole.svg.samples"
fFlameRun "${tmpDir}/flame/flame_20260101-000000_whole.svg"
[[ "${flameOut}" == *"640 of about 1600 samples reached the graph (40%)"* ]] \
	|| fBad "flame-report.py does not say how much of the profile the graph is missing: ${flameOut@Q}"
rm -f "${tmpDir}/flame/flame_20260101-000000_whole.svg.samples"
fFlameRun "${tmpDir}/flame/flame_20260101-000000_whole.svg"
[[ "${flameOut}" != *"reached the graph"* ]] \
	|| fBad "flame-report.py invented a sample count for a graph that has none"
grep -q '{}.samples' "${repoDir}/source/rust/src/main.rs" \
	|| fBad "the profiler does not record how many samples reached the graph"
fTest EqeDCi0 20260922-1-flame-report-recursion
##	20260922 item 1: a name inside itself on one stack, a recursive call or one
##	helper inlined at two depths, was counted once per depth, so recursive
##	emit_node read twice the whole emit share. 60 samples of it, 40 nested.
fFlame "${tmpDir}/flame/flame_20260101-000000_nest.svg" 16 'shcl::Document::emit_node|0|2|60' 'shcl::Parser::parse|60|2|40' 'shcl::Document::emit_node|0|1|40' 'shcl::emit_cell|0|0|20'
fFlameRun "${tmpDir}/flame/flame_20260101-000000_nest.svg"
[[ "${flameRc}" == 0 && "${flameOut}" == *" 60.0%   60  shcl::Document::emit_node"* ]] \
	|| fBad "flame-report.py counted a recursive call more than once (rc ${flameRc}): ${flameOut@Q}"
fTest Eq5mJo0 c-runner-needs-reads-tsv
##	The C corpus runner counted a case with no reads.tsv as passing, where the
##	other three runners stop on it. One real case, minus that file.
if fHave cc; then
	mkdir -p "${tmpDir}/corpus-noreads"
	cp -r "${repoDir}/project/conformance/001-messy-cities" "${tmpDir}/corpus-noreads/"
	rm -f "${tmpDir}/corpus-noreads/001-messy-cities/reads.tsv"
	if cc -std=c11 -O2 -I"${repoDir}/source/c" "${repoDir}/source/c/tests/conformance.c" -o "${tmpDir}/cconf" -lm -lpthread; then
		"${tmpDir}/cconf" "${tmpDir}/corpus-noreads" >/dev/null 2>&1 && fBad "the C corpus runner passed a case with no reads.tsv"
		fTest Er20EK3 20260920-idea4-c-runner-needs-input
		##	20260920 idea 4: a directory with no input.shcl was not a case at all,
		##	so it asserted nothing while looking present. One good case beside it,
		##	so the only thing wrong is the missing file.
		mkdir -p "${tmpDir}/corpus-noinput/002-b"
		cp -r "${repoDir}/project/conformance/001-messy-cities" "${tmpDir}/corpus-noinput/"
		printf 'query\ttype\texpected\tstatus\n' > "${tmpDir}/corpus-noinput/002-b/reads.tsv"
		noInput="$("${tmpDir}/cconf" "${tmpDir}/corpus-noinput" 2>&1 >/dev/null || true)"
		[[ "${noInput}" == *"002-b: missing input.shcl"* ]] || fBad "the C corpus runner skipped a case directory with no input.shcl"
	else
		fBad "the C corpus runner did not build"
	fi
else
	fTestSkipBlock
fi
fTest Eq5kgry 20260909-28-largedoc-empty-reference
##	20260909 item 28: largedoc.bash skipped its invariants when the reference
##	wrote nothing, and empty output agrees with empty output, so it said OK.
printf '#!/bin/sh\nexit 0\n' > "${tmpDir}/emptycli"; chmod +x "${tmpDir}/emptycli"
bash "${repoDir}/cicd/utility/largedoc.bash" --mib 1 "a|${tmpDir}/emptycli" "b|${tmpDir}/emptycli" >/dev/null 2>&1 \
	&& fBad "largedoc.bash passed a reference that wrote nothing"
fTest Eq5jgxF 20260909-27-check-pins-fetch-forms
##	20260909 item 27: check-pins.bash saw only `curl -o /absolute/path`, so any
##	other fetch passed with no hash, and so did a commented-out check. Each
##	variant is a copy of the real workflow with one change; the unchanged copy
##	has to pass first, or the refusals prove nothing.
mkdir -p "${tmpDir}/pins/cicd/utility/include" "${tmpDir}/pins/.github/workflows"
cp "${repoDir}/cicd/utility/check-pins.bash" "${tmpDir}/pins/cicd/utility/"
cp "${repoDir}/cicd/utility/include/test-id.bash" "${tmpDir}/pins/cicd/utility/include/"
cp "${repoDir}/cicd/config.bash" "${tmpDir}/pins/cicd/"
pinsYml="${tmpDir}/pins/.github/workflows/ci.yml"
fPinsRun(){   ## fPinsRun SED-EXPR: run check-pins on ci.yml edited by SED-EXPR; 0 if it passed
	sed -E "$1" "${repoDir}/.github/workflows/ci.yml" > "${pinsYml}"
	bash "${tmpDir}/pins/cicd/utility/check-pins.bash" >/dev/null 2>&1
}
fPinsRun 's/^//' || fBad "check-pins.bash failed on an unchanged copy of ci.yml"
fTest Eq5jgxG 20260830-43-check-pins-exact-names
##	20260830 item 43: pins matched by substring, so `build` found itself inside
##	other names and a version inside a longer one. And the cppcheck wheel was
##	written in three places with only two compared.
fPinsRun 's#staticcheck@2026\.1$#staticcheck@2026.10#' && fBad "check-pins.bash took 2026.10 for a pin of 2026.1"
fPinsRun 's# build==# pybuild==#' || true
pinsOut="$(bash "${tmpDir}/pins/cicd/utility/check-pins.bash" 2>&1 || true)"
[[ "${pinsOut}" == *"build is pinned at "*" and no line of ci.yml names build"* ]] \
	|| fBad "check-pins.bash took pybuild for the build pin: $(tail -n 3 <<<"${pinsOut}")"
fPinsRun 's#cppcheck==#cppcheck==9#' && fBad "check-pins.bash passed a cppcheck wheel off CPPCHECK_WHEEL"
fPinsRun 's#-o /tmp/shellcheck\.tar\.xz#-o shellcheck.tar.xz#' && fBad "check-pins.bash passed a relative curl -o"
fPinsRun 's#^([[:space:]]*)(echo "8c3be12b)#\1\# \2#' && fBad "check-pins.bash passed a commented-out sha256 check"
fPinsRun 's#^([[:space:]]*)(echo "8c3be12b.*)$#\1\2\n\1curl -fsSL https://example.com/x.tgz | tar xz#' && fBad "check-pins.bash passed curl piped to tar"
fPinsRun 's#^([[:space:]]*)(echo "8c3be12b.*)$#\1\2\n\1wget -O x.tgz https://example.com/x.tgz#' && fBad "check-pins.bash passed wget -O"
fPinsRun 's#^([[:space:]]*)(echo "8c3be12b.*)$#\1\2\n\1gh release download v1 -R a/b#' && fBad "check-pins.bash passed gh release download"
fTest EqL4rtp 20260918b-45-check-pins-install-families
##	20260918b item 45: the reverse check read its three install families in one
##	group under errexit, so with no pip or npm line the go and PowerShell ones
##	were never read and an unpinned `go install` passed. The run fails anyway
##	here, since the pip pins lose their line; the message is what is checked.
sed -E -e '/(pip|npm) install/d' -e 's#^([[:space:]]*)(go install honnef\.co.*)$#\1\2\n\1go install example.com/x/cmd/unpinnedtool@v1.0.0#' \
	"${repoDir}/.github/workflows/ci.yml" > "${pinsYml}"
pinsOut="$(bash "${tmpDir}/pins/cicd/utility/check-pins.bash" 2>&1 || true)"
[[ "${pinsOut}" == *"installs unpinnedtool at a pinned version"* ]] \
	|| fBad "check-pins.bash missed an unpinned go install once ci.yml had no pip line: $(tail -n 3 <<<"${pinsOut}")"
##	And a family whose line is there but written so its pattern reads no name
##	has gone blind; that is a failure too, not an empty list.
fPinsRun 's#pip install ruff==.*$#pip install -r requirements.txt#' || true
pinsOut="$(bash "${tmpDir}/pins/cicd/utility/check-pins.bash" 2>&1 || true)"
[[ "${pinsOut}" == *"has a pip install line and no pinned name was read"* ]] \
	|| fBad "check-pins.bash read no pip pins from a pip line and said nothing: $(tail -n 3 <<<"${pinsOut}")"
fTest Epu2f56 20260909-24-flame-report-marker
##	20260909 item 24: rotation retagged a graph and left its sidecar under the
##	old role, so the caveat vanished. And --check --file wrote the named graph's
##	stamp into the shared marker, so one dated ahead left the gate at SEEN for
##	good. SEEN needs the marker to name the newest graph; --file never moves it.
mkdir -p "${tmpDir}/flameseen"
cp "${tmpDir}/flame/flame_20260101-000000_whole.svg" "${tmpDir}/flameseen/flame_20260103-000000_latest.svg"
printf '640 1600\n' > "${tmpDir}/flameseen/flame_20260103-000000_frequent.svg.samples"
fFlameRun "${tmpDir}/flameseen/flame_20260103-000000_latest.svg"
[[ "${flameOut}" == *"640 of about 1600 samples reached the graph"* ]] \
	|| fBad "flame-report.py lost the sample count of a graph rotation retagged: ${flameOut@Q}"
cp "${tmpDir}/flame/flame_20260101-000000_whole.svg" "${tmpDir}/flame_20991231-000000_ahead.svg"
python3 "${repoDir}/cicd/utility/flame-report.py" --check --dir "${tmpDir}/flameseen" >/dev/null 2>&1 || true
python3 "${repoDir}/cicd/utility/flame-report.py" --check --dir "${tmpDir}/flameseen" --file "${tmpDir}/flame_20991231-000000_ahead.svg" >/dev/null 2>&1 || true
cp "${tmpDir}/flame/flame_20260101-000000_whole.svg" "${tmpDir}/flameseen/flame_20260104-000000_frequent.svg"
flameOut="$(python3 "${repoDir}/cicd/utility/flame-report.py" --check --dir "${tmpDir}/flameseen" 2>&1 || true)"
[[ "${flameOut}" == "NEW flame_20260104-000000_frequent.svg"* ]] \
	|| fBad "flame-report.py stayed SEEN past a marker a --file run moved: ${flameOut@Q}"
flameOut="$(python3 "${repoDir}/cicd/utility/flame-report.py" --check --dir "${tmpDir}/flameseen" 2>&1 || true)"
[[ "${flameOut}" == "SEEN "* ]] || fBad "flame-report.py reported a graph it had already seen: ${flameOut@Q}"
fTest EqMEejS 20260918b-63-flame-report-age
##	20260918b item 63: the line named the graph and said nothing about when it
##	was profiled, so a startup look standing on a fortnight-old artifact read
##	exactly like one standing on this morning's. Both gates say the age now.
touch -d '16 days ago' "${tmpDir}/flameseen/flame_20260104-000000_frequent.svg"
flameOut="$(python3 "${repoDir}/cicd/utility/flame-report.py" --check --dir "${tmpDir}/flameseen" 2>&1 || true)"
[[ "${flameOut}" == *"16d old"* ]] || fBad "flame-report.py does not say how old the graph behind its report is: ${flameOut@Q}"

fTest EojucQq 20260901b-21-lint-report-echoed-commands
##	20260901b item 21: lint-report.bash counted the `-D warnings` in the clippy
##	command line the pre-push gate's nested run echoes as a warning, so every
##	run that pushed to dev read as one finding. A real clippy warning and a
##	cppcheck one still count; the two echoed command lines do not.
lintDone=$'\n[ shcl CI/CD: done. ]\n'
printf 'Lint ...........: cargo clippy --all-targets -- -D warnings\nLint ...........: cppcheck --enable=warning,portability src.c\nOK: lint\n%s' "${lintDone}" > "${tmpDir}/run_20260101-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --file "${tmpDir}/run_20260101-000000.log" 2>&1 || true)"
[[ "${lintOut}" == "CLEAN "* ]] || fBad "lint-report.bash counted an echoed command line as a warning: ${lintOut@Q}"
fTest Er20EK4 20260829-30-lint-report-govulncheck-note
##	20260829 item 30: govulncheck's note about vulnerabilities in code this
##	project does not call is informational, and it flagged every run.
printf 'OK: lint\nYour code is affected by 0 vulnerabilities.\nThis scan also found 1 vulnerability in packages you import and 2 vulnerabilities in modules you\nrequire, but your code doesn'"'"'t appear to call these vulnerabilities.\n%s' "${lintDone}" > "${tmpDir}/run_20260101-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --file "${tmpDir}/run_20260101-000000.log" 2>&1 || true)"
[[ "${lintOut}" == "CLEAN "* ]] || fBad "lint-report.bash counted govulncheck's informational block as a warning: ${lintOut@Q}"
printf 'Lint ...........: cargo clippy --all-targets -- -D warnings\nLint ...........: cppcheck --enable=warning,portability src.c\nOK: lint\n%s' "${lintDone}" > "${tmpDir}/run_20260101-000000.log"
printf 'warning: unused variable: x\n --> src/main.rs:1:1\nsrc.c:12:3: warning: uninitialized variable [uninitvar]\n%s' "${lintDone}" >> "${tmpDir}/run_20260101-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --file "${tmpDir}/run_20260101-000000.log" 2>&1 || true)"
[[ "${lintOut}" == "FLAG "*"(2 warning line(s), "* ]] || fBad "lint-report.bash missed a real warning: ${lintOut@Q}"
fTest Epu2f57 20260909-23-lint-report-failed-runs
##	20260909 item 23: a failed run printed CLEAN, since only rustc's `error[`
##	counted as a failure. Each spelling on its own must report FAILED.
for failLine in 'src.c:3:5: error: conflicting types for x' 'SC2086 (info): Double quote to prevent globbing.' \
	'test result: FAILED. 3 passed; 8 failed' '--- FAIL: TestX (0.00s)' "thread 'main' panicked at src/lib.rs:1:1:" \
	'Traceback (most recent call last):' '[ CICD ABORTED (exit 1) at line 5: false ]' '[ FAILED: tests failed ]'; do
	printf 'OK: lint\n%s\n' "${failLine}" > "${tmpDir}/run_20260102-000000.log"
	lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --file "${tmpDir}/run_20260102-000000.log" 2>&1 || true)"
	[[ "${lintOut}" == "FAILED "* ]] || fBad "lint-report.bash called a failed run clean (${failLine}): ${lintOut@Q}"
done
fTest Epu2f58 20260909-24-lint-report-marker
##	20260909 item 24: --check --file wrote the named log's stamp into the shared
##	marker, so a name that sorts high left the gate at SEEN for good.
mkdir -p "${tmpDir}/lintseen"
printf 'OK: lint\n%s' "${lintDone}" > "${tmpDir}/lintseen/run_20260101-000000.log"
printf 'OK: lint\n%s' "${lintDone}" > "${tmpDir}/zzz.log"
bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" >/dev/null 2>&1 || true
bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" --file "${tmpDir}/zzz.log" >/dev/null 2>&1 || true
printf 'OK: lint\n%s' "${lintDone}" > "${tmpDir}/lintseen/run_20260102-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "CLEAN run_20260102-000000.log"* ]] || fBad "lint-report.bash stayed SEEN past a marker a --file run moved: ${lintOut@Q}"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "SEEN "* ]] || fBad "lint-report.bash reported a log it had already seen: ${lintOut@Q}"
fTest EqL2HuS 20260918b-13-lint-report-incomplete-run
##	20260918b item 13: a log read while its run was still going, or after the run
##	was killed, said CLEAN and took the marker, so the warnings and the abort that
##	came after were never shown. A nested run's done line, echoed by a publish
##	before the outer run ends, does not finish the outer one either.
printf '[ 2/9  Build (debug) ]\n   Compiling shcl v2.0.0\n' > "${tmpDir}/lintseen/run_20260103-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "INCOMPLETE run_20260103-000000.log"* ]] || fBad "lint-report.bash did not call an unfinished run INCOMPLETE: ${lintOut@Q}"
printf 'warning: unused variable: x\n' >> "${tmpDir}/lintseen/run_20260103-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "INCOMPLETE run_20260103-000000.log"*"1 warning line(s)"* ]] || fBad "lint-report.bash marked an unfinished run seen: ${lintOut@Q}"
printf '[ shcl CI/CD: done. ]\n[ 9/9  Publish ]\n' >> "${tmpDir}/lintseen/run_20260103-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "INCOMPLETE "* ]] || fBad "lint-report.bash took a nested run's done line for the end of the run: ${lintOut@Q}"
printf '\n[ FAILED: the installers differ from origin/main ]\n' >> "${tmpDir}/lintseen/run_20260103-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "FAILED run_20260103-000000.log"* ]] || fBad "lint-report.bash did not report the run once it failed: ${lintOut@Q}"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "SEEN "* ]] || fBad "lint-report.bash did not mark a finished failed run seen: ${lintOut@Q}"
fTest EqMEejT 20260918b-63-lint-report-age
##	20260918b item 63, the other half: same silence about the log's age.
touch -d '16 days ago' "${tmpDir}/lintseen/run_20260103-000000.log"
lintOut="$(bash "${repoDir}/cicd/utility/lint-report.bash" --check --dir "${tmpDir}/lintseen" 2>&1 || true)"
[[ "${lintOut}" == "SEEN "*"16d old)"* ]] || fBad "lint-report.bash does not say how old the log behind its report is: ${lintOut@Q}"

fTest EoUpKv2 20260830b-9-stable-channel-pick
##	20260830b item 9: the stable channel took GitHub's date-ordered "latest
##	release" verbatim, so a patch back-ported to an older line after a newer one
##	shipped was handed out as stable. The fixture is in publish order, newest
##	first, and the answer must not be the first row.
##	20260924c idea 3: install.bash ranked any tag, and `vnext` sorts above every
##	version under sort -V.
cat > "${tmpDir}/rel.json" <<'JSON'
[
  {
    "tag_name": "vnext",
    "draft": false,
    "prerelease": false
  },
  {
    "tag_name": "v1.2.1",
    "draft": false,
    "prerelease": false
  },
  {
    "tag_name": "v2.1.0-alpha.1",
    "draft": false,
    "prerelease": true
  },
  {
    "tag_name": "v2.2.0",
    "draft": true,
    "prerelease": false
  },
  {
    "tag_name": "v2.0.0",
    "draft": false,
    "prerelease": false
  },
  {
    "tag_name": "v2.1.0-alpha.10",
    "draft": false,
    "prerelease": true
  },
  {
    "tag_name": "v2.1.0-alpha.2",
    "draft": false,
    "prerelease": true
  }
]
JSON
##	The function comes out of the shipped installer by name, so the gate runs
##	the real text rather than a copy that can drift.
eval "$(sed -n '/^fPickTag()/,/^}/p' "${repoDir}/install.bash")"
out="$(fPickTag stable "${tmpDir}/rel.json")"
[[ "${out}" == "v2.0.0" ]] || fBad "install.bash stable channel picked ${out@Q}, want v2.0.0"
##	20260829 item 21: a pre-release suffix compared as text, so alpha.10 sorted
##	below alpha.2. Both installers order the digit runs numerically.
out="$(fPickTag dev "${tmpDir}/rel.json")"
[[ "${out}" == "v2.1.0-alpha.10" ]] || fBad "install.bash dev channel picked ${out@Q}, want v2.1.0-alpha.10"

fTest EonXwm9 20260901b-34-compact-release-json
##	20260901b item 34: the same list with no whitespace. The API is documented
##	as pretty-printing, and a proxy that does not left the picker reading one
##	field per release, so it answered nothing and the run said no release was
##	published at all.
tr -d ' \t\n' < "${tmpDir}/rel.json" > "${tmpDir}/rel-compact.json"
out="$(fPickTag stable "${tmpDir}/rel-compact.json")"
[[ "${out}" == "v2.0.0" ]] || fBad "install.bash stable channel on compact json picked ${out@Q}, want v2.0.0"
out="$(fPickTag dev "${tmpDir}/rel-compact.json")"
[[ "${out}" == "v2.1.0-alpha.10" ]] || fBad "install.bash dev channel on compact json picked ${out@Q}, want v2.1.0-alpha.10"

fTest Er1zTEg 20260924c-idea4-install-bash-plan-page
##	20260924c idea 4: the plan names the release page it installs from. The
##	whole script runs, with a curl on PATH that answers the release list and
##	nothing else. setsid leaves no terminal, so the run stops at the prompt,
##	after the plan and before any download.
if fHave setsid && fHave openssl; then
	mkdir -p "${tmpDir}/apibin" "${tmpDir}/planhome"
	printf '[{"tag_name":"v2.0.0","prerelease":false,"draft":false},{"tag_name":"v3.0.0-beta1","prerelease":true,"draft":false}]\n' > "${tmpDir}/planrel.json"
	cat > "${tmpDir}/apibin/curl" <<-STUB
		#!/bin/sh
		out=""; url=""
		while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
		case "\${url}" in https://api.github.com/repos/yottacore/shcl/releases*) cp '${tmpDir}/planrel.json' "\${out}" ;; *) exit 22 ;; esac
	STUB
	chmod 755 "${tmpDir}/apibin/curl"
	for release in stable dev; do
		tag=v2.0.0; [[ "${release}" == dev ]] && tag=v3.0.0-beta1
		# shellcheck disable=SC2031  ## the gate's own PATH, which no subshell above changed for this one
		out="$(HOME="${tmpDir}/planhome" PATH="${tmpDir}/apibin:${PATH}" setsid -w bash "${repoDir}/install.bash" --release "${release}" </dev/null 2>&1 || true)"
		[[ "${out}" == *"shcl ${tag#v} (${release}, linux-"*"  from     https://github.com/yottacore/shcl/releases/tag/${tag}"$'\n'* ]] \
			|| fBad "install.bash --release ${release} plan does not name its release page: ${out@Q}"
	done
else
	fTestSkip
fi

fTest ErlTWJD 20261004-install-bash-freebsd-plan
##	FreeBSD x86_64 has its own binary, so a FreeBSD uname plans that asset, and
##	FreeBSD on arm64 is refused before any fetch. Same run as the plan-page
##	row, with a uname on PATH.
if fHave setsid && fHave openssl; then
	mkdir -p "${tmpDir}/bsdbin" "${tmpDir}/bsdhome"
	cp "${tmpDir}/apibin/curl" "${tmpDir}/bsdbin/curl"
	for bsdArch in amd64 arm64; do
		# shellcheck disable=SC2016  ## the stub's own $1
		printf '#!/bin/sh\ncase "$1" in -s) echo FreeBSD ;; -m) echo %s ;; *) echo FreeBSD ;; esac\n' "${bsdArch}" > "${tmpDir}/bsdbin/uname"
		chmod 755 "${tmpDir}/bsdbin/uname"
		# shellcheck disable=SC2031  ## the gate's own PATH, which no subshell above changed for this one
		out="$(HOME="${tmpDir}/bsdhome" PATH="${tmpDir}/bsdbin:${PATH}" setsid -w bash "${repoDir}/install.bash" --release dev </dev/null 2>&1 || true)"
		if [[ "${bsdArch}" == amd64 ]]; then
			[[ "${out}" == *"shcl 3.0.0-beta1 (dev, freebsd-x86_64)"* ]] || fBad "install.bash on FreeBSD amd64 does not plan the freebsd-x86_64 binary: ${out@Q}"
		else
			[[ "${out}" == *"no prebuilt FreeBSD arm64 binary"* && "${out}" != *"shcl 3.0.0"* ]] || fBad "install.bash on FreeBSD arm64 got past the platform gate: ${out@Q}"
		fi
	done
else
	fTestSkip
fi

fTest ErxeImS 2026100313461652-install-bash-macos-plan
##	macOS has one universal binary, so a Darwin uname plans that asset on an
##	Intel Mac and on Apple silicon alike, never a per-arch one. Same run as the
##	plan-page row.
if fHave setsid && fHave openssl; then
	mkdir -p "${tmpDir}/macbin" "${tmpDir}/machome"
	cp "${tmpDir}/apibin/curl" "${tmpDir}/macbin/curl"
	for macArch in x86_64 arm64; do
		# shellcheck disable=SC2016  ## the stub's own $1
		printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo %s ;; *) echo Darwin ;; esac\n' "${macArch}" > "${tmpDir}/macbin/uname"
		chmod 755 "${tmpDir}/macbin/uname"
		# shellcheck disable=SC2031  ## the gate's own PATH, which no subshell above changed for this one
		out="$(HOME="${tmpDir}/machome" PATH="${tmpDir}/macbin:${PATH}" setsid -w bash "${repoDir}/install.bash" --release dev </dev/null 2>&1 || true)"
		[[ "${out}" == *"shcl 3.0.0-beta1 (dev, macos-universal)"* ]] || fBad "install.bash on macOS ${macArch} does not plan the macos-universal binary: ${out@Q}"
	done
else
	fTestSkip
fi

fTest ErxeImT 2026100313461652-install-bash-macos-install
##	The whole install on a Darwin uname, from a stand-in release: the signed
##	sums are read, the universal binary is the one fetched and checked, and it
##	is what the user target gets. openssl verifies nothing here, since the
##	real signing key is not here, and also does the checksums for real.
if fHave setsid && fHave openssl; then
	mi="${tmpDir}/macinst"
	mkdir -p "${mi}/bin" "${mi}/home" "${mi}/rel"
	realOpenssl="$(command -v openssl)"
	printf '[{"tag_name":"v3.0.0-beta1","prerelease":true,"draft":false}]\n' > "${mi}/rel.json"
	printf '#!/bin/sh\necho "shcl v3.0.0-beta1"\n' > "${mi}/rel/shcl-3.0.0-beta1-macos-universal"
	printf '#!/bin/sh\nexit 9\n' > "${mi}/rel/shcl-3.0.0-beta1-linux-x86_64"
	( cd "${mi}/rel" && sha256sum shcl-3.0.0-beta1-linux-x86_64 shcl-3.0.0-beta1-macos-universal > "${mi}/sums" )
	: > "${mi}/fetched"
	cat > "${mi}/bin/curl" <<-STUB
		#!/bin/sh
		out=""; url=""
		while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
		echo "\${url}" >> '${mi}/fetched'
		case "\${url}" in
			https://api.github.com/repos/yottacore/shcl/releases*) cp '${mi}/rel.json' "\${out}" ;;
			*/shcl-3.0.0-beta1-sha256sums.txt) cp '${mi}/sums' "\${out}" ;;
			*/shcl-3.0.0-beta1-sha256sums.txt.sig) : > "\${out}" ;;
			*/shcl-3.0.0-beta1-macos-universal) cp '${mi}/rel/shcl-3.0.0-beta1-macos-universal' "\${out}" ;;
			*) exit 22 ;;
		esac
	STUB
	cat > "${mi}/bin/openssl" <<-STUB
		#!/bin/sh
		for a in "\$@"; do [ "\${a}" = -verify ] && exit 0; done
		exec '${realOpenssl}' "\$@"
	STUB
	# shellcheck disable=SC2016  ## the stub's own $1
	printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "${mi}/bin/uname"
	chmod 755 "${mi}/bin/curl" "${mi}/bin/openssl" "${mi}/bin/uname"
	# shellcheck disable=SC2031  ## the gate's own PATH, which no subshell above changed for this one
	out="$(HOME="${mi}/home" PATH="${mi}/bin:${PATH}" setsid -w bash "${repoDir}/install.bash" --release dev --yes </dev/null 2>&1 || true)"
	[[ "${out}" == *"installed shcl 3.0.0-beta1"* ]] || fBad "install.bash on macOS did not install the universal binary: ${out@Q}"
	cmp -s "${mi}/home/.local/share/shcl/shcl" "${mi}/rel/shcl-3.0.0-beta1-macos-universal" \
		|| fBad "install.bash on macOS laid down something other than the universal binary"
	grep -q 'macos-universal$' "${mi}/fetched" || fBad "install.bash on macOS never fetched the universal binary: $(cat "${mi}/fetched")"
	grep -qE -- '-(x86_64|arm64)$' "${mi}/fetched" && fBad "install.bash on macOS fetched a per-arch binary: $(cat "${mi}/fetched")"
else
	fTestSkip
fi

fTest ErlTWLO 20261004-install-bash-release-without-platform
##	A release from before a platform got its binary is named as such, from the
##	signed sums, and the binary is never fetched. openssl is stubbed, since the
##	real signing key is not here, and only the verify step reaches it.
if fHave setsid; then
	mkdir -p "${tmpDir}/nobin/bin" "${tmpDir}/nobin/home"
	printf '[{"tag_name":"v3.0.0-beta1","prerelease":true,"draft":false}]\n' > "${tmpDir}/nobin/rel.json"
	printf 'abc  shcl-3.0.0-beta1-linux-x86_64\n' > "${tmpDir}/nobin/sums"
	: > "${tmpDir}/nobin/fetched"
	cat > "${tmpDir}/nobin/bin/curl" <<-STUB
		#!/bin/sh
		out=""; url=""
		while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
		echo "\${url}" >> '${tmpDir}/nobin/fetched'
		case "\${url}" in
			https://api.github.com/repos/yottacore/shcl/releases*) cp '${tmpDir}/nobin/rel.json' "\${out}" ;;
			*/shcl-3.0.0-beta1-sha256sums.txt) cp '${tmpDir}/nobin/sums' "\${out}" ;;
			*/shcl-3.0.0-beta1-sha256sums.txt.sig) : > "\${out}" ;;
			*) exit 22 ;;
		esac
	STUB
	printf '#!/bin/sh\nexit 0\n' > "${tmpDir}/nobin/bin/openssl"
	# shellcheck disable=SC2016  ## the stub's own $1
	printf '#!/bin/sh\ncase "$1" in -s) echo FreeBSD ;; -m) echo amd64 ;; *) echo FreeBSD ;; esac\n' > "${tmpDir}/nobin/bin/uname"
	chmod 755 "${tmpDir}/nobin/bin/curl" "${tmpDir}/nobin/bin/openssl" "${tmpDir}/nobin/bin/uname"
	# shellcheck disable=SC2031  ## the gate's own PATH, which no subshell above changed for this one
	out="$(HOME="${tmpDir}/nobin/home" PATH="${tmpDir}/nobin/bin:${PATH}" setsid -w bash "${repoDir}/install.bash" --release dev --yes </dev/null 2>&1 || true)"
	[[ "${out}" == *"release v3.0.0-beta1 has no freebsd-x86_64 binary"* ]] || fBad "install.bash does not say the release lacks this platform's binary: ${out@Q}"
	grep -q 'freebsd-x86_64$' "${tmpDir}/nobin/fetched" && fBad "install.bash fetched a binary the sums file does not list: $(cat "${tmpDir}/nobin/fetched")"
	[[ -e "${tmpDir}/nobin/home/.local/share/shcl" ]] && fBad "install.bash laid something down for a release with no binary"
else
	fTestSkip
fi

fTest Er1zTEh 20260830-7-sums-lookup-missing-entry
##	20260830 item 7: a lookup in the sums file that matched nothing failed its
##	substitution under pipefail, and the script ended with no message before
##	the check that says what is missing. A release with no drop-ins has to get
##	as far as its binary-only note. The two lookups are lifted by text. The
##	unguarded-grep scan further down holds every other one.
lookups="$(grep -E '^want(_src)?="\$\(grep ' "${repoDir}/install.bash" || true)"
if [[ "$(grep -c . <<<"${lookups}")" != 2 ]]; then
	fBad "install.bash's sums lookups are not the two lines this row lifts: ${lookups@Q}"
else
	mkdir -p "${tmpDir}/lookup"; printf 'abc  shcl-9.9.9-other\n' > "${tmpDir}/lookup/sums"
	# shellcheck disable=SC2016  ## the inner shell's own variables
	out="$(tmp="${tmpDir}/lookup" asset=shcl-9.9.9-linux-x86_64 dropins=shcl-9.9.9-dropins.tar.gz bash -c 'set -euo pipefail; eval "$1"; echo "reached [${want}] [${want_src}]"' _ "${lookups}" 2>&1 || true)"
	[[ "${out}" == "reached [] []" ]] || fBad "install.bash ends with no message on a sums file missing an entry: ${out@Q}"
fi

fTest EoUpKv3 install-ps1-channel-pick
if fHave pwsh; then
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		sed -n '/^\tfunction Select-ReleaseTag/,/^\t}/p' "${repoDir}/install.ps1"
		echo "\$rel = Get-Content '${tmpDir}/rel.json' -Raw | ConvertFrom-Json"
		echo 'Write-Output ("stable=" + (Select-ReleaseTag stable $rel).tag_name)'
		echo 'Write-Output ("dev=" + (Select-ReleaseTag dev $rel).tag_name)'
	} > "${tmpDir}/pick.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/pick.ps1" 2>&1 || true)"
	[[ "${out}" == *"stable=v2.0.0"* ]]        || fBad "install.ps1 stable channel: ${out@Q}"
	[[ "${out}" == *"dev=v2.1.0-alpha.10"* ]]  || fBad "install.ps1 dev channel: ${out@Q}"
else
	fTestSkip
fi

fTest EqpJ3x2 20260924c-idea7-stable-falls-back-to-prerelease
##	20260924c idea 7: stable is the default channel, so with no full release at
##	all it takes the newest pre-release rather than finding nothing.
cat > "${tmpDir}/rel-pre.json" <<'JSON'
[
  { "tag_name": "v3.0.0-beta2", "draft": true, "prerelease": true },
  { "tag_name": "v3.0.0-beta1", "draft": false, "prerelease": true },
  { "tag_name": "v3.0.0-alpha.9", "draft": false, "prerelease": true }
]
JSON
out="$(fPickTag stable "${tmpDir}/rel-pre.json")"
[[ "${out}" == "v3.0.0-beta1" ]] || fBad "install.bash stable channel with no full release picked ${out@Q}, want v3.0.0-beta1"
if fHave pwsh; then
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		sed -n '/^\tfunction Select-ReleaseTag/,/^\t}/p' "${repoDir}/install.ps1"
		echo "\$rel = Get-Content '${tmpDir}/rel-pre.json' -Raw | ConvertFrom-Json"
		echo 'Write-Output ("stable=" + (Select-ReleaseTag stable $rel).tag_name)'
	} > "${tmpDir}/pickpre.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/pickpre.ps1" 2>&1 || true)"
	[[ "${out}" == *"stable=v3.0.0-beta1"* ]] || fBad "install.ps1 stable channel with no full release: ${out@Q}"

	fTest EqpJ3x3 20260924c-idea5-install-ps1-target-probe
	##	20260924c idea 5: a read-only target, or a shcl.exe held open, failed
	##	after the download with raw exception text. Both are asked first now.
	mkdir -p "${tmpDir}/itarget/ro" "${tmpDir}/itarget/rw"
	: > "${tmpDir}/itarget/rw/shcl.exe"
	chmod 555 "${tmpDir}/itarget/ro"
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		sed -n '/^\tfunction Test-InstallTarget/,/^\t}/p' "${repoDir}/install.ps1"
		echo "Write-Output (\"rw=[\" + (Test-InstallTarget -Dest '${tmpDir}/itarget/rw') + ']')"
		echo "Write-Output (\"ro=[\" + (Test-InstallTarget -Dest '${tmpDir}/itarget/ro/Shcl') + ']')"
		echo "\$held = [IO.File]::Open('${tmpDir}/itarget/rw/shcl.exe', 'Open', 'ReadWrite', 'None')"
		echo "Write-Output (\"held=[\" + (Test-InstallTarget -Dest '${tmpDir}/itarget/rw') + ']')"
		echo '$held.Dispose()'
	} > "${tmpDir}/itarget.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/itarget.ps1" 2>&1 || true)"
	chmod 755 "${tmpDir}/itarget/ro"
	[[ "${out}" == *"rw=[]"* ]] || fBad "install.ps1 refused a writable target: ${out@Q}"
	if ((EUID != 0)); then
		[[ "${out}" == *"ro=[cannot write"*"not writable]"* ]] || fBad "install.ps1 did not see a read-only target before the download: ${out@Q}"
	fi
	[[ "${out}" == *"held=[cannot replace"*"in use"* ]] || fBad "install.ps1 did not see a shcl.exe held open: ${out@Q}"
else
	fTestSkipBlock
fi

fTest EonXwmA 20260901b-34-install-ps1-windows-only-paths
##	20260901b item 34, both windows-only and neither reachable from a linux
##	pwsh: a 32-bit host reads Program Files (x86) out of ProgramFiles, and
##	Windows PowerShell 5.1 turns a native command's stderr into error records
##	under `2>&1`, which the script's own Stop preference then throws on. The
##	first is an expression a linux pwsh can evaluate; the second is source
##	order, the way the smoke-run placement below is.
# shellcheck disable=SC2016  ## PowerShell's own $variable, matched literally
pfLine="$( { grep -F 'programFiles = if ($env:ProgramW6432)' "${repoDir}/install.ps1" || true; } | head -n1)"
if [[ -z "${pfLine}" ]]; then
	fBad "install.ps1 reads ProgramFiles without asking for the 64-bit one"
elif fHave pwsh; then
	#  shellcheck disable=2016  ## PowerShell's own $variables.
	{
		echo '$env:ProgramFiles = "C:\Program Files (x86)"'
		echo '$env:ProgramW6432 = "C:\Program Files"'
		printf '%s\n' "${pfLine}"
		echo 'Write-Output ("wow=" + $programFiles)'
		echo 'Remove-Item Env:ProgramW6432'
		printf '%s\n' "${pfLine}"
		echo 'Write-Output ("plain=" + $programFiles)'
	} > "${tmpDir}/pf.ps1"
	out="$(pwsh -NoProfile -File "${tmpDir}/pf.ps1" 2>&1 || true)"
	[[ "${out}" == *'wow=C:\Program Files'* && "${out}" != *'wow=C:\Program Files (x86)'* ]] \
		|| fBad "install.ps1 puts a 64-bit install under the x86 program files: ${out@Q}"
	[[ "${out}" == *'plain=C:\Program Files (x86)'* ]] \
		|| fBad "install.ps1 ignores ProgramFiles where there is no 64-bit one: ${out@Q}"
fi
fTest EonZZBw 20260901b-38-setup-uninstaller-first
##	20260901b item 38: the setup .exe writes the same directory and registers
##	itself with Add/Remove Programs, so deleting its files from here left that
##	entry pointing at nothing. Windows-only, so the check is source order.
setupTest="$( { grep -n "uninstall.exe'" "${repoDir}/install.ps1" || true; } | head -n1 | cut -d: -f1)"
setupWipe="$( { grep -n "Remove-ShclFile -Dest \$dest" "${repoDir}/install.ps1" || true; } | head -n1 | cut -d: -f1)"
if [[ -z "${setupTest}" || -z "${setupWipe}" ]] || ((setupTest >= setupWipe)); then
	fBad "install.ps1 removes a setup install's files without deferring to its uninstaller"
fi
grep -q 'Add/Remove Programs entry still shows the version it installed' "${repoDir}/install.ps1" \
	|| fBad "install.ps1 does not say a setup install's Add/Remove entry goes stale when it writes over one"

fTest EonXwmB install-ps1-smoke-runs-under-continue
## The preference is set inside Invoke-ShclSmoke, so the function's own scope
## puts it back.
smokeFn="$(sed -n '/^\tfunction Invoke-ShclSmoke/,/^\t}/p' "${repoDir}/install.ps1")"
eapLine="$( { grep -n "ErrorActionPreference = 'Continue'" <<<"${smokeFn}" || true; } | head -n1 | cut -d: -f1)"
smokeRun="$( { grep -n 'version 2>&1' <<<"${smokeFn}" || true; } | head -n1 | cut -d: -f1)"
if [[ -z "${eapLine}" || -z "${smokeRun}" ]] || ((eapLine >= smokeRun)); then
	fBad "install.ps1 runs the smoke test under its own Stop preference, which 5.1 throws on"
fi

fTest EonYeTo 20260901b-35-rpm-owns-its-directories
##	20260901b item 35: the rpm listed the payload's subdirectories and not their
##	parent, so removing the package left /usr/share/shcl behind. The package
##	read-back lives in package.bash, which only runs at release time; building a
##	stub package here gives it something to fail on every run.
## Through fHave like every other tool here: two defects are pinned by this
## block alone, and a skip nobody saw left the hosted gate without them.
if fHave nfpm && fHave dpkg-deb && fHave rpm; then
	pDir="${tmpDir}/nfpm"
	mkdir -p "${pDir}/payload/code" "${pDir}/payload/scripts" "${pDir}/payload/man" "${pDir}/payload/doc" "${pDir}/payload/completions"
	printf 'x\n' > "${pDir}/payload/code/lib.rs"
	printf 'x\n' > "${pDir}/payload/scripts/shcl.bash"
	printf 'x\n' > "${pDir}/payload/doc/copyright"
	printf 'x\n' > "${pDir}/payload/completions/shcl.bash"
	printf 'x\n' > "${pDir}/payload/completions/_shcl"
	printf 'x\n' | gzip -9nc > "${pDir}/payload/man/shcl.1.gz"
	printf 'x\n' | gzip -9nc > "${pDir}/payload/doc/changelog.gz"
	##	20260918b item 40: the rpm required a package named libgcc, which
	##	openSUSE does not have. The stub has a real binary linked to
	##	libgcc_s, the way the x86_64 build is, with the names package.bash
	##	uses, so the read-back can hold them against what rpm generates.
	cp "${cli}" "${pDir}/p"
	eval "$(grep -E '^(deb|rpm)GccDep=' "${repoDir}/cicd/utility/package.bash")"
	[[ -n "${rpmGccDep:-}" ]] || fBad "package.bash names no rpm libgcc dependency"
	sed -e "s|\${SHCL_VERSION}|9.9.9|g" -e "s|\${SHCL_ARCH}|amd64|g" \
	    -e "s|\${SHCL_BIN}|${pDir}/p|g" -e "s|\${SHCL_PAYLOAD}|${pDir}/payload|g" \
	    -e "s|\${SHCL_GLIBC}|2.34|g" -e "s|\${SHCL_DEB_LIBGCC}|\\n      - ${debGccDep:-}|g" -e "s|\${SHCL_RPM_LIBGCC}|\\n      - ${rpmGccDep:-}|g" \
	    "${repoDir}/cicd/packaging/nfpm.yaml" > "${pDir}/nfpm.yaml"
	if nfpm package -f "${pDir}/nfpm.yaml" -p deb -t "${pDir}/p.deb" >/dev/null 2>&1 \
	   && nfpm package -f "${pDir}/nfpm.yaml" -p rpm -t "${pDir}/p.rpm" >/dev/null 2>&1; then
		##	The shipped read-back, run on the stub packages.
		eval "$(sed -n '/^fCheckDeps()/,/^}/p' "${repoDir}/cicd/utility/package.bash")"
		# shellcheck disable=SC2329  ## called from the lifted fCheckDeps
		( fDie(){ echo "shell-regress: $*" >&2; exit 1; }; fCheckDeps "${pDir}/p" 2.34 1 ) \
			|| fBad "the packages do not read back the way package.bash requires"
	else
		fBad "nfpm could not build a package from cicd/packaging/nfpm.yaml"
	fi
	fTest Er20EK5 20260829-26-packages-reproducible
	##	20260829 item 26: two builds seconds apart gave different packages, from
	##	the staged payload's mtimes and the rpm's build stamp. The shipped script,
	##	twice, a second apart, on a small stand-in binary.
	for r in r1 r2; do
		mkdir -p "${pDir}/${r}"; cp /bin/true "${pDir}/${r}/shcl-9.9.9-linux-x86_64"
		"${repoDir}/cicd/utility/package.bash" "${repoDir}" "${pDir}/${r}" 9.9.9 > "${pDir}/${r}.log" 2>&1 \
			|| fBad "package.bash failed on a stand-in binary: $(tail -n 3 "${pDir}/${r}.log")"
		[[ "${r}" == r1 ]] && sleep 1
	done
	for f in deb rpm; do
		[[ -f "${pDir}/r1/shcl-9.9.9-linux-x86_64.${f}" ]] || { fBad "package.bash built no .${f}"; continue; }
		cmp -s "${pDir}/r1/shcl-9.9.9-linux-x86_64.${f}" "${pDir}/r2/shcl-9.9.9-linux-x86_64.${f}" \
			|| fBad "two builds of the same .${f} a second apart differ"
	done
else
	fTestSkip
fi

fTest Er20EK6 20260829-26-dropins-tarball-reproducible
##	The same item's other half: the drop-ins tarball recorded the checkout's
##	mtimes and the local owner, so a fresh clone gave another sum. The tar line
##	comes out of cicd.bash, run once on this tree and once on a copy with new
##	mtimes and the modes a checkout under umask 077 gets (20260926 item 12);
##	the two have to match and name no owner but 0.
tarLine="$(sed -n '/tar --sort=name/,/dropins\.tar\.gz/p' "${repoDir}/cicd/cicd.bash")"
if [[ "${tarLine}" == *"dropins.tar.gz"* ]]; then
	dropFiles="$(sed -n 's/^[[:space:]]*\(source\/[^|]*\)\\$/\1/p' <<<"${tarLine}")"
	mkdir -p "${tmpDir}/dropins/copy" "${tmpDir}/dropins/a" "${tmpDir}/dropins/b"
	# shellcheck disable=SC2086  ## the file list splits on purpose
	(cd "${repoDir}" && cp --parents ${dropFiles} "${tmpDir}/dropins/copy/")
	chmod -R go-rwx "${tmpDir}/dropins/copy"
	fDropins(){   ## fDropins ROOT OUTDIR: the lifted tar line, in a subshell
		# shellcheck disable=SC2034  ## read by the lifted line
		( EXE_NAME=shcl; ver=9.9.9; root="$1"; art_dir="$2"
		  SOURCE_DATE_EPOCH="$(git -C "${repoDir}" log -1 --format=%ct)"; eval "${tarLine}" )
	}
	fDropins "${repoDir}" "${tmpDir}/dropins/a"
	fDropins "${tmpDir}/dropins/copy" "${tmpDir}/dropins/b"
	cmp -s "${tmpDir}/dropins/a/shcl-9.9.9-dropins.tar.gz" "${tmpDir}/dropins/b/shcl-9.9.9-dropins.tar.gz" \
		|| fBad "the drop-ins tarball differs between two checkouts of the same files"
	tarOwners="$(tar -tvzf "${tmpDir}/dropins/a/shcl-9.9.9-dropins.tar.gz" | awk '{print $2}' | sort -u)"
	[[ "${tarOwners}" == "0/0" ]] || fBad "the drop-ins tarball records an owner: ${tarOwners}"
	##	20260928 idea 7: the two builds match under the old tar line too when
	##	this checkout was itself made under umask 077, so the modes are checked
	##	as well: 644, or 755 where git records the file executable.
	while read -r perm _ _ _ _ name; do
		want="-rw-r--r--"
		[[ "$(git -C "${repoDir}" ls-files -s -- "${name}" | cut -c1-6)" == 100755 ]] && want="-rwxr-xr-x"
		[[ "${perm}" == "${want}" ]] || fBad "the drop-ins tarball has ${name} at ${perm}, not ${want}"
	done < <(tar -tvzf "${tmpDir}/dropins/a/shcl-9.9.9-dropins.tar.gz")
else
	fBad "cicd.bash no longer builds the drop-ins tarball with a tar --sort=name line"
fi

fTest Er20EK7 20260904-40-no-profiler-in-artifacts
##	20260904 item 40: the profiler never shipping rested on the release command
##	not including the feature flag. package.bash checks the files now, and it
##	runs only at release, so its check runs here on a stub artifact with one of
##	the crate names in it, and on a clean one.
eval "$(sed -n '/^fCheckNoProfiler()/,/^}/p' "${repoDir}/cicd/utility/package.bash")"
if declare -F fCheckNoProfiler >/dev/null; then
	mkdir -p "${tmpDir}/noprof/art" "${tmpDir}/noprof/payload/code"
	printf 'x\n' > "${tmpDir}/noprof/payload/code/lib.rs"
	printf 'ELF\0clean\0' > "${tmpDir}/noprof/art/shcl-1.0.0-linux-x86_64"
	# shellcheck disable=SC2034,SC2329  ## read by, and called from, the lifted fCheckNoProfiler
	( artDir="${tmpDir}/noprof/art"; payload="${tmpDir}/noprof/payload"
	  fDie(){ echo "$*"; exit 1; }; fCheckNoProfiler ) >/dev/null \
		|| fBad "package.bash's profiler check refused a clean artifact"
	printf 'ELF\0%s::ProfilerGuard\0' "ppr""of" > "${tmpDir}/noprof/art/shcl-1.0.0-linux-x86_64"
	# shellcheck disable=SC2034,SC2329
	profOut="$( artDir="${tmpDir}/noprof/art"; payload="${tmpDir}/noprof/payload"
	  fDie(){ echo "$*"; exit 1; }; fCheckNoProfiler )" || true
	[[ "${profOut}" == "shcl-1.0.0-linux-x86_64: has the profiler dependency, which must never ship" ]] \
		|| fBad "package.bash packaged a binary with the profiler: ${profOut@Q}"
else
	fBad "package.bash no longer has fCheckNoProfiler"
fi

fTest EoUoQT2 20260830b-8-prerelease-nsis-version
##	20260830b item 8: a prerelease version reached NSIS's four-integer version
##	field verbatim, and makensis rejected it under errexit, so the release stage
##	died on the first prerelease cut. A fake .exe is enough - the setup never
##	runs, it only has to build.
if fHave makensis; then
	pkgDir="${tmpDir}/pkg"; mkdir -p "${pkgDir}"
	: > "${pkgDir}/shcl-2.1.0-alpha.1-windows-x86_64.exe"
	if "${repoDir}/cicd/utility/package.bash" "${repoDir}" "${pkgDir}" "2.1.0-alpha.1" > "${tmpDir}/pkg.log" 2>&1; then
		[[ -f "${pkgDir}/shcl-2.1.0-alpha.1-windows-x86_64-setup.exe" ]] \
			|| fBad "packaging a prerelease built no setup: $(cat "${tmpDir}/pkg.log")"
	else
		fBad "packaging a prerelease failed: $(cat "${tmpDir}/pkg.log")"
	fi
	fTest EqGk8rw 20260918-13-nsis-uninstall-names-files
	##	20260918 item 13: the uninstaller deleted code\*.* and scripts\*.*, so a
	##	file someone else kept there went too. What makensis compiles into it
	##	has to name each payload file, through the list package.bash writes,
	##	and hold no wildcard.
	nsiPay="${tmpDir}/nsipay"; mkdir -p "${nsiPay}/code" "${nsiPay}/scripts"
	: > "${nsiPay}/code/lib.rs"; : > "${nsiPay}/scripts/shcl.ps1"; : > "${tmpDir}/fake.exe"
	eval "$(sed -n '/^fUninstallList()/,/^}/p' "${repoDir}/cicd/utility/package.bash")"
	if declare -F fUninstallList >/dev/null; then
		fUninstallList "${nsiPay}" > "${tmpDir}/uninstall.nsh"
		nsiOut="$(makensis -V4 -DVERSION=1.0.0 -DVERQUAD=1.0.0.0 -DSRCEXE="${tmpDir}/fake.exe" -DPAYLOAD="${nsiPay}" \
			-DOUTFILE="${tmpDir}/un-setup.exe" -DUNINSTLIST="${tmpDir}/uninstall.nsh" "${repoDir}/cicd/packaging/shcl.nsi" 2>&1 || true)"
		# shellcheck disable=SC2016  ## $INSTDIR is NSIS's, not the shell's
		if ! grep -qF 'Delete: "$INSTDIR\code\lib.rs"' <<<"${nsiOut}" || ! grep -qF 'Delete: "$INSTDIR\scripts\shcl.ps1"' <<<"${nsiOut}"; then
			fBad "the setup's uninstaller does not name each payload file: $(grep -E '^Delete' <<<"${nsiOut}" | tr '\n' ' ' || true)"
		fi
		if grep -qE '^Delete: .*\*' <<<"${nsiOut}"; then
			fBad "the setup's uninstaller deletes by wildcard: $(grep -E '^Delete: .*\*' <<<"${nsiOut}" | tr '\n' ' ' || true)"
		fi
	else
		fBad "package.bash no longer has fUninstallList, which the setup's uninstall list comes from"
	fi
else
	echo "shell-regress: makensis not installed - packaging row skipped"
	fTestSkipBlock
fi

fTest EoUqEKX 20260830b-11-guarded-iswindows
##	20260830b item 11: $IsWindows does not exist on Windows PowerShell 5.1, and
##	reading it there throws under a caller's strict mode. Every read has to sit
##	behind a version test that short-circuits first, which cannot be exercised
##	from a 7.x session because $PSVersionTable is read-only.
while IFS= read -r h; do
	fBad "source/powershell/shcl.ps1: unguarded \$IsWindows read: ${h}"
done < <(grep -n 'IsWindows' "${repoDir}/source/powershell/shcl.ps1" \
	| grep -vE '^[0-9]+:##' | grep -vE 'PSVersion\.Major -lt 6 -or' || true)

fTest EoXLk6q comparison-worker-arguments
##	The comparison worker: a bad ITERS used to be a traceback, and a zero one
##	raised while formatting a time that was never taken. The listing must also
##	survive a loader failing some way other than a missing import, and must not
##	grow a duplicate search-path entry per call.
worker="${repoDir}/cicd/utility/comparison/pyworker.py"
if [[ -f "${worker}" ]]; then
	: > "${tmpDir}/w.shcl"
	printf 'a: 1\n' > "${tmpDir}/w.shcl"
	for bad in abc 0 -1; do
		out="$(python3 "${worker}" shcl "${tmpDir}/w.shcl" "${bad}" 2>&1)" && rc=0 || rc=$?
		((rc == 2)) || fBad "pyworker.py ITERS=${bad}: exit ${rc}, expected 2"
		[[ "${out}" == usage:* ]] || fBad "pyworker.py ITERS=${bad} did not print the usage line: ${out}"
	done
	## Its own loader is called once per listed entry, so a path pushed per call
	## shows up as a duplicate after two.
	dups="$(python3 - "${worker}" <<'PYEOF'
import runpy, sys
path = sys.argv[1]
mod = runpy.run_path(path)
before = list(sys.path)
mod["load_shcl"](); mod["load_shcl"]()
print(len(sys.path) - len(before))
PYEOF
)"
	[[ "${dups}" == "1" ]] || fBad "pyworker.py load_shcl added ${dups} path entries over two calls, expected 1"
	## 20260909 item 61: lxml's parser wants bytes where every other loader here
	## wants text, and the encode used to sit inside the timed parse - about 28%
	## on a 7 MB document, charged to lxml. A loader's fourth element prepares the
	## source once, before the clock starts, and the parse must see that.
	prep="$(python3 - "${worker}" "${tmpDir}/w.shcl" <<'PYEOF'
import contextlib, io, runpy, sys
mod = runpy.run_path(sys.argv[1])
seen = []
def parse(x):
	seen.append(x)
	return x
mod["ENTRIES"]["probe"] = (lambda: ("v", parse, None, lambda t: ("PREPARED", t)), "x", "x", "x", "x")
with contextlib.redirect_stdout(io.StringIO()):
	mod["run"]("probe", sys.argv[2], 2)
ok = bool(seen) and all(isinstance(x, tuple) and x[0] == "PREPARED" for x in seen)
print("ok" if ok else "raw")
PYEOF
)"
	[[ "${prep}" == "ok" ]] || fBad "pyworker.py run() hands the parser the file text, not what the loader prepared"
	## 20260920b item 17: a document with a line the parse could not take was
	## timed as though it had read whole, where the Rust half refuses it.
	printf 'a: 1\nb\nc: 2\n' > "${tmpDir}/wbad.shcl"
	rc=0; out="$(python3 "${worker}" shcl "${tmpDir}/wbad.shcl" 1 2>&1)" || rc=$?
	[[ "${rc}" == 0 && "${out}" == "failed=1 diagnostics, 0 lines lost" ]] || fBad "pyworker.py timed a partial parse (exit ${rc}): ${out@Q}"
fi

fTest EqBCxoW 20260909-61-demo-output-order
##	20260909 item 61: the demo captured stdout and stderr separately and stuck
##	one after the other, so every stderr line ended up under every stdout line -
##	an order no terminal produces. The two share a pipe now.
gif="${repoDir}/cicd/utility/gen-demo-gif.py"
if [[ -f "${gif}" ]] && python3 -c 'import PIL' 2>/dev/null; then
	merged="$(python3 - "${gif}" <<'PYEOF'
import runpy, sys
mod = runpy.run_path(sys.argv[1])
step = {"show": "x", "run": "echo one; echo TWO >&2; echo three"}
print("|".join(mod["fRunStep"](step, "shcl", "/bin/true")))
PYEOF
)"
	[[ "${merged}" == "one|TWO|three" ]] || fBad "gen-demo-gif.py does not render a step's output in emission order: ${merged}"

	fTest Er20EK8 20260718-17-demo-stops-on-step-exit
	##	20260718 item 17: a step that failed rendered its error text into the gif,
	##	and the pipeline published it. An unexpected exit has to stop the render,
	##	and one the step asks for with expect_exit has to go through.
	stepExit="$(python3 - "${gif}" 2>&1 <<'PYEOF'
import runpy, sys
mod = runpy.run_path(sys.argv[1])
try:
	mod["fRunStep"]({"show": "x", "run": "echo oops; exit 3"}, "shcl", "/bin/true")
	print("rendered")
except SystemExit as e:
	print(f"exit {e.code}")
print("|".join(mod["fRunStep"]({"show": "x", "run": "echo oops; exit 3", "expect_exit": 3}, "shcl", "/bin/true")))
PYEOF
)" || true
	[[ "${stepExit}" == *"step exited 3, expected 0"*$'\n'"exit 2"$'\n'"oops" ]] \
		|| fBad "gen-demo-gif.py did not stop on an unexpected step exit, or refused an expected one: ${stepExit@Q}"

	fTest EqM7a7s 20260918b-62-demo-matches-the-gif
	##	20260918b item 62: the committed gif showed output the CLI no longer
	##	printed - an E014 wording two rounds old, and a `check` missing its
	##	explain line - because the gif stage is the one the release gate skips
	##	(--no-gif), so nothing held the two together. The gif shows whatever
	##	fRunStep captures, so capturing it here and comparing it with a golden
	##	says the gif is stale the day the output changes.
	demoGot="$(cd "${repoDir}" && python3 - "${gif}" "${repoDir}/cicd/demo-scenario.toml" "${cli}" <<'DEMOEOF'
import runpy, sys, tomllib
mod = runpy.run_path(sys.argv[1])
with open(sys.argv[2], "rb") as fh:
	sc = tomllib.load(fh)
prog = sc.get("prog", "shcl")
lines = []
for step in sc.get("step", []):
	lines.append("$ " + step["show"].replace("{prog}", prog))
	lines += mod["fRunStep"](step, prog, sys.argv[3])
print("\n".join(lines))
DEMOEOF
)"
	if [[ "${demoGot}" != "$(cat "${repoDir}/cicd/demo/expected.txt")" ]]; then
		fBad "the demo steps no longer print what assets/demo.gif shows; rerender the gif (cicd.bash gif stage, or gen-demo-gif.py) and refresh cicd/demo/expected.txt"
	fi
elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
	fBad "the demo output order cannot be checked here, and the gate requires it"
else
	echo "shell-regress: skipping the demo output order (no Pillow here)"
	echo shell-regress >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkipBlock
fi

fTest Ep1EGVf 20260904-26-perf-gate-stub-clis
##	20260904 item 26: perf-gate's exit-code and line-count checks had never been
##	fed a CLI that does no work, so deleting them changed nothing. Two stubs:
##	one that prints nothing and one that exits wrong.
mkdir -p "${tmpDir}/stubs"
printf '#!/usr/bin/env bash\nexit 0\n' > "${tmpDir}/stubs/quiet"
printf '#!/usr/bin/env bash\necho x\nexit 1\n' > "${tmpDir}/stubs/wrong"
chmod +x "${tmpDir}/stubs/quiet" "${tmpDir}/stubs/wrong"
out="$(bash "${repoDir}/cicd/utility/perf-gate.bash" --keys 500 "quiet|${tmpDir}/stubs/quiet" 2>&1 || true)"
[[ "${out}" == *"printed 0 line(s)"* ]] || fBad "perf-gate accepted a CLI that printed nothing: $(tail -n 2 <<<"${out}")"
out="$(bash "${repoDir}/cicd/utility/perf-gate.bash" --keys 500 "wrong|${tmpDir}/stubs/wrong" 2>&1 || true)"
[[ "${out}" == *"did not do the work"* ]] || fBad "perf-gate accepted a CLI that exited wrong: $(tail -n 2 <<<"${out}")"

fTest EqQUj04 20260920-2-ci-runs-the-cross-checks
##	20260920 item 2: the cross checks sat inside the release-build branch, and
##	--ci empties the release command, so the one run that decides whether a
##	commit reaches main compiled none of them for a month. Driven rather than
##	grepped: a throwaway repo holding the real engine, a config with every stage
##	empty, and a cross check that touches a marker file.
stubDir="${tmpDir}/cicd-stub"
mkdir -p "${stubDir}/cicd/utility/include"
cp "${repoDir}/cicd/cicd.bash" "${stubDir}/cicd/"
cp "${repoDir}/cicd/utility/include/gfs-rotate.bash" "${stubDir}/cicd/utility/include/"
cp "${repoDir}/cicd/utility/green-tree.bash" "${stubDir}/cicd/utility/"
cat > "${stubDir}/cicd/config.bash" <<'EOF'
APP_NAME="stub"; EXE_NAME="stub"; VERSION_MANIFEST="Cargo.toml"; LINT_LOG_DIR=""
FMT_CMD=(); FMT_CHECK_CMD=(); BUILD_CMD=(); LINT_CMD=(); TEST_CMD=()
SHELLCHECK_TARGETS=(); BINDING_CLIS=(); LARGEDOC_MIB=0
PROFILE_ENABLE=0; GIF_ENABLE=0; GIT_PUBLISH=(); DOGFOOD_FIXED_DESTS=()
RELEASE_NATIVE_CMD=(); RELEASE_NATIVE_BIN=""; RELEASE_NATIVE_OSARCH="x"
CROSS_TARGETS=(); RELEASE_ARTIFACT_DIR=""
CROSS_CHECKS=( "marker|touch \"${SHCL_STUB_MARKER}\"${SHCL_STUB_FAIL:+; false}" )
EOF
(
	cd "${stubDir}"
	git init -q .
	printf 'x\n' > f
	git add -A
	git -c user.email=stub@example.invalid -c user.name=stub commit -qm stub
) || fBad "could not stand up the cicd stub repo"
export SHCL_STUB_MARKER="${stubDir}/marker"
##	The gate run has to compile them.
rm -f "${SHCL_STUB_MARKER}"
if ( cd "${stubDir}" && bash cicd/cicd.bash --ci ) > "${tmpDir}/stub-ci.log" 2>&1; then
	[[ -f "${SHCL_STUB_MARKER}" ]] || fBad "cicd.bash --ci ran no cross check"
else
	fBad "cicd.bash --ci failed on the stub repo: $(tail -n 3 "${tmpDir}/stub-ci.log")"
fi
##	And a failing one has to stop the run, or running them buys nothing.
rm -f "${SHCL_STUB_MARKER}"
if ( export SHCL_STUB_FAIL=1; cd "${stubDir}" && bash cicd/cicd.bash --ci ) > "${tmpDir}/stub-fail.log" 2>&1; then
	fBad "cicd.bash --ci passed with a failing cross check"
fi
grep -q 'cross check failed: marker' "${tmpDir}/stub-fail.log" \
	|| fBad "cicd.bash did not name the cross check that failed"
##	--no-cross drops the checks with the targets: it is what a box without the
##	cross toolchains passes, and mingw is one of them.
rm -f "${SHCL_STUB_MARKER}"
( cd "${stubDir}" && bash cicd/cicd.bash --ci --no-cross ) > "${tmpDir}/stub-nocross.log" 2>&1 \
	|| fBad "cicd.bash --ci --no-cross failed on the stub repo"
if [[ -f "${SHCL_STUB_MARKER}" ]]; then fBad "--no-cross ran a cross check anyway"; fi
unset SHCL_STUB_MARKER

fTest Ep1EGVg 20260904-26-installers-compared-after-publish
##	20260904 item 26: the installers ship from main, so cicd.bash compares them
##	against origin/main after a dev publish. The line has to be there.
grep -qF -- 'git diff --stat origin/main -- install.bash install.ps1 install-dev.bash' "${repoDir}/cicd/cicd.bash" || fBad "cicd.bash no longer compares the installers against origin/main after a publish"

fTest EqzwPFM pin-drift-quoted-commands
##	The pin drift warning ran each pin's command from an unquoted expansion, so
##	a quoted argument arrived with its quotes as text and the PSScriptAnalyzer
##	pin reported drift on every run. The lifted loop, on a pin whose tool
##	answers with its version only when the quoting survives.
driftLoop="$(sed -n '/^if declare -p TOOL_PINS &>\/dev\/null; then$/,/^fi$/p' "${repoDir}/cicd/cicd.bash")"
# shellcheck disable=SC2016  ## cicd.bash's own text, matched literally
if [[ "${driftLoop}" != *'for pin in "${TOOL_PINS[@]}"'* ]]; then
	fBad "cicd.bash's pin drift loop is not where this row lifts it from"
else
	mkdir -p "${tmpDir}/driftbin"
	# shellcheck disable=SC2016  ## the stand-in's own parameters
	printf '#!/bin/sh\nif [ "$#" = 2 ] && [ "$2" = "(Get-Thing).Version" ]; then echo 1.2.3; else echo confused; fi\n' > "${tmpDir}/driftbin/quotedtool"
	chmod +x "${tmpDir}/driftbin/quotedtool"
	# shellcheck disable=SC2031  ## this is the script's own PATH; the subshell above keeps its change
	out="$(
		# shellcheck disable=SC2030  ## the substitution keeps this PATH to itself
		PATH="${tmpDir}/driftbin:${PATH}"
		# shellcheck disable=SC2034  ## read by the lifted loop
		TOOL_PINS=("quotedtool|1.2.3|quotedtool -Command \"(Get-Thing).Version\"")
		# shellcheck disable=SC2329  ## called from the lifted loop
		fEcho(){ printf '%s\n' "$*" ;}
		eval "${driftLoop}"
	)"
	[[ -z "${out}" ]] || fBad "cicd.bash's pin drift check misreads a pin whose command is quoted: ${out@Q}"
fi

fTest EqpNNtw 20260924c-idea13-build-number
##	20260924c idea 13: the release binaries print a build number, minutes from
##	2000 to the commit in Crockford base32. The rows pin the encoding and that
##	the release build is the one handed it.
eval "$(sed -n '/^fBuildNumber()/,/^}/p' "${repoDir}/cicd/cicd.bash")"
if declare -F fBuildNumber >/dev/null; then
	for row in "946684800 0" "946684829 0" "946684830 1" "946686720 10" "946746240 100" "2052828780 hjkmn" "2959950660 zzzzz" "2959950690 100000"; do
		got="$(fBuildNumber "${row% *}")"
		[[ "${got}" == "${row#* }" ]] || fBad "cicd.bash build number for ${row% *} is ${got@Q}, want ${row#* }"
	done
	##	20260924d idea 3: a time that is not one gives no build and fails, and
	##	the argument never reaches arithmetic.
	marker="${tmpDir}/build-number-ran"
	for bad in "" "abc" "946684799" "-5" "1.5" " 946684800" "x[\$(touch ${marker})]"; do
		if got="$(fBuildNumber "${bad}" 2>/dev/null)"; then fBad "cicd.bash build number took ${bad@Q} and gave ${got@Q}"; fi
	done
	if [[ -e "${marker}" ]]; then fBad "cicd.bash build number ran a command from its argument"; fi
else
	fBad "cicd.bash no longer has fBuildNumber"
fi
buildLine="$( { grep -n '^[[:space:]]*export SHCL_BUILD$' "${repoDir}/cicd/cicd.bash" || true; } | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016  ## cicd.bash's own text, matched literally
releaseLine="$( { grep -n '^[[:space:]]*"${RELEASE_NATIVE_CMD\[@\]}"$' "${repoDir}/cicd/cicd.bash" || true; } | head -n1 | cut -d: -f1)"
if [[ -z "${buildLine}" || -z "${releaseLine}" ]] || ((buildLine > releaseLine)); then
	fBad "cicd.bash does not hand SHCL_BUILD to the native release build"
fi

fTest Ep1EGVh 20260904-28-gates-read-the-strict-flag
##	20260904 item 28: SHCL_GATE_STRICT is armed by one line in cicd.bash and read
##	by the gates; deleting the line disarmed every skip-as-failure silently.
grep -qE '^\s*export SHCL_GATE_STRICT=1' "${repoDir}/cicd/cicd.bash" || fBad "cicd.bash no longer exports SHCL_GATE_STRICT under --ci"
##	The grep is for the expansion, not the name: a history line or a comment
##	mentioning the flag satisfied the old pattern, so a gate could lose its
##	guard and stay on the list. -F because the pattern has braces.
# shellcheck disable=SC2016  ## the literal expansion is the pattern
for g in check-c-compilers.bash check-locale.bash check-docs.bash check-readme.bash package.bash shell-regress.bash cli-regress.bash; do
	grep -qF '${SHCL_GATE_STRICT' "${repoDir}/cicd/utility/${g}" || fBad "${g} no longer reads SHCL_GATE_STRICT"
done
fTest Epsjpda 20260909-53-every-tool-skip-reads-the-strict-flag
##	20260909 item 53: the list above was five gates of fourteen, and every skip
##	the round found was outside it. A hand list drifts, so the rule is derived:
##	a gate that says it is skipping because a tool is not here has to be able to
##	call that a failure. Input-shaped skips (crosscheck's NUL cases,
##	check-migrate's untrimmable documents) are not environment and stay out.
for g in "${repoDir}"/cicd/utility/*.bash; do
	grep -qE 'skipping .*\(no ' "${g}" || continue
	# shellcheck disable=SC2016  ## the literal expansion is the pattern
	grep -qF '${SHCL_GATE_STRICT' "${g}" || fBad "${g##*/} skips over a missing tool without reading SHCL_GATE_STRICT"
done
##	The same skips outside the gate have to be noted, or a local run that
##	skipped one records its tree as though it ran everything. This file is not
##	in the list, since the grep below would find its own pattern; the fHave
##	self-test further down covers it.
for g in check-c-compilers.bash check-locale.bash check-docs.bash cli-regress.bash; do
	grep -qF 'SHCL_GATE_SKIPS:-/dev/null' "${repoDir}/cicd/utility/${g}" || fBad "${g} no longer notes a local skip in SHCL_GATE_SKIPS"
done
fTest EqGhNQu 20260918-11-each-skip-reads-and-notes
##	20260918 item 11: both rules above are per file, so a second skip in a file
##	that guards its first went out bare, and cli-regress's man page check did.
##	Each skip over a missing tool has to read the strict flag in the lines just
##	above it and note itself in SHCL_GATE_SKIPS in the lines just after.
for g in "${repoDir}"/cicd/utility/*.bash; do
	while IFS=: read -r n _; do
		from=$((n > 6 ? n - 6 : 1))
		# shellcheck disable=SC2016  ## the literal expansion is the pattern
		sed -n "${from},$((n - 1))p" "${g}" | grep -qF '${SHCL_GATE_STRICT' \
			|| fBad "${g##*/}:${n} skips over a missing tool without reading SHCL_GATE_STRICT just above"
		sed -n "$((n + 1)),$((n + 2))p" "${g}" | grep -qF 'SHCL_GATE_SKIPS:-/dev/null' \
			|| fBad "${g##*/}:${n} skips over a missing tool without noting it in SHCL_GATE_SKIPS"
	done < <(grep -nE '^[[:space:]]*echo ".*skipping .*\(no ' "${g}" || true)
done
fTest EqL3ERU 20260918b-43-bare-list-growth
##	20260918b item 43: the rules above key on a skip message, so a skip that
##	prints none passes them. This one keys on the defect instead: a list of rows
##	or modes grown only when a tool or a system file is here. Each one has to
##	read the strict flag within the next lines, or go through fHave or fHaveFile.
fBareGrowth(){  ## fBareGrowth FILE: prints "LINE" per bare conditional growth
	local n
	while IFS=: read -r n _; do
		# shellcheck disable=SC2016  ## the literal expansion is the pattern
		sed -n "${n},$((n + 20))p" "$1" | grep -qF '${SHCL_GATE_STRICT' || echo "${n}"
	done < <(grep -nE '(command -v [^;|]*|\[\[ -[rxefds] "?/[^]]*\]\])[[:space:]]*(&&|; then)[[:space:]]*[A-Za-z_]+\+=\(' "$1" || true)
}
for g in "${repoDir}"/cicd/utility/*.bash; do
	for n in $(fBareGrowth "${g}"); do
		fBad "${g##*/}:${n} grows a list only when a tool or file is here, and never reads SHCL_GATE_STRICT"
	done
done
## Assembled, so the bait does not trip the scan when it sweeps this file.
amp='&&'; thn='; then'
printf '%s\n' "[[ -r /usr/share/x/y ]] ${amp} modes+=(lib)" "command -v zz >/dev/null 2>&1 ${amp} tools+=(zz)" "if [[ -x /opt/t ]]${thn} rows+=(t); fi" > "${tmpDir}/growth-bait"
[[ "$(fBareGrowth "${tmpDir}/growth-bait" | paste -sd' ')" == "1 2 3" ]] || fBad "the bare list-growth scan missed its bait: $(fBareGrowth "${tmpDir}/growth-bait" | paste -sd' ')"
grep -q 'record_green=0' "${repoDir}/cicd/cicd.bash" || fBad "cicd.bash no longer holds back a partial run from recording its tree"

fTest Ep1EGVi 20260904-29-sanitize-c-arms-every-type
##	20260904 item 29: sanitize-c.bash replays every reads.tsv row type through
##	its own case arms; a type with no arm is an error there now, but a corpus
##	type the arms forgot would only show once the sanitizer run hit it. Every
##	type the corpus uses has to have an arm.
# shellcheck disable=SC2016  ## the \$ is for sed, not the shell
arms="$(sed -n '/^	case "\$type" in/,/^	esac/p' "${repoDir}/cicd/utility/sanitize-c.bash" | grep -oE "^[[:space:]]*[][a-z_'|*]+\)" | tr -d " \t')" | tr '|' '\n' | sort -u || true)"
## An arm with a `*` is a pattern, as `duration*` for `duration@s`; the rest
## are exact, since `int[]` read as a pattern is a bracket expression. The
## bare `*` is the arm that refuses an unknown type, so it counts for none.
fHasArm(){
	local arm
	grep -qxF -- "$1" <<<"${arms}" && return 0
	while IFS= read -r arm; do
		# shellcheck disable=SC2053  ## the arm is meant as a pattern
		if [[ "${arm}" != '*' && "${arm}" == *'*'* && "$1" == ${arm} ]]; then return 0; fi
	done <<<"${arms}"
	return 1
}
while IFS= read -r t; do
	[[ -n "${t}" && "${t}" != "type" ]] || continue
	fHasArm "${t}" || fBad "sanitize-c.bash has no arm for reads.tsv type ${t}"
done < <(cut -f2 "${repoDir}"/project/conformance/*/reads.tsv | sort -u)

fTest Ep1EGVj 20260904-32-no-readelf-into-grep-q
##	20260904 item 32: `cmd | grep -q` under pipefail reads a SIGPIPE'd writer as
##	"no match"; package.bash states the rule at its deb listing and broke it at
##	the libgcc probe. No readelf may feed grep -q directly.
grep -nE 'readelf[^|]*\|\s*grep -q' "${repoDir}/cicd/utility/package.bash" && fBad "package.bash pipes readelf into grep -q"

fTest Ep1BXPl 20260904-23-check-c-compilers-needs-three
##	20260904 item 23: check-c-compilers.bash reported OK with one compiler and
##	never read the gate flag, so a runner that lost its compilers would have
##	kept passing. Under the flag a thin sweep has to fail before it builds.
##	The PATH keeps every tool but the compilers, with one gcc put back.
mkdir -p "${tmpDir}/onecc"
for f in /usr/bin/* /bin/*; do
	if [[ -x "${f}" ]]; then ln -sf "${f}" "${tmpDir}/onecc/" 2>/dev/null || true; fi
done
rm -f "${tmpDir}"/onecc/gcc-* "${tmpDir}/onecc/clang" "${tmpDir}/onecc/cc" "${tmpDir}/onecc/gcc"
ln -sf "$(command -v gcc || command -v cc)" "${tmpDir}/onecc/gcc"
out="$(PATH="${tmpDir}/onecc" SHCL_GATE_STRICT=1 "${BASH}" "${repoDir}/cicd/utility/check-c-compilers.bash" "${repoDir}" 2>&1 || true)"
[[ "${out}" == *"needs two versioned gccs and clang"* ]] || fBad "check-c-compilers passed the gate with one compiler: ${out@Q}"
fTest EqzwPFN 20260909-39-check-c-compilers-long-cascade
##	20260909 item 39: a failed build's output reached `head` through a pipe,
##	and on a long cascade the writer's SIGPIPE under pipefail ended the sweep
##	at 141 instead of counting the build and going on. Both lifted steps, each
##	in a shell of its own under the script's options, since errexit does not
##	act inside a || list, on a compiler stand-in that fails with about a
##	megabyte of errors.
cccFns="$(sed -n '/^fBuild()/,/^}/p;/^fRefuse()/,/^}/p' "${repoDir}/cicd/utility/check-c-compilers.bash")"
if [[ "${cccFns}" == *"fBuild()"*"fRefuse()"* ]]; then
	printf '#!/bin/sh\nyes "x.c:1:1: error: stand-in" | head -c 1000000\nexit 1\n' > "${tmpDir}/loudcc"; chmod +x "${tmpDir}/loudcc"
	# shellcheck disable=SC2016  ## the inner shell's own parameters
	for call in 'fBuild "$1" -O2 x.c' 'fRefuse "$1" x.c "never said"'; do
		rc=0
		# shellcheck disable=SC2016  ## the inner shell's own parameters
		"${BASH}" -c 'set -Eeuo pipefail; repoDir="$3" tmpDir="$4"; eval "$2"; '"${call}" _ "${tmpDir}/loudcc" "${cccFns}" "${repoDir}" "${tmpDir}" 2>/dev/null || rc=$?
		[[ "${rc}" == 1 ]] || fBad "check-c-compilers.bash's ${call%% *} on a long error cascade returned ${rc}, not 1"
	done
else
	fBad "check-c-compilers.bash no longer has fBuild and fRefuse"
fi

fTest EqGiYnI 20260918-12-check-migrate-empty-dump
##	20260918 item 12: check-migrate reported OK on the corpus alone when its fuzz
##	dump wrote nothing, which is what a test filter matching no test does. The
##	cargo here passes a build through and writes nothing for a test.
if realCargo="$(command -v cargo)"; then
	mkdir -p "${tmpDir}/nodump"
	printf '#!/bin/sh\ncase " $* " in *" test "*) exit 0 ;; esac\nexec "%s" "$@"\n' "${realCargo}" > "${tmpDir}/nodump/cargo"
	chmod +x "${tmpDir}/nodump/cargo"
	rc=0
	# shellcheck disable=SC2031  ## this is the script's own PATH; the subshell above keeps its change
	out="$(PATH="${tmpDir}/nodump:${PATH}" "${BASH}" "${repoDir}/cicd/utility/check-migrate.bash" 2>&1)" || rc=$?
	[[ "${rc}" == 2 && "${out}" == *"the fuzz dump wrote no documents"* ]] \
		|| fBad "check-migrate passed with an empty fuzz dump (exit ${rc}): $(tail -c 200 <<<"${out}")"
else
	fHave cargo || true
	fTestSkip
fi

fTest Ep1BXPm 20260904-24-publish-identity-fallbacks
##	20260904 item 24: the publish script ran `git config user.name` as a bare
##	statement under set -e, so a repository with no identity died in the trap
##	before doing anything; and its ssh-host probe assigned from a pipeline
##	whose failure killed the script ahead of the fallback on the next line.
##	Both lines need their fallback.
pub="${repoDir}/cicd/utility/n8git_backup-and-publish"
[[ "$(grep -cE 'git config user\.(name|email)[^|]*\|\|' "${pub}" || true)" == 2 ]] || fBad "n8git_backup-and-publish reads the git identity without a fallback"
grep -qE 'sshHost="\$\(git remote get-url origin[^)]*\|\| true\)"' "${pub}" || fBad "n8git_backup-and-publish assigns sshHost without a fallback"

fTest EpxyX0a 20260909-29-gfs-keep-values-not-run
##	20260909 item 29: a GFS_KEEP_* value reached arithmetic, where bash runs a
##	command substitution hidden in an array subscript. The payload has no space,
##	since the period counts are word-split before they reach arithmetic, and the
##	subshell drops nounset, which stops the substitution at an unbound name. A
##	file from 2024 gives every period, the year included, one that has ended.
gfsLib="${repoDir}/cicd/utility/include/gfs-rotate.bash"
mkdir -p "${tmpDir}/gfs"
for n in 20240101 20260101 20260102 20260103; do : > "${tmpDir}/gfs/log_${n}-120000.txt"; done
for v in GFS_KEEP_FREQUENT GFS_KEEP_HOURLY GFS_KEEP_DAILY GFS_KEEP_WEEKLY GFS_KEEP_MONTHLY GFS_KEEP_YEARLY; do
	# shellcheck source=/dev/null
	( set +u; source "${gfsLib}"; export "${v}=x[\$(>${tmpDir}/gfs-ran-${v})]"; gfs_rotate "${tmpDir}/gfs" log txt ) >/dev/null 2>&1 || true
	[[ ! -e "${tmpDir}/gfs-ran-${v}" ]] || fBad "gfs-rotate ran a command held in ${v}"
done

fTest EpxyX0b 20260909-21-publish-keeps-work-after-failed-pull
##	20260909 item 21: a failed pull left the uncommitted work in a stash, and the
##	next run found a clean tree and published without it at exit 0. Runs in a
##	scratch remote with a stub rar; the gate's own git environment is cleared
##	first, or the sandbox commands would reach the real repository.
if command -v git >/dev/null 2>&1; then
	out="$(
		unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX GIT_CONFIG_COUNT
		export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
		sb="${tmpDir}/publish"
		mkdir -p "${sb}/bin" "${sb}/a" "${sb}/b"
		printf '#!/bin/sh\nexit 0\n' > "${sb}/bin/rar"; chmod +x "${sb}/bin/rar"
		fClone(){ git clone -q "${sb}/remote.git" "$1" 2>/dev/null; git -C "$1" config user.name t; git -C "$1" config user.email t@t.invalid ;}
		fCommit(){ echo "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2" ;}
		## The stub rar first, then the system dirs and git's own. PATH itself is
		## not read here: an earlier row sets it in a subshell, and shellcheck
		## flags any later read.
		gitBin="$(dirname "$(command -v git)")"
		fPublish(){ (cd "$1" && PATH="${sb}/bin:${gitBin}:/usr/bin:/bin" GIT_BACKUP_AND_PUBLISH_QUIET=1 GIT_BACKUP_AND_PUBLISH_NOBACKUP=1 "${BASH}" "${pub}" "${@:2}" >/dev/null 2>&1) && echo 0 || echo 1 ;}
		git init -q --bare -b main "${sb}/remote.git"
		fClone "${sb}/a/github"; fCommit "${sb}/a/github" f 1; git -C "${sb}/a/github" push -q -u origin HEAD 2>/dev/null
		fClone "${sb}/other"; fCommit "${sb}/other" g 2; git -C "${sb}/other" push -q 2>/dev/null
		## Diverged from upstream, with an uncommitted edit on top.
		fCommit "${sb}/a/github" h 3; echo dirty >> "${sb}/a/github/f"
		rc="$(fPublish "${sb}/a/github")"
		stashed="$(git -C "${sb}/a/github" stash list | wc -l)"
		git -C "${sb}/a/github" diff --quiet && dirty=0 || dirty=1
		## Up to date, clean, with an earlier run's stash still held.
		fClone "${sb}/b/github"; echo x >> "${sb}/b/github/f"; git -C "${sb}/b/github" stash push -q -m auto-stash
		rc2="$(fPublish "${sb}/b/github")"
		## 20260920b item 18: every quote in a message was swapped for a prime
		## before the commit. The message has to reach the remote as typed.
		fClone "${sb}/c/github"; echo y >> "${sb}/c/github/f"
		rc3="$(fPublish "${sb}/c/github" --message "it's \"done\"")"
		echo "${rc} ${stashed// /} ${dirty} ${rc2} ${rc3}"
		git -C "${sb}/remote.git" log -1 --format=%s 2>/dev/null || true
	)" || true
	read -r pullRc pullStashed pullDirty leftRc msgRc <<< "${out:-x x x x x}"
	[[ "${msgRc}" == 0 && "${out#*$'\n'}" == "it's \"done\"" ]] \
		|| fBad "n8git_backup-and-publish did not commit a message as given (exit ${msgRc}): ${out#*$'\n'}"
	[[ "${pullRc}" == 1 ]] || fBad "n8git_backup-and-publish exited ${pullRc} after a failed pull"
	[[ "${pullStashed}" == 0 && "${pullDirty}" == 1 ]] || fBad "n8git_backup-and-publish left the work in a stash after a failed pull (stashes ${pullStashed}, tree dirty ${pullDirty})"
	[[ "${leftRc}" == 1 ]] || fBad "n8git_backup-and-publish published over an earlier run's auto-stash"
fi

fTest Er20EK9 20260819-1-remote-sync-stage
##	20260819 item 1: the only pull was in the publish stage, after the tests,
##	so upstream work went out never built here. Stage 0 comes out of cicd.bash
##	by text and runs on clones of a scratch remote: diverged stops, behind
##	fast-forwards around a stashed edit, and a stash that will not go back
##	stops with the work kept. An untracked file upstream also adds is stashed
##	too, so the fast-forward goes through (20260923 item 14).
syncBlock="$(sed -n '/^if ((sync_enable)); then$/,/^fi$/p' "${repoDir}/cicd/cicd.bash")"
if [[ "${syncBlock}" == *"Remote sync"* && "${syncBlock}" == *"merge --ff-only"* ]]; then
	out="$(
		## The lifted block calls git too, so the user's own config is kept out here.
		git(){ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 command git "$@" ;}
		sb="${tmpDir}/sync"; mkdir -p "${sb}"
		fClone(){ git clone -q "${sb}/remote.git" "$1" 2>/dev/null; git -C "$1" config user.name t; git -C "$1" config user.email t@t.invalid ;}
		fCommit(){ echo "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2" ;}
		fSync(){   ## fSync CLONE: the lifted stage on CLONE; prints its last line
			# shellcheck disable=SC2034,SC2329  ## read by, and called from, the lifted block
			( root="$1"; sync_enable=1; stamp=t
			  fSection(){ :; }; fEcho(){ echo "$*"; }; fDie(){ echo "DIE: $*"; exit 1; }
			  eval "${syncBlock}" ) 2>&1 | tail -n 1 || true
		}
		git init -q --bare -b main "${sb}/remote.git"
		fClone "${sb}/up"; fCommit "${sb}/up" f 1; fCommit "${sb}/up" g 1; git -C "${sb}/up" push -q -u origin HEAD 2>/dev/null
		for c in div conflict other untracked clash; do fClone "${sb}/${c}"; done
		fCommit "${sb}/up" f 2; fCommit "${sb}/up" h 2; git -C "${sb}/up" push -q 2>/dev/null
		fCommit "${sb}/div" g 3
		echo 9 > "${sb}/conflict/f"
		echo 9 > "${sb}/other/g"
		echo 9 > "${sb}/untracked/new"
		fSync "${sb}/div"
		fSync "${sb}/conflict"; git -C "${sb}/conflict" stash list | wc -l
		fSync "${sb}/other"; cat "${sb}/other/f" "${sb}/other/g"
		fSync "${sb}/untracked"
		echo 9 > "${sb}/clash/h"
		fSync "${sb}/clash"; git -C "${sb}/clash" stash list | wc -l; cat "${sb}/clash/f"
	)" || true
	syncWant="DIE: main and origin/main have diverged (1 local, 2 remote); reconcile by hand
DIE: the local changes conflict with origin/main; they are safe in the stash - resolve, then 'git stash drop'
1
OK: fast-forwarded 2 commit(s) from origin/main
2
9
OK: fast-forwarded 2 commit(s) from origin/main
DIE: the local changes conflict with origin/main; they are safe in the stash - resolve, then 'git stash drop'
1
2"
	[[ "${out}" == "${syncWant}" ]] || fBad "cicd.bash's remote sync did not stop, fast-forward and keep the work as it should: ${out@Q}"
else
	fBad "cicd.bash no longer has its remote sync stage as one if-block"
fi

fTest Eq92jkm 20260909-39-git-auto-msg-empty-messages
##	20260909 item 39: git-auto-msg.bash judged "empty" by `#` alone and wrote
##	the message as given, so git threw the commit away as empty under another
##	comment char, commit.verbose, an unedited template, or a message whose line
##	starts with the comment char. The last one has to fail by name instead.
if command -v git >/dev/null 2>&1; then
	out="$(
		unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX GIT_CONFIG_COUNT
		sb="${tmpDir}/automsg"
		git init -q -b main "${sb}"; cd "${sb}" || exit
		git config user.name t; git config user.email t@t.invalid
		printf 'template text\n' > "${sb}/tmpl"
		fTry(){   ## fTry MESSAGE [CONFIG=VALUE]: prints the subject git stored, or "rc N"
			local rc=0
			echo "$RANDOM" >> f; git add f
			env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR="${repoDir}/cicd/utility/git-auto-msg.bash" GIT_AUTO_MESSAGE="$1" \
				git ${2:+-c "$2"} commit -q >/dev/null 2>"${sb}/err" || rc=$?
			((rc == 0)) && git log -1 --format=%s || echo "rc ${rc}"
		}
		fTry plain
		fTry semi core.commentChar=';'
		fTry verbose commit.verbose=true
		fTry tmpl commit.template="${sb}/tmpl"
		fTry '   '
		fTry '#12 fix'
		grep -c 'drops as a comment' "${sb}/err" || true
	)" || true
	want=$'plain\nsemi\nverbose\ntmpl\nCI/CD automated commit\nrc 1\n1'
	[[ "${out}" == "${want}" ]] || fBad "git-auto-msg.bash: commits came out as ${out@Q}"
fi

fTest EqpV5Gi 20260924c-idea11-dogfood-runner
##	20260924c idea 11: dogfood_shcl.ps1 replaced n8runshcl.ps1 and keeps its
##	lessons: a file with some other name in the pool is not a version, the build
##	about to run is never pruned, and a failed removal says so. Plus its own: the
##	pipe sees only what shcl printed, `-v` reaches shcl, a running version stays,
##	and a regular file at the fixed name is someone else's.
if fHave pwsh; then
	dh="${tmpDir}/dfhome"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	dpool="${dh}/.local/bin/shcl_versions"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	printf '#!/bin/sh\necho "one: $*"\nexit 3\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	touch -d '2026-09-20 10:00 UTC' "${dsrc}/shcl"
	fDogfood(){ env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" TZ=UTC pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" "$@" 2>"${tmpDir}/df.err" ;}
	rc=0; out="$(fDogfood -v a)" || rc=$?
	[[ "${out}" == "one: -v a" && "${rc}" == 3 ]] || fBad "dogfood_shcl.ps1 did not run the build with its arguments and exit code: ${out@Q} rc ${rc}"
	[[ "$(readlink "${dh}/.local/bin/shcl")" == "${dpool}/shcl_20260920-100000_newest" ]] || fBad "dogfood_shcl.ps1 did not point the fixed name at the new version"
	grep -q 'new build 20260920-100000' "${tmpDir}/df.err" || fBad "dogfood_shcl.ps1 said nothing on stderr about the build it took"
	out="$(fDogfood x)" || true
	[[ "${out}" == "one: x" && ! -s "${tmpDir}/df.err" ]] || fBad "dogfood_shcl.ps1 spoke up on a run that changed nothing: $(cat "${tmpDir}/df.err")"
	for d in 01 02 03 04 05 06 07 08 09 10 11 12; do : > "${dpool}/shcl_202608${d}-120000"; done
	: > "${dpool}/shcl_junk"
	cp /bin/sleep "${dpool}/shcl_20260805-120000"
	chmod 755 "${dpool}/shcl_20260805-120000"
	"${dpool}/shcl_20260805-120000" 60 & sleeper=$!
	out="$(fDogfood y)" || true
	kill "${sleeper}" 2>/dev/null || true; wait "${sleeper}" 2>/dev/null || true
	n="$(find "${dpool}" -name 'shcl_2026*' | wc -l)"
	[[ "${out}" == "one: y" ]] || fBad "dogfood_shcl.ps1 ran something other than the newest build: ${out@Q}"
	((n >= 5 && n <= 11)) || fBad "dogfood_shcl.ps1 kept ${n} versions, outside the budget"
	[[ -e "${dpool}/shcl_junk" ]] || fBad "dogfood_shcl.ps1 deleted a file that is not a version"
	[[ -e "${dpool}/shcl_20260805-120000" ]] || fBad "dogfood_shcl.ps1 deleted a version that was running"
	[[ -e "${dpool}/shcl_20260920-100000_newest" && -e "${dpool}/shcl_20260801-120000_oldest" ]] || fBad "dogfood_shcl.ps1 lost the newest or the oldest version: $(find "${dpool}" -mindepth 1 -printf '%f ')"
	for d in 01 02 03 04 05 06 07 08 09; do : > "${dpool}/shcl_202607${d}-120000"; done
	if ((EUID != 0)); then
		chmod 555 "${dpool}"
		out="$(fDogfood z)" || true
		chmod 755 "${dpool}"
		grep -q 'could not remove shcl_202607' "${tmpDir}/df.err" || fBad "dogfood_shcl.ps1 said nothing about a version it failed to remove: $(cat "${tmpDir}/df.err")"
	fi
	rm -f "${dh}/.local/bin/shcl"; echo mine > "${dh}/.local/bin/shcl"
	out="$(fDogfood w)" || true
	[[ "$(cat "${dh}/.local/bin/shcl")" == mine && "${out}" == "one: w" ]] || fBad "dogfood_shcl.ps1 replaced a regular file at the fixed name, or did not run the newest: ${out@Q}"
else
	fTestSkip
fi

fTest Er7xgGI 20260926-item11-dogfood-stamp-culture
##	20260926 item 11: the runner wrote a build's stamp in the current culture and
##	read it back as invariant, so under th-TH the held name moved 543 years each
##	run and a newer build was never taken. Stamps are local time (reopened
##	20260928), so the zone is pinned away from UTC.
if fHave pwsh; then
	dh="${tmpDir}/dfculture"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	printf '#!/bin/sh\necho one\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	touch -d '2026-09-20 10:00 UTC' "${dsrc}/shcl"
	fDogfoodTh(){ env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" TZ=Asia/Bangkok LC_ALL=th_TH.UTF-8 LANG=th_TH.UTF-8 pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" "$@" 2>"${tmpDir}/df.err" ;}
	fDogfoodTh x >/dev/null || true
	fDogfoodTh x >/dev/null || true
	held="$(find "${dh}/.local/bin/shcl_versions" -mindepth 1 -printf '%f ')"
	[[ "${held}" == "shcl_20260920-170000_newest " ]] || fBad "dogfood_shcl.ps1 under th-TH held ${held@Q}"
	printf '#!/bin/sh\necho two\n' > "${dsrc}/shcl"
	touch -d '2026-09-21 10:00 UTC' "${dsrc}/shcl"
	out="$(fDogfoodTh x)" || true
	[[ "${out}" == two ]] || fBad "dogfood_shcl.ps1 under th-TH did not take the newer build: ${out@Q}"
else
	fTestSkip
fi

fTest Er7xgHi 20260924d-item4-dogfood-no-update-target
##	20260924d item 4: --no-update ran whatever the fixed name pointed at, an
##	installed release included, not only the newest held build.
if fHave pwsh; then
	dh="${tmpDir}/dfnoupdate"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin" "${dh}/other"
	printf '#!/bin/sh\necho held\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	fDogfoodN(){ env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" "$@" 2>"${tmpDir}/df.err" ;}
	fDogfoodN x >/dev/null || true
	printf '#!/bin/sh\necho installed\n' > "${dh}/other/shcl"; chmod +x "${dh}/other/shcl"
	ln -sfn "${dh}/other/shcl" "${dh}/.local/bin/shcl"
	out="$(fDogfoodN --no-update)" || true
	[[ "${out}" == held ]] || fBad "dogfood_shcl.ps1 --no-update ran what the fixed name pointed at: ${out@Q}"
else
	fTestSkip
fi

fTest ErD17r2 20260928-item16-dogfood-impossible-date
##	20260928 item 16: a pool file named for a date that cannot be, a 13th month,
##	stopped every run before shcl started, --no-update included. It is not one
##	of the runner's, so it is left alone.
if fHave pwsh; then
	dh="${tmpDir}/dfbaddate"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	printf '#!/bin/sh\necho held\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	fDogfoodB(){ env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" "$@" 2>"${tmpDir}/df.err" ;}
	fDogfoodB x >/dev/null || true
	: > "${dh}/.local/bin/shcl_versions/shcl_20261399-000000"
	rc=0; out="$(fDogfoodB --no-update)" || rc=$?
	[[ "${out}" == held && "${rc}" == 0 ]] || fBad "dogfood_shcl.ps1 --no-update with an impossible pool date: ${out@Q} rc ${rc}: $(head -c 200 "${tmpDir}/df.err")"
	rc=0; out="$(fDogfoodB x)" || rc=$?
	[[ "${out}" == held && "${rc}" == 0 && -e "${dh}/.local/bin/shcl_versions/shcl_20261399-000000" ]] || fBad "dogfood_shcl.ps1 with an impossible pool date: ${out@Q} rc ${rc}, or the file went"
else
	fTestSkip
fi

fTest ErkOqsp 20261003-item5-dogfood-file-colon-args
##	Code review 20261003 item 5: the launchers start the runner with -File, so
##	a `-`-led argument with a colon reached shcl in two pieces. Through the
##	bash launcher, the way it is typed.
if fHave pwsh; then
	dh="${tmpDir}/dfcolon"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	#  shellcheck disable=2016  ## the stub's own $@ and $a.
	printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	#  shellcheck disable=2016  ## PowerShell's own $true, passed as typed.
	colonArgs=(get '--set=url=http://x' '-x:y' '-b:' c '-k:$true' '--z=1:2' -- '' 'a b')
	want="$(printf '[%s]\n' "${colonArgs[@]}")"
	got="$(env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" bash "${repoDir}/utility/dogfood_shcl" "${colonArgs[@]}" 2>/dev/null </dev/null || true)"
	[[ "${got}" == "${want}" ]] || fBad "dogfood_shcl changed its arguments on the way to shcl: ${got@Q} against ${want@Q}"
else
	fTestSkip
fi

fTest ErmwiJ3 2026100408550401-dogfood-session-colon-args
##	Called from a session, an unquoted `-x:y` reached shcl as `y`. It wants
##	what a direct call passes, where `-x: y` is two arguments.
if fHave pwsh; then
	dh="${tmpDir}/dfsesscolon"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	#  shellcheck disable=2016  ## the stub's own $@ and $a.
	printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	cat > "${tmpDir}/dfsesscolon.ps1" <<'PSEOF'
Set-StrictMode -Version Latest
$o = @(& $args[0] --no-update a -x:y -x: y '-x:' y -k:$true)
$want = @('[a]', '[-x:y]', '[-x:]', '[y]', '[-x:]', '[y]', '[-k:True]')
if (($o -join '|') -cne ($want -join '|')) { "lost: came back [$($o -join '|')]" } else { 'done' }
PSEOF
	env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" x >/dev/null 2>&1 </dev/null || true
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${tmpDir}/dfsesscolon.ps1" "${repoDir}/utility/dogfood_shcl.ps1" 2>&1 </dev/null || true)"
	[[ "${out}" == "done" ]] || fBad "dogfood_shcl.ps1 from a session changed a colon argument: ${out@Q}"
else
	fTestSkip
fi

fTest ErkOqyK 20261003-item8-dogfood-legacy-quotes
##	Code review 20261003 item 8: the runner called shcl with its arguments as
##	they came, so under Windows PowerShell 5.1 an embedded quote never reached
##	shcl and an empty argument was left out. `zip="02134"` saved as a number at
##	exit 0. The Legacy mode of 7 builds the command line the same way, so it
##	stands in for 5.1. Same values as shcl.ps1's row (20260928 item 4).
if fHave pwsh; then
	dh="${tmpDir}/dflegacy"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	#  shellcheck disable=2016  ## the stub's own $@ and $a.
	printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	#  shellcheck disable=2016,2028  ## PowerShell's own $variables and backslashes, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$PSNativeCommandArgumentPassing = "Legacy"'
		echo '$q = [string][char]34'
		echo '$vals = @(("zip=" + $q + "02134" + $q), ($q + "q" + $q), ("a" + $q + "b"), "", "C:\a b\", ("p\" + $q + "q"), ("x " + $q + "y" + $q + " z"))'
		echo '$o = @(& $args[0] --no-update @vals)'
		echo '$want = @($vals | ForEach-Object { "[" + $_ + "]" })'
		echo 'if (($o -join "|") -cne ($want -join "|")) { "lost: came back [$($o -join "|")]" } else { "done" }'
	} > "${tmpDir}/dflegacy.ps1"
	env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" x >/dev/null 2>&1 </dev/null || true
	out="$(env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${tmpDir}/dflegacy.ps1" "${repoDir}/utility/dogfood_shcl.ps1" 2>&1 </dev/null || true)"
	[[ "${out}" == "done" ]] || fBad "dogfood_shcl.ps1 under legacy argument passing: ${out@Q}"
else
	fTestSkip
fi

fTest Er7xgJ2 20260924d-item6-dogfood-quiet-notes
##	20260924d item 6: the note that the fixed name was left alone came on every
##	run. It comes with the build that could not be linked, and not again.
if fHave pwsh; then
	dh="${tmpDir}/dfquiet"
	dsrc="${dh}/synced/0-0/common/exec/util/linux/bin"
	mkdir -p "${dsrc}" "${dh}/.local/bin"
	printf '#!/bin/sh\necho one\n' > "${dsrc}/shcl"; chmod +x "${dsrc}/shcl"
	echo mine > "${dh}/.local/bin/shcl"
	fDogfoodQ(){ env -u DISPLAY -u WAYLAND_DISPLAY HOME="${dh}" pwsh -NoProfile -File "${repoDir}/utility/dogfood_shcl.ps1" "$@" 2>"${tmpDir}/df.err" ;}
	fDogfoodQ x >/dev/null || true
	grep -q 'left alone' "${tmpDir}/df.err" || fBad "dogfood_shcl.ps1 did not say the fixed name was left alone when it took a build"
	fDogfoodQ x >/dev/null || true
	[[ ! -s "${tmpDir}/df.err" ]] || fBad "dogfood_shcl.ps1 repeated a note on a run that changed nothing: $(cat "${tmpDir}/df.err")"
else
	fTestSkip
fi

fTest Er7zdIP 20260924d-idea1-dogfood-dests
##	20260924d idea 1: stage 7 fell back to ~/.local/bin, where shcl is the
##	dogfood runner's link and the installer's, and a copy there replaced the
##	link with a regular file both then refused.
# shellcheck disable=SC2016  ## expands in the child shell
dests="$(HOME=/h bash -c 'set +u; source "$1"; printf "%s\n" "${DOGFOOD_FIXED_DESTS[@]}"' _ "${repoDir}/cicd/config.bash")"
if grep -qxF '/h/.local/bin' <<< "${dests}"; then fBad "stage 7 can drop the binary over the dogfood runner's link: ${dests//$'\n'/ }"; fi

fTest EqpV5Gj 20260924c-idea9-dogfood-binary-in-use
##	20260924c idea 9: the dogfood stage copied over a binary that was running.
##	It asks /proc first now.
eval "$(sed -n '/^fInUse()/,/^}/p' "${repoDir}/cicd/cicd.bash")"
if ! declare -F fInUse >/dev/null; then
	fBad "cicd.bash no longer has fInUse"
elif [[ -d /proc/self ]]; then
	cp /bin/sleep "${tmpDir}/inuse-bin"
	"${tmpDir}/inuse-bin" 60 & inusePid=$!
	sleep 0.3
	fInUse "${tmpDir}/inuse-bin" || fBad "cicd.bash did not see a running dogfood binary"
	kill "${inusePid}" 2>/dev/null || true; wait "${inusePid}" 2>/dev/null || true
	fInUse "${tmpDir}/inuse-bin" && fBad "cicd.bash called an idle dogfood binary running"
	# shellcheck disable=SC2016  ## cicd.bash's own text, matched literally
	grep -qF 'fInUse "${dogfood_dest}/${EXE_NAME}"' "${repoDir}/cicd/cicd.bash" || fBad "cicd.bash no longer asks whether the dogfood binary is running"
fi

fTest Ep1BXPn 20260904-25-largedoc-small-size
##	20260904 item 25: largedoc's memory ceilings were strictly per input MiB, so
##	at one MiB the runtime's own footprint failed a healthy tree. Run the gate
##	small, which is exactly the size a developer shrinks it to.
if [[ -x "${cli}" && -x "${repoDir}/source/go/shcl" && -x "${repoDir}/source/c/shcl" ]]; then
	out="$(bash "${repoDir}/cicd/utility/largedoc.bash" --mib 1 "rust|${cli}" "go|${repoDir}/source/go/shcl" "python|${repoDir}/source/python/cmd/shcl/main.py" "c|${repoDir}/source/c/shcl" 2>&1 || true)"
	[[ "${out}" == *"OK"* && "${out}" != *"TOO BIG"* ]] || fBad "largedoc --mib 1 fails on a healthy tree: $(tail -n 3 <<<"${out}")"
else
	fTestSkip
fi

fTest ErD7avs 20260928-item18-closed-items-test-parent
##	20260928 item 18: check-docs' closed-items check took the nearest closed item
##	above as the parent, so an item under a review round's heading bullet passed
##	on a Test line from an item above the round. The check's Python is lifted
##	out by text and run on a small backlog: one borrowed line must be named,
##	and an item inside a closed item with a Test line, or under a plain bullet
##	inside one, must not.
docs="${repoDir}/cicd/utility/check-docs.bash"
awk -v id=Er8RudX '$1 == "fTest" && $2 == id {on = 1} on && /<<.PYEOF.$/ {py = 1; next} py && /^PYEOF$/ {exit} py' "${docs}" > "${tmpDir}/closed.py"
{
	printf '## Done\n\n'
	printf -- '- \u2705 Earlier item.\n\t- Test case: t0.\n\n'
	printf -- '- Code review X:\n\n\t- \u2705 Borrowed item.\n\t\t- Opened: 1\n\n'
	printf -- '- \u2705 Parent item.\n\t- Test case: t1.\n\t- \u2705 Child item.\n\t- Languages:\n\t\t- \u2705 Grandchild item.\n'
} > "${tmpDir}/closed.md"
if [[ ! -s "${tmpDir}/closed.py" ]]; then
	fBad "the closed-items check was not found in check-docs.bash"
else
	out="$(python3 "${tmpDir}/closed.py" "${tmpDir}/closed.md" 2>&1 || true)"
	[[ "${out}" == *"Borrowed item"* && "${out}" != *"Child item"* && "${out}" != *"Grandchild"* && "${out}" != *"Traceback"* ]] \
		|| fBad "closed-items check on a fixture backlog said: ${out@Q}"
fi

fTest ErD9eyc 20260928-item19-skipped-block-names-its-tests
##	20260928 item 19: a block skipped for a missing tool printed a skip line for
##	the test opened before it and nothing for the tests inside it. The helper
##	reads the block out of the calling script, so it is run on a script here,
##	nested blocks, a one-line else and a function included.
{
	printf '%s\n' 'testWhere=t testCounter=nBad; nBad=0' "source '${repoDir}/cicd/utility/include/test-id.bash'"
	printf '%s\n' 'fTest A1 first' 'if false; then' '	fTest B2 nested' '	if true; then' '		fTest C3 deeper' '	fi' 'else' '	fTestSkipBlock' 'fi'
	printf '%s\n' 'fTest D4 after' 'fg(){' '	fTest E5 in-function' '	if false; then' '		fTest F6 fn-nested' '	else fTestSkipBlock; fi' '}' 'fg' 'fTestEnd'
} > "${tmpDir}/skipblock.bash"
out="$(bash "${tmpDir}/skipblock.bash" 2>&1 | tr '\n' ' ' || true)"
[[ "${out}" == "skip A1 t first skip B2 t nested skip C3 t deeper ok   D4 t after skip E5 t in-function skip F6 t fn-nested " ]] \
	|| fBad "fTestSkipBlock on a fixture script printed: ${out@Q}"

fTest ErDB6ek 20260928-idea6-test-ids-strays
##	20260928 idea 6: a Rust test outside lib.rs and tests/, a Go test whose
##	parameter is not t, and one under the Go CLI's module ran with no ID, and
##	test-ids.py said nothing. A fake tree holds one of each, and a placed one.
ti="${tmpDir}/tids"
mkdir -p "${ti}/cicd/utility" "${ti}/project/conformance" "${ti}/source/rust/src" "${ti}/source/go/cmd/shcl"
cp "${repoDir}/cicd/utility/test-ids.py" "${ti}/cicd/utility/"
printf 'rows=(\n)\nsaveCases=(\n)\n' > "${ti}/cicd/utility/cli-regress.bash"
printf 'workloads=(\n)\n' > "${ti}/cicd/utility/perf-gate.bash"
printf '#[cfg(test)]\nmod t {\n\t#[test]\n\tfn x() {}\n}\n' > "${ti}/source/rust/src/other.rs"
printf 'package shcl\n\nfunc TestTT(tt *testing.T) {\n}\n\nfunc TestOk(t *testing.T) {\n\tdefer testID(t, "ErD9eyd")\n}\n' > "${ti}/source/go/x_test.go"
printf 'package main\n\nfunc TestCmd(t *testing.T) {\n}\n' > "${ti}/source/go/cmd/shcl/main_test.go"
if git -C "${ti}" init -q 2>/dev/null && git -C "${ti}" add -A 2>/dev/null; then
	out="$(python3 "${ti}/cicd/utility/test-ids.py" check 2>&1 || true)"
	n="$(grep -c 'a test in a place the tables here do not know' <<<"${out}" || true)"
	[[ "${n}" == 3 && "${out}" == *"other.rs:3:"* && "${out}" == *"x_test.go:3:"* && "${out}" == *"main_test.go:3:"* ]] \
		|| fBad "test-ids.py on three misplaced tests said: ${out@Q}"
else
	fBad "could not make the fake tree for test-ids.py"
fi

fTest EoXPkY4 check-completions-option-less-subcommand
##	The completions check against a subcommand that takes no options. One side
##	emitted a row for it and the other dropped any row with an empty option
##	list, so the two could never agree however the completions wrote it - a
##	lint failure blaming the completions on the day such a subcommand is added.
##	The fixture is the real files with one added, so the check runs against the
##	extractors as shipped rather than a hand-written stand-in.
gate="${repoDir}/cicd/utility/check-completions.bash"
if [[ -x "${gate}" ]]; then
	fix="${tmpDir}/optless"
	mkdir -p "${fix}/source/rust/src" "${fix}/source/completions"
	##	20260920 idea 7: a replace whose anchor has moved does nothing and says
	##	nothing. One broken anchor leaves the row failing for the wrong reason,
	##	and all six broken leaves it comparing the real files with each other
	##	and passing. Every replace is checked and names the anchor it wanted.
	fixRc=0
	python3 - "${repoDir}" "${fix}" > "${tmpDir}/optless.log" 2>&1 <<'PYEOF' || fixRc=$?
import sys
repo, fix = sys.argv[1], sys.argv[2]
TAB = chr(9)
NL = chr(10)

def sub(text, old, new, what):
    out = text.replace(old, new, 1)
    if out == text:
        sys.exit("anchor not found: " + what)
    return out

s = open(repo + "/source/rust/src/main.rs").read()
arm = TAB * 2 + '"count" | "instances" | "children" | "paths" => &['
s = sub(s, arm, TAB * 2 + '"ping" => &[],' + NL + arm, "main.rs: the option-less arm of allowed_opts")
s = sub(s, TAB + '"explain",' + NL + "];", TAB + '"explain",' + NL + TAB + '"ping",' + NL + "];", "main.rs: the end of COMMANDS")
disp = TAB * 2 + '"paths" => do_paths(o),'
hl = "  shcl paths [options] FILE "
s = sub(s, hl, "  shcl ping                              say nothing" + NL + hl, "main.rs: the paths line of the help")
s = sub(s, disp, disp + NL + TAB * 2 + '"ping" => 0,', "main.rs: the paths line of the dispatch")
open(fix + "/source/rust/src/main.rs", "w").write(s)
for name in ("shcl.bash", "_shcl"):
    c = open(repo + "/source/completions/" + name).read()
    row = TAB * 2 + "count|instances|children|paths) echo '--strictness"
    c = sub(c, row, TAB * 2 + "ping)            echo '' ;;" + NL + row, name + ": the option row for count")
    if name == "shcl.bash":
        c = sub(c, "paths migrate tokens explain help", "paths migrate tokens explain ping help", name + ": the command list")
    else:
        pl = TAB * 2 + "'paths:every field path in the document'"
        c = sub(c, pl, pl + NL + TAB * 2 + "'ping:say nothing'", name + ": the paths description")
    open(fix + "/source/completions/" + name, "w").write(c)
PYEOF
	if ((fixRc != 0)); then
		fBad "the check-completions fixture did not build: $(cat "${tmpDir}/optless.log")"
	elif ! out="$("${gate}" "${fix}" 2>&1)"; then
		fBad "check-completions rejects an option-less subcommand the completions list correctly: ${out}"
	fi
fi

fTest EoXV3tQ installers-help-version-refusals
##	Both bash installers used to heredoc their own source header, so the help
##	opened with the file name as a comment and every wrapped line had a `##`
##	and a hard tab. The PowerShell installer printed clean prose, so the two
##	documented installers spoke in different registers.
for inst in install.bash install-dev.bash; do
	[[ -f "${repoDir}/${inst}" ]] || continue
	help="$(bash "${repoDir}/${inst}" --help 2>&1 || true)"
	if grep -q '^##' <<<"${help}"; then
		fBad "${inst} --help prints comment markup"
	fi
	if grep -qP '\t' <<<"${help}"; then
		fBad "${inst} --help prints hard tabs, which render raggedly off tab width 8"
	fi
	[[ -n "${help}" ]] || fBad "${inst} --help printed nothing"
	##	20260803 item 24: the help was read back out of the script's own file,
	##	which the one-liner's pipe does not leave, so it printed nothing at exit
	##	0. And an option given no value ended the run with nothing said.
	help="$(bash <(cat "${repoDir}/${inst}") --help 2>&1 || true)"
	[[ "${help}" == *"Usage (one-liner):"* ]] || fBad "${inst} --help through the one-liner's pipe: $(head -n 4 <<<"${help}")"
	opt=--dir; [[ "${inst}" == install.bash ]] && opt=--target
	rc=0; out="$(bash "${repoDir}/${inst}" "${opt}" 2>&1 </dev/null)" || rc=$?
	[[ "${rc}" != 0 && "${out}" == *"missing value for ${opt}"* ]] || fBad "${inst} ${opt} with no value (exit ${rc}): ${out@Q}"
	##	20260924c ideas 1 and 2: the installer names its own version, and every
	##	run opens and ends on a blank line, a refusal included. Byte for byte,
	##	since a substitution would eat the blank lines this is about.
	ver="$(sed -n 's/^installer_version="\(.*\)"$/\1/p' "${repoDir}/${inst}")"
	rc=0; bash "${repoDir}/${inst}" --version >"${tmpDir}/iv.out" 2>"${tmpDir}/iv.err" </dev/null || rc=$?
	if ! { [[ "${rc}" == 0 && -n "${ver}" && ! -s "${tmpDir}/iv.err" ]] && cmp -s "${tmpDir}/iv.out" <(printf '\n%s %s\n\n' "${inst}" "${ver}"); }; then
		fBad "${inst} --version (exit ${rc}): $(od -c "${tmpDir}/iv.out" | head -n 3)"
	fi
	rc=0; bash "${repoDir}/${inst}" --bogus >"${tmpDir}/iv.out" 2>"${tmpDir}/iv.err" </dev/null || rc=$?
	if ! { [[ "${rc}" == 1 ]] && cmp -s "${tmpDir}/iv.out" <(printf '\n') && cmp -s "${tmpDir}/iv.err" <(printf '%s: unknown option: --bogus\n\n' "${inst}"); }; then
		fBad "${inst} does not open and end a refusal on a blank line (exit ${rc}): $(od -c "${tmpDir}/iv.out" "${tmpDir}/iv.err" | head -n 5)"
	fi
	[[ "${help}" == $'\n'* ]] || fBad "${inst} --help does not open on a blank line"
	[[ "$(tail -c 2 < <(bash "${repoDir}/${inst}" --help 2>&1 </dev/null) | od -An -c | tr -d ' ')" == '\n\n' ]] \
		|| fBad "${inst} --help does not end on a blank line"
done

fTest EoXVLaC install-bash-uninstall-names-leftovers
##	The bash uninstall reported "removed" while leaving a directory full of files
##	it had not installed. The PowerShell installer already said so; this is the
##	same wording on the bash side.
if [[ -f "${repoDir}/install.bash" ]]; then
	fake="${tmpDir}/fakehome"
	mkdir -p "${fake}/.local/share/shcl"
	out="$(HOME="${fake}" bash "${repoDir}/install.bash" --target user --uninstall --yes 2>&1 || true)"
	grep -q '^removed$' <<<"${out}" || fBad "install.bash --uninstall of an empty dir did not report a clean removal: ${out}"
	mkdir -p "${fake}/.local/share/shcl"
	printf 'x\n' > "${fake}/.local/share/shcl/not-ours.txt"
	out="$(HOME="${fake}" bash "${repoDir}/install.bash" --target user --uninstall --yes 2>&1 || true)"
	grep -q 'did not put there' <<<"${out}" || fBad "install.bash --uninstall said nothing about the files it left behind: ${out}"
	[[ -f "${fake}/.local/share/shcl/not-ours.txt" ]] || fBad "install.bash --uninstall removed a file it did not install"
fi

fTest EqzwPFO 20260829-20-no-terminal-prompt
##	20260829 item 20: with no terminal, the prompt's open of /dev/tty failed
##	out loud ahead of the message saying so. setsid leaves no terminal, and the
##	uninstall asks before it touches anything. install-dev.bash's prompt is run
##	the same way in check-install-dev.bash; the install prompt waits on the
##	network, so every site is also held to the order.
if fHave setsid; then
	## An install dir to remove, or the uninstall says there is nothing to do
	## before it asks.
	mkdir -p "${tmpDir}/ttyhome/.local/share/shcl"
	rc=0; HOME="${tmpDir}/ttyhome" setsid -w bash "${repoDir}/install.bash" --uninstall --target=user >/dev/null 2>"${tmpDir}/tty.err" </dev/null || rc=$?
	[[ "${rc}" == 1 && "$(head -n1 "${tmpDir}/tty.err")" == "install.bash: no terminal to confirm on - pass --yes" ]] \
		|| fBad "install.bash with no terminal does not say so first (exit ${rc}): $(head -n1 "${tmpDir}/tty.err")"
else
	fTestSkip
fi
ttyReads="$(grep -n -F '</dev/tty' "${repoDir}/install.bash" "${repoDir}/install-dev.bash" || true)"
n="$(grep -c . <<<"${ttyReads}" || true)"
((n >= 3)) || fBad "found ${n} of the three terminal prompts in install.bash and install-dev.bash"
while IFS= read -r h; do
	[[ -z "${h}" || "${h}" == *'2>/dev/null </dev/tty'* ]] || fBad "a terminal prompt opens /dev/tty before its errors are silenced: ${h}"
done <<<"${ttyReads}"

fTest EoXVsMS install-ps1-smoke-before-publish
##	install.ps1 used to run the binary only after writing it into place, where
##	the Linux installer runs it from the temp dir first so one that will not
##	start never becomes an install. Order in the source is the whole assertion;
##	running the real thing needs a network and a release.
ps1="${repoDir}/install.ps1"
if [[ -f "${ps1}" ]]; then
	smokeLine="$({ grep -n "Invoke-ShclSmoke -Exe \$tmpExe" "${ps1}" || true ;} | head -n1 | cut -d: -f1)"
	publishLine="$({ grep -n "Move-Item -Force -LiteralPath (Join-Path -Path \$dest -ChildPath '.shcl.exe.new')" "${ps1}" || true ;} | head -n1 | cut -d: -f1)"
	if [[ -z "${smokeLine}" ]]; then
		fBad "install.ps1 never runs the downloaded binary from the temp dir"
	elif [[ -z "${publishLine}" ]]; then
		fBad "install.ps1: cannot find where the binary is published"
	elif ((smokeLine >= publishLine)); then
		fBad "install.ps1 runs the binary at line ${smokeLine}, after publishing it at ${publishLine}"
	fi
	## A bare native call throws under this script's error preference on 7.4+,
	## which turned a failing binary into an exception after the success message.
	grep -q 'smoke.Code -ne 0' <<<"$(sed -n "${smokeLine:-1},+4p" "${ps1}")" \
		|| fBad "install.ps1 does not test the smoke run's exit status"

	fTest EqzwPFP 20260829-22-install-ps1-basic-parsing-and-tar
	##	20260829 item 22: Windows PowerShell 5.1 needs -UseBasicParsing on a
	##	web call wherever the IE engine is missing, Server Core among them. And
	##	a Windows older than 10 1803 has no tar, which has to be found out before
	##	the first download rather than after it.
	webCalls="$(grep -nE '(^|[^A-Za-z-])(Invoke-WebRequest|Invoke-RestMethod)([^A-Za-z-]|$)' "${ps1}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
	n="$(grep -c . <<<"${webCalls}" || true)"
	((n >= 2)) || fBad "install.ps1: found ${n} web calls to check for -UseBasicParsing"
	while IFS= read -r h; do
		[[ -z "${h}" || "${h}" == *"-UseBasicParsing"* ]] || fBad "install.ps1 makes a web call without -UseBasicParsing: ${h}"
	done <<<"${webCalls}"
	tarLine="$( { grep -n 'Get-Command -Name tar ' "${ps1}" || true ;} | head -n1 | cut -d: -f1)"
	getLine="$( { grep -n '^[[:space:]]*Save-ReleaseAsset -Uri ' "${ps1}" || true ;} | head -n1 | cut -d: -f1)"
	if [[ -z "${tarLine}" || -z "${getLine}" ]] || ((tarLine >= getLine)); then
		fBad "install.ps1 does not look for tar before its first download"
	fi

	fTest EqzwPFQ 20260829-19-install-ps1-uninstall-hint
	##	20260829 item 19: the uninstall hint named a script file the one-liner
	##	user never had. The lifted line, both ways the script can be run.
	# shellcheck disable=SC2016  ## PowerShell's own $variable, matched literally
	rerunLine="$( { grep -F '$rerun = if ($invokedAsFile)' "${ps1}" || true ;} | head -n1)"
	if [[ -z "${rerunLine}" ]]; then
		fBad "install.ps1's uninstall hint is not the line this row lifts"
	elif fHave pwsh; then
		#  shellcheck disable=2016  ## PowerShell's own $variables.
		{
			echo '$scriptPath = "C:\x\install.ps1"'
			echo 'foreach ($invokedAsFile in $false, $true) {'
			printf '%s\n' "${rerunLine}"
			echo 'Write-Output "file=$invokedAsFile $rerun"'
			echo '}'
		} > "${tmpDir}/rerun.ps1"
		out="$(pwsh -NoProfile -File "${tmpDir}/rerun.ps1" 2>&1 </dev/null || true)"
		[[ "${out}" == *"file=False & ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1)))"* ]] \
			|| fBad "install.ps1's uninstall hint under the one-liner: ${out@Q}"
		[[ "${out}" == *"file=True & 'C:\x\install.ps1'"* ]] || fBad "install.ps1's uninstall hint from a file: ${out@Q}"
		grep -qF '& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1)))' "${repoDir}/README.md" \
			|| fBad "the README no longer documents the one-liner install.ps1 names"
	fi
else
	fTestSkipBlock
fi

fTest EomZie0 flame-report-names-a-missing-dir
##	The profiler stage's hot-spot report. Its only diagnostics go to stderr, and
##	the stage used to discard them, so the log recorded the failure with no cause.
report="${repoDir}/cicd/utility/flame-report.py"
if [[ -f "${report}" ]]; then
	out="$(python3 "${report}" --dir "${tmpDir}/no-such-profile-dir" 2>&1 || true)"
	[[ "${out}" == *"no profiling dir"* ]] || fBad "flame-report.py says nothing usable about a missing directory: ${out}"
	if grep -qE 'flame-report\.py[^|]*2>/dev/null' "${repoDir}/cicd/cicd.bash"; then
		fBad "cicd.bash discards the hot-spot report's stderr, which is its only diagnostic"
	fi
fi

##	Every tracked shell script, whether or not it is named `*.bash`: the
##	pre-push hook and the publish script have no extension, and both are
##	`set -e` scripts the scans below are about. Untracked-but-not-ignored files
##	are in, so a script written and not yet added is still scanned; build output
##	is out, because it is ignored. Built once, since it reads the start of every
##	file in the tree. Read with builtins: a head and a grep per file were most
##	of this script's time. Two bytes first, so a binary is never read as a line.
fShellFiles(){
	local f magic line
	while IFS= read -r f; do
		case "${f}" in
			*.bash) printf '%s\n' "${repoDir}/${f}" ;;
			*)
				[[ -f "${repoDir}/${f}" ]] || continue
				magic=""; IFS= read -r -n 2 magic <"${repoDir}/${f}" || true
				[[ "${magic}" == '#!' ]] || continue
				line=""; IFS= read -r line <"${repoDir}/${f}" || true
				if [[ "${line}" =~ [^[:alnum:]_](bash|sh)([^[:alnum:]_]|$) ]]; then printf '%s\n' "${repoDir}/${f}"; fi
				;;
		esac
	done < <(git -C "${repoDir}" ls-files --cached --others --exclude-standard | sort -u)
}
mapfile -t shellFileList < <(fShellFiles)

##	The two static scans, as functions so the self-test below can run them over a
##	file holding every spelling they are meant to catch. Both were written for
##	one spelling each and missed the ordinary ones.
##
##	`\t` in a grep -E pattern: POSIX ERE has no such escape, so the pattern
##	matches nothing under the grep a script gets, while matching fine under the
##	interactive one on this box. Either quote style, either option spelling.
fScanTabEre(){
	grep -nE "grep [^|;]*(-[A-Za-z]*E[A-Za-z]*|--extended-regexp)[^|;]*['\"][^'\"]*\\\\t" "$1" || true
}

##	A `grep` inside an assigned command substitution with no `|| true`: when it
##	matches nothing the assignment fails, errexit kills the script, and the
##	check that would have printed the reason never runs. Every way to write an
##	assignment counts - a keyword prefix, an array element, `+=`, backticks.
##	Line continuations are joined first, so a substitution that ends in
##	`|| true` several lines down is read as guarded.
fScanUnguardedGrep(){
	sed -e :a -e '/\\$/N; s/\\\n//; ta' "$1" \
		| grep -nE '^[[:space:]]*(local|declare|typeset|export|readonly)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=.*(\$\(|`).*\bgrep\b' \
		| grep -vE '\|\|[[:space:]]*(true|:)' || true
}

fTest EqL3ERV fhave-strict-and-skip
##	The self-test: one file with every spelling, so a scan that stops seeing
##	one of them fails here rather than going quiet over the repo.
##	The strict switch itself: under the gate a missing tool has to be a failure,
##	or a runner that loses one reports OK forever. Locally it stays a skip.
{
	## The tool is missing on purpose, so neither probe may note it in the list
	## of the run this is part of: that would hold back the run's own record.
	runSkips="${SHCL_GATE_SKIPS:-}"
	strictBad=0
	( SHCL_GATE_STRICT=1; SHCL_GATE_SKIPS=/dev/null; fBad(){ exit 7 ;}; fHave definitely-not-a-tool ) 2>/dev/null || strictBad=$?
	((strictBad == 7)) || fBad "fHave did not fail on a missing tool under the gate"
	laxBad=0
	( unset SHCL_GATE_STRICT; SHCL_GATE_SKIPS=/dev/null; fBad(){ exit 7 ;}; fHave definitely-not-a-tool ) 2>/dev/null || laxBad=$?
	((laxBad == 1)) || fBad "fHave did not skip a missing tool outside the gate (exit ${laxBad})"
	## A skip nobody notes lets the run record its tree, and the pre-push hook
	## then waves through a commit whose gate never ran that row.
	: > "${tmpDir}/skips"
	( unset SHCL_GATE_STRICT; SHCL_GATE_SKIPS="${tmpDir}/skips"; fBad(){ exit 7 ;}; fHave definitely-not-a-tool ) 2>/dev/null || true
	grep -qx definitely-not-a-tool "${tmpDir}/skips" || fBad "fHave skipped a missing tool without noting it in SHCL_GATE_SKIPS"
	[[ -z "${runSkips}" ]] || ! grep -qx definitely-not-a-tool "${runSkips}" \
		|| fBad "the fHave self-test noted its made-up tool in the run's own skip list"
	## 20260918b item 43: the same three answers for a missing file, and the
	## local skip says so, since a skip nobody sees is what the item was.
	strictBad=0
	( SHCL_GATE_STRICT=1; SHCL_GATE_SKIPS=/dev/null; fBad(){ exit 7 ;}; fHaveFile "${tmpDir}/no-such-file" made-up-package ) 2>/dev/null || strictBad=$?
	((strictBad == 7)) || fBad "fHaveFile did not fail on a missing file under the gate"
	laxBad=0
	laxOut="$( ( unset SHCL_GATE_STRICT; SHCL_GATE_SKIPS="${tmpDir}/skips"; fBad(){ exit 7 ;}; fHaveFile "${tmpDir}/no-such-file" made-up-package ) 2>&1)" || laxBad=$?
	((laxBad == 1)) || fBad "fHaveFile did not skip a missing file outside the gate (exit ${laxBad})"
	[[ "${laxOut}" == *"skipping the made-up-package rows"* ]] || fBad "fHaveFile skipped a missing file with nothing said: ${laxOut@Q}"
	grep -qx made-up-package "${tmpDir}/skips" || fBad "fHaveFile skipped a missing file without noting it in SHCL_GATE_SKIPS"
}

fTest EomZie1 static-scan-self-test
##	The escape is assembled rather than written, so the bait for the second scan
##	does not trip that scan when it sweeps this file.
bs=$'\\'
#  shellcheck disable=2016  ## the bait is the literal text of the shapes being scanned for.
{
	printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
		'local x="$(grep -c a f)"' 'declare y="$(grep -c a f)"' 'export Z="$(grep -c a f)"' \
		'readonly W="$(grep -c a f)"' 'arr[0]="$(grep -c a f)"' 'acc+="$(grep -c a f)"' \
		'bt="`grep -c a f`"' 'ok="$(grep -c a f || true)"' \
		"grep --extended-regexp \"x${bs}ty\" f" "grep -E 'a${bs}tb' f" 'grep -E "[[:space:]]" f'
} > "${tmpDir}/scanbait.bash"
n="$(fScanUnguardedGrep "${tmpDir}/scanbait.bash" | wc -l)"
((n == 7)) || fBad "the unguarded-grep scan found ${n} of 7 spellings"
n="$(fScanTabEre "${tmpDir}/scanbait.bash" | wc -l)"
((n == 2)) || fBad "the backslash-t scan found ${n} of 2 spellings"

fTest EpFAzfl funnel-scan
##	The parser's lost count and its dead-level push have one home, the funnel
##	(`refuse` in each binding). An arm that counted or pushed by hand is the
##	shape nine review items took, one arm at a time, so no arm may. The scan
##	lifts the funnel by its first line and the next function start, wants
##	every increment and dead push inside it, and allows three outside: the
##	merge's, which sums a layer's count into the base, migrate's `st.lost`,
##	which counts 2.x bindings in a text rewrite and never reaches a document,
##	and the emitter's `tail`, its model of the stack a reload will build,
##	which pushes where that reload's funnel will.
##	The patterns ride the environment: awk's -v unescapes its value, so `\(`
##	would reach the regex as a bare `(`.
fScanFunnel(){   ## fScanFunnel FILE FUNNEL-REGEX NEXT-FN-REGEX WRITE-REGEX -> "inside outside"
	fn="$2" nx="$3" wr="$4" awk '
		$0 ~ ENVIRON["fn"] { in_fn = 1; next }
		in_fn && $0 ~ ENVIRON["nx"] { in_fn = 0 }
		$0 ~ ENVIRON["wr"] && $0 !~ /(over|st)(\.|->)_?lost/ && $0 !~ /tail/ { if (in_fn) ni++; else { no++; print FILENAME ":" NR ": " $0 > "/dev/stderr" } }
		END { print ni + 0, no + 0 }
	' "$1"
}
fCheckFunnel(){  ## fCheckFunnel LABEL FILE FUNNEL-REGEX NEXT-FN-REGEX WRITE-REGEX
	local counts
	counts="$(fScanFunnel "$2" "$3" "$4" "$5" 2>&1 || echo "scan failed 0 0")"
	local inside="${counts##*$'\n'}"; inside="${inside%% *}"
	local outside="${counts##* }"
	((inside >= 2)) || fBad "$1: the funnel holds ${inside} of the two writes (scan blind?)"
	((outside == 0)) || fBad "$1: ${outside} lost-count or dead-level write(s) outside the funnel:"$'\n'"${counts%$'\n'*}"
}
fCheckFunnel rust   "${repoDir}/source/rust/src/lib.rs"  '^\tfn refuse\('              '^\tfn |^}'          'lost \+=|lost\+=|DEAD\)\)'
fCheckFunnel go     "${repoDir}/source/go/shcl.go"       '^func \(p \*parser\) refuse\(' '^func '            'lost\+\+|lost \+=|node: dead}'
fCheckFunnel python "${repoDir}/source/python/shcl.py"   '^\tdef _refuse\('            '^\tdef |^class |^def ' 'lost \+=|, DEAD\)\)'
fCheckFunnel c      "${repoDir}/source/c/shcl.h"         '^static void p_refuse\('      '^static |^}'         'lost\+\+|lost \+=|node = DEAD'
##	Bait: a funnel holding both writes, a model push past it, and one stray
##	increment past it.
{
	printf '%s\n' 'static void p_refuse(void) {' '	P->d->lost += n;' '	se.node = DEAD;' '}' \
		'static void other(void) {' '	d->lost += over->lost;' '	se.node = DEAD; push(&e->tail, se);' '	P->d->lost++;' '}'
} > "${tmpDir}/funnelbait.h"
counts="$(fScanFunnel "${tmpDir}/funnelbait.h" '^static void p_refuse\(' '^static |^}' 'lost\+\+|lost \+=|node = DEAD' 2>/dev/null)"
[[ "$counts" == "2 1" ]] || fBad "the funnel scan counted '${counts}' on the bait, wanted '2 1'"

fTest EpFkZy6 tokenizer-scan
##	The tokenizer is the one place the lexical rules live, so no binding may
##	have a second quote state machine. The scan lifts each binding's
##	tokenizer section by its header and refuses a quote-state variable or the
##	close-finder anywhere outside it; inside it wants at least two hits, or
##	the scan is blind.
fScanTokenizer(){   ## fScanTokenizer FILE START-REGEX END-REGEX STATE-REGEX -> "inside outside"
	st="$2" en="$3" qs="$4" awk '
		$0 ~ ENVIRON["st"] { in_sec = 1; next }
		in_sec && $0 ~ ENVIRON["en"] { in_sec = 0 }
		$0 ~ ENVIRON["qs"] { if (in_sec) ni++; else { no++; print FILENAME ":" NR ": " $0 > "/dev/stderr" } }
		END { print ni + 0, no + 0 }
	' "$1"
}
fCheckTokenizer(){  ## fCheckTokenizer LABEL FILE START-REGEX END-REGEX STATE-REGEX
	local counts
	counts="$(fScanTokenizer "$2" "$3" "$4" "$5" 2>&1 || echo "scan failed 0 0")"
	local inside="${counts##*$'\n'}"; inside="${inside%% *}"
	local outside="${counts##* }"
	((inside >= 2)) || fBad "$1: the tokenizer section holds ${inside} quote-state site(s) (scan blind?)"
	((outside == 0)) || fBad "$1: ${outside} quote state machine(s) outside the tokenizer:"$'\n'"${counts%$'\n'*}"
}
tokState='in_quote|inQuote|in_q\b|quote_close\(|quoteClose\('
fCheckTokenizer rust   "${repoDir}/source/rust/src/lib.rs" 'Tokenizer - the one place the lexical rules live' '^// Path scanner' "${tokState}"
fCheckTokenizer go     "${repoDir}/source/go/shcl.go"      'Tokenizer - the one place the lexical rules live' '^// Path scanner' "${tokState}"
fCheckTokenizer python "${repoDir}/source/python/shcl.py"  'Tokenizer - the one place the lexical rules live' '^# Path scanner'  "${tokState}"
fCheckTokenizer c      "${repoDir}/source/c/shcl.h"        'Tokenizer - the one place the lexical rules live' 'Path scanner'     "${tokState}"
##	Bait: a tokenizer holding two sites and one quote loop past it.
{
	printf '%s\n' '// Tokenizer - the one place the lexical rules live' 'let c = quote_close(s, 0);' 'let d = quote_close(s, 1);' \
		'// Path scanner' 'let mut in_quote = None;'
} > "${tmpDir}/tokbait.rs"
counts="$(fScanTokenizer "${tmpDir}/tokbait.rs" 'Tokenizer - the one place the lexical rules live' '^// Path scanner' "${tokState}" 2>/dev/null)"
[[ "$counts" == "2 1" ]] || fBad "the tokenizer scan counted '${counts}' on the bait, wanted '2 1'"

fTest EoXOPYu no-failed-test-loop-bodies
##	A one-line loop body that is a `[[ ... ]] && ...` list. When the test fails
##	on the last iteration the loop returns 1, which is harmless at statement
##	level on this bash but kills the caller the moment the loop becomes the last
##	command in a function. Unmatched globs are the usual way in. `|| continue`
##	or an `if` is the fix.
while IFS= read -r f; do
	grep -qE '^set -[A-Za-z]*e' "${f}" || continue
	hits="$(grep -nE 'do[[:space:]]+\[\[[^]]*\]\][[:space:]]*&&[^;]*;[[:space:]]*done' "${f}" || true)"
	if [[ -n "${hits}" ]]; then
		while IFS= read -r h; do fBad "${f#"${repoDir}/"}: loop body ends on a failed-test && list: ${h}"; done <<<"${hits}"
	fi
done < <(printf '%s\n' "${shellFileList[@]}")

fTest EoXYMt8 no-tab-escape-in-ere
##	`\t` in a grep -E pattern. POSIX ERE has no such escape, so the pattern
##	matches nothing under the grep a script gets, while matching fine under the
##	interactive one on this box - a check that looks like it works and asserts
##	nothing. Twice in one round. Use a literal tab or `[[:space:]]`.
while IFS= read -r f; do
	hits="$(fScanTabEre "${f}")"
	if [[ -n "${hits}" ]]; then
		while IFS= read -r h; do fBad "${f#"${repoDir}/"}: backslash-t in a grep -E pattern, which POSIX ERE does not read as a tab: ${h}"; done <<<"${hits}"
	fi
done < <(printf '%s\n' "${shellFileList[@]}")

fTest EoTJb0N no-unguarded-grep
##	The static half. Line continuations are joined first, so a substitution that
##	ends in `|| true` several lines down is read as guarded.
while IFS= read -r f; do
	grep -qE '^set -[A-Za-z]*e' "${f}" || continue
	hits="$(fScanUnguardedGrep "${f}")"
	if [[ -n "${hits}" ]]; then
		while IFS= read -r h; do fBad "${f#"${repoDir}/"}: unguarded grep in an assigned substitution: ${h}"; done <<<"${hits}"
	fi
done < <(printf '%s\n' "${shellFileList[@]}")

fTest EqL3sFE 20260918b-44-shellcheck-list-complete
##	20260918b item 44: green-tree.bash went in with no line in the shellcheck
##	list, and nothing noticed. The list is compared with the shell files the
##	scans above walk, both ways, so a new script cannot miss the lint stage and
##	a renamed one cannot leave a dead entry.
# shellcheck source=/dev/null
scTargets="$( ( set +u; source "${repoDir}/cicd/config.bash"; printf '%s\n' "${SHELLCHECK_TARGETS[@]}" ) | LC_ALL=C sort -u)"
shFiles="$(while IFS= read -r f; do printf '%s\n' "${f#"${repoDir}/"}"; done < <(printf '%s\n' "${shellFileList[@]}") | LC_ALL=C sort -u)"
while IFS= read -r f; do
	if [[ -n "${f}" ]]; then fBad "${f}: a shell script the lint stage does not shellcheck; add it to SHELLCHECK_TARGETS"; fi
done < <(LC_ALL=C comm -23 <(printf '%s\n' "${shFiles}") <(printf '%s\n' "${scTargets}"))
while IFS= read -r f; do
	if [[ -n "${f}" ]]; then fBad "${f}: in SHELLCHECK_TARGETS and not a tracked shell script"; fi
done < <(LC_ALL=C comm -13 <(printf '%s\n' "${shFiles}") <(printf '%s\n' "${scTargets}"))
((${#shFiles} > 0 && ${#scTargets} > 0)) || fBad "the shellcheck list comparison read an empty side"

fTest EqRQpEn 20260920-idea5-powershell-lint-list
##	20260920 idea 5: the list above is derived and its two siblings were not, so
##	a new `.ps1` or `.py` would be linted by nothing and no gate would say so.
##	The same comparison, once per kind.
# shellcheck source=/dev/null
lintExtra="$( set +u; source "${repoDir}/cicd/config.bash"; printf '%s\n' "${LINT_EXTRA[@]}" )"

##	PowerShell: one PSScriptAnalyzer line per tracked file, both ways.
psTargets="$(grep -oE 'Invoke-ScriptAnalyzer -Path [^ ]+' <<<"${lintExtra}" | awk '{print $3}' | LC_ALL=C sort -u || true)"
psFiles="$(git -C "${repoDir}" ls-files --cached --others --exclude-standard -- '*.ps1' | LC_ALL=C sort -u)"
while IFS= read -r f; do
	if [[ -n "${f}" ]]; then fBad "${f}: a PowerShell script the lint stage does not analyze; add a line to LINT_EXTRA"; fi
done < <(LC_ALL=C comm -23 <(printf '%s\n' "${psFiles}") <(printf '%s\n' "${psTargets}"))
while IFS= read -r f; do
	if [[ -n "${f}" ]]; then fBad "${f}: analyzed by LINT_EXTRA and not a tracked PowerShell script"; fi
done < <(LC_ALL=C comm -13 <(printf '%s\n' "${psFiles}") <(printf '%s\n' "${psTargets}"))
((${#psFiles} > 0 && ${#psTargets} > 0)) || fBad "the PowerShell list comparison read an empty side"

fTest EqRQpEo 20260920-idea5-python-lint-lists
##	Python has two lists. The binding's own files are named in its project file,
##	which is what mypy reads; ruff there is pointed at the whole directory, so it
##	needs no list. Everything else is on the pipeline's own ruff line.
pyMypy="$(sed -n 's/^files = \[\(.*\)\]$/\1/p' "${repoDir}/source/python/pyproject.toml" \
	| tr ',' '\n' | tr -d ' "' | sed '/^$/d' | sed 's|^|source/python/|' | LC_ALL=C sort -u)"
pyRuffLine="$(grep -F 'ruff check' <<<"${lintExtra}" | grep -vF 'cd source/python' || true)"
pyRuff="$(grep -oE '[^ ]+\.py' <<<"${pyRuffLine}" | LC_ALL=C sort -u || true)"
pyTargets="$(printf '%s\n%s\n' "${pyMypy}" "${pyRuff}" | sed '/^$/d' | LC_ALL=C sort -u)"
pyFiles="$(git -C "${repoDir}" ls-files --cached --others --exclude-standard -- '*.py' | LC_ALL=C sort -u)"
while IFS= read -r f; do
	if [[ -n "${f}" ]]; then fBad "${f}: a Python file no lint list names; add it to the pipeline's ruff line or to source/python/pyproject.toml"; fi
done < <(LC_ALL=C comm -23 <(printf '%s\n' "${pyFiles}") <(printf '%s\n' "${pyTargets}"))
while IFS= read -r f; do
	if [[ -n "${f}" ]]; then fBad "${f}: named by a lint list and not a tracked Python file"; fi
done < <(LC_ALL=C comm -13 <(printf '%s\n' "${pyFiles}") <(printf '%s\n' "${pyTargets}"))
((${#pyMypy} > 0 && ${#pyRuff} > 0)) || fBad "the Python list comparison read an empty side"

fTest Eoltu24 20260902-18-split-tabs-keeps-empty-fields
##	20260902 item 18: the two corpus replays split a reads.tsv row with
##	`IFS=$'\t' read`, which drops a leading or doubled tab because tab is IFS
##	whitespace whatever IFS is set to - so the top-level `children` row arrived
##	as a type nothing had an arm for and ran nothing. Lifted out of
##	crosscheck.bash by name so the check cannot drift from the shipped text.
eval "$(sed -n '/^fSplitTabs()/,/^}/p' "${repoDir}/cicd/utility/crosscheck.bash")"
cols=()
fSplitTabs "$(printf '\tchildren\tdb|web\t-')"
[[ "${#cols[@]}" == 4 && -z "${cols[0]}" && "${cols[1]}" == "children" ]] \
	|| fBad "fSplitTabs dropped a leading empty field: ${cols[*]@Q}"
fSplitTabs "$(printf 'nope\tchildren\t\t-')"
[[ "${#cols[@]}" == 4 && "${cols[2]}" == "" && "${cols[3]}" == "-" ]] \
	|| fBad "fSplitTabs dropped a middle empty field: ${cols[*]@Q}"
fSplitTabs "one"
[[ "${#cols[@]}" == 1 && "${cols[0]}" == "one" ]] || fBad "fSplitTabs mangled a single field: ${cols[*]@Q}"

fTest Eols8ls 20260902-17-float-generator
##	20260902 item 17: the crosscheck's float-spelling dimension built its powers
##	of two as `2 ^ e`, which gawk computes as 1/(2^1074) for a subnormal - so 52
##	of its rows were the value zero and tested nothing - and drew its "fixed"
##	random set from srand()/rand(), whose sequence differs between awks. The
##	shipped generator is lifted out of crosscheck.bash by name so the check
##	cannot drift from it. It sits inside a function, so the indent is allowed for.
gen="$(sed -n "/^[[:space:]]*awk 'BEGIN{/,/^[[:space:]]*}' > /p" "${repoDir}/cicd/utility/crosscheck.bash" | sed "1s/^[[:space:]]*awk '//; \$s/}' > .*/}/")"
[[ -n "${gen}" ]] || fBad "could not lift the float generator out of crosscheck.bash"
printf '%s
' "${gen}" > "${tmpDir}/floats.awk"
first=""
for a in gawk mawk "busybox awk" awk; do
	read -r -a acmd <<<"${a}"
	command -v "${acmd[0]}" > /dev/null 2>&1 || continue
	"${acmd[@]}" -f "${tmpDir}/floats.awk" > "${tmpDir}/floats.out" 2>/dev/null || { fBad "float generator failed under ${a}"; continue; }
	zeros="$(grep -cE $'^float	p[0-9]+	-?0$' "${tmpDir}/floats.out" || true)"
	((zeros == 0)) || fBad "float generator wrote ${zeros} zero-valued power row(s) under ${a}"
	sum="$(sha256sum < "${tmpDir}/floats.out")"
	if [[ -z "${first}" ]]; then first="${sum}"
	elif [[ "${sum}" != "${first}" ]]; then fBad "float generator differs under ${a}"; fi
done
[[ -n "${first}" ]] || fBad "no awk found to run the float generator"

fTest EqzuifK crosscheck-failure-paths
##	The crosscheck's own failure paths, which a real run reaches only on the day
##	two bindings disagree. Stub CLIs answer every call with its words, paths cut
##	to the base name since each binding writes under its own root, and the
##	stub's file name picks the one place it breaks. 20260726 item 4: a second
##	divergence and the summary were lost to the diff pipeline's status.
##	20260716 items 15, 16 and 27: a dropped final newline compared equal, a run
##	with too few comparisons passed, and a last reads.tsv row with no newline
##	after it was never read. The usage block always compares, so an empty
##	corpus has a check of its own.
xcDir="${tmpDir}/xc"
mkdir -p "${xcDir}/corpus/001-a" "${xcDir}/empty" "${xcDir}/nodump"
cat > "${xcDir}/ref" <<'EOF'
#!/usr/bin/env bash
line=""; for a in "$@"; do line+="${a##*/} "; done
case "${0##*/}:${line}" in
	two:version\ |two:about\ ) echo "other" ;;
	abrt:version\ ) echo "Fatal Python error: stub abort" >&2; exit 134 ;;
	abrt:about\ ) echo "stub about refused" >&2; exit 3 ;;
	nonl:version\ ) printf '%s' "${line}" ;;
	tsv:count\ *zz\ ) echo "other" ;;
	crlf:set\ --write\ c.shcl\ ) sed 's/$/\r/' >>"${@: -1}" ;;
	*:set\ --write\ c.shcl\ ) cat >>"${@: -1}" ;;
	*) printf '%s\n' "${line}" ;;
esac
EOF
chmod +x "${xcDir}/ref"
for m in two nonl tsv crlf abrt; do cp "${xcDir}/ref" "${xcDir}/${m}"; done
printf 'a: 1\n' > "${xcDir}/corpus/001-a/input.shcl"
printf 'query\ttype\texpected\tstatus\na\tint\t1\tok\nzz\tcount\t0\tok' > "${xcDir}/corpus/001-a/reads.tsv"
## The run's strict flag and skip list stay out, since these dumps leave out
## folders on purpose; a row that wants either sets it in xcEnv.
xcEnv=()
fCrosscheck(){  ## fCrosscheck ARGS...: crosscheck's stdout and stderr in xcOut, its exit in xcRc
	xcRc=0
	xcOut="$(cd "${repoDir}" && env -u SHCL_GATE_STRICT SHCL_GATE_SKIPS=/dev/null CPU_CAP=2 ${xcEnv[@]+"${xcEnv[@]}"} bash cicd/utility/crosscheck.bash "$@" 2>&1)" || xcRc=$?
}
fCrosscheck --corpus "${xcDir}/corpus" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 0 && "${xcOut}" == *"bindings agree on"* ]] || fBad "crosscheck self-test: two identical stubs did not agree (exit ${xcRc}): ${xcOut@Q}"
fCrosscheck --corpus "${xcDir}/corpus" "ref|${xcDir}/ref" "two|${xcDir}/two"
[[ "${xcRc}" == 1 && "${xcOut}" == *"DIVERGE usage version:"* && "${xcOut}" == *"DIVERGE usage about:"* \
	&& "${xcOut}" =~ crosscheck:\ 2/[0-9]+\ comparison ]] \
	|| fBad "crosscheck did not report both divergences and the count (exit ${xcRc}): ${xcOut@Q}"
fCrosscheck --corpus "${xcDir}/corpus" "ref|${xcDir}/ref" "nonl|${xcDir}/nonl"
[[ "${xcRc}" == 1 && "${xcOut}" == *"DIVERGE usage version:"* ]] || fBad "crosscheck missed a dropped final newline (exit ${xcRc})"
fCrosscheck --corpus "${xcDir}/corpus" "ref|${xcDir}/ref" "tsv|${xcDir}/tsv"
[[ "${xcRc}" == 1 && "${xcOut}" == *"DIVERGE count zz:"* ]] || fBad "crosscheck skipped a last reads.tsv row with no final newline (exit ${xcRc})"
fTest EqzuifL 20260920-idea4-crosscheck-needs-input
##	20260920 idea 4: a case directory with no input.shcl was skipped without a
##	word, so it looked present and asserted nothing.
mkdir -p "${xcDir}/noinput/002-b"
cp -r "${xcDir}/corpus/001-a" "${xcDir}/noinput/"
cp "${xcDir}/corpus/001-a/reads.tsv" "${xcDir}/noinput/002-b/"
fCrosscheck --corpus "${xcDir}/noinput" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 && "${xcOut}" == *"002-b/ has no input.shcl"* ]] || fBad "crosscheck skipped a case directory with no input.shcl (exit ${xcRc}): ${xcOut@Q}"
fCrosscheck --corpus "${xcDir}/empty" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 && "${xcOut}" == *"no case directories"* ]] || fBad "crosscheck took an empty corpus (exit ${xcRc})"
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/nodump" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 ]] || fBad "crosscheck took an --extra directory with no *.shcl (exit ${xcRc})"
fCrosscheck --corpus "${xcDir}/corpus" --min 1000000 "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 && "${xcOut}" == *"need at least 1000000"* ]] || fBad "crosscheck passed below its --min floor (exit ${xcRc})"
fTest ErUF4pC 2026100114175701-crosscheck-eol-keep-saves
##	2026100114175701: the dump's eol/ inputs go through each binding's keep
##	save with their ops on stdin, and the bytes on disk are compared, CRs and
##	all. An input with no ops, or an eol/ with no input, is a broken dump.
mkdir -p "${xcDir}/eoldump/eol"
printf 'a: 1\n' > "${xcDir}/eoldump/fuzz_00000.shcl"
printf 'a :  1 \r\nb :  2 \n' > "${xcDir}/eoldump/eol/00000.shcl"
printf 'int\tz0\t7\n' > "${xcDir}/eoldump/eol/00000.ops"
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/eoldump" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 0 && "${xcOut}" == *"ok   ErUF4nK "* ]] || fBad "crosscheck: two identical keep saves did not agree (exit ${xcRc}): ${xcOut@Q}"
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/eoldump" "ref|${xcDir}/ref" "crlf|${xcDir}/crlf"
[[ "${xcRc}" == 1 && "${xcOut}" == *"DIVERGE keep save 00000.shcl: crlf vs ref"* && "${xcOut}" == *"FAIL ErUF4nK "* ]] \
	|| fBad "crosscheck missed a keep save that ends its lines in CRLF (exit ${xcRc}): ${xcOut@Q}"
mkdir -p "${xcDir}/eolnoops/eol"
cp "${xcDir}/eoldump/fuzz_00000.shcl" "${xcDir}/eolnoops/"
cp "${xcDir}/eoldump/eol/00000.shcl" "${xcDir}/eolnoops/eol/"
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/eolnoops" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 && "${xcOut}" == *"has no .ops beside it"* ]] || fBad "crosscheck took an eol/ input with no ops (exit ${xcRc}): ${xcOut@Q}"
mkdir -p "${xcDir}/eolempty/eol"
cp "${xcDir}/eoldump/fuzz_00000.shcl" "${xcDir}/eolempty/"
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/eolempty" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 && "${xcOut}" == *"empty keep-save dump"* ]] || fBad "crosscheck took an empty eol/ (exit ${xcRc})"
fTest Erkag5x 2026100307163912-crosscheck-dump-folder-missing
##	2026100307163912: a dump with no eol/ folder turned the keep-save replay
##	off without a word, strict or not.
mkdir -p "${xcDir}/noeol/kept"
cp "${xcDir}/eoldump/fuzz_00000.shcl" "${xcDir}/noeol/"
cp "${xcDir}/eoldump/eol/00000.shcl" "${xcDir}/eoldump/eol/00000.ops" "${xcDir}/noeol/kept/"
xcEnv=(SHCL_GATE_STRICT=1)
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/noeol" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 2 && "${xcOut}" == *"has no eol/ folder"* ]] || fBad "a strict crosscheck took a dump with no eol/ (exit ${xcRc}): ${xcOut@Q}"
: > "${xcDir}/skips"
xcEnv=(SHCL_GATE_SKIPS="${xcDir}/skips")
fCrosscheck --corpus "${xcDir}/corpus" --extra "${xcDir}/noeol" "ref|${xcDir}/ref" "other|${xcDir}/ref"
[[ "${xcRc}" == 0 && "${xcOut}" == *"skip ErUF4nK "* && "${xcOut}" == *"ok   EreXO4J "* && "$(cat "${xcDir}/skips")" == "crosscheck eol" ]] \
	|| fBad "crosscheck did not note a dump with no eol/ as a skip (exit ${xcRc}, skips $(cat "${xcDir}/skips")): ${xcOut@Q}"
xcEnv=()
fTest Ern198f 2026100313174976-crosscheck-shows-a-crash
##	2026100313174976: a Python CLI killed by SIGABRT under load showed only as
##	exit 134 in the diff, and its stderr was thrown away. The stub exits 134
##	rather than raising the signal, since crosscheck sees only the status and a
##	real abort would leave a core behind on every run.
fCrosscheck --corpus "${xcDir}/corpus" "ref|${xcDir}/ref" "abrt|${xcDir}/abrt"
[[ "${xcRc}" == 1 && "${xcOut}" == *"abrt was killed by signal 6 (SIGABRT, exit 134)"* && "${xcOut}" == *"| Fatal Python error: stub abort"* \
	&& "${xcOut}" == *"| stub about refused"* ]] || fBad "crosscheck did not show a crashed binding's signal and stderr (exit ${xcRc}): ${xcOut@Q}"
fCrosscheck --corpus "${xcDir}/corpus" "ref|${xcDir}/ref" "two|${xcDir}/two"
[[ "${xcRc}" == 1 && "${xcOut}" != *"stderr:"* && "${xcOut}" != *"killed by signal"* ]] || fBad "crosscheck showed stderr or a signal for a binding that had neither (exit ${xcRc}): ${xcOut@Q}"

fTestEnd

if ((nBad)); then
	echo "shell-regress: ${nBad} check(s) failed" >&2
	exit 1
fi
echo "shell-regress: OK: wrappers, one-liner scope, packaging, installers, comparison worker, and no unguarded greps, failed-test loop bodies or tab escapes in an ERE"

##	History:
##		2026-08-30  Created, pinning the wrapper and installer defects from the
##		            20260829 and 20260830 rounds.
##		2026-09-19  Clears git's local environment at the top.
##		2026-09-19  fHaveFile, and a scan for a list grown only when a tool or file
##		            is here. The lint-report rows cover an unfinished run.
##		2026-09-19  The shellcheck list is compared with the tracked shell files.
##		2026-09-19  check-pins: an empty pip family, and a pip line read blind.
##		2026-09-20  The PowerShell and Python lint lists get the same comparison.
