#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' config.bash's arrays, of which only TOOL_PINS and CPPCHECK_WHEEL are read here.

##	Purpose:
##		Fail when a pin in config.bash TOOL_PINS is not the one ci.yml installs.
##		The two lists are kept by hand; the last time they drifted, hosted CI
##		stayed red for days while the local gate was green. For every pinned
##		tool the hosted gate installs, some line of ci.yml has to name the tool
##		and its pinned version together as one token (ruff==X, staticcheck@X,
##		a download URL carrying X, go-version: "X") - whole words, so `build`
##		is not satisfied by a line that merely contains those letters, nor
##		`1.5.0` by govulncheck's v1.5.0. cppcheck is the odd one: pip installs
##		its PyPI wheel, whose version (CPPCHECK_WHEEL) is not the binary version
##		TOOL_PINS checks, so ci.yml has to carry the wheel token and, on a line
##		naming cppcheck, the binary version that wheel bundles - bump both.
##	Syntax:
##		check-pins.bash
##	Exit: 0 = every pin matches, 1 = a mismatch (named), 2 = cannot read inputs.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

cicdDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ciFile="${cicdDir}/../.github/workflows/ci.yml"
[[ -r "${ciFile}" ]] || { echo "check-pins: cannot read ${ciFile}" >&2; exit 2; }

## config.bash expands the cap while it loads; any value will do here.
CPU_CAP="${CPU_CAP:-1}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../config.bash
source "${cicdDir}/config.bash"
declare -p TOOL_PINS &>/dev/null || { echo "check-pins: config.bash has no TOOL_PINS" >&2; exit 2; }
[[ -n "${CPPCHECK_WHEEL:-}" ]] || { echo "check-pins: config.bash has no CPPCHECK_WHEEL" >&2; exit 2; }

testWhere="check-pins"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"

## Not installed by the hosted gate, which builds no cross targets.
notInCi=(cargo-zigbuild)

## Does ci.yml name tool $1 at version $2 as one token? The name is bounded on
## the left, then the joiner ci.yml uses (==, @, -, /, setup-go's `-version: "`,
## or Install-Module's ` -RequiredVersion `), an optional v, the version, and
## nothing digit-like after.
fNamesAt(){ grep -qE -- "(^|[^A-Za-z0-9_-])${1}(==|@|-|/|-version: \"| -RequiredVersion )v?${2//./\\.}([^0-9]|$)" "${ciFile}"; }

fTest EoLqLse tool-pins-match-ci
for pin in "${TOOL_PINS[@]}"; do
	name="${pin%%|*}"; rest="${pin#*|}"; ver="${rest%%|*}"
	skip=0
	for x in "${notInCi[@]}"; do
		if [[ "${x}" == "${name}" ]]; then skip=1; fi
	done
	((skip)) && continue
	if [[ "${name}" == cppcheck ]]; then
		fNamesAt cppcheck "${CPPCHECK_WHEEL}" || { echo "check-pins: cppcheck's wheel is ${CPPCHECK_WHEEL} in config.bash, and no line of ci.yml installs cppcheck==${CPPCHECK_WHEEL}" >&2; nBad=$((nBad + 1)); }
		## The binary version rides in the comment beside that install line. Two
		## steps rather than one pipeline so nothing sits downstream of an
		## early-exiting reader.
		namedLines="$(grep -iE -- '(^|[^A-Za-z0-9_-])cppcheck' "${ciFile}" || true)"
		grep -qE -- "(^|[^0-9.])${ver//./\\.}([^0-9]|$)" <<<"${namedLines}" && continue
	elif fNamesAt "${name}" "${ver}"; then
		continue
	fi
	echo "check-pins: ${name} is pinned at ${ver} in config.bash, and no line of ci.yml names ${name} with that version" >&2
	nBad=$((nBad + 1))
done

## A version pin is only half of it. The workflow also fetches two tools as
## archives and puts them ahead of the system copy, and one of those went in
## with nothing checked at all, so the pin bought nothing.
## Only one spelling can be followed to its check: `curl ... -o /absolute/path`.
## Any other fetch fails here rather than passing unseen, and so does a check
## that is commented out.
fTest EoaI9wW downloads-are-hashed
liveLines="$(grep -vE -- '^[[:space:]]*#' "${ciFile}" || true)"
while IFS= read -r fetchLine; do
	[[ -n "${fetchLine}" ]] || continue
	if ! grep -qE -- '(^|[[:space:]])curl[[:space:]].*[[:space:]]-o[[:space:]]+/' <<<"${fetchLine}" \
		|| grep -qE -- '\||[[:space:]]-O([[:space:]]|$)' <<<"${fetchLine}"; then
		echo "check-pins: ci.yml fetches in a form this check cannot follow to its sha256 (use curl -o /absolute/path): ${fetchLine#"${fetchLine%%[![:space:]]*}"}" >&2; nBad=$((nBad + 1))
	fi
done < <(grep -E -- '(^|[^A-Za-z0-9_-])(curl|wget|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|Start-BitsTransfer)([^A-Za-z0-9_-]|$)|gh (release|run) download' <<<"${liveLines}" || true)
while IFS= read -r target; do
	[[ -n "${target}" ]] || continue
	checked="$(grep -F -- "${target}\" | sha256sum -c" <<<"${liveLines}" || true)"
	if [[ -z "${checked}" ]]; then
		echo "check-pins: ci.yml downloads ${target} and never checks it" >&2; nBad=$((nBad + 1))
	elif ! grep -qE -- '[0-9a-f]{64}' <<<"${checked}"; then
		echo "check-pins: the check on ${target} carries no sha256" >&2; nBad=$((nBad + 1))
	fi
done < <(grep -oE -- '-o[[:space:]]+/[^[:space:]]+' <<<"${liveLines}" | sed 's/^-o[[:space:]]*//' | sort -u || true)

## The other direction. The checks above pass when a pin is DELETED from
## config.bash while ci.yml still installs the tool, which is how the one lint
## tool with no pin stayed unpinned. Every version-bearing install line in
## ci.yml has to name a tool TOOL_PINS knows.
## Each family is read on its own, guarded. They used to share one group under
## errexit and pipefail, so the first that matched nothing ended the group and
## the rest were never read; a process substitution's status is never seen, so
## nothing said so.
fTest EomaBGC installs-are-pinned
## pip and npm: name==version, name@version.
pipNames="$(grep -oE -- 'pip install[^|;]*' "${ciFile}" \
	| grep -oE -- '[A-Za-z][A-Za-z0-9_.-]*(==|@)[0-9]' | sed -E 's/(==|@)[0-9]$//' || true)"
npmNames="$(grep -oE -- 'npm install[^|;]*' "${ciFile}" \
	| grep -oE -- '[A-Za-z][A-Za-z0-9_.-]*(==|@)[0-9]' | sed -E 's/(==|@)[0-9]$//' || true)"
## go install module/path/cmd/NAME@version.
goNames="$(grep -oE -- 'go install [^[:space:]]+@[^[:space:]]+' "${ciFile}" \
	| sed -E 's#.*/([^/@]+)@.*#\1#' || true)"
## PowerShell modules.
psNames="$(grep -oE -- 'Install-Module [A-Za-z][A-Za-z0-9_.-]* -RequiredVersion' "${ciFile}" \
	| sed -E 's/Install-Module ([^ ]+).*/\1/' || true)"
## A family whose install line is there and whose pattern read no name from it
## has gone blind, which is this check's own failure rather than a pass.
for fam in "pip install|${pipNames}" "npm install|${npmNames}" "go install|${goNames}" "Install-Module|${psNames}"; do
	if grep -qF -- "${fam%%|*}" <<<"${liveLines}" && [[ -z "${fam#*|}" ]]; then
		echo "check-pins: ci.yml has a ${fam%%|*} line and no pinned name was read from it" >&2; nBad=$((nBad + 1))
	fi
done
while IFS= read -r named; do
	found=0
	for pin in "${TOOL_PINS[@]}"; do
		[[ "${pin%%|*}" == "${named}" ]] && found=1
	done
	((found)) || { echo "check-pins: ci.yml installs ${named} at a pinned version and config.bash has no TOOL_PINS entry for it" >&2; nBad=$((nBad + 1)); }
done < <(printf '%s\n%s\n%s\n%s\n' "${pipNames}" "${npmNames}" "${goNames}" "${psNames}" | sed '/^$/d' | sort -u)

fTestEnd
rc=0
if [[ "${nBad}" != 0 ]]; then rc=1; fi
((rc)) || echo "check-pins: OK: every TOOL_PINS entry the hosted gate installs matches ci.yml, every tool ci.yml pins has an entry, and every download it fetches is hashed"
exit "${rc}"


##	History:
##		- 2026-08-29 JC: Created.
##		- 2026-08-30 JC: Whole-token matching; the cppcheck wheel is checked
##		  against CPPCHECK_WHEEL as well as the binary version.
##		- 2026-08-31 JC: Every archive the workflow downloads has to be hashed.
##		- 2026-09-16 JC: A fetch in any other spelling fails, and a commented-out
##		  check does not count.
##		- 2026-09-19 JC: The reverse check reads each install family on its own,
##		  and a family whose line reads no name fails.
