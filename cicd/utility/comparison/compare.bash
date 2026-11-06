#!/usr/bin/env bash

##	Purpose:
##		Measure SHCL against JSON, YAML, TOML and XML on documents that hold the
##		same data in each format, at a size where parser behavior actually shows.
##		The README makes claims about how SHCL compares; this is where the
##		numbers behind them come from, and rerunning it is how they stay honest.
##
##		The comparison holds the language constant within a tier, so every format
##		is read by a library from the same ecosystem, built the same way. The
##		Rust tier is the headline; the Python tier repeats it over the same
##		documents to separate what a format costs from what one implementation
##		of it costs. Python libraries that are not installed are skipped and
##		named, never fatal - only python3 itself is needed.
##
##		Detailed results accumulate in results.shcl - written, pruned and read
##		back through this repo's own library, which is both the storage format
##		and the point.
##
##		Run on demand, never as a pipeline stage: benchmarks are noisy and slow,
##		and a red build caused by a busy machine teaches nobody anything. The
##		Rust crate beside this script is the only thing in the repo with
##		third-party dependencies, and it stays out of the gate for that reason
##		too - the gate must not need crates.io to pass.
##	Syntax:
##		compare.bash [--no-build] [tool options...]
##		  --no-build   use the binary already built
##		  --help       full option list from the tool itself
##	Exit: 0 = every measurement completed, 1 = one or more failed.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bin="${here}/target/release/shcl-comparison"

build=1
args=()
for a in "$@"; do
	case "${a}" in
		--no-build) build=0 ;;
		*) args+=("${a}") ;;
	esac
done

## rustup's cargo, so the pinned toolchain wins over whatever the system has.
export PATH="${HOME}/.cargo/bin:${PATH}"

if ((build)); then
	echo "[ Building the comparison tool ]"
	cargo build --release --manifest-path "${here}/Cargo.toml"
	echo
fi

[[ -x "${bin}" ]] || { echo "compare: no binary at ${bin} - drop --no-build" >&2; exit 1; }

exec "${bin}" "${args[@]}"


##	History:
##		- 2026-08-20 JC: Created, with the Rust tool beside it.
