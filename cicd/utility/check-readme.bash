#!/usr/bin/env bash

##	Purpose:
##		Build the README's six code examples the way a reader would: each block
##		verbatim, wrapped in whatever a reader has to add around it, and built
##		with the line the README itself gives. The five that end in a save are
##		then run against the config file the README shows, and the file they
##		leave is compared with the block that says what the save does.
##
##		These are the first thing a consumer copies, and nothing else in the
##		pipeline builds them. The C one also has a build order that is easy
##		to "tidy" wrong: shcl.h asks for a POSIX level, a feature request only
##		counts before the first system header, and putting <stdio.h> above the
##		header turns the file tier into a wall of implicit declarations. The Go
##		one is unforgiving in a different way - an unused variable there is a
##		compile error, not a warning, so a fragment that reads fine does not
##		build.
##	Syntax:
##		check-readme.bash [README] [HEADER]
##	Exit: 0 = every example builds, 1 = one does not, 2 = usage or missing input.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

repoDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readme="${1:-${repoDir}/README.md}"
header="${2:-${repoDir}/source/c/shcl.h}"
[[ -f "${readme}" ]] || { echo "check-readme: no README at ${readme}" >&2; exit 2 ;}
[[ -f "${header}" ]] || { echo "check-readme: no header at ${header}" >&2; exit 2 ;}

testWhere="check-readme"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "${repoDir}/cicd/utility/include/test-id.bash"
##	Every failure here ends the run, so the open test is failed on the way out.
fOnExit(){
	local rc=$?
	if [[ "${rc}" != 0 ]]; then nBad=$((nBad + 1)); fi
	fTestEnd
	rm -rf "${tmpDir}"
}
tmpDir="$(mktemp -d)"; trap fOnExit EXIT
cp "${header}" "${tmpDir}/"

##	The config the examples read, and the file the README says the save leaves.
##	Every example but Zig's ends in a save, and until 2026-09-20 nothing ran any
##	of them, so the shown result and the code that produces it could drift apart.
awk '/^## What a .shcl file looks like/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tmpDir}/server-in.shcl"
awk '/^### What saving does/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tmpDir}/expected.shcl"
[[ -s "${tmpDir}/server-in.shcl" && -s "${tmpDir}/expected.shcl" ]] \
	|| { echo "check-readme: the config block or the 'What saving does' block is gone from ${readme}" >&2; exit 2 ;}

##	Run an example in its own directory, on a fresh copy of the config, and
##	compare what it saved.
fRunExample(){   ## fRunExample NAME DIR CMD...
	local name="$1" dir="$2"; shift 2
	cp "${tmpDir}/server-in.shcl" "${dir}/server.shcl"
	if ! ( cd "${dir}" && "$@" ) > "${dir}/run.out" 2>&1; then
		echo "check-readme: the README's ${name} example does not run:" >&2
		head -n 20 "${dir}/run.out" >&2
		exit 1
	fi
	if ! diff -u "${tmpDir}/expected.shcl" "${dir}/server.shcl" > "${dir}/run.diff"; then
		echo "check-readme: the ${name} example saves a file the README's 'What saving does' block does not show:" >&2
		head -n 20 "${dir}/run.diff" >&2
		exit 1
	fi
}

fTest EpHHs8W c-example
##	The C example is the fenced ~~~c block; the file has exactly one.
awk '/^~~~+c$/ { inBlock = 1; next } /^~~~+$/ { inBlock = 0 } inBlock' "${readme}" > "${tmpDir}/block.c"
[[ -s "${tmpDir}/block.c" ]] || { echo "check-readme: no c example found in ${readme}" >&2; exit 2 ;}

##	Without a system include of its own the ordering is not being exercised at
##	all - the header pulls in what the example uses, and any order compiles.
grep -q '^#include <' "${tmpDir}/block.c" \
	|| { echo "check-readme: the example shows no system include, so its build order proves nothing" >&2; exit 1 ;}

##	Everything above the P() macro is the preamble; the rest is statements, so
##	it needs a function around it.
awk 'BEGIN { pre = 1 }
     /^#define P\(s\)/ { pre = 0; print; print ""; print "int main(void) {"; next }
     pre { print; next }
     { print }
     END { print "\treturn 0;"; print "}" }' "${tmpDir}/block.c" > "${tmpDir}/example.c"

##	The compile line the README gives its readers, plus -Werror so a warning
##	the reader would see is a failure here.
if ! cc -std=c11 -O2 -Wall -Wextra -Werror -I"${tmpDir}" "${tmpDir}/example.c" -o "${tmpDir}/example" -lm 2> "${tmpDir}/cc.err"; then
	echo "check-readme: the README's C example does not build:" >&2
	head -n 20 "${tmpDir}/cc.err" >&2
	exit 1
fi
fRunExample C "${tmpDir}" ./example

##	C++. Two blocks: the implementation file verbatim, then the example, whose
##	statements go in a main() from its first comment on. The two files build
##	apart with the line the README gives, which is the point: the example's
##	file sees no C.
fTest Er1ohBI cpp-example
mkdir -p "${tmpDir}/cppex"
cp "${header}" "${repoDir}/source/c/shcl.hpp" "${tmpDir}/cppex/"
awk '/^~~~+cpp$/ { n++; inBlock = 1; next } /^~~~+$/ { inBlock = 0 } inBlock { print > (dir "/block" n ".cpp") }' dir="${tmpDir}/cppex" "${readme}"
[[ -s "${tmpDir}/cppex/block1.cpp" && -s "${tmpDir}/cppex/block2.cpp" ]] || { echo "check-readme: the two cpp blocks are gone from ${readme}" >&2; exit 2 ;}
mv "${tmpDir}/cppex/block1.cpp" "${tmpDir}/cppex/impl.cpp"
awk 'BEGIN { pre = 1 }
     pre && /^\/\/ One call reads and parses/ { pre = 0; print "int main() {"; print; next }
     { print }
     END { print "}" }' "${tmpDir}/cppex/block2.cpp" > "${tmpDir}/cppex/main.cpp"
grep -q '^int main' "${tmpDir}/cppex/main.cpp" \
	|| { echo "check-readme: the cpp example no longer has the line the main() split is taken at" >&2; exit 1 ;}
if ! ( cd "${tmpDir}/cppex" && c++ -std=c++17 -O2 -Wall -Wextra -Werror main.cpp impl.cpp -o ex -lm ) 2> "${tmpDir}/cpp.err"; then
	echo "check-readme: the README's C++ example does not build:" >&2
	head -n 20 "${tmpDir}/cpp.err" >&2
	exit 1
fi
fRunExample C++ "${tmpDir}/cppex" ./ex

##	Go. The fragment is statements plus the import line it already shows, so a
##	reader adds a package clause, a main() and the two standard imports the
##	body calls. The module resolves the library from the tree rather than the
##	proxy, so this needs no network.
fTest EpHHs8X go-example
awk '/^~~~+go$/ { inBlock = 1; next } /^~~~+$/ { inBlock = 0 } inBlock' "${readme}" > "${tmpDir}/block.go"
[[ -s "${tmpDir}/block.go" ]] || { echo "check-readme: no go example found in ${readme}" >&2; exit 2 ;}
mkdir -p "${tmpDir}/goex"
{
	echo 'package main'
	echo
	echo 'import ('
	echo '	"fmt"'
	echo '	"log"'
	sed -n 's/^import shcl \(.*\)$/	shcl \1/p' "${tmpDir}/block.go"
	echo ')'
	echo
	echo 'func main() {'
	grep -v '^import shcl ' "${tmpDir}/block.go"
	echo '}'
} > "${tmpDir}/goex/main.go"
{
	echo 'module readme-example'
	echo
	echo 'go 1.24'
	echo
	echo 'require github.com/yottacore/shcl/source/go/v2 v2.0.0'
	echo
	echo "replace github.com/yottacore/shcl/source/go/v2 => ${repoDir}/source/go"
} > "${tmpDir}/goex/go.mod"
if ! ( cd "${tmpDir}/goex" && GOFLAGS=-mod=mod go build -o goex . ) 2> "${tmpDir}/go.err"; then
	echo "check-readme: the README's Go example does not build:" >&2
	head -n 20 "${tmpDir}/go.err" >&2
	exit 1
fi
fRunExample Go "${tmpDir}/goex" ./goex

##	Python. The block is a whole script already, so the only thing a reader adds
##	is the module on the import path - which for the published package is what
##	pip put there, and here is the tree's own copy.
fTest EqRTWFf python-example
mkdir -p "${tmpDir}/pyex"
awk '/^~~~+python$/ { inBlock = 1; next } /^~~~+$/ { inBlock = 0 } inBlock' "${readme}" > "${tmpDir}/pyex/example.py"
[[ -s "${tmpDir}/pyex/example.py" ]] || { echo "check-readme: no python example found in ${readme}" >&2; exit 2 ;}
cp "${repoDir}/source/python/shcl.py" "${tmpDir}/pyex/"
fRunExample Python "${tmpDir}/pyex" python3 example.py

##	Rust. The block is statements plus its own use line, so a reader adds a
##	main(); the `?` on the save makes that main return the save's error type.
##	The dependency is a path rather than the README's `shcl = "2"`, since the
##	gate must not need crates.io - what is being checked is the code, and the
##	crate it resolves to is this tree's.
fTest EqRTWFg rust-example
mkdir -p "${tmpDir}/rsex/src"
awk '/^~~~+rust$/ { inBlock = 1; next } /^~~~+$/ { inBlock = 0 } inBlock' "${readme}" > "${tmpDir}/block.rs"
[[ -s "${tmpDir}/block.rs" ]] || { echo "check-readme: no rust example found in ${readme}" >&2; exit 2 ;}
{
	sed -n '/^use /p' "${tmpDir}/block.rs"
	echo
	echo 'fn main() -> Result<(), shcl::SaveError> {'
	sed '/^use /d' "${tmpDir}/block.rs"
	echo '	Ok(())'
	echo '}'
} > "${tmpDir}/rsex/src/main.rs"
{
	echo '[package]'
	echo 'name = "readme-example"'
	echo 'version = "0.0.0"'
	echo 'edition = "2021"'
	echo
	echo '[dependencies]'
	echo "shcl = { path = \"${repoDir}/source/rust\" }"
} > "${tmpDir}/rsex/Cargo.toml"
##	The toolchain the rest of the gate uses. Without it the example resolves to
##	whatever rustc comes first on PATH, which on a box with a distribution rustc
##	ahead of rustup is not the one anything else here builds with.
cp "${repoDir}/rust-toolchain.toml" "${tmpDir}/rsex/"
if ! ( cd "${tmpDir}/rsex" && CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="${tmpDir}/rstarget" cargo build -q ) 2> "${tmpDir}/rs.err"; then
	echo "check-readme: the README's Rust example does not build:" >&2
	head -n 20 "${tmpDir}/rs.err" >&2
	exit 1
fi
fRunExample Rust "${tmpDir}/rsex" "${tmpDir}/rstarget/debug/readme-example"

##	Zig. The block is helper functions and then statements, so the statements
##	go in a main(); everything else is verbatim, including the two-line impl.c
##	and the build line the README prints beside it. Skipped out loud where
##	there is no zig - it is not a build dependency of anything shipped.
fTest EpHHs8Y zig-example
if command -v zig >/dev/null 2>&1; then
	awk '/^~~~+zig$/ { inBlock = 1; next } /^~~~+$/ { inBlock = 0 } inBlock' "${readme}" > "${tmpDir}/block.zig"
	[[ -s "${tmpDir}/block.zig" ]] || { echo "check-readme: no zig example found in ${readme}" >&2; exit 2 ;}
	mkdir -p "${tmpDir}/zigex"
	cp "${header}" "${tmpDir}/zigex/"
	printf '#define SHCL_IMPLEMENTATION\n#include "shcl.h"\n' > "${tmpDir}/zigex/impl.c"
	awk 'BEGIN { pre = 1 }
	     pre && /^\/\/ The C file tier/ { pre = 0; print "pub fn main() void {"; print; next }
	     { print }
	     END { print "}" }' "${tmpDir}/block.zig" > "${tmpDir}/zigex/main.zig"
	grep -q '^pub fn main' "${tmpDir}/zigex/main.zig" \
		|| { echo "check-readme: the zig example no longer has the line the main() split is taken at" >&2; exit 1 ;}
	if ! ( cd "${tmpDir}/zigex" && zig build-exe main.zig impl.c -lc -lm -I. ) > "${tmpDir}/zig.err" 2>&1; then
		echo "check-readme: the README's Zig example does not build:" >&2
		head -n 20 "${tmpDir}/zig.err" >&2
		exit 1
	fi
elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
	echo "check-readme: no zig here, and the gate requires it" >&2
	exit 1
else
	echo "check-readme: skipping the Zig example (no zig here)"
	echo check-readme >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
fi
##	The transcripts. A ~~~console block reads as real output, so every `$ shcl`
##	line in one is run against the README's own server.shcl and schema, and has
##	to print what the block shows, stderr included, in the order a terminal
##	shows it. They drifted twice, each time a new line of output reached no
##	transcript. Two files the README describes rather than shows are made here:
##	server.shcl with the colon knocked off line 3, for the block that starts
##	with `shcl check server.shcl`, and an app.shcl whose line 2 has the
##	misspelled key its schema block reports.
fTest EqGg9jM console-transcripts
cli="${SHCL_CLI:-${repoDir}/source/rust/target/debug/shcl}"
[[ -x "${cli}" ]] || { echo "check-readme: no built CLI at ${cli} to run the transcripts with" >&2; exit 2 ;}
tx="${tmpDir}/tx"
mkdir -p "${tx}/bin" "${tx}/cases"
ln -s "${cli}" "${tx}/bin/shcl"
awk '/^## What a .shcl file looks like/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tx}/server-shown.shcl"
awk '/^Hand it a schema/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tx}/app-schema.shcl"
[[ -s "${tx}/server-shown.shcl" && -s "${tx}/app-schema.shcl" ]] \
	|| { echo "check-readme: the transcripts' server.shcl or schema block is gone from ${readme}" >&2; exit 2 ;}
sed '3s/://' "${tx}/server-shown.shcl" > "${tx}/server-knocked.shcl"
printf 'workers: 4\nlog-levle: warn\n' > "${tx}/app.shcl"
##	One case per command: N.cmd, N.want (the lines under it, less the blank that
##	ends them) and N.blk (which block it is in).
awk -v dir="${tx}/cases" '
	function done_case() { sub(/\n\n$/, "\n", buf); printf "%s", buf > (dir "/" n ".want"); close(dir "/" n ".want"); n = 0 }
	/^~~~+console$/ { inb = 1; blk++; next }
	inb && /^~~~+$/ { if (n) done_case(); inb = 0; next }
	inb && /^\$ / { if (n) done_case(); n = ++cases; print substr($0, 3) > (dir "/" n ".cmd"); close(dir "/" n ".cmd"); print blk > (dir "/" n ".blk"); close(dir "/" n ".blk"); buf = ""; next }
	inb && n { buf = buf $0 "\n" }' "${readme}"
nCases=0; nTxBad=0; lastBlk=""
for cmdFile in $(find "${tx}/cases" -name '*.cmd' | sort -t/ -k1 -V); do
	base="${cmdFile%.cmd}"
	cmd="$(cat "${cmdFile}")"
	blk="$(cat "${base}.blk")"
	if [[ "${blk}" != "${lastBlk}" ]]; then
		lastBlk="${blk}"
		if [[ "${cmd}" == "shcl check server.shcl"* ]]; then
			cp "${tx}/server-knocked.shcl" "${tx}/server.shcl"
		else
			cp "${tx}/server-shown.shcl" "${tx}/server.shcl"
		fi
	fi
	[[ "${cmd}" == shcl\ * ]] || continue
	want="$(cat "${base}.want")"
	got="$(cd "${tx}" && PATH="${tx}/bin:${PATH}" bash -c "${cmd}" 2>&1 </dev/null || true)"
	nCases=$((nCases + 1))
	if [[ "${got}" != "${want}" ]]; then
		echo "check-readme: transcript: '${cmd}' prints:" >&2
		diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | sed 's/^/	/' >&2 || true
		nTxBad=$((nTxBad + 1))
	fi
done
if ((nCases < 10)); then
	echo "check-readme: transcript: only ${nCases} command(s) found in the README's console blocks" >&2
	exit 1
fi
((nTxBad == 0)) || exit 1
fTestEnd
echo "check-readme: the ${nCases} transcript command(s) print what the README shows"

##	The Escapes sample went in with a bad escape that nothing read.
fTest Es3cEBF escapes-sample
awk '/^## Escapes/ { f = 1 } f && /^~~~+text$/ { b = 1; next } b && /^~~~+$/ { exit } b' "${readme}" > "${tmpDir}/escapes.shcl"
[[ -s "${tmpDir}/escapes.shcl" ]] || { echo "check-readme: the Escapes sample is gone from ${readme}" >&2; exit 1 ;}
escOut="$("${cli}" check "${tmpDir}/escapes.shcl" 2>&1 || true)"
if [[ "${escOut}" != "ok (0 diagnostic(s))" ]]; then
	echo "check-readme: the Escapes sample does not load clean:" >&2
	printf '%s\n' "${escOut}" | sed 's/^/	/' >&2
	exit 1
fi
fTestEnd

##	The shell blocks. The Bash and PowerShell ones went stale at 3.0, first on
##	the comma rule and then on the selectors, since nothing ran them. A section's
##	blocks run top to bottom in one directory, the way a reader pastes them, on
##	the README's server.shcl with the wrapper beside it and SHCL_BIN pinned to the
##	built CLI. Every command has to succeed, and the file left behind has to load
##	clean.
fSectionBlocks(){   ## fSectionBlocks HEADING LANG DIR: writes DIR/N.blk, prints N
	mkdir -p "$3"
	awk -v head="$1" -v lang="$2" -v dir="$3" '
		fence != "" { if ($0 == fence) { fence = ""; if (out != "") { close(out); out = "" } } else if (out != "") print > out; next }
		/^~~~+/ { fence = $0; sub(/[^~].*$/, "", fence); if (f && $0 == fence lang) out = dir "/" (++n) ".blk"; next }
		/^#+ / { f = ($0 == head) }
		END { print n + 0 }' "${readme}"
}
fSectionLoadsClean(){   ## fSectionLoadsClean NAME DIR
	local out
	out="$("${cli}" check "$2/server.shcl" 2>&1 || true)"
	[[ "${out}" == "ok (0 diagnostic(s))" ]] && return 0
	echo "check-readme: the README's $1 blocks leave a server.shcl that does not load clean:" >&2
	printf '%s\n' "${out}" | sed 's/^/	/' >&2
	exit 1
}
##	A bash or sh section runs as one script under errexit. A line such as
##	`x=$(...)   # 52428800, in bytes` is a claim about what x holds, so it is
##	checked too.
fRunBashSection(){   ## fRunBashSection HEADING LANG
	local dir="${tmpDir}/sh-${2}-${1//[^A-Za-z]/}" n i name want
	n="$(fSectionBlocks "$1" "$2" "${dir}")"
	if [[ "${n}" == 0 ]]; then echo "check-readme: no ${2} block under '${1}' in ${readme}" >&2; exit 1; fi
	cp "${tmpDir}/server-in.shcl" "${dir}/server.shcl"
	cp "${repoDir}/source/bash/shcl.bash" "${dir}/"
	{
		echo 'set -Eeo pipefail'
		# shellcheck disable=SC2016  ## expands in the generated script
		echo 'trap '\''echo "fails at: ${BASH_COMMAND}" >&2'\'' ERR'
		for ((i = 1; i <= n; i++)); do cat "${dir}/${i}.blk"; done
		for ((i = 1; i <= n; i++)); do
			sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=\$\(.*\)[[:space:]]+#[[:space:]]*([0-9]+)([^0-9].*)?$/\1 \2/p' "${dir}/${i}.blk"
		done | while read -r name want; do
			echo "[[ \"\${${name}}\" == '${want}' ]] || { echo \"check-readme: README ${2} block: ${name} is '\${${name}}', its comment says ${want}\" >&2; exit 1; }"
		done
	} > "${dir}/run.bash"
	if ! ( cd "${dir}" && PATH="${tx}/bin:${PATH}" SHCL_BIN="${cli}" bash "${dir}/run.bash" ) > "${dir}/run.out" 2>&1 </dev/null; then
		echo "check-readme: the README's ${2} blocks under '${1}' do not run:" >&2
		head -n 20 "${dir}/run.out" | sed 's/^/	/' >&2
		exit 1
	fi
	fSectionLoadsClean "${2} '${1}'" "${dir}"
	echo "check-readme: the ${n} ${2} block(s) under '${1}' run"
}
fTest Es9JhMP shell-blocks
fRunBashSection '## Using the CLI' sh
fRunBashSection '### Bash' bash
fTestEnd

##	PowerShell has no errexit for a native exit code, so the blocks are parsed
##	and run one top-level statement at a time, dot-sourced so each sees what the
##	last one set, and a nonzero LASTEXITCODE after any of them fails the run.
fTest Es9JhOf powershell-blocks
if command -v pwsh >/dev/null 2>&1; then
	psDir="${tmpDir}/ps"
	nPs="$(fSectionBlocks '### PowerShell' powershell "${psDir}")"
	if [[ "${nPs}" == 0 ]]; then echo "check-readme: no powershell block under '### PowerShell' in ${readme}" >&2; exit 1; fi
	cp "${tmpDir}/server-in.shcl" "${psDir}/server.shcl"
	cp "${repoDir}/source/powershell/shcl.ps1" "${psDir}/"
	cat > "${tmpDir}/run-ps-blocks.ps1" << 'EOF'
$ErrorActionPreference = 'Stop'
foreach ($__readmeBlock in (Get-ChildItem -Path $args[0] -Filter '*.blk' | Sort-Object -Property { [int]$_.BaseName })) {
	$__readmeTokens = $null; $__readmeErrors = $null
	$__readmeAst = [System.Management.Automation.Language.Parser]::ParseFile($__readmeBlock.FullName, [ref]$__readmeTokens, [ref]$__readmeErrors)
	if ($__readmeErrors.Count -gt 0) {
		[Console]::Error.WriteLine("check-readme: README PowerShell block $($__readmeBlock.BaseName) does not parse: $($__readmeErrors[0].Message)")
		exit 1
	}
	foreach ($__readmeStatement in $__readmeAst.EndBlock.Statements) {
		$global:LASTEXITCODE = 0
		. ([scriptblock]::Create($__readmeStatement.Extent.Text))
		if ($global:LASTEXITCODE -ne 0) {
			[Console]::Error.WriteLine("check-readme: README PowerShell block $($__readmeBlock.BaseName) exits $($global:LASTEXITCODE) at: $($__readmeStatement.Extent.Text)")
			exit 1
		}
	}
}
exit 0
EOF
	if ! ( cd "${psDir}" && SHCL_BIN="${cli}" env -u DISPLAY pwsh -NoProfile -NonInteractive -File "${tmpDir}/run-ps-blocks.ps1" "${psDir}" ) > "${psDir}/run.out" 2>&1 </dev/null; then
		echo "check-readme: the README's PowerShell blocks do not run:" >&2
		head -n 20 "${psDir}/run.out" | sed 's/^/	/' >&2
		exit 1
	fi
	fSectionLoadsClean PowerShell "${psDir}"
	echo "check-readme: the ${nPs} PowerShell block(s) run"
elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
	echo "check-readme: no pwsh here, and the gate requires it" >&2
	exit 1
else
	echo "check-readme: skipping the PowerShell blocks (no pwsh here)"
	echo check-readme >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
fi
fTestEnd

##	The prose under the Bash block says what each of the two set options makes
##	of one piece of text: --set one string, --set-literal a two-element array.
##	It said so of comma text after 3.0 made that an error.
fTest Es9JhQu set-spellings
# shellcheck disable=SC2016  ## the backticks are markdown, not expansions
setText="$(awk '/^The two spellings differ/' "${readme}" | grep -oE '`[a-z.-]+=[^`]*,[^`]*`' | head -n1 | tr -d '`' || true)"
[[ -n "${setText}" ]] || { echo "check-readme: the paragraph on --set and --set-literal no longer shows its comma text" >&2; exit 1 ;}
for setOpt in --set --set-literal; do
	if [[ "${setOpt}" == --set ]]; then wantN=1; else wantN=2; fi
	printf 'x: 1\n' > "${tmpDir}/spell.shcl"
	if ! "${cli}" set --write "${tmpDir}/spell.shcl" "${setOpt}" "${setText}" > "${tmpDir}/spell.out" 2>&1; then
		echo "check-readme: '${setOpt} ${setText}', from the README, fails:" >&2
		sed 's/^/	/' "${tmpDir}/spell.out" >&2
		exit 1
	fi
	gotN="$("${cli}" get --array "${tmpDir}/spell.shcl" "${setText%%=*}" 2>/dev/null | wc -l | tr -d ' ' || true)"
	if [[ "${gotN}" != "${wantN}" ]]; then
		echo "check-readme: '${setOpt} ${setText}', from the README, writes ${gotN} element(s), not ${wantN}" >&2
		exit 1
	fi
done
fTestEnd

##	The paragraph on 2.x files names the value that needs --from-2x and the one
##	that comes through as it was. It went stale once already, on backslashes.
fTest Es9KiYw migrate-claims
migPara="$(awk '/^If you have files written for 2.x/' "${readme}")"
# shellcheck disable=SC2016  ## the backticks are markdown, not expansions
migComma="$(grep -oE '`[a-z]+: [^`]*,[^`]*`' <<< "${migPara}" | head -n1 | tr -d '`' || true)"
# shellcheck disable=SC2016  ## the backticks are markdown, not expansions
migSlash="$(grep -oE '`[a-z]+: [^`]*\\[^`]*`' <<< "${migPara}" | head -n1 | tr -d '`' || true)"
[[ -n "${migComma}" && -n "${migSlash}" ]] \
	|| { echo "check-readme: the paragraph on 2.x files no longer shows its comma value and its backslash value" >&2; exit 1 ;}
printf '%s\n' "${migComma}" > "${tmpDir}/mig.shcl"
migRc=0; migOut="$("${cli}" migrate "${tmpDir}/mig.shcl" 2>/dev/null)" || migRc=$?
if [[ "${migRc}" != 7 || "${migOut}" != "${migComma}" ]]; then
	echo "check-readme: migrate on '${migComma}' exits ${migRc} and prints '${migOut}'; the README says it is left alone at exit 7" >&2
	exit 1
fi
printf '%s\n' "${migSlash}" > "${tmpDir}/mig.shcl"
migRc=0; migOut="$("${cli}" migrate "${tmpDir}/mig.shcl" 2>/dev/null)" || migRc=$?
if [[ "${migRc}" != 0 || "${migOut%%$'\n'*}" != "${migSlash}" ]]; then
	echo "check-readme: migrate on '${migSlash}' exits ${migRc} and prints '${migOut%%$'\n'*}'; the README says it comes through as it was" >&2
	exit 1
fi
fTestEnd
echo "check-readme: OK"

##	History:
##		2026-08-30  Created, after the example was found not to build with the
##		            system includes a reader adds above the header.
##		2026-09-08  Go and Zig join it, after the Go fragment was found not to
##		            compile at all and the Zig one to be checked by nothing.
##		2026-09-17  The zig skip is a failure under SHCL_GATE_STRICT and is noted
##		            in SHCL_GATE_SKIPS, so a local run that took it is not
##		            recorded as having run everything.
##		2026-09-18  The console transcripts are run and compared, after a new
##		            line of output reached none of them for the second time.
##		2026-09-20  The Rust and Python examples build too, and all four that
##		            save are run and their file compared with the README's.
##		2026-09-26  The C++ example, built apart from its implementation file.
##		2026-10-07  The Escapes sample has to load clean.
##		2026-10-08  The Bash, PowerShell and CLI shell blocks run, after the
##		            first two were found failing on 3.0. Also the --set prose
##		            and the 2.x migrate paragraph's two values.
