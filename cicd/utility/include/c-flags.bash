#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' The scripts that source this read them.

##	Purpose:
##		The sanitizer build's flags and its list of programs, in one place:
##		sanitize-c.bash builds from them and gen-compdb.bash writes the compile
##		database clang-tidy reads from them, so the two can't drift apart.
##		Paths are from the repo root.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## -O1 keeps line numbers honest in a report; -fno-sanitize-recover makes every
## UBSan finding fatal instead of a note that scrolls past.
cSanFlags=(-O1 -g "-fsanitize=address,undefined" -fno-sanitize-recover=all -fno-omit-frame-pointer -Wall -Wextra -Werror -Isource/c)
## TSan can't share a build with ASan.
cTsanFlags=(-O1 -g -fsanitize=thread -Wall -Wextra -Werror -Isource/c)
## libstdc++'s debug mode, on top of cSanFlags, for sanitize-c.bash
## --glibcxx-debug. It checks each iterator against its container, which
## _GLIBCXX_ASSERTIONS doesn't, and it changes the ABI, so it builds alone.
cDebugStlFlags=(-D_GLIBCXX_DEBUG -DSHCL_ARENA_MALLOC)

## NAME|COMPILER|STD|SOURCE|EXTRA FLAGS. SHCL_ARENA_MALLOC gives each arena
## request a malloc of its own, so ASan sees inside what is one block in a
## normal build. mem_bounds, oom_hook and oom_recover keep the bump arena,
## since they count its blocks and its allocations. _GLIBCXX_ASSERTIONS is
## libstdc++'s checked mode, bounds on operator[] and front() included, and
## keeps the ABI.
cSanBuilds=(
	"conformance|cc|c11|source/c/tests/conformance.c|-DSHCL_ARENA_MALLOC"
	"oom_hook|cc|c11|source/c/tests/oom_hook.c|"
	"oom_recover|cc|c11|source/c/tests/oom_recover.c|"
	"mem_bounds|cc|c11|source/c/tests/mem_bounds.c|"
	"veneer_smoke|g++|c++17|source/c/tests/veneer_smoke.cpp|-DSHCL_ARENA_MALLOC -D_GLIBCXX_ASSERTIONS"
	"shcl|cc|c11|source/c/cmd/shcl/main.c|-DSHCL_ARENA_MALLOC"
)


##	History:
##		- 2026-10-17 JC: Created, out of sanitize-c.bash, for the compile database.
##		- 2026-10-19 JC: cDebugStlFlags.
