#!/usr/bin/env bash

##	Purpose:
##		Runs a release build on the test box that runs it natively, over the
##		same CLI cases the other release checks use, and it has to give the
##		same stdout, stderr and exit code as the Linux release built from the
##		same source (2026102419263412).
##		A row that ends in |suites also builds the 4 bindings there from a
##		copy of the tracked source, and runs their conformance suites and
##		cli-regress through box-suites.bash (2026102419263417). |suites=LIST
##		runs only those, such as the Go suite on a slow box (2026102419263422).
##		A Windows build, BIN ending in .exe, means a Windows box. Its ssh opens
##		in cmd, so box-cases.ps1 runs the cases there in place of the sh half,
##		and only the code of an OS error is compared (2026103016433921). Its
##		|suites runs win-runners.bash there, from a copy of the tracked source,
##		which runs the 4 bindings' runners, cli-regress and winpath-regress.ps1
##		as the hosted windows job does. It takes no LIST (2026103016433943).
##		A Windows row's |perf runs perf-gate.bash there over that build, under
##		git's bash, since timed work goes to vm925w (2026103016433965).
##		Each box is held through the VM state helper's wrap, which takes the
##		shared host lock and puts a VM back the way it was found. The box gets
##		a work folder of its own under its temp root, removed after.
##		A box that isn't there, or no helper, is a SKIP, and the rest go on.
##	Syntax:
##		check-boxes.bash LINUX_BIN BOX|SSH_TARGET|BIN[|suites[=LIST]][|perf]...
##		  LINUX_BIN         the native release build, run here for the answers
##		  BOX               the box's name in the host lock
##		  SSH_TARGET        user@host for ssh
##		  BIN               the release build that box runs; empty when none
##		  suites            also run the suites there
##		  LIST              a comma list of rust, go, python, c and cli
##		  perf              also run perf-gate.bash there, Windows boxes only
##		  SHCL_VM_STATE     the VM state helper (default claude_vm-state.bash in
##		                    the synced util tree, then on PATH)
##		  SHCL_BOX_WAIT     seconds to wait for a box another session holds
##		                    (default 900)
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

self="$(realpath -- "${BASH_SOURCE[0]}")"
meDir="$(dirname -- "${self}")"
root="$(cd -- "${meDir}/../.." && pwd)"
sshOpts=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)

##	The box half, plain sh for FreeBSD's sh and macOS's bash 3.2. Makes
##	${HOST_TEMP:-${TMPDIR:-/tmp}}/shcl/<stamp>_<NNN>, unpacks stdin there, runs
##	the cases at low priority (nice, and ionice where the box has it), sends the
##	outputs back, and removes the folder. With a source tree in src/, it runs
##	box-suites.bash there too, over the suites named in want, with
##	/usr/local/bin on PATH for the toolchains a BSD box keeps there.
fBoxScript(){ cat <<'EOF'
base="${HOST_TEMP:-${TMPDIR:-/tmp}}"; base="${base%/}/shcl"
mkdir -p "${base}" || exit 90
stamp="$(date +%Y%m%d-%H%M%S)"; n=1
while :; do
	w="${base}/${stamp}_$(printf '%03d' "${n}")"
	mkdir "${w}" 2>/dev/null && break
	n=$((n + 1)); [ "${n}" -le 999 ] || exit 90
done
gone(){
	case "${w}" in *..*|*//*) return 0 ;; "${base}"/*_[0-9][0-9][0-9]) ;; *) return 0 ;; esac
	[ -d "${w}" ] && [ ! -h "${w}" ] && rm -rf -- "${w}"
}
trap gone EXIT
cd "${w}" && tar -xf - && [ -f run.sh ] || exit 91
io="$(command -v ionice 2>/dev/null)" || io=
case "${io}" in /*) "${io}" -c 3 true 2>/dev/null && io="${io} -c 3" || io= ;; *) io= ;; esac
env -i PATH=/usr/bin:/bin HOME=/ ${io} nice -n 19 sh run.sh > rc.lst 2> /dev/null
set --
if [ -d src ]; then
	set -- s; p=/usr/local/bin:/usr/bin:/bin
	want="$(cat want 2>/dev/null)" || want=
	[ -n "${want}" ] || want=all
	bsh="$(PATH="${p}" command -v bash 2>/dev/null)" || bsh=
	if [ -n "${bsh}" ]; then
		(cd src && env -i PATH="${p}" HOME="${w}" ${io} nice -n 19 "${bsh}" cicd/utility/box-suites.bash "${w}/s" "${want}") > /dev/null 2>&1
	else
		mkdir -p s; for x in rust go python c cli; do
			case ",${want}," in ,all,|*,${x},*) echo "skip ${x} no bash on the box" ;; esac
		done > s/suites.lst
	fi
fi
tar -cf - rc.lst o "$@"
EOF
}

##	The same as check-freebsd's, so the two runs differ only by the build.
fDriver(){ cat <<'EOF'
set -f
tab="$(printf '\t')"; IFS="${tab}"
mkdir -p o
while read -r n rest; do
	set -- ${rest}
	./shcl "$@" > "o/${n}.o" 2> "o/${n}.e" < /dev/null
	echo "${n} rc $?"
done < cases.tsv
EOF
}

##	A Windows box's work folder, made the way fBoxScript makes one, under
##	HOST_TEMP or else TEMP. Prints its path.
fWinMkdir(){ cat <<'EOF'
$ErrorActionPreference = 'Stop'
$base = $env:HOST_TEMP; if (-not $base) { $base = $env:TEMP }
$base = Join-Path -Path $base -ChildPath 'shcl'
if (-not (Test-Path -LiteralPath $base)) { $null = New-Item -ItemType Directory -Path $base }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
for ($n = 1; $n -le 999; $n++) {
	$w = Join-Path -Path $base -ChildPath ('{0}_{1:d3}' -f $stamp, $n)
	try { $null = New-Item -ItemType Directory -Path $w; $w; exit 0 } catch { $null = $_ }
}
exit 90
EOF
}
##	fWinRm DIR: removes that work folder, and only a folder of that shape that
##	isn't a link.
fWinRm(){ cat <<EOF
\$w = '$1'
\$i = Get-Item -LiteralPath \$w -Force -ErrorAction SilentlyContinue
if (\$i -and \$i.PSIsContainer -and -not (\$i.Attributes -band [IO.FileAttributes]::ReparsePoint) -and \$w -match '\\\\shcl\\\\[0-9]{8}-[0-9]{6}_[0-9]{3}\$') { Remove-Item -LiteralPath \$w -Recurse -Force }
EOF
}
##	fWinPs SCRIPT: runs PowerShell text on the box, encoded, since cmd mangles
##	quotes. Short scripts only: cmd caps a command at 8191 characters.
fWinPs(){
	local enc
	enc="$(printf '%s' "$1" | iconv -t UTF-16LE | base64 -w0)"
	# shellcheck disable=SC2029  ## the encoded script is meant to be expanded here
	ssh "${sshOpts[@]}" "${target}" "pwsh -NoProfile -NonInteractive -EncodedCommand ${enc}" < /dev/null
}

##	--on-box runs inside wrap, so the lock is held only while the box works.
##	It leaves a status file: ran, or skip and why. --on-winbox is the same for
##	a Windows box, whose ssh opens in cmd: box-cases.ps1 and the tar go over by
##	scp into a work folder of its own, it runs there, out.tar comes back by
##	scp, and the folder is removed.
if [[ "${1:-}" == --on-winbox ]]; then
	(($# == 4)) || exit 2
	target="$2"; inTar="$3"; outDir="$4"
	if ! ssh "${sshOpts[@]}" "${target}" "exit 0" < /dev/null > /dev/null 2>&1; then
		echo "skip ssh to ${target} did not answer" > "${outDir}/status"; exit 0
	fi
	boxDir="$(fWinPs "$(fWinMkdir)" 2> "${outDir}/ssh.err" | tr -d '\r' || true)"
	if ! [[ "${boxDir}" =~ ^[A-Za-z]:\\[^\'\"\ ]+\\shcl\\[0-9]{8}-[0-9]{6}_[0-9]{3}$ ]]; then
		echo "fail no work folder on the box: ${boxDir} $(tail -n 2 "${outDir}/ssh.err" | tr '\n' ' ')" > "${outDir}/status"; exit 0
	fi
	trap 'fWinPs "$(fWinRm "${boxDir}")" > /dev/null 2>&1 || true' EXIT
	scpDir="${boxDir//\\//}"; rc=0; what=scp
	scp -q "${sshOpts[@]}" "${inTar}" "${meDir}/box-cases.ps1" "${target}:${scpDir}/" < /dev/null 2>> "${outDir}/ssh.err" || rc=$?
	if ((rc == 0)); then
		what="the box"
		# shellcheck disable=SC2029  ## the box's folder is meant to be expanded here
		ssh "${sshOpts[@]}" "${target}" "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"${boxDir}\\box-cases.ps1\"" < /dev/null > "${outDir}/box.out" 2>> "${outDir}/ssh.err" || rc=$?
	fi
	if ((rc == 0)); then
		what="scp back"
		scp -q "${sshOpts[@]}" "${target}:${scpDir}/out.tar" "${outDir}/out.tar" < /dev/null 2>> "${outDir}/ssh.err" || rc=$?
	fi
	##	pwsh colors its errors.
	if ((rc)); then echo "fail ${what} exited ${rc}: $(tail -n 2 "${outDir}/ssh.err" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')" > "${outDir}/status"
	else echo ran > "${outDir}/status"; fi
	exit 0
fi
if [[ "${1:-}" == --on-box ]]; then
	(($# == 4)) || exit 2
	target="$2"; inTar="$3"; outDir="$4"
	if ! ssh "${sshOpts[@]}" "${target}" true < /dev/null > /dev/null 2>&1; then
		echo "skip ssh to ${target} did not answer" > "${outDir}/status"; exit 0
	fi
	rc=0; boxCmd="$(fBoxScript)"; boxCmd="${boxCmd//\'/\'\\\'\'}"
	# shellcheck disable=SC2029  ## the box half is meant to be expanded here
	ssh "${sshOpts[@]}" "${target}" "sh -c '${boxCmd}'" < "${inTar}" > "${outDir}/out.tar" 2> "${outDir}/ssh.err" || rc=$?
	if ((rc)); then echo "fail the box exited ${rc}: $(tail -n 2 "${outDir}/ssh.err" | tr '\n' ' ')" > "${outDir}/status"
	else echo ran > "${outDir}/status"; fi
	exit 0
fi

testWhere=check-boxes; testCounter=nBad
declare -i nBad=0 nRan=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/corpus-cases.bash"

fBad(){ echo "check-boxes: $1" >&2; nBad+=1 ;}
fOsErr(){ find "$1" -name '*.e' -size +0 -exec sed -i -E 's/: [^:]+ \(os error ([0-9]+)\)/: (os error \1)/' {} + ;}
suiteNames=(rust go python c cli)
suitesRe='^suites(=(rust|go|python|c|cli)(,(rust|go|python|c|cli))*)?$'
##	fRowWords ROW: sets box, target, bin, suites and perf from a row, and fails
##	on a word it has no name for.
fRowWords(){
	local w rest
	local -a ws=()
	IFS='|' read -r box target bin rest <<< "$1"
	suites=""; perf=0
	IFS='|' read -ra ws <<< "${rest}"
	for w in "${ws[@]}"; do
		if [[ "${w}" == perf ]]; then perf=1
		elif [[ -z "${suites}" && "${w}" =~ ${suitesRe} ]]; then suites="${w}"
		else return 1; fi
	done
}
##	fWants LIST NAME: whether a box's suite list, all or a comma list, has NAME.
fWants(){ [[ "$1" == all || ",$1," == *",$2,"* ]] ;}
##	fSrcTree DIR [PATH...]: the tracked files of source/ and project/, as they
##	are in the tree, plus what box-suites.bash and cli-regress need from cicd/,
##	and any PATH given.
fSrcTree(){
	local d="$1"; shift
	mkdir -p "${d}"
	git -C "${root}" ls-files -z --cached --others --exclude-standard -- source project cicd/utility/box-suites.bash cicd/utility/cli-regress.bash cicd/utility/include/test-id.bash "$@" \
		| tar -C "${root}" --null --ignore-failed-read -T - -cf - | tar -C "${d}" -xf -
}
##	What win-runners.bash and winpath-regress.ps1 read besides.
winSrc=(cicd/utility/win-runners.bash cicd/utility/winpath-regress.ps1 cicd/utility/winpath-sandbox.ps1 cicd/packaging/shclpath.ps1 install.ps1 utility/dogfood_shcl.ps1 utility/dogfood_shcl.cmd)
##	fSuiteRows NAME: one line per box for that suite, out of suites.all.
fSuiteRows(){
	local s="$1" bx st nm rest
	declare -i n=0
	while read -r bx st nm rest; do
		[[ "${nm}" == "${s}" ]] || continue
		case "${st}" in
			pass) echo "PASS ${bx}: the ${s} suite (${rest})"; n+=1 ;;
			skip) echo "SKIP ${bx}: the ${s} suite, ${rest}" ;;
			*)    fBad "${bx}: the ${s} suite failed (${rest})"; n+=1
			      tail -n 20 "b_${bx}/back/s/${s}.log" 2> /dev/null | sed 's/^/    /' >&2 || true ;;
		esac
	done < <(cat suites.all 2> /dev/null || true)
	((n)) || fTestSkip
}
case "${1:-}" in -h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${self}" | sed 's/^##	\{0,1\}//'; exit 0 ;; esac
(($# >= 1)) || { echo "usage: check-boxes.bash LINUX_BIN BOX|SSH_TARGET|BIN..." >&2; exit 2 ;}
linBin="$(realpath -- "$1")"; shift
[[ -f "${linBin}" ]] || { echo "check-boxes: no such file: ${linBin}" >&2; exit 2 ;}
for row in "$@"; do
	fRowWords "${row}" && [[ "${box}" =~ ^[A-Za-z0-9._-]+$ && -n "${target}" ]] || { echo "check-boxes: not BOX|SSH_TARGET|BIN[|suites[=LIST]][|perf]: ${row}" >&2; exit 2 ;}
	[[ "${bin}" != *.exe || "${suites}" != suites=* ]] || { echo "check-boxes: a Windows box runs win-runners.bash whole, so no LIST: ${row}" >&2; exit 2 ;}
	((perf == 0)) || [[ "${bin}" == *.exe ]] || { echo "check-boxes: perf runs on a Windows box only: ${row}" >&2; exit 2 ;}
done

vmState="${SHCL_VM_STATE:-${HOME}/synced/0-0/common/exec/util/linux/bash/claude_vm-state.bash}"
[[ -x "${vmState}" ]] || vmState="$(command -v claude_vm-state.bash || true)"
boxWait="${SHCL_BOX_WAIT:-900}"
[[ "${boxWait}" =~ ^[0-9]+$ ]] || boxWait=900

startDir="${PWD}"
work="$(mktemp -d)"; trap 'rm -rf -- "${work}"' EXIT
cd "${work}"
mkdir -p g/c
for d in "${root}"/project/conformance/*/; do cp -r "${d%/}" g/c/; done
fCases > g/cases.tsv
nCases="$(wc -l < g/cases.tsv)"
fDriver > g/run.sh
cp -r g h
cp "${linBin}" h/shcl
( cd h && env -i PATH=/usr/bin:/bin HOME=/ sh run.sh > rc.lst 2> /dev/null ) || fBad "the host run of the CLI cases failed"

fTest decyk each test box runs its release build like the Linux one
for row in "$@"; do
	fRowWords "${row}"
	want=""; case "${suites}" in suites) want=all ;; suites=*) want="${suites#suites=}" ;; esac
	[[ -z "${bin}" || "${bin}" == /* ]] || bin="${startDir}/${bin}"
	b="b_${box}"; mkdir -p "${b}/g" "${b}/back"
	if [[ ! -f "${bin}" ]]; then echo "SKIP ${box}: no release build for it"; continue; fi
	if [[ -z "${vmState}" ]]; then echo "SKIP ${box}: no claude_vm-state.bash, so no host lock"; continue; fi
	##	A Windows build means a Windows box, which runs the cases through
	##	box-cases.ps1, and win-runners.bash for its suites (2026103016433943).
	onBox=--on-box; exe=""; cmp=h; winRun=0
	if [[ "${bin}" == *.exe ]]; then
		onBox=--on-winbox; exe=.exe; cmp=hw
		if [[ -n "${want}" ]]; then winRun=1; want=""; fi
	fi
	cp -r g/. "${b}/g/"; cp "${bin}" "${b}/g/shcl${exe}"
	if [[ -n "${want}" ]]; then fSrcTree "${b}/g/src"; echo "${want}" > "${b}/g/want"; fi
	((winRun == 0)) || fSrcTree "${b}/g/src" "${winSrc[@]}"
	if ((perf)); then mkdir -p "${b}/g/p/include"; cp "${meDir}/perf-gate.bash" "${meDir}/cpu-time.ps1" "${b}/g/p/"; cp "${meDir}/include/test-id.bash" "${b}/g/p/include/"; fi
	tar -C "${b}/g" --format=pax -cf "${b}/in.tar" .
	SECONDS=0; wrapRc=0
	"${vmState}" wrap "${box}" --wait "${boxWait}" -- "${self}" "${onBox}" "${target}" "${work}/${b}/in.tar" "${work}/${b}" < /dev/null > "${b}/wrap.out" 2>&1 || wrapRc=$?
	status="$(cat -- "${b}/status" 2>/dev/null || true)"
	case "${status}" in
		ran) ;;
		skip\ *) echo "SKIP ${box}: ${status#skip }"; continue ;;
		fail\ *) fBad "${box}: ${status#fail }"; continue ;;
		*) echo "SKIP ${box}: not taken or not up (wrap exited ${wrapRc}: $(tail -n 1 "${b}/wrap.out"))"; continue ;;
	esac
	((wrapRc == 0)) || echo "check-boxes: ${box}: wrap exited ${wrapRc} after the run: $(tail -n 1 "${b}/wrap.out")" >&2
	if ! tar -C "${b}/back" -xf "${b}/out.tar" 2>/dev/null; then fBad "${box}: nothing came back"; continue; fi
	nRan+=1
	##	Windows words its own errors, "The system cannot find the file
	##	specified.", so there only the code in `(os error N)` is compared, as
	##	check-win-release does.
	if [[ "${cmp}" == hw ]]; then
		[[ -d hw ]] || { cp -r h hw; fOsErr hw/o; }
		fOsErr "${b}/back/o"
	fi
	nGot="$(grep -c ' rc ' "${b}/back/rc.lst" 2>/dev/null || true)"
	((nGot == nCases)) || fBad "${box}: ${nGot:-0} of ${nCases} CLI runs came back"
	diffIds="$( { diff "${cmp}/rc.lst" "${b}/back/rc.lst" | sed -n 's/^[<>] \([0-9]*\) rc .*/\1/p' || true
		diff -rq "${cmp}/o" "${b}/back/o" 2>/dev/null | grep -oE '[0-9]+\.[oe]( |$)' | sed 's/\.[oe] *$//'; } | sort -un || true)"
	nDiff=0; [[ -z "${diffIds}" ]] || nDiff="$(wc -l <<< "${diffIds}")"
	also="${suites:+ with the suites}"
	if ((perf)); then if [[ -n "${also}" ]]; then also+=" and perf-gate"; else also=" with perf-gate"; fi; fi
	awk -F'\t' 'NR == FNR { bad[$1] = 1; next } ($1 in bad) && shown++ < 5 { $1 = "    differs: " $1; print }' OFS=' ' - g/cases.tsv <<< "${diffIds}" >&2
	if ((nDiff)); then fBad "${box}: ${nDiff} of ${nCases} CLI runs differ from the Linux build"
	else echo "PASS ${box}: ${nCases} CLI runs, same bytes and exit codes as the Linux build (${SECONDS} s${also})"; fi
	if ((winRun)); then
		if [[ -f "${b}/back/s/rc" ]]; then echo "${box} $(cat "${b}/back/s/rc")" >> winrun.all
		else echo "${box} nothing came back" >> winrun.all; fi
	fi
	if ((perf)); then
		if [[ -f "${b}/back/s/perf.rc" ]]; then echo "${box} $(tr -d '\r' < "${b}/back/s/perf.rc")" >> perfrun.all
		else echo "${box} nothing came back" >> perfrun.all; fi
	fi
	if [[ -z "${want}" ]]; then :
	elif [[ -f "${b}/back/s/suites.lst" ]]; then sed "s/^/${box} /" "${b}/back/s/suites.lst" >> suites.all
	else for s in "${suiteNames[@]}"; do if fWants "${want}" "${s}"; then echo "${box} fail ${s} nothing came back"; fi; done >> suites.all; fi
done
if ((nRan == 0 && nBad == 0)); then fTestSkip; fi

fTest demxj each suites box builds the Rust binding and passes its tests
fSuiteRows rust
fTest demxk each suites box builds the Go binding and passes its tests
fSuiteRows go
fTest demxm each suites box passes the Python conformance suite
fSuiteRows python
fTest demxn each suites box builds the C binding and passes its conformance suite
fSuiteRows c
fTest demxp each suites box passes cli-regress over the CLIs it built
fSuiteRows cli
fTest den85 each Windows suites box passes win-runners.bash, winpath-regress.ps1 included
declare -i nWin=0
while read -r bx rest; do
	log="b_${bx}/back/s/win-runners.log"
	##	The box's own status lines, with its name, so each test ID is in the log.
	sed -nE "s/^(PASS|FAIL|SKIP) ([0-9a-z]{5}) /\1 \2 ${bx}: /p" "${log}" 2> /dev/null | tr -d '\r' || true
	case "${rest}" in
		0) echo "PASS ${bx}: win-runners.bash ($(grep -c '^\[ ' "${log}" 2> /dev/null) rows)"; nWin+=1 ;;
		skip\ *) echo "SKIP ${bx}: win-runners.bash, ${rest#skip }" ;;
		*) fBad "${bx}: win-runners.bash failed (${rest})"; nWin+=1
		   grep -vE '^(PASS|SKIP) |: OK$|^\[ |^$' "${log}" 2> /dev/null | tail -n 20 | tr -d '\r' | sed 's/^/    /' >&2 || true ;;
	esac
done < <(cat winrun.all 2> /dev/null || true)
((nWin)) || fTestSkip
fTest dep83 each perf box passes perf-gate over its release build
declare -i nPerf=0
while read -r bx rest; do
	log="b_${bx}/back/s/perf-gate.log"
	sed -nE "s/^(PASS|FAIL|SKIP) ([0-9a-z]{5}) /\1 \2 ${bx}: /p" "${log}" 2> /dev/null | tr -d '\r' || true
	case "${rest}" in
		0) echo "PASS ${bx}: perf-gate over its release build"; nPerf+=1 ;;
		skip\ *) echo "SKIP ${bx}: perf-gate, ${rest#skip }" ;;
		*) fBad "${bx}: perf-gate failed (${rest})"; nPerf+=1
		   grep -E '^perf-gate: ' "${log}" 2> /dev/null | tail -n 20 | tr -d '\r' | sed 's/^/    /' >&2 || true ;;
	esac
done < <(cat perfrun.all 2> /dev/null || true)
((nPerf)) || fTestSkip
fTestEnd

if ((nBad)); then
	echo "check-boxes: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-boxes: OK"

##	History:
##		2026-10-24  Created, for 2026102419263412.
##		2026-10-29  Box half takes ionice -c 3 where there is one, for 2026102421025788.
##		2026-10-30  A |suites row runs the 4 bindings' suites and cli-regress there, for 2026102419263417.
##		2026-10-30  |suites=LIST runs only those suites, for 2026102419263422.
##		2026-10-30  A Windows box runs the cases through box-cases.ps1, for 2026103016433921.
##		2026-10-31  A Windows box's |suites runs win-runners.bash there, for 2026103016433943.
##		2026-10-31  A Windows box's |perf runs perf-gate.bash there, for 2026103016433965.
