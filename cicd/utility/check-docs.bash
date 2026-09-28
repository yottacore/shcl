#!/usr/bin/env bash

##	Purpose:
##		Document invariants that no linter checks and that a review round has
##		already found broken. Prose is mostly a matter of taste and stays out of
##		here; what goes in is a claim the documents make about themselves.
##	Syntax:
##		check-docs.bash [ROOT]
##	Exit: 0 = clean, 1 = a check failed, 2 = usage or missing input.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

repoDir="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -d "${repoDir}" ]] || { echo "check-docs: no such directory: ${repoDir}" >&2; exit 2 ;}
declare -i nBad=0
fBad(){ echo "check-docs: $1" >&2; nBad+=1 ;}
testWhere="check-docs"; testCounter="nBad"
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"

fTest Ep19Ax7 default-ops-in-help-table
##	Every write op the CLI dispatches with a -default form has to be spelled in
##	the help's op table, either by its own `name[-default]` entry or by the
##	`<type>[-array]-default` line that covers the typed scalars and arrays.
##	`raw-default` was accepted for a year and named nowhere.
mainRs="${repoDir}/source/rust/src/main.rs"
defaultOps="$(sed -n '/^fn apply_op/,/^}/p' "${mainRs}" | { grep -oE '"[a-z-]+-default" =>' || true ;} | tr -d '"=> ' | sort -u)"
[[ -n "${defaultOps}" ]] || fBad "main.rs: found no -default write ops in apply_op, so the op-table check had nothing to compare"
while IFS= read -r op; do
	[[ -n "${op}" ]] || continue
	base="${op%-default}"
	case "${base}" in
		int|float|bool|string|datetime|*-array) continue ;;
	esac
	grep -qF -- "  ${base}[-default]<TAB>" "${mainRs}" || fBad "write op ${op} is dispatched but the help's op table never spells ${base}[-default]"
done <<<"${defaultOps}"

fTest Eqp7thg python-version-matches-cargo
##	Cargo.toml is the version source, and the crosscheck holds the four CLIs to
##	it. The Python package's own version is read by nothing but pip, so a bump
##	that misses it goes out to PyPI under the old number.
cargoVer="$(sed -n '/^version = "/{s/^version = "\(.*\)"$/\1/p;q;}' "${repoDir}/source/rust/Cargo.toml" || true)"
pyVer="$(sed -n '/^version = "/{s/^version = "\(.*\)"$/\1/p;q;}' "${repoDir}/source/python/pyproject.toml" || true)"
[[ -n "${cargoVer}" && "${cargoVer}" == "${pyVer}" ]] \
	|| fBad "source/python/pyproject.toml is version '${pyVer}', but Cargo.toml says '${cargoVer}'"

fTest EpPR0oa migrate-section-in-spec-and-man
##	`migrate` is the one path across the 3.0 lexical change, and it needs a
##	place in the spec and the man page that says what it rewrites and what it
##	leaves alone. A doc pass once tidied the section away.
grep -q '^## Migrating from 2.x$' "${repoDir}/project/spec.md" || fBad "spec.md has no 'Migrating from 2.x' section"
grep -q '^\.SH MIGRATING FROM 2\.X$' "${repoDir}/source/man/shcl.1" || fBad "the man page has no MIGRATING FROM 2.X section"

fTest EoUst0C legal-disclaimer-not-reversed
##	A disclaimer that says the opposite of what it means is worse than none, and
##	these documents invite verbatim reuse, so the error travels. One negation in
##	the sentence is the disclaimer; two is "None of this is not legal advice".
##	The backlog quotes the broken wording as a finding, so it is not a document
##	making the claim and does not belong here.
while IFS= read -r hit; do
	fBad "reversed legal-advice disclaimer: ${hit}"
done < <(grep -rn "legal advice" --include='*.md' "${repoDir}" \
	| grep -v '/backlog\.md:' \
	| awk -F: 'BEGIN { neg = "(^|[^a-z])(no|none|not|never|nothing|nobody)([^a-z]|$)" }
	{
		loc = $1 ":" $2
		text = $0
		sub(/^[^:]*:[0-9]+:/, "", text)
		n = split(text, part, /\. /)
		for (i = 1; i <= n; i++) {
			if (part[i] !~ /legal advice/) continue
			low = tolower(part[i]); cnt = 0
			while (match(low, neg)) { cnt++; low = substr(low, RSTART + RLENGTH - 1) }
			if (cnt > 1) print loc ": " part[i]
		}
	}' || true)

fTest EoUw6nI backlog-done-sections-in-order
##	The backlog states an order for its finished sections and then drifted out of
##	it twice: rounds, loose items, rounds again. Loose items first, rounds after,
##	each run newest first.
backlog="${repoDir}/project/backlog.md"
if [[ -f "${backlog}" ]]; then
	while IFS= read -r problem; do fBad "${problem}"; done < <(awk '
		/^#+ / {
			if (heading != "") check()
			heading = ($0 ~ /Done|Canceled/) ? $0 : ""
			seenRound = 0; prevRound = ""; problem = ""
			next
		}
		heading != "" && /^- / {
			isRound = ($0 ~ /^- Code review [0-9]{8}[a-z]?:/)
			if (isRound) {
				tag = $0; sub(/^- Code review /, "", tag); sub(/:.*$/, "", tag)
				if (prevRound != "" && tag > prevRound && problem == "") problem = heading ": rounds out of order at " tag
				prevRound = tag; seenRound = 1
			} else if (seenRound && problem == "") {
				problem = heading ": a loose item sits below a code-review round"
			}
		}
		END { if (heading != "") check() }
		function check() { if (problem != "") print problem }
	' "${backlog}")
fi

fTest EqjdNqC doc-comments-on-the-right-declaration
##	A doc comment stranded on the wrong declaration came back four rounds running,
##	each time from code inserted between a comment and its function. Two places
##	can be read mechanically. A Go comment opens with the name it documents, so
##	one opening with another name declared in the package has moved. And every
##	veneer declaration that starts a group carries a comment, so the one left
##	bare when its comment moved shows. The attribute and a signature that wraps
##	still count as a declaration.
while IFS= read -r problem; do fBad "${problem}"; done < <(
	for pkg in "${repoDir}/source/go" "${repoDir}/source/go/cmd/shcl"; do
		LC_ALL=C awk -v root="${repoDir}/" '
			{ line[FILENAME, FNR] = $0; if (FNR > last[FILENAME]) last[FILENAME] = FNR; files[FILENAME] = 1 }
			match($0, /^(func (\([^)]*\) )?|type |var |const )[A-Za-z_][A-Za-z0-9_]*/) {
				nm = substr($0, RSTART, RLENGTH); sub(/.* /, "", nm); declared[nm] = 1
			}
			END {
				for (f in files) for (i = 2; i <= last[f]; i++) {
					if (!match(line[f, i], /^(func (\([^)]*\) )?|type |var |const )[A-Za-z_][A-Za-z0-9_]*/)) continue
					nm = substr(line[f, i], RSTART, RLENGTH); sub(/.* /, "", nm)
					j = i - 1; if (line[f, j] !~ /^\/\//) continue
					while (j > 1 && line[f, j - 1] ~ /^\/\//) j--
					w = line[f, j]; sub(/^\/\/[ \t]*/, "", w); sub(/[^A-Za-z0-9_].*$/, "", w)
					if (w != nm && (w in declared)) { g = f; sub(root, "", g); print g ":" j ": the comment for " w " sits on " nm }
				}
			}' "${pkg}"/*.go
	done
	LC_ALL=C awk '
		/^class Document/ { inDoc = 1 }
		inDoc && /^};/ { inDoc = 0 }
		inDoc && /^\t(\[\[nodiscard\]\] )?[A-Za-z][^(]*\(/ && !/^\t(return|if|for|while|public|private)/ {
			if (prev ~ /^[ \t]*$/ || prev ~ /^\t(public|private):/) print "source/c/shcl.hpp:" FNR ": a declaration heads a group with no comment above it"
		}
		{ prev = $0 }' "${repoDir}/source/c/shcl.hpp"
)

fTest Er1z2hU public-items-documented
##	Two rounds filled in public declarations that had no comment at all: about
##	sixty Go functions, the whole writer API among them, and sixty items in the
##	reference. An exported Go name needs a comment right above it; a method on an
##	unexported type is not exported. A Rust pub item needs a `///` above it, past
##	its attributes and any plain comment. Struct fields and enum variants are
##	left out, which is what keeps this from being rustc's missing_docs.
mapfile -t goSrcs < <(find "${repoDir}/source/go" -name '*.go' ! -name '*_test.go' | LC_ALL=C sort)
((${#goSrcs[@]})) || fBad "found no Go sources for the doc comment check"
while IFS= read -r problem; do fBad "${problem}"; done < <(
	LC_ALL=C awk -v root="${repoDir}/" '
		FNR == 1 { prev = "" }
		match($0, /^(func (\([^)]*\) )?|type )[A-Z][A-Za-z0-9_]*/) {
			decl = substr($0, RSTART, RLENGTH)
			recv = decl; sub(/\) .*/, "", recv); sub(/.*[ *]/, "", recv); sub(/\[.*/, "", recv)
			if (decl !~ /^func \(/ || recv ~ /^[A-Z]/) if (prev !~ /^\/\//) {
				f = FILENAME; sub(root, "", f); nm = decl; sub(/.* /, "", nm)
				print f ":" FNR ": exported " nm " has no doc comment"
			}
		}
		{ prev = $0 }' "${goSrcs[@]}"
	LC_ALL=C awk -v f="source/rust/src/lib.rs" '
		{ line[NR] = $0 }
		END {
			for (i = 2; i <= NR; i++) {
				if (line[i] !~ /^[ \t]*pub (const |unsafe |async )*(fn|struct|enum|type|const|trait|static|mod|union) /) continue
				j = i - 1
				while (j > 1 && (line[j] ~ /^[ \t]*#\[/ || line[j] ~ /^[ \t]*\/\/([^\/!]|$)/)) j--
				if (line[j] !~ /^[ \t]*\/\/\//) { nm = line[i]; sub(/^[ \t]*/, "", nm); sub(/[({<:=].*/, "", nm); print f ":" i ": " nm " has no doc comment" }
			}
		}' "${repoDir}/source/rust/src/lib.rs"
)

fTest Er1z2hV c-banned-string-calls-and-goto
##	The C rules: never sprintf, strcpy or strcat, nor their wide forms, and no
##	goto but the cleanup unwind. Seven old sites were each bounded by
##	construction, which is the reasoning the rule is there to stop. The tests
##	stay out, since they build fixtures and never ship.
for src in shcl.h shcl.hpp cmd/shcl/main.c; do
	while IFS= read -r hit; do fBad "source/c/${src}:${hit}"; done < <(
		LC_ALL=C awk '
			{ s = $0; sub(/\/\/.*/, "", s) }
			s ~ /(^|[^A-Za-z0-9_])(v?sprintf|strcpy|strcat|wcscpy|wcscat|gets)[ \t]*\(/ { print FNR ": calls a string function the C rules forbid; use snprintf or the builder" }
			s ~ /(^|[^A-Za-z0-9_])goto[ \t]/ && s !~ /goto[ \t]+cleanup/ { print FNR ": a goto that is not the cleanup unwind" }' "${repoDir}/source/c/${src}")
done

fTest Er1z2hW explain-codes-match-spec
##	`explain` is where a user looks a code up, and the spec is where the rule
##	behind it lives. E001 to E015 and H001 were once in neither. Every code the
##	reference lists has a row in a spec table, and every row names a live code.
explainCodes="$(sed -n '/^const CODES: &str = "/,/^";$/p' "${mainRs}" | grep -oE '^[EHV][0-9]{3}' | LC_ALL=C sort -u || true)"
# shellcheck disable=SC2016  ## the backticks are markdown, not command substitution
specCodes="$(grep -E '^\| `[EHV][0-9]{3}`' "${repoDir}/project/spec.md" | cut -d'|' -f2 | grep -oE '[EHV][0-9]{3}' | LC_ALL=C sort -u || true)"
if [[ -z "${explainCodes}" || -z "${specCodes}" ]]; then
	fBad "the explain-against-spec code check read an empty side"
else
	while IFS= read -r code; do
		if [[ -n "${code}" ]]; then fBad "explain lists ${code}, and no spec.md table row names it"; fi
	done < <(LC_ALL=C comm -23 <(printf '%s\n' "${explainCodes}") <(printf '%s\n' "${specCodes}"))
	while IFS= read -r code; do
		if [[ -n "${code}" ]]; then fBad "spec.md has a row for ${code}, which explain does not list"; fi
	done < <(LC_ALL=C comm -13 <(printf '%s\n' "${explainCodes}") <(printf '%s\n' "${specCodes}"))
fi

fTest EoXE67k no-shared-library-claim
##	The documents list five integration modes, two of which are a shared library.
##	Nothing in the tree builds one - no crate-type, no export macro in the C
##	header, and the release stage produces binaries, packages and the drop-in
##	tarball. So a document may describe compiling one, but may not offer it as
##	something already built. If a build for it is ever added, this check is what
##	says the wording may go back.
buildsSharedLib=0
if grep -rqE 'crate-type[^=]*=[^]]*(cdylib|dylib|staticlib)' --include='Cargo.toml' "${repoDir}"; then
	buildsSharedLib=1
fi
if ((! buildsSharedLib)); then
	while IFS= read -r hit; do
		fBad "offers a shared library as already built, and nothing builds one: ${hit}"
	done < <(grep -rniE '(prebuilt|pre-built|published|shipped)[^.]*\.(so|dll|dylib)|\b(prebuilt|pre-built)\b[^.]*shared librar' \
		--include='*.md' "${repoDir}" | grep -v '/backlog\.md:' || true)
fi

fTest EoXVY4O installer-tar-prerequisite
##	The Windows installer refuses outright without `tar`, and the README's
##	prerequisites used to cover only the Linux side, so the requirement was
##	reachable only by running it and failing.
ps1="${repoDir}/install.ps1"
readme="${repoDir}/README.md"
if [[ -f "${ps1}" && -f "${readme}" ]] && grep -q "needs tar to unpack" "${ps1}"; then
	grep -qE '(^|[^a-z])tar([^a-z]|$).*[Ww]indows|[Ww]indows.*(^|[^a-z])tar([^a-z]|$)' "${readme}" \
		|| fBad "install.ps1 requires tar and README.md never says so on the Windows side"
fi

fTest EqKhPQP install-ps1-ascii-no-bom
##	The README runs install.ps1 through `irm | iex`, and irm keeps a byte-order
##	mark as the first character, which puts `param` second and fails the parse.
##	Every test ran the file with -File, which strips the mark. So the file stays
##	ASCII with no mark: nothing then needs one, PSScriptAnalyzer's BOM rule
##	included. The parse below reads the bytes the way irm hands them over.
##	The other PowerShell files follow suit. Windows PowerShell 5.1 reads a file
##	with no mark in the ANSI code page, so ASCII is the one text that needs
##	none anywhere.
if git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	while IFS= read -r f; do
		[[ -f "${repoDir}/${f}" ]] || continue
		[[ "$(head -c3 "${repoDir}/${f}" | od -An -tx1 | tr -d ' \n')" == efbbbf ]] \
			&& fBad "${f} starts with a byte-order mark; PowerShell files stay ASCII with no mark"
		LC_ALL=C grep -qP '[^\x00-\x7F]' "${repoDir}/${f}" \
			&& fBad "${f} holds a non-ASCII byte; PowerShell files stay ASCII so they need no byte-order mark"
	done < <(git -C "${repoDir}" ls-files '*.ps1' '*.psm1' '*.psd1' || true)
fi
if [[ -f "${ps1}" ]]; then
	if command -v pwsh >/dev/null; then
		# shellcheck disable=SC2016  ## PowerShell text, expanded by pwsh
		nParse="$(SHCL_PS1="${ps1}" pwsh -NoProfile -NonInteractive -Command '$t = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($env:SHCL_PS1)); $e = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e); $e.Count' 2>/dev/null || true)"
		[[ "${nParse}" == 0 ]] || fBad "install.ps1 does not parse from its raw bytes, the way irm | iex reads it (${nParse:-no answer})"
	elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		fBad "no pwsh to parse install.ps1 with, and the gate requires it"
	else
		echo "check-docs: SKIPPED the install.ps1 parse - no pwsh"
		echo check-docs >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fi
fi

fTest EqKhPQQ go-test-count-1
##	The corpus sits outside the Go module, so go's test cache cannot see a
##	changed case and answers `ok (cached)` over a broken golden. Every go test
##	a gate runs passes -count=1.
while IFS= read -r hit; do
	fBad "go test without -count=1, which a cached pass hides a corpus change behind: ${hit}"
done < <(grep -nE '(^|[^a-z])go (-C [^ ]+ )?test' "${repoDir}/cicd/config.bash" "${repoDir}/cicd/utility/win-runners.bash" \
	| grep -v -e '-count=1' -e ':[0-9]*:[[:space:]]*#' || true)

fTest EqL4fPc withdrawn-lexical-wording-gone
##	Two lexical rules were withdrawn and their wording outlived them, one site
##	per round: a `#` ending a value only behind a blank (2026-09-06, replaced
##	on 2026-09-10 by a `#` outside quotes always opening a comment), and an open
##	quote running to the line end (2.x). The documents that state the current
##	rules may not carry the old phrasing. The changelog is history and is left
##	out.
# shellcheck disable=SC2016  ## the backticks are markdown, not command substitution
while IFS= read -r hit; do
	fBad "states a withdrawn lexical rule: ${hit}"
done < <(grep -nHiE 'behind a blank|a `#` anywhere else|swallowing the trailing comment|comma hides inside the open quote' \
	"${repoDir}/README.md" "${repoDir}/project/style-guide_code.md" "${repoDir}/project/spec.md" "${repoDir}/project/design.md" \
	"${repoDir}/project/conformance/README.md" "${repoDir}/source/man/shcl.1" 2>/dev/null | sed "s|^${repoDir}/||" || true)

fTest EqL4fPd corpus-readme-notes-every-case
##	contributing.md says the corpus README carries a note per case, and 58
##	cases went without one. Every case directory has to be named in a note,
##	alone (`044`) or as the edge of a range (`014`-`016`).
corpusDir="${repoDir}/project/conformance"
if [[ -f "${corpusDir}/README.md" ]]; then
	# shellcheck disable=SC2016  ## the backticks are markdown, not command substitution
	noted="$(grep -oE '`[0-9]{3}`(-`[0-9]{3}`)?' "${corpusDir}/README.md" | tr -d '`' || true)"
	for d in "${corpusDir}"/[0-9][0-9][0-9]-*/; do
		[[ -d "${d}" ]] || continue
		n="${d%/}"; n="${n##*/}"; n="${n%%-*}"
		found=0
		while IFS= read -r r; do
			[[ -n "${r}" ]] || continue
			lo="${r%%-*}"; hi="${r##*-}"
			if ((10#${n} >= 10#${lo} && 10#${n} <= 10#${hi})); then found=1; break; fi
		done <<<"${noted}"
		((found)) || fBad "project/conformance/README.md has no note for case ${n}"
	done
fi

fTest EqL3TGq spdx-and-copyright-headers
##	The style guide says every source file starts with the SPDX line and the
##	copyright, and files added later kept arriving without them. "Starts with"
##	means the header block, which in a script comes after the purpose text, so
##	the first 80 lines are searched. One awk over every file, since a head and a
##	grep per file were most of this script's time. An empty file never reaches
##	awk's first line, so it is caught before.
if git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	hdrFiles=()
	while IFS= read -r f; do
		[[ -f "${repoDir}/${f}" ]] || continue
		if [[ ! -s "${repoDir}/${f}" ]]; then fBad "${f} has no SPDX line in its header"; fBad "${f} has no copyright line in its header"; continue; fi
		hdrFiles+=("${repoDir}/${f}")
	done < <(git -C "${repoDir}" ls-files -- '*.rs' '*.go' '*.py' '*.c' '*.h' '*.hpp' '*.cpp' '*.bash' '*.ps1' || true)
	while IFS=$'\t' read -r f what; do
		fBad "${f#"${repoDir}/"} has no ${what} line in its header"
	done < <(((${#hdrFiles[@]})) && LC_ALL=C awk '
		function report() { if (!spdx) print name "\tSPDX"; if (!copy) print name "\tcopyright" }
		FNR == 1 { if (name != "") report(); name = FILENAME; spdx = 0; copy = 0 }
		FNR > 80 { nextfile }
		/SPDX-License-Identifier/ { spdx = 1 }
		/Copyright/ { copy = 1 }
		END { if (name != "") report() }' "${hdrFiles[@]}")
fi

fTest EqSvlSq copyright-marker-bytes
##	The marker in a copyright line is a fixed run of bytes to be copied, never
##	retyped. One arrived with a Georgian letter one code point off the right
##	one and read the same on screen, and the check above only asks for the word
##	"Copyright". So compare the bytes. The PowerShell files and rust/build.rs
##	are the sanctioned ASCII forms with no marker, and the shared cicd/utility
##	scripts carry the Bubbles form.
if git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	marker='[ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]'
	mkFiles=()
	while IFS= read -r f; do
		[[ -f "${repoDir}/${f}" ]] || continue
		[[ "${f}" == *.ps1 || "${f}" == "source/rust/build.rs" ]] && continue
		mkFiles+=("${repoDir}/${f}")
	done < <(git -C "${repoDir}" ls-files || true)
	##	The first marker line in each file's first 80, as a head and a grep -m1
	##	per file found it.
	while IFS=$'\t' read -r f line; do
		[[ "${line}" == *"${marker}"* ]] || fBad "${f#"${repoDir}/"} carries a copyright marker that is not the canonical bytes"
	done < <(((${#mkFiles[@]})) && LC_ALL=C awk '
		FNR > 80 { nextfile }
		/Copyright.*ID:/ { print FILENAME "\t" $0; nextfile }' "${mkFiles[@]}")
fi

fTest EqzuifI contact-address-spelling
##	20260920b item 21: a contact address people read is spelled with the
##	circled A, not as a plain address, and three had sat on an old domain. The
##	code of conduct is the Contributor Covenant's own text, nfpm.yaml is read
##	by a packaging tool as an email, and the backlog quotes old findings.
if git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	while IFS= read -r hit; do
		fBad "${hit%%:*}: a plain shcl@ address where a reader wants the circled-A form (line ${hit#*:})"
	done < <(git -C "${repoDir}" grep -nIE -o 'shcl@[A-Za-z0-9-]+\.[A-Za-z]' -- . ':!*code_of_conduct.md' ':!cicd/packaging/nfpm.yaml' ':!project/backlog.md' | cut -d: -f1,2 || true)
fi

fTest EqzuifJ c-section-rules
##	20260920b item 22: the C file's section rules are `// --- <title> ---`, and
##	`// ====` is kept for the one header and implementation split. The Rust and
##	Go three-line form and a second `// ====` both turned up there once.
cHeader="${repoDir}/source/c/shcl.h"
if [[ -f "${cHeader}" ]]; then
	nSplit="$(grep -cE '^// =+$' "${cHeader}" || true)"
	[[ "${nSplit}" == 1 ]] || fBad "source/c/shcl.h has ${nSplit} '// ====' lines; the one header and implementation split is the only one"
	while IFS= read -r hit; do
		fBad "source/c/shcl.h:${hit%%:*}: a section rule not in the C form '// --- <title> ---'"
	done < <(grep -nE '^// -{3}' "${cHeader}" | { grep -vE '^[0-9]+:// --- .*[^ -].* -+$' || true ;})
fi

fTest EqjsQiu no-old-org-path
##	The repo moved to the yottacore org, and a sweep for the old owner path
##	missed the man page's troff spelling. The old path redirects, so nothing
##	breaks when one comes back; it just goes stale. Past changelog entries and
##	the backlog name it on purpose.
if git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	while IFS= read -r hit; do
		fBad "${hit%%:*}: names the old repo path, not yottacore/shcl (line ${hit#*:})"
	done < <(git -C "${repoDir}" grep -nIE -o 'jim.{0,4}collier/shcl' -- . ':!changelog.md' ':!project/backlog.md' | cut -d: -f1,2 || true)
fi

fTest EqvmQhs us-spelling
##	US spelling. "model" and "label" with a doubled l came back two rounds
##	running, each closed by a sweep that left nothing behind. The -ise forms go by stem, so
##	promise, premise, treatise and arise pass. The code of conduct is the
##	Contributor Covenant's own text, and the backlog quotes old findings.
if git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	british='\b(label|model|travel|cancel|signal|level|fuel|channel|tunnel|total|marshal)l(ed|ing|er|ers)\b'
	british+='|\b(col|behavi|fav|hon|flav|lab|neighb|harb|rum|hum|arm|vap|od|endeav|sav|rig|vig|cand)our(s|ed|ing|ite|ites|able|ably|ful|less|ly)?\b'
	british+='|\b[a-z]+(al|an|ar|en|er|gn|ic|il|im|it|ol|on|or)is(e|ed|es|er|ers|ing|ation|ations)\b'
	british+='|\b(custom|random|econom)is(e|ed|es|er|ers|ing|ation|ations)\b|\b(ana|para|cata)lys(e|ed|es|er|ers|ing)\b'
	british+='|\blicence\b|\b(cent|fib|lit|theat)re(s|d)?\b|\b(defen|offen|preten)ce\b|\bartefacts?\b'
	while IFS= read -r hit; do
		fBad "British spelling: ${hit}"
	done < <(git -C "${repoDir}" grep -nIiEo "${british}" -- . ':!project/backlog.md' ':!*code_of_conduct.md' || true)
fi

##	The grammar is the oracle harnesses are written against. It has to read as
##	ABNF and derive what the parser reads; the samples live in check-abnf.py,
##	which prints its own tests.
fTestEnd
python3 "${repoDir}/cicd/utility/check-abnf.py" "${repoDir}/project/grammar.abnf" \
	|| fBad "project/grammar.abnf failed check-abnf.py (run it for the detail)"

fTest EqL29qS man-page-date-current
##	The man page carries a revision date and no version, and the date went
##	stale on the next edit twice. The rule: the .TH date is no earlier than the
##	last commit that touched the page. A commit that edits the page and bumps
##	the date the same day passes, and so does a bump not yet committed. A
##	shallow clone has only its tip commit, whose date says nothing about the
##	page, so there it is skipped.
man="${repoDir}/source/man/shcl.1"
if [[ -f "${man}" ]] && git -C "${repoDir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	if [[ "$(git -C "${repoDir}" rev-parse --is-shallow-repository 2>/dev/null || true)" == true ]]; then
		echo "check-docs: skipping the man page date check (shallow clone)"
	else
		thDate="$(sed -nE 's/^\.TH [^ ]+ [^ ]+ ([0-9]{4}-[0-9]{2}-[0-9]{2}) .*/\1/p' "${man}" | head -n1)"
		lastEdit="$(git -C "${repoDir}" log -1 --format=%cs -- source/man/shcl.1 2>/dev/null || true)"
		if [[ -z "${thDate}" ]]; then
			fBad "source/man/shcl.1 has no YYYY-MM-DD date on its .TH line"
		elif [[ -n "${lastEdit}" && "${thDate}" < "${lastEdit}" ]]; then
			fBad "source/man/shcl.1 .TH date ${thDate} is older than its last commit, ${lastEdit}"
		fi
	fi
fi

fTest EqQW89I performance-numbers-match-results
##	The README's performance numbers and design.md's table come out of
##	cicd/utility/comparison/, which is not a gate and runs only when asked. They
##	sat at 1.2.0 figures for two majors, and the only thing saying how old they
##	were was a date in design.md's prose. The rule: that date is the day of the
##	newest run in results.shcl. Refreshing one without the other then goes red
##	instead of leaving a currency claim nobody can check.
cmpResults="${repoDir}/cicd/utility/comparison/results.shcl"
designDoc="${repoDir}/project/design.md"
if [[ -f "${cmpResults}" && -f "${designDoc}" ]]; then
	newestRun="$(sed -nE 's/^run: ([0-9]{8})-[0-9]{6}[[:space:]]*$/\1/p' "${cmpResults}" | sort | tail -n1)"
	rerunDate="$(sed -nE 's/.*rerun on ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' "${designDoc}" | head -n1)"
	if [[ -z "${newestRun}" ]]; then
		fBad "cicd/utility/comparison/results.shcl carries no run: stamp"
	elif [[ -z "${rerunDate}" ]]; then
		fBad "project/design.md no longer says when the format comparison was last rerun"
	elif [[ "${rerunDate}" != "${newestRun:0:4}-${newestRun:4:2}-${newestRun:6:2}" ]]; then
		fBad "project/design.md says the comparison was rerun on ${rerunDate}, but the newest run in results.shcl is ${newestRun}: rerun cicd/utility/comparison/ and refresh the numbers, or fix the date"
	fi
	##	The date above is not the numbers. Both documents print two ratios in
	##	prose, and the 2026-09-19 rerun refreshed the tables and left the Python
	##	one at a figure two runs and a major old. Both are derived here from the
	##	same run the tables come from. The tier's `toml` library is `tomllib` in
	##	Python and `toml` in Rust; each document's own wording is matched, so a
	##	reworded sentence has to come back through here.
	cmpBin="${repoDir}/source/rust/target/debug/shcl"
	newestStamp="$(sed -nE 's/^run: ([0-9]{8}-[0-9]{6})[[:space:]]*$/\1/p' "${cmpResults}" | sort | tail -n1)"
	if [[ -x "${cmpBin}" && -n "${newestStamp}" ]]; then
		fRatio(){  ## fRatio TIER: shcl's parse time over that tier's toml reader, one decimal
			local tier="$1" mine theirs
			mine="$("${cmpBin}" get --float "${cmpResults}" "run[${newestStamp}].tier[${tier}].library[shcl].rank-parse-secs" 2>/dev/null || true)"
			theirs="$("${cmpBin}" get --float "${cmpResults}" "run[${newestStamp}].tier[${tier}].library[toml].rank-parse-secs" 2>/dev/null || true)"
			awk -v a="${mine}" -v b="${theirs}" 'BEGIN { if (b + 0 > 0) printf "%.1f", a / b }'
		}
		pyRatio="$(fRatio python)"; rustRatio="$(fRatio rust)"
		if [[ -z "${pyRatio}" || -z "${rustRatio}" ]]; then
			fBad "could not read the newest comparison run's parse times out of results.shcl"
		else
			#  shellcheck disable=2016  ## the backticks are the document's own markdown.
			grep -qF "SHCL reads ${pyRatio} times slower than \`tomllib\`; in Rust, ${rustRatio} times slower than \`toml\`" "${readme}" \
				|| fBad "README.md: the performance sentence does not print the newest run's ratios (${pyRatio} Python, ${rustRatio} Rust)"
			#  shellcheck disable=2016  ## the backticks are the document's own markdown.
			grep -qF "SHCL ${pyRatio}x behind \`tomllib\`" "${designDoc}" \
				|| fBad "project/design.md: the Python tier bullet does not print the newest run's ratio (${pyRatio})"
			#  shellcheck disable=2016  ## the backticks are the document's own markdown.
			grep -qF "${rustRatio}x behind \`toml\` in Rust" "${designDoc}" \
				|| fBad "project/design.md: the Rust tier figure does not print the newest run's ratio (${rustRatio})"
		fi
		##	20260918b item 47: three more sentences had drifted from the file
		##	they cite - SHCL's place in each tier, how close its gzipped file
		##	comes to the smallest, and the schema shape's read time and sizes.
		fRead(){  ## fRead TYPE PATH: every value at PATH under the newest run, one per line
			"${cmpBin}" get "--$1" --array "${cmpResults}" "run[${newestStamp}].$2" 2>/dev/null || true
		}
		fPlace(){  ## fPlace TIER: shcl's place by rank-parse-secs, as the documents word it
			awk -v m="$(fRead float "tier[$1].library[shcl].rank-parse-secs")" '
				BEGIN { split("first second third fourth fifth sixth seventh eighth ninth tenth", ord, " ")
					split("one two three four five six seven eight nine ten", num, " ") }
				{ n++; if ($1 + 0 < m + 0) p++ }
				END { p++; if (m == "" || n < 2 || n > 10) exit; print (p == n) ? "last" : ord[p] " of " num[n] }' \
				<<<"$(fRead float "tier[$1].library[*].rank-parse-secs")"
		}
		rustPlace="$(fPlace rust)"; pyPlace="$(fPlace python)"
		if [[ -z "${rustPlace}" || -z "${pyPlace}" ]]; then
			fBad "could not read the newest comparison run's tier order out of results.shcl"
		else
			for verb in sorts loads; do
				grep -qF "SHCL ${verb} ${rustPlace} in Rust and ${pyPlace} in Python" "${designDoc}" \
					|| fBad "project/design.md: 'SHCL ${verb} ...' does not give the newest run's places (${rustPlace} in Rust, ${pyPlace} in Python)"
			done
		fi
		##	The gzip spread is the widest over the Rust tier's shapes, rounded up,
		##	so "within N%" is both true and the tightest whole number.
		gzSpread=""
		while IFS= read -r shape; do
			[[ -n "${shape}" ]] || continue
			gzSpread="$(awk -v m="$(fRead int "tier[rust].shape[${shape}].library[shcl].gzip-bytes")" -v w="${gzSpread:-0}" '
				NR == 1 || $1 + 0 < lo { lo = $1 + 0 }
				END { if (m == "" || lo <= 0) exit; s = (m / lo - 1) * 100; if (s < w) s = w; print s }' \
				<<<"$(fRead int "tier[rust].shape[${shape}].library[*].gzip-bytes")")"
			[[ -n "${gzSpread}" ]] || break
		done < <("${cmpBin}" instances "${cmpResults}" "run[${newestStamp}].tier[rust].shape" 2>/dev/null || true)
		if [[ -z "${gzSpread}" ]]; then
			fBad "could not read the newest comparison run's gzip sizes out of results.shcl"
		else
			gzPct="$(awk -v s="${gzSpread}" 'BEGIN { c = int(s); if (c < s) c++; print c }')"
			grep -qF "Gzipped, SHCL is within ${gzPct}% of the smallest file" "${designDoc}" \
				|| fBad "project/design.md: the gzip sentence does not say within ${gzPct}%, the newest run's widest gap"
		fi
		##	The README's schema section: SHCL's size against JSON and XML, and a
		##	read time given as a fraction of a second, which has to be true.
		ddlSecs="$(fRead float "tier[rust].shape[ddl].library[shcl].parse-secs")"
		ddlSizes="$(fRead int "tier[rust].shape[ddl].library[shcl].bytes") $(fRead int "tier[rust].shape[ddl].library[json].bytes") $(fRead int "tier[rust].shape[ddl].library[xml].bytes")"
		read -r ddlShcl ddlJson ddlXml <<<"${ddlSizes}"
		if [[ -z "${ddlSecs}" || -z "${ddlXml:-}" ]]; then
			fBad "could not read the newest comparison run's schema shape out of results.shcl"
		else
			vsJson="$(awk -v a="${ddlShcl}" -v b="${ddlJson}" 'BEGIN { printf "%.0f", (1 - a / b) * 100 }')"
			vsXml="$(awk -v a="${ddlShcl}" -v b="${ddlXml}" 'BEGIN { printf "%.0f", (1 - a / b) * 100 }')"
			grep -qF "SHCL is ${vsJson}% smaller than JSON and ${vsXml}% smaller than XML" "${readme}" \
				|| fBad "README.md: the schema sentence does not give the newest run's sizes (${vsJson}% smaller than JSON, ${vsXml}% than XML)"
			frac="$(sed -nE 's/.*reads in under an? ([a-z]+) of a second.*/\1/p' "${readme}" | head -n1)"
			denom="$(awk -v f="${frac}" 'BEGIN { split("tenth 10 twentieth 20 thirtieth 30 fortieth 40 fiftieth 50 sixtieth 60 seventieth 70 eightieth 80 ninetieth 90 hundredth 100 thousandth 1000", t, " ")
				for (i = 1; i < 24; i += 2) if (t[i] == f) print t[i + 1] }')"
			if [[ -z "${denom}" ]]; then
				fBad "README.md: no 'reads in under a ... of a second' sentence to check the schema read time against"
			else
				awk -v s="${ddlSecs}" -v d="${denom}" 'BEGIN { exit !(s * d < 1) }' \
					|| fBad "README.md: SHCL reads the schema shape in ${ddlSecs} s, which is not under a ${frac} of a second"
			fi
		fi
	elif [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		fBad "no debug binary to read results.shcl with, and the gate requires it"
	else
		echo "check-docs: SKIPPED the comparison ratios - no debug binary (cargo build first)"
		echo check-docs >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fi
fi

fTest EoXWC8G blank-line-between-bullets
##	Two top-level bullets with no blank line between them. Auto-generated TOC
##	blocks are the exception - the tool strips blank lines out of them, so a
##	`<!-- TOC -->` region is skipped, as is any list of bare anchor links, which
##	is what a hand-maintained contents block looks like.
while IFS= read -r f; do
	while IFS= read -r hit; do
		fBad "adjacent top-level bullets: ${f#"${repoDir}/"}:${hit}"
	done < <(awk '
		/<!-- TOC -->/      { toc = 1 }
		/<!-- \/TOC -->/    { toc = 0 }
		{
			isBullet = ($0 ~ /^- /)
			anchor   = ($0 ~ /^- \[[^]]*\]\(#[^)]*\)[[:space:]]*$/)
			if (!toc && !anchor && prevBullet && isBullet) print NR ": " substr($0, 1, 60)
			prevBullet = isBullet && !anchor
			prev = $0
		}' "${f}" || true)
done < <(find "${repoDir}" -name '*.md' -not -path '*/target/*' -not -path '*/.git/*' -not -path '*/node_modules/*' | sort)

fTest EoXWh5c prose-to-stderr-claim
##	The claim that the code goes to stdout and the prose to stderr. The stderr
##	line carries the code too, and has since the round that changed the CLI's
##	voice - so a document saying otherwise describes a split that is not there.
while IFS= read -r hit; do
	fBad "says the prose alone goes to stderr, but the stderr line carries the code: ${hit}"
done < <(grep -rn "prose to stderr" --include='*.md' "${repoDir}" | grep -v '/backlog\.md:' || true)

fTest EoXX3yy setter-examples-check-the-result
##	Each language example says a setter reports whether the write applied, then
##	three of the four called the first two bare. The Rust one checks all three,
##	because the type system makes it, so it is the comparison a reader has.
readme="${repoDir}/README.md"
if [[ -f "${readme}" ]]; then
	for fence in rust go python c; do
		block="$(awk -v f="^~~~+${fence}\$" '$0 ~ f, /^~~~+$/' "${readme}")"
		[[ -n "${block}" ]] || { fBad "README.md has no \`\`\`${fence} example, so its setter checks went unread"; continue ;}
		calls="$(grep -cE '(doc\.[Ss]et[A-Za-z_]+\(|shcl_set_[a-z]+\(doc)' <<<"${block}" || true)"
		checked="$(grep -cE '(if !doc\.[Ss]et|if not doc\.set_|if \(!shcl_set_)' <<<"${block}" || true)"
		((calls == 0)) && continue
		((checked >= calls)) || fBad "README ${fence} example calls ${calls} setter(s) and checks ${checked}"
	done
fi

fTest EoXYMt6 backlog-stamps-end-items
##	The stamps terminate an item: an outcome bullet below them makes them stop
##	being a reliable end marker, and puts the result furthest from the finding.
##	Legacy items only. The new issue template, and the section that uses it,
##	put Opened near the top. That section runs to the next heading at its own
##	level or above, whichever level it sits at.
while IFS= read -r hit; do
	fBad "backlog.md: sub-bullet below the stamps: ${hit}"
done < <(awk '
	/^<!--/                { tmpl = 1 }
	/-->/                  { tmpl = 0; next }
	/^#+ / {
		level = index($0, " ") - 1
		if ($0 ~ /^#+ New format/) newfmt = level
		else if (newfmt && level <= newfmt) newfmt = 0
	}
	tmpl || newfmt         { next }
	match($0, /^\t+- (Opened|Closed): /) { stamp = NR; indent = length($0) - length(substr($0, RSTART + RLENGTH)); next }
	stamp == NR - 1 && /^\t+- / { print NR ": " substr($0, 1, 60) }
	{ stamp = 0 }' "${backlog}" || true)

fTest Er8RudX backlog-closed-items-name-a-test
##	Every closed item says which test pins it, or why none does: a legacy
##	checkmark item carries a Test case, Test or Pinned by line of its own or
##	under a checked item it sits in, and a new-format item that is Done or
##	waiting on signoff carries a Test case row. 98 closed items had none before
##	anything checked (20260926 idea 1).
while IFS= read -r hit; do
	fBad "backlog.md: a closed item names no test: ${hit}"
done < <(python3 - "${backlog}" <<'PYEOF'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
# The issue template's legend sits in a comment; it is no item.
inside = False
for i, line in enumerate(lines):
	if line.startswith("<!--"):
		inside = True
	if inside:
		lines[i] = ""
	if "-->" in line:
		inside = False
test = re.compile(r"^(\t*)- (Test case|Test|Pinned by|Pinned)[: ]")
items = []
for i, line in enumerate(lines):
	m = re.match(r"^(\t*)- \u2705 ", line)
	if m:
		items.append((i, len(m.group(1))))
def own_test(i, depth):
	for line in lines[i + 1:]:
		if not line.strip():
			if depth == 0:
				return False
			continue
		m = re.match(r"^(\t*)- ", line)
		if m and len(m.group(1)) <= depth:
			return False
		t = test.match(line)
		if t and len(t.group(1)) == depth + 1:
			return True
	return False
has = {i: own_test(i, d) for i, d in items}
for k, (i, d) in enumerate(items):
	if has[i]:
		continue
	parent = next((p for p, pd in reversed(items[:k]) if pd < d), None)
	if parent is not None and has[parent] and d > 0:
		continue
	print(f"{i + 1}: {lines[i].strip()[:60]}")
status = None
for i, line in enumerate(lines):
	if re.match(r"^- \S", line):
		status, start, found = None, i, False
	m = re.match(r"^\t- Status: (Done|Waiting on signoff)$", line)
	if m:
		status = start
	if re.match(r"^\t- Test case: ", line):
		found = True
	end = i + 1 == len(lines) or re.match(r"^(- \S|#)", lines[i + 1])
	if end and status is not None and not found:
		print(f"{status + 1}: {lines[status].strip()[:60]}")
		status = None
PYEOF
)

fTest EoXYMt7 no-found-by-bullets
##	How a defect was found is not what changed. The gate that caught it belongs
##	in the cause line where it is the point, not in a bullet of its own.
while IFS= read -r hit; do
	fBad "backlog.md: says how it was found rather than what changed: ${hit}"
done < <(grep -nE '^[[:space:]]*- Found (by|while) ' "${backlog}" || true)

fTest Eolyg4u v096-v097-generation-only
##	V096 and V097 come only from generation, so validating anything against the
##	schema cannot reproduce them - the veneer header used to send a reader that
##	way for the fault list, which returns the validated document's own V002 and
##	V007 instead. The C CLI made the same mistake and was fixed in 20260830b.
while IFS= read -r hit; do
	fBad "shcl.hpp: sends a reader to validate() for generation faults: ${hit}"
done < <(grep -nE 'for the fault list, validate\(\)' "${repoDir}/source/c/shcl.hpp" || true)

fTest EolzoJk mon-dd-yyyy-needs-quotes
##	A bare `Mon DD, YYYY` is two array elements, not a date: the comma splits
##	first. The bullet listing that spelling has to say so, or a reader copies it
##	unquoted out of the spec and gets a BadType.
grep -q 'in the space form a comma may follow the day .*only inside quotes' "${repoDir}/project/spec.md" \
	|| fBad "spec.md: the Mon DD, YYYY bullet does not say the comma spelling needs quotes"

fTest Eom0qpk edit-options-named-in-docs
##	Prose that names the CLI's edit options, or the subcommands that take a
##	layer, goes stale the moment one is added. Each claim is checked against the
##	shipped help text rather than against a copy of the list.
help="$("${repoDir}/source/rust/target/debug/shcl" help 2>/dev/null || true)"
##	Four checks below read the help. Without the debug binary they cannot run,
##	which the gate treats as a failure, since its build stage comes first.
if [[ -z "${help}" ]]; then
	if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
		fBad "no debug binary to read the help from, and the gate requires it"
	else
		echo "check-docs: SKIPPED the help checks - no debug binary (cargo build first)"
		echo check-docs >> "${SHCL_GATE_SKIPS:-/dev/null}"
		fTestSkip
	fi
fi
if [[ -n "${help}" ]]; then
	for opt in --remove --set-default --set-literal-default; do
		grep -q -- "${opt}" <<<"${help}" || continue
		grep -q -- "\`${opt}" "${repoDir}/README.md" \
			|| fBad "README.md: ${opt} is in the help and not in the edit-options paragraph"
		grep -qF -- "${opt//-/\\-}" "${repoDir}/source/man/shcl.1" \
			|| fBad "shcl.1: ${opt} is in the help and not in the man page"
	done
	##	The man page's WRITE OPS sentence lists the options that stop stdin
	##	being read; the CLI reads it only when none of the five is given.
	writeops="$(sed -n '/^\.SH WRITE OPS/,/One op per line/p' "${repoDir}/source/man/shcl.1")"
	for opt in '\-\-set' '\-\-set\-literal' '\-\-set\-default' '\-\-set\-literal\-default' '\-\-remove'; do
		grep -qF -- "${opt}" <<<"${writeops}" \
			|| fBad "shcl.1: WRITE OPS does not name ${opt//\\/} among the options that carry the edits"
	done
fi

fTest Eom0qpl layer-subcommands-in-spec
##	Every subcommand that takes a layer has to be in the spec's list of them.
##	Driven off the CLI rather than off a copy: the list went stale twice.
if [[ -n "${help}" ]]; then
	#  shellcheck disable=2016  ## the backticks are the document's own markdown.
	layerLine="$(grep -n 'takes repeated `--layer=FILE`' "${repoDir}/project/spec.md" | head -1 || true)"
	[[ -n "${layerLine}" ]] || fBad "spec.md: no sentence listing the subcommands that take --layer"
	tmpErr="$(mktemp)"
	for cmd in get fmt count instances children paths set check; do
		"${repoDir}/source/rust/target/debug/shcl" "${cmd}" --layer=/dev/null /dev/null a < /dev/null > /dev/null 2>"${tmpErr}" || true
		grep -qE 'unknown option|not valid for' "${tmpErr}" && continue
		grep -qF -- "\`${cmd}\`" <<<"${layerLine}" \
			|| fBad "spec.md: ${cmd} takes --layer and is not in the list of subcommands that do"
	done
	rm -f "${tmpErr}"
else
	fTestSkip
fi

fTest EqRTWFc exit-codes-match-help
##	The CLI style guide carries its own copy of the exit codes, and nothing held
##	it to the CLI: its row for 6 named migrate --check for two days after fmt
##	got one, so the guide called the fmt arm a bug. Two things are checked. The
##	help's code list and the guide's table have to name the same codes, and no
##	guide row may pin a --check to one subcommand, since both fmt and migrate
##	have one and naming either makes the other read wrong.
if [[ -n "${help}" ]]; then
	guide="${repoDir}/project/style-guide_ui-ux.md"
	exitRows="$(sed -n '/^## Exit codes$/,/^## /p' "${guide}" | { grep -E '^\| [0-9]' || true ;})"
	[[ -n "${exitRows}" ]] || fBad "style-guide_ui-ux.md: no exit-code table to compare with the help"
	helpCodes="$(sed -n '/^Exit codes:/,$p' <<<"${help}" | sed 's/^Exit codes: //' \
		| { grep -oE '(^|, )[0-9] ' || true ;} | tr -dc '0-9\n' | sort -u)"
	[[ -n "${helpCodes}" ]] || fBad "the help has no 'Exit codes:' paragraph to read the codes out of"
	guideCodes="$(awk '{ print $2 }' <<<"${exitRows}" | sort -u)"
	[[ "${helpCodes}" == "${guideCodes}" ]] \
		|| fBad "style-guide_ui-ux.md: the exit table names $(tr '\n' ' ' <<<"${guideCodes}")and the help names $(tr '\n' ' ' <<<"${helpCodes}")"
	while IFS= read -r row; do
		#  shellcheck disable=2016  ## the backticks are the document's own markdown.
		if grep -qE '`(fmt|migrate|check|set|init|get) --check`' <<<"${row}"; then
			fBad "style-guide_ui-ux.md: an exit row names one subcommand's --check: ${row}"
		fi
	done <<<"${exitRows}"

	##	20260920 idea 10: the man page is the third copy of the exit codes and
	##	of the per-option subcommand lists, and it was held to neither. Both are
	##	compared with the help, which cli-regress.bash holds to the CLI itself.
	manCodes="$(sed -n '/^\.SH EXIT STATUS$/,/^\.SH /p' "${man}" | sed -n 's/^\.B \([0-9]\)$/\1/p' | sort -u)"
	[[ -n "${manCodes}" ]] || fBad "shcl.1: no EXIT STATUS entries to compare with the help"
	[[ "${helpCodes}" == "${manCodes}" ]] \
		|| fBad "shcl.1: EXIT STATUS names $(tr '\n' ' ' <<<"${manCodes}")and the help names $(tr '\n' ' ' <<<"${helpCodes}")"

	##	Both lists name subcommands in prose around them, so each is reduced to
	##	the subcommand names it holds and the two sets are compared. The man
	##	page spells an option with escaped hyphens and roff font macros around
	##	the names, which come off first.
	mapfile -t docCmds < <(printf '%s\n' "${help}" | { grep -oE '^  shcl [a-z]+' || true ;} \
		| awk '{print $2}' | { grep -vxE 'help|about' || true ;} | sort -u)
	fNames(){   ## fNames TEXT -> the subcommand names in it, sorted
		local w out=""
		for w in ${1//[^a-z]/ }; do
			for c in "${docCmds[@]}"; do if [[ "${w}" == "${c}" ]]; then out+="${c} "; fi; done
		done
		tr ' ' '\n' <<<"${out}" | sort -u | xargs
	}
	##	"(same)", or no parentheses at all, carries the entry above, in the help
	##	and in the man page alike.
	declare -A helpScope=()
	carried=""
	while IFS=$'\t' read -r spell par; do
		if [[ -n "${par}" && "${par}" != "(same"* ]]; then carried="$(fNames "${par}")"; fi
		helpScope["${spell%%=*}"]="${carried}"
	done < <(printf '%s\n' "${help}" | awk '
		/^Options \(/ { on = 1; next }
		on && /^[^ ]/ { on = 0 }
		!on { next }
		/^  --/ {
			if (spell != "") print spell "\t" par
			spell = $1; par = ""; inpar = 0
			d = substr($0, 42)
			if (substr(d, 1, 1) == "(") { inpar = 1 }
			if (inpar) { par = d; if (index(d, ")")) { par = substr(d, 1, index(d, ")")); inpar = 0 } }
			next
		}
		inpar {
			d = substr($0, 42)
			if (index(d, ")")) { par = par substr(d, 1, index(d, ")")); inpar = 0 } else { par = par d }
		}
		END { if (spell != "") print spell "\t" par }')
	manOpts=0
	manCarried=""
	while IFS=$'\t' read -r opt par; do
		[[ -v "helpScope[${opt}]" ]] || { fBad "shcl.1: ${opt} has no entry in the help's option list"; continue ;}
		if [[ "${par}" != *"(same"* ]]; then manCarried="$(fNames "${par}")"; fi
		manOpts=$((manOpts + 1))
		[[ "${manCarried}" == "${helpScope[${opt}]}" ]] \
			|| fBad "shcl.1: ${opt} belongs to (${manCarried}) here and (${helpScope[${opt}]}) in the help"
	done < <(awk '
		/^\.SH OPTIONS$/ { on = 1; next }
		on && /^\.SH / { exit }
		!on { next }
		/^\.B[IR]? \\-\\-/ { spell = $2; sub(/=.*/, "", spell); gsub(/\\-/, "-", spell); next }
		/^\.RB \(/ && spell != "" { print spell "\t" $0; spell = "" }' "${man}")
	((manOpts >= 10)) || fBad "shcl.1: only ${manOpts} option(s) could be matched with the help's list"

	##	20260904 item 31: the fmt synopsis had lost `[options]` and `-w` in the
	##	help and the man page alike. Every word of a help synopsis has to be in
	##	the man page's .SY block for that subcommand. The man page may say more,
	##	since the help's column is narrow, and may spell a placeholder longer
	##	(S there, SCHEMA here). ` | ` between two subcommands starts another.
	##	`[options]` may also be spelled out, as long as every option the
	##	subcommand's own help lists is there.
	declare -A manSy=()
	while IFS=$'\t' read -r cmds words; do
		for c in ${cmds}; do manSy["${c}"]="${words}"; done
	done < <(awk '
		/^\.SH SYNOPSIS$/ { on = 1; next }
		on && /^\.SH / { exit }
		/^\.SY shcl$/ && on { sy = 1; n = 0; words = ""; next }
		sy && /^\.YS$/ { print cmds "\t" words; sy = 0; next }
		sy {
			t = $0; sub(/^\.[A-Z]+ /, "", t); gsub(/\\-/, "-", t); gsub(/[][|=]/, " ", t)
			if (++n == 1) cmds = t; else words = words " " t
		}' "${man}")
	((${#manSy[@]} >= 10)) || fBad "shcl.1: only ${#manSy[@]} subcommand(s) found in SYNOPSIS"
	declare -A helpSy=()
	while IFS= read -r syn; do
		rest="${syn}"
		while [[ -n "${rest}" ]]; do
			seg="${rest%% | *}"
			if [[ "${rest}" == *" | "* ]]; then rest="${rest#* | }"; else rest=""; fi
			read -r -a w <<<"${seg//[][|=]/ }"
			helpSy["${w[0]}"]=1
			if [[ ! -v "manSy[${w[0]}]" ]]; then fBad "shcl.1: SYNOPSIS has no entry for ${w[0]}"; continue; fi
			read -r -a mw <<<"${manSy[${w[0]}]}"
			for word in "${w[@]:1}"; do
				found=0
				for m in "${mw[@]}"; do
					if [[ "${m}" == "${word}" || ( "${word}" =~ ^[A-Z]+$ && "${m}" =~ ^[A-Z]+$ && "${m}" == "${word}"* ) ]]; then found=1; break; fi
				done
				if ((! found)) && [[ "${word}" == options ]]; then
					found=1; nOpt=0
					while IFS= read -r o; do
						nOpt=$((nOpt + 1))
						[[ " ${mw[*]} " == *" ${o} "* ]] || found=0
					done < <("${repoDir}/source/rust/target/debug/shcl" help "${w[0]}" 2>/dev/null \
						| awk '/^Options/ { on = 1; next } on && /^  --/ { o = $1; sub(/=.*/, "", o); print o }')
					((nOpt)) || found=0
				fi
				((found)) || fBad "shcl.1: the SYNOPSIS for ${w[0]} does not say '${word}', which the help's does"
			done
		done
	done < <(printf '%s\n' "${help}" | sed -n 's/^  shcl \([a-z-].*\)$/\1/p' | sed 's/  .*//')
	for c in "${!manSy[@]}"; do
		[[ -v "helpSy[${c}]" ]] || fBad "shcl.1: SYNOPSIS names ${c}, which the help's synopsis lines do not"
	done

	##	The same round: the spec said two options shared the ordered list where
	##	the CLI has five, and never named `--slots`. The edit options are read
	##	from the help's own sentence, so a sixth has to reach the spec too.
	editOpts="$(printf '%s\n' "${help}" | sed -n '/Edits go in as the repeatable/,/ options, which/p' | { grep -oE -- '--[a-z-]+' || true ;})"
	nEdit="$(grep -c . <<<"${editOpts}" || true)"
	numWords=(zero one two three four five six seven eight nine ten)
	#  shellcheck disable=2016  ## the backticks are the document's own markdown.
	editSpec="$(sed -n '/^- A `--set` value goes in as/,/share one ordered list/p' "${repoDir}/project/spec.md")"
	if ((nEdit < 2 || nEdit > 10)); then
		fBad "found ${nEdit} edit option(s) in the help's set paragraph, so the spec's list went unread"
	elif [[ -z "${editSpec}" ]]; then
		fBad "spec.md: no sentence saying which edit options share one ordered list"
	else
		grep -qF -- "all ${numWords[nEdit]} share one ordered list" <<<"${editSpec}" \
			|| fBad "spec.md: the edit options do not say all ${numWords[nEdit]} share one ordered list"
		while IFS= read -r opt; do
			grep -qE -- "\`${opt}[=\`]" <<<"${editSpec}" || fBad "spec.md: ${opt} is an edit option in the help and not in the spec's list"
		done <<<"${editOpts}"
		if grep -q -- '--slots' <<<"${help}"; then
			#  shellcheck disable=2016  ## the backticks are the document's own markdown.
			grep -qF -- '`--slots`' <<<"${editSpec}" || fBad "spec.md: the edit options paragraph does not name --slots"
		fi
	fi
else
	fTestSkip
fi

fTest Eom0qpm readme-get-transcript-shows-diagnostic
##	Every subcommand that loads a document prints the load's diagnostics, so a
##	README transcript reading a damaged file has to show them - the get example
##	sat under a check example that showed the same file's diagnostic and said
##	nothing itself.
readmeGet="$(sed -n '/shcl get server.shcl log-level/,/^~~~~*$/p' "${repoDir}/README.md")"
grep -q 'E014' <<<"${readmeGet}" \
	|| fBad "README.md: the get transcript on the damaged file shows no load diagnostic"
##	And the diagnostic it shows is the one the CLI prints. The file is the
##	README's own example with the colon knocked off line 3, as the prose says.
if [[ -n "${help}" ]]; then
	tmpDoc="$(mktemp -d)"
	awk '/^## What a \.shcl file looks like/ { hdr = 1 } hdr && /^~~~+text$/ { body = 1; next } body && /^~~~+$/ { exit } body' "${readme}" \
		| sed '3s/: / /' > "${tmpDoc}/server.shcl"
	shown="$(grep -m1 'E014 malformed' <<<"${readmeGet}" || true)"
	actual="$(cd "${tmpDoc}" && "${repoDir}/source/rust/target/debug/shcl" get server.shcl log-level 2>&1 >/dev/null || true)"
	[[ -n "${shown}" && "${shown}" == "${actual}" ]] \
		|| fBad "README.md: the E014 transcript line is not what the CLI prints (${actual})"
	rm -rf "${tmpDoc}"
fi

fTest EometfE merge-facts-in-spec
##	Three merge facts a consumer folding layers itself has to know, and that
##	nothing in the code or the corpus can tell them: the fold is not
##	associative, the merged document keeps the base's strictness, and a
##	replaced node is kept. The spec says them, and so does every binding's
##	merge doc comment - a port that loses one leaves its own users guessing.
grep -q 'fold is not associative' "${repoDir}/project/spec.md" \
	|| fBad "spec.md: Layered loading does not say the fold is not associative"
##	The other two facts of that paragraph, the five deliberate merge behaviors
##	before it, and the datetime tolerance paragraph: each went in as prose alone
##	in the 20260901b and 20260902 rounds, and each could be deleted with every
##	gate green.
for phrase in "keeps the base's strictness" "merge is not free" \
	"cites the line of whichever file the node came from" \
	"drops the base leaf's comments and its blank-line grouping" \
	"doubles a container's leading comments" "sums across layers" \
	"strict failure in a lower layer" "Tolerances the whitelist allows"; do
	grep -qF -- "${phrase}" "${repoDir}/project/spec.md" || fBad "spec.md no longer says: ${phrase}"
done
fTest EqB32JE migrate-section-promises
##	20260909 item 55: migrate is the only path across the breaking change and had
##	no normative description of what it promises. Same reason as the loop above -
##	prose alone can be deleted with every gate green.
for phrase in "The output is its own fixpoint" "It is not a formatter" \
	"never writes the whole info block into a file that had none" \
	"Exit codes: 0 when the file needed nothing or was rewritten"; do
	grep -qF -- "${phrase}" "${repoDir}/project/spec.md" || fBad "spec.md's Migrating section no longer says: ${phrase}"
done
fTest Ep1EGVe python-iterative-walks
##	20260901b item 45: the Python section owns the iterative-walk deviation and
##	its reason; it sat under the C heading once.
pySection="$(sed -n '/^### Python/,/^### C/p' "${repoDir}/project/style-guide_code.md")"
grep -qF 'emit, overlay and clone walks are iterative' <<<"${pySection}" || fBad "style-guide_code.md: the Python section does not list the iterative walks"
grep -qF 'recursion limit' <<<"${pySection}" || fBad "style-guide_code.md: the Python section does not say why the walks are iterative"
fTest EometfF merge-doc-comments-say-not-associative
for src in source/rust/src/lib.rs source/go/shcl.go source/python/shcl.py source/c/shcl.h; do
	grep -q 'fold is not associative' "${repoDir}/${src}" \
		|| fBad "${src}: the merge doc comment does not say the fold is not associative"
done

fTest Eon0GaO tie-rounding-and-status-order
##	Two rules every port has to implement identically and that lived only in the
##	code: which way a float-to-int tie rounds at Loose, and the order the
##	aggregate status of an array read takes its worst slot in.
#  shellcheck disable=2016  ## the backticks are the document's own markdown.
grep -q 'rounds half away from zero' "${repoDir}/project/spec.md" \
	|| fBad "spec.md: the coercion table does not say which way a float-to-int tie rounds"
#  shellcheck disable=2016  ## the backticks are the document's own markdown.
grep -qF -- '`Good` < `Empty` < `NotFound` < `BadType` < `Multiple`' "${repoDir}/project/spec.md" \
	|| fBad "spec.md: the aggregate status rule does not give the ordering"

fTest Eon78xs authored-name-lifetime
##	shcl_authored_name hands back the stored spelling, which lives in the
##	document's arena and survives shcl_reads_release. The header used to promise
##	the shorter read-arena lifetime, which no caller was hurt by and every
##	caller would have believed.
grep -B 3 -F 'shcl_str shcl_authored_name(shcl_doc *d' "${repoDir}/source/c/shcl.h" \
	| grep -q "document's own arena" \
	|| fBad "shcl.h: shcl_authored_name does not say its result lives in the document's arena"

fTest EqQW89J contents-blocks-match-headings
##	A contents block is generated by an editor extension, so nothing in the
##	pipeline had ever compared one with the headings under it. The spec went
##	without one entirely for 758 lines. Each document that carries a block gets
##	it rebuilt here from its own h2 to h5 and compared. Heading-slug collisions
##	come out of the same pass, which no linter catches either.
fBuildToc(){  ## fBuildToc FILE: the contents block those headings would generate
	awk '
		/^(```|~~~)/ { fence = !fence; next }
		fence { next }
		/^#{2,5} / {
			depth = index($0, " ") - 1
			text = substr($0, depth + 2)
			sub(/[ \t]+$/, "", text)
			if (prev ~ /TOC ignore:true/ || text == "Table of contents") { prev = $0; next }
			slug = tolower(text)
			gsub(/[^a-z0-9 -]/, "", slug)
			gsub(/ /, "-", slug)
			pad = ""
			for (i = 2; i < depth; i++) pad = pad "\t"
			print pad "- [" text "](#" slug ")"
		}
		{ prev = $0 }
	' "$1"
}
for doc in README.md contributing.md project/design.md project/spec.md ai_policy.md; do
	[[ -f "${repoDir}/${doc}" ]] || continue
	live="$(sed -n '/^<!-- TOC -->$/,/^<!-- \/TOC -->$/p' "${repoDir}/${doc}" | sed '1d;$d' | sed '/^$/d')"
	if [[ -z "${live}" ]]; then
		fBad "${doc} carries no contents block, and it is long enough to need one"
		continue
	fi
	want="$(fBuildToc "${repoDir}/${doc}")"
	[[ "${live}" == "${want}" ]] \
		|| fBad "${doc}: the contents block is not what its headings generate; regenerate it (first difference: $(diff <(echo "${live}") <(echo "${want}") | sed -n '2p'))"
	dupe="$(sed -E 's/.*\(#(.*)\)/\1/' <<<"${want}" | sort | uniq -d | head -n1)"
	[[ -z "${dupe}" ]] || fBad "${doc}: two headings share the anchor #${dupe}, so one of the contents links goes to the wrong place"
done

fTest EqQW89K flame-report-keys-exist
##	The hot-spot report buckets a sample by the names in its ancestor frames, so
##	a renamed function moves its whole bucket into "other" and the report reads
##	as though that subsystem costs nothing. `scan_path` sat there for weeks after
##	the lookup scanner was renamed. Every name the buckets key on has to be a
##	function the reference still defines.
flameKeys="$(sed -n '/^\t\tif any("Parser::parse"/,/^\t\telse:/p' "${repoDir}/cicd/utility/flame-report.py" \
	| { grep -oE '"[A-Za-z_:]+"' || true ;} | tr -d '"' | sed 's/.*:://' | sort -u)"
[[ -n "${flameKeys}" ]] || fBad "flame-report.py: found no bucket keys to check against the reference"
while IFS= read -r key; do
	[[ -n "${key}" ]] || continue
	grep -qE "fn ${key}" "${repoDir}/source/rust/src/lib.rs" \
		|| fBad "flame-report.py buckets on '${key}', which the reference has no function for"
done <<<"${flameKeys}"

fTest EonNaTZ e003-reachable
##	E003 was listed as unreachable from a file. The `[#N]` spelling is - the `#`
##	opens a comment first - but the bare index spelling is documented and does
##	reach it, so the row must not tell a reader to ignore the code.
grep -q 'E003.*Unreachable in practice' "${repoDir}/project/spec.md" \
	&& fBad "spec.md: the E003 row still calls the code unreachable from a file"

fTest Ep3TJTc crossed-range-drops-range
##	A crossed `min`/`max` range drops the range and keeps the field's other
##	constraints (the spec's schema table). The changelog once said both that
##	and that the field is dropped, in two entries under one Unreleased heading,
##	because a later round amended the entry by appending a second one.
grep -qF 'the range is dropped (the field keeps its other constraints)' "${repoDir}/project/spec.md" \
	|| fBad "spec.md: the crossed-range row no longer says the range is dropped and the field kept"
grep -q 'The field is dropped' "${repoDir}/changelog.md" \
	&& fBad "changelog.md: a crossed min/max range drops the range, not the field"

fTest EpFkZy5 tokenizer-sentence
##	The style guide names the tokenizer as the one place the lexical rules
##	live, and the reference's section header says the same. Both sentences
##	are what a reader is told to rely on, so neither may drift or go.
grep -qF 'The tokenizer is the one place the lexical rules live.' "${repoDir}/project/style-guide_code.md" \
	|| fBad "style-guide_code.md: the tokenizer sentence is gone"
grep -qF '// Tokenizer - the one place the lexical rules live' "${repoDir}/source/rust/src/lib.rs" \
	|| fBad "lib.rs: the tokenizer section header is gone"

fTest EpGigIN setter-read-back-sentence
##	Same for the write side: the setters' one rule is a sentence a reader is
##	told to rely on, and the reference's section header repeats it.
grep -qF 'A setter writes only what reads back.' "${repoDir}/project/style-guide_code.md" \
	|| fBad "style-guide_code.md: the setter read-back sentence is gone"
grep -qF '// The write side'"'"'s one rule: what is written has to read back' "${repoDir}/source/rust/src/lib.rs" \
	|| fBad "lib.rs: the write-side section header is gone"

fTest EpHGoa0 installers-match-main
##	Nothing ships the installers and the README one-liners fetch them from main
##	as they run, so a fix that stops at dev reaches nobody. That is the one
##	drift in the tree that reaches users the moment it happens, and until now it
##	rested on remembering the docs-only exception at every merge. Skipped rather
##	than failed where the refs are not both present: a shallow CI clone or a
##	fork has no origin/main to compare against, and a missing ref is not drift.
##	Under the pre-push hook for main, the tree here is what main is about to
##	become and origin/main is still the old one, so the refs would refuse the
##	very push that brings the installers level. That tree stands in for main.
installers=(install.bash install.ps1 install-dev.bash)
if [[ "${SHCL_GATE_REF:-}" == main ]] && git -C "${repoDir}" rev-parse --verify -q origin/dev >/dev/null; then
	drifted="$(git -C "${repoDir}" diff --name-only origin/dev -- "${installers[@]}" || true)"
	if [[ -n "${drifted}" ]]; then
		while IFS= read -r f; do
			fBad "installer differs between this push to main and dev: ${f}"
		done <<<"${drifted}"
	fi
elif git -C "${repoDir}" rev-parse --verify -q origin/main >/dev/null && git -C "${repoDir}" rev-parse --verify -q origin/dev >/dev/null; then
	drifted="$(git -C "${repoDir}" diff --name-only origin/main origin/dev -- "${installers[@]}" || true)"
	if [[ -n "${drifted}" ]]; then
		while IFS= read -r f; do
			fBad "installer on dev and not on main, where the one-liners read it: ${f}"
		done <<<"${drifted}"
	fi
else
	echo "check-docs: skipping the installer drift check (origin/main or origin/dev not present)"
	fTestSkip
fi
fTestEnd

if ((nBad)); then
	echo "check-docs: ${nBad} check(s) failed" >&2
	exit 1
fi
echo "check-docs: OK"

##	History:
##		2026-08-30  Created, after a double negative reversed the legal-advice
##		            disclaimer in a document that invites verbatim reuse.
##		2026-09-05  The crossed-range entry must agree with the spec's table.
##		2026-09-08  The tokenizer sentence in the style guide and the reference.
##		2026-09-08  The installers on main must match the ones on dev.
##		2026-09-18  Under the hook for a push to main, the tree under test
##		            stands in for main, since origin/main has not moved yet.
##		2026-09-10  The comment-rule example is no longer required; the rule is 2.x's.
##		2026-09-19  install.ps1 stays ASCII with no byte-order mark, and parses
##		            from its raw bytes.
##		2026-09-19  Every go test a gate runs passes -count=1.
##		2026-09-19  The man page date is no older than its last commit.
##		2026-09-19  grammar.abnf reads as ABNF and derives the fence labels
##		            the parser reads.
##		2026-09-19  Every tracked source file carries the SPDX and copyright lines.
##		2026-09-19  The corpus README states no withdrawn lexical rule and has a
##		            note for every case.
##		2026-09-19  design.md's comparison rerun date matches the newest run in
##		            results.shcl.
##		2026-09-20  The man page's exit codes and per-option subcommand lists are
##		            compared with the help's.
##		2026-09-20  Every copyright marker is the canonical bytes, not a retyped
##		            lookalike.
##		2026-09-23  No Go doc comment opens with another declared name, and every
##		            veneer declaration heading a group has a comment.
##		2026-09-24  Every PowerShell file is ASCII with no byte-order mark.
##		2026-09-25  No British spelling outside the code of conduct and the
##		            backlog.
##		2026-09-26  The help's synopsis lines against the man page's, the spec's
##		            edit options against the help, four more comparison
##		            sentences against results.shcl, plain contact addresses,
##		            and the C header's section rules.
##		2026-09-26  Every exported Go name and Rust pub item has a doc comment,
##		            the C sources call no forbidden string function or bare
##		            goto, and explain's codes match the spec's tables.
