#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' config.bash's arrays, of which only the release commands are read here.

##	Purpose:
##		Fail when code end users run picks up anything third-party. The leak and
##		static checks cover third-party code only where users run it, and today
##		none of it does, so a crate, Go module, Python import, C header or
##		library, or a vendored file would reach users with no check judging it.
##		What counts as what users run: the Rust library and CLI as release
##		builds them, both Go modules on every OS the release builds, shcl.py and
##		the Python CLI, and the C header, the veneer and the C CLI. Dev and
##		build tooling, the profiler feature and test code are out.
##		Offline and a few seconds: cargo metadata --no-deps and the go tool
##		read only what is in the tree.
##	Syntax:
##		check-deps.bash [REPO_DIR]
##	Exit: 0 = nothing third-party, 1 = something is (named), 2 = cannot read inputs.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

repoDir="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -r "${repoDir}/source/rust/Cargo.toml" && -r "${repoDir}/cicd/config.bash" ]] || { echo "check-deps: cannot read the tree at ${repoDir}" >&2; exit 2; }
CPU_CAP="${CPU_CAP:-1}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../config.bash
source "${repoDir}/cicd/config.bash"
testWhere="check-deps"; testCounter="nBad"; nBad=0
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
fBad(){ echo "check-deps: $*" >&2; nBad=$((nBad + 1)); }

## Nothing third-party is allowed today. Once something has had what the
## footer below asks for, it goes in its list.
okCrates=()
okGoModules=()
okPyModules=(shcl)
okQuotedIncludes=(shcl.h shcl.hpp)

## Libraries that come with the OS, by bare name: no lib prefix, no .dll or
## .so suffix, lower case.
fSystemLib(){
	case "$1" in
		kernel32|advapi32|ntdll|user32|shell32|ole32|oleaut32|bcrypt|ws2_32|userenv|shlwapi|synchronization|ucrtbase|msvcrt) return 0 ;;
		c|m|dl|pthread|rt|util|gcc_s|ld-linux*|ld-musl*|linux-vdso*|system) return 0 ;;
	esac
	return 1
}
fBareLib(){
	local n="${1,,}"
	n="${n##*/}"; n="${n%%.so*}"; n="${n%.dll}"; n="${n%.lib}"; n="${n%.dylib}"
	[[ "${n}" == lib?* ]] && n="${n#lib}"
	printf '%s' "${n}"
}

## C, C++, POSIX and Windows headers. An angle include with no dot and no
## slash is the C++ standard library's.
sysHeaders=" assert.h complex.h ctype.h errno.h fenv.h float.h inttypes.h iso646.h limits.h locale.h math.h setjmp.h signal.h
	stdalign.h stdarg.h stdatomic.h stdbit.h stdbool.h stdckdint.h stddef.h stdint.h stdio.h stdlib.h stdnoreturn.h string.h
	tgmath.h threads.h time.h uchar.h wchar.h wctype.h
	unistd.h fcntl.h strings.h dirent.h dlfcn.h poll.h pthread.h spawn.h termios.h sys/stat.h sys/types.h sys/time.h
	sys/wait.h sys/mman.h sys/ioctl.h sys/param.h
	windows.h shellapi.h io.h process.h direct.h share.h malloc.h intrin.h aclapi.h sddl.h "

mapfile -t tracked < <(git -C "${repoDir}" ls-files)
((${#tracked[@]})) || { echo "check-deps: git lists no files under ${repoDir}" >&2; exit 2; }
## Files end users run, test code left out.
shipped=()
for f in "${tracked[@]}"; do
	case "${f}" in
		source/rust/tests/*|source/python/tests/*|source/c/tests/*|*_test.go) ;;
		source/rust/src/*|source/rust/build.rs|source/go/*|source/python/shcl.py|source/python/cmd/*|source/c/*|source/completions/*) shipped+=("${f}") ;;
		install.bash|install.ps1|cicd/packaging/shclpath.ps1) shipped+=("${f}") ;;
	esac
done
cFiles=(); rsFiles=(); goFiles=(); pyFiles=()
for f in "${shipped[@]}"; do
	case "${f}" in
		*.c|*.h|*.hpp|*.cc|*.cpp|*.cxx|*.hh) cFiles+=("${f}") ;;
		*.rs) rsFiles+=("${f}") ;;
		*.go) goFiles+=("${f}") ;;
		*.py) pyFiles+=("${f}") ;;
	esac
done
((${#cFiles[@]} && ${#rsFiles[@]} && ${#goFiles[@]} && ${#pyFiles[@]})) || { echo "check-deps: a language has no shipped files; the lists above went stale" >&2; exit 2; }

## Optional crates count when a feature the release turns on reaches them, so
## the release commands' feature flags are read too.
fTest EtDJq3P rust-release-has-no-crates
relFeatures=""
for cmd in "${RELEASE_NATIVE_CMD[*]}" "${CROSS_TARGETS[@]}"; do
	[[ "${cmd}" == *--all-features* ]] && relFeatures+=" *"
	while [[ "${cmd}" =~ (--features[=[:space:]]+|-F[[:space:]]+)([^[:space:]]+)(.*) ]]; do
		relFeatures+=" ${BASH_REMATCH[2]//,/ }"; cmd="${BASH_REMATCH[3]}"
	done
done
if ! meta="$(cd "${repoDir}" && cargo metadata --offline --no-deps --format-version 1 --manifest-path source/rust/Cargo.toml 2>&1)"; then
	fBad "cargo metadata failed: ${meta}"
elif [[ "${meta}" != *'"name":"shcl"'* ]]; then
	fBad "cargo metadata names no shcl package, so nothing was judged"
else
	while IFS= read -r line; do
		[[ -z "${line}" ]] && continue
		ok=0
		for c in "${okCrates[@]}"; do
			if [[ "${line}" == "${c} "* ]]; then ok=1; fi
		done
		((ok)) || fBad "Rust release build depends on crate ${line}"
	done < <(python3 -c '
import json, sys
meta = json.loads(sys.argv[1])
extra = sys.argv[2].split()
for pkg in meta["packages"]:
	feats = pkg["features"]
	optional = {d.get("rename") or d["name"] for d in pkg["dependencies"] if d["optional"]}
	todo = ["default"] + (list(feats) + sorted(optional) if "*" in extra else extra)
	seen, reached = set(), set()
	while todo:
		f = todo.pop()
		if f in seen:
			continue
		seen.add(f)
		if f in optional:
			reached.add(f)
		for item in feats.get(f, []):
			if item.startswith("dep:"):
				reached.add(item[4:])
			elif "/" in item:
				name = item.split("/", 1)[0]
				if not name.endswith("?"):
					reached.add(name)
					todo.append(name)
			else:
				todo.append(item)
	for d in pkg["dependencies"]:
		key = d.get("rename") or d["name"]
		if d["kind"] == "dev" or (d["optional"] and key not in reached):
			continue
		name, req, kind, tgt = d["name"], d["req"], d["kind"] or "normal", d["target"]
		where = f" for {tgt}" if tgt else ""
		print(f"{name} {req} ({kind}{where})")
' "${meta}" "${relFeatures}")
fi

## Both modules' build lists, and every package each OS the release covers
## builds. A package inside our own modules is ours; the file check below
## catches a copy put there. cgo would link C, and a user's build may have it
## on, so it's on here for every OS.
fTest EtDJq3Q go-modules-are-stdlib-only
goLib="$(go -C "${repoDir}/source/go" list -m 2>/dev/null)" || { fBad "go cannot read source/go/go.mod"; goLib="?"; }
goCmd="$(go -C "${repoDir}/source/go/cmd" list -m 2>/dev/null)" || { fBad "go cannot read source/go/cmd/go.mod"; goCmd="?"; }
for mod in source/go source/go/cmd; do
	if ! mods="$(GOPROXY=off GOFLAGS=-mod=readonly go -C "${repoDir}/${mod}" list -m -f '{{.Path}}' all 2>&1)"; then
		fBad "go list -m all failed in ${mod}: ${mods}"; continue
	fi
	while IFS= read -r m; do
		[[ -z "${m}" || "${m}" == "${goLib}" || "${m}" == "${goCmd}" ]] && continue
		ok=0
		for c in "${okGoModules[@]}"; do
			if [[ "${m}" == "${c}" ]]; then ok=1; fi
		done
		((ok)) || fBad "Go module ${mod} requires ${m}"
	done <<<"${mods}"
	for os in linux windows darwin freebsd; do
		if ! pkgs="$(GOOS="${os}" CGO_ENABLED=1 GOPROXY=off GOFLAGS=-mod=readonly go -C "${repoDir}/${mod}" list -deps -f '{{if not .Standard}}{{.ImportPath}} {{len .CgoFiles}}{{end}}' ./... 2>&1)"; then
			fBad "go list -deps failed in ${mod} for ${os}: ${pkgs}"; continue
		fi
		[[ -n "${pkgs}" ]] || fBad "go list -deps in ${mod} for ${os} named no package, so nothing was judged"
		while read -r p cgo; do
			[[ -z "${p}" ]] && continue
			case "${p}" in
				"${goLib}"|"${goLib}"/*|"${goCmd}"|"${goCmd}"/*) ;;
				*) fBad "Go module ${mod} builds ${p} for ${os}" ;;
			esac
			[[ "${cgo}" == 0 ]] || fBad "Go package ${p} uses cgo for ${os}, which links C"
		done <<<"${pkgs}"
	done
done

## Every import, function-level ones included, and anything imported by name
## at run time, which can't be judged.
fTest EtDJq3R python-imports-are-stdlib-only
if ! pyOut="$(cd "${repoDir}" && python3 -c '
import ast, sys
ok = set(sys.argv[1].split())
if not hasattr(sys, "stdlib_module_names"):
	sys.exit("python3 is older than 3.10 and has no stdlib_module_names")
std = set(sys.stdlib_module_names)
judged = 0
for path in sys.argv[2:]:
	tree = ast.parse(open(path, encoding="utf-8").read(), path)
	for node in ast.walk(tree):
		names = []
		if isinstance(node, ast.Import):
			names = [a.name for a in node.names]
		elif isinstance(node, ast.ImportFrom):
			names = ["." * node.level + (node.module or "")]
		elif isinstance(node, ast.Call):
			fn = node.func
			called = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", "")
			if called in ("import_module", "__import__"):
				print(f"{path}:{node.lineno}: imports a module by name at run time")
		for name in names:
			judged += 1
			top = name.split(".")[0]
			if name.startswith(".") or (top not in std and top not in ok):
				print(f"{path}:{node.lineno}: imports {name}, past the standard library")
print(f"={judged}")
' "${okPyModules[*]}" "${pyFiles[@]}" 2>&1)"; then
	fBad "cannot read the Python imports: ${pyOut}"
fi
while IFS= read -r line; do
	if [[ "${line}" == =* ]]; then
		[[ "${line}" != =0 ]] || fBad "no import was read from the Python files, so nothing was judged"
	elif [[ -n "${line}" ]]; then fBad "${line}"; fi
done <<<"${pyOut}"
[[ "${pyOut}" == *$'\n'=* || "${pyOut}" == =* ]] || fBad "the Python import scan stopped early: ${pyOut}"

fTest EtDJq3S c-includes-are-system-only
nInc=0
for f in "${cFiles[@]}"; do
	while IFS=: read -r ln inc; do
		nInc=$((nInc + 1))
		inc="${inc#*include}"; inc="${inc#"${inc%%[![:space:]]*}"}"
		if [[ "${inc}" =~ ^\"([^\"]+)\" ]]; then
			ok=0
			for c in "${okQuotedIncludes[@]}"; do
				if [[ "${BASH_REMATCH[1]}" == "${c}" ]]; then ok=1; fi
			done
			((ok)) || fBad "${f}:${ln}: includes \"${BASH_REMATCH[1]}\", which isn't one of ours"
		elif [[ "${inc}" =~ ^\<([^\>]+)\> ]]; then
			h="${BASH_REMATCH[1]}"
			[[ "${h}" != *[./]* || "${sysHeaders}" == *[[:space:]]"${h}"[[:space:]]* ]] \
				|| fBad "${f}:${ln}: includes <${h}>, which isn't a C, C++, POSIX or Windows header (if the OS has it, add it to sysHeaders)"
		else
			fBad "${f}:${ln}: includes ${inc}, which this check can't read"
		fi
	done < <(grep -nE -- '^[[:space:]]*#[[:space:]]*include' "${repoDir}/${f}" || true)
done
((nInc)) || fBad "no include was read from the C files, so nothing was judged"

## A library named in code: Rust link attributes and build-script link lines,
## Go and Python DLL loads, C pragmas and run-time loads. A name that isn't a
## literal can't be judged, so it fails too.
fTest EtDJq3T libraries-named-in-code-are-system-only
## $3 is the name as written, quoted unless $4 says it's bare.
fLibName(){
	local f="$1" ln="$2" raw="$3" bare="${4:-0}" name
	raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"
	if [[ "${bare}" == 1 && "${raw}" =~ ^([A-Za-z0-9_.+-]+)$ ]] || [[ "${raw}" =~ ${quotedRe} ]]; then
		name="${BASH_REMATCH[1]}"
	else
		fBad "${f}:${ln}: loads a library whose name isn't a literal: ${raw}"; return
	fi
	nLibs=$((nLibs + 1))
	fSystemLib "$(fBareLib "${name}")" || fBad "${f}:${ln}: links or loads ${name}, which doesn't come with the OS"
}
nLibs=0
quotedRe='^L?["'"'"']([A-Za-z0-9_.+-]+)["'"'"']$'
libRe='#\[link\(name *= *("[^"]*")|rustc-link-lib=([A-Za-z-]+=)?([^"[:space:]]+)|(NewLazyDLL|NewLazySystemDLL|LoadDLL|MustLoadDLL|WinDLL|CDLL|OleDLL|PyDLL|LoadLibrary(Ex)?[AW]?|dlopen|find_library)\(([^,)]*)|#[[:space:]]*pragma[[:space:]]+comment\([[:space:]]*lib[[:space:]]*,([^)]*)\)|(windll|cdll|oledll)\.([A-Za-z0-9_]+)'
for f in "${rsFiles[@]}" "${goFiles[@]}" "${pyFiles[@]}" "${cFiles[@]}"; do
	while IFS= read -r hit; do
		ln="${hit%%:*}"; text="${hit#*:}"
		## A comment naming a call isn't a load.
		[[ "${text}" =~ ^[[:space:]]*(//|/?\*) ]] && continue
		[[ "${f}" == *.py && "${text}" =~ ^[[:space:]]*# ]] && continue
		while [[ "${text}" =~ (${libRe})(.*) ]]; do
			text="${BASH_REMATCH[11]}"
			if [[ -n "${BASH_REMATCH[2]}" ]]; then fLibName "${f}" "${ln}" "${BASH_REMATCH[2]}"
			elif [[ -n "${BASH_REMATCH[4]}" ]]; then fLibName "${f}" "${ln}" "${BASH_REMATCH[4]}" 1
			elif [[ -n "${BASH_REMATCH[5]}" ]]; then fLibName "${f}" "${ln}" "${BASH_REMATCH[7]}"
			elif [[ -n "${BASH_REMATCH[8]}" ]]; then fLibName "${f}" "${ln}" "${BASH_REMATCH[8]}"
			else fLibName "${f}" "${ln}" "${BASH_REMATCH[10]}" 1
			fi
		done
	done < <(grep -nE -- "${libRe}" "${repoDir}/${f}" || true)
done
## The Windows code paths load kernel32 and advapi32 today, so none read means
## the patterns went blind.
((nLibs)) || fBad "no library name was read from the code, so nothing was judged"
## Link flags in the tracked cargo config reach every Rust build.
while IFS= read -r hit; do
	fBad "a cargo config links a library: ${hit}"
done < <(cd "${repoDir}" && git ls-files -z -- '.cargo/config*' '*/.cargo/config*' | xargs -0 -r grep -HnE -- '(^|[" ])-l[[:space:]=]*[A-Za-z]|link-arg=-l|rustc-link-lib' || true)

## The CLIs the build stage made, by what the loader will pull in.
fTest EtDJq3U built-clis-link-system-libraries-only
nElf=0
if command -v readelf >/dev/null 2>&1; then
	for bin in source/rust/target/debug/shcl source/c/shcl source/go/shcl; do
		[[ -f "${repoDir}/${bin}" ]] || continue
		nElf=$((nElf + 1))
		while IFS= read -r lib; do
			[[ -n "${lib}" ]] || continue
			fSystemLib "$(fBareLib "${lib}")" || fBad "${bin} links ${lib}, which doesn't come with the OS"
		done < <(LC_ALL=C readelf -d "${repoDir}/${bin}" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p')
	done
fi
((nElf)) || fTestSkip

## Copied-in code. A path named like a vendor tree, a submodule, or a cargo
## config that swaps the crate source. Anywhere in the tree, since a build can
## pick a vendor folder up on its own.
fTest EtDJq3V no-vendored-trees
for f in "${tracked[@]}"; do
	if [[ "${f,,}" =~ (^|/)(vendor|vendored|third[_-]?party|thirdparty|3rd[_-]?party|external|extern|_deps|contrib)(/|$) ]]; then
		fBad "${f} looks vendored"
	fi
done
while read -r mode _ _ path; do
	[[ "${mode}" == 160000 ]] && fBad "${path} is a submodule"
done < <(git -C "${repoDir}" ls-files -s)
while IFS= read -r hit; do
	fBad "a cargo config replaces a crate source: ${hit}"
done < <(cd "${repoDir}" && git ls-files -z -- '.cargo/config*' '*/.cargo/config*' | xargs -0 -r grep -HnE -- '^[[:space:]]*\[(source|patch)[].]' || true)

## Every shipped code file is ours: an MIT SPDX line and our copyright near
## the top. A copied-in file fails here even when it imports nothing.
fTest EtDJq3W shipped-files-are-ours
for f in "${shipped[@]}"; do
	case "${f}" in
		*.md|*.toml|*.lock|*.mod|*.sum|*.conf|*.txt|*.json|*.yaml|*.yml|*.1) continue ;;
	esac
	top="$(head -n 60 -- "${repoDir}/${f}")"
	if ! grep -qE -- 'SPDX-License-Identifier: MIT' <<<"${top}" || ! grep -qE -- 'Copyright (©|\([Cc]\)) 20[0-9]{2} Jim Collier' <<<"${top}"; then
		fBad "${f} reaches end users without our MIT header, so it may be copied in"
	fi
done

fTestEnd
if [[ "${nBad}" != 0 ]]; then
	cat >&2 <<-'EOF'
		check-deps: third-party code now reaches end users. Before it goes in the script's allowed lists:
		check-deps:   - The leak and static checks run over it: soak, the sanitizers, Miri and the C analyzers.
		check-deps:   - CodeQL reports on it. codeql-scan.bash reports only on source/ today.
		check-deps:   - The Already-in-place rows of backlog items 2026101707582803 and 2026101711273980 say it's covered.
	EOF
	exit 1
fi
echo "check-deps: OK: no crate, Go module, Python import, C header or library past the system's, and no vendored file, in what end users run"
exit 0


##	History:
##		- 2026-10-19 JC: Created.
