#!/usr/bin/env bash

##	Purpose:
##		Keep the Python distribution to the library alone. The CLI and the test
##		runner live beside the module and must never ship: the Rust binary is the
##		only CLI this project distributes, and a PyPI install is a dependency,
##		not an installation. Only one line of pyproject.toml enforces that today
##		(py-modules), so a switch to package discovery would start shipping cmd/
##		and tests/ with nothing to notice. This builds both artifacts and reads
##		what is actually in them.
##	Syntax:
##		check-wheel.bash [ROOT]
##		  ROOT   repo root (default: two levels up from this script)
##	Exit: 0 = the wheel and sdist have the library and nothing else, 1 = they do not.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd -- "${meDir}/../.." && pwd)}"
pyDir="${root}/source/python"
testWhere="check-wheel"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "${meDir}/include/test-id.bash"

command -v pyproject-build >/dev/null 2>&1 \
	|| { echo "check-wheel: pyproject-build not installed (pipx install build)" >&2; exit 1; }

## Build into a temp dir, and take the build's own leavings with it: an sdist
## build writes shcl.egg-info and build/ back into the source tree, which is
## exactly the stale-artifact litter this repo keeps having to sweep up.
outDir="$(mktemp -d)"
trap 'rm -rf "${outDir}" "${pyDir}/build" "${pyDir}/shcl.egg-info"' EXIT

## The isolated environment fetches the build backend, and until it was pinned
## it fetched whatever setuptools PyPI served that day - into a build the gate
## then reads as the truth about the package. The constraints file names the
## version, so the backend is the same one every time; the file says why the
## hashes are not there. The version is read back out of the built wheel below,
## so a pin that did not take effect fails rather than passes.
buildConstraints="${root}/cicd/packaging/python-build-constraints.txt"
[[ -r "${buildConstraints}" ]] \
	|| { echo "check-wheel: no build constraints at ${buildConstraints}" >&2; exit 1; }
export PIP_CONSTRAINT="${buildConstraints}"
wantBackend="$(sed -n 's/^setuptools==\([0-9][^ \\]*\).*/\1/p' "${buildConstraints}")"
[[ -n "${wantBackend}" ]] \
	|| { echo "check-wheel: ${buildConstraints} names no setuptools version" >&2; exit 1; }

## Output is kept rather than discarded: this build stands up an isolated
## environment and can fail for reasons that have nothing to do with the
## package - a network blip fetching the backend, most of them transient - and
## a bare "build failed" leaves nothing to tell those apart from a real one.
## Same reason for the retries: the isolated environment pulls the build backend
## from PyPI every time, so an unreachable registry refuses a push over a package
## that is fine. Partial output is cleared between tries so a half-written wheel
## can never be the one that gets read.
buildLog="${outDir}/build.log"
for attempt in 1 2 3; do
	( cd "${pyDir}" && pyproject-build --outdir "${outDir}" ) >"${buildLog}" 2>&1 && break
	if ((attempt == 3)); then
		echo "check-wheel: build failed, ${attempt} tries" >&2
		tail -n 25 "${buildLog}" >&2
		exit 1
	fi
	echo "check-wheel: build attempt ${attempt} failed, retrying" >&2
	rm -rf "${outDir:?}"/* "${pyDir}/build" "${pyDir}/shcl.egg-info"
	sleep $((attempt * 5))
done

## Indent a multi-line block for the error output. Parameter expansion rather
## than a sed pipe: one less fork, and shellcheck prefers it.
fIndent(){ printf '  %s\n' "${1//$'\n'/$'\n'  }"; }

fTest EqM6SvY backend-is-the-pinned-one
## What actually built the wheel. setuptools writes itself into the metadata as
## `Generator: setuptools (X)`, so this reads the pin off the artifact rather
## than off the command line that asked for it.
gotBackend="$(python3 - "${outDir}" <<'PY'
import glob, re, sys, zipfile
z = zipfile.ZipFile(glob.glob(sys.argv[1] + "/*.whl")[0])
name = next(n for n in z.namelist() if n.endswith(".dist-info/WHEEL"))
m = re.search(r"^Generator:\s*setuptools\s*\(([^)]+)\)", z.read(name).decode(), re.M)
print(m.group(1) if m else "")
PY
)"
if [[ "${gotBackend}" != "${wantBackend}" ]]; then
	echo "check-wheel: the constraints file pins setuptools ${wantBackend}, and the wheel was built by ${gotBackend:-an unknown backend}" >&2
	nBad=$((nBad + 1))
fi

fTest EnUSdUG wheel-is-the-library-alone
## The wheel's payload is everything outside the .dist-info metadata directory.
## Exactly one file belongs there.
wheelPayload="$(python3 - "${outDir}" <<'PY'
import glob, sys, zipfile
names = zipfile.ZipFile(glob.glob(sys.argv[1] + "/*.whl")[0]).namelist()
print("\n".join(sorted(n for n in names if ".dist-info/" not in n and not n.endswith("/"))))
PY
)"
if [[ "${wheelPayload}" != "shcl.py" ]]; then
	echo "check-wheel: the wheel should have shcl.py and nothing else; it has:" >&2
	fIndent "${wheelPayload:-(nothing)}" >&2
	nBad=$((nBad + 1))
fi

fTest EnUSdUH wheel-installs-no-command
## An entry point would put a `shcl` command on PATH from a pip install, which
## is the thing this whole arrangement exists to prevent.
if python3 - "${outDir}" <<'PY'
import glob, sys, zipfile
z = zipfile.ZipFile(glob.glob(sys.argv[1] + "/*.whl")[0])
sys.exit(0 if any(n.endswith("entry_points.txt") for n in z.namelist()) else 1)
PY
then
	echo "check-wheel: the wheel declares entry points; a pip install would install a command" >&2
	nBad=$((nBad + 1))
fi

fTest EnUSdUI sdist-has-no-cli-or-tests
## The sdist is looser by nature - it has the project files - but the CLI
## and the tests still have no business in it.
strays="$(tar tzf "${outDir}"/*.tar.gz | grep -E '/(cmd|tests)/' || true)"
if [[ -n "${strays}" ]]; then
	echo "check-wheel: the sdist has the CLI or the tests:" >&2
	fIndent "${strays}" >&2
	nBad=$((nBad + 1))
fi

fTestEnd
rc=0
if [[ "${nBad}" != 0 ]]; then rc=1; fi
((rc == 0)) && echo "check-wheel: the python distribution is the library alone"
exit "${rc}"


##	History:
##		- 2026-08-20 JC: Created. Builds the wheel and sdist and reads what is in them, rather than trusting the one pyproject line that keeps the CLI out.
##		- 2026-08-27 JC: Build is retried twice before it counts as a failure; an unreachable PyPI was refusing pushes.
##		- 2026-09-19 JC: The build backend is pinned through PIP_CONSTRAINT, and the built wheel has to say that version built it.
