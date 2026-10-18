#!/usr/bin/env bash

##	Purpose:
##		Write compile_commands.json for the programs sanitize-c.bash builds,
##		with the flags it builds them with, from include/c-flags.bash. There's
##		no build system to write one. clang-tidy without it guesses the flags,
##		misses the defines, and checks other code than the build's without
##		saying so.
##	Syntax:
##		gen-compdb.bash [OUT_DIR]
##		  OUT_DIR  where compile_commands.json goes (default cicd/artifacts/c-build)
##	Exit: 0 = written, 2 = could not write it.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/c-flags.bash"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-${root}/cicd/artifacts/c-build}"
mkdir -p -- "${out}" || { echo "gen-compdb: cannot make ${out}" >&2; exit 2; }
out="$(cd -- "${out}" && pwd)"

fJsonStr(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "${s}"; }

{
	echo '['
	sep=""
	for build in "${cSanBuilds[@]}"; do
		IFS='|' read -r bName bCc bStd bSrc bExtra <<<"${build}"
		read -r -a bExtraArgs <<<"${bExtra}"
		args=("${bCc}" "-std=${bStd}" "${cSanFlags[@]}" "${bExtraArgs[@]}" -c "${bSrc}" -o "${out}/${bName}.o")
		printf '%s\t{"directory": %s, "file": %s, "arguments": [' "${sep}" "$(fJsonStr "${root}")" "$(fJsonStr "${root}/${bSrc}")"
		argSep=""
		for a in "${args[@]}"; do printf '%s%s' "${argSep}" "$(fJsonStr "${a}")"; argSep=", "; done
		printf ']}'
		sep=$',\n'
	done
	printf '\n]\n'
} > "${out}/compile_commands.json.tmp" || { echo "gen-compdb: cannot write ${out}/compile_commands.json" >&2; exit 2; }
mv -f -- "${out}/compile_commands.json.tmp" "${out}/compile_commands.json"


##	History:
##		- 2026-10-17 JC: Created.
