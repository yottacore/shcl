#!/usr/bin/env bash

##	Purpose:
##		shcl.go is meant to be copied into another program on its own, and the
##		lint stage's vet only sees the host's GOOS. So this builds shcl.go alone,
##		in a module of its own, for one 64-bit arch of every GOOS Go has, and
##		vets the Go CLI for the same list. beta1 failed on js and wasip1 for a
##		syscall constant they don't have (2026110611562400). plan9 is left out:
##		its syscall package has none of the errno names the write status reads.
##		32-bit targets are out of scope, and the version cap doesn't fit there.
##	Syntax:
##		check-go-alone.bash
##		  CPU_CAP     GOMAXPROCS for the go calls (default half the cores)
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
testWhere=check-go-alone; testCounter=nBad
declare -i nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/safe-rm.bash"

fBad(){ echo "check-go-alone: $1" >&2; nBad+=1 ;}
case "${1:-}" in -h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed 's/^##	\{0,1\}//'; exit 0 ;; esac
(($# == 0)) || { echo "usage: check-go-alone.bash" >&2; exit 2 ;}
jobs="${CPU_CAP:-}"
# shellcheck source-path=SCRIPTDIR
[[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || { source "${meDir}/include/cpu-cap.bash"; fCpuCap; jobs="${CPU_CAP}"; }
export GOMAXPROCS="${jobs}"
##	android and ios link only through cgo, and go vet refuses them without it.
fCgo(){ case "${1%/*}" in android|ios) echo 1 ;; *) echo 0 ;; esac ;}

if command -v go >/dev/null 2>&1; then
	##	The first 64-bit arch go lists for each GOOS.
	mapfile -t targets < <(go tool dist list | awk -F/ '$1 != "plan9" && $2 !~ /^(386|arm|mips|mipsle)$/ && !seen[$1]++')
	((${#targets[@]} >= 10)) || fBad "go tool dist list gave only ${#targets[@]} targets"
	work=''; fSafeTmpDir work
	trap 'fSafeRm "${work}"' EXIT
	mkdir "${work}/lib"
	cp "${root}/source/go/shcl.go" "${work}/lib/"
	printf 'module shclalone\n\ngo 1.20\n' > "${work}/lib/go.mod"

	fTest deyvc shcl.go builds alone for every GOOS but plan9
	for t in "${targets[@]}"; do
		out="$(cd "${work}/lib" && CGO_ENABLED="$(fCgo "${t}")" GOOS="${t%/*}" GOARCH="${t#*/}" go vet . 2>&1)" || fBad "${t}: $(head -n 3 <<< "${out}" | tr '\n' ' ')"
	done

	##	A main package for android or ios needs that system's C headers, and
	##	nobody runs the CLI there, so those two check only the library.
	fTest deyvd the Go CLI builds for every GOOS but plan9, android and ios
	for t in "${targets[@]}"; do
		case "${t%/*}" in android|ios) continue ;; esac
		out="$(cd "${root}/source/go/cmd" && CGO_ENABLED=0 GOOS="${t%/*}" GOARCH="${t#*/}" go vet ./shcl 2>&1)" || fBad "${t}: $(head -n 3 <<< "${out}" | tr '\n' ' ')"
	done
	##	The CLI keeps its own copy of the flag table, and only the library's is
	##	tested against syscall.O_NONBLOCK.
	fBody(){ sed -n '/^func noWaitFlag() int {$/,/^}$/p' "$1" ;}
	libBody="$(fBody "${root}/source/go/shcl.go")"
	[[ -n "${libBody}" && "${libBody}" == "$(fBody "${root}/source/go/cmd/shcl/main.go")" ]] || fBad "noWaitFlag in cmd/shcl/main.go is missing or differs from shcl.go's"
	((nBad)) || echo "check-go-alone: ${#targets[@]} targets: ${targets[*]}"
else
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then fBad "needs go, and the gate requires it"; fi
	echo "check-go-alone: skipping (no go)"
	echo check-go-alone >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkipBlock
fi
fTestEnd

if ((nBad)); then
	echo "check-go-alone: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-go-alone: OK"

##	History:
##		2026-11-06  Created, for 2026110611562400.
