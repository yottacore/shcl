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
##		Also fails when the jobs that run cicd.bash --merge-gate between them
##		leave a stage out, when one of them runs both lint and tests or without
##		--no-container, when a
##		cicd/container recipe installs a pinned tool at another version, and
##		when one fetches something it doesn't hash. A leak check's tool that
##		ci.yml leaves out fails here unless every job that runs the leak
##		checks skips its step, and no other step may name it.
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

## The cap config.bash's strings read; any value will do here.
CPU_CAP="${CPU_CAP:-1}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../config.bash
source "${cicdDir}/config.bash"
declare -p TOOL_PINS &>/dev/null || { echo "check-pins: config.bash has no TOOL_PINS" >&2; exit 2; }
[[ -n "${CPPCHECK_WHEEL:-}" ]] || { echo "check-pins: config.bash has no CPPCHECK_WHEEL" >&2; exit 2; }

testWhere="check-pins"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"

## Not pinned in the hosted gate, which builds no windows release and so no
## setup. It installs apt's nsis for the shell-regress rows that compile the
## setup script, whose output is read and thrown away. cargo-zigbuild is
## pinned there, for the macOS job's universal build.
notInCi=(makensis)
## Run only by a leak check that every hosted job skips with --skip, since
## CodeQL's bundle is about 700 MB and its run more than the tests half has
## time for. The check below holds each to that.
leakOnly=(codeql)
notInCi+=("${leakOnly[@]}")

## Does ci.yml name tool $1 at version $2 as one token? The name is bounded on
## the left, then the joiner ci.yml uses (==, apt's =, @, -, /, setup-go's
## `-version: "`, or Install-Module's ` -RequiredVersion `), an optional v, the
## version, and nothing digit-like after.
fNamesAt(){ grep -qE -- "(^|[^A-Za-z0-9_-])${1}(==|=|@|-|/|-version: \"| -RequiredVersion )v?${2//./\\.}([^0-9]|$)" "${ciFile}"; }

fTest dbz38 tool-pins-match-ci
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
fTest dcqge downloads-are-hashed
liveLines="$(grep -vE -- '^[[:space:]]*#' "${ciFile}" || true)"
while IFS= read -r fetchLine; do
	[[ -n "${fetchLine}" ]] || continue
	if ! grep -qE -- '(^|[[:space:]])curl[[:space:]].*[[:space:]]-o[[:space:]]+/' <<<"${fetchLine}" \
		|| grep -qE -- '\||[[:space:]]-O([[:space:]]|$)' <<<"${fetchLine}"; then
		echo "check-pins: ci.yml fetches in a form this check cannot follow to its sha256 (use curl -o /absolute/path): ${fetchLine#"${fetchLine%%[![:space:]]*}"}" >&2; nBad=$((nBad + 1))
	fi
done < <(grep -E -- '(^|[^A-Za-z0-9_-])(curl|wget|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|Start-BitsTransfer)([^A-Za-z0-9_-]|$)|gh (release|run) download' <<<"${liveLines}" || true)
## A check counts only where nothing after it can turn it into a pass, and a
## file is fetched once, or the check can be of the first fetch and not the one
## that's used.
fetchTargets="$(grep -oE -- '-o[[:space:]]+/[^[:space:]]+' <<<"${liveLines}" | sed 's/^-o[[:space:]]*//' | sort || true)"
while IFS= read -r target; do
	[[ -n "${target}" ]] || continue
	checked="$(grep -F -- "${target}\" | sha256sum -c" <<<"${liveLines}" | grep -E -- 'sha256sum -c -?[[:space:]]*$' || true)"
	if [[ -z "${checked}" ]]; then
		echo "check-pins: ci.yml downloads ${target} and never checks it" >&2; nBad=$((nBad + 1))
	elif ! grep -qE -- '[0-9a-f]{64}' <<<"${checked}"; then
		echo "check-pins: the check on ${target} has no sha256" >&2; nBad=$((nBad + 1))
	fi
done < <(uniq <<<"${fetchTargets}")
while IFS= read -r target; do
	[[ -n "${target}" ]] || continue
	echo "check-pins: ci.yml downloads ${target} more than once" >&2; nBad=$((nBad + 1))
done < <(uniq -d <<<"${fetchTargets}")

## The other direction. The checks above pass when a pin is DELETED from
## config.bash while ci.yml still installs the tool, which is how the one lint
## tool with no pin stayed unpinned. Every version-bearing install line in
## ci.yml has to name a tool TOOL_PINS knows.
## Each family is read on its own, guarded. They used to share one group under
## errexit and pipefail, so the first that matched nothing ended the group and
## the rest were never read; a process substitution's status is never seen, so
## nothing said so.
fTest dcv6n installs-are-pinned
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

## The hosted gate is split into parallel jobs, each running cicd.bash
## --merge-gate with flags that leave stages out. Between them they have to run
## every stage. Only flags that each drop a stage no other flag touches are
## allowed, so "some job runs without each flag" is the whole test. --no-largedoc
## and --quick overlap --no-tests, and would let the large document fall
## through. --no-cross and --no-release share the cross targets, which the
## halves leave to the jobs that build on their own runners (2026102813104371).
## --no-remote is the LAN boxes, and --skip is held to the leak check below.
fTest ddwkk hosted-jobs-cover-the-gate
stageFlags=(--no-fmt --no-lint --no-tests --no-cross --no-release)
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
inImage=(); runSkips=()
for runArgs in "${gateRuns[@]}"; do
	read -r -a runWords <<<"${runArgs}"
	hasGate=0; hasNoCtr=0; skips=""
	for w in "${runWords[@]}"; do
		if [[ "${w}" == --merge-gate ]]; then hasGate=1; continue; fi
		if [[ "${w}" == --no-container ]]; then hasNoCtr=1; continue; fi
		if [[ "${w}" == --no-remote ]]; then continue; fi
		if [[ "${w}" == --skip=?* ]]; then skips+="${w#--skip=}"$'\n'; continue; fi
		known=0
		for f in "${stageFlags[@]}"; do
			if [[ "${w}" == "${f}" ]]; then known=1; fi
		done
		if ((known)); then flagUsed["${w}"]=1
		else echo "check-pins: ci.yml runs the gate with ${w}, which may leave out more than one stage:${runArgs}" >&2; nBad=$((nBad + 1)); fi
	done
	((hasGate)) || { echo "check-pins: ci.yml runs cicd.bash without --merge-gate:${runArgs}" >&2; nBad=$((nBad + 1)); }
	((hasNoCtr)) || inImage+=("${runArgs}")
	runSkips+=("${skips}")
	## Lint and tests together were the one job that ran past the 60-minute
	## limit (2026101011200000), so each job leaves one of them out.
	if [[ " ${runArgs} " != *" --no-lint "* && " ${runArgs} " != *" --no-tests "* ]]; then
		echo "check-pins: a hosted job runs both lint and tests, which as one job ran out of time:${runArgs}" >&2; nBad=$((nBad + 1))
	fi
	## Tests then the release ran out the hour too (2026102915235852).
	if [[ " ${runArgs} " != *" --no-tests "* && " ${runArgs} " != *" --no-release "* ]]; then
		echo "check-pins: a hosted job runs both tests and the release, which as one job ran out of time:${runArgs}" >&2; nBad=$((nBad + 1))
	fi
	for f in "${stageFlags[@]}"; do
		if [[ " ${runArgs} " != *" ${f} "* ]]; then flagMissingSomewhere["${f}"]=1; fi
	done
done
for f in "${!flagUsed[@]}"; do
	[[ -n "${flagMissingSomewhere[${f}]:-}" ]] || { echo "check-pins: every hosted job runs the gate with ${f}, so that stage runs nowhere" >&2; nBad=$((nBad + 1)); }
done

## A runner has docker, so a run there without --no-container builds the whole
## build image before anything else, and the job runs out of time (2026101920461174).
fTest de61r hosted-jobs-skip-the-image
for runArgs in "${inImage[@]}"; do
	echo "check-pins: ci.yml runs the gate without --no-container, so it would build the image first:${runArgs}" >&2; nBad=$((nBad + 1))
done

## A leak check's tool ci.yml leaves out is skipped by name in every hosted job
## that runs the leak checks, the ones without --no-tests, and no other step
## names it. A --skip of anything else leaves out a step the runner can run.
fTest de5an leakcheck-only-tools-stay-out-of-the-gate
for tool in "${leakOnly[@]}"; do
	toolRe="(^|[^A-Za-z0-9_-])${tool}([^A-Za-z0-9_]|$)"
	for step in "${FMT_CHECK_CMD[*]:-}" "${FMT_CHECK_EXTRA[@]}" "${BUILD_CMD[*]:-}" "${BUILD_EXTRA[@]}" "${LINT_CMD[*]:-}" "${LINT_EXTRA[@]}" \
		"${TEST_CMD[*]:-}" "${TEST_EXTRA[@]}" "${CROSS_CHECKS[@]}" "${RELEASE_CHECKS[@]}"; do
		if [[ "${step}" =~ ${toolRe} ]]; then
			echo "check-pins: ${tool} is left out of ci.yml as a leak check's tool, and a step the gate runs names it: ${step}" >&2; nBad=$((nBad + 1))
		fi
	done
	for step in "${LEAKCHECK_FAST[@]}" "${LEAKCHECK_STEPS[@]}"; do
		[[ "${step}" =~ ${toolRe} ]] || continue
		for i in "${!gateRuns[@]}"; do
			[[ " ${gateRuns[${i}]} " != *" --no-tests "* ]] || continue
			skipped=0
			while IFS= read -r skipText; do
				if [[ -n "${skipText}" && "${step}" == *"${skipText}"* ]]; then skipped=1; fi
			done <<<"${runSkips[${i}]}"
			((skipped)) || { echo "check-pins: ${tool} is left out of ci.yml, and a hosted job runs the leak check that needs it: ${step}:${gateRuns[${i}]}" >&2; nBad=$((nBad + 1)); }
		done
	done
done
for i in "${!gateRuns[@]}"; do
	while IFS= read -r skipText; do
		[[ -n "${skipText}" ]] || continue
		needed=0
		for step in "${LEAKCHECK_FAST[@]}" "${LEAKCHECK_STEPS[@]}"; do
			[[ "${step}" == *"${skipText}"* ]] || continue
			for tool in "${leakOnly[@]}"; do
				if [[ "${step}" =~ (^|[^A-Za-z0-9_-])${tool}([^A-Za-z0-9_]|$) ]]; then needed=1; fi
			done
		done
		((needed)) || { echo "check-pins: ci.yml skips ${skipText}, which is no leak check whose tool it leaves out:${gateRuns[${i}]}" >&2; nBad=$((nBad + 1)); }
	done <<<"${runSkips[${i}]}"
done

## The --container images are the other copy. The main one installs every
## pinned tool, so one of its files has to name each at its pin: the joiners
## above, a package.json `"name": "X"`, or `ARG NAME_VER=X`, with NAME upper
## case and - as _. Any recipe's ARG for a pinned tool has to match it too, so
## an extra image can't drift on its own, and so does a version written straight
## into a RUN line.
fTest ddx1t container-pins-match
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
		## A version written into the RUN line goes around the ARG.
		while IFS= read -r token; do
			[[ "${token}" =~ ^(.*/)?([A-Za-z][A-Za-z0-9_.-]*)(==|@|\ -RequiredVersion\ )v?([0-9][A-Za-z0-9._+-]*)$ ]] || continue
			tokName="${BASH_REMATCH[2]}"; tokVer="${BASH_REMATCH[4]}"
			for pin in "${TOOL_PINS[@]}"; do
				name="${pin%%|*}"; rest="${pin#*|}"; ver="${rest%%|*}"
				if [[ "${name}" == "${tokName}" && "${ver#v}" != "${tokVer}" ]]; then
					echo "check-pins: ${f#"${cicdDir}/"} installs ${token##*/}, and config.bash pins ${name} at ${ver}" >&2; nBad=$((nBad + 1))
				fi
			done
		done < <(grep -vE -- '^[[:space:]]*#' "${f}" | grep -oE -- '[A-Za-z0-9_./-]*[A-Za-z][A-Za-z0-9_.-]*(==|@| -RequiredVersion )v?[0-9][A-Za-z0-9._+-]*' || true)
	done
fi

## Each recipe fetches in the one spelling this can follow, `curl -fsSLo FILE`,
## one to a line, with `&& echo "${X_SHA256}  FILE" | sha256sum -c -` on the
## next line and X_SHA256 a sha256. The next line, since a check anywhere else
## can be of an earlier fetch to the same name, and Docker drops a comment line
## inside a RUN. A fetch is curl or wget with an option or a URL, or run as a
## command; the package lists name both bare. A base image is pinned by digest.
## pip installs only by hash, and npm only from the lock file.
fTest ddx1v container-downloads-are-hashed
fetchRe='(^|[^A-Za-z0-9_-])(curl|wget)[[:space:]]+-|(^|[^A-Za-z0-9_-])(curl|wget)[[:space:]].*://|(^RUN|&&|\||;|\$\()[[:space:]]*(curl|wget|git[[:space:]]+clone)([[:space:]]|$)|^ADD[[:space:]]'
fetchWordRe='(^|[^A-Za-z0-9_-])(curl|wget)([^A-Za-z0-9_-]|$)'
checkRe='^&&[[:space:]]+echo "\$\{([A-Z0-9_]+)\}  ([^"]+)" \| sha256sum -c -( \\)?$'
for f in "${recipes[@]}"; do
	rel="${f#"${cicdDir}/"}"
	mapfile -t recipeLines < "${f}"
	declare -A fetched=()
	for ((i = 0; i < ${#recipeLines[@]}; i++)); do
		fetchLine="${recipeLines[i]}"
		[[ ! "${fetchLine}" =~ ^[[:space:]]*# ]] || continue
		if [[ "${fetchLine}" =~ ^FROM[[:space:]] && ! "${fetchLine}" =~ @sha256:[0-9a-f]{64}([[:space:]]|$) ]]; then
			echo "check-pins: ${rel} takes a base image that isn't pinned by digest: ${fetchLine}" >&2; nBad=$((nBad + 1))
		fi
		[[ "${fetchLine}" =~ ${fetchRe} ]] || continue
		shown="${fetchLine#"${fetchLine%%[![:space:]]*}"}"
		afterFirst="${fetchLine#*curl}"; [[ "${afterFirst}" != "${fetchLine}" ]] || afterFirst="${fetchLine#*wget}"
		target=""
		if [[ "${fetchLine}" =~ curl[[:space:]]+-fsSLo[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then target="${BASH_REMATCH[1]}"; fi
		if [[ -z "${target}" || "${afterFirst}" =~ ${fetchWordRe} ]]; then
			echo "check-pins: ${rel} fetches in a form this check cannot follow to its sha256 (use curl -fsSLo FILE, one to a line): ${shown}" >&2
			nBad=$((nBad + 1)); continue
		fi
		if [[ -n "${fetched[${target}]:-}" ]]; then
			echo "check-pins: ${rel} downloads ${target} twice" >&2; nBad=$((nBad + 1))
		fi
		fetched["${target}"]=1
		checkLine="${recipeLines[i + 1]:-}"; checkLine="${checkLine#"${checkLine%%[![:space:]]*}"}"
		if [[ ! "${checkLine}" =~ ${checkRe} || "${BASH_REMATCH[2]}" != "${target}" ]]; then
			echo "check-pins: ${rel} downloads ${target} and the next line doesn't check it: ${shown}" >&2; nBad=$((nBad + 1))
		elif ! grep -qE -- "^ARG ${BASH_REMATCH[1]}=[0-9a-f]{64}$" "${f}"; then
			echo "check-pins: ${rel} checks ${target} against ${BASH_REMATCH[1]}, which is not a sha256" >&2; nBad=$((nBad + 1))
		fi
	done
	unset fetched
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
##		- 2026-10-16 JC: A recipe's check has to be on the line after its fetch, a fetch
##		  with the URL first or no option counts, a base image needs a digest, and a
##		  version in a RUN line is held to the pin. In ci.yml too, a file is fetched
##		  once and nothing follows its check.
##		- 2026-10-16 JC: No hosted job runs both lint and tests.
##		- 2026-10-19 JC: The hosted jobs run --gate. apt's name=version is a joiner.
##		- 2026-10-19 JC: A --leakcheck-only tool stays out of ci.yml, and out of every gate step.
##		- 2026-10-19 JC: Every hosted gate run passes --no-container.
##		- 2026-10-28: The hosted jobs run --merge-gate, with --no-release and --no-remote
##		  allowed. A leak check's tool ci.yml leaves out is skipped by --skip in every
##		  job that runs the leak checks, and --skip names nothing else.
