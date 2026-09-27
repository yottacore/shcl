#!/usr/bin/env bash

##	Purpose:
##		Fail when shcl.h declares a public call that the C++ veneer neither
##		makes nor lists below with the reason it does not need to. The veneer
##		began as a read layer and fell behind C one addition at a time, with
##		nothing to say so, until it could load and save a document but not
##		change a value in it. A call counts as made when shcl.hpp names it
##		outside a comment, which also counts a function passed by pointer.
##		The list has to stay true as well: a listed call the veneer now makes,
##		or one shcl.h no longer declares, fails too.
##		It also compiles a get<int> snippet, which has to stop at get<T>'s
##		static_assert rather than build and fail at the link.
##	Syntax:
##		check-veneer.bash
##	Exit: 0 = every public call is made or listed, 1 = one is not (named),
##	      2 = cannot read inputs.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

srcDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../source/c" && pwd)"
header="${srcDir}/shcl.h"
veneer="${srcDir}/shcl.hpp"
[[ -r "${header}" && -r "${veneer}" ]] || { echo "check-veneer: cannot read ${header} or ${veneer}" >&2; exit 2; }
testWhere="check-veneer"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"

## Public calls the veneer reaches another way, and how.
declare -A covered=(
	[shcl_get_int]="get_or<int64_t> reads through get<T> and checks the status itself"
	[shcl_get_float]="get_or<double> reads through get<T> and checks the status itself"
	[shcl_get_bool]="get_or<bool> reads through get<T> and checks the status itself"
	[shcl_get_int_or]="get_or<int64_t> reads through get<T> and checks the status itself"
	[shcl_get_float_or]="get_or<double> reads through get<T> and checks the status itself"
	[shcl_get_bool_or]="get_or<bool> reads through get<T> and checks the status itself"
	[shcl_read_string_to]="every veneer read releases first and copies into a std container"
	[shcl_read_int_array_to]="every veneer read releases first and copies into a std container"
	[shcl_read_float_array_to]="every veneer read releases first and copies into a std container"
	[shcl_read_bool_array_to]="every veneer read releases first and copies into a std container"
	[shcl_read_datetime_array_to]="every veneer read releases first and copies into a std container"
	[shcl_read_string_array_to]="every veneer read releases first and copies into a std container"
)

fTest Eq4sdfk every-c-call-is-wrapped
## Declarations start at column 0 with their return type; everything above the
## implementation guard is the public half. A floor on the count, since a
## pattern that stopped matching would otherwise pass with nothing to check.
declared=()
while IFS= read -r name; do
	declared+=("${name}")
done < <(sed -n '1,/^#ifdef SHCL_IMPLEMENTATION/p' "${header}" | sed -nE 's/^[A-Za-z_][A-Za-z0-9_ *]*[ *](shcl_[a-z0-9_]+)\(.*/\1/p' | sort -u)
((${#declared[@]} >= 50)) || { echo "check-veneer: found ${#declared[@]} public calls in shcl.h, too few to trust; has the declaration style changed?" >&2; exit 2; }

declare -A made=()
while IFS= read -r name; do
	made["${name}"]=1
done < <(sed -E 's#//.*$##' "${veneer}" | { grep -oE 'shcl_[a-z0-9_]+' || true; } | sort -u)

declare -A isDeclared=()
for name in "${declared[@]}"; do
	isDeclared["${name}"]=1
	if [[ -n "${made[${name}]:-}" ]]; then
		if [[ -n "${covered[${name}]:-}" ]]; then
			echo "check-veneer: shcl.hpp calls ${name}, which is also listed as reached another way; take it off the list" >&2; nBad=$((nBad + 1))
		fi
	elif [[ -z "${covered[${name}]:-}" ]]; then
		echo "check-veneer: shcl.h declares ${name} and shcl.hpp never calls it; wrap it, or list it in this script with the reason" >&2; nBad=$((nBad + 1))
	fi
done
for name in "${!covered[@]}"; do
	if [[ -z "${isDeclared[${name}]:-}" ]]; then
		echo "check-veneer: ${name} is listed as reached another way, and shcl.h no longer declares it" >&2; nBad=$((nBad + 1))
	fi
done

fTest Eqzz38Z get-refuses-an-unsupported-type
## get<T> with a T it has no read for has to stop at compile time with the
## static_assert's text. Without the assert it was a bare undefined-symbol link
## error. The same snippet must compile with a supported T, or a broken snippet
## would pass as the refusal.
cxx="${CXX:-g++}"
command -v "${cxx}" >/dev/null || { echo "check-veneer: no C++ compiler (${cxx})" >&2; exit 2; }
work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
fGetSnippet(){ printf '#include "shcl.hpp"\nint main() { auto d = shcl::Document::parse("a: 1\\n"); return d.get<%s>("a").value == 1 ? 0 : 1; }\n' "$1" >"${work}/get.cpp"; }
fGetSnippet int64_t
if ! "${cxx}" -std=c++17 -fsyntax-only -I"${srcDir}" "${work}/get.cpp" 2>"${work}/good.err"; then
	echo "check-veneer: the get<T> snippet does not compile with a supported T" >&2; cat "${work}/good.err" >&2; nBad=$((nBad + 1))
fi
fGetSnippet int
if "${cxx}" -std=c++17 -fsyntax-only -I"${srcDir}" "${work}/get.cpp" 2>"${work}/bad.err"; then
	echo "check-veneer: get<int> compiles; an unsupported T has to fail at compile time" >&2; nBad=$((nBad + 1))
elif ! grep -qF 'T must be exactly int64_t' "${work}/bad.err"; then
	echo "check-veneer: get<int> fails without the static_assert's message:" >&2; head -5 "${work}/bad.err" >&2; nBad=$((nBad + 1))
fi

fTest Er1ohBJ public-half-names-no-c
## A C++ caller sees none of the C interface. Above the implementation section
## the header names only its own guard and the two knobs, and the C include
## sits inside an SHCL_IMPLEMENTATION block of its own.
while IFS= read -r hit; do
	echo "check-veneer: the public half of shcl.hpp names the C interface: ${hit}" >&2; nBad=$((nBad + 1))
done < <(sed -E 's#//.*$##' "${veneer}" | awk '
	/^#ifdef SHCL_IMPLEMENTATION$/ { n++; if (n == 1) { skip = 1; next } else exit }
	skip && /^#endif/ { skip = 0; next }
	!skip { print FNR ": " $0 }' | { grep -E 'shcl_[a-z]|SHCL_' || true; } | { grep -vE '^[0-9]+: #(ifndef|define|endif) SHCL_HPP|SHCL_NO_FILE_IO' || true; })

## The same thing, as a compiler sees it: a consumer file has no C header, and
## the consumer and implementation files, compiled apart, link and run.
fTest Er1ohBK consumer-cannot-call-c
fFlags=(-std=c++17 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror -I"${srcDir}")
printf '#include "shcl.hpp"\nint main() { return shcl_parse("", 0) != 0; }\n' >"${work}/sees.cpp"
if "${cxx}" "${fFlags[@]}" -fsyntax-only "${work}/sees.cpp" 2>/dev/null; then
	echo "check-veneer: a file including only shcl.hpp can call shcl_parse" >&2; nBad=$((nBad + 1))
fi
fTest Er1ohBL split-build-links-and-runs
printf '#define SHCL_IMPLEMENTATION\n#include "shcl.hpp"\n' >"${work}/impl.cpp"
cat >"${work}/user.cpp" <<'EOF'
#include "shcl.hpp"
#ifdef SHCL_H
#error shcl.h is visible to a consumer
#endif
int main() {
	auto d = shcl::Document::parse("a: 1\nt: 2026-01-02T03:04Z\n");
	if (!d || d.get_or<std::int64_t>("a", 0) != 1 || !d.set_string("b", "x")) return 1;
	auto t = d.read_datetime("t");
	if (!t.ok() || t.value != *shcl::parse_datetime(t.value.str())) return 2;
	auto [text, faults] = shcl::generate(shcl::Document::parse("field: p\n\tdefault: 1\n"), true);
	if (!faults.empty() || text.empty() || shcl::GEN_BANNER.empty()) return 3;
	return shcl::Document::parse(d.to_canonical()).get_or<std::string>("b", "") == "x" ? 0 : 4;
}
EOF
if ! "${cxx}" "${fFlags[@]}" -c "${work}/impl.cpp" -o "${work}/impl.o" 2>"${work}/split.err" \
	|| ! "${cxx}" "${fFlags[@]}" -c "${work}/user.cpp" -o "${work}/user.o" 2>>"${work}/split.err" \
	|| ! "${cxx}" "${work}/user.o" "${work}/impl.o" -o "${work}/split" -lm 2>>"${work}/split.err"; then
	echo "check-veneer: a consumer file and the implementation file do not build and link apart:" >&2; head -20 "${work}/split.err" >&2; nBad=$((nBad + 1))
else
	splitRc=0; "${work}/split" || splitRc=$?
	if [[ "${splitRc}" != 0 ]]; then echo "check-veneer: the consumer built apart from the implementation gave the wrong answer (exit ${splitRc})" >&2; nBad=$((nBad + 1)); fi
fi

fTestEnd
rc=0
if [[ "${nBad}" != 0 ]]; then rc=1; fi
((rc)) || echo "check-veneer: OK: each of the ${#declared[@]} public calls in shcl.h is made by shcl.hpp or listed with a reason (${#covered[@]}), get<int> stops at the static_assert, and a consumer sees no C and links apart"
exit "${rc}"


##	History:
##		- 2026-09-16 JC: Created.
##		- 2026-09-26 JC: get<int> compile-fail check.
##		- 2026-09-26 JC: The public half names no C, and a consumer links apart.
