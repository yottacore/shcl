#!/usr/bin/env bash

##	Purpose:
##		Keep the shell completions in step with the CLI. Both completion files
##		carry the same per-subcommand option table the CLI validates against in
##		check_opts(), so an option added to one and not the others would offer a
##		completion the CLI rejects as a usage error - or hide a real one. This
##		diffs all three tables, and the top-level offers (subcommand words plus
##		the informational flags), and fails on any disagreement.
##	Syntax:
##		check-completions.bash [ROOT]
##		  ROOT   repo root (default: two levels up from this script)
##	Exit: 0 = the three tables agree, 1 = they do not.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd -- "${meDir}/../.." && pwd)}"
testWhere="check-completions"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"

mainRs="${root}/source/rust/src/main.rs"
compFiles=("${root}/source/completions/shcl.bash" "${root}/source/completions/_shcl")

for f in "${mainRs}" "${compFiles[@]}"; do
	[[ -f "${f}" ]] || { echo "check-completions: missing ${f}" >&2; exit 1; }
done

## The CLI's table, one arm per line: `get<TAB>--array --default ...`. The arm
## list is flattened to a single line first, then split on the `],` that ends
## each one - option names never contain a bracket, so nothing else can match.
fRustTable() {
	sed -n '/let allowed: &\[&str\] = match cmd {/,/^\t};$/p' "${mainRs}" \
	| tr '\n' ' ' | tr -s ' ' | sed 's/\], /]\n/g' \
	| while read -r arm; do
		[[ "${arm}" == *'=>'* && "${arm}" == *'"'* ]] || continue   ## skips the _ => &[] catch-all
		names="$(grep -o '"[a-z]*"' <<<"${arm%%=>*}" | tr -d '"' | paste -sd'|' || true)"
		opts="$(grep -o -- '--[a-z0-9<>-]*' <<<"${arm#*=>}" | sort -u | paste -sd' ' || true)"
		printf '%s\t%s\n' "${names}" "${opts}"
	done
}

## The same table out of a completion file. Both files spell it identically, so
## one extractor covers them.
fCompTable() {
	sed -n "s/^[[:space:]]*\([a-z|]\+\))[[:space:]]*echo '\([^']*\)'.*/\1\t\2/p" "$1" \
	| while IFS=$'\t' read -r names opts; do
		## An empty option list is a row, not a row to drop: the CLI side keeps
		## its arm either way, so dropping it here made an option-less
		## subcommand impossible for the two sides to ever agree on. The
		## completion's `*)` default arm is excluded by the pattern above, which
		## only matches subcommand words.
		printf '%s\t%s\n' "${names}" "$(tr ' ' '\n' <<<"${opts}" | sort -u | paste -sd' ')"
	done
}

## The CLI's top-level offer: the COMMANDS const plus everything asked_for()
## answers to - the informational words on the right of each arm and the flag
## spellings on the left.
fRustTop() {
	{
		## Whole declaration, not one line: rustfmt wraps the array once it
		## outgrows the line width, and a single-line grep then reads none of it.
		sed -n '/const COMMANDS/,/];/p' "${mainRs}" | grep -o '"[a-z]*"' || true
		sed -n '/fn asked_for/,/^}/p' "${mainRs}" | grep 'return Some(' \
		| while IFS= read -r arm; do
			grep -o '"[^"]*"' <<<"${arm%%=>*}" || true
			grep -o '"[a-z]*"' <<<"${arm#*=>}" || true
		done
	} | tr -d '"' | sort -u | paste -sd' '
}

## The CLI's value-taking options: the arms asked_for() steps over. Flattened
## first, since rustfmt puts one name per line.
fRustValOpts() {
	sed -n '/^fn asked_for/,/^}/p' "${mainRs}" | tr '\n\t' '  ' | tr -s ' ' \
	| { grep -oE '("--[a-z0-9-]+" [|] )*"--[a-z0-9-]+" => i [+]= 1' || true ;} \
	| { grep -o '"--[a-z0-9-]*"' || true ;} | tr -d '"' | sort -u | paste -sd' '
}

## The same list out of a completion file.
fCompValOpts() {
	sed -n "s/^_shcl_valopts='\([^']*\)'.*/\1/p" "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd' '
}

## The reference's dispatch arms, one name per line. Matched on the arm arrow
## rather than on indentation: `\t` is not an escape in POSIX ERE, so a pattern
## carrying one matches nothing under the grep a script gets.
fRustDispatch() {
	sed -n '/^fn run(cmd: &str, o: &Opts) -> u8 {/,/^}$/p' "${mainRs}" \
	| { grep -oE '"[a-z]+" =>' || true ;} | tr -d '">= ' | sort -u
}

## The bash completion's word-1 offer: the subcommand list plus the extra
## tokens on its compgen line.
fBashTop() {
	local subs extra
	subs="$(sed -n "s/^_shcl_subcommands='\([^']*\)'.*/\1/p" "$1")"
	extra="$(sed -n 's/.*compgen -W "\${_shcl_subcommands} \([^"]*\)".*/\1/p' "$1")"
	tr ' ' '\n' <<<"${subs} ${extra}" | sed '/^$/d' | sort -u | paste -sd' '
}

## The zsh completion's word-2 offer: the cmds array names plus its bare
## compadd of the informational flags.
fZshTop() {
	local subs extra
	subs="$(sed -n "s/^[[:space:]]*'\([a-z]*\):.*/\1/p" "$1")"
	extra="$(sed -n 's/^[[:space:]]*compadd -- \(-h .*\)$/\1/p' "$1")"
	tr ' ' '\n' <<<"${subs} ${extra}" | sed '/^$/d' | sort -u | paste -sd' '
}

fTest EnPQRbk option-tables-agree
rustTable="$(fRustTable)"
[[ -n "${rustTable}" ]] || { echo "check-completions: no option table found in ${mainRs}" >&2; exit 1; }

for cf in "${compFiles[@]}"; do
	compTable="$(fCompTable "${cf}")"
	if ! diff <(printf '%s\n' "${rustTable}") <(printf '%s\n' "${compTable}") >/dev/null; then
		echo "check-completions: $(basename "${cf}") disagrees with the CLI (< CLI, > completion):" >&2
		diff <(printf '%s\n' "${rustTable}") <(printf '%s\n' "${compTable}") >&2 || true
		nBad=$((nBad + 1))
	fi
done

fTest EoShutc top-level-offers-agree
rustTop="$(fRustTop)"
[[ -n "${rustTop}" ]] || { echo "check-completions: no top-level offer found in ${mainRs}" >&2; exit 1; }

for cf in "${compFiles[@]}"; do
	case "${cf}" in
		*/_shcl) compTop="$(fZshTop "${cf}")" ;;
		*)       compTop="$(fBashTop "${cf}")" ;;
	esac
	if [[ "${rustTop}" != "${compTop}" ]]; then
		echo "check-completions: $(basename "${cf}") top-level offer disagrees with the CLI:" >&2
		echo "  CLI:        ${rustTop}" >&2
		echo "  completion: ${compTop}" >&2
		nBad=$((nBad + 1))
	fi
done

fTest Ep11mJc value-options-agree
## The value-option lists: an option that takes a value and is missing here
## has its value counted as a positional, which eats the FILE slot.
rustVal="$(fRustValOpts)"
[[ -n "${rustVal}" ]] || { echo "check-completions: no value-option list found in ${mainRs}" >&2; exit 1; }
for cf in "${compFiles[@]}"; do
	compVal="$(fCompValOpts "${cf}")"
	if [[ "${rustVal}" != "${compVal}" ]]; then
		echo "check-completions: $(basename "${cf}") value-option list disagrees with the CLI:" >&2
		echo "  CLI:        ${rustVal}" >&2
		echo "  completion: ${compVal}" >&2
		nBad=$((nBad + 1))
	fi
done

fTest EoXNcum every-command-dispatches
## Every command the CLI accepts must have a dispatch arm of its own. One
## without used to fall through to whichever command the catch-all named - no
## compile error, no message.
rustCmds="$(sed -n '/const COMMANDS/,/];/p' "${mainRs}" | { grep -o '"[a-z]*"' || true ;} | tr -d '"' | sort -u)"
rustArms="$(fRustDispatch)"
if [[ "${rustCmds}" != "${rustArms}" ]]; then
	echo "check-completions: COMMANDS and the dispatch disagree:" >&2
	echo "  COMMANDS: $(paste -sd' ' <<<"${rustCmds}")" >&2
	echo "  dispatch: $(paste -sd' ' <<<"${rustArms}")" >&2
	nBad=$((nBad + 1))
fi

fTestEnd
rc=0
if [[ "${nBad}" != 0 ]]; then rc=1; fi
((rc)) || echo "check-completions: OK ($(wc -l <<<"${rustTable}") subcommands + top-level offer + value options + dispatch, ${#compFiles[@]} completion files)"
exit "${rc}"


##	Script history:
##		- 20260818: Created.
##		- 20260830: Also diff the top-level offers.
##		- 20260905: Also diff the value-option lists.
