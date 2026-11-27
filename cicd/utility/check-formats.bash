#!/usr/bin/env bash

##	Purpose:
##		The format round trip: every published format and pin, read by the CLI
##		built at its own tag or commit, and converted by the current CLI, reads
##		the same. For each format the documents are the corpus inputs at that
##		format's commit, the current corpus inputs, and a fuzz dump. A document
##		counts when the old CLI loads it clean, with its stamp lines taken
##		out. The current CLI's `upgrade --from=FORMAT` converts it, and its
##		output, read by the current CLI, has to give the paths, the instance
##		counts, and each instance's string array, raw body and info string that the old
##		CLI gave for the original. check-format-reads.py does the comparing,
##		and its help says what counts and what fails.
##
##		One commit stands for each format: the release that starts it, or the
##		earliest pin, by the design doc's tables. Pins of one format read every
##		document the same, so the others add nothing. Each is built once into
##		its own gitignored target, keyed by its hash, so a run after the first
##		builds nothing.
##	Syntax:
##		check-formats.bash [--iters N] [--min N] [--only FORMAT]... [--show N]
##		  --iters N      fuzz iterations to dump (default 2000)
##		  --min N        fail a format with fewer than N compared documents
##		                 (default 40)
##		  --only FORMAT  check only this format; may repeat
##		  --show N       print the first N mismatches of each format (default 3)
##	Exit: 0 = every format reads the same, 1 = a reading differs or too few
##		documents were compared, 2 = usage or a build failure.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/safe-rm.bash"

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
declare -i iters=2000 minCompared=40 show=3; only=()
while (($#)); do case "$1" in
	--iters)  iters="${2:-2000}"; shift 2 ;;
	--min)    minCompared="${2:-40}"; shift 2 ;;
	--only)   only+=("${2:-}"); shift 2 ;;
	--show)   show="${2:-3}"; shift 2 ;;
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)        echo "check-formats: unknown argument: $1" >&2; exit 2 ;;
esac; done

##	Format and the commit that stands for it. Full hashes, since a shallow
##	clone can fetch one by hash but not by a short name. Each format's test ID
##	is in check-format-reads.py.
oracles=(
	"1.0|4edc05dd36859996c4ad669455a62bd26528c60b"      # v1.0.0
	"1.1|e4f2263fe000815660148dd1cd850baecc1c9cf4"      # v1.1.0
	"2.0|fd1068a629701068f07a197de45212d267c20f46"      # v2.0.0
	"3.0-1f8|1f880093e4d228d029ffce5d505659bb566c69d4"
	"3.0-30d|30d367274cc835de78ac0b22c0d8342eb512dfd5"
	"3.0-b10|b10c2009d36cb9c6cf20c15269155052cf4be450"
	"3.0-f8e|f8e27a222718138f644b606771fa1fbf6fb7e4e3"
	"3.0-a37|a37aa2cefe86270e554e6c184e66803862bf941b"
	"3.0-9ef|9effd271996a9c9958c373a8f34db214c6083f22"
	"3.0-a65|a65eceb8f0ef15624bc2aced9e47215fda92f886"
	"3.0|99a9f7b69c8bacfac1cb09e7a04ea74323bfeb7b"      # v3.0.0-beta1
)
names=" ${oracles[*]%%|*} "
for o in "${only[@]}"; do
	[[ "${names}" == *" ${o} "* ]] || { echo "check-formats: no format ${o}" >&2; exit 2; }
done

##	The pipeline passes its CPU share. Alone, a quarter of the CPUs.
declare -i jobs="${CPU_CAP:-0}"
((jobs > 0)) || jobs=$(( $(nproc 2>/dev/null || echo 4) / 4 ))
((jobs > 0)) || jobs=1

tmpDir=''; fSafeTmpDir tmpDir
trap 'fSafeRm "${tmpDir}"' EXIT

newCli="${root}/source/rust/target/debug/shcl"
( cd "${root}/source/rust" && cargo build --quiet ) || { echo "check-formats: the current build failed" >&2; exit 2; }

##	The soup, from the current fuzz generator, as check-migrate makes it.
dump="${tmpDir}/dump"; mkdir -p "${dump}"
( cd "${root}/source/rust" && SHCL_FUZZ_DUMP="${dump}" SHCL_FUZZ_ITERS="${iters}" SHCL_FUZZ_DUMP_MAX=500 \
	cargo test --quiet --test fuzz_smoke mutated_inputs >/dev/null 2>&1 ) || { echo "check-formats: the fuzz dump failed" >&2; exit 2; }
##	A filter that matches nothing passes and writes nothing.
nDumped="$(find "${dump}" -maxdepth 1 -name '*.shcl' | wc -l | tr -d ' ')"
((nDumped > 0)) || { echo "check-formats: the fuzz dump wrote no documents" >&2; exit 2; }

##	Builds the CLI at REV into its own target, and unpacks REV's corpus.
fOracle(){
	local name="$1" rev="$2" src="${tmpDir}/src-$1" target="${root}/source/rust/target-formats/$1"
	if ! git -C "${root}" cat-file -e "${rev}^{commit}" 2>/dev/null; then
		git -C "${root}" fetch --depth=1 origin "${rev}" >/dev/null 2>&1 || true
	fi
	mkdir -p -- "${src}"
	git -C "${root}" archive "${rev}" source/rust project/conformance | tar -x -C "${src}" \
		|| { echo "check-formats: cannot unpack ${rev:0:12} for ${name}" >&2; return 1; }
	if [[ -x "${target}/debug/shcl" && "$(cat "${target}/.pin" 2>/dev/null || true)" == "${rev}" ]]; then return 0; fi
	echo "check-formats: building ${name} at ${rev:0:12}"
	( cd "${src}/source/rust" && CARGO_TARGET_DIR="${target}" nice -n 19 cargo build --quiet -j "${jobs}" --bin shcl ) \
		|| { echo "check-formats: the ${name} build failed" >&2; return 1; }
	printf '%s\n' "${rev}" > "${target}/.pin"
}

specs=()
for o in "${oracles[@]}"; do
	IFS='|' read -r name rev <<<"${o}"
	if ((${#only[@]})) && [[ " ${only[*]} " != *" ${name} "* ]]; then continue; fi
	fOracle "${name}" "${rev}" || exit 2
	specs+=("${name}|${root}/source/rust/target-formats/${name}/debug/shcl|${tmpDir}/src-${name}/project/conformance")
done

declare -i rc=0
nice -n 19 python3 "${meDir}/check-format-reads.py" --new "${newCli}" --jobs "${jobs}" --min "${minCompared}" --show "${show}" \
	--corpus "${root}/project/conformance" --dump "${dump}" "${specs[@]}" || rc=$?
case "${rc}" in
	0) echo "check-formats: OK" ;;
	1) echo "check-formats: a format reads differently after its conversion"; exit 1 ;;
	*) echo "check-formats: the comparison failed (exit ${rc})" >&2; exit 2 ;;
esac

##	History:
##		2026-11-20  Created: each published format and pin round-trips
##		            against its own CLI (2026111907080466).
##		2026-11-27  The info string is compared too (2026110409565662).
