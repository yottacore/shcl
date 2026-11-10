#!/usr/bin/env bash

##	Purpose:
##		The filesystem property test of each binding (2026110616475901), on a
##		256 MB tmpfs made for the run and gone with it, then the cross-binding
##		check over the cases each one ran. Each binding's command gets
##		SHCL_FS_DIR, the folder its cases go in, and SHCL_FUZZ_DUMP, where it
##		writes fs/NAME-rows.tsv and fs/NAME-drawn.tsv. Every binding's fixed
##		rows must match the reference's line for line, and its drawn cases too,
##		over the seeds both ran.
##		The tmpfs, first route that works (2026111010012287):
##		  - SHCL_FS_TMPFS, when it names a tmpfs already mounted, as the
##		    container run's --mount is.
##		  - On Linux, a user namespace around each command, with the tmpfs
##		    mounted in it and the caller's own uid mapped back, so the read-bit
##		    cases run as the caller and not as root. It's gone when the command
##		    exits, so there's nothing to unmount.
##		  - Otherwise a plain folder in this script's temp folder, with a note:
##		    line. Never /dev/shm or the project tree.
##	Syntax:
##		fs-property.bash NAME|COMMAND [NAME|COMMAND ...]
##		  NAME|COMMAND  a binding's name and the command, run by bash from the
##		                tree root, that runs its filesystem property tests. The
##		                first is the reference.
##	Exit: 0 all passed and agree, 1 a test failed or the answers differ, 2 usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/safe-rm.bash"
testWhere=fs-property; testCounter=nBad

case "${1:-}" in -h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;; esac
(($#)) || { echo "usage: fs-property.bash NAME|COMMAND [NAME|COMMAND ...]" >&2; exit 2; }
for b in "$@"; do
	[[ "${b}" == ?*'|'?* ]] || { echo "fs-property: not NAME|COMMAND: ${b}" >&2; exit 2; }
done

work=''; fSafeTmpDir work; trap 'fSafeRm "${work}"' EXIT
dump="${work}/dump"; mkdir "${dump}"
fsSize=256m

## The route, and the words for it in the run's log.
fsDir=""; fsRoute=""; fsWhy=""; fsWrap=()
fIsTmpfs(){   ## fIsTmpfs DIR -> 0 when DIR is a tmpfs mount point
	local mnt type rest
	[[ -r /proc/self/mounts ]] || return 1
	while read -r _ mnt type rest; do
		if [[ "${mnt}" == "$1" && "${type}" == tmpfs ]]; then return 0; fi
	done < /proc/self/mounts
	return 1
}
if [[ -n "${SHCL_FS_TMPFS:-}" ]]; then
	if fIsTmpfs "${SHCL_FS_TMPFS}"; then fsDir="${SHCL_FS_TMPFS}"; fsRoute="the run's tmpfs"
	else echo "note: SHCL_FS_TMPFS names ${SHCL_FS_TMPFS}, which isn't a tmpfs here"; fi
fi
if [[ -z "${fsDir}" && "$(uname -s)" == Linux ]]; then
	if ! command -v unshare > /dev/null; then
		fsWhy="there's no unshare"
	else
		mkdir "${work}/fs"
		## The outer namespace makes the mount, as its root, and the inner one
		## gives the command back the caller's uid and gid.
		# shellcheck disable=SC2016  ## run by the sh in the namespace
		fsWrap=(unshare -Urm sh -c 'd="$1" s="$2" u="$3" g="$4"; shift 4; mount -t tmpfs -o "size=${s}" shcl-fs "${d}" && exec unshare "--map-user=${u}" "--map-group=${g}" -- "$@"' \
			sh "${work}/fs" "${fsSize}" "$(id -u)" "$(id -g)")
		# shellcheck disable=SC2016  ## run by the sh in the namespace
		if probe="$("${fsWrap[@]}" sh -c 'stat -f -c %T "$1"; id -u' sh "${work}/fs" 2>&1)" && [[ "${probe}" == "tmpfs"$'\n'"$(id -u)" ]]; then
			fsDir="${work}/fs"; fsRoute="a tmpfs in a user namespace for each binding"
		else
			fsWrap=()
			fsWhy="a user namespace with a tmpfs failed: $(head -1 <<< "${probe}")"
		fi
	fi
fi
if [[ -z "${fsDir}" ]]; then
	fsDir="${work}/plain"; mkdir "${fsDir}"
	echo "note: no tmpfs for the filesystem cases (${fsWhy:-none of the routes is for $(uname -s)}), so they go in ${fsDir}, a plain folder"
else
	echo "fs property: cases on ${fsRoute}, ${fsSize}, at ${fsDir}"
fi

declare -i nBad=0
names=()
for b in "$@"; do
	name="${b%%|*}"; cmd="${b#*|}"; names+=("${name}")
	echo "fs property: ${name}: ${cmd}"
	## The folder's type, as the command sees it, ahead of the command.
	rc=0
	# shellcheck disable=SC2016  ## run by bash in the route's wrapper
	env SHCL_FS_DIR="${fsDir}" SHCL_FUZZ_DUMP="${dump}" ${fsWrap[@]+"${fsWrap[@]}"} \
		bash -c 'printf "%s\n" "$(stat -f -c %T "${SHCL_FS_DIR}" 2> /dev/null || echo unknown)" > "${SHCL_FUZZ_DUMP}/$2.fstype"; eval "$1"' bash "${cmd}" "${name}" || rc=$?
	if ((rc != 0)); then echo "fs property: ${name} failed, exit ${rc}" >&2; nBad+=1; fi
done
## A failed run's dump is short or missing, so the compare would only repeat it.
((nBad == 0)) || exit 1

fTest df4ch the filesystem cases ran on a tmpfs made for the run
for name in "${names[@]}"; do
	got="$(cat "${dump}/${name}.fstype" 2> /dev/null || echo none)"
	if [[ -n "${fsWrap[*]:-}" || "${fsDir}" == "${SHCL_FS_TMPFS:-/nonesuch}" ]]; then
		if [[ "${got}" != tmpfs ]]; then echo "fs property: ${name}'s cases went on ${got}, not a tmpfs" >&2; nBad+=1; fi
	else
		fTestSkip
	fi
done

ref="${names[0]}"
fTest df4cf every binding gives the reference\'s answer on each fixed filesystem row
for name in "${names[@]:1}"; do
	a="${dump}/fs/${ref}-rows.tsv"; b="${dump}/fs/${name}-rows.tsv"
	if [[ ! -s "${a}" || ! -s "${b}" ]]; then echo "fs property: no rows from $([[ -s "${a}" ]] && echo "${name}" || echo "${ref}")" >&2; nBad+=1; continue; fi
	if ! cmp -s "${a}" "${b}"; then
		echo "fs property: ${name}'s rows differ from ${ref}'s, first at:" >&2
		diff "${a}" "${b}" | head -4 >&2 || true
		nBad+=1
	fi
done
fTest df4cg every binding gives the reference\'s answer on each drawn filesystem case both ran
for name in "${names[@]:1}"; do
	a="${dump}/fs/${ref}-drawn.tsv"; b="${dump}/fs/${name}-drawn.tsv"
	if [[ ! -s "${a}" || ! -s "${b}" ]]; then echo "fs property: no drawn cases from $([[ -s "${a}" ]] && echo "${name}" || echo "${ref}")" >&2; nBad+=1; continue; fi
	na="$(wc -l < "${a}")"; nb="$(wc -l < "${b}")"; n=$((na < nb ? na : nb))
	if ! cmp -s <(head -n "${n}" "${a}") <(head -n "${n}" "${b}"); then
		echo "fs property: ${name}'s drawn cases differ from ${ref}'s, first at:" >&2
		diff <(head -n "${n}" "${a}") <(head -n "${n}" "${b}") | head -4 >&2 || true
		nBad+=1
	else
		echo "fs property: ${name} agrees with ${ref} on ${n} drawn cases"
	fi
done
fTestEnd
((nBad == 0)) || exit 1
exit 0


##	History:
##		- 2026-11-10 JC: Created.
