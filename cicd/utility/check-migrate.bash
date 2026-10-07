#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately.' Cumbersome and unnecessary here.

##	Purpose:
##		The migration gate: for every corpus input and every fuzz-dumped
##		document, the current parser's reading of `migrate`'s output equals the
##		2.x parser's reading of the original. Read, not canonical text: the two
##		emitters write a value differently on purpose (single quotes for a
##		backslash, no `\'`), so the trees are compared through the reads - the
##		path list, the instance count at every path, and each instance's
##		string array, raw body and info string. A path is compared by its
##		names, each read back by the rules of the CLI that printed it. The
##		2.x side is a build of the last pre-cut dev commit, pinned below by
##		hash and built into its own gitignored target the way the pre-push
##		gate builds, so the comparison never rests on whatever `shcl` is on
##		PATH.
##
##		Compared is what 2.x read cleanly. A line it kept as malformed may read
##		as a binding now, which is a gain, not a migration; a bracket array it
##		counted lost was refused by 2.x itself; a dropped line of any kind says
##		nothing. So those lines come out of the document first, and the rest is
##		compared, as long as 2.x then reads it cleanly. Two more kinds of line
##		come out the same way: a fence label holding a `#`, which 2.x ran to
##		the end of the line and which ends at the `#` now, with no quoting to
##		write it; and a carriage return in the middle of a line, which 2.x kept
##		as content and which is a blank at a piece's edge now. These are found
##		in the 2.x text, never in migrate's output. Each is asserted on a
##		corpus case, so the list cannot rot. A backslash pair 2.x read as an
##		escape stays as written and reads as text now, so an element read or
##		a quoted name may differ from the 2.x one in that way alone
##		(fBackslashText).
##
##		A compared document also has to migrate at exit 0, unless 2.x read a
##		raw block that never closes: the Format line would be more of its body,
##		so migrate refuses that file at 7, and has to. Some lines 2.x read
##		cleanly have no spelling now either (fLostNow), and come out too. A
##		document whose only unclean lines are those or bracket arrays has to
##		be refused over exactly that many lost lines. The corpus half has its
##		own floor, since the fuzz dump alone can meet the overall one, and so
##		does the fuzz half, since the corpus alone can meet it too.
##
##		Each compared document also goes through `upgrade --write`, with and
##		without --from-2x. A rewrite leaves the original bytes under the dated
##		backup name, and a fresh file that loads clean, has the info block
##		once, reads as the migrated text, and is left alone by a second run.
##		A file left alone keeps its bytes, and one naming format 3 always is.
##	Syntax:
##		check-migrate.bash [--corpus DIR] [--iters N] [--min N] [--min-corpus N] [--min-fuzz N]
##		  --corpus DIR  conformance corpus root (default project/conformance)
##		  --iters N     fuzz iterations to dump (default 2000)
##		  --min N       fail unless at least N documents were compared (default 100)
##		  --min-corpus N  and at least N of them corpus cases (default 80)
##		  --min-fuzz N  and at least N of them fuzz-dumped (default 200)
##	Exit: 0 = every compared document equal, 1 = a divergence, 2 = usage or a build failure.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/include/test-id.bash"
testWhere=check-migrate; testCounter=nBad

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${meDir}/../.." && pwd)"
corpus="${root}/project/conformance"; declare -i iters=2000 minCompared=100 minCorpus=80 minFuzz=200
while (($#)); do case "$1" in
	--corpus)  corpus="${2:-}"; shift 2 ;;
	--iters)   iters="${2:-2000}"; shift 2 ;;
	--min)     minCompared="${2:-100}"; shift 2 ;;
	--min-corpus) minCorpus="${2:-80}"; shift 2 ;;
	--min-fuzz) minFuzz="${2:-200}"; shift 2 ;;
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         echo "check-migrate: unknown argument: $1" >&2; exit 2 ;;
esac; done
[[ -d "${corpus}" ]] || { echo "check-migrate: no corpus dir: ${corpus}" >&2; exit 2; }

##	The last dev commit before the lexical cut: the funnel merge.
pin="7be348d0de309ead4cba9f2fa28650b48b320519"
if ! git -C "${root}" cat-file -e "${pin}^{commit}" 2>/dev/null; then
	## A shallow clone (the hosted runner) has no history; a full sha can still
	## be fetched on its own.
	git -C "${root}" fetch --depth=1 origin "${pin}" >/dev/null 2>&1 || true
	git -C "${root}" cat-file -e "${pin}^{commit}" 2>/dev/null \
		|| { echo "check-migrate: the pinned 2.x commit ${pin:0:12} is not in this clone" >&2; exit 2; }
fi

tmpDir="$(mktemp -d)"; tree=""
fCleanup(){
	if [[ -n "${tree}" ]]; then git -C "${root}" worktree remove --force "${tree}" >/dev/null 2>&1 || true; fi
	git -C "${root}" worktree prune >/dev/null 2>&1 || true
	rm -rf "${tmpDir}"
}
trap fCleanup EXIT

##	Build the 2.x CLI once per pin; the target dir keeps it across runs.
oldTarget="${root}/source/rust/target-migrate"
oldCli="${oldTarget}/debug/shcl"
if [[ ! -x "${oldCli}" || "$(cat "${oldTarget}/.pin" 2>/dev/null || true)" != "${pin}" ]]; then
	echo "check-migrate: building the 2.x reference at ${pin:0:12}"
	tree="$(mktemp -d "${TMPDIR:-/tmp}/shcl-migrate.XXXXXX")"
	git -C "${root}" worktree add --detach "${tree}" "${pin}" >/dev/null 2>&1 \
		|| { echo "check-migrate: cannot check ${pin:0:12} out" >&2; exit 2; }
	mkdir -p "${oldTarget}"
	ln -s "${oldTarget}" "${tree}/source/rust/target"
	( cd "${tree}/source/rust" && cargo build --quiet ) || { echo "check-migrate: the 2.x build failed" >&2; exit 2; }
	printf '%s\n' "${pin}" > "${oldTarget}/.pin"
	fCleanup; tree=""; tmpDir="$(mktemp -d)"
fi
newCli="${root}/source/rust/target/debug/shcl"
[[ -x "${newCli}" ]] || ( cd "${root}/source/rust" && cargo build --quiet )

##	The soup, from the current fuzz generator.
dump="${tmpDir}/dump"; mkdir -p "${dump}"
( cd "${root}/source/rust" && SHCL_FUZZ_DUMP="${dump}" SHCL_FUZZ_ITERS="${iters}" SHCL_FUZZ_DUMP_MAX=500 \
	cargo test --quiet --test fuzz_smoke mutated_inputs >/dev/null 2>&1 ) || { echo "check-migrate: the fuzz dump failed" >&2; exit 2; }
##	A test filter that matches nothing passes and writes nothing, and the corpus
##	alone meets the overall floor, so an empty dump has to be caught here.
nDumped="$(find "${dump}" -maxdepth 1 -name '*.shcl' | wc -l)"
((nDumped > 0)) || { echo "check-migrate: the fuzz dump wrote no documents" >&2; exit 2; }

##	The corpus spells a selector in parens now, which 2.x refuses, so each
##	input that has one is also compared as 2.x wrote it, in brackets. Any
##	text will do as a 2.x document, so a paren pair is swapped wherever it
##	follows a name, raw bodies and values included. An input that names
##	format 3 is current to migrate, which leaves it as written, so it gets no
##	copy.
brackets="${tmpDir}/brackets"; mkdir -p "${brackets}"
python3 -c '
import os, re, sys
out = sys.argv[1]
for f in sys.argv[2:]:
	text = open(f, "rb").read().decode("utf-8", "surrogateescape")
	swapped = re.sub(r"(?<=[A-Za-z0-9_\x27\"-])\(([^()\r\n]*)\)", r"[\1]", text)
	if swapped != text and not re.search(r"^##[ \t]+Format[ \t]+[3-9]", text, re.M):
		name = os.path.basename(os.path.dirname(f))
		open(os.path.join(out, "brackets_" + name + ".shcl"), "wb").write(swapped.encode("utf-8", "surrogateescape"))
' "${brackets}" "${corpus}"/*/input.shcl

##	The lines 2.x did not read cleanly, by number. A line is clean when every
##	code 2.x reports on it binds the line: E001 (field kept), E005 (fence
##	unterminated, body kept), E015 (repaired), E017 (kept literally), the two
##	hints, and E019 as a hint, which is the `name:[x]` sugar read as `name: x`.
##	E019 as an error is the bracket array. Read from what 2.x's `check` printed,
##	so one run of it serves every question asked of the same bytes.
fCheck2x(){ "${oldCli}" check "$1" 2>/dev/null || true; }
fUnclean2x(){
	awk '$1 == "line" {
		if ($4 ~ /^(E001|E005|E015|E017|H001|H002)$/ || ($4 == "E019" && $3 == "Hint:")) next
		sub(/:$/, "", $2); print $2 }'
}

##	The string array goes through `--slots`, one status and one line per element.
##	2.x prints an element holding a line break as it is, over several lines, and
##	the current CLI escapes it onto one. The 2.x side is put back together at each
##	status and escaped by the CLI's rule, so the two compare element by element.
fOneLine2x(){ awk '
	function put() { if (!have) return; if (v ~ /[\n\r]/) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); gsub(/\n/, "\\n", v); gsub(/\r/, "\\r", v); gsub(/\t/, "\\t", v); v = "\"" v "\"" } print s "\t" v }
	/^(Good|Empty|NotFound|BadType|Multiple)\t/ { put(); i = index($0, "\t"); s = substr($0, 1, i - 1); v = substr($0, i + 1); have = 1; next }
	{ v = v "\n" $0 }
	END { put() }'; }

##	The two CLIs spell a quoted name each by its own rules: 2.x with
##	backslash escapes, the current one with `◉` escapes and either quote. So
##	each path is read back to its names, by the rules of the CLI that printed
##	it, and written one way for both: a bare name as it is, any other in
##	guillemets, with a character that would not show as %HEX;. fReadTree
##	marks the lines that hold a path, \x01P before a path line and \x01C
##	before a count line's path, then a tab and the rest. The escape names
##	come from gen-escapes.py, so no copy of the list lives here.
fLogicalPaths(){ python3 -c '
import importlib.util, re, sys
side = sys.argv[1]
spec = importlib.util.spec_from_file_location("gen_escapes", sys.argv[2])
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
names = {n.upper(): v for n, v in gen.ESCAPE_NAMES}
mark = chr(gen.ESCAPE_MARK)
def mark_name(m):
	n = m.group(1).upper()
	if n in names:
		return names[n]
	for pre in gen.CODE_PREFIXES:
		if n.startswith(pre) and re.fullmatch(r"[0-9A-F]{1,6}", n[len(pre):]):
			return chr(int(n[len(pre):], 16))
	return m.group(0)
unescape = {"t": "\t", "n": "\n"}
def read_name(s, i):
	q = s[i]
	if side == "2x":
		j, out = i + 1, []
		while j < len(s) and s[j] != q:
			if s[j] == "\\" and j + 1 < len(s):
				out.append(unescape.get(s[j + 1], s[j + 1])); j += 2
			else:
				out.append(s[j]); j += 1
		return "".join(out), j + 1
	j = s.find(q, i + 1)
	j = len(s) if j < 0 else j
	return re.sub(mark + r"([^" + mark + r"]*)" + mark, mark_name, s[i + 1:j]), j + 1
def show(name):
	if re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name):
		return name
	return "\u00ab" + "".join(c if c.isprintable() and c not in "%\u00ab\u00bb" else "%%%X;" % ord(c) for c in name) + "\u00bb"
def logical(path):
	out, i = [], 0
	while i < len(path):
		if path[i] in "\"\x27":
			name, i = read_name(path, i)
			out.append(show(name))
		elif path[i] in ".[":
			k = path.find("]", i) + 1 if path[i] == "[" else i + 1
			k = len(path) if k <= i else k
			out.append(path[i:k]); i = k
		else:
			k = i
			while k < len(path) and path[k] not in ".[":
				k += 1
			out.append(show(path[i:k])); i = k
	return "".join(out)
for line in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n"):
	if line.startswith("\x01P\t"):
		line = logical(line[3:])
	elif line.startswith("\x01C\t"):
		path, _, n = line[3:].partition("\t")
		line = "count " + logical(path) + " = " + n
	sys.stdout.buffer.write((line + "\n").encode("utf-8", "surrogateescape"))
' "$1" "${meDir}/gen-escapes.py"; }

##	Everything a tree is, read through one CLI: the paths, the count at each,
##	and per instance the string array, the raw body and the info string, with
##	the exit codes, one line per read. A path holding a tab cannot ride the
##	loop; those are left to the native runners. A path goes after `--`, since
##	one led by `-` would read as an option. An instance is `[#N]` to 2.x and
##	`(N)` now.
fReadTree(){
	local cli="$1" doc="$2" p n i q rc side=now
	if [[ "${cli}" == "${oldCli}" ]]; then side=2x; fi
	{
		rc=0; "${cli}" paths "${doc}" > "${tmpDir}/paths" 2>/dev/null || rc=$?
		sed $'s/^/\x01P\t/' "${tmpDir}/paths"
		((rc == 0)) || echo "paths exit ${rc}"
		while IFS= read -r p; do
			[[ -n "${p}" && "${p}" != *$'\t'* ]] || continue
			n="$("${cli}" count "${doc}" -- "${p}" 2>/dev/null || true)"
			printf '\x01C\t%s\t%s\n' "${p}" "${n}"
			[[ "${n}" =~ ^[0-9]+$ ]] || continue
			for ((i = 0; i < n; i++)); do
				if [[ "${side}" == 2x ]]; then q="${p}[#${i}]"; else q="${p}(${i})"; fi
				rc=0; "${cli}" get --string --array --slots "${doc}" -- "${q}" > "${tmpDir}/array" 2>/dev/null || rc=$?
				if [[ "${side}" == 2x ]]; then fOneLine2x < "${tmpDir}/array"; else cat "${tmpDir}/array"; fi
				[[ "${rc}" == 0 ]] || echo "string exit ${rc}"
				"${cli}" get --raw "${doc}" -- "${q}" 2>/dev/null || echo "raw exit $?"
				"${cli}" get --rawinfo "${doc}" -- "${q}" 2>/dev/null || echo "rawinfo exit $?"
			done
		done < "${tmpDir}/paths"
	} | fLogicalPaths "${side}"
}

##	One read answers differently by decision rather than by migration: the info
##	string of an empty binding was BadType in 2.x and is Empty now, matching the
##	raw-content read on the same node. The two reads sit next to each other in
##	the tree above, so the 2.x side's answer is brought forward here rather than
##	dropping the info string from the comparison entirely.
##	Each read prints its (empty) value before its status line, so the raw status
##	sits two lines back.
fAge2xReads(){ awk '$0 == "rawinfo exit 4" && prev == "" && prev2 == "raw exit 2" { $0 = "rawinfo exit 2" } { print; prev2 = prev; prev = $0 }'; }

##	A NUL-bearing document cannot ride a command substitution; the native
##	runners pin those.
fHasNul(){ IFS= read -r -d '' _ <"$1"; }

##	A 2.x fence label with a `#` has no spelling here at all: the `#` opens
##	the line's comment now, and nothing quotes a label. So `migrate` leaves the
##	line as written and the reading differs by design. Matched on the text
##	rather than by file name, because a fuzz document's number moves every time
##	the corpus grows.
fInfoHashLabel(){ grep -qE '(```|~~~)[^#]*#' "$1"; }

##	A carriage return with more text after it on its line. At a piece's edge it
##	was content to 2.x and is trimmed now; in the middle of a piece it reads the
##	same either way, and the corpus pins that, so matching loosely costs little.
fCrMidLine(){ grep -q $'\r[^\r]' "$1"; }

##	A backslash pair 2.x read as an escape stays as written, and reads as text
##	now (2026-10-05). So a value read differs from the 2.x one in exactly that
##	way and no other: read with the 2.x escapes, the current value gives the
##	2.x one, spelled the way fOneLine2x spells it. The same goes for a quoted
##	name in a path, as fLogicalPaths writes it. Only an element or path line
##	that holds a backslash is let through, matched by position, and only when
##	both sides have the same number of lines. Prints the current reads with
##	each such line given the 2.x spelling, so the diff after it shows the rest.
fBackslashText(){ python3 -c '
import re, sys
want = open(sys.argv[1], "rb").read().decode("utf-8", "surrogateescape").split("\n")
got = open(sys.argv[2], "rb").read().decode("utf-8", "surrogateescape").split("\n")
esc = {"t": "\t", "n": "\n", "\\": "\\", "\"": "\"", "\x27": "\x27"}
def decode(v):
	out, i = [], 0
	while i < len(v):
		if v[i] == "\\" and i + 1 < len(v) and v[i + 1] in esc:
			out.append(esc[v[i + 1]]); i += 2
		else:
			out.append(v[i]); i += 1
	return "".join(out)
def one_line(v):
	if "\n" not in v and "\r" not in v:
		return v
	for a, b in (("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
		v = v.replace(a, b)
	return "\"" + v + "\""
def show(name):
	if re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name):
		return name
	return "\u00ab" + "".join(c if c.isprintable() and c not in "%\u00ab\u00bb" else "%%%X;" % ord(c) for c in name) + "\u00bb"
def decode_names(line):
	return re.sub("\u00ab([^\u00bb]*)\u00bb", lambda m: show(decode(re.sub(r"%([0-9A-F]+);", lambda h: chr(int(h.group(1), 16)), m.group(1)))), line)
status = ("Good\t", "Empty\t", "BadType\t", "Multiple\t", "NotFound\t")
if len(want) == len(got):
	for k, (w, g) in enumerate(zip(want, got)):
		if w == g or "\\" not in g:
			continue
		if g.startswith(status):
			head, value = g.split("\t", 1)
			if head + "\t" + one_line(decode(value)) == w:
				got[k] = w
		elif "\u00ab" in g and decode_names(g) == w:
			got[k] = w
sys.stdout.buffer.write("\n".join(got).encode("utf-8", "surrogateescape"))
' "$1" "$2"; }

##	2.x read the body of a raw block that never closes to the end of the file
##	(E005, a clean code above). Asked of 2.x, not of migrate's output.
fRawOpen2x(){ awk '$1 == "line" && $4 == "E005" { found = 1 } END { exit !found }' <<<"$(fCheck2x "$1")"; }

##	An indent 2.x placed and the current rules do not. A decrease has to return
##	to the exact column of an ancestor now, so a tab followed by a space-tab, or
##	by two spaces, bound in 2.x and is `E012` here. `migrate` rewrites spellings
##	and not layout, so the line is left as written and the reading differs by
##	design. Nothing is damaged quietly: a load that dropped the line makes
##	`migrate --write` and `fmt --write` refuse at exit 7. Asked of the current
##	parser rather than matched on the text, since what counts is the column the
##	indent falls on and not which characters make it up.
fUnplaced(){
	{ "${newCli}" check "$1" 2>/dev/null || true; } | awk '$1 == "line" && $4 == "E012" { sub(/:$/, "", $2); print $2 }'
}

##	Lines 2.x read cleanly that nothing spells now, so migrate counts them
##	lost and refuses: a selector holding a bare comma, which 2.x matched
##	against an array value by its display form; and a comma list on a field
##	with lines under it, which is E028 in brackets and another value as one
##	string. The first is found in the 2.x text, read the way 2.x reads a
##	path: a backslash shields the next character, and `name:[x]` is a
##	selector too. A raw body is passed over, its block opened by a fence run
##	after the path's colon or at the start of a line. The second is asked of
##	the current parser on migrate's output, and kept only where the 2.x line
##	has a comma.
fLostNow(){
	python3 -c '
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "surrogateescape")
fence = None
def opens(v):
	m = re.match(r"(`{3,}|~{3,})", v.lstrip(" \t"))
	return (m.group(1)[0], len(m.group(1))) if m else None
for n, line in enumerate(text.split("\n"), 1):
	s, i = line.strip(" \t\r"), 0
	if fence:
		if len(s) >= fence[1] and s == fence[0] * len(s):
			fence = None
		continue
	fence = opens(s)
	while not fence and i < len(s):
		if s[i] in "\"\x27":
			q, i = s[i], i + 1
			while i < len(s) and s[i] != q:
				i += 2 if s[i] == "\\" else 1
			i += 1
		else:
			m = re.match(r"[A-Za-z0-9_-]+", s[i:])
			if not m:
				break
			i += m.end()
		m = re.match(r"[ \t]*:?[ \t]*\[", s[i:])
		if m:
			i += m.end()
			body = re.match(r"[ \t]*[^\"\x27 \t\]]", s[i:])
			commas = 0
			while i < len(s) and s[i] != "]":
				commas += s[i] == ","
				i += 2 if s[i] == "\\" else 1
			if body and commas and i < len(s):
				print(n)
				break
			i += 1
		m = re.match(r"[ \t]*\.[ \t]*", s[i:])
		if not m:
			rest = s[i:].lstrip(" \t")
			if rest.startswith(":"):
				fence = opens(rest[1:])
			break
		i += m.end()
' "$1"
	{ "${newCli}" migrate --from-2x "$1" 2>/dev/null || true; } | { "${newCli}" check - 2>/dev/null || true; } \
		| awk '$1 == "line" && $4 == "E028" { sub(/:$/, "", $2); print $2 }' \
		| awk 'NR == FNR { if (index($0, ",")) comma[FNR] = 1; next } comma[$1]' "$1" -
}

##	Takes out every line above, until 2.x reads what is left cleanly. Fails
##	when nothing is left, or when taking lines out keeps turning up more. The
##	first round has the same bytes as the source, so it takes the source's
##	2.x check as given rather than running it again.
fTrim(){
	local src="$1" dst="$2" check2x="$3" lines round
	cp "${src}" "${dst}"
	for round in 1 2 3 4; do
		((round == 1)) || check2x="$(fCheck2x "${dst}")"
		lines="$( { fUnclean2x <<<"${check2x}"
			fUnplaced "${dst}"
			fLostNow "${dst}"
			grep -anE '(```|~~~)[^#]*#' "${dst}" | cut -d: -f1
			grep -an $'\r[^\r]' "${dst}" | cut -d: -f1; } | sort -un)"
		if [[ -z "${lines}" ]]; then [[ -s "${dst}" ]]; return; fi
		sed "${lines//$'\n'/d;}d" "${dst}" > "${dst}.next"
		mv "${dst}.next" "${dst}"
	done
	return 1
}

##	`upgrade --write`, the way a program calls it at start, on each compared
##	document. The backup's name has the test clock's time in it.
upDir="${tmpDir}/up"; upClock="2026-10-04 00:15:00 -420 PDT"
upBackup="cfg_backup_20261004-001500_format-v2.shcl"
declare -i nUpBad=0 nUpRewritten=0 nUpCleanRewritten=0 nUpCurrent=0 nUpPlain=0 nUpAmbiguous=0

##	Errors the current rules find on a load. Hints don't count; `upgrade`
##	leaves a file with only those alone.
fErrors(){ { "${newCli}" check "$1" 2>/dev/null || true; } | awk '$1 == "line" && $3 == "Error:" && $4 ~ /^E/ { n++ } END { print n + 0 }'; }

##	Whether `migrate --from-2x` changed anything but the stamp. It adds the
##	migrated line only then; a refused file gets no stamp, so its text is
##	compared whole.
fMigrateChanged(){
	local last
	last="$(tail -n 1 "$2")"; last="${last%$'\r'}"
	[[ "${last}" == "##    Migrated from SHCL 2.x." ]] && return 0
	[[ "${last}" == "##    Format   "* ]] && return 1
	! cmp -s "$1" "$2"
}

##	A fresh dir holding only the document as cfg.shcl, run through `upgrade
##	--write` and any options given. The exit code is left in upRc.
fUpgradeRun(){
	local src="$1"; shift
	rm -rf "${upDir}"; mkdir -p "${upDir}"; cp "${src}" "${upDir}/cfg.shcl"
	fUpgradeAgain "$@"
}
fUpgradeAgain(){
	upRc=0
	SHCL_TEST_CLOCK="${upClock}" "${newCli}" upgrade --write "$@" "${upDir}/cfg.shcl" >/dev/null 2>"${tmpDir}/upgrade.err" || upRc=$?
}
fUpBad(){ nUpBad+=1; echo "check-migrate: UPGRADE ${upName}: $*"; }
fUpEntries(){ find "${upDir}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

##	Left alone: exit 0, the same bytes, and no backup.
fUpUntouched(){
	((upRc == 0)) || fUpBad "$1: exit ${upRc}, not 0"
	cmp -s "${upSrc}" "${upDir}/cfg.shcl" || fUpBad "$1: the file was changed"
	[[ "$(fUpEntries)" == 1 ]] || fUpBad "$1: something was written beside the file"
}

##	Rewritten: the backup has the original bytes under the dated name, the
##	fresh file loads clean, has the info block once, and a second run, with
##	or without --from-2x, leaves it alone.
fUpRewritten(){
	local how="$1" fresh="${upDir}/cfg.shcl" n opt
	((upRc == 0)) || fUpBad "${how}: exit ${upRc}, not 0"
	cmp -s "${upSrc}" "${upDir}/${upBackup}" || fUpBad "${how}: no backup ${upBackup} with the original bytes"
	[[ "$(fUpEntries)" == 2 ]] || fUpBad "${how}: $(fUpEntries) entries, not the file and its backup"
	n="$(fErrors "${fresh}")"; ((n == 0)) || fUpBad "${how}: the fresh file loads with ${n} error(s)"
	n="$(grep -c 'This config file format is SHCL\.' "${fresh}" || true)"
	[[ "${n}" == 1 ]] || fUpBad "${how}: the info block is there ${n} time(s)"
	cp "${fresh}" "${tmpDir}/fresh.again"
	for opt in --from-2x ""; do
		fUpgradeAgain ${opt:+"${opt}"}
		((upRc == 0)) && cmp -s "${tmpDir}/fresh.again" "${fresh}" && [[ "$(fUpEntries)" == 2 ]] \
			|| fUpBad "${how}: a second upgrade ${opt:-without --from-2x} did not leave it alone (exit ${upRc})"
	done
}

##	With --from-2x a file is rewritten when it loads with an error, or when
##	it loads clean and `migrate` would still change it (`p: a,b`); its reads
##	are the migrated text's. Without, a clean file is current, and one with
##	an error is either the same fresh file or refused at 7 for text that
##	reads two ways, as `migrate` refuses it.
fUpgradeCheck(){
	upName="$1"; upSrc="$2"
	local migrated="$3" migReads="$4" errs changed=0 reads
	errs="$(fErrors "${upSrc}")"
	fMigrateChanged "${upSrc}" "${migrated}" && changed=1
	fUpgradeRun "${upSrc}" --from-2x
	if ((errs || changed)); then
		nUpRewritten+=1; ((errs)) || nUpCleanRewritten+=1
		fUpRewritten "--from-2x"
		reads="$(fReadTree "${newCli}" "${upDir}/cfg.shcl")"
		if [[ "${reads}" != "${migReads}" ]]; then
			fUpBad "--from-2x: the fresh file and the migrated text read differently"
			diff <(printf '%s\n' "${migReads}") <(printf '%s\n' "${reads}") | head -12 || true
		fi
		cp "${upDir}/cfg.shcl" "${tmpDir}/fresh.shcl"
	else
		nUpCurrent+=1
		fUpUntouched "--from-2x, a clean file migrate leaves as it is"
	fi
	fUpgradeRun "${upSrc}"
	if ((errs == 0)); then
		fUpUntouched "a clean file without --from-2x"
	elif ((upRc == 7)); then
		nUpAmbiguous+=1; upRc=0
		fUpUntouched "a refusal at 7"
		if "${newCli}" migrate "${upSrc}" >/dev/null 2>&1; then fUpBad "refused at 7, and migrate without --from-2x did not refuse"; fi
	else
		nUpPlain+=1
		fUpRewritten "without --from-2x"
		cmp -s "${tmpDir}/fresh.shcl" "${upDir}/cfg.shcl" || fUpBad "without --from-2x: a fresh file other than the --from-2x one"
	fi
}

declare -i nCompared=0 nCorpus=0 nTrimmed=0 nSkipped=0 nBad=0 nLostChecked=0 nRawOpen=0
fTest Eq5YPgP corpus and fuzz documents migrate to the tree 2.x read
for f in "${corpus}"/*/input.shcl "${brackets}"/*.shcl "${dump}"/*.shcl; do
	[[ -f "${f}" ]] || continue
	name="${f%/input.shcl}"; name="${name##*/}"; name="${name%.shcl}"
	if fHasNul "${f}"; then nSkipped+=1; continue; fi
	## Every document here is a 2.x file by construction, which is exactly what
	## migrate cannot read off the text: without the flag it leaves the pieces
	## the two rule sets disagree on and refuses.
	## When the one thing wrong with the file under 2.x is bracket arrays and
	## lines nothing spells now, migrate has to refuse over each of them and
	## nothing else.
	check2x="$(fCheck2x "${f}")"
	e019="$(awk '$1 == "line" && $3 == "Error:" && $4 == "E019" { sub(/:$/, "", $2); print $2 }' <<<"${check2x}" | sort -u)"
	## A line 2.x already refused for anything but a bracket array is not
	## one of these.
	refused="$(comm -23 <(fUnclean2x <<<"${check2x}" | sort -u) <(printf '%s\n' "${e019}"))"
	lostNow="$(awk 'NR == FNR { bad[$1] = 1; next } !bad[$1]' <(printf '%s\n' "${refused}") <(fLostNow "${f}"))"
	unclean="$( { fUnclean2x <<<"${check2x}"; printf '%s\n' "${lostNow}"; } | grep . | sort -un || true)"
	arrays="$(printf '%s\n' "${e019}" "${lostNow}" | grep . | sort -un || true)"
	if [[ -n "${unclean}" && "${unclean}" == "${arrays}" ]]; then
		lostRc=0; lostOut="$("${newCli}" migrate --from-2x "${f}" 2>&1 >/dev/null)" || lostRc=$?
		if ((lostRc != 7)); then
			nBad+=1
			echo "check-migrate: DIVERGE ${name}: 2.x read a value nothing spells now, and migrate exited ${lostRc}, not the refusal 7"
		fi
		wantLost="$(grep -c . <<<"${arrays}" || true)"
		gotLost="$(sed -n 's/.*: \([0-9][0-9]*\) line(s) bound a value under 2\.x.*/\1/p' <<<"${lostOut}")"
		nLostChecked+=1
		if [[ "${gotLost:-0}" != "${wantLost}" ]]; then
			nBad+=1
			echo "check-migrate: DIVERGE ${name}: 2.x read ${wantLost} line(s) nothing spells now, migrate counted ${gotLost:-0} lost"
		fi
	fi
	if ! fTrim "${f}" "${tmpDir}/original.shcl" "${check2x}"; then nSkipped+=1; continue; fi
	cmp -s "${f}" "${tmpDir}/original.shcl" || nTrimmed+=1
	f="${tmpDir}/original.shcl"
	rc=0; "${newCli}" migrate --from-2x "${f}" > "${tmpDir}/migrated.shcl" 2>"${tmpDir}/migrate.err" || rc=$?
	## The refusal still prints the migrated text, so the reads below compare it.
	if fRawOpen2x "${f}"; then
		nRawOpen+=1
		if ((rc != 7)) || ! grep -q 'nowhere to put the Format line' "${tmpDir}/migrate.err"; then
			nBad+=1
			echo "check-migrate: DIVERGE ${name}: 2.x read a raw block that never closes, and migrate exited ${rc} without refusing over it"
		fi
	elif ((rc != 0)); then
		nBad+=1
		echo "check-migrate: DIVERGE ${name}: 2.x read it cleanly, and migrate exited ${rc}"
	fi
	old="$(fReadTree "${oldCli}" "${f}")"
	want="$(fAge2xReads <<<"${old}")"
	got="$(fReadTree "${newCli}" "${tmpDir}/migrated.shcl")"
	fUpgradeCheck "${name}" "${f}" "${tmpDir}/migrated.shcl" "${got}"
	if [[ "${want}" != "${got}" && "${got}" == *\\* ]]; then
		printf '%s' "${want}" > "${tmpDir}/want.reads"; printf '%s' "${got}" > "${tmpDir}/got.reads"
		got="$(fBackslashText "${tmpDir}/want.reads" "${tmpDir}/got.reads")"
	fi
	nCompared+=1; [[ "${name}" == fuzz_* ]] || nCorpus+=1
	if [[ "${want}" != "${got}" ]]; then
		nBad+=1
		echo "check-migrate: DIVERGE ${name}: the 2.x reads of the original and the current reads of the migrated text differ"
		diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | head -12 || true
	fi
	## 2026-10-06: the 2.x build no longer reads the migrated text. The output is
	## written in the new syntax, brackets, `- ` items and `◉` escapes, which 2.x
	## reads as something else, and the Format line is what stops a second run.
	# old2="$(fReadTree "${oldCli}" "${tmpDir}/migrated.shcl")"
	# if [[ "${old}" != "${old2}" ]]; then
	# 	nBad+=1
	# 	echo "check-migrate: DIVERGE ${name}: the 2.x reads of the original and of the migrated text differ"
	# 	diff <(printf '%s\n' "${old}") <(printf '%s\n' "${old2}") | head -12 || true
	# fi
done
##	The floors are this test's, or its line read ok on a run that then refused
##	for comparing too little. The exit below still says which floor.
if ((nCompared < minCompared || nCorpus < minCorpus || nCompared - nCorpus < minFuzz)); then nBad+=1; fi

fTest Es34DZj compared documents upgrade to a fresh file beside a backup of the original
nBad+=nUpBad
##	Each way through fUpgradeCheck has to be taken by some document, or one of
##	its branches checked nothing.
if ((nUpRewritten == 0 || nUpCleanRewritten == 0 || nUpCurrent == 0 || nUpPlain == 0 || nUpAmbiguous == 0)); then
	nBad+=1
	echo "check-migrate: an upgrade case no document reached: ${nUpRewritten} rewritten with --from-2x, ${nUpCleanRewritten} of them clean, ${nUpCurrent} current, ${nUpPlain} rewritten without it, ${nUpAmbiguous} refused at 7" >&2
fi

##	A file naming format 3 is never touched, even one that loads with an
##	error.
fTest Es34DZk a file naming format 3 is never upgraded
printf 'a: 1\n  bad\nb 2\n\n##    Format   3\n' > "${tmpDir}/format3-bad.shcl"
declare -i nFormat3=0; nUpBad=0
for f in "${corpus}"/*/input.shcl "${tmpDir}/format3-bad.shcl"; do
	grep -qE '^##[[:space:]]+Format[[:space:]]+[3-9]' "${f}" || continue
	upName="${f%/input.shcl}"; upName="${upName##*/}"; upSrc="${f}"; nFormat3+=1
	fUpgradeRun "${f}" --from-2x; fUpUntouched "format 3, with --from-2x"
	fUpgradeRun "${f}";           fUpUntouched "format 3, without --from-2x"
done
nBad+=nUpBad
((nFormat3 > 1)) || { echo "check-migrate: no corpus input names format 3" >&2; nBad+=1; }

##	Each named case has to keep its shape, or the exception is stale.
fTest EpUIoZd 068 still has a fence label holding a hash
fInfoHashLabel "${corpus}/068-info-hash-spellings/input.shcl" 2>/dev/null \
	|| { echo "check-migrate: 068-info-hash-spellings no longer has a fence label holding a #" >&2; nBad+=1; }
## 2026-10-05: migrate leaves a 2.x backslash as written, so a path that held
## a line break under 2.x reads as the path now and is no longer lost. The
## exception these two kept from rotting is gone, and fPathBreak with it.
# fTest ErUuq8D 170 still has a path that held a line break
# [[ -n "$(fPathBreak "${corpus}/170-unknown-escape/input.shcl")" ]] \
# 	|| { echo "check-migrate: 170-unknown-escape no longer has a path that held a line break" >&2; nBad+=1; }
# fTest ErkiUcu the paths that held a line break in 171 are found in its 2.x text
# ## A drive, a share, and a list element 2.x read as `E:`, a line
# ## break and `ew`, which double quotes write as `"E:\new"`.
# breaks171="$(fPathBreak "${corpus}/171-windows-path-escape/input.shcl" | paste -sd ' ')"
# [[ "${breaks171}" == "3 4 11" ]] \
# 	|| { echo "check-migrate: 171-windows-path-escape has paths that held a line break on lines '${breaks171}', not '3 4 11'" >&2; nBad+=1; }
fTest Erklujb 096 is refused for the raw block 2.x read to the end
rawRc=0; "${newCli}" migrate --from-2x "${corpus}/096-raw-unterminated-eof/input.shcl" >/dev/null 2>"${tmpDir}/migrate.err" || rawRc=$?
{ fRawOpen2x "${corpus}/096-raw-unterminated-eof/input.shcl" && ((rawRc == 7)) && grep -q 'nowhere to put the Format line' "${tmpDir}/migrate.err"; } \
	|| { echo "check-migrate: 096-raw-unterminated-eof is no longer an open raw block under 2.x that migrate refuses (exit ${rawRc})" >&2; nBad+=1; }
fTest EpUIoZe 094 still has a mid-line carriage return
fCrMidLine "${corpus}/094-unicode-space/input.shcl" 2>/dev/null \
	|| { echo "check-migrate: 094-unicode-space no longer has a mid-line carriage return" >&2; nBad+=1; }
##	The third has no corpus case - a new one shifts the fuzz seed set, which
##	costs a gate round - so it is checked against a document built here: 2.x
##	reads both elements, the current parser places only the first, and the write
##	half refuses rather than dropping the second quietly.
printf 'list:\n\t* one\n \t* two\n' > "${tmpDir}/indent.shcl"
fTest EqRiIDw the loose-indent exception fires on a space before a tab
[[ "$(fUnplaced "${tmpDir}/indent.shcl")" == 3 ]] \
	|| { echo "check-migrate: the loose-indent exception no longer fires on a space before a tab" >&2; nBad+=1; }
fTest EqRiIDx 2.x reads both elements of the loose-indent document
[[ "$("${oldCli}" get --string --array "${tmpDir}/indent.shcl" list 2>/dev/null | wc -l | tr -d " ")" == 2 ]] \
	|| { echo "check-migrate: 2.x no longer reads both elements of the loose-indent document" >&2; nBad+=1; }
fTest EqRiIDy a rewrite of the loose-indent document is refused at 7
indentRc=0
"${newCli}" migrate --from-2x --write "${tmpDir}/indent.shcl" >/dev/null 2>&1 || indentRc=$?
((indentRc == 7)) \
	|| { echo "check-migrate: a rewrite of the loose-indent document exited ${indentRc}, not the refusal 7" >&2; nBad+=1; }
fTestEnd
if ((nCompared < minCompared || nCorpus < minCorpus || nCompared - nCorpus < minFuzz)); then
	echo "check-migrate: only ${nCompared} document(s) compared, ${nCorpus} of them corpus cases and $((nCompared - nCorpus)) fuzz-dumped; need ${minCompared}, ${minCorpus} and ${minFuzz} (${nSkipped} skipped)" >&2
	exit 2
fi
if ((nBad)); then
	echo "check-migrate: ${nBad} divergence(s) over ${nCompared} document(s) (${nSkipped} skipped)" >&2
	exit 1
fi
echo "check-migrate: OK: ${nCompared} document(s) migrate to the tree 2.x read, ${nCorpus} corpus cases, $((nCompared - nCorpus)) fuzz-dumped and ${nTrimmed} with lines taken out first; ${nLostChecked} lost count(s) match; ${nRawOpen} refused for an open raw block; ${nSkipped} skipped; upgrade rewrote ${nUpRewritten} with --from-2x (${nUpCleanRewritten} that loaded clean) and ${nUpPlain} without, left ${nUpCurrent} and ${nFormat3} naming format 3, refused ${nUpAmbiguous} at 7"

##	History:
##		2026-09-08  Created with the 3.0 lexical cut, pinned on the funnel merge.
##		2026-09-15  The 2.x build reads the migrated text too.
##		2026-09-16  Lines 2.x could not read come out rather than the whole
##		            document; exit code, lost count and a corpus floor checked.
##		2026-09-18  A floor for the fuzz half and an empty dump refused, after a
##		            dump that wrote nothing passed on the corpus alone.
##		2026-09-20  An indent the current parser places nowhere comes out too, and
##		            the exception is checked against a document built here.
##		2026-10-04  Paths that held a line break are found in the 2.x text rather
##		            than in migrate's output, and any document with one has to
##		            be refused at 7.
##		2026-10-04  A document 2.x read with a raw block that never closes has to
##		            be refused at 7 over it, and its reads still compare.
##		2026-10-05  A backslash 2.x read as an escape reads as text now, so an
##		            element read may differ in that way alone, and a path that
##		            held a line break is no longer refused.
##		2026-10-06  The 2.x build no longer reads the migrated text, which is
##		            in the new syntax. Paths are compared by name, a quoted
##		            name may differ by a backslash pair too, and a selector
##		            with a comma or a comma list over lines counts as lost.
##		2026-10-06  An instance is read as (N) on the current side, and the
##		            corpus inputs with a selector are compared in brackets too.
##		2026-10-07  Each compared document goes through `upgrade --write` too,
##		            and a file naming format 3 is never upgraded.
