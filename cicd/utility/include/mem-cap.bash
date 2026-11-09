#!/usr/bin/env bash

##	Purpose:
##		The memory cap for a run and the containers it starts, worked out in
##		one place. On 2026-11-08 another project's analyzer container took 67 GB
##		plus 18 GB of swap on b23, and the box's OOM guard killed the desktop
##		session instead, so a run caps itself, with no swap, and goes first
##		when the box runs short. A step killed at the cap exits 137.
##			fMemCap              set memCap from CICD_MEM_CAP, or the default;
##			                     says why and returns 1 for anything else
##			fMemCtrArgs ARRAY    fill ARRAY with the docker run args for the
##			                     cap, or none for CICD_MEM_CAP=none
##			fMemScope SCRIPT [ARG...]
##			                     run SCRIPT again under a systemd user scope at
##			                     the cap, once per run, when one can be had here
##		CICD_MEM_CAP is a docker size such as 24g, or none for no cap. The
##		default is a third of MemTotal, from 4g to 32g. No step was over 24 GB
##		in the 2 weeks to 2026-11-09 (the build peaked at 13.7 GB, the C
##		analyzers at 12.4 GB), so none takes the higher default of 48g.
##		SHCL_SYSTEMD_RUN names another systemd-run, for a test.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


memCap="${memCap:-}"

## The value is only ever matched, never used in arithmetic, so x[$(cmd)]
## runs nothing.
fMemCap(){
	local cap="${CICD_MEM_CAP:-}" kb
	memCap=""
	if [[ -z "${cap}" ]]; then
		kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
		[[ "${kb}" =~ ^[0-9]{1,15}$ ]] || kb=0
		cap=$(( kb / 3 / 1048576 ))
		if (( cap > 32 )); then cap=32; fi
		if (( cap < 4 )); then cap=4; fi
		cap="${cap}g"
	fi
	if [[ "${cap}" != none && ! "${cap}" =~ ^[1-9][0-9]{0,14}[kmg]?$ ]]; then
		printf "CICD_MEM_CAP='%s' isn't a size such as 24g, or none\n" "${cap}" >&2
		return 1
	fi
	memCap="${cap}"
}

## No swap, and the OOM killer takes the container first.
# shellcheck disable=SC2034  ## a nameref, read by the caller
fMemCtrArgs(){
	local -n out_m5q="$1"
	out_m5q=()
	fMemCap || return 1
	[[ "${memCap}" == none ]] || out_m5q=(--memory "${memCap}" --memory-swap "${memCap}" --oom-score-adj 1000)
}

## A docker container is dockerd's child, not this scope's, so fMemCtrArgs
## caps those. A hosted runner, or a box with no user systemd (macOS, FreeBSD,
## a container), runs as before. Call fMemCap first.
fMemScope(){
	local sdRun="${SHCL_SYSTEMD_RUN:-systemd-run}"
	[[ -z "${SHCL_MEM_SCOPED:-}" ]] || return 0
	export SHCL_MEM_SCOPED=none
	if [[ "${memCap}" == none || -n "${GITHUB_ACTIONS:-}" ]]; then return 0; fi
	if ! command -v "${sdRun}" >/dev/null 2>&1 || ! command -v choom >/dev/null 2>&1; then return 0; fi
	"${sdRun}" --user --scope --quiet true >/dev/null 2>&1 || return 0
	SHCL_MEM_SCOPED="${memCap}"
	exec "${sdRun}" --user --scope --quiet -p "MemoryMax=${memCap^^}" -p MemorySwapMax=0 choom -n 1000 -- bash "$@"
}

##	History:
##		- 20261109: Created, for a memory cap with no swap on the run and on
##		  each container it starts.
