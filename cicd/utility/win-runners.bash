#!/usr/bin/env bash

##	Purpose:
##		Run every binding's conformance runner on whatever host this is invoked
##		on. The pipeline's own test stage is defined in cicd/config.bash and is
##		wired into the engine, which is bash plus Linux tooling all the way down,
##		so none of it runs on windows. That left the file tier - the one part of
##		the library with real per-platform code - covered only where the
##		platform-specific half never executes, and the python binding threw on
##		every windows overwrite for a release without anything noticing. This is
##		the smaller gate that does run there: the runners, the veneer smoke and,
##		on a real windows host, the installers' registry PATH handling.
##	Syntax:
##		win-runners.bash [ROOT]
##		  ROOT   repo root (default: two levels up from this script)
##		CC, CXX and PYTHON override the tools it reaches for. WINRUN_PARTIAL
##		runs the rows a box has the tools for instead of refusing the lot, and
##		takes the registry row through a sandbox rather than this box's own
##		registry; it is for a developer machine, and the hosted job does not
##		set it.
##	Exit: 0 = every runner passed, 1 = at least one did not, 2 = a tool is missing.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd -- "${meDir}/../.." && pwd)}"
cd -- "${root}"

cc="${CC:-gcc}"
cxx="${CXX:-g++}"
py="${PYTHON:-}"
if [[ -z "${py}" ]]; then
	if command -v python3 >/dev/null 2>&1; then py=python3; else py=python; fi
fi

## Without the suffix the link succeeds and the run cannot find what it wrote.
exe=""
case "$(uname -s 2>/dev/null || true)" in MINGW*|MSYS*|CYGWIN*) exe=".exe" ;; esac

## A missing compiler otherwise surfaces as an unreadable build error three
## stages later; say which tool and stop. WINRUN_PARTIAL runs what the box does
## have instead, for a developer machine missing one toolchain - the hosted job
## never sets it, and a skipped row is named in the summary either way.
missing=()
for tool in cargo go "${py}" "${cc}" "${cxx}"; do
	command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if ((${#missing[@]} > 0)); then
	echo "win-runners: not found: ${missing[*]}" >&2
	[[ -n "${WINRUN_PARTIAL:-}" ]] || exit 2
	echo "win-runners: WINRUN_PARTIAL set; the rows needing those are skipped" >&2
fi
fHave() {   ## fHave TOOL [TOOL ...] - false if any is in the missing list
	local want have
	for want in "$@"; do
		for have in ${missing[@]+"${missing[@]}"}; do
			[[ "${want}" == "${have}" ]] && return 1
		done
	done
	return 0
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "win-runners: root ${root}"
echo "win-runners: $(uname -s 2>/dev/null || echo unknown), cc=${cc} cxx=${cxx} py=${py}"

failed=()
skipped=()
##	A step that is a test itself, rather than a runner printing its own, takes
##	--id with its test ID and gets a status line in place of the OK line.
fRun() {   ## fRun [--id ID] NAME TOOLS COMMAND [ARG ...]   TOOLS is space-separated
	local id=""
	if [[ "$1" == --id ]]; then id="$2"; shift 2; fi
	local name="$1" tools="$2"; shift 2
	echo
	echo "[ ${name} ]"
	# shellcheck disable=2086  ## the tool list is meant to split
	if ! fHave ${tools}; then
		fStepLine skip "${id}" "${name}" SKIPPED; skipped+=("${name}"); return 0
	fi
	if "$@"; then fStepLine ok "${id}" "${name}" OK
	else fStepLine FAIL "${id}" "${name}" FAILED >&2; failed+=("${name}"); fi
}
fStepLine() {   ## fStepLine STATUS ID NAME WORD
	if [[ -n "$2" ]]; then printf '%-4s %s win-runners %s\n' "$1" "$2" "$3"
	else echo "win-runners: $3: $4"; fi
}

## The C pair build into the temp dir rather than the tree, so a run leaves
## nothing behind for the next one to pick up stale.
fRunC() {
	"${cc}" -std=c11 -O2 -Wall -Wextra -Werror -Isource/c \
		source/c/tests/conformance.c -o "${work}/conformance${exe}" -lm \
		&& "${work}/conformance${exe}" project/conformance
}
fRunCxx() {
	"${cxx}" -std=c++17 -O2 -Wall -Wextra -Werror -Isource/c \
		source/c/tests/veneer_smoke.cpp -o "${work}/veneer${exe}" -lm \
		&& "${work}/veneer${exe}"
}
## Both oom tests end up at a setjmp recovery point, which unwinds through SEH on
## this host and through nothing much on linux or under wine, so windows is the
## only place the arrival can be judged. It also has to hold at every
## optimization level: the shape that broke it needs both a frame pointer and
## saved xmm registers, which is a decision gcc makes per level, so -O2 alone
## would have missed -O1.
fRunOomSweep() {   ## fRunOomSweep NAME
	local name="$1" opt
	for opt in -O0 -O1 -O2 -O3 -Os; do
		"${cc}" -std=c11 "${opt}" -Wall -Wextra -Werror -Isource/c \
			"source/c/tests/${name}.c" -o "${work}/${name}${exe}" -lm || return 1
		"${work}/${name}${exe}" || { echo "win-runners: ${name}: ${opt}: exit $?" >&2; return 1; }
	done
}
## The allocation bounds move with the allocator, so they belong here rather
## than on linux alone.
fRunMemBounds() {
	"${cc}" -std=c11 -O2 -Wall -Wextra -Werror -Isource/c \
		source/c/tests/mem_bounds.c -o "${work}/mem_bounds${exe}" -lm \
		&& "${work}/mem_bounds${exe}"
}
## The C CLI, built once for the five rows that run it; a compile is several
## seconds, more under mingw. A failed build is remembered, so each of those
## rows fails on it rather than compiling again.
cliBuilt=""
fBuildCcli() {
	if [[ -z "${cliBuilt}" ]]; then
		cliBuilt=1
		"${cc}" -std=c11 -O2 -Wall -Wextra -Werror -Isource/c \
			source/c/cmd/shcl/main.c -o "${work}/shcl-c${exe}" -lm || cliBuilt=0
	fi
	[[ "${cliBuilt}" == 1 ]]
}

## The C CLI's argv: the narrow one arrives in the active code page, best-fit
## mapped, so a name the page cannot spell reached a different file. The two
## names here are the shapes that went wrong: one outside the page, one the
## page maps onto a plain letter.
fRunCcli() {
	fBuildCcli || return 1
	local dir="${work}/argv"
	mkdir -p "${dir}"
	printf 'a: 1\n' > "${dir}/a.shcl"
	printf 'b: 1\n' > "${dir}/ā.shcl"
	printf 'c: 1\n' > "${dir}/café.shcl"
	local got
	got="$("${work}/shcl-c${exe}" get "${dir}/café.shcl" c 2>&1)" || { echo "win-runners: c cli: café.shcl: ${got}" >&2; return 1; }
	[[ "${got}" == "1" ]] || { echo "win-runners: c cli: café.shcl read ${got@Q}" >&2; return 1; }
	"${work}/shcl-c${exe}" set --write --set x=1 "${dir}/ā.shcl" > /dev/null || return 1
	[[ "$(cat "${dir}/a.shcl")" == "a: 1" ]] || { echo "win-runners: c cli: a.shcl was rewritten in place of ā.shcl" >&2; return 1; }
	grep -q '^x: 1$' "${dir}/ā.shcl" || { echo "win-runners: c cli: ā.shcl was not written" >&2; return 1; }
}

## A path past MAX_PATH, which needs the `\\?\` prefix a caller has to spell
## itself. The C save prefixed an already-prefixed path again and built
## `\\?\UNC\?\C:\...`, which no create opens; under MAX_PATH the strip that
## follows undid it, so only a long path showed it. Nothing on linux has the
## limit and nothing under wine reaches this code, so the row lives here.
fRunLongPath() {
	fBuildCcli || return 1
	## Two segments of 100, so the whole path is past 260 with room for the
	## temp file's own suffix.
	local deep
	deep="${work}/$(printf 'd%.0s' {1..100})/$(printf 'e%.0s' {1..100})"
	mkdir -p "${deep}" || return 1
	local win
	win="$(cygpath -w "${deep}" 2>/dev/null)" || return 1
	## cygpath gives the prefix back on a path this long; the test is about the
	## prefixed spelling, so put it on either way.
	[[ "${win:0:4}" == "\\\\?\\" ]] || win="\\\\?\\${win}"
	"${work}/shcl-c${exe}" set --write --set a=1 "${win}\\new.shcl" || return 1
	[[ -f "${deep}/new.shcl" ]] || { echo "win-runners: long path: the file was not written" >&2; return 1; }
	grep -q '^a: 1$' "${deep}/new.shcl"
}

## A stdin nothing is attached to reads as an empty document, exit 0. POSIX
## reports that as EOF and every binding already agreed there; windows answers
## with an invalid handle or an invalid function instead, which each runtime
## spells its own way, so this is the only place the rule can be judged.
fRunClosedStdin() {
	local bad=0
	local clis=()
	fBuildCcli || return 1
	clis+=("c|${work}/shcl-c${exe}")
	## Each CLI drops out on its own rather than taking the row with it, so a box
	## short one toolchain still judges the other three.
	if fHave cargo; then
		cargo build --quiet --manifest-path source/rust/Cargo.toml || return 1
		clis+=("rust|source/rust/target/debug/shcl${exe}")
	fi
	if fHave go; then
		go -C source/go/cmd build -o "${work}/shcl-go${exe}" ./shcl || return 1
		clis+=("go|${work}/shcl-go${exe}")
	fi
	if fHave "${py}"; then clis+=("python|${py} source/python/cmd/shcl/main.py"); fi
	local entry name cmd out rc
	for entry in "${clis[@]}"; do
		name="${entry%%|*}"; cmd="${entry#*|}"
		## Split on purpose: the python entry is an interpreter plus a script.
		rc=0; out="$(${cmd} fmt - 0<&- 2>&1)" || rc=$?
		if ((rc != 0)) || [[ -n "${out}" ]]; then
			echo "win-runners: closed stdin: ${name} exited ${rc} saying ${out@Q}" >&2
			bad=1
		fi
	done
	((bad == 0))
}

## The CLI rows the corpus cannot reach - closed streams, a bare CR ending an
## ops line, the message a failed write names. One of them pins a windows-only
## fix, and until now no cli-regress ran here at all. Python's CLI is a script
## with no executable bit on windows, and cli-regress runs each CLI as one
## path, so it goes through a wrapper; msys counts a file opening with #! as
## executable. Its CRLF and locale-encoding fixes were windows fixes too.
fRunCliRegress() {
	local clis=()
	fBuildCcli || return 1
	clis+=("c|${work}/shcl-c${exe}")
	if fHave cargo; then
		cargo build --quiet --manifest-path source/rust/Cargo.toml || return 1
		clis+=("rust|source/rust/target/debug/shcl${exe}")
	fi
	if fHave go; then
		go -C source/go/cmd build -o "${work}/shcl-go${exe}" ./shcl || return 1
		clis+=("go|${work}/shcl-go${exe}")
	fi
	if fHave "${py}"; then
		printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "${py}" "${root}/source/python/cmd/shcl/main.py" > "${work}/shcl-py"
		chmod +x "${work}/shcl-py"
		clis+=("python|${work}/shcl-py")
	fi
	bash cicd/utility/cli-regress.bash "${clis[@]}"
}

## Its own row rather than an fRun one, because a host that cannot give us a
## sandbox is a skip and not a failure - no feature installed, or somebody's own
## sandbox already up. Exit 2 from the wrapper is that case; 0 and 1 are a result.
fRunWinpathSandbox() {
	local status=0
	echo
	echo "[ windows path (sandbox) ]"
	powershell -NoProfile -ExecutionPolicy Bypass -File cicd/utility/winpath-sandbox.ps1 || status=$?
	case "${status}" in
		0) echo "win-runners: windows path (sandbox): OK" ;;
		2) echo "win-runners: windows path (sandbox): SKIPPED"; skipped+=("windows path (sandbox)") ;;
		*) echo "win-runners: windows path (sandbox): FAILED" >&2; failed+=("windows path (sandbox)") ;;
	esac
}

## install.ps1's uninstall skipped a file it could not delete in silence, then
## blamed the dir it kept on files it never installed. A running shcl.exe is
## what holds one; a handle opened with no sharing stops a delete the same way
## and needs no process to manage. Under 5.1, where the one-liner runs.
fRunUninstallLock() {
	local dir="${work}/lockdest" ps="${work}/lock.ps1" win out
	mkdir -p "${dir}/code"
	printf 'x\n' > "${dir}/shcl.exe"; printf 'x\n' > "${dir}/code/lib.rs"
	win="$(cygpath -w "${dir}")" || return 1
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo 'Set-StrictMode -Version Latest'
		echo '$ErrorActionPreference = "Stop"'
		sed -n '/^\tfunction Remove-ShclFile/,/^\t}/p' install.ps1
		echo "\$exe = Join-Path -Path '${win}' -ChildPath 'shcl.exe'"
		echo '$held = [System.IO.File]::Open($exe, "Open", "Read", "None")'
		echo "try { \$r = Remove-ShclFile -Dest '${win}' } finally { \$held.Dispose() }"
		echo 'Write-Output ("stuck=[{0}] foreign={1}" -f ($r.Stuck -join ","), $r.Foreign)'
	} > "${ps}"
	out="$(powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "${ps}")" 2>&1)" \
		|| { echo "win-runners: uninstall lock: ${out}" >&2; return 1; }
	[[ "${out}" == *"stuck=[${win}\\shcl.exe] foreign=False"* ]] \
		|| { echo "win-runners: uninstall lock: ${out@Q}" >&2; return 1; }
	[[ ! -e "${dir}/code" ]] || { echo "win-runners: uninstall lock: the emptied code dir was left" >&2; return 1; }
}

## 20260924 item 7: Windows PowerShell 5.1 puts a BOM in front of text it pipes
## to a program when $OutputEncoding carries one, as it does on a UTF-8 console,
## and `set` then read the first op as unknown. Piped the way a user types it.
fRunOpsBom51() {
	local f="${work}/bom51.shcl" ps="${work}/bom51.ps1" out
	cargo build --quiet --manifest-path source/rust/Cargo.toml || return 1
	printf 'a: 1\n' > "${f}"
	#  shellcheck disable=2016  ## PowerShell's own $variables, quoted so bash leaves them alone.
	{
		echo '$OutputEncoding = [System.Text.Encoding]::UTF8'
		echo "\"int\`tk\`t5\" | & '$(cygpath -w source/rust/target/debug/shcl.exe)' set --write '$(cygpath -w "${f}")'"
		echo 'exit $LASTEXITCODE'
	} > "${ps}"
	out="$(powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "${ps}")" 2>&1)" \
		|| { echo "win-runners: ops bom 5.1: ${out}" >&2; return 1; }
	grep -q '^k: 5' "${f}" || { echo "win-runners: ops bom 5.1: the op did not apply: $(cat "${f}")" >&2; return 1; }
}

## 20260924d idea 4 and item 5: the dogfood runner stopped at once under
## Windows PowerShell 5.1, and on Windows put its fixed name where no install
## puts shcl and no PATH looks. A scratch profile under both shells: the build
## comes in, runs, and the fixed name is install.ps1's user folder.
fRunDogfood() {
	local sh prof app src out
	cargo build --quiet --manifest-path source/rust/Cargo.toml || return 1
	for sh in powershell pwsh; do
		command -v "${sh}" >/dev/null 2>&1 || continue
		prof="${work}/df-${sh}/profile"; app="${work}/df-${sh}/app"
		src="${prof}/Dropbox/0-0/common/exec/util/mswin/cli/by-self/win64"
		mkdir -p "${src}" "${app}"
		cp source/rust/target/debug/shcl.exe "${src}/shcl.exe"
		out="$(USERPROFILE="$(cygpath -w "${prof}")" LOCALAPPDATA="$(cygpath -w "${app}")" \
			"${sh}" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w utility/dogfood_shcl.ps1)" version 2>&1)" \
			|| { echo "win-runners: dogfood (${sh}): ${out}" >&2; return 1; }
		[[ "${out}" == *"shcl v"* ]] || { echo "win-runners: dogfood (${sh}) did not run the build: ${out@Q}" >&2; return 1; }
		[[ -e "${app}/Programs/Shcl/shcl.exe" ]] || { echo "win-runners: dogfood (${sh}) left no fixed name in Programs\\Shcl" >&2; return 1; }
	done
}

## Fuzz iterations stay at the in-test default: the long soak is the Linux gate's
## job, and nothing about it is platform-dependent.
##	A windows device name is not something a save may replace, and until
##	2026-09-20 every binding refused one only because a later step happened to
##	fail: the C CLI did not return at all on CON, and the other three printed
##	whatever the OS said about the publish. The names are reserved whether or
##	not a device sits behind them, so COM1 belongs in the list on a box with no
##	serial port. Run under a timeout, since the defect this watches for is a
##	read that waits on the console - a gate that hangs reports nothing.
fCheckDevices() {   ## fCheckDevices CLI [ARG ...]
	local d out rc
	for d in CON NUL COM1; do
		rc=0
		out="$(timeout 20 "$@" set --write --set a=1 "${d}" 2>&1 </dev/null)" || rc=$?
		((rc == 8)) || { echo "win-runners: devices: ${d} exited ${rc}, wanted 8: ${out@Q}" >&2; return 1; }
		[[ "${out}" == *"not a regular file"* ]] \
			|| { echo "win-runners: devices: ${d} said ${out@Q}" >&2; return 1; }
	done
	##	An ordinary create still works, or the test above would pass on a CLI
	##	that refuses everything.
	rm -f "${work}/dev-ok.shcl"
	rc=0
	timeout 20 "$@" set --write --set a=1 "${work}/dev-ok.shcl" >/dev/null 2>&1 </dev/null || rc=$?
	((rc == 0)) || { echo "win-runners: devices: an ordinary create exited ${rc}" >&2; return 1; }
	grep -q '^a: 1$' "${work}/dev-ok.shcl"
}

fDevicesC() {
	fBuildCcli || return 1
	fCheckDevices "${work}/shcl-c${exe}"
}

fDevicesRust() {
	cargo build --quiet --manifest-path source/rust/Cargo.toml || return 1
	fCheckDevices "source/rust/target/debug/shcl${exe}"
}

fDevicesGo() {
	( cd source/go/cmd && go build -o "${work}/shcl-dev-go${exe}" ./shcl ) || return 1
	fCheckDevices "${work}/shcl-dev-go${exe}"
}

fDevicesPython() {
	fCheckDevices "${py}" source/python/cmd/shcl/main.py
}

fRun "rust"        "cargo"          cargo test --manifest-path source/rust/Cargo.toml
fRun "go library"  "go"             go -C source/go test -count=1
fRun "go cli"      "go"             go -C source/go/cmd test -count=1 ./...
fRun "python"      "${py}"          "${py}" source/python/tests/conformance.py
fRun "c"           "${cc}"          fRunC
fRun "c++ veneer"  "${cxx}"         fRunCxx
fRun "c oom hook"  "${cc}"          fRunOomSweep oom_hook
fRun "c oom recover" "${cc}"        fRunOomSweep oom_recover
fRun "c mem bounds" "${cc}"         fRunMemBounds
fRun --id EojrwSX "c cli argv"  "${cc}"          fRunCcli
fRun --id EonWXt5 "closed stdin" "${cc}"         fRunClosedStdin
fRun --id EqMiKTw "c long path" "${cc}"          fRunLongPath
fRun "cli regress"  "${cc}"         fRunCliRegress
fRun --id EqS4fJw "devices c"   "${cc}"          fDevicesC
fRun --id EqS4fJx "devices rust" "cargo"         fDevicesRust
fRun --id EqS4fJy "devices go"  "go"             fDevicesGo
fRun --id EqS4fJz "devices python" "${py}"       fDevicesPython
## The installers' PATH handling needs a real registry, which only exists here.
## It overwrites the machine PATH for the length of the run - fine on a throwaway
## runner, not on a workstation, so a developer box gets the same test inside a
## sandbox, whose registry is thrown away with it.
case "$(uname -s 2>/dev/null || true)" in
	MINGW*|MSYS*|CYGWIN*)
		fRun --id EqbvAmG "uninstall lock" "" fRunUninstallLock
		fRun --id Er8Neza "dogfood runner" "cargo" fRunDogfood
		fRun --id Er8M8AX "ops bom 5.1" "cargo" fRunOpsBom51
		if [[ -n "${WINRUN_PARTIAL:-}" ]]; then fRunWinpathSandbox
		else fRun "windows path" "" powershell -NoProfile -ExecutionPolicy Bypass -File cicd/utility/winpath-regress.ps1
		fi
		;;
esac

echo
((${#skipped[@]} == 0)) || echo "win-runners: SKIPPED: ${skipped[*]}"
if ((${#failed[@]} == 0)); then
	echo "win-runners: OK"
else
	echo "win-runners: FAILED: ${failed[*]}" >&2
	exit 1
fi


##	Script history:
##		- 20260920: A device-name row per binding: CON, NUL and COM1 refuse at
##		            exit 8 saying so, and an ordinary create still works.
##		- 20260821: Created. Nothing in the pipeline ran any binding on windows,
##		  where the file tier's publish step is a different code path in all four.
##		- 20260901: The installers' PATH handling joins, windows hosts only - it
##		  needs a real registry.
##		- 20260903: The allocation-failure recovery joins, and the oom hook it
##		  sits beside now sweeps the same five optimization levels. Their unwind
##		  is a real SEH unwind only here.
##		- 20260903: WINRUN_PARTIAL runs what a developer box has rather than
##		  refusing the lot over one absent toolchain. Skipped rows are named.
##		- 20260903: The registry row runs on a developer box too, inside a
##		  sandbox, instead of being skipped there.
