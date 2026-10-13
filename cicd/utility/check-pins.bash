#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' config.bash's arrays, of which only TOOL_PINS and CPPCHECK_WHEEL are read here.

##	Purpose:
##		Fail when a pin in config.bash TOOL_PINS is not the one ci.yml installs.
##		The two lists are kept by hand; the last time they drifted, hosted CI
##		stayed red for days while the local gate was green. For every pinned
##		tool the hosted gate installs, some line of ci.yml has to name the tool
##		and its pinned version together as one token (ruff==X, staticcheck@X,
##		a download URL with X, go-version: "X") - whole words, so `build`
##		is not satisfied by a line that merely contains those letters, nor
##		`1.5.0` by govulncheck's v1.5.0. cppcheck is the odd one: pip installs
##		its PyPI wheel, whose version (CPPCHECK_WHEEL) is not the binary version
##		TOOL_PINS checks, so ci.yml has to name the wheel token and, on a line
##		naming cppcheck, the binary version that wheel bundles - bump both.
##		Also fails when the jobs that run cicd.bash --ci between them leave a
##		stage out, when a cicd/container recipe installs a pinned tool at
##		another version, and when one fetches something it doesn't hash.
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

## Not pinned in the hosted gate, which builds no release packages. It installs
## apt's nsis for the shell-regress rows that compile the setup script, whose
## output is read and thrown away. cargo-zigbuild is pinned there, for the
## macOS job's universal build.
notInCi=(makensis)

## Does ci.yml name tool $1 at version $2 as one token? The name is bounded on
## the left, then the joiner ci.yml uses (==, @, -, /, setup-go's `-version: "`,
## or Install-Module's ` -RequiredVersion `), an optional v, the version, and
## nothing digit-like after.
fNamesAt(){ grep -qE -- "(^|[^A-Za-z0-9_-])${1}(==|@|-|/|-version: \"| -RequiredVersion )v?${2//./\\.}([^0-9]|$)" "${ciFile}"; }

fTest EoSE8Nk tool-pins-match-ci
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
fTest Eq5jgxE downloads-are-hashed
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
		echo "check-pins: the check on ${target} has no sha256" >&2; nBad=$((nBad + 1))
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
fTest EqL4rto installs-are-pinned
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
## An install line whose pattern reads no name from it has gone blind, which
## is this check's own failure rather than a pass. Line by line, since one
## family can have several: the macOS job has its own pip line, and a family
## that read a name anywhere said nothing about a line it could not read.
for fam in "pip install" "npm install" "go install" "Install-Module"; do
	while IFS= read -r famLine; do
		[[ -n "${famLine}" ]] || continue
		case "${fam}" in
			"go install")     famName="$(grep -oE -- 'go install [^[:space:]]+@[^[:space:]]+' <<<"${famLine}" || true)" ;;
			"Install-Module") famName="$(grep -oE -- 'Install-Module [A-Za-z][A-Za-z0-9_.-]* -RequiredVersion' <<<"${famLine}" || true)" ;;
			*)                famName="$(grep -oE -- "${fam}[^|;]*" <<<"${famLine}" | grep -oE -- '[A-Za-z][A-Za-z0-9_.-]*(==|@)[0-9]' || true)" ;;
		esac
		[[ -n "${famName}" ]] || { echo "check-pins: ci.yml has a ${fam} line and no pinned name was read from it" >&2; nBad=$((nBad + 1)); }
	done < <(grep -F -- "${fam}" <<<"${liveLines}" || true)
done
while IFS= read -r named; do
	found=0
	for pin in "${TOOL_PINS[@]}"; do
		[[ "${pin%%|*}" == "${named}" ]] && found=1
	done
	((found)) || { echo "check-pins: ci.yml installs ${named} at a pinned version and config.bash has no TOOL_PINS entry for it" >&2; nBad=$((nBad + 1)); }
done < <(printf '%s\n%s\n%s\n%s\n' "${pipNames}" "${npmNames}" "${goNames}" "${psNames}" | sed '/^$/d' | sort -u)

## The hosted gate is split into parallel jobs, each running cicd.bash --ci
## with a flag that leaves one stage out. Between them they have to run every
## stage. Only flags that each drop a stage no other flag touches are allowed,
## so "some job runs without each flag" is the whole test. --no-largedoc and
## --quick overlap --no-tests, and would let the large document fall through.
fTest EsZzNCY hosted-jobs-cover-the-gate
stageFlags=(--no-fmt --no-lint --no-tests --no-cross)
gateRuns=()
matrixRe='\$\{\{ *matrix\.([A-Za-z0-9_-]+) *\}\}'
while IFS= read -r runLine; do
	[[ -n "${runLine}" ]] || continue
	runArgs="${runLine#*cicd/cicd.bash}"
	if [[ "${runArgs}" =~ ${matrixRe} ]]; then
		matrixKey="${BASH_REMATCH[1]}"
		matrixVals="$(sed -nE "s/^[[:space:]]*(-[[:space:]]+)?${matrixKey}:[[:space:]]*//p" <<<"${liveLines}" || true)"
		[[ -n "${matrixVals}" ]] || { echo "check-pins: ci.yml runs cicd.bash with matrix.${matrixKey} and no value for it was read" >&2; nBad=$((nBad + 1)); }
		while IFS= read -r matrixVal; do
			[[ -n "${matrixVal}" ]] && gateRuns+=("${runArgs/"${BASH_REMATCH[0]}"/${matrixVal}}")
		done <<<"${matrixVals}"
	else
		gateRuns+=("${runArgs}")
	fi
done < <(grep -E -- 'cicd/cicd\.bash' <<<"${liveLines}" || true)
((${#gateRuns[@]})) || { echo "check-pins: no job in ci.yml runs cicd/cicd.bash" >&2; nBad=$((nBad + 1)); }
declare -A flagMissingSomewhere=() flagUsed=()
for runArgs in "${gateRuns[@]}"; do
	read -r -a runWords <<<"${runArgs}"
	hasCi=0
	for w in "${runWords[@]}"; do
		if [[ "${w}" == --ci ]]; then hasCi=1; continue; fi
		known=0
		for f in "${stageFlags[@]}"; do
			if [[ "${w}" == "${f}" ]]; then known=1; fi
		done
		if ((known)); then flagUsed["${w}"]=1
		else echo "check-pins: ci.yml runs the gate with ${w}, which may leave out more than one stage:${runArgs}" >&2; nBad=$((nBad + 1)); fi
	done
	((hasCi)) || { echo "check-pins: ci.yml runs cicd.bash without --ci:${runArgs}" >&2; nBad=$((nBad + 1)); }
	for f in "${stageFlags[@]}"; do
		if [[ " ${runArgs} " != *" ${f} "* ]]; then flagMissingSomewhere["${f}"]=1; fi
	done
done
for f in "${!flagUsed[@]}"; do
	[[ -n "${flagMissingSomewhere[${f}]:-}" ]] || { echo "check-pins: every hosted job runs the gate with ${f}, so that stage runs nowhere" >&2; nBad=$((nBad + 1)); }
done

## The --container images are the other copy. The main one installs every
## pinned tool, so one of its files has to name each at its pin: the joiners
## above, a package.json `"name": "X"`, or `ARG NAME_VER=X`, with NAME upper
## case and - as _. Any recipe's ARG for a pinned tool has to match it too, so
## an extra image can't drift on its own.
fTest Esbpsph container-pins-match
ctrDir="${cicdDir}/container"
mainFiles=("${ctrDir}/Dockerfile" "${ctrDir}/requirements.txt" "${ctrDir}/package.json")
recipes=()
for f in "${ctrDir}"/Dockerfile "${ctrDir}"/*.Dockerfile; do
	if [[ -f "${f}" ]]; then recipes+=("${f}"); fi
done
if [[ ! -f "${mainFiles[0]}" ]]; then
	echo "check-pins: no main container recipe at cicd/container/Dockerfile" >&2; nBad=$((nBad + 1))
else
	for pin in "${TOOL_PINS[@]}"; do
		name="${pin%%|*}"; rest="${pin#*|}"; ver="${rest%%|*}"
		argName="$(tr 'a-z-' 'A-Z_' <<<"${name}")_VER"
		if [[ "${name}" == cppcheck ]]; then
			grep -qE -- "^cppcheck==${CPPCHECK_WHEEL//./\\.}([^0-9]|$)" "${ctrDir}/requirements.txt" \
				&& grep -iE -- 'cppcheck' "${ctrDir}/requirements.txt" | grep -qE -- "(^|[^0-9.])${ver//./\\.}([^0-9]|$)" && continue
			echo "check-pins: the container's requirements.txt has to install cppcheck==${CPPCHECK_WHEEL} and name the ${ver} binary it bundles" >&2
			nBad=$((nBad + 1)); continue
		fi
		if grep -qE -- "(^|[^A-Za-z0-9_-])${name}(==|@|\": \"| -RequiredVersion )v?${ver//./\\.}([^0-9]|$)" "${mainFiles[@]}" 2>/dev/null \
			|| grep -qE -- "^ARG ${argName}=v?${ver//./\\.}([^0-9]|$)" "${mainFiles[0]}"; then
			continue
		fi
		echo "check-pins: ${name} is pinned at ${ver} in config.bash, and the main container recipe doesn't install that version" >&2
		nBad=$((nBad + 1))
	done
	for f in "${recipes[@]}"; do
		while IFS='=' read -r argName argVer; do
			argName="${argName#ARG }"; argName="${argName%_VER}"
			for pin in "${TOOL_PINS[@]}"; do
				name="${pin%%|*}"; rest="${pin#*|}"; ver="${rest%%|*}"
				[[ "$(tr 'a-z-' 'A-Z_' <<<"${name}")" == "${argName}" ]] || continue
				if [[ ! "${argVer}" =~ ^v?${ver//./\\.}([^0-9]|$) ]]; then
					echo "check-pins: ${f#"${cicdDir}/"} pins ${name} at ${argVer}, and config.bash at ${ver}" >&2; nBad=$((nBad + 1))
				fi
			done
		done < <(grep -oE -- '^ARG [A-Z0-9_]+_VER=[^[:space:]]+' "${f}" || true)
	done
fi

## Each recipe fetches in the one spelling this can follow, `curl -fsSLo FILE`,
## checked by `echo "${X_SHA256}  FILE" | sha256sum -c -` with X_SHA256 a
## sha256. A fetch is curl or wget with an option, since the package lists name
## both bare. pip installs only by hash, and npm only from the lock file.
fTest Esbpt85 container-downloads-are-hashed
for f in "${recipes[@]}"; do
	rel="${f#"${cicdDir}/"}"
	while IFS= read -r fetchLine; do
		if [[ ! "${fetchLine}" =~ curl[[:space:]]+-fsSLo[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
			echo "check-pins: ${rel} fetches in a form this check cannot follow to its sha256 (use curl -fsSLo FILE): ${fetchLine#"${fetchLine%%[![:space:]]*}"}" >&2
			nBad=$((nBad + 1)); continue
		fi
		target="${BASH_REMATCH[1]}"
		shaArg="$(grep -oE -- "echo \"\\\$\\{[A-Z0-9_]+\\}  ${target//./\\.}\" \\| sha256sum -c" "${f}" | sed -E 's/^echo "\$\{([A-Z0-9_]+)\}.*/\1/' | head -n 1 || true)"
		if [[ -z "${shaArg}" ]]; then
			echo "check-pins: ${rel} downloads ${target} and never checks it" >&2; nBad=$((nBad + 1))
		elif ! grep -qE -- "^ARG ${shaArg}=[0-9a-f]{64}$" "${f}"; then
			echo "check-pins: ${rel} checks ${target} against ${shaArg}, which is not a sha256" >&2; nBad=$((nBad + 1))
		fi
	done < <(grep -E -- '(^|[^A-Za-z0-9_-])(curl|wget)[[:space:]]+-|^ADD ' "${f}" | grep -vE -- '^[[:space:]]*#' || true)
	while IFS= read -r pipLine; do
		[[ "${pipLine}" == *--require-hashes* ]] || { echo "check-pins: ${rel} installs with pip without --require-hashes" >&2; nBad=$((nBad + 1)); }
	done < <(grep -E -- 'pip install' "${f}" || true)
	if grep -qE -- 'npm (install|i) ' "${f}"; then
		echo "check-pins: ${rel} runs npm install; only npm ci keeps to the lock file's hashes" >&2; nBad=$((nBad + 1))
	fi
done

fTestEnd
rc=0
if [[ "${nBad}" != 0 ]]; then rc=1; fi
((rc)) || echo "check-pins: OK: every TOOL_PINS entry the hosted gate installs matches ci.yml, every tool ci.yml pins has an entry, every download it fetches is hashed, its jobs run every stage of the gate, and the container recipes agree with the pins and hash what they fetch"
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
##		- 2026-10-13 JC: The jobs that run cicd.bash have to cover every stage between them.
##		- 2026-10-13 JC: The container recipes are held to the pins, and their downloads to a sha256.
