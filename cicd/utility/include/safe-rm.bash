#!/usr/bin/env bash

##	Purpose:
##		The one way a pipeline script takes a folder down. A fresh clone or
##		another box has no copy of the guard by hand, so this is the repo's own,
##		per the shared Safe removal rule. Sourced by cicd.bash.
##	Functions:
##		fSafeRm PATH            remove PATH, somewhere under a folder named tmp
##		                        or under ${HOST_TEMP}/${projectName}, never that
##		                        project folder or ${HOST_TEMP} itself
##		fSafeRmUnder PARENT PATH  remove PATH, strictly under PARENT, for a
##		                        build folder in the repo
##	The caller sets HOST_TEMP, resolved with realpath once, and projectName.
##	Both refuse an empty path, .., //, a newline, a link, a path through a link
##	and one that isn't there, and stay on one filesystem. PARENT itself may sit
##	behind a link.
##	History: At bottom of script.

##	Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


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
	real="$(realpath -e -- "${p}" 2> /dev/null)" || { printf 'safe-rm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${p}" ]]; then printf 'safe-rm: refused, goes through a link: %s\n' "${p}" >&2; return 1; fi
	rm -rf --one-file-system -- "${p}"
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
	topReal="$(realpath -e -- "${top}" 2> /dev/null)" || { printf 'safe-rm: refused, not there: %s\n' "${top}" >&2; return 1; }
	real="$(realpath -e -- "${p}" 2> /dev/null)" || { printf 'safe-rm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${topReal}/${p#"${top}"/}" ]]; then printf 'safe-rm: refused, goes through a link: %s\n' "${p}" >&2; return 1; fi
	rm -rf --one-file-system -- "${p}"
}


##	History:
##		- 2026-10-31 JC: Created, from the shared guard, for the run folder and the
##		  repo's build folders (2026103114555299).
