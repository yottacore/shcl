#!/usr/bin/env bash

##	Purpose:
##		Float handling must not follow the host program's locale. The C library
##		converts both directions through calls that do - strtod and printf -
##		and under a comma-decimal locale it once wrote 1.5 as "1" and read every
##		float back as a bad type. No corpus case can ask for a locale, so the
##		fix went in with nothing pinning it.
##
##		This builds a comma-decimal locale from a definition of its own (no
##		system locale is guaranteed to have one, and generating one needs no
##		privileges) and runs the whole C corpus under it, then the CLI end to
##		end on the same document.
##	Syntax:
##		check-locale.bash [ROOT]
##	Exit: 0 = clean or skipped, 1 = a check failed, 2 = usage or missing input.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=check-locale; testCounter=nBad

repoDir="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -d "${repoDir}" ]] || { echo "check-locale: no such directory: ${repoDir}" >&2; exit 2 ;}

##	Both come from libc's own packaging, so a machine missing them is one where
##	no locale could be built at all. Loud rather than silent: a gate nobody
##	notices has stopped running is worse than one that fails.
if ! command -v localedef >/dev/null 2>&1 || [[ ! -e /usr/share/i18n/locales/POSIX ]]; then
	## Under the gate a skip is a failure: a runner that loses a tool would
	## otherwise report OK forever. Locally it stays a skip.
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		echo "check-locale: localedef or the POSIX locale source is missing, and the gate requires it" >&2
		exit 1
	fi
	echo "check-locale: SKIPPED - localedef or the POSIX locale source is missing"
	echo check-locale >> "${SHCL_GATE_SKIPS:-/dev/null}"
	exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

##	POSIX for every category except the numeric one, which is the whole point.
##	A real locale (de_DE and friends) would do, but none is guaranteed present.
{
	printf 'LC_NUMERIC\ndecimal_point "<U002C>"\nthousands_sep "<U002E>"\ngrouping 3;3\nEND LC_NUMERIC\n\n'
	for cat in LC_CTYPE LC_COLLATE LC_TIME LC_MONETARY LC_MESSAGES LC_PAPER; do
		printf '%s\ncopy "POSIX"\nEND %s\n\n' "${cat}" "${cat}"
	done
} > "${work}/commadec"
mkdir -p "${work}/loc"
##	-c to write the locale anyway: POSIX defines none of the address-book
##	categories, so it warns about each missing one and exits nonzero. Whether it
##	worked is decided by reading the locale back, not by the exit status.
localedef -c -i "${work}/commadec" -f UTF-8 "${work}/loc/commadec.UTF-8" >"${work}/localedef.log" 2>&1 || true
export LOCPATH="${work}/loc"
point="$(LC_ALL=commadec.UTF-8 locale decimal_point 2>/dev/null || true)"
if [[ "${point}" != "," ]]; then
	echo "check-locale: the built locale's decimal point is '${point}', not a comma:" >&2
	tail -n 5 "${work}/localedef.log" >&2
	exit 2
fi

declare -i nBad=0
fBad(){ echo "check-locale: $1" >&2; nBad+=1 ;}

##	The library, through the corpus runner. SHCL_TEST_LC_NUMERIC is what tells
##	it to take the numeric category from the environment instead of pinning C.
##	Its own per-test lines stay in its log; the tail on a failure leaves them
##	out, so what shows is the failure.
fTest EoaHRyi the C corpus under a comma-decimal locale
cc -std=c11 -O2 -Wall -Wextra -Werror -I"${repoDir}/source/c" \
	"${repoDir}/source/c/tests/conformance.c" -o "${work}/conformance" -lm -lpthread \
	|| { echo "check-locale: the corpus runner did not build" >&2; exit 2 ;}
LC_ALL=commadec.UTF-8 SHCL_TEST_LC_NUMERIC=1 "${work}/conformance" "${repoDir}/project/conformance" \
	> "${work}/corpus.out" 2>&1 || { fBad "the corpus fails under a comma-decimal locale:"
		{ grep -vE '^(ok|skip) +[0-9A-Za-z-]{7} c ' "${work}/corpus.out" || true; } | tail -n 5 >&2 ;}

##	A C program built here has to take the comma from the environment, or every
##	check below passes whether or not the library handles it.
printf '#include <locale.h>\n#include <stdio.h>\nint main(void) { setlocale(LC_ALL, ""); printf("%%.1f\\n", 1.5); return 0; }\n' > "${work}/probe.c"
cc -std=c11 -O2 "${work}/probe.c" -o "${work}/probe" || { echo "check-locale: the locale probe did not build" >&2; exit 2 ;}
probed="$(LC_ALL=commadec.UTF-8 "${work}/probe" || true)"
[[ "${probed}" == "1,5" ]] || { echo "check-locale: a C program here does not adopt the built locale (printed '${probed}')" >&2; exit 2 ;}

##	And the same property end to end, which is what a user sees. The shipped CLI
##	pins its own locale at startup, so it cannot fail here by itself. A copy
##	with the pin turned into adopting the environment is what reaches the
##	library's own handling.
cc -std=c11 -O2 -Wall -Wextra -Werror -I"${repoDir}/source/c" \
	"${repoDir}/source/c/cmd/shcl/main.c" -o "${work}/shcl" -lm \
	|| { echo "check-locale: the C CLI did not build" >&2; exit 2 ;}
pin='setlocale(LC_ALL, "C");'
grep -qF -- "${pin}" "${repoDir}/source/c/cmd/shcl/main.c" || { echo "check-locale: main.c no longer pins its locale with ${pin}" >&2; exit 2 ;}
mkdir -p "${work}/envcli"
sed 's/setlocale(LC_ALL, "C");/setlocale(LC_ALL, "");/' "${repoDir}/source/c/cmd/shcl/main.c" > "${work}/envcli/main.c"
cc -std=c11 -O2 -Wall -Wextra -Werror -I"${repoDir}/source/c" -I"${repoDir}/source/c/cmd/shcl" \
	"${work}/envcli/main.c" -o "${work}/shcl-env" -lm \
	|| { echo "check-locale: the C CLI did not build with its locale unpinned" >&2; exit 2 ;}
printf 'ratio: 3.5\ntiny: 0.125\nbig: 1.5e300\nneg: -0.5\n' > "${work}/floats.shcl"
LC_ALL=C "${work}/shcl" fmt "${work}/floats.shcl" > "${work}/plain.out" 2>&1 || true
for cli in shcl shcl-env; do
	if [[ "${cli}" == shcl ]]; then fTest Eq5kgrw the C CLI with its locale pinned under a comma-decimal locale
	else fTest Eq5kgrx the C CLI adopting a comma-decimal locale; fi
	LC_ALL=commadec.UTF-8 "${work}/${cli}" fmt "${work}/floats.shcl" > "${work}/comma.out" 2>&1 || true
	if ! cmp -s "${work}/plain.out" "${work}/comma.out"; then
		fBad "${cli} formats floats differently under a comma-decimal locale:"
		diff "${work}/plain.out" "${work}/comma.out" | head -n 6 >&2 || true
	fi
	grep -q '^ratio: 3\.5$' "${work}/comma.out" || fBad "${cli} did not write 3.5 under a comma-decimal locale"
	## fmt passes the text through; a typed read is what converts it.
	got="$(LC_ALL=commadec.UTF-8 "${work}/${cli}" get --float "${work}/floats.shcl" ratio 2>&1 || true)"
	[[ "${got}" == "3.5" ]] || fBad "${cli} read ratio as '${got}' under a comma-decimal locale, not 3.5"
done
fTestEnd

if ((nBad)); then
	echo "check-locale: ${nBad} check(s) failed" >&2
	exit 1
fi
echo "check-locale: OK: corpus and CLI unchanged under a comma-decimal locale"

##	History:
##		2026-08-31  Created. The locale fix from the 20260817 round went in with
##		            nothing pinning it, on the reading that a corpus case cannot
##		            set a locale - which is true of the corpus and not of a gate.
##		2026-09-16  A failed CLI compare no longer ends the run before its summary.
##		            A probe proves the locale is adopted, and an unpinned CLI copy
##		            gives the CLI half something that can fail.
