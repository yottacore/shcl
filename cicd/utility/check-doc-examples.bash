#!/usr/bin/env bash

##	Purpose:
##		Run the examples the docs state a result for, through every binding's
##		CLI. The value syntax doc's and the spec's tables go through
##		doc-tables.py, which reads each table from the doc and holds every row
##		it can read to the result the row states. The man page's example blocks
##		run the way check-readme runs the README's: top to bottom in one
##		directory, with the CLI first on PATH as `shcl`, every command has to
##		succeed, the file left behind has to load clean, and the four bindings
##		have to print the same.
##
##		A corpus case's expected output is written by hand, which is what lets
##		it catch a defect all four bindings share. The doc tables are hand
##		written too, and before this nothing ran them.
##	Syntax:
##		check-doc-examples.bash NAME|CLI [NAME|CLI ...]
##	Exit: 0 = every example holds, 1 = one does not, 2 = usage or missing input.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

repoDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
testWhere="check-doc-examples"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "${repoDir}/cicd/utility/include/test-id.bash"
bindings=()
while (($#)); do case "$1" in
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         bindings+=("$1"); shift ;;
esac; done
((${#bindings[@]})) || { echo "check-doc-examples: no bindings given" >&2; exit 2; }
##	Absolute, since the man page's blocks run in a directory of their own.
for k in "${!bindings[@]}"; do
	b="${bindings[k]}"
	[[ -x "${b#*|}" ]] || { echo "check-doc-examples: binding CLI not executable: ${b#*|}" >&2; exit 2; }
	if [[ "${b#*|}" != /* ]]; then bindings[k]="${b%%|*}|${PWD}/${b#*|}"; fi
done
readme="${repoDir}/README.md"
manPage="${repoDir}/source/man/shcl.1"
[[ -f "${readme}" && -f "${manPage}" ]] || { echo "check-doc-examples: no README or man page" >&2; exit 2; }

fOnExit(){
	local rc=$?
	if [[ "${rc}" != 0 ]]; then nBad=$((nBad + 1)); fi
	fTestEnd
	rm -rf "${tmpDir}"
}
tmpDir="$(mktemp -d)"; trap fOnExit EXIT

##	The floors sit a little under what each doc has now, so a reader that stops
##	matching its table, or a table that loses its rows, fails rather than
##	checking less.
fTest EsJLUJx value-syntax-tables
python3 "${repoDir}/cicd/utility/doc-tables.py" "${repoDir}/project/design_docs/value-syntax.md" 50 "${bindings[@]}" || nBad=$((nBad + 1))
fTest EsJLUJy spec-tables
python3 "${repoDir}/cicd/utility/doc-tables.py" "${repoDir}/project/spec.md" 28 "${bindings[@]}" || nBad=$((nBad + 1))

##	The man page shows its examples in .nf blocks. Every block is either under
##	EXAMPLES, and runs, or under a section listed here as not shell.
fTest EsJLUJz man-examples
declare -A notShell=(["WRITE OPS"]="the ops script's grammar, one op per line")
blkDir="${tmpDir}/man"; mkdir -p "${blkDir}"
nBlk="$(awk -v dir="${blkDir}" '
	/^\.SH / { sec = substr($0, 5); gsub(/"/, "", sec); next }
	/^\.nf/ { n++; out = dir "/" n ".blk"; print sec > (dir "/" n ".sec"); close(dir "/" n ".sec"); printf "" > out; inb = 1; next }
	/^\.fi/ { if (inb) close(out); inb = 0; next }
	inb { print > out }
	END { print n + 0 }' "${manPage}")"
nRun=0
: > "${tmpDir}/man.sh"
for ((i = 1; i <= nBlk; i++)); do
	sec="$(cat "${blkDir}/${i}.sec")"
	if [[ -n "${notShell[${sec}]:-}" ]]; then continue; fi
	if [[ "${sec}" != EXAMPLES ]]; then
		echo "check-doc-examples: the man page has a .nf block under ${sec}; run it here or list the section as not shell" >&2
		nBad=$((nBad + 1)); continue
	fi
	##	Only \- is translated. Any other roff escape or request in a block would
	##	reach the shell as something the page does not show.
	if grep -nE '\\[^-]|^\.' "${blkDir}/${i}.blk" >&2; then
		echo "check-doc-examples: man page example block ${i} holds roff the gate does not translate (above)" >&2
		nBad=$((nBad + 1)); continue
	fi
	sed 's/\\-/-/g' "${blkDir}/${i}.blk" >> "${tmpDir}/man.sh"
	nRun=$((nRun + 1))
done
if ((nRun < 5)); then
	echo "check-doc-examples: only ${nRun} example block(s) found in the man page" >&2
	nBad=$((nBad + 1))
fi
##	The page names its files without showing them. server.shcl and the schema
##	are the README's, app.shcl passes that schema, and base.shcl under
##	site.shcl merges to a document that passes it too.
awk '/^## What a .shcl file looks like/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tmpDir}/server.shcl"
awk '/^Hand it a schema/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tmpDir}/app-schema.shcl"
[[ -s "${tmpDir}/server.shcl" && -s "${tmpDir}/app-schema.shcl" ]] \
	|| { echo "check-doc-examples: the README's server.shcl or schema block is gone" >&2; exit 2; }
if command -v jq >/dev/null 2>&1; then
	firstOut=""; manBad="${nBad}"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; dir="${tmpDir}/run-${name}"
		mkdir -p "${dir}/bin"
		ln -s "${b#*|}" "${dir}/bin/shcl"
		cp "${tmpDir}/server.shcl" "${tmpDir}/app-schema.shcl" "${dir}/"
		cp "${tmpDir}/app-schema.shcl" "${dir}/s.shcl"
		printf 'workers: 4\nlog-level: warn\n' > "${dir}/app.shcl"
		printf 'workers: 4\nlog-level: warn\n' > "${dir}/base.shcl"
		printf 'workers: 8\n' > "${dir}/site.shcl"
		{
			echo 'set -Eeo pipefail'
			# shellcheck disable=SC2016  ## expands in the generated script
			echo 'trap '\''echo "fails at: ${BASH_COMMAND}" >&2'\'' ERR'
			##	An installed shcl further down PATH would run the blocks just as
			##	well, and prove nothing about this one.
			echo "[[ \"\$(command -v shcl)\" == '${dir}/bin/shcl' && -x '${dir}/bin/shcl' ]] || { echo 'not the CLI under test' >&2; exit 1; }"
			cat "${tmpDir}/man.sh"
		} > "${dir}/run.bash"
		if ! ( cd "${dir}" && PATH="${dir}/bin:${PATH}" bash "${dir}/run.bash" ) > "${dir}/run.out" 2> "${dir}/run.err" </dev/null; then
			echo "check-doc-examples: [${name}] the man page's examples do not run:" >&2
			head -n 20 "${dir}/run.err" | sed 's/^/	/' >&2
			nBad=$((nBad + 1)); continue
		fi
		left="$("${b#*|}" check "${dir}/server.shcl" 2>&1 || true)"
		if [[ "${left}" != "ok (0 diagnostic(s))" ]]; then
			echo "check-doc-examples: [${name}] the man page's examples leave a server.shcl that does not load clean:" >&2
			printf '%s\n' "${left}" | sed 's/^/	/' >&2
			nBad=$((nBad + 1))
		fi
		if [[ -z "${firstOut}" ]]; then
			firstOut="${dir}/run.out"
		elif ! cmp -s "${firstOut}" "${dir}/run.out"; then
			echo "check-doc-examples: [${name}] the man page's examples print something other than ${bindings[0]%%|*} does:" >&2
			diff "${firstOut}" "${dir}/run.out" | head -n 20 | sed 's/^/	/' >&2 || true
			nBad=$((nBad + 1))
		fi
	done
	if [[ "${nBad}" == "${manBad}" ]]; then echo "check-doc-examples: the man page's ${nRun} example block(s) run on ${#bindings[@]} binding(s)"; fi
elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
	echo "check-doc-examples: no jq here, and the gate requires it" >&2
	nBad=$((nBad + 1))
else
	echo "check-doc-examples: skipping the man page's examples (no jq here)"
	echo check-doc-examples >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
fi
fTestEnd

if ((nBad)); then
	echo "check-doc-examples: ${nBad} check(s) failed" >&2
	exit 1
fi
echo "check-doc-examples: OK"

##	History:
##		2026-10-10  Created: the value syntax doc's and the spec's tables, and
##		            the man page's example blocks (2026100719122102).
