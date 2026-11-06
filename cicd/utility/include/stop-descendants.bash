#!/usr/bin/env bash

##	Purpose:
##		Stops what a script started before its EXIT trap takes away the files
##		those processes use (2026101920461153). A TERM to the script's PID alone
##		leaves its children running: a `docker run` and its container went on
##		for 2 minutes over a frozen copy and a temp dir already gone. Sourced by
##		cicd.bash and the gates that run their tools in the image.
##	Functions:
##		fStopDescendants   TERM every process under this shell, wait up to
##		                   SHCL_STOP_WAIT seconds (30) for them to go, then
##		                   KILL the rest. A container named in a file listed in
##		                   stop_cidfiles that's still running is then killed by
##		                   docker, since a KILLed `docker run` leaves it up.
##		                   A docker client passes the TERM to its container and
##		                   waits for it, so most stops never get that far.
##		                   A PID in stop_keep is passed over, with what it
##		                   started, such as the tee a script logs through.
##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## Container ID files, from --cidfile. The caller removes one once its run ends.
declare -a stop_cidfiles=() stop_keep=()

## Alive, and not a zombie waiting for its parent to reap it.
fStopAlive(){
	local line=""
	{ read -r line < "/proc/$1/stat"; } 2>/dev/null || return 1
	line="${line##*) }"
	[[ "${line:0:1}" != [ZX] ]]
}

## Builtins only, so the walk itself starts no process that would be on the list.
fStopDescendants(){
	local f line pid ppid wait="${SHCL_STOP_WAIT:-30}" engine="${SHCL_DOCKER:-docker}" cid="" i=0 left=0
	local -A kids=() keep=()
	local -a todo=() found=()
	## A subshell running a trap it took with it isn't the script.
	[[ "${BASHPID}" == "$$" && -d /proc/self ]] || return 0
	for f in /proc/[0-9]*/stat; do
		{ read -r line < "${f}"; } 2>/dev/null || continue
		pid="${f#/proc/}"; pid="${pid%/stat}"
		## The name in parens can hold spaces, so the fields start after its last ')'.
		line="${line##*) }"; line="${line#* }"; ppid="${line%% *}"
		kids["${ppid}"]+=" ${pid}"
	done
	for pid in "${stop_keep[@]}"; do keep["${pid}"]=1; done
	todo=($$)
	while ((${#todo[@]})); do
		pid="${todo[0]}"; todo=("${todo[@]:1}")
		for f in ${kids[${pid}]:-}; do
			if [[ -z "${keep[${f}]:-}" ]]; then found+=("${f}"); todo+=("${f}"); fi
		done
	done
	if ((${#found[@]})); then
		kill -TERM "${found[@]}" 2>/dev/null || true
		for ((i = 0; i < wait * 5; i++)); do
			left=0
			for pid in "${found[@]}"; do if fStopAlive "${pid}"; then left=$((left + 1)); fi; done
			((left)) || break
			sleep 0.2 || true
		done
		if ((left)); then
			for pid in "${found[@]}"; do if fStopAlive "${pid}"; then kill -KILL "${pid}" 2>/dev/null || true; fi; done
		fi
		printf '[ cleanup: stopped %s process(es) the run left%s ]\n' "${#found[@]}" "$( ((left)) && echo ", ${left} by KILL after ${wait} s")" >&2
	fi
	for f in "${stop_cidfiles[@]}"; do
		cid=""; { read -r cid < "${f}"; } 2>/dev/null || true
		if [[ -n "${cid}" ]]; then
			"${engine}" kill "${cid}" >/dev/null 2>&1 && echo "[ cleanup: killed container ${cid:0:12} ]" >&2 || true
		fi
	done
	stop_cidfiles=()
	return 0
}


##	History:
##		- 2026-10-21 JC: Created, for a run stopped by a TERM to its PID.
