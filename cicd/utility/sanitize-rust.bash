#!/usr/bin/env bash

##	Purpose:
##		The Rust test suite again under AddressSanitizer and LeakSanitizer, and
##		under Miri, on the dated nightly that rust-toolchain.toml names under
##		[nightly]. The plain cargo test proves the output; this proves the
##		memory behind it. A read past a buffer in an unsafe block, a leaked Box,
##		or undefined behavior that happens not to change a result passes every
##		other gate and fails here.
##		- ASan builds std too (-Zbuild-std), or std goes unchecked, and names
##		  the target, or the flags reach build scripts too. Its own target dir.
##		- LSan reports at exit, so a leak fails the whole test binary. To find
##		  the test, rerun that binary with --test-threads=1 and a filter.
##		- Miri skips tests that call FFI or start a process, each marked with
##		  why. Tests that walk the whole corpus or fuzz take minutes each there,
##		  so they're marked too and only run under --miri-all.
##	Syntax:
##		sanitize-rust.bash [--asan] [--miri] [--miri-all]
##		  --asan      the whole suite under ASan and LSan
##		  --miri      Miri over every test but the slow ones
##		  --miri-all  Miri over every test it can run. Hours, so it's for
##		              --leakcheck, not the full run.
##		  No option means --asan --miri, which is the full run's share.
##		CPU_CAP in the environment sets the jobs and test threads (default half
##		the cores).
##	Exit: 0 = clean, 1 = a test failed or a sanitizer or Miri reported, 2 = can't run.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=sanitize-rust; testCounter=nBad; nBad=0

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
manifest=source/rust/Cargo.toml

doAsan=0; doMiri=0; miriAll=0
for arg in "$@"; do
	case "${arg}" in
		--asan)     doAsan=1 ;;
		--miri)     doMiri=1 ;;
		--miri-all) doMiri=1; miriAll=1 ;;
		*) echo "sanitize-rust: unknown option: ${arg}" >&2; exit 2 ;;
	esac
done
if ((! doAsan && ! doMiri)); then doAsan=1; doMiri=1; fi

cap="${CPU_CAP:-}"
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || cap=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
((cap > 0)) || cap=1

nightly="$(sed -n '/^\[nightly\]/,/^\[/s/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)"
[[ -n "${nightly}" ]] || { echo "sanitize-rust: rust-toolchain.toml names no [nightly] channel" >&2; exit 2; }
## Asking cargo through rustup would install a missing toolchain on the spot,
## so the list says whether it's here.
installed="$(rustup toolchain list 2>/dev/null || true)"
if ! grep -q -- "^${nightly}-" <<<"${installed}"; then
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		echo "sanitize-rust: ${nightly} isn't installed, and the gate requires it" >&2
		exit 1
	fi
	echo "sanitize-rust: SKIPPED - ${nightly} isn't installed (rustup toolchain install ${nightly} --component rust-src,miri)"
	echo sanitize-rust >> "${SHCL_GATE_SKIPS:-/dev/null}"
	exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

## The suite's own status lines were shown by the tests stage, so only a FAIL
## line comes through here, then whatever a sanitizer or Miri said.
fShow(){
	grep -vE '^(ok|skip) +[0-9A-Za-z]{7} rust |^test .+ \.\.\. (ok|ignored)$' "$1" || true
}

if ((doAsan)); then
	fTest EszIPWj rust-suite-under-asan-and-lsan
	## LLVM's runtime prints bare addresses unless it finds a symbolizer, and
	## distributions add the version to the name.
	if [[ -z "${ASAN_SYMBOLIZER_PATH:-}" ]]; then
		for sym in llvm-symbolizer llvm-symbolizer-{24..14}; do
			if command -v "${sym}" >/dev/null 2>&1; then export ASAN_SYMBOLIZER_PATH; ASAN_SYMBOLIZER_PATH="$(command -v "${sym}")"; break; fi
		done
	fi
	asanRc=0
	## exitcode 77 is no exit any test binary uses, so a report can't pass for
	## a test's own failure.
	env RUSTFLAGS="-Zsanitizer=address" RUSTDOCFLAGS="-Zsanitizer=address" \
		ASAN_OPTIONS="exitcode=77:detect_leaks=1:${ASAN_OPTIONS:-}" LSAN_OPTIONS="exitcode=77:${LSAN_OPTIONS:-}" \
		RUST_TEST_THREADS="${cap}" \
		cargo "+${nightly}" test -j "${cap}" --no-fail-fast -Zbuild-std --target x86_64-unknown-linux-gnu \
		--target-dir source/rust/target/sanitize-asan --manifest-path "${manifest}" \
		>"${work}/asan.log" 2>&1 || asanRc=$?
	if ((asanRc != 0)); then
		fShow "${work}/asan.log"
		echo "sanitize-rust: the suite under ASan exited ${asanRc}" >&2
		nBad=$((nBad + 1))
	fi
fi

if ((doMiri)); then
	if ((miriAll)); then fTest EszIPWl rust-suite-under-miri-all
	else fTest EszIPWk rust-suite-under-miri; fi
	## Isolation off, since the tests read the corpus. Miri ignores opt-level
	## and warns that it does; 0 says nothing. --cfg shcl_miri_all lets in the
	## slow tests. The pinned clock keeps a setter's note off tzset, which
	## Miri can't call, and few fuzz rounds keep the fuzz tests to seconds.
	## The slow fuzz tests get more, since a few check their generator by
	## what share of rounds hit a case, and 20 is too few for that.
	fuzzIters=20; miriCfg=""
	if ((miriAll)); then fuzzIters=100; miriCfg="--cfg shcl_miri_all"; fi
	miriEnv=(MIRIFLAGS="-Zmiri-disable-isolation ${MIRIFLAGS:-}" CARGO_PROFILE_TEST_OPT_LEVEL=0 RUSTFLAGS="${miriCfg}"
		SHCL_TEST_CLOCK="2026-10-04 00:15:00 -420 PDT" SHCL_FUZZ_ITERS="${SHCL_MIRI_FUZZ_ITERS:-${fuzzIters}}" RUST_TEST_THREADS=1)
	miriCargo=(cargo "+${nightly}" miri test --target-dir source/rust/target/sanitize-miri --manifest-path "${manifest}")
	buildRc=0
	env "${miriEnv[@]}" "${miriCargo[@]}" -j "${cap}" --no-run >"${work}/miri-build.log" 2>&1 || buildRc=$?
	if ((buildRc != 0)); then
		cat "${work}/miri-build.log"
		echo "sanitize-rust: the tests didn't build for Miri" >&2
		nBad=$((nBad + 1))
	else
		## Miri runs a binary's threads on one core, so each test is a job of
		## its own, cap at a time, named from its binary's list.
		selectors=(--lib)
		for f in source/rust/tests/*.rs; do
			selectors+=("--test $(basename -- "${f}" .rs)")
		done
		jobSel=(); jobTest=()
		for sel in "${selectors[@]}"; do
			# shellcheck disable=2086  ## the selector is 2 words
			env "${miriEnv[@]}" "${miriCargo[@]}" ${sel} -- --list >"${work}/list" 2>&1 || true
			nListed=0
			while IFS= read -r t; do
				jobSel+=("${sel}"); jobTest+=("${t}"); nListed=$((nListed + 1))
			done < <(sed -n 's/: test$//p' "${work}/list")
			if ((nListed == 0)); then
				cat "${work}/list"
				echo "sanitize-rust: ${sel} listed no tests under Miri" >&2
				nBad=$((nBad + 1))
			fi
		done
		nLive=0
		for i in "${!jobTest[@]}"; do
			if ((nLive >= cap)); then
				wait -n || true
				nLive=$((nLive - 1))
			fi
			# shellcheck disable=2086  ## the selector is 2 words
			{ jrc=0; env "${miriEnv[@]}" "${miriCargo[@]}" ${jobSel[i]} -- --exact "${jobTest[i]}" >"${work}/miri-${i}.log" 2>&1 || jrc=$?; echo "${jrc}" >"${work}/miri-${i}.rc"; } &
			nLive=$((nLive + 1))
		done
		wait
		for i in "${!jobTest[@]}"; do
			jrc=""
			if [[ -f "${work}/miri-${i}.rc" ]]; then read -r jrc <"${work}/miri-${i}.rc"; fi
			[[ "${jrc}" == 0 ]] && continue
			fShow "${work}/miri-${i}.log"
			echo "sanitize-rust: ${jobTest[i]} (${jobSel[i]}) under Miri exited ${jrc:-without a result}" >&2
			nBad=$((nBad + 1))
		done
	fi
fi

fTestEnd
if [[ "${nBad}" != 0 ]]; then exit 1; fi
echo "sanitize-rust: OK: nothing reported"


##	History:
##		- 2026-10-17 JC: Created.
