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
##		  - On macOS, a 256 MB RAM disk from hdiutil, HFS+ and so blind to case
##		    as the case rows need, mounted on a folder here and detached at the
##		    end (2026111010331517).
##		  - On FreeBSD, a tmpfs mounted on a folder here and unmounted at the
##		    end, where the box lets this user mount one (root, or
##		    vfs.usermount=1).
##		  - On Windows, a folder in the temp folder, as TEMP spells it, so a
##		    short-name TEMP reaches the cases. No note: line, since that's the
##		    route.
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

## What the route made outside the work folder, or mounted in it, for
## fFsDown. A mount has to go before the folder under it can.
fsMnt=""; fsDev=""; fsWinTop=""; fsWinDir=""
fFsDown(){
	if [[ -n "${fsMnt}" ]]; then umount "${fsMnt}" 2> /dev/null || echo "fs property: couldn't unmount ${fsMnt}" >&2; fi
	if [[ -n "${fsDev}" ]]; then hdiutil detach "${fsDev}" > /dev/null 2>&1 || hdiutil detach -force "${fsDev}" > /dev/null 2>&1 || echo "fs property: couldn't detach ${fsDev}" >&2; fi
	if [[ -n "${fsWinDir}" ]]; then fSafeRmUnder_IfThere "${fsWinTop}" "${fsWinDir}" || true; fi
	fsMnt=""; fsDev=""; fsWinDir=""
}
osName="$(uname -s)"
## mount, umount and newfs_hfs live in /sbin there, which a box's PATH can lack.
case "${osName}" in Darwin|FreeBSD) PATH="${PATH}:/sbin:/usr/sbin" ;; esac
## The Windows temp folder as TEMP spells it, short name and all, taken before
## fSafeTmpDir points TEMP at a work folder spelled out long.
case "${osName}" in MINGW*|MSYS*|CYGWIN*) fsWinTop="${TEMP:-${TMP:-}}"; [[ -z "${fsWinTop}" ]] || fsWinTop="$(cygpath -u "${fsWinTop}")"; fsWinTop="${fsWinTop%/}" ;; esac
work=''; fSafeTmpDir work; trap 'fFsDown; fSafeRm "${work}"' EXIT
dump="${work}/dump"; mkdir "${dump}"
fsSize=256m

## The type of the filesystem DIR is on, from GNU stat, else from the mount
## table where DIR is a mount point, else "unknown".
fFsType(){
	local t
	if t="$(stat -f -c %T "$1" 2> /dev/null)" && [[ -n "${t}" ]]; then echo "${t}"; return 0; fi
	t="$(mount 2> /dev/null | awk -v on=" on $1 (" 'i = index($0, on) { s = substr($0, i + length(on)); sub(/[,)].*/, "", s); print s; exit }')" || t=""
	echo "${t:-unknown}"
}

## The route, the words for it in the run's log, and the type its folder has
## to be on for df4ch, empty where it's not a mount made for the run.
fsDir=""; fsRoute=""; fsWhy=""; fsWrap=(); fsWant=""; fsWin=0
fIsTmpfs(){   ## fIsTmpfs DIR -> 0 when DIR is a tmpfs mount point
	local mnt type rest
	[[ -r /proc/self/mounts ]] || return 1
	while read -r _ mnt type rest; do
		if [[ "${mnt}" == "$1" && "${type}" == tmpfs ]]; then return 0; fi
	done < /proc/self/mounts
	return 1
}
if [[ -n "${SHCL_FS_TMPFS:-}" ]]; then
	if fIsTmpfs "${SHCL_FS_TMPFS}"; then fsDir="${SHCL_FS_TMPFS}"; fsRoute="the run's tmpfs"; fsWant=tmpfs
	else echo "note: SHCL_FS_TMPFS names ${SHCL_FS_TMPFS}, which isn't a tmpfs here"; fi
fi
if [[ -z "${fsDir}" && "${osName}" == Darwin ]]; then
	## 512-byte sectors. newfs_hfs's default is HFS+ that ignores case, and a
	## volume a user mounts keeps owners, so the read-bit cases still hold.
	mkdir "${work}/fs"
	if ! fsDev="$(hdiutil attach -nomount "ram://$((256 * 2048))" 2>&1)"; then
		fsWhy="hdiutil attach failed: $(head -1 <<< "${fsDev}")"; fsDev=""
	else
		fsDev="${fsDev%%[[:space:]]*}"
		if ! out="$(newfs_hfs -v shcl-fs "${fsDev}" 2>&1)"; then fsWhy="newfs_hfs failed: $(head -1 <<< "${out}")"
		elif ! out="$(mount -t hfs "${fsDev}" "${work}/fs" 2>&1)"; then fsWhy="mount failed: $(head -1 <<< "${out}")"
		else fsMnt="${work}/fs"; fi
		if [[ -n "${fsMnt}" && "$(fFsType "${fsMnt}")" == hfs ]]; then
			fsDir="${fsMnt}"; fsRoute="a RAM disk"; fsWant=hfs
		else
			[[ -n "${fsWhy}" ]] || fsWhy="the RAM disk isn't on ${work}/fs"
			fFsDown
		fi
	fi
fi
if [[ -z "${fsDir}" && "${osName}" == FreeBSD ]]; then
	mkdir "${work}/fs"
	if ! out="$(mount -t tmpfs -o "size=${fsSize}" shcl-fs "${work}/fs" 2>&1)"; then
		fsWhy="mount -t tmpfs failed: $(head -1 <<< "${out}")"
	else
		fsMnt="${work}/fs"
		if [[ "$(fFsType "${fsMnt}")" == tmpfs ]]; then fsDir="${fsMnt}"; fsRoute="a tmpfs"; fsWant=tmpfs
		else fsWhy="the tmpfs isn't on ${fsMnt}"; fFsDown; fi
	fi
fi
if [[ -z "${fsDir}" && -n "${fsWinTop}" ]]; then
	if [[ -d "${fsWinTop}" ]] && fsWinDir="$(mktemp -d "${fsWinTop}/shcl-fs.XXXXXXXX")"; then
		fsDir="${fsWinDir}"; fsRoute="the temp folder"; fsWin=1
	else
		fsWinDir=""; fsWhy="no folder could be made in TEMP, ${fsWinTop}"
	fi
fi
if [[ -z "${fsDir}" && "${osName}" == Linux ]]; then
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
			fsDir="${work}/fs"; fsRoute="a tmpfs in a user namespace for each binding"; fsWant=tmpfs
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
	echo "fs property: cases on ${fsRoute}${fsWant:+, ${fsSize}}, at ${fsDir}"
fi

declare -i nBad=0
names=()
for b in "$@"; do
	name="${b%%|*}"; cmd="${b#*|}"; names+=("${name}")
	echo "fs property: ${name}: ${cmd}"
	## The folder's type, as the command sees it, ahead of the command.
	rc=0
	if ((${#fsWrap[@]})); then
		# shellcheck disable=SC2016  ## run by bash in the route's wrapper
		env SHCL_FS_DIR="${fsDir}" SHCL_FUZZ_DUMP="${dump}" "${fsWrap[@]}" \
			bash -c 'printf "%s\n" "$(stat -f -c %T "${SHCL_FS_DIR}" 2> /dev/null || echo unknown)" > "${SHCL_FUZZ_DUMP}/$2.fstype"; eval "$1"' bash "${cmd}" "${name}" || rc=$?
	else
		fFsType "${fsDir}" > "${dump}/${name}.fstype"
		## A native Windows program gets the folder in its own spelling.
		nativeDir="${fsDir}"; if ((fsWin)); then nativeDir="$(cygpath -w "${fsDir}")"; fi
		# shellcheck disable=SC2016  ## run by bash
		env SHCL_FS_DIR="${nativeDir}" SHCL_FUZZ_DUMP="${dump}" bash -c 'eval "$1"' bash "${cmd}" || rc=$?
	fi
	if ((rc != 0)); then echo "fs property: ${name} failed, exit ${rc}" >&2; nBad+=1; fi
done
## A failed run's dump is short or missing, so the compare would only repeat it.
((nBad == 0)) || exit 1

fTest df4ch the filesystem cases ran on a tmpfs or RAM disk made for the run
for name in "${names[@]}"; do
	got="$(cat "${dump}/${name}.fstype" 2> /dev/null || echo none)"
	if [[ -n "${fsWant}" ]]; then
		if [[ "${got}" != "${fsWant}" ]]; then echo "fs property: ${name}'s cases went on ${got}, not ${fsWant}" >&2; nBad+=1; fi
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
##		- 2026-11-11: The macOS RAM disk, FreeBSD's tmpfs and the Windows temp folder, for 2026111010331517.
