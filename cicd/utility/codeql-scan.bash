#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' config.bash's arrays, of which only TOOL_PINS and the CTR_ settings are read here.

##	Purpose:
##		CodeQL over all 5 languages, for --leakcheck. C and C++ are one
##		database, then Go, Python and Rust, each analyzed with its own
##		security-and-quality suite. Any finding fails. One that's wrong, or
##		real and filed as a bug, is suppressed at its line, with a comment
##		alone on the line before it:
##			// codeql[QUERY-ID] the reason, or the backlog item's ID
##		with # in Python, and /* */ above commented-out C, which a // line
##		would join. CodeQL's alert-suppression query finds them, and this
##		matches them to the findings. The pinned version has no such query
##		for Rust, so cicd/codeql/rust-suppression is the same one over Rust's
##		comments. There's no baseline file, a suppression has to give its
##		reason and still cover a finding, and lgtm and noqa comments, which
##		CodeQL would take too, don't count.
##		It runs over a copy of source/ with one planted finding per language
##		in it, and each has to be reported. Each database has to hold every
##		source file of its languages, and Rust's workspace has to load, so an
##		extractor that quietly dropped code fails rather than passing as clean.
##		Go's tests are extracted too, which CodeQL leaves out by default.
##		Go gets a second pass with GOOS=windows, for the files behind the
##		windows build tag. C and Rust are analyzed as the Linux build sees
##		them.
##		The Rust extractor swaps a stable toolchain for the newer one its
##		rust-analyzer wants, and would install it, so this runs on the dated
##		nightly from rust-toolchain.toml, which it keeps.
##		The databases, the SARIF, and findings.txt go in cicd/artifacts/codeql/.
##		CodeQL is the version TOOL_PINS names and runs in the build image, with
##		no network. On a box without it this fetches the crates Cargo.lock
##		names for the Rust extractor into the cargo home --container runs use,
##		under CTR_CACHE, then starts that image and runs in it, building it
##		first if it isn't here. Under the repo, the crates' own Cargo.toml and
##		README files would turn up in check-docs' greps of the tree.
##		The hosted gate doesn't run --leakcheck, so it doesn't install CodeQL.
##	Syntax:
##		codeql-scan.bash
##		CPU_CAP in the environment caps the threads (default a quarter of the
##		cores).
##	Exit: 0 = clean, 1 = a finding, a missed bait, a dropped file or a bad
##	      suppression, 2 = could not run.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"
cd "${root}"
# shellcheck source-path=SCRIPTDIR
source "${here}/include/test-id.bash"
# shellcheck source-path=SCRIPTDIR
source "${here}/include/stop-descendants.bash"
testWhere=codeql-scan; testCounter=nBad; nBad=0

if (($#)); then echo "codeql-scan: takes no arguments (see the header)" >&2; exit 2; fi

cap="${CPU_CAP:-}"
# shellcheck source-path=SCRIPTDIR
[[ "${cap}" =~ ^[1-9][0-9]*$ ]] || { source "$(dirname -- "${BASH_SOURCE[0]}")/include/cpu-cap.bash"; fCpuCap hard; cap="${CPU_CAP}"; }
((cap > 0)) || cap=1
## For the strings config.bash eval's later, and the run in the image.
CPU_CAP="${cap}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../config.bash
source "${root}/cicd/config.bash"

pinVer=""
for pin in "${TOOL_PINS[@]}"; do
	if [[ "${pin%%|*}" == codeql ]]; then rest="${pin#*|}"; pinVer="${rest%%|*}"; fi
done
[[ -n "${pinVer}" ]] || { echo "codeql-scan: TOOL_PINS has no codeql" >&2; exit 2; }
nightly="$(sed -n '/^\[nightly\]/,/^\[/s/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)"
[[ -n "${nightly}" ]] || { echo "codeql-scan: rust-toolchain.toml names no [nightly] channel" >&2; exit 2; }

art="${root}/cicd/artifacts/codeql"
## The scratch dir has a copy of source/, which under the repo would turn up
## in check-docs' greps of the tree, so it goes beside the container caches.
## In the image that's TMPDIR, which is in the scratch dir outside. Never
## /tmp: a run writes a GB or so.
scratch="${CTR_CACHE}"
if [[ -n "${SHCL_IN_IMAGE:-}" ]]; then scratch="${TMPDIR:?}"; fi
mkdir -p "${art}" "${scratch}"
work="$(mktemp -d "${scratch}/codeql.XXXXXX")"; trap 'fStopDescendants; rm -rf "${work}"' EXIT

skipping=0
missing=()
for t in codeql cc g++ go python3 cargo rustup jq unzip; do
	if ! command -v "${t}" >/dev/null 2>&1; then missing+=("${t}"); fi
done
if command -v codeql >/dev/null 2>&1 && [[ "$(codeql version --format=terse 2>/dev/null)" != "${pinVer}" ]]; then missing+=("codeql ${pinVer}"); fi
if command -v rustup >/dev/null 2>&1 && ! rustup toolchain list 2>/dev/null | grep -q -- "^${nightly}-"; then missing+=("${nightly}"); fi
if ((${#missing[@]})); then
	if [[ -n "${SHCL_IN_IMAGE:-}" ]]; then echo "codeql-scan: the build image has no ${missing[*]}" >&2; exit 2; fi
	# shellcheck source-path=SCRIPTDIR
	source "${here}/include/ctr-image.bash"
	whyNot="$(fCtrWhyNot)"
	if [[ -z "${whyNot}" ]]; then
		## The image has no network, and the Rust extractor reads every crate
		## the lock file names, the optional ones included.
		export SHCL_CTR_CARGO="${CTR_CACHE}/main/cargo"
		CARGO_HOME="${SHCL_CTR_CARGO}" cargo fetch --locked --quiet --manifest-path source/rust/Cargo.toml \
			|| { echo "codeql-scan: could not fetch the crates source/rust/Cargo.lock names" >&2; exit 2; }
		# shellcheck source-path=SCRIPTDIR
		source "${here}/include/ctr-image.bash"
		rc=0; fCtrRunSelf "${work}" "${art}:${SHCL_CTR_CARGO}" "${root}/cicd/utility/codeql-scan.bash" || rc=$?
		exit "${rc}"
	fi
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then echo "codeql-scan: no ${missing[*]}, and no build image, since ${whyNot}; the gate requires them" >&2; nBad=1
	else echo "codeql-scan: skipping, no ${missing[*]}, and no build image, since ${whyNot}" >&2; echo codeql-scan >> "${SHCL_GATE_SKIPS:-/dev/null}"; fi
	skipping=1
fi
if [[ -n "${SHCL_IN_IMAGE:-}" ]]; then
	[[ -n "${SHCL_CTR_CARGO:-}" ]] || { echo "codeql-scan: no SHCL_CTR_CARGO, so no crates for the Rust extractor" >&2; exit 2; }
	export CARGO_HOME="${SHCL_CTR_CARGO}" CARGO_NET_OFFLINE=true
fi

## pass|extractor's name|query pack|source extensions|bait file. The bait
## files are from source/, and planted in the copy only. A pass's language is
## its name up to a dash, and gowin is Go with GOOS=windows.
langs=(
	"cpp|c-cpp|codeql/cpp-queries|c h cpp hpp|c/tests/codeql_bait.c c/tests/codeql_bait.cpp"
	"go|go|codeql/go-queries|go|go/codeql_bait.go"
	"go-win|go|codeql/go-queries|go|go/codeql_bait_windows.go"
	"python|python|codeql/python-queries|py|python/codeql_bait.py"
	"rust|rust|codeql/rust-queries|rs|rust/tests/codeql_bait.rs"
)
## A bait is never a finding, in its own pass or another one that sees it.
allBaits=""
for spec in "${langs[@]}"; do IFS='|' read -r _ _ _ _ b <<<"${spec}"; allBaits+=" ${b}"; done
src="${work}/src"
declare -A baitSeen=() dbFull=() langClean=()
suppressOk=1
start="${SECONDS}"

fBaits(){
	## A stack address kept past its frame, and a new with free.
	printf '%s\n' 'static int *kept;' \
		'static void keep(void) { int x = 1; kept = &x; }' 'int main(void) { keep(); return 0; }' > "${src}/c/tests/codeql_bait.c"
	printf '%s\n' '#include <cstdlib>' \
		'int main() { int *p = new int(1); std::free(p); return 0; }' > "${src}/c/tests/codeql_bait.cpp"
	## A value stored and never read.
	printf '%s\n' 'package shcl' '' 'func codeqlBait(n int) int {' '	n = n * 2' '	return 0' '}' > "${src}/go/codeql_bait.go"
	## The same, in a file only the windows build takes.
	printf '%s\n' 'package shcl' '' 'func codeqlBaitWin(n int) int {' '	n = n * 3' '	return 0' '}' > "${src}/go/codeql_bait_windows.go"
	## A file opened and never closed.
	printf '%s\n' 'def codeql_bait(path):' '    f = open(path)' '    return f.read()' > "${src}/python/codeql_bait.py"
	## A read through a null pointer.
	printf '%s\n' '#[test]' 'fn codeql_bait() {' '	let p: *const u8 = std::ptr::null();' '	let _v = unsafe { *p };' '}' > "${src}/rust/tests/codeql_bait.rs"
}

if ((! skipping)); then
	mkdir -p "${src}" "${work}/obj" "${work}/rtarget" "${art}/db"
	## What git ignores stays out: the CLI builds and every target dir.
	tar -C source --exclude='./rust/target*' --exclude=./c/shcl --exclude=./go/shcl --exclude=./python/build \
		--exclude=./python/dist --exclude='*.egg-info' --exclude=__pycache__ -cf - ./c ./go ./python ./rust | tar -C "${src}" -xf -
	fBaits
	{
		echo 'set -e'
		echo "cd '${src}'"
		for f in "${src}"/c/cmd/shcl/main.c "${src}"/c/tests/*.c; do echo "cc -std=c11 -O0 -g -Ic -c '${f}' -o '${work}/obj/${f##*/}.o'"; done
		for f in "${src}"/c/tests/*.cpp; do echo "g++ -std=c++17 -O0 -g -Ic -c '${f}' -o '${work}/obj/${f##*/}.o'"; done
	} > "${work}/build-c.bash"
	: > "${art}/findings.txt"
	cp -r cicd/codeql/rust-suppression "${work}/rust-suppression"
	if ! (cd "${work}/rust-suppression" && codeql pack install >"${work}/pack.log" 2>&1); then
		cat "${work}/pack.log"; echo "codeql-scan: the Rust suppression query's pack didn't resolve" >&2; exit 2
	fi

	for spec in "${langs[@]}"; do
		IFS='|' read -r lang ext pack exts baits <<<"${spec}"
		db="${art}/db/${lang}"; log="${art}/${lang}-create.log"
		opts=()
		goos="$(go env GOOS 2>/dev/null || echo linux)"
		case "${lang}" in
			cpp)  opts=(--command="bash ${work}/build-c.bash") ;;
			go*)  opts=(-O go.extract_tests=true -O go.extract_vendor_dirs=true) ;;
			rust) opts=(-O "rust.cargo_target_dir=${work}/rtarget") ;;
		esac
		if [[ "${lang}" == go-win ]]; then goos=windows; fi
		echo "codeql-scan: ${lang}: building the database"
		if ! GOOS="${goos}" RUSTUP_TOOLCHAIN="${nightly}" codeql database create "${db}" --language="${ext}" --source-root="${src}" \
			--threads="${cap}" --overwrite "${opts[@]}" >"${log}" 2>&1; then
			tail -n 20 "${log}"; echo "codeql-scan: ${lang}: the database didn't build, see ${log#"${root}/"}" >&2; exit 2
		fi

		## Every source file of the language, against what the database kept.
		listed="$(unzip -Z1 "${db}/src.zip")"
		## Go builds only the files whose build tags fit this platform, and
		## the extractor sees what the build sees. The rest are named, not
		## failed.
		otherOs=""
		if [[ "${lang}" == go* ]]; then
			while IFS= read -r -d '' mod; do
				otherOs+="$(GOOS="${goos}" go -C "${mod%/go.mod}" list -e -f '{{range .IgnoredGoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}' ./...)"$'\n'
			done < <(find "${src}/go" -name go.mod -print0)
			names="${otherOs//"${src}/"/}"
			echo "codeql-scan: ${lang}: left to other platforms by their build tags: ${names//$'\n'/ }"
		fi
		full=1
		for e in ${exts}; do
			while IFS= read -r -d '' f; do
				grep -qxF -- "${f}" <<<"${otherOs}" && continue
				if ! grep -qxF -- "${f#/}" <<<"${listed}"; then echo "codeql-scan: ${lang}: the database left out ${f#"${src}/"}"; full=0; fi
			done < <(find "${src}" -name "*.${e}" -print0)
		done
		if [[ "${lang}" == rust ]] && grep -qE 'failed to load workspace|semantic analyzer unavailable' "${log}"; then
			grep -E 'failed to load workspace' "${log}" | head -n 3
			echo "codeql-scan: rust: the workspace didn't load, so the extraction has no types or macros"; full=0
		fi
		dbFull["${lang}"]="${full}"

		echo "codeql-scan: ${lang}: running ${pack##*/}'s security-and-quality suite"
		if ! codeql database analyze "${db}" "${pack}:codeql-suites/${lang%%-*}-security-and-quality.qls" \
			--format=sarif-latest --output="${art}/${lang}.sarif" --threads="${cap}" --ram=8192 >"${art}/${lang}-analyze.log" 2>&1; then
			tail -n 20 "${art}/${lang}-analyze.log"; echo "codeql-scan: ${lang}: the analysis didn't finish" >&2; exit 2
		fi
		## The suppression comments, from the language's own query. They're
		## matched to the findings here: the CLI's own matching goes wrong
		## after a literal U+2028 or U+2029, which shcl.py's whitespace table
		## has, and it would take a noqa comment as a suppression of anything.
		## query run takes a file, not a pack's query.
		suppress="${work}/rust-suppression/AlertSuppression.ql"
		if [[ "${lang}" != rust ]]; then suppress="$(codeql resolve queries "${pack}:AlertSuppression.ql" 2>/dev/null | head -n 1)"; fi
		if ! codeql query run --database="${db}" --output="${work}/${lang}-sup.bqrs" --threads="${cap}" "${suppress}" >"${work}/${lang}-sup.log" 2>&1 \
			|| ! codeql bqrs decode --format=json --entities=url "${work}/${lang}-sup.bqrs" >"${work}/${lang}-sup.json" 2>>"${work}/${lang}-sup.log"; then
			tail -n 20 "${work}/${lang}-sup.log"; echo "codeql-scan: ${lang}: the suppression query didn't run" >&2; exit 2
		fi
		## file, the line it covers, its own line, the query IDs, the reason.
		jq -r --arg pre "file://${src}/" '.suppressions.tuples[] | select(.[1] | test("(?i)\\bcodeql\\s*\\[")) |
			[(.[3].url.uri | ltrimstr($pre)), (.[3].url.startLine | tostring), (.[0].url.startLine | tostring),
			(.[2] | sub("^lgtm\\["; "") | sub("\\]$"; "")), (.[1] | sub("^[^\\]]*\\]\\s*"; ""))] | @tsv' \
			"${work}/${lang}-sup.json" > "${work}/${lang}-sup.tsv"
		## file, line, query and the message's first line, for every finding.
		jq -r '.runs[].results[] | [(.locations[0].physicalLocation.artifactLocation.uri // "?"),
			(.locations[0].physicalLocation.region.startLine // 0 | tostring), .ruleId, (.message.text | split("\n")[0])] | @tsv' \
			"${art}/${lang}.sarif" > "${work}/${lang}.tsv"
		## The windows pass judges only the files the Linux one left out. The
		## rest it shares, and a suppression there would be stale in one pass.
		if [[ "${lang}" == go-win ]]; then
			winOnly="$(grep -vxF -f <(printf '%s\n' "${otherOs}" | grep .) <<<"${goLinuxOther}" | sed "s|^${src}/||" || true)"
			echo "codeql-scan: go-win: judging ${winOnly//$'\n'/ }"
			for t in "${work}/${lang}-sup.tsv" "${work}/${lang}.tsv"; do
				awk -F'\t' 'NR == FNR { if ($0 != "") keep[$0] = 1; next } ($1 in keep)' <(printf '%s\n' "${winOnly}") "${t}" > "${work}/winonly.tsv"
				mv "${work}/winonly.tsv" "${t}"
			done
		fi
		if [[ "${lang}" == go ]]; then goLinuxOther="${otherOs}"; fi
		## A finding is open unless a codeql[...] line covers it by its query
		## ID, and a suppression that covers nothing is stale.
		awk -F'\t' -v OFS='\t' '
			FILENAME == ARGV[1] {
				if ($5 == "") print "noreason", $1 ":" $3
				n = split($4, ids, /[ ,]+/)
				for (i = 1; i <= n; i++) if (ids[i] != "") { k = $1 SUBSEP $2 SUBSEP ids[i]; sup[k] = 1; at[k] = $1 ":" $3 }
				next
			}
			{ k = $1 SUBSEP $2 SUBSEP $3; if (k in sup) used[k] = 1; else print "open", $0 }
			END { for (k in sup) if (!(k in used)) { split(k, p, SUBSEP); print "stale", at[k], p[3] } }
		' "${work}/${lang}-sup.tsv" "${work}/${lang}.tsv" > "${work}/${lang}-judged.tsv"
		for b in ${baits}; do
			if grep -qP -- "^open\t${b//./\\.}\t" "${work}/${lang}-judged.tsv"; then baitSeen["${b}"]=1
			else baitSeen["${b}"]=0; echo "codeql-scan: ${lang}: nothing reported in the planted ${b##*/}"; fi
		done
		clean=1
		while IFS=$'\t' read -r state uri line rule msg; do
			case "${state}" in
				open)
					case " ${allBaits} " in *" ${uri} "*) continue ;; esac
					echo "codeql: source/${uri}:${line}: ${rule}: ${msg}" | tee -a "${art}/findings.txt"; clean=0 ;;
				noreason) echo "codeql-scan: source/${uri}: a suppression with no reason"; suppressOk=0 ;;
				stale) echo "codeql-scan: source/${uri}: suppresses ${line}, and the line under it has no such finding"; suppressOk=0 ;;
			esac
		done < "${work}/${lang}-judged.tsv"
		langClean["${lang}"]="${clean}"
	done
fi

fJudge(){
	if ((skipping)); then fTestSkip; return 0; fi
	if [[ "$1" != 1 ]]; then nBad=$((nBad + 1)); fi
}
fTest de5a7 reports the planted C finding
fJudge "${baitSeen[c/tests/codeql_bait.c]:-0}"
fTest de5a8 reports the planted C++ finding
fJudge "${baitSeen[c/tests/codeql_bait.cpp]:-0}"
fTest de5a9 reports the planted Go finding
fJudge "${baitSeen[go/codeql_bait.go]:-0}"
fTest de5pg reports the planted Go finding in a windows-only file
fJudge "${baitSeen[go/codeql_bait_windows.go]:-0}"
fTest de5aa reports the planted Python finding
fJudge "${baitSeen[python/codeql_bait.py]:-0}"
fTest de5ab reports the planted Rust finding
fJudge "${baitSeen[rust/tests/codeql_bait.rs]:-0}"
fTest de5ac the C and C++ database has every C and C++ file
fJudge "${dbFull[cpp]:-0}"
fTest de5ad the Go database has every Go file, tests included
fJudge "${dbFull[go]:-0}"
fTest de5ph the windows Go database has every Go file the windows build takes
fJudge "${dbFull[go-win]:-0}"
fTest de5ae the Python database has every Python file
fJudge "${dbFull[python]:-0}"
fTest de5af the Rust database has every Rust file, with its workspace loaded
fJudge "${dbFull[rust]:-0}"
fTest de5ag nothing found in the C and C++ code
fJudge "${langClean[cpp]:-0}"
fTest de5ah nothing found in the Go code
fJudge "${langClean[go]:-0}"
fTest de5pj nothing found in the windows-only Go files
fJudge "${langClean[go-win]:-0}"
fTest de5aj nothing found in the Python code
fJudge "${langClean[python]:-0}"
fTest de5ak nothing found in the Rust code
fJudge "${langClean[rust]:-0}"
fTest de5am every suppression gives its reason and covers a finding
fJudge "${suppressOk}"
fTestEnd
if ((nBad)); then exit 1; fi
if ((! skipping)); then
	echo "codeql-scan: OK: nothing found in the 5 languages, every bait was caught, and the databases and SARIF are in cicd/artifacts/codeql/ ($((SECONDS - start)) s)"
fi
exit 0


##	History:
##		- 2026-10-19 JC: Created.
##		- 2026-10-19 JC: Go windows pass.
##		- 2026-10-19 JC: The build image only when docker answers.
