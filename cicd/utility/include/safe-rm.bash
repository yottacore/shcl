#!/usr/bin/env bash

##	Purpose:
##		The one way a pipeline script takes a folder down. A fresh clone or
##		another box has no copy of the guard by hand, so this is the repo's own,
##		per the shared Safe removal rule. Sourced by cicd.bash, the pre-push
##		hook and the gate scripts, some of which run on macOS, BSD and Windows
##		boxes, so it needs no GNU realpath or rm.
##	Functions:
##		fSafeRm PATH            remove PATH, somewhere under a folder named tmp
##		                        or under ${HOST_TEMP}/${projectName}, never that
##		                        project folder or ${HOST_TEMP} itself
##		fSafeRmUnder PARENT PATH  remove PATH, strictly under PARENT, for a
##		                        build folder in the repo
##		fSafeRmUnder_IfThere PARENT PATH  the same, and nothing to do when
##		                        PATH isn't there
##		fSafeTmpDir VAR         make a gate script's scratch folder and put its
##		                        path in VAR: inside the run's folder in a run,
##		                        a run folder of its own when run by hand
##	The caller sets HOST_TEMP, resolved with realpath once, and projectName,
##	or calls fSafeTmpDir first, which does both.
##	Both refuse an empty path, .., //, a newline, a link, a path through a link
##	and one that isn't there, and stay on one filesystem. PARENT itself may sit
##	behind a link.
##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## realpath -e, which macOS and BSD don't have. The caller has refused a link.
## No bare return: in an EXIT trap it hands back the status the script exited with.
__fSafeRmReal(){
	local d=''
	[[ -e "${1}" ]] || return 1
	if [[ -d "${1}" ]]; then
		(CDPATH='' cd -P -- "${1}" 2> /dev/null && pwd -P)
	else
		d="${1%/*}"; d="$(CDPATH='' cd -P -- "${d:-/}" 2> /dev/null && pwd -P)" || return 1
		printf '%s/%s\n' "${d%/}" "${1##*/}"
	fi
}
## One filesystem: GNU rm, and BSD's -x.
__safeRmOneFs=(--one-file-system)
if ! rm --version > /dev/null 2>&1; then
	case "$(uname -s 2> /dev/null)" in Darwin|*BSD|DragonFly) __safeRmOneFs=(-x) ;; *) __safeRmOneFs=() ;; esac
fi

fSafeRm(){
	local p="${1:-}" real='' own="${HOST_TEMP:?}/${projectName:?}"
	if [[ "${#}" -ne 1 || -z "${p}" || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'safe-rm: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	p="${p%/}"
	if ! [[ "${p}" =~ ^/(.+/)?tmp/[^/]+(/[^/]+)*$ || "${p}" == "${own}"/?* ]]; then
		printf 'safe-rm: refused, not under a tmp folder: %s\n' "${p}" >&2; return 1
	fi
	if [[ "${p}" == "${HOST_TEMP}" || ( "${p}" == "${HOST_TEMP}"/* && "${p#"${HOST_TEMP}"/}" != */* ) ]]; then
		printf 'safe-rm: refused, a whole project temp folder: %s\n' "${p}" >&2; return 1
	fi
	if [[ -L "${p}" ]]; then printf 'safe-rm: refused, a link: %s\n' "${p}" >&2; return 1; fi
	real="$(__fSafeRmReal "${p}")" || { printf 'safe-rm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${p}" ]]; then printf 'safe-rm: refused, goes through a link: %s\n' "${p}" >&2; return 1; fi
	rm -rf ${__safeRmOneFs[@]+"${__safeRmOneFs[@]}"} -- "${p}"
}

## Same checks, with the one parent named by the caller in place of the tmp rule.
fSafeRmUnder(){
	local top="${1:-}" p="${2:-}" real='' topReal=''
	if [[ "${#}" -ne 2 || -z "${p}" || "${top}" != /?* || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'safe-rm: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	p="${p%/}"; top="${top%/}"
	if [[ "${p}" != "${top}"/?* ]]; then printf 'safe-rm: refused, not under %s: %s\n' "${top}" "${p}" >&2; return 1; fi
	if [[ -L "${p}" ]]; then printf 'safe-rm: refused, a link: %s\n' "${p}" >&2; return 1; fi
	## The parent may sit behind a link, as a checkout often does, but nothing below it.
	topReal="$(__fSafeRmReal "${top}")" || { printf 'safe-rm: refused, not there: %s\n' "${top}" >&2; return 1; }
	real="$(__fSafeRmReal "${p}")" || { printf 'safe-rm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${topReal}/${p#"${top}"/}" ]]; then printf 'safe-rm: refused, goes through a link: %s\n' "${p}" >&2; return 1; fi
	rm -rf ${__safeRmOneFs[@]+"${__safeRmOneFs[@]}"} -- "${p}"
}

fSafeRmUnder_IfThere(){
	if [[ -e "${2:-}" || -L "${2:-}" ]]; then fSafeRmUnder "$@"; fi
}

## Not in a $(...): it sets HOST_TEMP and projectName for the fSafeRm after it.
## The odd suffix keeps the locals off the caller's variable name.
## A folder of its own gets a run.pid, so a killed script's is swept like a run's.
fSafeTmpDir(){
	local d_q8z='' n_q8z stamp_q8z=''
	[[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "fSafeTmpDir: bad variable name '${1:-}'" >&2; return 1; }
	projectName="${projectName:-shcl}"
	HOST_TEMP="${HOST_TEMP:-${TMPDIR:-/tmp}}"
	if [[ "${HOST_TEMP}" != /* ]]; then HOST_TEMP=/tmp; fi
	if ! mkdir -p -- "${HOST_TEMP}/${projectName}" 2>/dev/null || ! HOST_TEMP="$(__fSafeRmReal "${HOST_TEMP}")"; then
		echo "could not make ${HOST_TEMP}/${projectName}" >&2; return 1
	fi
	export HOST_TEMP
	if [[ "${TMPDIR:-}" == "${HOST_TEMP}/${projectName}"/?* && -d "${TMPDIR}" && ! -L "${TMPDIR%/}" ]]; then
		d_q8z="$(mktemp -d "${TMPDIR%/}/tmp.XXXXXXXXXX")" || return 1
	else
		stamp_q8z="$(date +%Y%m%d-%H%M%S)"
		for ((n_q8z = 1; n_q8z < 1000; n_q8z++)); do
			printf -v d_q8z '%s/%s/%s_%03d' "${HOST_TEMP}" "${projectName}" "${stamp_q8z}" "${n_q8z}"
			if mkdir -- "${d_q8z}" 2>/dev/null; then break; fi
			d_q8z=''
		done
		[[ -n "${d_q8z}" ]] || { echo "could not make a folder under ${HOST_TEMP}/${projectName}" >&2; return 1; }
		echo "$$" > "${d_q8z}/run.pid"
		export TMPDIR="${d_q8z}" TEMP="${d_q8z}" TMP="${d_q8z}"
	fi
	printf -v "${1}" '%s' "${d_q8z}"
}


##	History:
##		- 2026-10-31 JC: Created, from the shared guard, for the run folder and the
##		  repo's build folders (2026103114555299).
##		- 2026-10-31 JC: fSafeTmpDir and fSafeRmUnder_IfThere, for the hook and
##		  the gate scripts (2026103114560029).
