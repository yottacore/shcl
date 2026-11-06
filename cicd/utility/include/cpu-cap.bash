#!/usr/bin/env bash

##	Purpose:
##		The job count for a step, worked out in one place (2026102421025778):
##		half the CPUs, or a quarter when the step is hard or the box is busy,
##		never under 1. Busy means the 1-minute load is over half the CPU count.
##			fCpuCap [hard]   set and export CPU_CAP, and the thread knobs the
##			                 tools read, for the next step
##		cpuCount, cpuLoad (in hundredths) and cpuWhy say what it went by.
##		SHCL_CPU_FIXED, a count the run's caller gave as CPU_CAP, wins over all
##		of it, as on a hosted runner with nothing else on it.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


cpuCount=0; cpuLoad=0; cpuWhy=""
## A test points this at a file of its own.
cpuLoadFile="${cpuLoadFile:-/proc/loadavg}"

fCpuCount(){
	local n=''
	n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
	[[ "${n}" =~ ^[1-9][0-9]*$ ]] || n=2
	printf '%s' "${n}"
}

## In hundredths, so the compare stays in integers. 0 when no source answers,
## which reads as idle.
fCpuLoad(){
	local l='' whole frac
	if [[ -r "${cpuLoadFile}" ]]; then read -r l _ < "${cpuLoadFile}"
	else l="$(sysctl -n vm.loadavg 2>/dev/null || true)"; l="${l#\{ }"; l="${l%% *}"
	fi
	[[ "${l}" =~ ^([0-9]+)(\.([0-9]*))?$ ]] || { printf 0; return 0; }
	whole="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]}00"
	printf '%s' "$(( 10#${whole} * 100 + 10#${frac:0:2} ))"
}

fCpuCap(){
	local hard="${1:-}" cap
	cpuCount="$(fCpuCount)"; cpuLoad="$(fCpuLoad)"; cpuWhy=""
	if [[ "${SHCL_CPU_FIXED:-}" =~ ^[1-9][0-9]*$ ]]; then
		cap="${SHCL_CPU_FIXED}"; cpuWhy="given"
	else
		cap=$(( cpuCount / 2 ))
		if [[ -n "${hard}" ]]; then cpuWhy="hard step"
		elif (( cpuLoad > cpuCount * 50 )); then cpuWhy="busy"
		fi
		if [[ -n "${cpuWhy}" ]]; then cap=$(( cpuCount / 4 )); fi
		if (( cap < 1 )); then cap=1; fi
	fi
	CPU_CAP="${cap}"
	export CPU_CAP CARGO_BUILD_JOBS="${cap}" RUST_TEST_THREADS="${cap}" GOMAXPROCS="${cap}" RAYON_NUM_THREADS="${cap}"
}

##	History:
##		- 20261024: Created, from the half-the-cores cap cicd.bash and each gate
##		  script worked out on their own.
