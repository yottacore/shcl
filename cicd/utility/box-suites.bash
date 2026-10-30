#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  ## the suite commands are single-quoted on purpose, for eval, and use cFlags there

##	Purpose:
##		Runs on a test box, from a copy of the source tree check-boxes.bash sent
##		there: builds the 4 bindings with that box's own toolchains and runs
##		their conformance suites, then cli-regress over the compiled CLIs that
##		built (2026102419263417). A suite whose tool the box lacks is skipped.
##		Everything it writes stays under OUT_DIR and the tree's parent, which
##		the box half removes after.
##	Syntax:
##		box-suites.bash OUT_DIR   run from the tree's root
##		  OUT_DIR/suites.lst      one line per suite: "pass NAME SECS s", "fail
##		                          NAME exit RC, SECS s" or "skip NAME WHY"
##		  OUT_DIR/NAME.log        each suite's output
##	Exit: 0, whatever the suites did; the list says how each went.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -uo pipefail

out="${1:?OUT_DIR}"; mkdir -p "${out}" || exit 2
scratch="$(cd -- .. && pwd)"

##	The same cap rule as the build box, from this box's CPU count and load:
##	half the CPUs, a quarter when the 1-minute load is over half, never under 1.
nCpu="$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 1)"
load="$(uptime | sed -E 's/.*load averages?: *([0-9]+).*/\1/')"
[[ "${nCpu}" =~ ^[0-9]+$ ]] || nCpu=1
[[ "${load}" =~ ^[0-9]+$ ]] || load=0
cap=$((nCpu / 2)); ((load * 2 > nCpu)) && cap=$((nCpu / 4)); ((cap >= 1)) || cap=1
export CPU_CAP="${cap}" CARGO_BUILD_JOBS="${cap}" RUST_TEST_THREADS="${cap}" GOMAXPROCS="${cap}" RAYON_NUM_THREADS="${cap}"
export TMPDIR="${scratch}/t" CARGO_HOME="${scratch}/cargo-home" GOCACHE="${scratch}/go-cache" GOPATH="${scratch}/go-path"
export GOFLAGS=-modcacherw GOTOOLCHAIN=local GOTELEMETRY=off PYTHONDONTWRITEBYTECODE=1 SHCL_FUZZ_ITERS=20000
mkdir -p "${TMPDIR}"

cFlags=(-std=c11 -O2 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -Isource/c)
clis=()

##	fSuite NAME TOOL CLI_NAME CLI_PATH COMMAND: runs COMMAND when TOOL is here,
##	and adds the binding's CLI for cli-regress once it's built, pass or fail.
fSuite(){
	local name="$1" tool="$2" cliName="$3" cliPath="$4" cmd="$5" rc=0 t0="${SECONDS}"
	if ! command -v "${tool}" > /dev/null 2>&1; then echo "skip ${name} no ${tool} on the box" >> "${out}/suites.lst"; return 0; fi
	( eval "${cmd}" ) > "${out}/${name}.log" 2>&1 || rc=$?
	if [[ "${cliPath}" != - && -x "${cliPath}" ]]; then clis+=("${cliName}|${cliPath}"); fi
	if ((rc)); then echo "fail ${name} exit ${rc}, $((SECONDS - t0)) s" >> "${out}/suites.lst"; return 0; fi
	echo "pass ${name} $((SECONDS - t0)) s" >> "${out}/suites.lst"
}

fSuite rust cargo rust source/rust/target/debug/shcl \
	'cargo build --locked --manifest-path source/rust/Cargo.toml && cargo test --locked --manifest-path source/rust/Cargo.toml'
fSuite go go go source/go/shcl \
	'go -C source/go/cmd build -o ../shcl ./shcl && go -C source/go test -count=1 && go -C source/go/cmd test -count=1 ./...'
##	No Python CLI for cli-regress here: it starts an interpreter per call, which
##	held about 270 s of the box's 290 s of cli-regress on vmFreeBSD, and its
##	conformance suite still runs.
fSuite python python3 - - \
	'python3 -X dev -W error::ResourceWarning source/python/tests/conformance.py'
fSuite c cc c source/c/shcl \
	'cc "${cFlags[@]}" source/c/cmd/shcl/main.c -o source/c/shcl -lm && cc "${cFlags[@]}" source/c/tests/conformance.c -o "${TMPDIR}/cconf" -lm -lpthread && "${TMPDIR}/cconf" project/conformance'
if ((${#clis[@]} == 0)); then echo "skip cli no binding CLI built" >> "${out}/suites.lst"
else fSuite cli bash - - 'bash cicd/utility/cli-regress.bash "${clis[@]}"'; fi
exit 0

##	History:
##		2026-10-30  Created, for 2026102419263417.
