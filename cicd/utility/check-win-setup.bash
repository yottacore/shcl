#!/usr/bin/env bash

##	Purpose:
##		The windows setup runs NSIS's installer code and its nsExec plugin as
##		administrator on the user's box, and nothing else runs it. This installs
##		with the built setup silently, runs `shcl --version` from the machine
##		PATH, then uninstalls and checks the PATH entry, the files and the
##		uninstall key are gone (2026101921290791). Windows only, as an
##		administrator, under git-bash. It refuses to run over an existing
##		install.
##	Syntax:
##		check-win-setup.bash SETUP_EXE
##	Exit: 0 = passed, 1 = a check failed, 2 = usage or not windows.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
testWhere=check-win-setup; testCounter=nBad
declare -i nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"

fBad(){ echo "check-win-setup: $1" >&2; nBad+=1 ;}
case "${1:-}" in -h|--help) sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed 's/^##	\{0,1\}//'; exit 0 ;; esac
(($# == 1)) && [[ -f "$1" ]] || { echo "usage: check-win-setup.bash SETUP_EXE" >&2; exit 2 ;}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) echo "check-win-setup: windows only" >&2; exit 2 ;; esac
## NSIS reads /S and /D itself, so msys must not turn them into paths.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
setup="$(realpath -- "$1")"
dirWin="${ProgramW6432:-${PROGRAMFILES}}\\Shcl"
dirU="$(cygpath -u "${dirWin}")"
regKey='HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\Shcl'
[[ ! -e "${dirU}" ]] || { echo "check-win-setup: ${dirWin} is there already; this only installs over nothing" >&2; exit 2 ;}

fPs(){ powershell.exe -NoProfile -NonInteractive -Command "$1" | tr -d '\r' ;}
## 0 when DIR is an entry of the machine PATH, as Windows reads it.
fOnPath(){
	local e
	while IFS= read -r e; do
		[[ "${e,,}" == "${1,,}" || "${e,,}" == "${1,,}\\" ]] && return 0
	done < <(fPs "[Environment]::GetEnvironmentVariable('Path','Machine')" | tr ';' '\n')
	return 1
}
## The setup's stub is 32-bit, so its key is in the 32-bit view. Apps and
## features reads both, and so does this.
fHasKey(){ reg query "${regKey}" /reg:64 >/dev/null 2>&1 || reg query "${regKey}" /reg:32 >/dev/null 2>&1 ;}
## NSIS reads _?= only unquoted and last, and msys quotes an argument with a
## space, so the uninstaller copied itself to temp and returned at once.
## Start-Process joins its arguments as they are and waits.
fUninstall(){ fPs "exit (Start-Process -FilePath '${dirWin}\uninstall.exe' -ArgumentList '/S','_?=${dirWin}' -Wait -PassThru).ExitCode" ;}
## A failed run still takes the install off the box.
trap '[[ -f "${dirU}/uninstall.exe" ]] && fUninstall || true' EXIT

fTest EtIkYkb the setup installs silently and puts its folder on the machine PATH
rc=0; "${setup}" /S || rc=$?
((rc == 0)) || fBad "setup /S exited ${rc}"
[[ -f "${dirU}/shcl.exe" && -f "${dirU}/uninstall.exe" ]] || fBad "${dirWin} is missing shcl.exe or uninstall.exe"
fOnPath "${dirWin}" || fBad "${dirWin} isn't on the machine PATH"
fHasKey || fBad "no ${regKey}, in either view"

fTest EtIkYnd shcl from the machine PATH is the installed one and runs
want="$("${dirU}/shcl.exe" --version 2>&1 | tr -d '\r' || true)"
got="$(fPs "\$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine'); (Get-Command shcl).Source; shcl --version" 2>&1 || true)"
[[ "${got,,}" == "${dirWin,,}\\shcl.exe"$'\n'"${want,,}" && "${want}" == "shcl v"* ]] \
	|| fBad "shcl from the machine PATH gave ${got@Q}, the installed one ${want@Q}"

fTest EtIkYqY the uninstaller takes off the PATH entry, the files and the uninstall key
## With _?= it runs in place and waits, so it can't delete itself or the folder.
rc=0; fUninstall || rc=$?
((rc == 0)) || fBad "uninstall.exe /S exited ${rc}"
! fOnPath "${dirWin}" || fBad "${dirWin} is still on the machine PATH"
fHasKey && fBad "${regKey} is still there"
left="$(cd "${dirU}" 2>/dev/null && find . -mindepth 1 ! -name uninstall.exe || true)"
[[ -z "${left}" ]] || fBad "the uninstaller left ${left//$'\n'/ } in ${dirWin}"
rm -f "${dirU}/uninstall.exe"; rmdir "${dirU}" 2>/dev/null || fBad "${dirWin} isn't empty past uninstall.exe"
fTestEnd

if ((nBad)); then
	echo "check-win-setup: ${nBad} problem(s)" >&2
	exit 1
fi
echo "check-win-setup: OK"

##	History:
##		2026-10-20  Created, for 2026101921290791.
