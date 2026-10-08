#!/usr/bin/env bash

##	Purpose:
##		Pin CLI behavior the conformance corpus structurally cannot reach: a
##		closed stdin or stdout, '-' named twice on one command line, a carriage
##		return at the end of an ops line, the shape of an op-script error, and
##		whether a read failure still names its cause. Plus the one thing about
##		the help text a diff between bindings cannot see: how wide it is. Every
##		row runs against every binding and is checked against a fixed
##		expectation, not against the other bindings - four-way agreement proves
##		parity, not correctness, and each of these was a defect all four shared.
##
##		stdout and the exit code are contract and are matched exactly. stderr
##		wording is per-binding voice, so a row matches it with a regex that has
##		to hold for all four, or exactly where all four say the same thing.
##	Syntax:
##		cli-regress.bash NAME|CLI [NAME|CLI ...]
##	Exit: 0 = every row passes everywhere, 1 = a row failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

repoDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
## Read by the include: one status line per test, with its test ID.
# shellcheck disable=SC2034
testWhere="cli-regress" testCounter="nBad"
# shellcheck disable=SC1091
source "${repoDir}/cicd/utility/include/test-id.bash"
bindings=()
while (($#)); do case "$1" in
	-h|--help) grep -E '^##' "$0" | sed 's/^##\t\?//'; exit 0 ;;
	*)         bindings+=("$1"); shift ;;
esac; done
((${#bindings[@]})) || { echo "cli-regress: no bindings given" >&2; exit 2; }
for b in "${bindings[@]}"; do
	cli="${b#*|}"
	[[ -x "${cli}" ]] || { echo "cli-regress: binding CLI not executable: ${cli}" >&2; exit 2; }
done

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) onWindows=1 ;; *) onWindows=0 ;; esac
## Stock macOS has no timeout, adn every row then failed at 127.
command -v timeout >/dev/null 2>&1 || { echo "cli-regress: needs timeout (GNU coreutils on macOS)" >&2; exit 2; }
## GNU stat on Linux and msys, BSD stat on macOS and FreeBSD. %a is the mode as
## GNU writes it, special bits included and no leading zero.
if stat -c %i / >/dev/null 2>&1; then gnuStat=1; else gnuStat=0; fi
fStat(){   ## fStat i|G|a FILE
	if [[ "${gnuStat}" == 1 ]]; then stat -c "%$1" "$2"; return; fi
	case "$1" in
		i) stat -f %i "$2" ;;
		G) stat -f %Sg "$2" ;;
		a) printf '%o\n' "$(( 0$(stat -f %p "$2") & 07777 ))" ;;
	esac
}
startDir="${PWD}"
## A setter's note on a kept line it comments out has the local time in it.
export SHCL_TEST_CLOCK="2026-10-04 00:15:00 -420 PDT"

##	The unwritable directory below has to be made writable again or the cleanup
##	cannot empty it.
fCleanup(){
	if [[ "${onWindows}" == 1 ]]; then
		MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "${tmpDir}/nowrite")" /remove:d '*S-1-1-0' >/dev/null 2>&1 || true
	fi
	chmod -R u+w "${tmpDir}" 2>/dev/null || true
	rm -rf "${tmpDir}"
}
tmpDir="$(mktemp -d)"; trap fCleanup EXIT
printf 'a: 1\n'          > "${tmpDir}/ok.shcl"
printf 'a: 1\n  bad\nb 2\n' > "${tmpDir}/bad.shcl"
## A second damaged file, so a layered load has two to tell apart.
printf 'c: 1\nalso bad\n' > "${tmpDir}/bad2.shcl"
mkdir -p "${tmpDir}/adir"
## The deepest a document can legally go: one level under the 512 cap. Python
## was the binding still recursing a frame per level, so this is the shape that
## would exhaust its stack.
awk 'BEGIN{ for (i = 0; i < 511; i++) { for (j = 0; j < i; j++) printf "\t"; printf "n%d:\n", i }
	for (j = 0; j < 511; j++) printf "\t"; printf "leaf: 1\n" }' > "${tmpDir}/deep.shcl"
## A schema whose own default breaks the field's constraints. Generation used to
## emit it anyway, so the starter config failed the schema that produced it.
printf 'field: server.port\n\ttype: int\n\trequired: yes\n\tmin: 1\n\tmax: 10\n\tdefault: 99\n' > "${tmpDir}/baddef.shcl"
## A must-exist path with no name to generate: repeat 1 is a must-exist bound
## like `required`, and generation cannot satisfy it, so the schema is faulted
## rather than a starter that fails its first check. Repeat 2 is the one
## documented shortfall and generates.
printf 'field: "*"\n\ttype: int\n\trepeat: 1\n' > "${tmpDir}/star1.shcl"
printf 'field: "*"\n\ttype: int\n\trepeat: 2\n' > "${tmpDir}/star2.shcl"
## The generation field ceiling, either side of it: the cap used to fire AT the
## limit while its message said past it.
awk 'BEGIN{ for (i = 0; i < 10000; i++) printf "field: f%d\n", i }' > "${tmpDir}/cap10000.shcl"
awk 'BEGIN{ for (i = 0; i < 10001; i++) printf "field: f%d\n", i }' > "${tmpDir}/cap10001.shcl"
## A generator-only `default` the schema cannot write on a value line: a raw
## block has no inline form, and a `type: raw` field's default goes out inline
## and then fails its own type check. Both used to be dropped or reported as a
## wrong type in the generated output.
printf 'field: b\n\ttype: raw\n\tdefault: hello\n\trequired: yes\n' > "${tmpDir}/rawdef.shcl"
## A `desc` with a comma in it. Bare, it used to make the value several
## elements, and the comment came out missing rather than holding the sentence.
## A bare comma is an error now, so the sentence is quoted.
printf 'field: a\n\tdesc: "one, two"\n\trequired: yes\n' > "${tmpDir}/commadesc.shcl"
## A field name with a line break, and a flat name with a dot. Both used
## to be pasted into the diagnostic exactly as stored, so one hint arrived as
## three stderr lines and a flat name read just like nesting.
printf '"a\\nb": 1\n"a\\nb": 2\n' > "${tmpDir}/nbname.shcl"
## An indented malformed line behind a two-byte character, so the E014 column
## counts the indent and bytes rather than characters.
printf 'a:\n\t"\303\251" x\n' > "${tmpDir}/colbytes.shcl"
## A malformed line behind a blank run holding a carriage return, which is a
## blank and never indent. The column left the run out.
printf '\r  b[c: 2\n' > "${tmpDir}/colcr.shcl"
## An int-array whose second element breaks the max, and a float whose bound is
## integral. A range diagnostic used to name the field and nothing else.
printf 'field: ns\n\ttype: int-array\n\tmax: 10\nfield: fs\n\ttype: float-array\n\tmin: 1.0\n' > "${tmpDir}/range.shcl"
printf 'ns: [5, 20, 3]\nfs: [2.0, 0.5, 4.0]\n' > "${tmpDir}/outofrange.shcl"
printf '"x.y": 1\n' > "${tmpDir}/dotname.shcl"
## Script comments past any pipe's buffer, for the @appear and @change rows.
awk 'BEGIN{ for (i = 0; i < 16384; i++) printf "# %061d\n", i }' > "${tmpDir}/opsfill"
## Schema paths and a type with a line break. Every code that names schema
## text printed it raw, so one diagnostic arrived as two stderr lines. The
## break is the value's NEWLINE escape, so the path text holds a real one.
mark=$'\xe2\x97\x89'
printf "field: 'a.\"x%sNEWLINE%sy\"'\n\trequired: yes\nfield: 'b.\"x%sNEWLINE%sy\"'\n\ttype: int\n\tmin: 5\n\tmax: 6\n\tallowed: [5, 6, 1]\n\trepeat: 3\nfield: 'c.\"x%sNEWLINE%sy\"'\n\ttype: bool\n" "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" > "${tmpDir}/nlschema.shcl"
printf 'b:\n\t"x%sNEWLINE%sy": 9\n\t"x%sNEWLINE%sy": 1\nc:\n\t"x%sNEWLINE%sy": maybe\n' "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" > "${tmpDir}/nldoc.shcl"
printf "field: k\n\ttype: \"in%sNEWLINE%st\"\nfield: 'd.\"x%sNEWLINE%sy\".'\n" "${mark}" "${mark}" "${mark}" "${mark}" > "${tmpDir}/nlfault.shcl"
printf 'field: x.y\n\ttype: int\n' > "${tmpDir}/dotschema.shcl"
## A directory a write cannot create a temp file in. The phase is worth naming -
## it is the difference between "fix the file" and "fix its directory" - and the
## C CLI used to guess it from an access() that answers yes for every existing
## directory on windows.
mkdir -p "${tmpDir}/nowrite"
printf 'a: 1\n' > "${tmpDir}/nowrite/f.shcl"
chmod 500 "${tmpDir}/nowrite"
## Windows decides a create by the ACL, not the mode bits, so there the
## directory is denied adding a file instead. The fix (20260902 item 44) was
## windows-only, and the chmod left its row nothing to judge. A deny that does
## not hold for this account would pass the old code too, so a create is tried
## first; the path conversion is off so /deny reaches icacls as written. The
## try is a native one: on the hosted runner a create from bash goes through
## the deny while a native process is refused.
nowriteHeld=1
if [[ "${onWindows}" == 1 ]]; then
	nowriteHeld=0
	if MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "${tmpDir}/nowrite")" /deny '*S-1-1-0:(WD,AD)' >/dev/null \
		&& ! powershell.exe -NoProfile -NonInteractive -Command "try { [IO.File]::Create('$(cygpath -w "${tmpDir}/nowrite/probe")').Close(); exit 0 } catch { exit 1 }" >/dev/null 2>&1; then
		nowriteHeld=1
	fi
fi
## A raw block against a string `allowed`: the body has its own newlines, so
## one diagnostic used to span several stderr lines.
#  shellcheck disable=2016  ## the backticks are the fence the fixture needs.
printf 'b:\n\t```\n\tline one\n\tline two\n\t```\n' > "${tmpDir}/rawval.shcl"
printf 'field: b\n\ttype: string\n\tallowed: nope\n' > "${tmpDir}/rawvalschema.shcl"
## A schema whose own load has something to say: two `field: a` instances merge,
## so `allowed` repeats as a bare leaf - which is exactly what the V092 under it
## is about, and it was invisible.
printf 'field: a\n\tallowed: x\nfield: a\n\tallowed: y\n' > "${tmpDir}/hintschema.shcl"
## A must-exist path with nothing to generate from: an index selector needs an
## instance that is not there, and a path past the nesting cap would draw E016
## on the way back in. Either way the fault names the path rather than reporting
## the generated config as missing it.
printf 'field: "srv(1).port"\n\trequired: yes\n' > "${tmpDir}/idxreq.shcl"
## Two must-exist paths nothing can generate, either side of a field that
## generates fine: the refusal used to stop at the first, so fixing one only
## bought the next one's message.
printf 'field: "srv(1).port"\n\trequired: yes\nfield: "*"\n\ttype: int\n\trepeat: 1\nfield: ok\n\ttype: int\n' > "${tmpDir}/twoblocked.shcl"
## A schema that does not build: the report is the build faults alone, not the
## faults plus what an empty document would owe the schema.
printf 'field: a\n\ttype: int\n\trequired: yes\nfield: b\n\ttype: nope\n' > "${tmpDir}/nobuild.shcl"
## An instance whose discriminator holds an '=', which is what made --set's own
## split ambiguous.
printf 'x(a=b):\n\tc: 0\n' > "${tmpDir}/sel.shcl"
## An instance whose discriminator holds an apostrophe: ordinary text in a bare
## selector, which the split used to read as an open quote.
printf "srv(\"O'Brien\"):\n\tport: 0\n" > "${tmpDir}/quote.shcl"
## A name a path cannot hold bare, for the traversal commands: enumerating keys
## is only useful if what comes back can be read straight back.
printf 'db:\n\thost: h\n\t"odd.key": 2\nweb:\n\tport: 1\n' > "${tmpDir}/tree.shcl"
## Two plain keys, for the edit options: what each one leaves behind is the
## whole assertion, so the document has to be small enough to spell out.
printf 'a: 1\nb: 2\n' > "${tmpDir}/two.shcl"
## Bracket text on a value line is kept verbatim and binds nothing, so the
## rewrite goes through unchanged. The 2.x selector sugar reads the same way
## now, and the line under it loads under the field with no value, so that
## file saves as written too. The sugar file is copied fresh for every run of a row
## that names %W%, since a rewrite is the thing being tested.
printf 'ports: [80, 443]\n' > "${tmpDir}/brarray.shcl"
printf 'srv("1,000").port: 1\n' > "${tmpDir}/selcomma.shcl"
printf 'base:[Boston]\n\tlat: 42\n' > "${tmpDir}/sugar.shcl"
## A value the two rule sets read differently: 2.x resolved the backslash and
## these rules do not. migrate leaves it as written, so it reads as text
## (2026-10-05). Copied fresh for the rows that rewrite, the way the sugar
## file is.
printf 'p: %s\n' "'C:\temp'" > "${tmpDir}/bsrc.shcl"
## An escaped comma 2.x folded into one element, so migrate rewrites the line,
## plus a tab-indented line at no open level, which the load drops. The rewrite
## is refused, which is what --check has to say rather than counting the line
## it would have changed.
printf 'list: a\\,b, c\nwin:\n\t\tm: 4\n\tstray: 1\n' > "${tmpDir}/mlost.shcl"
## The bracket array again, for the rows that rewrite it. %BA% is shared, and a
## migrate that stamps the file would leave the next binding nothing to do.
printf 'ports: [80, 443]\n' > "${tmpDir}/brsrc.shcl"
## A file that says which rules wrote it, which is the whole answer: there is
## nothing to migrate and a second run must not touch it.
printf 'p: 1\n##    Format   3\n' > "${tmpDir}/stamped.shcl"
## A Format line inside a raw body is that block's content. Taken as the
## file's, the first made a current file look like 2.x and rewrote it at exit
## 0, and the second made any file look current.
#  shellcheck disable=2016  ## the backticks are the fence the fixture needs.
## The first has a raw block the two rule sets split differently beside it
## (2026-10-05), since a backslash in a value no longer reads two ways. Taken
## as 2.x, it would refuse over that block never closing instead.
printf 'note:\n\t```\n##    Format   2\n\t```\n%s: ~~~\n\tx\n\t~~~\n' "'C:\\'" > "${tmpDir}/rawfmt2.shcl"
#  shellcheck disable=2016
printf 'p: %s\nnote:\n\t```\n##    Format   3\n\t```\n' "'C:\temp'" > "${tmpDir}/rawfmt3.shcl"
## A stamped file behind a BOM, whose value 2.x would have read another way.
printf '\357\273\277##    Format   3\np: %s\n' 'C:\temp' > "${tmpDir}/bomstamped.shcl"
## A file naming its schema on a Schema line, beside a schema it fails, and
## files naming a URL and a schema that is not there.
mkdir -p "${tmpDir}/sp"
printf 'field: port\n\ttype: int\n' > "${tmpDir}/sp/app.schema.shcl"
printf '##    Schema   app.schema.shcl\nport: abc\n' > "${tmpDir}/sp/cfg.shcl"
printf '##    Schema   https://example.com/app.schema.shcl\nport: abc\n' > "${tmpDir}/spurl.shcl"
printf '##    Schema   gone.schema.shcl\nport: abc\n' > "${tmpDir}/spgone.shcl"
## A Schema line indented under a block, the way fmt writes it. Lines naming a
## device, a FIFO, a path holding a NUL and a windows share, which check must
## not read. A config whose name holds a backslash, which is no separator here.
printf 'a:\n\t##    Schema   app.schema.shcl\n\tb: 1\nport: abc\n' > "${tmpDir}/sp/ind.shcl"
printf '##    Schema   /dev/zero\nport: 1\n' > "${tmpDir}/sp/zero.shcl"
printf '##    Schema   fifo\nport: 1\n' > "${tmpDir}/sp/fifo.shcl"
printf '##    Schema   app.schema.shcl\000x\nport: 1\n' > "${tmpDir}/sp/nul.shcl"
printf '##    Schema   //host/share/app.schema.shcl\nport: 1\n' > "${tmpDir}/sp/share.shcl"
if [[ "${onWindows}" == 0 ]]; then
	mkfifo "${tmpDir}/sp/fifo"
	printf '##    Schema   ./app.schema.shcl\nport: abc\n' > "${tmpDir}/sp/back\\slash.shcl"
fi
## A Schema line in a raw body opened by a single-quoted name ending in a
## backslash. 2.x read that backslash as escaping the quote, and a line walk
## that read the file that way took the line as the file's. The same for a
## Format line, beside a value the two rule sets read differently.
printf '%s: ~~~\n\t##    Schema   ./lax.shcl\n\t~~~\n##    Schema   app.schema.shcl\nport: abc\n' "'C:\\'" > "${tmpDir}/sp/rawname.shcl"
printf '%s: ~~~\n\t##    Format   3\n\t~~~\np: %s\n' "'C:\\'" "'C:\temp'" > "${tmpDir}/rawfmtq.shcl"
## The kernel's page map is a regular file of size 0 that reads as hundreds of
## GiB, so only a cap on the read stops it. A schema exactly at the cap is
## read, and one a byte over is not.
printf '##    Schema   /proc/self/pagemap\nport: 1\n' > "${tmpDir}/sp/pagemap.shcl"
printf '##    Schema   atcap.schema.shcl\nport: abc\n' > "${tmpDir}/sp/atcap.shcl"
printf '##    Schema   overcap.schema.shcl\nport: abc\n' > "${tmpDir}/sp/overcap.shcl"
capPad="#$(printf 'x%.0s' {1..1022})"$'\n'; capPad="${capPad}${capPad}${capPad}${capPad}"
{ printf 'field: port\n\ttype: int\n'; for ((i = 0; i < 4200; i++)); do printf '%s' "${capPad}"; done; } > "${tmpDir}/sp/atcap.schema.shcl"
cp "${tmpDir}/sp/atcap.schema.shcl" "${tmpDir}/sp/overcap.schema.shcl"
truncate -s 16777216 "${tmpDir}/sp/atcap.schema.shcl"
truncate -s 16777217 "${tmpDir}/sp/overcap.schema.shcl"
## A Format line indented under a block, beside a value 2.x read another way.
printf 'p: %s\nsrv:\n\t##    Format   3\n\tx: 1\n' "'C:\temp'" > "${tmpDir}/indstamped.shcl"
## A Format line of five thousand digits: no format will have that number, and
## CPython refuses an int() past 4300 digits, so Python raised where the other
## three read it as this major and said there was nothing to migrate.
{ printf 'p: 1\n##    Format   '; printf '9%.0s' $(seq 5000); printf '\n'; } > "${tmpDir}/bigfmt.shcl"
## An older Format line with migrate's own stamp after it, so the first line
## found is the older one.
printf 'a: 1\n##    Format   0\n##    Format   3\n' > "${tmpDir}/twostamps.shcl"
## An old info block with the file's own comments written right under it.
printf 'port: 1\n\n##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://example.invalid/shcl\n##\n## Ops team: do not edit by hand.\n## Pager: 555-0100\n' > "${tmpDir}/ownbanner.shcl"
## A default on a path whose last segment selects by value. A value after that
## selector is ignored, so generation used to write a line that failed its own
## check. One default contradicts the selector and one names it.
printf 'field: "a(b)"\n\trequired: yes\n\tdefault: hello\n' > "${tmpDir}/seldefbad.shcl"
## A schema naming a path the two-error file does not have, so validation has
## something to say that the parse does not.
printf 'field: zz\n\trequired: yes\n' > "${tmpDir}/missreq.shcl"
## Two instances whose values hold a real line break, and one plain value, so a
## listing that spans lines can be told from one that does not. Then an array
## and a scalar each holding one, for get.
printf 'srv: "a%sNEWLINE%sb"\nsrv: "c%sNEWLINE%sd"\nplain: x.y\narr: ["a%sNEWLINE%sb", c]\none: "x%sNEWLINE%sy"\n' "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" "${mark}" > "${tmpDir}/nlvalue.shcl"
printf 'field: "a(b)"\n\trequired: yes\n\tdefault: b\n' > "${tmpDir}/seldefok.shcl"
## An optional field's line is commented, so the self-check never read its
## default. The second schema must still pass, since each line works alone;
## checked all at once, srv and srv.port make two srv against a repeat of 1.
printf 'field: port\n\ttype: int\n\tmax: 10\n\tdefault: 99\n' > "${tmpDir}/optdefbad.shcl"
printf 'field: srv\n\trepeat: [0, 1]\n\tdefault: web\nfield: srv.port\n\ttype: int\n\tdefault: 80\nfield: "a(b)"\n\tdefault: c\n' > "${tmpDir}/optdefok.shcl"
## An optional field whose default names another instance than its path
## selects. Its line is commented, so the check only looked at the value.
## The second schema is the optdefok one with `a(b)` defaulting to `b`, which
## is what that one now has to say to pass.
printf 'field: "env(prod)"\n\tdefault: staging\n' > "${tmpDir}/optselbad.shcl"
printf 'field: srv\n\trepeat: [0, 1]\n\tdefault: web\nfield: srv.port\n\ttype: int\n\tdefault: 80\nfield: "a(b)"\n\tdefault: b\n' > "${tmpDir}/optdefok2.shcl"
## An optional line with no default was never read back, so a selector whose
## value breaks the field's type went out commented at exit 0. And a valued
## parent whose array default holds a `]` has no selector a child can use.
printf 'field: "flag(on)"\n\ttype: int\n' > "${tmpDir}/optnodef.shcl"
printf 'field: tags\n\trequired: yes\n\tdefault: ["a]", c]\nfield: tags.x\n\trequired: yes\n' > "${tmpDir}/nosel.shcl"

## A 250-character basename. The temp file used to take the whole name plus
## the process id, which put it over the filesystem's limit somewhere in the
## low 240s - at a point that moved with the width of the pid.
longName="$(printf 'l%.0s' $(seq 245)).shcl"
printf 'k: 1\n' > "${tmpDir}/${longName}"
## Sixty four-byte characters: 245 bytes, inside the filesystem's limit. The
## temp name's cap counted characters, so this one could not be rewritten.
wideName="$(printf '\xf0\x9f\x98\x80%.0s' $(seq 60)).shcl"
printf 'k: 1\n' > "${tmpDir}/${wideName}"
## Loads without a diagnostic, so a --check row's stderr holds only --check's own
## line. The extra spaces are all that is wrong with it.
printf 'a:   1\n' > "${tmpDir}/noncanon.shcl"
## A file kept by hand, for the save that keeps lines: spacing, a quoted
## value, a capital and a four-space indent that the canonical form rewrites.
printf '# note\nName:   "x"   # c\nblock:\n    a: 1\n' > "${tmpDir}/keepsrc.shcl"
## The load drops the tab-indented stray line. The keep save writes it back.
printf 'font:\n\tsize: 12\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n' > "${tmpDir}/keeplost.shcl"
printf 'val: 1\n\t- e\nz: 2\n' > "${tmpDir}/keepelem.shcl"
## A wildcard selector keeps the line under a malformed array dropped: the
## path could not open, where a plain one now does (2026100115403384).
printf 'x(*): [1, 2\n x:\nx.a: 2\n' > "${tmpDir}/keepgap.shcl"
printf 'a:\n\tx: 1\nb:   2\na:\n\ty: 1\n' > "${tmpDir}/keepfold.shcl"
## Mixed line ends, the first line the odd one out either way.
printf 'a: 1\nb: 2\r\nc: 3\r\n' > "${tmpDir}/keepcrlf.shcl"
printf 'a: 1\r\nb: 2\nc: 3\n' > "${tmpDir}/keeplf.shcl"
## A CRLF raw block in an LF file, and files with no final newline whose last
## kept line ends the other way from most.
#  shellcheck disable=2016  ## the backticks are the fence the fixture needs.
printf 'x: 1\ny: 2\nr: ```\r\n\tb\r\n\t```\r\nz: 3\n' > "${tmpDir}/keepraw.shcl"
printf 'a: 1\r\nb: 2\nc: 3\nx: 0\r\nz: 9' > "${tmpDir}/keeptail.shcl"
printf 'a: 1\r\nb: 2\r\nc: 3\r\nx: 0\nz: 9' > "${tmpDir}/keeptaillf.shcl"
## 2.x selector sugar in a CRLF file, and in one split evenly between the two.
printf 'base:[Boston]\r\n\tlat: 42\r\n' > "${tmpDir}/migcrlf.shcl"
printf 'base:[Boston]\r\n\tlat: 42\n' > "${tmpDir}/migtie.shcl"
## No final newline: a CRLF file, and a last line ending in a lone CR in an LF
## file and in a CRLF one. The stamp ends that line, and that is no rewrite.
printf 'a: 1\r\nb: 2\r\nc: 3' > "${tmpDir}/mignofinal.shcl"
## A list with a field under it after an instance an edit empties, which has
## fields: no text loads that back (2026100511210900).
printf 'x: v\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n' > "${tmpDir}/listempty.shcl"
printf 'a: 1\nb: 2\r' > "${tmpDir}/miglonecr.shcl"
printf 'a: 1\r\nb: 2\r\nc: 3\r' > "${tmpDir}/miglonecrcrlf.shcl"
## A 2.x file whose raw block never closes, so the Format line has nowhere to go.
printf 'a: %s\nb: ~~~\n\tline\n' "'x\ty'" > "${tmpDir}/migraw.shcl"
## Two Windows paths holding a line break on one line, and a bracket array on
## the next: three values lost, on two lines.
printf '%s\n' 'p: "C:\\a\nb", "D:\\c\nd"' 'q: [1, 2]' > "${tmpDir}/miglost2.shcl"
## 2.x text upgrade has to make over: a comma list these rules refuse, under
## the info block 2.x's init wrote, less its two links, which goes. And text
## that reads two ways, a,b, beside an unclosed quote, so it does not load
## clean either.
printf 'tags: a, b\nport: 80\n\n#\n# This config file format is SHCL.\n# "Simple Hierarchical Config Language"\n#    Legal    SHCL is Copyright \302\251 2026 Jim Collier. License: MIT. No warranty.\n#\n' > "${tmpDir}/upgv2.shcl"
printf 'a: x,y\nb: "q\n' > "${tmpDir}/upgamb.shcl"
## Clean under these rules, and an array under 2.x.
printf 'p: a,b\n' > "${tmpDir}/upgclean.shcl"
## A schema key nothing knows, on schema line 2.
printf 'field: a\n\tbogus: 1\n' > "${tmpDir}/unkey.shcl"
## A file and a name that both start with a dash, so only `--` makes them data.
## The row that names it runs from inside the temp dir.
printf -- '"-h": 7\n' > "${tmpDir}/-dash.shcl"
## A value outside ASCII, for a stdout whose locale cannot write it.
printf 'n: "caf\303\251 \342\202\254"\n' > "${tmpDir}/nonascii.shcl"
## Seventy of each: the C CLI once held these in fixed arrays of 64.
manyLayers="$(printf -- '--layer=%%F%% %.0s' {1..70})"
manySets="$(for i in {0..69}; do printf -- '--set=k%d=%d ' "${i}" "${i}"; done)"

##	Rows: id | argv | stdin | rc | stdout | stderr-regex [| created-file]
##	The last field is optional: when given, %C% must hold exactly that text
##	after the run, which is how a write that prints nothing gets asserted.
##	argv placeholders: %F% the good file, %B% the two-error file, %B2% a second
##	damaged file for a layered load, %D% a directory,
##	%P% the deepest legal document, %S% the self-contradicting schema, %S1%/%S2%
##	a nameless must-exist path at repeat 1 and 2, %S3% a schema that does not
##	build, %S4% a required path with an index selector, %SF% two of them either
##	side of a field that generates, %S5%/%S6% a schema at and
##	one past the generation field ceiling, %S7% a schema whose own load hints,
##	%S8% a raw default, %S9% a desc with a comma, %N% a file in a directory that
##	takes no temp file, %R%/%SA% a raw block and a schema that refuses it, %X% an
##	instance whose discriminator holds an '=', %Q% one whose discriminator holds
##	an apostrophe, %T% a document with a name that needs quoting in a path,
##	%F2% a two-key file for the edit options, %M% a path with no file at it,
##	%BA% a bracket array, %SQ% a selector whose discriminator needs quotes,
##	%SP% a file naming its schema on a Schema line, %SPS% that schema, %SPU%
##	a file naming a URL there, %SPG% one naming a schema that is not there,
##	%SPI% one naming it on an indented line, %SPZ%/%SPF%/%SPN% ones naming a
##	device, a FIFO and a path holding a NUL, %SPW% one naming a windows share
##	(windows only), %SPB% one whose name holds a backslash, %SPM% one naming
##	/proc/self/pagemap, %SPC%/%SPO% ones naming a schema exactly at the read
##	cap and one byte over it, %SPR% one naming it after a raw body opened by a
##	name ending in a backslash, %V3I% a file whose
##	Format line is indented,
##	%SV% a schema naming a path the two-error file does not have,
##	%NV% two instance values holding a line break beside one plain value,
##	%K% a fresh copy of a file kept by hand, at the path %C% names, %KL% the
##	same for a file whose load drops a line, %KE% one that drops an element
##	under a field with a value, %KG% one that drops a line between two lines
##	of one block, %KF% one whose save cannot keep its lines, %KM%/%KN% ones
##	whose line ends are mostly CRLF and mostly LF, %KR% a CRLF raw block in an
##	LF file, %KT%/%KU% no final newline after a last line ending the other way,
##	%MC% 2.x sugar in a CRLF file, %MT% the same with as many LF line ends,
##	%MN%/%MX%/%MY% a CRLF file with no final newline and ones whose last line
##	ends in a lone CR, in an LF file and a CRLF one, %MR% a 2.x file whose raw
##	block never closes, and %MNW%/%MXW%/%MRW% fresh copies of the first, second
##	and fourth at the path %C% names, %MV% two lost values on one line and a
##	bracket array on the next, %LEW% a fresh copy at that path of a stacked
##	list with a field under it, after an instance of its name with fields,
##	%U2% a 2.x file under 2.x's info block that does not load clean, %UA% one
##	that reads two ways, and %U2W%/%UAW% fresh copies of them at that path,
##	%UC% one that loads clean and reads as an array under 2.x,
##	%W% a fresh copy of the selector-sugar file, %BS% a fresh copy of a file
##	holding a backslash 2.x read as an escape, %BW% a fresh copy of
##	the bracket array, %V3% a file that already names its format,
##	%V3B% the same behind a BOM, %V03% an older Format line and then the
##	current one, %BN% an info block with the file's own comments under it, %FB% a Format line of five thousand digits, %RF2%/%RF3% a raw body holding a Format line, %RFQ% one opened by a name ending in a backslash,
##	%ML% a 2.x file migrate rewrites whose migrated text still drops a line,
##	%SB%/%SC% a last-segment selector whose default contradicts it and one
##	whose default names it, %SD%/%SE% an optional field's bad default and
##	optional lines that each pass alone, %SH% an optional field whose default
##	names another instance than its path selects, %SI% the %SE% schema with a
##	default that names its instance, %SJ% an optional selector with no
##	default whose value breaks its type, %SK% a valued parent whose array
##	default has no selector spelling,
##	%C% a path with nothing at it, cleared before every binding's run, %E% an
##	empty argument, %DB% a --default with a line break, %LS% a long s
##	(U+017F), which Unicode upper-cases to S,
##	%L% a fresh copy of a file whose basename is 250 characters, %LW% one whose
##	basename is 245 bytes of four-byte characters,
##	%NB% a repeated field name with a line break, %DN%/%SN% a flat name
##	with a dot and a schema that declares it as nesting, %SL%/%SM% schema
##	paths and a type with a line break, valid and faulted, and %DL% a
##	document for them, %CB% a malformed
##	line indented and behind a non-ASCII name, %CR% one behind a carriage
##	return that is not indent, %SG%/%DG% a schema with an int
##	and a float range and a document that breaks both, %NC% a file that loads
##	clean and is not canonical, %SU% a schema with an unknown key on line 2,
##	%DD% a file named -dash.shcl holding the name -h (the row runs from the
##	temp dir), %NA% a value outside ASCII, %XF% a byte that is not UTF-8.
##	stdin: printf %b text, '-' none, '@closedin' / '@closedout' close that
##	stream, '@fullout' / '@fullerr' point it at a device that is always full,
##	'@appear' / '@change' make %C% or change it while the command waits on
##	stdin for its ops, '@asciilocale' none, with an ASCII-only locale and
##	PYTHONIOENCODING, '@memcap' none, under a 2 GB address-space cap so a read
##	that never ends fails fast.
##	stdout and stderr: '-' means unchecked; an empty stdout field means exactly empty.
##	A stderr regex starting with '!' must match NO line. A stderr field
##	starting with '=' is the whole of stderr, printf %b text, matched exactly.
##	Each row names the round and item it pins, and starts with its test ID.
## A CLI that starts reading a stdin nothing feeds would hang the gate. Each
## row runs under this limit and fails by name instead (20260926 idea 5).
rowSecs=60
rows=(
	## 20260830 item 15: a second '-' read an empty document that looked like an answer.
	'EoTHA7U|dup-stdin-schema|check --schema=- -|a: 1\n|1||named only once'
	'EoTHA7V|dup-stdin-layer|get --layer=- - a|a: 1\n|1||named only once'
	## 20260830 item 10: the reference kept a trailing CR on an ops line, the ports stripped it.
	'EoTHA7W|ops-line-cr|set %F%|int\tx\t1\r|0|a: 1\n\nx: 1\n|-'
	'EoTHA7X|ops-lone-cr|set %F%|int\tx\t1\n\r|0|a: 1\n\nx: 1\n|-'
	## 20260908: one CR comes off an ops line, not two - the second is the value's.
	'EpGigIR|ops-double-cr|set %F%|string\tx\tv\r\r\n|0|a: 1\n\nx: "v\xe2\x97\x89CR\xe2\x97\x89"\n|-'
	## 20260924 item 7: Windows PowerShell 5.1 puts a BOM, or more than one, in
	## front of text it pipes to a program, and the first op read as unknown.
	'Er83b6G|ops-leading-bom|set %F%|\xef\xbb\xbf\xef\xbb\xbfint\tx\t1\n|0|a: 1\n\nx: 1\n|-'
	## 20260830 item 14: Python raised a traceback, C exited nonzero. POSIX-only:
	## the row closes fd 0, and windows has no equivalent a shell can set up.
	'EoTHA7Y|closed-stdin|fmt -|@closedin|0||^$'
	'EoTHA7Z|closed-stdout|fmt %F%|@closedout|0|-|^$'
	## 20260830 item 16: C dropped the line number and the offending op.
	'EoTHA7a|bad-op-unknown|set %F%|bogus\ta\t1\n|1|-|op line 1: unknown op: bogus'
	## 20260925: the banner op takes on or off where other ops take a path.
	'Equbm1a|banner-on-off|set %F%|banner\ton\nbanner\toff\n|0|a: 1\n|-'
	'Equbm1b|banner-bad-value|set %F%|banner\tmaybe\n|1|-|op line 1: bad banner: maybe \(on or off\)$'
	## 2026100307163904: banner took the file's own comments written against
	## the block with it, at exit 0.
	'Erg8DKv|banner-off-keeps-own-comments|set %BN%|banner\toff\n|0|port: 1\n\n## Ops team: do not edit by hand.\n## Pager: 555-0100\n|-'
	'Erg8DKw|banner-on-keeps-own-comments|set %BN%|banner\ton\n|0|port: 1\n\n## Ops team: do not edit by hand.\n## Pager: 555-0100\n\n##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://github.com/yottacore/shcl\n##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n##    Legal    SHCL is Copyright \xc2\xa9 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n##\n|-'
	'Equbm1c|clear-comments-extra-field|set %F%|clear-comments\ta\tx\n|1|-|clear-comments takes 2 tab-separated field'
	## 20260830 item 18: C answered a directory with a bare "read error". Exit 8
	## since 20260830b item 22 split I/O out of the usage code. The wording is
	## the CLIs' own, from a stat ahead of the read, so the row can expect one
	## spelling rather than four platforms' worth (20260901b item 32).
	'EoTHA7b|read-dir-names-error|fmt %D%|-|8|-|^[^ ]*adir: Is a directory$'
	## 20260830 item 17: C printed a bare count instead of naming the diagnostics.
	'EoTHA7c|strict-load-list|fmt --strictness=strict %B%|-|6|-|strict load failed: 2 error diagnostic'
	## 20260918 item 21: the spec named two summary spellings for check and a
	## strict one prints a third.
	'EqGg9jN|check-strict-summary|check --strictness=strict %B%|-|6|line 2: Error: E015\nline 3: Error: E014\nstrict load failed: 2 diagnostic(s)\n|-'
	## 20260920b item 7: a strict load still hands back the document it
	## recovered, so check --schema validates it. Without this the V-codes were
	## dropped and a user got less out of check at strict than at standard.
	'EqT42DA|check-strict-schema-validates|check --strictness=strict --schema=%SV% %B%|-|6|line 2: Error: E015\nline 3: Error: E014\nline 0: Error: V002\nline 1: Error: V001\nstrict load failed: 4 diagnostic(s)\n|-'
	## 20260830 round: an unknown command is judged before its options.
	'EoTHA7d|unknown-cmd-before-opts|bogus --nope %F%|-|1|-|unknown command: bogus'
	## 20260909 item 59: a real option in front of the subcommand was called
	## unknown and then handed its own spelling back as a suggestion, and a value
	## option in space form that ate the filename got only the usage line.
	'EqBBQ52|opt-before-cmd|--schema=x check %F%|-|1||^option --schema goes after the subcommand'
	'EqBBQ53|unknown-opt-before-cmd|--nope check %F%|-|1||^unknown option: --nope'
	'EqBBQ54|opt-space-ate-file|check --schema %F%|-|1||took .* as its value, so no FILE is left'
	## 20260918b item 33: `--schema=` is a path the command line gave, so every
	## binding reads it and fails; Go read the empty string as "no schema".
	'EqM10jo|schema-empty-value|check --schema= %F%|-|8|-|-'
	'EqM10jp|init-schema-empty-value|init --schema=|-|8|-|-'
	## init takes no FILE, so the space form has to keep working there.
	'EqBBQ55|opt-space-init-ok|init --no-banner --schema %S2%|-|0|-|^$'
	## 20260829 item 10: Python recursed a frame per level in three places.
	'EoTJum8|deep-nesting|fmt %P%|-|0|-|^$'
	## 20260830b item 4: init emitted a config that fails the schema that made it.
	'EoTgCvg|init-bad-default|init --schema=%S%|-|6||V097 generated value fails the schema'
	## 20260901 item 5: the self-check waved every V007 through, so a repeat
	## lower bound of 1 - a must-exist path - went out as a config that fails
	## its own schema at exit 0.
	'Eof5nNR|init-star-repeat1|init --schema=%S1%|-|6||V097 required path cannot be generated: \* \(a \* name segment has no name to write\)'
	'Eof5nNS|init-star-repeat2|init --schema=%S2%|-|0|-|^$'
	## 20260902 item 19: an index selector or a path past the cap got the
	## self-check's "required path missing", which points at the config rather
	## than at the schema line nothing can generate.
	'Eolv8m8|init-index-required|init --schema=%S4%|-|6||V097 required path cannot be generated: srv\(1\).port \(an index selector needs an instance'
	## 20260909 item 49: one unwritable path took the whole schema with it and
	## the message said only which path, so the reason and the other blockers
	## were both left to guesswork.
	'EqAwaj2|init-blocked-first|init --schema=%SF%|-|6||V097 required path cannot be generated: srv\(1\).port \(an index selector needs an instance'
	'EqAwaj3|init-blocked-second|init --schema=%SF%|-|6||V097 required path cannot be generated: \* \(a \* name segment has no name to write\)'
	## 20260902 item 20: V096 fired at exactly the ceiling, on a schema with no
	## fragments, saying the schema expands past it.
	'EolvZ3A|init-cap-at-limit|init --no-banner --schema=%S5%|-|0|-|^$'
	'EolvZ3B|init-cap-over|init --no-banner --schema=%S6%|-|6||V096 schema expands past 10000 fields'
	## 20260902 item 43: a raw default was dropped or misreported, a desc with a
	## comma produced no comment, and V096/V097 named a schema line space they
	## are not in.
	'Eon2Qoy|init-raw-default|init --schema=%S8%|-|6||schema line 3: Error: V092'
	'Eon2Qoz|init-comma-desc|init --no-banner --schema=%S9%|-|0|## one, two\n## any, required\na:\n|-'
	'Eon2Qp0|init-genfault-line-space|init --schema=%S4%|-|6||^line 0: Error: V097'
	'Eof5nNT|init-build-fault|init --schema=%S3%|-|6||V091 unknown schema type'
	'Eof5nNU|init-build-fault-only|init --schema=%S3%|-|6||!V002'
	## 20260909 item 5: a value after a last-segment selector is ignored, so a
	## default there generated a line that failed check at exit 6.
	'EptVfIP|init-selector-default-contradicts|init --schema=%SB%|-|6||V097 generated value fails the schema that produced it: required path missing: a\(b\)'
	'EptVfIQ|init-selector-default-consistent|init --no-banner --schema=%SC%|-|0|## any, required\na: b\n|-'
	## Loose bug from 20260909 item 5: an optional field's bad default went out
	## commented at exit 0.
	'EpxsEn2|init-optional-bad-default|init --schema=%SD%|-|6||V097 generated value fails the schema that produced it: value above max 10 at .port.: 99'
	## 20260918 item 4: the same for a default that names another instance.
	'EqGXrwW|init-optional-selector-default|init --schema=%SH%|-|6||V097 generated value fails the schema that produced it: default does not name the instance its path selects: env\(prod\)$'
	## Retired 2026-09-17: a commented child of a commented valued parent now
	## selects the parent's default, so the dotted `srv.port` this row expected
	## became two instances once both lines were uncommented. The row below is
	## the same schema and exit code with the new spelling.
	# 'init-optional-defaults-ok|init --no-banner --schema=%SE%|-|0|## any, repeat 0-1\n# srv: web\n\n## int\n# srv.port: 80\n\n## any\n# a: c\n|-'
	## Retired 2026-09-18 by 20260918 item 4: its `a[b]` had `default: c`,
	## which names another instance than the path selects, and the spec says
	## that fails generation for an optional field too. The row below is the
	## same schema with the default naming `b`.
	# 'init-optional-defaults-ok|init --no-banner --schema=%SE%|-|0|## any, repeat 0-1\n# srv: web\n\n## int\n# srv[web].port: 80\n\n## any\n# a: c\n|-'
	'EqGXrwX|init-optional-defaults-ok-named|init --no-banner --schema=%SI%|-|0|## any, repeat 0-1\n# srv: web\n\n## int\n# srv(web).port: 80\n\n## any\n# a: b\n|-'
	## 20260918b item 26: every commented line is read back, not only one
	## with a default. Item 27: no selector spelling is a refusal, not a
	## child under another instance.
	'EqLiw1w|init-optional-no-default-read-back|init --schema=%SJ%|-|6||V097 generated value fails the schema that produced it: wrong type at .flag\(on\).'
	'EqLiw1x|init-no-selector-spelling|init --schema=%SK%|-|6||V097 required path cannot be generated: tags.x \(its parent.s value has no selector spelling\)'
	## 20260918 item 9: an empty topic is an unknown command, as in the
	## reference; the ports read it as no topic and printed the help at exit 0.
	'EqGfSo4|help-empty-topic|help %E%|-|1||^unknown command:  \(see --help\)$'
	'EqGfSo5|empty-cmd-help|%E% --help|-|1||^unknown command:  \(see --help\)$'
	## 20260918 item 10: a help flag after `help` was taken for the topic.
	'EqGfSo6|help-help-flag|help --help|-|0|-|^$'
	'EqGfSo7|help-h-flag|help -h|-|0|-|^$'
	'EqGfSo8|help-cmd-help-flag|help get --help|-|0|-|^$'
	## 20260918 item 16: the "no FILE is left" refusal came before the option
	## check, so it named the wrong fault and a fix that did not work.
	'EqGfas4|explain-opt-refused-first|explain --layer E001|-|1||^option --layer not valid for explain'
	'EqGfas5|migrate-opt-refused-first|migrate --layer x|-|1||^option --layer not valid for migrate'
	## 20260918 item 17: Go and Python folded a non-ASCII code by Unicode rules
	## and suggested a code for it.
	'EqGfmq0|explain-non-ascii-no-suggestion|explain %LS%001|-|1||!did you mean'
	## 20260918 item 22: two real options still called unknown.
	'EqGgJM8|short-write-before-cmd|-w fmt %F%|-|1||^option -w goes after the subcommand \(see --help\)$'
	'EqGgJM9|flag-given-value|fmt --write=yes %F%|-|1||^option --write takes no value \(see --help\)$'
	'EqGgJMA|type-flag-given-value|get --int=5 %F% a|-|1||^option --int takes no value \(see --help\)$'
	## 20260918 item 23: three usage errors that neither said the fix nor
	## pointed at the help.
	'EqGgRwO|raw-array-see-help|get --raw --array %F% a|-|1||has no --array form \(see --help\)$'
	'EqGgRwP|layer-stdin-set-see-help|set --layer=- %F%|-|1||^--layer=- is not valid for set: .*\(see --help\)$'
	'EqGgRwQ|init-strictness-see-help|init --strictness=1 --schema=%S2%|-|1||^option --strictness not valid for init: .*\(see --help\)$'
	## 20260918 items 19 and 20: explain gave a file spelling that is a comment,
	## and left out the V097 a user meets most.
	'EqGfmq1|explain-e003|explain E003|-|0|\nE003  error       selector names an instance that does not exist\n  a(5).b where there is one a. An index selects an existing instance by\n  position and never creates one, so a binding line should select by value\n  instead.\n\n|-'
	'EqGfmq2|explain-v097|explain V097|-|0|\nV097  error       generated output does not load, or fails its own schema\n  init checks its own output before returning it, so a starter config that\n  would fail its first check is a fault instead. A default outside its\n  field'"'"'s constraints is one cause. A required path nothing can generate is\n  the other, such as one with an index selector, a(0), or a * name. Line 0.\n\n|-'
	## 20260830 item 35: -h and --help after FILE were an unknown option, though
	## every other option is read there.
	'EoUxXlV|help-after-file|get %F% -h|-|0|-|-'
	'EoUxXlW|help-after-file-long|get %F% --help|-|0|-|-'
	## 20260830 item 47: at the default strictness a recovered-from typo was
	## silent unless --write was passed, so stdout had the repair with
	## nothing said about it.
	'EoUxXlX|fmt-diags-without-write|fmt %B%|-|0|-|E015 missing colon'
	'EoUxXlY|set-diags-without-write|set --set=a=2 %B%|-|0|-|E015 missing colon'
	## 20260804: given a --set, set takes its edits from the options and leaves
	## stdin alone, or a set run from a terminal would sit waiting on it.
	'Er1zoZE|set-option-skips-stdin|set --set=a=2 %F%|int\tx\t7\n|0|a: 2\n|-'
	## 20260829 item 6: --set split PATH from VALUE at the first '=' anywhere, so
	## a selector holding one could not be addressed at all.
	'EoUxXlZ|set-eq-in-selector|set --set=x(a=b).c=1 %X%|-|0|x(a=b):\n\tc: 1\n|-'
	## 20260905 item 3: a quote anywhere in the path was read as opening a quoted
	## piece, so an apostrophe in a bare selector left every later '=' looking
	## quoted and the option was refused while get on the same path worked.
	## A quote in a bare selector body is E025 now (2026100207032800), so these
	## two are refused; the quoted rows below take their place.
	#"Ep3OILK|set-quote-in-selector|set --set=srv[O'Brien].port=9 %Q%|-|0|srv[\"O'Brien\"]:\n\tport: 9\n|-"
	#"Ep3OILL|set-default-quote-in-selector|set --set-default=srv[O'Brien].port=9 %Q%|-|0|srv[\"O'Brien\"]:\n\tport: 0\n|-"
	"ErrQs1W|set-quoted-quote-in-selector|set --set=srv(\"O'Brien\").port=9 %Q%|-|0|srv(\"O'Brien\"):\n\tport: 9\n|-"
	"ErrQs1X|set-default-quoted-quote-in-selector|set --set-default=srv(\"O'Brien\").port=9 %Q%|-|0|srv(\"O'Brien\"):\n\tport: 0\n|-"
	"ErrQs1Y|set-bare-quote-in-selector-refused|set --set=srv(O'Brien).port=9 %Q%|-|1||not a usable path"
	"Ep3OILM|set-quoted-selector-eq|set --set=x(\"k)=v\").d=2 %X%|-|0|x(a=b):\n\tc: 0\n\nx: \"k)=v\"\n\td: 2\n|-"
	## set writes back the lines its edits leave alone, printing or in place,
	## where fmt writes the canonical form.
	'EqutO7J|set-keeps-lines|set %K% --set=block.a=2|-|0|# note\nName:   "x"   # c\nblock:\n    a: 2\n|-'
	'EqutO7K|set-write-keeps-lines|set --write %K% --set=block.b=3|-|0|-|-|# note\nName:   "x"   # c\nblock:\n    a: 1\n    b: 3\n'
	'EqutO7L|fmt-write-rewrites-all|fmt --write %K%|-|0|-|-|# note\nname: "x"  # c\nblock:\n\ta: 1\n'
	## A new line ends the way most of the file's lines do, not its first.
	'ErPO61B|set-write-eol-mostly-crlf|set --write %KM% --set=d=4|-|0|-|-|a: 1\nb: 2\r\nc: 3\r\n\r\nd: 4\r\n'
	'ErPO633|set-write-eol-mostly-lf|set --write %KN% --set=d=4|-|0|-|-|a: 1\r\nb: 2\nc: 3\n\nd: 4\n'
	## A changed line keeps its own, a raw block turned scalar too.
	'ErTecqB|set-write-eol-raw-to-scalar|set --write %KR% --set=r=9|-|0|-|-|x: 1\ny: 2\nr: 9\r\nz: 3\n'
	## No final newline stays none, whichever way the new last line ended.
	'ErTecqC|set-write-eol-no-final-crlf|set --write %KT% --remove=z|-|0|-|-|a: 1\r\nb: 2\nc: 3\nx: 0'
	'ErTecqD|set-write-eol-no-final-lf|set --write %KU% --remove=z|-|0|-|-|a: 1\r\nb: 2\r\nc: 3\r\nx: 0'
	## A dropped line refuses the write only when the save falls back to
	## canonical. Removing margin would put stray under window, so that one does.
	'EqzUbG4|set-write-keeps-dropped|set --write %KL% --set=font.size=13|-|0|-|E012|font:\n\tsize: 13\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n'
	'EqzUbG5|set-write-fallback-refused|set --write %KL% --remove=window.margin|-|7|-|would delete 1 line|font:\n\tsize: 12\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n'
	## 20260926 item 1: a rewritten line took a dropped line with it at exit
	## 0, an element under a field with a value or an E018 line between two
	## lines of one block.
	'Er7gigM|set-write-keeps-dropped-element|set --write %KE% --set=val=9|-|7|-|would delete 1 line|val: 1\n\t- e\nz: 2\n'
	## 20260926 idea 2: a save meant to keep the lines that rewrote the whole
	## file said nothing.
	'Er8Ivln|set-write-says-canonical|set --write %KF% --set=b=3|-|0|-|rewritten in the canonical form|a:\n\tx: 1\n\ty: 1\nb: 3\n'
	## The kept line before a dotted line now sits level with its first name
	## (2026100213205957), so this save keeps its lines, the dropped one too.
	#'Er7gihi|set-write-keeps-dropped-between|set --write %KG% --set=x=v|-|7|-|would delete 1 line|x[*]: [1, 2\n x:\nx.a: 2\n'
	'EraAIXa|set-write-keeps-dropped-gap|set --write %KG% --set=x=v|-|0|-|-|x(*): [1, 2\n x:\nx: v\n a: 2\n'
	'EraAIXb|set-write-gap-fallback-refused|set --write %KG% --set=x.b=1|-|7|-|would delete 1 line|x(*): [1, 2\n x:\nx.a: 2\n'
	## 2026100717500003: without --write, set printed the canonical text with
	## the dropped line gone, at exit 0, where --write refused. The print now
	## answers as --write does, so `set f ... > f.new && mv f.new f` is safe.
	'Es8aXnv|set-print-refused-element|set %KE% --set=val=9|-|7||refusing to print: this result would delete 1 line|val: 1\n\t- e\nz: 2\n'
	'Es8aXnw|set-print-fallback-refused|set %KL% --remove=window.margin|-|7||refusing to print: this result would delete 1 line|font:\n\tsize: 12\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n'
	'Es8aXnx|set-print-lossy|set --lossy %KE% --set=val=9|-|0|val: 9\nz: 2\n|printed in the canonical form|val: 1\n\t- e\nz: 2\n'
	'Es8aXny|set-print-keeps-dropped|set %KL% --set=font.size=13|-|0|font:\n\tsize: 13\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n|!canonical|-'
	'Es8aXnz|set-print-says-canonical|set %KF% --set=b=3|-|0|a:\n\tx: 1\n\ty: 1\nb: 3\n|printed in the canonical form|-'
	## A layer under FILE is a merge, which keeps no lines, so a lost line
	## anywhere refuses, and --lossy prints with no word about keeping them.
	'Es8aXo0|set-print-layer-refused|set --set=q=1 --layer=%F% %KE%|-|7||refusing to print|-'
	'Es8aXo1|set-print-layer-lossy|set --lossy --set=q=1 --layer=%F% %KE%|-|0|-|!canonical form|-'
	"Ep3OILN|set-open-quote-refused|set --set=a(\"open=1 %X%|-|1|-|bad --set value"
	## 20260909 item 13: a value built by a setter or a selector read as
	## unquoted, so quoted thousands were BadType until a save and reload.
	'EpykNRw|set-quoted-thousands|get --int --set=a=1,000 %F% a|-|0|1000\n|-'
	"EpykNRx|set-selector-thousands|get --int --set=x(\"1,000\").y=1 %F% x|-|0|1000\n|-"
	'EpykNRy|selector-thousands|get --int %SQ% srv|-|0|1000\n|-'
	## 3.0: bracket text after the colon is one outcome, kept verbatim. The
	## 2.x selector sugar is that shape now too, and migrate is what brings
	## a file written with it across.
	## One diagnostic is one line, and a name is printed the way the emitter
	## would write it. A line break in a name used to split one hint across
	## three stderr lines, and a flat `x.y` printed the same as `x` nesting `y`.
	'Eq4AfLV|diag-name-line-break|check %NB%|-|0|line 2: Hint: H001\nok (1 diagnostic(s))\n|^line 2: Hint: H001 ."a\\nb". repeats'
	## The value half of the same rule: the H001 hint splices the repeated
	## values into its suggestion, and a value with a line break used to go
	## in raw, so the hint arrived as four stderr lines.
	'EqTPxzc|diag-value-line-break|check %NV%|-|0|line 2: Hint: H001\nok (1 diagnostic(s))\n|^line 2: Hint: H001 .srv. repeats as a bare leaf - did you mean .srv: \["a◉NEWLINE◉b", "c◉NEWLINE◉d"\].\?$'
	'Eq4AfLW|diag-name-dotted|check --schema=%SN% %DN%|-|6|line 1: Error: V001\nfailed: 1 diagnostic(s), 1 error(s)\n|unknown field ."x\.y".'
	## 20260918 item 14: the same for schema text, which every code below printed raw.
	'EqGaO1w|schema-text-v002|check --schema=%SL% %DL%|-|6|-|V002 required path missing: a\."x\\ny"$'
	'EqGaO1x|schema-text-v003|check --schema=%SL% %DL%|-|6|-|V003 wrong type at .c\."x\\ny".: value is not a valid bool$'
	'EqGaO1y|schema-text-v004|check --schema=%SL% %DL%|-|6|-|V004 value not allowed at .b\."x\\ny".: 9$'
	'EqGaO1z|schema-text-v005|check --schema=%SL% %DL%|-|6|-|V005 value below min 5 at .b\."x\\ny".: 1$'
	'EqGaO20|schema-text-v006|check --schema=%SL% %DL%|-|6|-|V006 value above max 6 at .b\."x\\ny".: 9$'
	'EqGaO21|schema-text-v007|check --schema=%SL% %DL%|-|6|-|V007 instance count out of bounds at .b\."x\\ny".: 2 not in 3\.\.3$'
	'EqGaO22|schema-text-v091|check --schema=%SM% %DL%|-|6|-|V091 unknown schema type .in\\nt.$'
	'EqGaO23|schema-text-v093|check --schema=%SM% %DL%|-|6|-|V093 bad schema path: d\."x\\ny"\.$'
	## A bracket array is the array spelling now, not E019 (2026100207032800).
	'Ep3QaNl|bracket-array-check|check %BA%|-|0|ok (0 diagnostic(s))\n|-'
	'EpFkZy7|bracket-array-write-kept|fmt --write %BA%|-|0||-'
	## The line under bracket text loads now (2026100115403384), so these two
	## no longer hold: no E018, nothing lost, and the write goes through.
	#'Ep3QaNm|sugar-check|check %W%|-|6|line 1: Error: E019\nline 2: Error: E018\nfailed: 2 diagnostic(s), 2 error(s)\n|-'
	## The sugar is an array on a field with a line under it now (E028): the
	## line is kept, and the line under it loads under the field with no value.
	'Ep3QaNn|sugar-check-strict|check --strictness=strict %W%|-|6|-|-'
	#'EpFkZy8|sugar-write-refused|fmt --write %W%|-|7|-|would delete 1 line'
	'ErUmRRa|sugar-check-block|check %W%|-|6|line 1: Error: E028\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E028 an array on a field with lines under it; the field takes one plain value or none$'
	'ErUmRRb|sugar-block-read|get %W% base.lat|-|0|42\n|-'
	'ErUmRRc|sugar-write-kept|fmt --write %W%|-|0||-'
	'Era9kPy|kept-under-kept-fmt|fmt -|a: [1\n\tb: [2\n|0|a: [1\n\tb: [2\n|-'
	'Era9kPz|kept-before-dotted-fmt|fmt -|k: [3\nm.n: 2\n|0|k: [3\nm:\n\tn: 2\n|-'
	## A comment between nested kept lines nests with them (2026100218185700).
	'Erls2v2|comment-under-kept-fmt|fmt -|a: [1\n\t# note\n\tb: [2\n|0|a: [1\n\t# note\n\tb: [2\n|-'
	'Erls2v3|comment-under-kept-in-block-fmt|fmt -|x:\n  a: [1\n    # note\n    b: [2\n  c: 1\n|0|x:\n\ta: [1\n\t\t# note\n\t\tb: [2\n\tc: 1\n|-'
	## A new field at the end of a block goes after the kept lines that end it,
	## not above them (2026100117214802).
	'Erls2uw|set-new-key-after-kept-end|set --set=b=1 -|x: 1\na:   [1\n# end\n|0|x: 1\na:   [1\n\nb: 1\n# end\n|-'
	'Erls2ux|set-new-key-after-kept-in-block|set --set=s.b=1 -|s:\n    a:   [1\n    # c\n|0|s:\n    a:   [1\n    b: 1\n    # c\n|-'
	## Arrays are written in brackets, and a list item is `- ` then one value
	## (2026100207032800). Each error names what is wrong.
	'ErqYSbF|array-e019-text-after|check -|log: [INFO] started\n|6|line 1: Error: E019\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E019 malformed array, text after .\].; quote the value if it is text$'
	'ErqYSbG|array-e019-nested|check -|n: [[1, 2], 3]\n|6|line 1: Error: E019\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E019 malformed array, a .\[. inside an array; quote the value if it is text$'
	'ErqYSbH|array-e019-empty-element|check -|g: [a,, b]\n|6|line 1: Error: E019\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E019 malformed array, an empty element; quote the value if it is text$'
	'ErqYSbI|array-e019-unclosed|check -|o: [a, b\n|6|line 1: Error: E019\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E019 malformed array, no closing .\]. on the line; quote the value if it is text$'
	'ErqYSbJ|array-e026-bare-comma|check -|ports: 80, 443\n|6|line 1: Error: E026\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E026 a comma then a space or the end in a bare value; write an array in brackets, \[a, b\], or quote the text$'
	'ErqYSbK|list-e013-old-marker|check -|a:\n\t* x\n|6|line 2: Error: E013\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 2: Error: E013 a list item is written .- . now, not .\*.$'
	'ErqYSbL|list-e027-name|check -|a:\n\t- name:\n|6|line 2: Error: E027\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 2: Error: E027 a list item with a colon then a space or the end; write a list of objects as instances, or quote the item if it is text$'
	'ErqYSbM|list-e019-nested|check -|a:\n\t- [x]\n|6|line 2: Error: E019\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 2: Error: E019 a list item is one value, and arrays do not nest; quote the item if it is text$'
	'ErqYSbQ|h001-suggests-brackets|check -|x: a\nx: b\n|0|line 2: Hint: H001\nok (1 diagnostic(s))\n|did you mean .x: \[a, b\].\?$'
	'ErqYSbR|fmt-keeps-stacked|fmt -|a:\n  - x\n  - "y z"\nb: [1,2]\n|0|a:\n\t- x\n\t- "y z"\nb: [1, 2]\n|-'
	## An array on a field with fields under it is E028: the line is kept and
	## written in place of the field's, and the fields under it load under the
	## field with no value. One that joined an earlier binding of its value
	## leaves that one its value.
	'ErrQs1b|array-e028-check|check -|route: [GET, POST]\n\tpath: /x\n|6|line 1: Error: E028\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E028 an array on a field with lines under it; the field takes one plain value or none$'
	'ErrQs1c|array-e028-read-under|get - route.path|route: [GET, POST]\n\tpath: /x\n|0|/x\n|-'
	'ErrQs1d|array-e028-read-field|get - route|route: [GET, POST]\n\tpath: /x\n|2|\n|-'
	'ErrQs1e|array-e028-fmt-kept|fmt -|route:   [GET, POST]\n  path: /x\n|0|route:   [GET, POST]\n\tpath: /x\n|-'
	'ErrQs1f|array-e028-joined-binding|fmt -|c: [v2]\nc:[v2]\n\tq: 1\n|0|c: [v2]\nc:[v2]\n\tq: 1\n|^line 2: Error: E028'
	## A list item with a bare comma is E026, kept among the items (it was
	## E010 and dropped).
	'ErrQs1g|list-e026-item-check|check -|a:\n\t- x, y\n\t- z\n|6|line 2: Error: E026\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 2: Error: E026 a comma then a space or the end in a list item; an item is one value, so quote the text$'
	'ErrQs1h|list-e026-item-kept|fmt -|a:\n\t- x, y\n\t- z\n|0|a:\n\t- x, y\n\t- z\n|-'
	## A bare value or list item may hold spaces, and a colon or comma with
	## text right after it is text. One with a blank or the end after it is an
	## error that says what to do (2026100207032800, 20261006).
	'ErvnzpS|bare-spaces-read|get - t|t: My  App  # c\n|0|My  App\n|-'
	'ErvnzpT|bare-spaces-fmt|fmt -|t: My  App\nl:\n\t- New York\n|0|t: "My  App"\nl:\n\t- "New York"\n|-'
	'ErvnzpU|bare-comma-text-read|get - o|o: rw,noatime\n|0|rw,noatime\n|-'
	'ErvnzpV|bare-colon-text-fmt|fmt -|d: :0\nu: http://h:80/p\n|0|d: ":0"\nu: "http://h:80/p"\n|-'
	'ErvnzpW|e025-loose-colon-check|check -|host: a.com port: 80\n|6|line 1: Error: E025\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E025 a colon then a space in a bare value; put each field on its own line, or quote the value$'
	'ErvnzpX|e025-tab-check|check -|t: a\tb\n|6|line 1: Error: E025\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E025 a tab in a bare value; quote it$'
	'ErvnzpY|e026-trailing-comma-check|check -|x: a,\n|6|line 1: Error: E026\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E026 a comma then a space or the end in a bare value'
	'ErvnzpZ|e027-name-value-check|check -|a:\n\t- name: value\n\t- b\n|6|line 2: Error: E027\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 2: Error: E027 a list item with a colon then a space or the end'
	'Ervnzpa|e025-selector-colon-check|check -|srv(a:b).p: 1\n|6|line 1: Error: E025\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E025 a colon in a bare selector; quote it$'
	'Ervnzpb|array-tight-comma-splits|set --set-literal=t=[a,b] -|t: 1\n|0|t: [a, b]\n|-'
	'Ervnzpc|set-literal-comma-text|set --set-literal=o=rw,noatime --set=e=a, -|o: 1\n|0|o: "rw,noatime"\n\ne: "a,"\n|-'
	'Ervnzpd|migrate-comma-list|migrate --from-2x -|x: a,b\ny: a, b\n|0|x: [a, b]\ny: [a, b]\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	'Ervnzpe|migrate-comma-ambiguous|migrate -|y: a,b\n|7|y: a,b\n|read one way under 2.x and another'
	## A comment on a stacked item stays on it, and one among the items stays
	## among them.
	'ErrQs1i|list-item-comment-fmt|fmt -|l:\n\t# first\n\t- a  # one\n\t- b\n|0|l:\n\t# first\n\t- a  # one\n\t- b\n|-'
	## An array setter keeps a stacked list stacked, as an overwrite keeps
	## quotes, and a backtick value goes in through --set-literal.
	'ErrQs1j|set-stacked-stays-stacked|set --set-literal=l=[1,2] -|l:\n\t- a\n|0|l:\n\t- 1\n\t- 2\n|-'
	"ErrQs1k|set-literal-backtick|set --set-literal=c=\`#FF8800\` -|c: 1\n|0|c: \`#FF8800\`\n|-"
	"ErrQs1l|set-keeps-backtick-kind|set --set=c=y -|c: \`x\`\n|0|c: \`y\`\n|-"
	## A setter that would put a field under an array, or an array over
	## fields, is refused (E028 on a reload).
	'ErrQs1m|set-field-under-array-refused|set --set=l.c=1 -|l: [a]\n|1||^--set: cannot write l.c: an array takes no lines under it$'
	'ErrQs1n|set-array-over-fields-refused|set --set-literal=c=[1,2] -|c: 1\n\tk: 2\n|1||^--set-literal: cannot write c: a field with lines under it takes one plain value or none$'
	## A selector matches one plain value. A bare body with a space or a quote
	## is E025 in a lookup too, and an array value is never selected.
	'ErrQs1o|get-bare-space-selector|get - base(New◉SPACE◉York).lat|base: "New York"\n\tlat: 1\n|0|1\n|-'
	'ErrQs1p|count-selector-skips-array|count - x(a)|x: [a]\nx: a\n|0|1\n|-'
	## A read's PATH that cannot parse is a usage error since 2026100717500001,
	## so this one is exit 1 now; Es8PcO0 below takes its place.
	#"ErrQs1q|get-bare-quote-selector-refused|get %Q% srv(O'Brien).port|-|3|\n|no value at that path"
	## 2026100610073400: a selector is written in parens. One in brackets is
	## E029, kept as written, and a path in brackets is refused with a reason.
	'ErxfmqM|e029-check|check -|a[x].b: 1\n|6|line 1: Error: E029\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E029 selector in brackets; write it in parens, name\(value\), since brackets are only for arrays, at column 2$'
	'ErxfmqN|e029-lines-under-load|get - srv(web).host|srv: web\n\tport: 80\nsrv[web]:\n\thost: h\n|0|h\n|E029'
	'ErxfmqO|e029-fmt-keeps-line|fmt -|srv: web\n\tport: 80\nsrv[web]:\n\thost: h\n|0|srv[web]:\nsrv: web\n\tport: 80\n\thost: h\n|E029'
	## Exit 1 since 2026100717500001, with the same reason; Es8PcNw below.
	#'ErxfmqP|get-bracket-path-named|get %F% a[0]|-|3|\n|a selector is written in parens now, name\(value\)'
	'ErxfmqQ|set-bracket-path-named|set --set=a[0].b=1 %F%|-|1||^--set: cannot write a\[0\]\.b: a selector is written in parens now, name\(value\)$'
	'ErxfmqR|remove-bracket-path-named|set --remove=a[0] %F2%|-|1||^bad --remove value \(a selector is written in parens now, name\(value\)\): a\[0\] \(see --help\)$'
	'ErxfmqS|ops-remove-bracket-path-named|set %F2%|remove\ta[0]\n|1||^op line 1: cannot remove a\[0\]: a selector is written in parens now, name\(value\)$'
	'ErxfmqT|schema-bracket-path-named|check --schema=- %F%|field: "a[*].b"\n|6|line 1: Error: V093\nfailed: 1 diagnostic(s), 1 error(s)\n|V093 bad schema path: a\[\*\]\.b; selector in brackets; write it in parens'
	## Exit 1 since 2026100717500001; Es8PcNz below.
	#'ErxfmqU|get-hash-index-refused|get %F% a(#0)|-|3|\n|no value at that path'
	'ErxfmqZ|set-hash-index-refused|set --set=a(#0)=2 %F%|-|1||not a usable path'
	'ErxfmqV|get-paren-index|get %F% a(0)|-|0|1\n|-'
	'ErxfmqW|e025-paren-in-selector|check -|a(x(y).b: 1\n|6|line 1: Error: E025\nfailed: 1 diagnostic(s), 1 error(s)\n|^line 1: Error: E025 a paren in a bare selector; quote it$'
	'ErxfmqX|get-quoted-paren-selector|get - a("x)y")|a: "x)y"\n|0|x)y\n|-'
	'ErxfmqY|explain-e029|explain E029|-|0|\nE029  error       a selector in brackets, the old spelling\n  Selectors are written in parens: person(Bucky).city, person("New York"),\n  person(0) and person(*). Brackets are only for arrays. The line is kept\n  as written and binds nothing. When it selects by value, the lines under\n  it still load, under the instance it names. On a command line, quote the\n  path, since a bare ( is a syntax error in most shells.\n\n|-'
	## 2026100717500001: a read took a PATH that cannot parse as not found, so
	## get --default printed the default at exit 0 and count printed 0. Every
	## read's PATH is refused at 1 now, as --remove's is, before the load. A
	## missing path still reads as not found, and children takes the empty
	## path as the top level.
	'Es8PcNw|get-bracket-path-usage|get %F% a[0]|-|1||=bad PATH (a selector is written in parens now, name(value)): a[0] (see --help)\n'
	'Es8PcNx|get-default-bad-path|get --int --default=8 %F% a[0].port|-|1||=bad PATH (a selector is written in parens now, name(value)): a[0].port (see --help)\n'
	'Es8PcNy|get-default-unparsable|get --default=8 %F% a..b|-|1||=bad PATH (not a usable path): a..b (see --help)\n'
	'Es8PcNz|get-hash-index-usage|get %F% a(#0)|-|1||=bad PATH (not a usable path): a(#0) (see --help)\n'
	"Es8PcO0|get-bare-quote-selector-usage|get %Q% srv(O'Brien).port|-|1||=bad PATH (not a usable path): srv(O'Brien).port (see --help)\n"
	'Es8PcO1|get-empty-path-usage|get --default=8 %F% %E%|-|1||=bad PATH (not a usable path):  (see --help)\n'
	'Es8PcO2|get-value-in-path-usage|get --on-bad=error %F% a:1|-|1||=bad PATH (not a usable path): a:1 (see --help)\n'
	'Es8PcO3|count-bad-path-usage|count %F% a[0]|-|1||=bad PATH (a selector is written in parens now, name(value)): a[0] (see --help)\n'
	'Es8PcO4|instances-bad-path-usage|instances %F% a(|-|1||=bad PATH (not a usable path): a( (see --help)\n'
	'Es8PcO5|children-bad-path-usage|children %F% .a|-|1||=bad PATH (not a usable path): .a (see --help)\n'
	'Es8PcO6|children-empty-path-top|children %F2% %E%|-|0|a\nb\n|^$'
	'Es8PcO7|get-default-missing-path|get --default=8 %F% nope|-|0|8\n|^$'
	'ErqYSbS|tokens-array|tokens -|p: [a, b] # c\nq: [x\n- y\n|0|1:0 name=0-1 sep=1 value=3-9 array=3 elem=4-5 elem=7-8 comment=10\n2:0 name=0-1 sep=1 value=3-5 array=3 array-fault=3:no closing \x27]\x27 on the line elem=4-5\n3:0 item value=2-3 elem=2-3\n|-'
	'ErqYWEx|get-one-element-string|get - p|p: [80]\n|0|[80]\n|-'
	'ErqYWEy|get-one-element-int|get --int - p|p: [80]\n|0|80\n|-'
	'ErqYWEz|get-empty-array-good|get --array - p|p: []\n|0||-'
	## A repeat header the load folded away goes with the last line under it,
	## blank line and all, and stays with its blank line while anything under
	## it does (2026100115323232).
	'Erls2uy|remove-emptied-repeat-header|set --remove=account(0).name -|account: w\n\temail: a@x\n\naccount: w\n\tname: W\n\nz: 1\n|0|account: w\n\temail: a@x\n\nz: 1\n|-'
	'Erls2uz|set-keeps-blank-above-repeat|set --set=s.a=5 -|s:\n\ta: 1\n\ns:\n\tb: 2\n|0|s:\n\ta: 5\n\ns:\n\tb: 2\n|-'
	## New lines take the indent step most blocks use, not the first block's
	## (2026100115403386).
	'Erls2v0|set-new-block-majority-step|set --set=shell.list.bash.command=bash -|window:\n\t\topacity: 1.0\nwindow:\n\tcolumns: 80\n|0|window:\n\t\topacity: 1.0\nwindow:\n\tcolumns: 80\n\nshell:\n\tlist:\n\t\tbash:\n\t\t\tcommand: bash\n|-'
	'Erls2v1|set-new-block-space-step|set --set=d.e.f=1 -|a:\n  x: 1\nb:\n    y: 1\nc:\n    z: 1\n|0|a:\n  x: 1\nb:\n    y: 1\nc:\n    z: 1\n\nd:\n    e:\n        f: 1\n|-'
	'EpFkZy9|sugar-migrate|migrate %W%|-|0|base: Boston\n\tlat: 42\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	'EpFkZyA|sugar-migrate-write|migrate --write %W%|-|0||-'
	## An unknown escape in double quotes was refused and kept as written, not
	## read with the pair kept after its `\n` already turned into a newline. A
	## backslash is text since 2026100207032800, so these three read clean and
	## the rows after them pin the escape mark instead.
	#'Er1adAn|escape-unknown-check|check -|a: "C:\\work\\new"\n|6|line 1: Error: E023\nfailed: 1 diagnostic(s), 1 error(s)\n|E023 unknown escape .\\w. in double quotes; write a backslash as .\\\\. or use single quotes$'
	#'Er1adAo|escape-unknown-read|get - a|a: "C:\\work"\n|3|\n|no value at that path'
	#'Er1adAp|escape-unknown-literal|set %F2%|literal\tx\t"C:\\work"\n|1||^op line 1: cannot write x'
	'ErpZsUX|escape-mark-unknown-check|check -|a: "say \xe2\x97\x89HELLO\xe2\x97\x89"\n|6|line 1: Error: E023\nfailed: 1 diagnostic(s), 1 error(s)\n|E023 unknown escape'
	'ErpZsUY|escape-mark-unknown-read|get - a|a: "\xe2\x97\x89NOPE\xe2\x97\x89"\n|3|\n|no value at that path'
	'ErpZsUZ|escape-mark-unknown-literal|set %F2%|literal\tx\t"\xe2\x97\x89NOPE\xe2\x97\x89"\n|1||^op line 1: cannot write x'
	'ErpZsUa|backslash-is-text-read|get - a|a: "C:\\work\\new"\n|0|C:\\work\\new\n|-'
	'Er1adAq|escape-unknown-path|get - "a\w"|"a\\\\w": 1\n|3|\n|no value at that path'
	'Er1adAr|escape-doubled-path|get - "a\\w"|"a\\\\w": 1\n|0|1\n|-'
	## \u and \U named a character by its code point, and one that named none
	## was E023. 2.x kept the pair as written, so migrate needed to be told
	## which rules wrote the file. Since 2026100207032800 a backslash is text,
	## the code point escape is U+XXXX between two marks, and the two rule sets
	## read the pair alike. Canonical output writes an invisible character as
	## a code point escape.
	## Raw UTF-8 bytes rather than \u in the printf text: msys bash leaves a \u
	## as written under the windows runner's locale.
	#'Er2qNPd|escape-unicode-read|get - a|a: "caf\\u00E9 \\U0001F600"\n|0|caf\xc3\xa9 \xf0\x9f\x98\x80\n|-'
	#'Er2qNPe|escape-unicode-bad|check -|a: "\\uD800"\n|6|line 1: Error: E023\nfailed: 1 diagnostic(s), 1 error(s)\n|E023 bad escape .\\u. in double quotes'
	'Er2qNPf|escape-unicode-fmt|fmt -|a: x\xe2\x80\x8by\n|0|a: "x\xe2\x97\x89U+200B\xe2\x97\x89y"\n|-'
	#'Er2qNPg|escape-unicode-name|paths -|"a\\u202Eb": 1\n|0|"a\\u202Eb"\n|-'
	#'Er2qNPh|escape-unicode-migrate-refused|migrate -|q: "\\u0041"\n|7|q: "\\u0041"\n|does not say which it was written for'
	#'Er2qNPi|escape-unicode-migrate-2x|migrate --from-2x -|q: "\\u0041"\n|0|q: "\\\\u0041"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	'ErpZsUb|escape-mark-code-read|get - a|a: "caf\xe2\x97\x89U+00E9\xe2\x97\x89 \xe2\x97\x89u+1f600\xe2\x97\x89"\n|0|caf\xc3\xa9 \xf0\x9f\x98\x80\n|-'
	'ErpZsUc|escape-mark-surrogate|check -|a: "\xe2\x97\x89U+D800\xe2\x97\x89"\n|6|line 1: Error: E023\nfailed: 1 diagnostic(s), 1 error(s)\n|E023 escape .* names no Unicode character'
	'ErpZsUd|escape-mark-code-name|paths -|"a\xe2\x97\x89U+202E\xe2\x97\x89b": 1\n|0|"a\xe2\x97\x89U+202E\xe2\x97\x89b"\n|-'
	'ErpZsUe|backslash-u-migrate|migrate -|q: "\\u0041"\n|0|q: "\\u0041"\n##    Format   3\n|-'
	## Every default-ignorable character is escaped, by its code point with at
	## least four digits. A variation selector after a visible character
	## stays, and so do a subdivision flag's tags.
	'ErEBHU3|escape-ignorable-fmt|fmt -|a: soft\xc2\xadhyphen\n|0|a: "soft\xe2\x97\x89U+00AD\xe2\x97\x89hyphen"\n|-'
	'ErEBHU4|escape-tags-fmt|fmt -|a: ok\xf3\xa0\x81\xa8\xf3\xa0\x81\xa9\n|0|a: "ok\xe2\x97\x89U+E0068\xe2\x97\x89\xe2\x97\x89U+E0069\xe2\x97\x89"\n|-'
	'ErEBHU5|escape-tags-set|set -|string\ta\tok\xf3\xa0\x81\xa8\xf3\xa0\x81\xa9\n|0|a: "ok\xe2\x97\x89U+E0068\xe2\x97\x89\xe2\x97\x89U+E0069\xe2\x97\x89"\n|-'
	'ErEBHU6|escape-flag-kept|fmt -|a: \xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xa5\xf3\xa0\x81\xae\xf3\xa0\x81\xa7\xf3\xa0\x81\xbf\n|0|a: \xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xa5\xf3\xa0\x81\xae\xf3\xa0\x81\xa7\xf3\xa0\x81\xbf\n|-'
	'ErEBHU7|escape-selector-kept|fmt -|a: \xe2\x9d\xa4\xef\xb8\x8f\n|0|a: \xe2\x9d\xa4\xef\xb8\x8f\n|-'
	'ErEBHU8|escape-selector-run|fmt -|a: x\xef\xb8\x8f\xef\xb8\x8f\n|0|a: "x\xef\xb8\x8f\xe2\x97\x89U+FE0F\xe2\x97\x89"\n|-'
	## A path in double quotes with a \t or \n escape was a hint, H004, and
	## reads, loads strict and saves as written. It is E024 now
	## (2026100115323227), so these three no longer hold.
	#'Er1iG7N|path-hint-read|get - a|a: "C:\\temp"\n|0|C:\temp\n|H004 value looks like a Windows path'
	#'Er1iG7O|path-hint-strict|check --strictness=strict -|a: "C:\\temp"\n|0|line 1: Hint: H004\nok (1 diagnostic(s))\n|-'
	#'Er1iG7P|path-hint-set|set - --set b=1|a: "C:\\temp"\n|0|a: "C:\\temp"\n\nb: 1\n|-'
	## It was refused like E023: kept as written, read as nothing, and the
	## lines under it still load. A tab or line break a setter wrote into such
	## a value went out as a \u escape, and SetLiteral text holding one was
	## refused. E024 is retired since 2026100207032800: the path is text, and
	## a tab goes out as the TAB escape.
	#'ErUmRRd|path-escape-read|get - a|a: "C:\\temp"\n|3|\n|E024 value starts like a Windows path'
	#'ErUmRRe|path-escape-strict|check -|a: "C:\\temp"\n|6|line 1: Error: E024\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'ErUmRRf|path-escape-block|get - a.b|a: "C:\\temp"\n\tb: 1\n|0|1\n|-'
	#'ErUmRRg|path-escape-set|set -|string\ta\tC:\\temp\n|0|a: "C:\\u0009emp"\n|-'
	#'ErUmRRh|path-escape-literal|set %F2%|literal\tx\t"C:\\temp"\n|1||^op line 1: cannot write x'
	#'ErUmRRi|path-escape-migrate-lost|migrate -|q: "\\\\\\\\srv\\new"\n|7|-|line break in a Windows path'
	#'Er1adAs|escape-unknown-migrate|migrate -|q: "C:\\work"\n|0|q: "C:\\\\work"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	'ErpZsUf|path-text-read|get - a|a: "C:\\temp"\n|0|C:\\temp\n|-'
	## The ops script kept 2.x's \n, \t and \\ in a string value until
	## 2026100717500002, so a Windows path lost its \t there alone. Op values
	## read the file's escape names now, and a backslash is text.
	#'ErpZsUg|path-tab-set|set -|string\ta\tC:\\temp\n|0|a: "C:\xe2\x97\x89TAB\xe2\x97\x89emp"\n|-'
	'ErpZsUh|path-text-literal|set -|literal\tx\t"C:\\temp"\n|0|x: "C:\\temp"\n|-'
	'ErpZsUi|backslash-migrate-same|migrate -|q: "C:\\work"\n|0|q: "C:\\work"\n##    Format   3\n|-'
	## 2026100717500002: an op value reads the file's escape names, a tab or a
	## line break included, and a backslash pair is text, the same as in --set.
	'Es8bB4z|ops-backslash-text|set -|string\ta\tC:\\temp\\new\n|0|a: "C:\\temp\\new"\n|-'
	'Es8bB50|ops-escape-names|set -|string\ta\tx\xe2\x97\x89TAB\xe2\x97\x89y\xe2\x97\x89NEWLINE\xe2\x97\x89z\n|0|a: "x\xe2\x97\x89TAB\xe2\x97\x89y\xe2\x97\x89NEWLINE\xe2\x97\x89z"\n|-'
	'Es8bB51|ops-raw-line-break|set -|raw\tr\tsh\techo hi\xe2\x97\x89NEWLINE\xe2\x97\x89echo bye\n|0|r:\n\t\x60\x60\x60sh\n\techo hi\n\techo bye\n\t\x60\x60\x60\n|-'
	'Es8bB52|ops-array-escapes|set -|string-array\ta\tC:\\new\tx\xe2\x97\x89TAB\xe2\x97\x89y\n|0|a: ["C:\\new", "x\xe2\x97\x89TAB\xe2\x97\x89y"]\n|-'
	'Es8bB53|ops-comment-escape|set -|comment\ta\tC:\\new \xe2\x97\x89ESCAPE_CHAR\xe2\x97\x89\nstring\ta\tv\n|0|# C:\\new \xe2\x97\x89\na: v\n|-'
	'Es8bB57|ops-default-escape|set -|string-default\ta\tx\xe2\x97\x89TAB\xe2\x97\x89\n|0|a: "x\xe2\x97\x89TAB\xe2\x97\x89"\n|-'
	## The value is read in quotes, so a quote in it stays text whichever kind.
	'Es8bB56|ops-escape-quotes|set -|string\ta\tsay "hi" it\x27s\xe2\x97\x89TAB\xe2\x97\x89ok\nstring\tb\tsay "hi"\xe2\x97\x89TAB\xe2\x97\x89\n|0|a: "say \xe2\x97\x89DOUBLE_QUOTE\xe2\x97\x89hi\xe2\x97\x89DOUBLE_QUOTE\xe2\x97\x89 it\x27s\xe2\x97\x89TAB\xe2\x97\x89ok"\n\nb: \x27say "hi"\xe2\x97\x89TAB\xe2\x97\x89\x27\n|-'
	'Es8bB54|ops-escape-unknown|set -|string\ta\tx\xe2\x97\x89NOPE\xe2\x97\x89\n|1||^op line 1: cannot write a: .*NOPE'
	## 2026100307163914: a field line kept for its value alone reads NotFound with
	## nothing under it and Empty once a line under it loads, and explain says so.
	'Erlr8eZ|kept-value-e019-empty|get - a|a: [1\n\tb: 1\n|2|\n|E019'
	'Erlr8gU|kept-value-e023-empty|get - a|a: "x\xe2\x97\x89Q\xe2\x97\x89"\n\tb: 1\n|2|\n|E023'
	## E024 is retired; a bare value with a space is the common case now.
	#Erlr8iQ|kept-value-e024-empty|get - a|a: "C:\\temp"\n\tb: 1\n|2|\n|E024'
	## A bare value may hold spaces since 20261006, so this line binds now.
	#ErpZsUj|kept-value-e025-empty|get - a|a: My App\n\tb: 1\n|2|\n|E025'
	'ErvnzpR|kept-value-e025-colon-empty|get - a|a: host: a.com port: 80\n\tb: 1\n|2|\n|E025'
	'Erlr21T|explain-e019-read|explain E019|-|0|\nE019  error       a bracket array that is not well formed\n  An array is one line, ports: [80, 443], and [] is the empty array. Text\n  after the closing \x27]\x27, a bare \x27[\x27 or \x27]\x27 inside, an empty element, or no\n  closing \x27]\x27 on the line is malformed. Quote the value if it is text:\n  log: "[INFO] started". A list item that is an array is E019 too, since\n  arrays do not nest. The line is kept verbatim: it binds nothing and\n  nothing counts as lost. The lines under it still load, under the field\n  with no value, so a read on the field is Empty when one of them loads and\n  NotFound when none does.\n\n|-'
	'ErqYSbN|explain-e013|explain E013|-|0|\nE013  error       a line starting with \x27*\x27, the old list item marker\n  A list item is written \x27- value\x27 now. The line is kept as written and\n  binds nothing, and the other items still load. What is written under it\n  goes with it.\n\n|-'
	'ErqYSbO|explain-e026|explain E026|-|0|\nE026  error       a bare comma with a space or the end after it\n  ports: 80, 443 is an error. Write the array in brackets, ports: [80, 443],\n  or quote text that has a comma. A comma with text right after it is text,\n  so opts: rw,noatime is one string. The line is kept verbatim and binds\n  nothing. The lines under it still load, under the field with no value. A\n  list item with a bare comma, - a, b, is kept the same way, and the other\n  items still load.\n\n|-'
	'ErrQs1Z|explain-e028|explain E028|-|0|\nE028  error       an array on a field with lines under it\n  A field with fields under it takes one plain value or none, so\n  route: [GET, POST] with lines under it is an error. Give the field one\n  value and put the list in a field under it: methods: [GET, POST]. The line\n  is kept verbatim, and the lines under it load under the field with no\n  value.\n\n|-'
	'ErrQs1a|explain-e010-retired|explain E010|-|0|\nE010  retired     error, replaced by E026\n  Loads no longer report E010. \x27shcl explain E026\x27 has the rule now.\n\n|-'
	'ErqYSbP|explain-e027|explain E027|-|0|\nE027  error       a list item like - name: or - name: value\n  A colon with a space or the end after it is how YAML starts an object in\n  a list, and SHCL writes one as an instance. A colon with text after it is\n  fine, as in - localhost:8080. Quote the item if it is text: - "name: a".\n  The line is kept as written, and the other items still load.\n\n|-'
	'Ervo6BP|explain-e025|explain E025|-|0|\nE025  error       a tab, a quote, a bracket or a loose colon in bare text\n  A bare value or list item may hold spaces, kept as typed. A tab or other\n  whitespace, a quote, a bracket, or a colon with a space or the end after\n  it is an error: host: a.com port: 80 is two fields on one line. Put each\n  field on its own line, or quote the value: name: "O\x27Brien". An array\n  element or a selector body takes no whitespace, and a selector body no\n  colon, comma or paren either. Whitespace at either end is trimmed first.\n  The line is kept verbatim and binds nothing. In a value, the lines under\n  it still load, under the field with no value.\n\n|-'
	## 2026-10-05: explain E023 prints the mark itself, not the text U+25C9.
	#'Erlr23g|explain-e023-read|explain E023|-|0|\nE023  error       a bad escape\n  An escape is a name from the escape list between two U+25C9 marks, such as\n  TAB, NEWLINE or U+200B, and a real U+25C9 is the name ESCAPE_CHAR. Anything\n  else between two marks is an error, and so is a mark with no partner. A\n  backslash is plain text. The line is kept verbatim: it binds nothing and a\n  read on it is NotFound. When only the value is wrong, the lines under it\n  still load, under the field with no value, and a read on the field is Empty\n  once one of them loads. When the name is, a raw block the line opens is kept\n  with it.\n\n|-'
	'Ers2pOq|explain-e023-mark|explain E023|-|0|\nE023  error       a bad escape\n  An escape is a name from the escape list between two \xe2\x97\x89 marks, such as\n  \xe2\x97\x89TAB\xe2\x97\x89, \xe2\x97\x89NEWLINE\xe2\x97\x89 or \xe2\x97\x89U+200B\xe2\x97\x89, and a real \xe2\x97\x89 is written \xe2\x97\x89ESCAPE_CHAR\xe2\x97\x89.\n  Anything else between two marks is an error, and so is a mark with no\n  partner. A backslash is plain text. The line is kept verbatim: it binds\n  nothing and a read on it is NotFound. When only the value is wrong, the\n  lines under it still load, under the field with no value, and a read on the\n  field is Empty once one of them loads. When the name is, a raw block the\n  line opens is kept with it.\n\n|-'
	## E024 is retired (2026100207032800), so explain says so.
	#'Erlr25Z|explain-e024-read|explain E024|-|0|\nE024  error       a Windows path in double quotes with a \\t or \\n escape\n  "C:\\temp" would read as C:, a tab, then emp, which a path almost never\n  means. The line is kept verbatim like E023: it binds nothing, and the\n  lines under it still load. A read on the field is Empty when one of them\n  loads and NotFound when none does. Use single quotes or no quotes, or\n  double each backslash.\n\n|-'
	'ErpaTy1|explain-e024-retired|explain E024|-|0|\nE024  retired     error, with no replacement\n  Loads no longer report E024, and no other code took its rule.\n\n|-'
	'ErpaTy2|explain-h003-retired|explain H003|-|0|\nH003  retired     hint, with no replacement\n  Loads no longer report H003, and no other code took its rule.\n\n|-'
	## 20260909 item 4: a 3.0 file writes a backslash value the same way a 2.x
	## one does, so migrating on a guess changed a correct file at exit 0. The
	## file has to say which rules wrote it, or the caller has to.
	## Durations and sizes print whole milliseconds and bytes. --unit gives a bare
	## number its unit, --decimal makes KB to TB powers of 1000, and each is
	## refused where it cannot mean anything.
	'Er35Y6E|duration-read|get --duration - t|t: "1h 30m"\n|0|5400000\n|-'
	'Er35Y6F|duration-name-unit|get --duration - wait-ms|wait-ms: 250\n|0|250\n|-'
	'Er35Y6G|duration-bare|get --duration - t|t: 90\n|4|0\n|not a valid duration'
	'Er35Y6H|duration-unit|get --duration --unit=s - t|t: 90\n|0|90000\n|-'
	'Er35Y6I|size-decimal|get --size --decimal - c|c: 2MB\n|0|2000000\n|-'
	'Er35Y6J|size-unit-space|get --size --unit KiB - c|c: 64\n|0|65536\n|-'
	'Er35Y6K|unit-needs-type|get --unit=s - t|t: 1\n|1||^--unit needs --duration or --size'
	'Er35Y6L|decimal-needs-size|get --duration --decimal - t|t: 1s\n|1||^--decimal needs --size'
	'Er35Y6M|unit-bad|get --size --unit=Mb - c|c: 1\n|1||^bad --unit value for --size: Mb'
	'Er35Y6N|unit-clash|get --duration --unit=s --unit=m - t|t: 1\n|1||^--unit=s cannot be combined with --unit=m'
	'Er35Y6O|duration-no-array|get --duration --array - t|t: 1s\n|1||^--duration has no --array form'
	'Er35Y6P|unit-hint|check -|t-ms: 5s\n|0|line 1: Hint: H005\nok (1 diagnostic(s))\n|H005 value is in s and the name says ms'
	## 20260928 idea 4: a hint found after the parse's pass, here a late fold,
	## was listed after every other diagnostic. The prose is the same in all
	## four, so stderr is pinned whole.
	"ErJK4ni|diag-line-order|check -|a: [1, 2]\nb: 0\na:\n\t- 1\n\t- 2\nc: [x\n|6|line 3: Hint: H002\nline 6: Error: E019\nfailed: 2 diagnostic(s), 1 error(s)\n|=line 3: Hint: H002 merged with 'a' at line 1 (same name and value combine)\nline 6: Error: E019 malformed array, no closing ']' on the line; quote the value if it is text\n(run 'shcl explain CODE' for the rule behind a code)\n"
	## A Schema line names the schema check uses when --schema is not given,
	## read from the config file's directory. A URL is left to editors.
	'Er2thhx|schema-line-check|check %SP%|-|6|line 2: Error: V003\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'Er2thhy|schema-line-url|check %SPU%|-|0|ok (0 diagnostic(s))\n|does not fetch'
	'Er2thhz|schema-line-gone|check %SPG%|-|8||gone\.schema\.shcl'
	'Er2thi0|schema-line-overridden|check --schema=%SPS% %SPU%|-|6|line 2: Error: V003\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	## An indented line counts, or fmt would turn the check off. Only a regular
	## file is read, and a backslash in the file name is part of the name.
	'ErCkXme|schema-line-indented|check %SPI%|-|6|line 4: Error: V003\nline 1: Error: V001\nfailed: 2 diagnostic(s), 2 error(s)\n|-'
	'ErCkXo8|schema-line-device|check %SPZ%|-|8||not a regular file'
	'ErCkXpb|schema-line-fifo|check %SPF%|-|8||not a regular file'
	'ErCkXr4|schema-line-nul|check %SPN%|-|8||-'
	'ErCkXsU|schema-line-backslash-name|check %SPB%|-|6|line 2: Error: V003\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'ErCkoh2|schema-line-share|check %SPW%|-|8||network or device path'
	## 20260930 item 3: a regular file can still read without end.
	'ErTZaL2|schema-line-pagemap|check %SPM%|@memcap|8||too large for a schema'
	'ErTZaL3|schema-line-at-cap|check %SPC%|-|6|line 2: Error: V003\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'ErTZaL4|schema-line-over-cap|check %SPO%|-|8||too large for a schema'
	## 20261003 item 3: the walk read raw blocks the 2.x way.
	'ErfuRh7|schema-line-raw-after-backslash|check %SPR%|-|6|line 5: Error: V003\nline 1: Error: V001\nfailed: 2 diagnostic(s), 2 error(s)\n|-'
	## 2026-10-05: migrate leaves a 2.x backslash as written, and it reads as
	## text under these rules, so this file reads one way and nothing is left
	## to refuse over.
	#'Eq4Rkv2|migrate-ambiguous-refused|migrate %BS%|-|7|-|does not say which it was written for'
	#"Eq4Rkv3|migrate-ambiguous-kept|migrate %BS%|-|7|p: 'C:\\\\temp'\n|-"
	#'Eq4Rkv4|migrate-ambiguous-write-refused|migrate --write %BS%|-|7|-|refusing to rewrite'
	'Ers2pOu|migrate-backslash-as-text|migrate %BS%|-|0|p: \x27C:\\temp\x27\n##    Format   3\n|!.'
	'Ers2pOv|migrate-backslash-write|migrate --write %BS%|-|0|-|migrated, 0 line\(s\) rewritten'
	'Ers2pOw|migrate-backslash-pairs|migrate -|a: "C:\\\\work"\nb: "say \\"hi\\""\nc: C:\\new\n|0|a: "C:\\\\work"\nb: \x27say \\"hi\\"\x27\nc: C:\\new\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## The 2.x tab went in as it was, since "C:\temp" was E024 (2026100115323227).
	## It is the TAB escape since 2026100207032800.
	#'Eq4Rkv5|migrate-from-2x|migrate --from-2x %BS%|-|0|p: "C:\\temp"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## 2026-10-05: the backslash stays, and reads as text.
	#'ErUn2Bt|migrate-from-2x-tab|migrate --from-2x %BS%|-|0|p: "C:\xe2\x97\x89TAB\xe2\x97\x89emp"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	'Ers2pOx|migrate-from-2x-backslash|migrate --from-2x %BS%|-|0|p: \x27C:\\temp\x27\n##    Format   3\n|-'
	## A file that names its format has nothing to migrate, which is what stops
	## the second run from rewriting the first run's output.
	'Eq4Rkv6|migrate-stamped-noop|migrate %V3%|-|0|p: 1\n##    Format   3\n|nothing to migrate'
	"ErCkXtw|migrate-indented-stamp-noop|migrate %V3I%|-|0|p: 'C:\\\\temp'\nsrv:\n\t##    Format   3\n\tx: 1\n|nothing to migrate"
	## 20260918 item 1: the version scan read raw bodies the rewrite skips.
	'EqGUXeC|migrate-format-in-raw-old|migrate %RF2%|-|7|-|does not say which it was written for'
	## The value beside it is no longer read two ways (2026-10-05), so this
	## pins the scan by the stamp migrate adds; ErfuRj5 holds the refusal.
	#'EqGUXeD|migrate-format-in-raw-new|migrate %RF3%|-|7|-|does not say which it was written for'
	'Ers2pOy|migrate-format-in-raw-stamps|migrate %RF3%|-|0|p: \x27C:\\temp\x27\nnote:\n\t\x60\x60\x60\n##    Format   3\n\t\x60\x60\x60\n##    Format   3\n|!nothing to migrate'
	'ErfuRj5|migrate-format-in-raw-after-backslash|migrate %RFQ%|-|7|-|does not say which it was written for'
	## 20260918 item 2: C looked for the version line before taking off a BOM.
	'EqGUXeE|migrate-bom-stamped|migrate %V3B%|-|0|-|nothing to migrate'
	'EqGUXeF|migrate-bom-stamped-from-2x|migrate --from-2x %V3B%|-|0|-|nothing to migrate'
	## Found by the fuzz in the 20260918 fix round: the first Format line decided,
	## so a file naming an older format was stamped again on every run.
	'EqGWgK0|migrate-two-stamps|migrate %V03%|-|0|-|nothing to migrate'
	## 20260918b item 30: Python raised on a Format line past 4300 digits.
	'EqLxvX0|migrate-huge-format|migrate %FB%|-|0|-|nothing to migrate'
	## 20260909 item 10: 2.x bound the bracket array and nothing binds it now.
	## Leaving the line is the decision; exiting 0 was the defect, since a
	## scripted migration could not tell "migrated" from "gave up".
	'Eq4Rkv7|migrate-lost-binding|migrate %BA%|-|7|-|bound a value under 2.x that nothing binds now'
	'Eq4Rkv8|migrate-lost-write-refused|migrate --write %BW%|-|7|-|refusing to rewrite'
	'Eq4Rkv9|migrate-lost-write-lossy|migrate --write --lossy %BW%|-|0|-|bound a value under 2.x'
	## 2026100410055748: the count was values, so this said 3 line(s).
	## A line break in a Windows path has a spelling since 2026100207032800, so
	## only the bracket line is lost and the count can no longer tell lines
	## from values.
	#'Erkljp5|migrate-lost-counts-lines|migrate --from-2x %MV%|-|7|-|: 2 line\(s\) bound a value under 2\.x'
	'ErpaTy3|migrate-lost-one-line|migrate --from-2x %MV%|-|7|-|: 1 line\(s\) bound a value under 2\.x'
	## 2026100207032800: 2.x matched a selector with a comma against an array
	## value, and let a comma list head lines of its own. Neither has a
	## spelling now, so both are lost, not rewritten at exit 0.
	'Erwf3oC|migrate-lost-array-selector|migrate --from-2x -|a[x, y].b: 1\n|7|-|: 1 line\(s\) bound a value under 2\.x'
	'Erwf3oD|migrate-lost-list-over-lines|migrate --from-2x -|a: 1, 2\n\tb: 1\n|7|-|: 1 line\(s\) bound a value under 2\.x'
	## 2026100610073400: a selector goes in parens. One in brackets is E029, so
	## the line is rewritten without --from-2x too.
	'Erxvsaw|migrate-selector-parens|migrate -|a[x].k: 1\nb[New York].k: 2\n|0|a(x).k: 1\nb("New York").k: 2\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## 20260909 item 41: telling a file that needs migrating from one that does
	## not took a diff of the output, and --write said nothing either way.
	'Eq4wD3Y|migrate-check-names|migrate --check %W%|-|6||w\.shcl:1: migrate would rewrite this line'
	## 20260918b item 54: fmt --check, migrate --check's sibling.
	'EqMO8f3|fmt-check-noncanonical|fmt --check %NC%|-|6||noncanon\.shcl: not canonical; fmt --write would rewrite it'
	'EqMO8f4|fmt-check-canonical|fmt --check %F%|-|0||!.'
	'EqMO8f5|fmt-check-write|fmt --check --write %NC%|-|1|-|--check cannot be combined with --write'
	## 20260920 item 1: --check promised a rewrite --write then refused. The
	## sugar file's --write row two dozen lines up is the other half of the pair.
	## The sugar file loses nothing now (2026100115403384), so the pair moved
	## to a file whose load drops a line.
	#'EqQSqyX|fmt-check-refused|fmt --check %W%|-|7||fmt --write would refuse: it would delete 1 line'
	'ErUn2Bu|fmt-check-refused-dropped|fmt --check %KL%|-|7||fmt --write would refuse: it would delete 1 line'
	'EqQSqyY|migrate-check-refused|migrate --check %ML%|-|7||migrate --write would refuse: the migrated text drops 1 line'
	'EqQSqyZ|migrate-write-refused-lost|migrate --write %ML%|-|7|-|refusing to rewrite: the migrated text drops 1 line'
	## 2026100717500003: printed, the same file exited 0. The text still
	## prints, since it keeps every line; the exit is what --write gives.
	## --lossy works without --write on migrate and set now, not on fmt.
	'Es8aXo2|migrate-print-refused-lost|migrate %ML%|-|7|list: ["a\\,b", c]\nwin:\n\t\tm: 4\n\tstray: 1\n##    Format   3\n##    Migrated from SHCL 2.x.\n|migrate --write would refuse: the migrated text drops 1 line'
	'Es8aXo3|migrate-print-lossy|migrate --lossy %ML%|-|0|-|!would refuse'
	'Es8aXo4|migrate-check-lossy|migrate --check --lossy %ML%|-|6||mlost\.shcl:1: migrate would rewrite this line'
	'Es8aXo5|fmt-lossy-without-write|fmt --lossy %F%|-|1||only meaningful with --write'
	## 20260918b item 55: a created file says so, since nothing else does.
	'EqMO8f6|create-says|set --write --no-banner %C% --set=a=1|-|0|-|created\.shcl: created|a: 1\n'
	## The sugar file's write goes through now (2026100115403384).
	#'EqMO8f7|write-existing-quiet|fmt --write %W%|-|7|-|!created'
	'ErUn2Bv|write-existing-quiet-kept|fmt --write %W%|-|0|-|!created'
	'Eq4wD3Z|migrate-check-clean|migrate --check %F%|-|0||!.'
	'Eq4wD3a|migrate-check-stamped|migrate --check %V3%|-|0||nothing to migrate'
	## 2026-10-05: nothing in the backslash file is rewritten now.
	#'Eq4wD3b|migrate-check-ambiguous|migrate --check %BS%|-|7||does not say which it was written for'
	#'Eq4wD3c|migrate-check-from-2x|migrate --check --from-2x %BS%|-|6||bs\.shcl:1: migrate would rewrite'
	'Ers2pOz|migrate-check-backslash|migrate --check --from-2x %BS%|-|0||!.'
	'Eq4wD3d|migrate-check-write|migrate --check --write %W%|-|1|-|--check cannot be combined with --write'
	'Eq4wD3e|migrate-write-says|migrate --write %W%|-|0||migrated, 1 line\(s\) rewritten'
	## The Format and Migrated lines end the way most of the file's lines do.
	'ErTecqE|migrate-write-eol-crlf|migrate --write %MC%|-|0||-|base: Boston\r\n\tlat: 42\r\n##    Format   3\r\n##    Migrated from SHCL 2.x.\r\n'
	'ErTecqF|migrate-eol-tie-lf|migrate %MT%|-|0|base: Boston\r\n\tlat: 42\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## 20261003 item 6: an unterminated last line compared unequal to itself
	## once the stamp ended it, so --check said 6 and --write kept a copy.
	'ErkalBd|migrate-check-no-final-crlf|migrate --check %MN%|-|0||!.'
	'ErkalBe|migrate-write-no-final-crlf|migrate --write %MNW%|-|0||migrated, 0 line\(s\) rewritten$|a: 1\r\nb: 2\r\nc: 3\r\n##    Format   3\r\n'
	'ErkalBf|migrate-check-lone-cr-lf|migrate --check %MX%|-|0||!.'
	'ErkalBg|migrate-write-lone-cr-lf|migrate --write %MXW%|-|0||migrated, 0 line\(s\) rewritten$|a: 1\nb: 2\r\n##    Format   3\n'
	'ErkalBh|migrate-check-lone-cr-crlf|migrate --check %MY%|-|0||!.'
	## 2026100316275800: a raw block that never closes left the file
	## unstamped at exit 0, so the next run could not tell it was migrated.
	'ErkalBb|migrate-check-raw-open|migrate --check --from-2x %MR%|-|7||nowhere to put the Format line'
	"ErkalBc|migrate-write-raw-open|migrate --write --from-2x %MRW%|-|7|-|nowhere to put the Format line|a: 'x\\\\ty'\nb: ~~~\n\tline\n"
	## The kept original, named. The save cases below check the file itself,
	## but they are POSIX fixtures, so this is the one windows runs.
	'Er5qICu|migrate-write-keeps|migrate --write %W%|-|0||migrated, 1 line\(s\) rewritten; the original is .*w_backup_20261004-001500_format-v2\.shcl$'
	## 2026100313461649: upgrade makes over a file that does not load clean,
	## keeps the original under the timestamped name, and leaves a clean one
	## alone. Text that reads two ways is refused at 7 with nothing written.
	'Es2Rg1E|upgrade-print|upgrade %U2%|-|0|tags: [a, b]\nport: 80\n\n##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://github.com/yottacore/shcl\n##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n##\n|E026'
	'Es2Rg1F|upgrade-write|upgrade --write %U2W%|-|0|-|upgraded; the original is .*created_backup_20261004-001500_format-v2\.shcl$|tags: [a, b]\nport: 80\n\n##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://github.com/yottacore/shcl\n##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n##\n'
	'Es2Rg1G|upgrade-write-ambiguous|upgrade --write %UAW%|-|7|-|read one way under 2\.x and another.*--from-2x|a: x,y\nb: "q\n'
	'Es2Rg1H|upgrade-clean|upgrade --write %NC%|-|0|-|nothing to upgrade'
	'Es2Rg1I|upgrade-usage-line|upgrade|-|1||^usage: shcl upgrade \[options\] FILE \(see --help\)$'
	'Es2Rg1J|upgrade-stdin-write|upgrade --write -|-|1||cannot rewrite stdin'
	'Es2Rg1K|upgrade-check-refused|upgrade --check %UA%|-|1||--check'
	## With --from-2x a clean file that reads differently once migrated is
	## made over too; without it, it is left alone.
	'Es2a1Ju|upgrade-from-2x-clean|upgrade --from-2x %UC%|-|0|p: [a, b]\n\n##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://github.com/yottacore/shcl\n##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n##\n|!.'
	'Es2a1Jv|upgrade-clean-unsaid|upgrade %UC%|-|0|p: a,b\n|nothing to upgrade'
	## 20260918 item 18: the usage line said [--write|-w] where the help line
	## says [options].
	'EqGfz44|migrate-usage-line|migrate|-|1||^usage: shcl migrate \[options\] FILE \(see --help\)$'
	## 20260904 item 47: the temp beside a long-named file ran past the name limit.
	'EpHEEKW|long-name-write|fmt --write %L%|-|0||-'
	## 20260909 item 16.
	'Epyq1rk|wide-name-write|fmt --write %LW%|-|0||-'
	'EpFkZyB|sugar-migrate-write-stdin|migrate --write -|-|1|-|cannot rewrite stdin'
	## 20260918b item 34: the same refusal on the other two, which the help's
	## "Also refused" list now names.
	'EqM10jq|write-stdin-fmt|fmt --write -|-|1|-|cannot rewrite stdin'
	'EqM10jr|write-stdin-set|set --write -|-|1|-|cannot rewrite stdin'
	## 20260802 item 11: --write with a lower layer wrote the merge into FILE, so
	## the layer's lines stayed there for good. The file is left as it was.
	'Er1zoZF|write-layer-fmt|fmt --write --layer=%F% %K%|-|1||^--write cannot be combined with --layer \(see --help\)$|# note\nName:   "x"   # c\nblock:\n    a: 1\n'
	'Er1zoZG|write-layer-set|set --write --layer=%F% --set=b=2 %K%|-|1||^--write cannot be combined with --layer \(see --help\)$|# note\nName:   "x"   # c\nblock:\n    a: 1\n'
	'EpFkZyC|tokens-line|tokens %F%|-|0|1:0 name=0-1 sep=1 value=3-4 elem=3-4\n|-'
	'EpFkZyD|tokens-fault|tokens %B%|-|0|1:0 name=0-1 sep=1 value=3-4 elem=3-4\n2:2 name=0-3\n3:0 name=0-3\n|-'
	## 20260923 item 20: the help and man page say each line is read on its own,
	## so a raw body line comes out as a field line.
	## 20260923 item 12: a `*` with only a blank after it is an empty element
	## to the parser (E009), and tokens called it a name fault.
	'Er84S7X|tokens-star-trailing-blank|tokens -|a:\n\t- \n\t-\t\n\t-\n|0|1:0 name=0-1 sep=1 value=2-2 elem=2-2\n2:1 item value=1-1 elem=1-1\n3:1 item value=1-1 elem=1-1\n4:1 name=0-1\n|-'
	'EqjsQiv|tokens-raw-body|tokens %R%|-|0|1:0 name=0-1 sep=1 value=2-2 elem=2-2\n2:1 fence value=0-3 elem=0-3\n3:1 name=0-8\n4:1 name=0-8\n5:1 fence value=0-3 elem=0-3\n|-'
	## 20260830b item 18: a read below strict returned the value and said nothing
	## about a line the load had dropped, so a damaged file read clean at exit 0.
	'EoXBb4q|get-diags|get %B% a|-|0|1\n|E015 missing colon'
	'EoXBb4r|count-diags|count %B% a|-|0|1\n|E015 missing colon'
	'EoXBb4s|instances-diags|instances %B% a|-|0|1\n|E015 missing colon'
	## 20260920b item 26: a value holding a line break printed across two lines,
	## so `instances` gave four lines where `count` said two. Only such a value
	## is escaped; a plain one with a dot in it comes out as written.
	## The escaped form was 2.x's `\n` until 2026100717500006. It is the
	## writer's now, as `init` writes it, so the rows that pinned `\n` give way
	## to the ones after them.
	#'EqT42DB|instances-one-per-line|instances %NV% srv|-|0|"a\\nb"\n"c\\nd"\n|-'
	'Es8bB58|instances-one-per-line-mark|instances %NV% srv|-|0|"a\xe2\x97\x89NEWLINE\xe2\x97\x89b"\n"c\xe2\x97\x89NEWLINE\xe2\x97\x89d"\n|-'
	'EqT42DC|instances-plain-unescaped|instances %NV% plain|-|0|x.y\n|-'
	## 20260923 item 4: the same for get's array and slot listings, one line per
	## element. A plain scalar read is the whole output, so it stays as it is.
	#'EqnwIkU|get-array-one-per-line|get --array %NV% arr|-|0|"a\\nb"\nc\n|-'
	#'EqnwIkV|get-slots-one-per-line|get --array --slots %NV% arr|-|0|Good\t"a\\nb"\nGood\tc\n|-'
	#'EqnwIkW|get-slots-scalar-escaped|get --slots %NV% one|-|0|Good\t"x\\ny"\n|-'
	'Es8bB59|get-array-one-per-line-mark|get --array %NV% arr|-|0|"a\xe2\x97\x89NEWLINE\xe2\x97\x89b"\nc\n|-'
	'Es8bB5A|get-slots-one-per-line-mark|get --array --slots %NV% arr|-|0|Good\t"a\xe2\x97\x89NEWLINE\xe2\x97\x89b"\nGood\tc\n|-'
	'Es8bB5B|get-slots-scalar-mark|get --slots %NV% one|-|0|Good\t"x\xe2\x97\x89NEWLINE\xe2\x97\x89y"\n|-'
	'EqnwIkX|get-scalar-unescaped|get %NV% one|-|0|x\ny\n|-'
	#'EqoRWES|get-array-default-missing|get --array %DB% %NV% nope|-|0|"q\\nr"\n|-'
	#'EqoRWET|get-array-default-slots|get --array --int %DB% %NV% arr|-|0|"q\\nr"\n"q\\nr"\n|-'
	'Es8bB5C|get-array-default-missing-mark|get --array %DB% %NV% nope|-|0|"q\xe2\x97\x89NEWLINE\xe2\x97\x89r"\n|-'
	'Es8bB5D|get-array-default-slots-mark|get --array --int %DB% %NV% arr|-|0|"q\xe2\x97\x89NEWLINE\xe2\x97\x89r"\n"q\xe2\x97\x89NEWLINE\xe2\x97\x89r"\n|-'
	## A backslash pair is text, so it is printed as written beside a real line
	## break, and a lone carriage return takes its own name.
	'Es8bB5E|get-array-backslash-text|get --array - x|x: ["a\xe2\x97\x89NEWLINE\xe2\x97\x89b", \x27a\\nb\x27]\n|0|"a\xe2\x97\x89NEWLINE\xe2\x97\x89b"\na\\nb\n|-'
	'Es8bB5F|instances-lone-cr|instances - x|x: "a\xe2\x97\x89CR\xe2\x97\x89b"\n|0|"a\xe2\x97\x89CR\xe2\x97\x89b"\n|-'
	'EqoRWEU|get-scalar-default-missing|get %DB% %NV% nope|-|0|q\nr\n|-'
	## 20260830b item 22: usage and I/O shared exit 1, so a script could not
	## tell "the command line is wrong" from "that file is not there".
	'EoXIc2a|io-missing-file|get %M% a|-|8|-|-'
	## 20260923 item 16: the UI guide's form is FILE: and the system's own
	## message, "No such file" here or "The system cannot find" on windows. Go
	## named the call and the path again, Python printed [Errno 2].
	'Er84wbv|io-missing-file-form|get %M% a|-|8|-|^[^ ]*not-there\.shcl: [NnT][a-z]'
	'EoXIc2b|io-missing-layer|fmt --layer=%M% %F%|-|8|-|-'
	'EoXIc2c|io-missing-check|check %M%|-|8|-|-'
	'EoXIc2d|io-missing-schema|init --schema=%M%|-|8|-|-'
	'EoXIc2e|usage-unknown-option|get --nope %F% a|-|1|-|unknown option'
	'EoXIc2f|usage-bad-write-path|set --set=a(*)=1 %F%|-|1|-|wildcard path cannot be written'
	## 20260830b item 21: removal and the set-if-absent family had no option
	## form, so a one-key edit meant a printf with a literal tab piped into set.
	## The five spellings share one ordered list, so the last one on a path wins.
	'EoXHUqG|remove-option|set --remove=b %F2%|-|0|a: 1\n|-'
	'EoXHUqH|set-default-absent|set --set-default=c=3 %F2%|-|0|a: 1\nb: 2\n\nc: 3\n|-'
	'EoXHUqI|set-default-present|set --set-default=a=9 %F2%|-|0|a: 1\nb: 2\n|-'
	'EoXHUqJ|set-literal-default|set --set-literal-default=p=[1,2] %F2%|-|0|a: 1\nb: 2\n\np: [1, 2]\n|-'
	'EoXHUqK|set-family-order|set --set=a=5 --remove=a %F2%|-|0|b: 2\n|-'
	'EoXHUqL|remove-ephemeral|get --remove=a %F2% a|-|3|-|-'
	'EoXHUqM|remove-write-refused|fmt --write --remove=a %F2%|-|1|-|cannot be combined with --remove'
	'EoXHUqN|remove-empty-path|set --remove= %F2%|-|1|-|bad --remove value'
	##	20260923 idea 2: a path that can never parse was taken as a miss and
	##	exited 0. It is refused now, while a missing path or a wildcard still
	##	removes nothing at exit 0. The ops script's remove and clear-comments
	##	refuse the same way.
	'EqvZOh6|remove-bad-path|set --remove=b( %F2%|-|1||^bad --remove value \(not a usable path\): b\( \(see --help\)$'
	'EqvZOh7|remove-value-in-path|set --remove=a:1 %F2%|-|1||^bad --remove value \(not a usable path\): a:1 \(see --help\)$'
	'EqvZOh8|remove-bad-path-on-get|get --remove=a..b %F2% a|-|1||^bad --remove value \(not a usable path\)'
	'EqvZOh9|remove-missing-ok|set --remove=nope %F2%|-|0|a: 1\nb: 2\n|-'
	'EqvZOhA|remove-wildcard-ok|set --remove=a.* %F2%|-|0|a: 1\nb: 2\n|-'
	'EqvZOhB|ops-remove-bad-path|set %F2%|remove\tb(|1||^op line 1: cannot remove b\(: not a usable path$'
	'EqvZOhC|ops-clear-comments-bad-path|set %F2%|clear-comments\ta..b|1||^op line 1: cannot clear-comments a\.\.b: not a usable path$'
	## 20260830b item 19: a script could read an open section's values but never
	## learn its keys, so the only route was parsing fmt output in shell. A name
	## needing quotes comes back path-ready, or enumerating it buys nothing.
	'EoXDpDN|children-top|children %T%|-|0|db\nweb\n|-'
	'EoXDpDO|children-quoted|children %T% db|-|0|host\n"odd.key"\n|-'
	'EoXDpDP|children-missing|children %T% nope|-|0||-'
	'EoXDpDQ|paths-all|paths %T%|-|0|db\ndb.host\ndb."odd.key"\nweb\nweb.port\n|-'
	## 20260901b item 28: a value with newlines in it stays on one line.
	'EonKleq|diag-value-one-line|check --schema=%SA% %R%|-|6|-|not allowed at .b.: line one.nline two'
	## 20260901b item 24: two layers with a bad line 2 printed the same thing
	## twice, with nothing to say which file each came from.
	'Eon9YY4|layer-diags-named|fmt --layer=%B% %B2%|-|0|-|bad2.shcl line 2: Error: E014'
	## 20260918b item 14: `set` kept its own copy of the fold and missed it.
	'EqLcx3w|layer-diags-named-set|set --set=q=1 --layer=%B% %B2%|-|0|-|bad2.shcl line 2: Error: E014'
	## 2026100511210900: emptying an instance left a list after it that the
	## reload drops, and the write went through at exit 0.
	'Ers2pP0|list-after-empty-refused|set --write %LEW%|empty\tx(v)\n|7|-|would delete 2 line|x: v\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n'
	'Ers2pP1|list-after-empty-lossy|set --write --lossy %LEW%|empty\tx(v)\n|0|-|rewritten in the canonical form|x:\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n'
	'Eon9YY5|single-file-diags-unnamed|fmt %B%|-|0|-|^line 3: Error: E014'
	## 2026-10-05: a line with no colon that is one name is E015 whatever its
	## name, and binds the name it reads as. With a colon, the name rule still
	## holds.
	## A blank in the name is E014 again, kept as written (2026-10-05), so the
	## user name line in these two moved to ErsrQb6 and ErsrQd5.
	#'Ers2pOr|no-colon-bad-name-e015|check -|404\n-x\nuser name\n|6|line 1: Error: E015\nline 2: Error: E015\nline 3: Error: E015\nfailed: 3 diagnostic(s), 3 error(s)\n|-'
	#'Ers2pOs|no-colon-bad-name-repaired|fmt -|404\n-x\nuser name\n|0|"404":\n"-x":\n"user name":\n|-'
	'ErsrQb6|no-colon-bad-name-narrow|check -|404\n-x\nuser name\nsquare-miles 300\n|6|line 1: Error: E015\nline 2: Error: E015\nline 3: Error: E014\nline 4: Error: E014\nfailed: 4 diagnostic(s), 4 error(s)\n|-'
	'ErsrQd5|no-colon-bad-name-narrow-fmt|fmt -|404\n-x\nuser name\nsquare-miles 300\n|0|"404":\n"-x":\nuser name\nsquare-miles 300\n|-'
	'Ers2pOt|colon-bad-name-e014|check -|404: x\n|6|line 1: Error: E014\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	## 20260909 item 34: E014 says where on the line the path went wrong, as
	## a byte column, which the tokenizer computed and the message dropped.
	'Eq8GC80|e014-column|check -|a: 1\n  bad\nab]\n|6|-|^line 3: Error: E014 malformed line skipped: unexpected character after the path, at column 3$'
	'Eq8GC81|e014-column-bytes|check %CB%|-|6|-|^line 2: Error: E014 malformed line skipped: unexpected character after the path, at column 7$'
	## 20260918 item 15: the blank run between the indent and the text counts.
	'EqGawtE|e014-column-cr-lead|check %CR%|-|6|-|E014 .*, at column 5$'
	## 20260901b item 26: a strict failure in a lower layer ends the fold there,
	## and says which layer it was.
	'EonFb9s|layer-strict-names-the-layer|fmt --strictness=strict --layer=%B% %B2%|-|6|-|bad.shcl line 2: Error: E015'
	'EqLcx3x|layer-strict-names-the-layer-set|set --set=q=1 --strictness=strict --layer=%B% %B2%|-|6|-|bad.shcl line 2: Error: E015'
	## 20261003 item 13: every file is read before any is loaded, so a missing
	## layer above a strict failure is 8, not 6. C read and loaded in turn.
	'Erlbzz0|layer-strict-then-missing|paths --strictness=strict --layer=%B% --layer=%M% %F%|-|8|-|not-there\.shcl'
	'Erlc00p|layer-strict-then-missing-set|set --set=q=1 --strictness=strict --layer=%B% --layer=%M% %F%|-|8|-|not-there\.shcl'
	## 20260902 item 44: the failing phase is named, not guessed.
	'Eon514S|write-names-the-phase|set --write --set=a=2 %N%|-|8|-|cannot create temporary file'
	## 20260902 item 41: the schema's own diagnostics were never printed, so the
	## hint that explains a schema fault could not be seen.
	'EomzUym|schema-own-hints|check --schema=%S7% %F%|-|6|-|schema line 4: Hint: H001'
	## 20260902 item 41: extra tab-separated fields were dropped, so a raw whose
	## content held a literal tab lost everything after it at exit 0.
	'EomzUyn|ops-extra-fields-raw|set %F%|raw\tk\t\tbody\twith\ttabs\n|1|-|raw takes 4 tab-separated'
	## 20260909 item 60: one message covered four causes across both halves of
	## the op, so a refusal never said which half to look at.
	'EqBBQ56|ops-raw-bad-info|set %F%|raw\tk\tc#x\tbody\n|1|-|the info string has no spelling that reads back'
	## The body's line break was \n until 2026100717500002; a backslash is text
	## now, so that body has a mid-line CR, which reads back.
	#'EqBBQ57|ops-raw-bad-body|set %F%|raw\tk\tc\tbody\r\\nmore\n|1|-|the block body has no spelling that reads back'
	'Es8bB55|ops-raw-bad-body-mark|set %F%|raw\tk\tc\tbody\r\xe2\x97\x89NEWLINE\xe2\x97\x89more\n|1|-|the block body has no spelling that reads back'
	'EomzUyo|ops-extra-fields-int|set %F%|int\tk\t1\textra\n|1|-|int takes 3 tab-separated'
	'EomzUyp|ops-array-takes-any|set %F%|int-array\tk\t1\t2\t3\n|0|a: 1\n\nk: [1, 2, 3]\n|-'
	## An array setter writes brackets whatever the length (2026100207032800).
	'ErqYWEv|ops-array-one-keeps-brackets|set %F%|int-array\tk\t80\n|0|a: 1\n\nk: [80]\n|-'
	'ErqYWEw|ops-array-none-is-empty-brackets|set %F%|int-array\tk\n|0|a: 1\n\nk: []\n|-'
	## 20260902 item 41: --default and --on-bad=error each overwrote the other's
	## mode, so which one applied depended on which was typed last.
	'EomzUyq|default-vs-onbad|get --int --default=7 --on-bad=error %F% nope|-|1|-|--default cannot be combined with --on-bad=error'
	'EomzUyr|onbad-vs-default|get --int --on-bad=error --default=7 %F% nope|-|1|-|--default cannot be combined with --on-bad=error'
	'EomzUys|default-with-onbad-default|get --int --default=7 --on-bad=default %F% nope|-|0|7\n|-'
	'Eon0wTA|default-alone|get --int --default=7 %F% nope|-|0|7\n|-'
	## 20260920 idea 2, the same disease one step wider: two options asking for
	## different answers resolved last-wins and said nothing, so the answer
	## depended on typing order. Both orders refuse, and a repeat with the same
	## value still goes through.
	'EqSNyFc|type-clash|get --int --raw %F% a|-|1|-|^--int cannot be combined with --raw \(see --help\)$'
	'EqSNyFd|type-clash-other-order|get --raw --int %F% a|-|1|-|^--raw cannot be combined with --int \(see --help\)$'
	'EqSNyFe|type-clash-first-pair-named|get --float --float --bool %F% a|-|1|-|^--float cannot be combined with --bool \(see --help\)$'
	'EqSNyFf|type-repeat-ok|get --int --int %F% a|-|0|1\n|-'
	'EqSNyFg|type-clash-after-cmd-refusal|check --int --raw %F%|-|1|-|^type options are not valid for check \(see --help\)$'
	##	20260923 idea 1: every edit option that shares --set's list gets the
	##	pipeline hint on check, not only the first three.
	'EqvY6JE|check-layer-hint|check --layer %F% %F%|-|1|-|^option --layer not valid for check: .*Pipe instead: shcl fmt --layer \.\.\. FILE '
	'EqvY6JF|check-set-hint|check --set a=1 %F%|-|1|-|^option --set not valid for check: .*Pipe instead: shcl fmt --set '
	'EqvY6JG|check-set-literal-hint|check --set-literal a=1 %F%|-|1|-|^option --set-literal not valid for check: .*Pipe instead: shcl fmt --set-literal '
	'EqvY6JH|check-set-default-hint|check --set-default a=1 %F%|-|1|-|^option --set-default not valid for check: .*Pipe instead: shcl fmt --set-default '
	'EqvY6JI|check-set-literal-default-hint|check --set-literal-default a=1 %F%|-|1|-|^option --set-literal-default not valid for check: .*Pipe instead: shcl fmt --set-literal-default '
	'EqvY6JJ|check-remove-hint|check --remove a %F%|-|1|-|^option --remove not valid for check: .*Pipe instead: shcl fmt --remove '
	'EqSNyFh|strictness-clash|get --int --strictness=1 --strictness=3 %F% a|-|1|-|^--strictness=1 cannot be combined with --strictness=3 \(see --help\)$'
	'EqSNyFi|strictness-same-level-ok|get --int --strictness=1 --strictness=loose %F% a|-|0|1\n|-'
	'EqSNyFj|onbad-clash|get --int --on-bad=error --on-bad=flag %F% nope|-|1|-|^--on-bad=error cannot be combined with --on-bad=flag \(see --help\)$'
	'EqSNyFk|onbad-same-mode-ok|get --int --on-bad=ERROR --on-bad=error %F% nope|-|3|-|no value at that path'
	## 20260716 item 22: the error mode printed a bare BadType, with no value, type
	## or file. 20260830 item 34: C printed a raw body as it stood, so the one
	## line ran over three, and the four CLIs each quoted the value their own way.
	'Er1zoZH|onbad-error-names-value|get --int --on-bad=error - a|a: 12cats\n|4||^cannot read a as int: value "12cats" is not a valid int \(in -\)$'
	'Er1zoZI|bad-int-raw-one-line|get --int %R% b|-|4|0\n|^cannot read b as int: value "line one\\nline two" is not a valid int \(in [^)]*rawval\.shcl\)$'
	'EqSNyFl|default-clash|get --int --default=7 --default=8 %F% nope|-|1|-|^--default=7 cannot be combined with --default=8 \(see --help\)$'
	'EqSNyFm|default-repeat-ok|get --int --default=7 --default=7 %F% nope|-|0|7\n|-'
	'EqSNyFn|schema-clash|check --schema=%S% --schema=%S2% %F%|-|1|-|^--schema=.* cannot be combined with --schema=.* \(see --help\)$'
	'EqSNyFo|layer-repeats|get --int --layer=%F% --layer=%F% %F% a|-|0|1\n|-'
	'EqSNyFp|set-repeats-last-wins|get --int --set=a=1 --set=a=2 %F% a|-|0|2\n|-'
	## 20260902 item 15: a refused edit returned before the load's diagnostics
	## were printed, so a damaged file said nothing about the damage.
	'EoloRK4|refused-set-still-reports|get --set=a(*)=1 %B% a|-|1|-|E015 missing colon'
	'EoloRK5|refused-op-still-reports|set %B%|int\ta(*)\t1\n|1|-|E015 missing colon'
	## 20260902 item 14: Go read a non-UTF-8 ops script as a usage error.
	'EolmgK0|ops-not-utf8|set %F%|\xff\n|8|-|-'
	## 20260902 items 8 and 9: a stdout that could not be written was reported
	## as success by three CLIs, and a stderr that could not be written aborted
	## the reference with nothing on stdout at all.
	'Eolhrw0|full-stdout-fmt|fmt %F%|@fullout|8|-|[Nn]o space left'
	'Eolhrw1|full-stdout-check|check %F%|@fullout|8|-|-'
	'Eolhrw2|full-stdout-get|get %F% a|@fullout|8|-|-'
	'Eolhrw3|full-stdout-set|set --set=a=2 %F%|@fullout|8|-|-'
	'Eolhrw4|full-stderr-keeps-stdout|fmt %B%|@fullerr|0|a: 1\n\tbad:\nb 2\n|-'
	## Found working 20260830b item 18: a merge does not keep diagnostics, so
	## reading them off the merged doc reported the lowest layer and stayed
	## silent about FILE - the one file the caller actually named.
	'EoXB1RA|layer-base-diags|fmt --layer=%F% %B%|-|0|-|E015 missing colon'
	'EoXB1RB|layer-base-diags-set|set --set=q=1 --layer=%F% %B%|-|0|-|E015 missing colon'
	## A created file says what format it is. The block goes at the bottom, the
	## edits above it, and --no-banner leaves it out. A file that is already
	## there is never given one. 20260909 item 56: the blank line above the
	## block, which init's output has and this one used to be missing.
	'EpL8Odc|create-info-block|set --write %C% --set=srv.port=8080|-|0|-|-|srv:\n\tport: 8080\n\n##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://github.com/yottacore/shcl\n##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n##    Legal    SHCL is Copyright \xc2\xa9 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n##\n'
	'EpL8Odd|create-no-banner|set --write --no-banner %C% --set=srv.port=8080|-|0|-|-|srv:\n\tport: 8080\n'
	## 20260909 item 35: set without --write took --no-banner and did nothing with
	## it, where --lossy in the same spot was refused.
	'Eq5lvLs|no-banner-without-write|set --no-banner --set=a=2 %F%|-|1|-|only meaningful with --write'
	## 20260909 item 33: the help put migrate and tokens among the subcommands
	## that take --strictness, --layer and --set. They refuse all three.
	'Eq5lvLt|migrate-no-strictness|migrate --strictness=strict %F%|-|1|-|not valid for migrate'
	'Eq5lvLu|tokens-no-layer|tokens --layer=%F% %F%|-|1|-|not valid for tokens'
	'Eq5lvLv|migrate-no-set|migrate --set=a=2 %F%|-|1|-|not valid for migrate'
	## 20260909 item 6: the create was decided before the wait on stdin, so a
	## file made during the wait was replaced by the edits at exit 0.
	'EpyBxDM|create-appeared|set --write %C%|@appear|8|-|exists|b: 2\n'
	## 20260918b item 16: the same wait on a file that was there. Another edit
	## made meanwhile was reverted at exit 0.
	'EqLeNlw|write-changed-during-wait|set --write %C%|@change|8|-|changed since it was read|a: 1\nb: 2\n'
	## Literal text is read the way a file line is, so a # opens a comment
	## there too and only what comes before it is written.
	'EpUIoZf|literal-hash|set --write --no-banner %C% --set-literal=color=red#ff0000|-|0|-|-|color: red\n'
	## 20260909 item 42: explain. A code is looked up whatever its case, an
	## unknown one is a usage error that says where the list is, and the
	## subcommand takes no options and no second code.
	'Eq9yPCC|explain-code|explain E019|-|0|-|-'
	'Eq9yPCD|explain-lower|explain e019|-|0|-|-'
	'Eq9yPCE|explain-unknown|explain E999|-|1|-|unknown diagnostic code: E999'
	'Eq9yPCF|explain-two|explain E019 E020|-|1|-|usage: shcl explain'
	'Eq9yPCG|explain-no-options|explain --strictness=strict E019|-|1|-|not valid for explain'
	## Review 20261003 idea 1: a retired code was an unknown one, and H004
	## suggested the unrelated E004. It says it was retired and what replaced
	## it, at exit 0 on stdout like any code explain knows. E024, which had
	## replaced it, is retired too since 2026100207032800.
	'Ern4qLa|explain-retired|explain H004|-|0|\nH004  retired     hint, with no replacement\n  Loads no longer report H004, and no other code took its rule.\n\n|='
	'Ern4qOc|explain-retired-lower|explain h004|-|0|\nH004  retired     hint, with no replacement\n  Loads no longer report H004, and no other code took its rule.\n\n|-'
	## 20260909 item 43: a near miss on a command, an option or a code says what
	## was probably meant. A word nothing is near says nothing.
	'Eq9yPCH|suggest-command|frmt %F%|-|1|-|did you mean .fmt.'
	'Eq9yPCI|suggest-option|get --stricness=1 %F% a|-|1|-|did you mean .--strictness.'
	'Eq9yPCJ|suggest-option-space|get --slot %F% a|-|1|-|did you mean .--slots.'
	'Eq9yPCK|suggest-code|explain E19|-|1|-|did you mean .E019.'
	'Eq9yPCL|suggest-none|zzzzzzzz %F%|-|1|-|!did you mean'
	## An unknown option and a bad option value end with the help pointer, like
	## the other usage errors that do not name their own fix.
	'EqBvhE8|help-ptr-unknown-option|get --nope %F% a|-|1|-|^unknown option: --nope \(see --help\)$'
	'EqBvhE9|help-ptr-suggest-option|get --stricness=1 %F% a|-|1|-|did you mean .--strictness..? \(see --help\)$'
	'EqBvhEA|help-ptr-on-bad|get --on-bad=zz %F% a|-|1|-|^bad --on-bad value: zz \(see --help\)$'
	'EqBvhEB|help-ptr-strictness|get --strictness=9 %F% a|-|1|-|^bad --strictness value: 9 \(see --help\)$'
	'EqBvhEC|help-ptr-remove|set --remove= %F2%|-|1|-|^bad --remove value \(want PATH\) \(see --help\)$'
	'EqBvhED|help-ptr-set|set --set==1 %F2%|-|1|-|^bad --set value .*: =1 \(see --help\)$'
	## 20260909 item 44: help narrows to one subcommand, by name or by the flag
	## after it, and refuses a name that is not one.
	'Eq9yPCM|help-subcommand|help get|-|0|-|-'
	'Eq9yPCN|help-subcommand-flag|fmt --help|-|0|-|-'
	'Eq9yPCO|help-subcommand-unknown|help frmt|-|1|-|unknown command: frmt'
	'Eq9yPCP|help-too-many|help get set|-|1|-|usage: shcl help'
	## 20260909 item 48: V005 and V006 named the field alone, so a long report
	## made you open the schema for every range failure. The int row also pins
	## that the element named is the one that broke the bound, not the first;
	## the float row pins that the bound is printed the way the annotation line
	## writes it, so `min: 1.0` reads as 1.
	'EqAaU1B|range-max-names-value|check --schema=%SG% %DG%|-|6|line 1: Error: V006\nline 2: Error: V005\nfailed: 2 diagnostic(s), 2 error(s)\n|V006 value above max 10 at .ns.: 20$'
	'EqAaU1C|range-min-names-bound|check --schema=%SG% %DG%|-|6|-|V005 value below min 1 at .fs.: 0\.5$'
	## 20260802 item 12: the whole command line was scanned for help and version
	## flags, so a value written like one printed the help at exit 0.
	'EqzuLVo|help-flag-as-default|get --default -h %F% nope|-|0|-h\n|-'
	'EqzuLVp|version-flag-as-default|get --default --version %F% nope|-|0|--version\n|-'
	## 20260923 item 17: the word forms ignored whatever came after them. An
	## option a command does not use is a usage error; the flags still work
	## anywhere. The word forms went on 2026-09-28 (item 9 of that review, a
	## decision), so these three no longer apply and the four rows below them
	## take their place.
	# 'Er863PI|version-word-refuses-extra|version --int|-|1||^usage: shcl version '
	# 'Er863Qj|about-word-refuses-extra|about extra|-|1||^usage: shcl about '
	# 'Er863S3|donate-word-refuses-extra|donate --int|-|1||^usage: shcl donate '
	## 20260928 item 9: a word left over from 2.x is an unknown command, and the
	## hint names its flag. help takes one topic and the informational flags.
	"ErCvyWK|version-word-gone|version|-|1||^unknown command: version; did you mean '--version'\\? \\(see --help\\)$"
	"ErCvyXy|about-word-gone|about extra|-|1||^unknown command: about; did you mean '--about'\\?"
	"ErCvyZZ|donate-word-gone|donate --int|-|1||^unknown command: donate; did you mean '--donate'\\?"
	"ErCvye5|help-topic-version-word|help version|-|1||^unknown command: version; did you mean '--version'\\?"
	## 20260802 item 25: `--` ends the options, so a FILE and a PATH that start
	## with a dash are data, and init refuses a FILE.
	'EqzuLVq|double-dash-ends-options|get -- %DD% -h|-|0|7\n|-'
	'EqzuLVr|init-extra-arg|init --schema=%S2% extra|-|1||^init takes no file argument \(see --help\)$'
	## 20260725 item 14: past 64 of either, the C CLI exited 1 with nothing on
	## stdout.
	"EqzuLVs|many-layers|get --int ${manyLayers}%F% a|-|0|1\n|-"
	"EqzuLVt|many-sets|get --int ${manySets}%F% k69|-|0|69\n|-"
	## 20260725 item 17: check --schema numbered a schema fault as a document
	## line. stderr names the schema; stdout keeps the one form.
	'EqzuLVu|check-schema-line-v090|check --schema=%SU% %F%|-|6|line 2: Error: V090\nfailed: 1 diagnostic(s), 1 error(s)\n|^schema line 2: Error: V090 unknown schema key .bogus.$'
	'EqzuLVv|check-schema-line-v091|check --schema=%S3% %F%|-|6|line 5: Error: V091\nfailed: 1 diagnostic(s), 1 error(s)\n|^schema line 5: Error: V091 unknown schema type .nope.$'
	'EqzuLVw|check-schema-line-v092|check --schema=%S8% %F%|-|6|-|^schema line 3: Error: V092 bad schema constraint .default.$'
	'EqzuLVx|check-schema-line-v093|check --schema=%SM% %F%|-|6|-|^schema line 3: Error: V093 bad schema path'
	## 20260716 item 24: an argument that is not UTF-8 panicked the reference at
	## 134 while the ports exited 3. POSIX-only: windows hands a program UTF-16.
	'EqzuLVy|argv-not-utf8|get %F% %XF%|-|1||^invalid argument encoding \(expected UTF-8\)$'
	'EqzuLVz|argv-not-utf8-value|get --default=a%XF% %F% nope|-|1||^invalid argument encoding \(expected UTF-8\)$'
	## 20260830 item 12: Python wrote stdout in the locale's encoding, which
	## raised on a non-ASCII value wherever that was not UTF-8.
	'EqzuLW0|ascii-locale-get|get %NA% n|@asciilocale|0|caf\xc3\xa9 \xe2\x82\xac\n|^$'
	'EqzuLW1|ascii-locale-fmt|fmt %NA%|@asciilocale|0|n: "caf\xc3\xa9 \xe2\x82\xac"\n|^$'
)

declare -i nRun=0 nBad=0

##	A row's status line goes out when the next row opens, so it covers every
##	binding.
for row in "${rows[@]}"; do
	IFS='|' read -r tid id argv stdinSpec wantRc wantOut wantErr wantFile <<<"${row}"
	fTest "${tid}" "${id}"
	argv="${argv//%F%/${tmpDir}/ok.shcl}"
	argv="${argv//%B2%/${tmpDir}/bad2.shcl}"
	argv="${argv//%B%/${tmpDir}/bad.shcl}"
	argv="${argv//%D%/${tmpDir}/adir}"
	argv="${argv//%P%/${tmpDir}/deep.shcl}"
	argv="${argv//%S%/${tmpDir}/baddef.shcl}"
	argv="${argv//%S1%/${tmpDir}/star1.shcl}"
	argv="${argv//%S2%/${tmpDir}/star2.shcl}"
	argv="${argv//%S3%/${tmpDir}/nobuild.shcl}"
	argv="${argv//%S4%/${tmpDir}/idxreq.shcl}"
	argv="${argv//%SF%/${tmpDir}/twoblocked.shcl}"
	argv="${argv//%S5%/${tmpDir}/cap10000.shcl}"
	argv="${argv//%S6%/${tmpDir}/cap10001.shcl}"
	argv="${argv//%S7%/${tmpDir}/hintschema.shcl}"
	argv="${argv//%S8%/${tmpDir}/rawdef.shcl}"
	argv="${argv//%S9%/${tmpDir}/commadesc.shcl}"
	argv="${argv//%SA%/${tmpDir}/rawvalschema.shcl}"
	argv="${argv//%SB%/${tmpDir}/seldefbad.shcl}"
	argv="${argv//%SC%/${tmpDir}/seldefok.shcl}"
	argv="${argv//%SD%/${tmpDir}/optdefbad.shcl}"
	argv="${argv//%SE%/${tmpDir}/optdefok.shcl}"
	argv="${argv//%SH%/${tmpDir}/optselbad.shcl}"
	argv="${argv//%SI%/${tmpDir}/optdefok2.shcl}"
	argv="${argv//%SJ%/${tmpDir}/optnodef.shcl}"
	argv="${argv//%SK%/${tmpDir}/nosel.shcl}"
	argv="${argv//%R%/${tmpDir}/rawval.shcl}"
	argv="${argv//%N%/${tmpDir}/nowrite/f.shcl}"
	argv="${argv//%X%/${tmpDir}/sel.shcl}"
	argv="${argv//%Q%/${tmpDir}/quote.shcl}"
	argv="${argv//%BA%/${tmpDir}/brarray.shcl}"
	argv="${argv//%SQ%/${tmpDir}/selcomma.shcl}"
	argv="${argv//%SPS%/${tmpDir}/sp/app.schema.shcl}"
	argv="${argv//%SPI%/${tmpDir}/sp/ind.shcl}"
	argv="${argv//%SPZ%/${tmpDir}/sp/zero.shcl}"
	argv="${argv//%SPF%/${tmpDir}/sp/fifo.shcl}"
	argv="${argv//%SPN%/${tmpDir}/sp/nul.shcl}"
	argv="${argv//%SPB%/${tmpDir}/sp/back\\slash.shcl}"
	argv="${argv//%SPW%/${tmpDir}/sp/share.shcl}"
	argv="${argv//%SPM%/${tmpDir}/sp/pagemap.shcl}"
	argv="${argv//%SPC%/${tmpDir}/sp/atcap.shcl}"
	argv="${argv//%SPO%/${tmpDir}/sp/overcap.shcl}"
	argv="${argv//%SPR%/${tmpDir}/sp/rawname.shcl}"
	argv="${argv//%SPU%/${tmpDir}/spurl.shcl}"
	argv="${argv//%SPG%/${tmpDir}/spgone.shcl}"
	argv="${argv//%SP%/${tmpDir}/sp/cfg.shcl}"
	argv="${argv//%SV%/${tmpDir}/missreq.shcl}"
	argv="${argv//%NV%/${tmpDir}/nlvalue.shcl}"
	argv="${argv//%NB%/${tmpDir}/nbname.shcl}"
	argv="${argv//%DN%/${tmpDir}/dotname.shcl}"
	argv="${argv//%SN%/${tmpDir}/dotschema.shcl}"
	argv="${argv//%SL%/${tmpDir}/nlschema.shcl}"
	argv="${argv//%SM%/${tmpDir}/nlfault.shcl}"
	argv="${argv//%DL%/${tmpDir}/nldoc.shcl}"
	argv="${argv//%CB%/${tmpDir}/colbytes.shcl}"
	argv="${argv//%CR%/${tmpDir}/colcr.shcl}"
	argv="${argv//%SG%/${tmpDir}/range.shcl}"
	argv="${argv//%NC%/${tmpDir}/noncanon.shcl}"
	argv="${argv//%DG%/${tmpDir}/outofrange.shcl}"
	## %W% and %L% are rewritten in place, so each binding gets its own fresh
	## copy below.
	argv="${argv//%V3%/${tmpDir}/stamped.shcl}"
	argv="${argv//%V3I%/${tmpDir}/indstamped.shcl}"
	argv="${argv//%V3B%/${tmpDir}/bomstamped.shcl}"
	argv="${argv//%V03%/${tmpDir}/twostamps.shcl}"
	argv="${argv//%BN%/${tmpDir}/ownbanner.shcl}"
	argv="${argv//%FB%/${tmpDir}/bigfmt.shcl}"
	argv="${argv//%RF2%/${tmpDir}/rawfmt2.shcl}"
	argv="${argv//%RF3%/${tmpDir}/rawfmt3.shcl}"
	argv="${argv//%RFQ%/${tmpDir}/rawfmtq.shcl}"
	argv="${argv//%ML%/${tmpDir}/mlost.shcl}"
	argv="${argv//%MT%/${tmpDir}/migtie.shcl}"
	argv="${argv//%MN%/${tmpDir}/mignofinal.shcl}"
	argv="${argv//%MX%/${tmpDir}/miglonecr.shcl}"
	argv="${argv//%MY%/${tmpDir}/miglonecrcrlf.shcl}"
	argv="${argv//%MR%/${tmpDir}/migraw.shcl}"
	argv="${argv//%MV%/${tmpDir}/miglost2.shcl}"
	argv="${argv//%U2%/${tmpDir}/upgv2.shcl}"
	argv="${argv//%UA%/${tmpDir}/upgamb.shcl}"
	argv="${argv//%UC%/${tmpDir}/upgclean.shcl}"
	argv="${argv//%SU%/${tmpDir}/unkey.shcl}"
	argv="${argv//%NA%/${tmpDir}/nonascii.shcl}"
	runIn=""
	if [[ "${argv}" == *%DD%* ]]; then
		runIn="${tmpDir}"
		argv="${argv//%DD%/-dash.shcl}"
	fi
	freshCopy=0
	if [[ "${argv}" == *%W%* ]]; then
		freshCopy=1
		argv="${argv//%W%/${tmpDir}/w.shcl}"
	fi
	freshBs=0
	if [[ "${argv}" == *%BS%* ]]; then
		freshBs=1
		argv="${argv//%BS%/${tmpDir}/bs.shcl}"
	fi
	freshBw=0
	if [[ "${argv}" == *%BW%* ]]; then
		freshBw=1
		argv="${argv//%BW%/${tmpDir}/bw.shcl}"
	fi
	freshKeep=0
	if [[ "${argv}" == *%K%* ]]; then
		freshKeep=1
		argv="${argv//%K%/${tmpDir}/created.shcl}"
	fi
	freshKeepLost=0
	if [[ "${argv}" == *%KL%* ]]; then
		freshKeepLost=1
		argv="${argv//%KL%/${tmpDir}/created.shcl}"
	fi
	freshKeepElem=0
	if [[ "${argv}" == *%KE%* ]]; then
		freshKeepElem=1
		argv="${argv//%KE%/${tmpDir}/created.shcl}"
	fi
	freshKeepGap=0
	if [[ "${argv}" == *%KG%* ]]; then
		freshKeepGap=1
		argv="${argv//%KG%/${tmpDir}/created.shcl}"
	fi
	freshKeepFold=0
	if [[ "${argv}" == *%KF%* ]]; then
		freshKeepFold=1
		argv="${argv//%KF%/${tmpDir}/created.shcl}"
	fi
	freshKeepCrlf=0
	if [[ "${argv}" == *%KM%* ]]; then
		freshKeepCrlf=1
		argv="${argv//%KM%/${tmpDir}/created.shcl}"
	fi
	freshKeepLf=0
	if [[ "${argv}" == *%KN%* ]]; then
		freshKeepLf=1
		argv="${argv//%KN%/${tmpDir}/created.shcl}"
	fi
	freshKeepRaw=0
	if [[ "${argv}" == *%KR%* ]]; then
		freshKeepRaw=1
		argv="${argv//%KR%/${tmpDir}/created.shcl}"
	fi
	freshKeepTail=0
	if [[ "${argv}" == *%KT%* ]]; then
		freshKeepTail=1
		argv="${argv//%KT%/${tmpDir}/created.shcl}"
	fi
	freshKeepTailLf=0
	if [[ "${argv}" == *%KU%* ]]; then
		freshKeepTailLf=1
		argv="${argv//%KU%/${tmpDir}/created.shcl}"
	fi
	freshMigCrlf=0
	if [[ "${argv}" == *%MC%* ]]; then
		freshMigCrlf=1
		argv="${argv//%MC%/${tmpDir}/created.shcl}"
	fi
	freshMigSrc=""
	if [[ "${argv}" == *%MNW%* ]]; then
		freshMigSrc=mignofinal
		argv="${argv//%MNW%/${tmpDir}/created.shcl}"
	elif [[ "${argv}" == *%MXW%* ]]; then
		freshMigSrc=miglonecr
		argv="${argv//%MXW%/${tmpDir}/created.shcl}"
	elif [[ "${argv}" == *%MRW%* ]]; then
		freshMigSrc=migraw
		argv="${argv//%MRW%/${tmpDir}/created.shcl}"
	elif [[ "${argv}" == *%LEW%* ]]; then
		freshMigSrc=listempty
		argv="${argv//%LEW%/${tmpDir}/created.shcl}"
	elif [[ "${argv}" == *%U2W%* ]]; then
		freshMigSrc=upgv2
		argv="${argv//%U2W%/${tmpDir}/created.shcl}"
	elif [[ "${argv}" == *%UAW%* ]]; then
		freshMigSrc=upgamb
		argv="${argv//%UAW%/${tmpDir}/created.shcl}"
	fi
	freshCreate=0
	if [[ "${argv}" == *%C%* ]]; then
		freshCreate=1
		argv="${argv//%C%/${tmpDir}/created.shcl}"
	fi
	freshLong=0
	if [[ "${argv}" == *%L%* ]]; then
		freshLong=1
		argv="${argv//%L%/${tmpDir}/${longName}}"
	fi
	freshWide=0
	if [[ "${argv}" == *%LW%* ]]; then
		freshWide=1
		argv="${argv//%LW%/${tmpDir}/${wideName}}"
	fi
	argv="${argv//%T%/${tmpDir}/tree.shcl}"
	argv="${argv//%LS%/$'\xc5\xbf'}"
	argv="${argv//%F2%/${tmpDir}/two.shcl}"
	argv="${argv//%M%/${tmpDir}/not-there.shcl}"
	## A device that is always full exists on linux and not on windows; the
	## rows that need one are skipped out loud rather than passing vacuously.
	## On windows the msys layer answers for /dev/full and takes the write, and
	## a closed stdout is an invalid handle each runtime reports its own way, so
	## those rows are POSIX rows and say so there. The unwritable directory is
	## an ACL deny there instead of a chmod.
	if [[ "${stdinSpec}" == @full* && ! -w /dev/full ]]; then
		##	Under the gate a skip is a failure, the way the other gates read it:
		##	these rows are the only cover a full-disk write has, and a runner
		##	that quietly loses /dev/full would report OK forever. On windows the
		##	row is skipped a line further down, which is a platform fact rather
		##	than a missing device.
		if [[ -n "${SHCL_GATE_STRICT:-}" && "${onWindows}" == 0 ]]; then
			echo "cli-regress: ${id}: no /dev/full here and the gate requires it" >&2; nBad+=1; continue
		fi
		echo "cli-regress: skipping ${id} (no /dev/full here)"
		echo "cli-regress ${id}" >> "${SHCL_GATE_SKIPS:-/dev/null}"
		fTestSkip; continue
	fi
	if [[ "${onWindows}" == 1 && ( "${stdinSpec}" == @full* || "${stdinSpec}" == @memcap || "${stdinSpec}" == @closedout || "${stdinSpec}" == @appear || "${stdinSpec}" == @change || "${argv}" == *%XF%* || "${argv}" == *"${tmpDir}/sp/zero"* || "${argv}" == *"${tmpDir}/sp/fifo"* || "${argv}" == *"${tmpDir}/sp/back"* ) ]]; then
		echo "cli-regress: skipping ${id} (POSIX fixture; not judged on windows)"
		fTestSkip; continue
	fi
	##	Linux has the page map; another POSIX system may not.
	if [[ "${onWindows}" == 0 && "${argv}" == *"${tmpDir}/sp/pagemap"* && ! -r /proc/self/pagemap ]]; then
		if [[ -n "${SHCL_GATE_STRICT:-}" && "$(uname -s)" == Linux ]]; then
			echo "cli-regress: ${id}: no /proc/self/pagemap here and the gate requires it" >&2; nBad+=1; continue
		fi
		echo "cli-regress: skipping ${id} (no /proc/self/pagemap here)"
		echo "cli-regress ${id}" >> "${SHCL_GATE_SKIPS:-/dev/null}"
		fTestSkip; continue
	fi
	if [[ "${onWindows}" == 0 && "${argv}" == *"${tmpDir}/sp/share.shcl"* ]]; then
		echo "cli-regress: skipping ${id} (windows fixture; not judged here)"
		fTestSkip; continue
	fi
	##	A developer box may run as an account the deny does not bind; the hosted
	##	job may not, since the row is the only cover the windows fix has.
	if [[ "${argv}" == *"${tmpDir}/nowrite/"* && "${nowriteHeld}" == 0 ]]; then
		if [[ -z "${WINRUN_PARTIAL:-}" ]]; then
			echo "cli-regress: ${id}: the directory deny did not hold, so the row cannot be judged" >&2; nBad+=1; continue
		fi
		echo "cli-regress: skipping ${id} (the directory deny does not bind this account)"
		fTestSkip; continue
	fi
	argv="${argv//%XF%/$'\xff'}"
	read -r -a args <<<"${argv}"
	for k in "${!args[@]}"; do
		if [[ "${args[k]}" == "%E%" ]]; then args[k]=""; fi
		if [[ "${args[k]}" == "%DB%" ]]; then args[k]=$'--default=q\nr'; fi
	done
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		## migrate and upgrade --write keep the original beside the file, and
		## refuse when a backup from the last binding's run is still there.
		rm -f "${tmpDir}"/{w,bs,bw,created}_backup_*
		((freshCopy)) && cp "${tmpDir}/sugar.shcl" "${tmpDir}/w.shcl"
		((freshBs)) && cp "${tmpDir}/bsrc.shcl" "${tmpDir}/bs.shcl"
		((freshBw)) && cp "${tmpDir}/brsrc.shcl" "${tmpDir}/bw.shcl"
		((freshLong)) && printf 'k: 1\n' > "${tmpDir}/${longName}"
		((freshWide)) && printf 'k: 1\n' > "${tmpDir}/${wideName}"
		((freshCreate)) && rm -f "${tmpDir}/created.shcl"
		((freshKeep)) && cp "${tmpDir}/keepsrc.shcl" "${tmpDir}/created.shcl"
		((freshKeepLost)) && cp "${tmpDir}/keeplost.shcl" "${tmpDir}/created.shcl"
		((freshKeepElem)) && cp "${tmpDir}/keepelem.shcl" "${tmpDir}/created.shcl"
		((freshKeepGap)) && cp "${tmpDir}/keepgap.shcl" "${tmpDir}/created.shcl"
		((freshKeepFold)) && cp "${tmpDir}/keepfold.shcl" "${tmpDir}/created.shcl"
		((freshKeepCrlf)) && cp "${tmpDir}/keepcrlf.shcl" "${tmpDir}/created.shcl"
		((freshKeepLf)) && cp "${tmpDir}/keeplf.shcl" "${tmpDir}/created.shcl"
		((freshKeepRaw)) && cp "${tmpDir}/keepraw.shcl" "${tmpDir}/created.shcl"
		((freshKeepTail)) && cp "${tmpDir}/keeptail.shcl" "${tmpDir}/created.shcl"
		((freshKeepTailLf)) && cp "${tmpDir}/keeptaillf.shcl" "${tmpDir}/created.shcl"
		((freshMigCrlf)) && cp "${tmpDir}/migcrlf.shcl" "${tmpDir}/created.shcl"
		[[ -n "${freshMigSrc}" ]] && cp "${tmpDir}/${freshMigSrc}.shcl" "${tmpDir}/created.shcl"
		if [[ -n "${runIn}" ]]; then cli="$(realpath -- "${cli}")"; cd -- "${runIn}"; fi
		rc=0
		case "${stdinSpec}" in
			@closedin)  timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" 0<&- || rc=$? ;;
			@closedout) timeout "${rowSecs}" "${cli}" "${args[@]}" 2>"${tmpDir}/err" >&- || rc=$?; : >"${tmpDir}/out" ;;
			@fullout)   timeout "${rowSecs}" "${cli}" "${args[@]}" 2>"${tmpDir}/err" >/dev/full || rc=$?; : >"${tmpDir}/out" ;;
			@fullerr)   timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>/dev/full || rc=$?; : >"${tmpDir}/err" ;;
			-)          timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$? ;;
			@asciilocale) PYTHONIOENCODING=ascii LC_ALL=C timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$? ;;
			@memcap)    (ulimit -v 2000000; exec timeout "${rowSecs}" "${cli}" "${args[@]}") >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$? ;;
			## The file turns up while the command waits on stdin: once it is
			## reading the ops, so the create has already been decided.
			## @change: the file is there first and changes during the wait.
			## The notice used to say when; a pipe gets none since
			## 2026100717500018. A write of more script comments than any pipe
			## holds returns only once the command is reading them.
			@appear|@change)
				[[ "${stdinSpec}" == @change ]] && printf 'a: 1\n' >"${tmpDir}/created.shcl"
				rm -f "${tmpDir}/in.fifo"; mkfifo "${tmpDir}/in.fifo"
				timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" <"${tmpDir}/in.fifo" &
				appearPid=$!
				exec {fifoFd}>"${tmpDir}/in.fifo"
				cat "${tmpDir}/opsfill" >&"${fifoFd}" || true
				if [[ "${stdinSpec}" == @change ]]; then
					printf 'a: 1\nb: 2\n' >"${tmpDir}/created.shcl"
				else
					printf 'b: 2\n' >"${tmpDir}/created.shcl"
				fi
				printf 'int\tk\t1\n' >&"${fifoFd}"
				exec {fifoFd}>&-
				wait "${appearPid}" || rc=$?
				;;
			*)          printf '%b' "${stdinSpec}" | timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" || rc=$? ;;
		esac
		cd -- "${startDir}"
		nRun+=1
		if ((rc == 124 && wantRc != 124)); then
			echo "cli-regress: ${id} [${name}]: timed out after ${rowSecs} s" >&2; nBad+=1; continue
		fi
		if ((rc != wantRc)); then
			echo "cli-regress: ${id} [${name}]: exit ${rc}, expected ${wantRc}" >&2; nBad+=1; continue
		fi
		##	read -d '' and printf -v keep every byte, trailing newlines included,
		##	which $(...) would drop on both sides.
		if [[ "${wantOut}" != "-" ]]; then
			gotOut=""; IFS= read -r -d '' gotOut <"${tmpDir}/out" || true
			printf -v expOut '%b' "${wantOut}"
			if [[ "${gotOut}" != "${expOut}" ]]; then
				echo "cli-regress: ${id} [${name}]: stdout ${gotOut@Q}, expected ${expOut@Q}" >&2; nBad+=1; continue
			fi
		fi
		if [[ -n "${wantFile}" && "${wantFile}" != "-" ]]; then
			gotFile=""
			if [[ -e "${tmpDir}/created.shcl" ]]; then IFS= read -r -d '' gotFile <"${tmpDir}/created.shcl" || true; fi
			printf -v expFile '%b' "${wantFile}"
			if [[ "${gotFile}" != "${expFile}" ]]; then
				echo "cli-regress: ${id} [${name}]: created file ${gotFile@Q}, expected ${expFile@Q}" >&2; nBad+=1; continue
			fi
		fi
		if [[ "${wantErr}" != "-" ]]; then
			gotErr="$(cat -- "${tmpDir}/err")"
			if [[ "${wantErr}" == =* ]]; then
				IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
				printf -v expErr '%b' "${wantErr#=}"
				if [[ "${gotErr}" != "${expErr}" ]]; then
					echo "cli-regress: ${id} [${name}]: stderr ${gotErr@Q}, expected ${expErr@Q}" >&2; nBad+=1
				fi
			elif [[ "${wantErr}" == !* ]]; then
				if grep -qE -- "${wantErr#!}" <<<"${gotErr}"; then
					echo "cli-regress: ${id} [${name}]: stderr ${gotErr@Q} matches /${wantErr#!}/" >&2; nBad+=1
				fi
			elif ! grep -qE -- "${wantErr}" <<<"${gotErr}"; then
				echo "cli-regress: ${id} [${name}]: stderr ${gotErr@Q} does not match /${wantErr}/" >&2; nBad+=1
			fi
		fi
	done
done

## 20260817 item 28: a bare run printed the help and exited 1, -v was refused
## while -V worked, and set sat on stdin saying nothing. Checked against help
## and -V rather than a spelling, since the version moves every release. The
## stdin notice is checked after these.
fTest Er1zoZJ bare-and-short-v
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	for pair in "|help" "-v|-V"; do
		IFS='|' read -r mine ref <<<"${pair}"
		rc=0; "${cli}" ${mine:+"${mine}"} >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$?
		"${cli}" "${ref}" >"${tmpDir}/ref" 2>/dev/null </dev/null || true
		nRun+=1
		if [[ "${rc}" != 0 || -s "${tmpDir}/err" ]] || ! cmp -s "${tmpDir}/out" "${tmpDir}/ref"; then
			echo "cli-regress: bare-and-short-v [${name}]: 'shcl ${mine}' exit ${rc}, expected 0 and the stdout of 'shcl ${ref}'" >&2; nBad+=1
		fi
	done
done
## 20260928 item 9: several informational flags in one run each print once,
## in the order asked, with one blank line before, between and after. The
## first one used to win and the rest were dropped. --about opens with the
## version line, so it covers --version, and a repeat prints once. Built from
## each flag's own output, since the version moves every release.
fTest ErCvyb6 info-flags-in-order
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	"${cli}" --version >"${tmpDir}/v" 2>/dev/null </dev/null || true
	"${cli}" --donate >"${tmpDir}/d" 2>/dev/null </dev/null || true
	"${cli}" help get >"${tmpDir}/g" 2>/dev/null </dev/null || true
	{ printf '\n'; cat "${tmpDir}/v" "${tmpDir}/d"; } >"${tmpDir}/want1"
	## Help less its last byte. BSD head has no -c -1.
	g="$(cat "${tmpDir}/g"; echo .)"
	{ printf '%s' "${g%?.}"; cat "${tmpDir}/d"; } >"${tmpDir}/want2"
	for pair in "--version --donate|want1" "help get --donate|want2" "get --help --donate|want2"; do
		IFS='|' read -r argv want <<<"${pair}"
		read -r -a args <<<"${argv}"
		rc=0; "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$?
		nRun+=1
		if [[ "${rc}" != 0 || -s "${tmpDir}/err" ]] || ! cmp -s "${tmpDir}/out" "${tmpDir}/${want}"; then
			echo "cli-regress: info-flags-in-order [${name}]: 'shcl ${argv}' exit ${rc}, or its stdout is not each output once, in order" >&2; nBad+=1
		fi
	done
done
fTest ErCvycb info-about-covers-version
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	"${cli}" --about >"${tmpDir}/a" 2>/dev/null </dev/null || true
	"${cli}" --donate >"${tmpDir}/d" 2>/dev/null </dev/null || true
	for pair in "--about --version|a" "--version --about|a" "-V --about -v|a" "--donate --donate|d"; do
		IFS='|' read -r argv want <<<"${pair}"
		read -r -a args <<<"${argv}"
		rc=0; "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$?
		nRun+=1
		if [[ "${rc}" != 0 || -s "${tmpDir}/err" ]] || ! cmp -s "${tmpDir}/out" "${tmpDir}/${want}"; then
			echo "cli-regress: info-about-covers-version [${name}]: 'shcl ${argv}' exit ${rc}, expected the stdout of one '${want}' output" >&2; nBad+=1
		fi
	done
done
## The notice went out whatever stdin was until 2026100717500018, so a script
## piping ops in got it on every run. Only a terminal gets it now.
#fTest EqzuLW2 set-stdin-notice
#for b in "${bindings[@]}"; do
#	name="${b%%|*}"; cli="${b#*|}"
#	rc=0; "${cli}" set "${tmpDir}/ok.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null || rc=$?
#	nRun+=1
#	gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
#	if [[ "${rc}" != 0 || "${gotErr}" != $'shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)\n' ]]; then
#		echo "cli-regress: set-stdin-notice [${name}]: exit ${rc}, stderr ${gotErr@Q}" >&2; nBad+=1
#	fi
#done
fTest Es8bB5G set-stdin-no-notice
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	for how in null pipe; do
		rc=0
		if [[ "${how}" == null ]]; then "${cli}" set "${tmpDir}/ok.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null || rc=$?
		else printf 'int\tx\t1\n' | "${cli}" set "${tmpDir}/ok.shcl" >/dev/null 2>"${tmpDir}/err" || rc=$?; fi
		nRun+=1
		if [[ "${rc}" != 0 || -s "${tmpDir}/err" ]]; then
			echo "cli-regress: set-stdin-no-notice [${name}]: stdin from ${how}, exit ${rc}, stderr $(cat -- "${tmpDir}/err")" >&2; nBad+=1
		fi
	done
done
## At a terminal the notice is what keeps the wait from reading as a hang. The
## terminal gets EOF before the command starts, so the ops script is empty.
fTest Es8bB5H set-stdin-notice-terminal
if [[ "${onWindows}" == 1 ]] || ! command -v python3 >/dev/null 2>&1; then
	echo "cli-regress: skipping set-stdin-notice-terminal (needs python3 and a POSIX terminal)"
	fTestSkip
else
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		rc=0
		python3 -c '
import os, subprocess, sys
master, slave = os.openpty()
os.write(master, b"\x04")
sys.exit(subprocess.run(sys.argv[1:], stdin=slave, stdout=subprocess.DEVNULL, timeout=60).returncode)
' "${cli}" set "${tmpDir}/ok.shcl" 2>"${tmpDir}/err" </dev/null || rc=$?
		nRun+=1
		gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
		if [[ "${rc}" != 0 || "${gotErr}" != $'shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)\n' ]]; then
			echo "cli-regress: set-stdin-notice-terminal [${name}]: exit ${rc}, stderr ${gotErr@Q}" >&2; nBad+=1
		fi
	done
fi

## 20260716 item 25: a reader that leaves early got three exit codes, 134 from
## the reference's abort, 141 from Go and 0 from Python. Settled as dying of
## SIGPIPE the way cat and head do, with nothing on stderr. The document has to
## outlast the pipe buffer, or the write is done before the reader goes. An
## ignored SIGPIPE survives exec and would let Go and C exit quietly, so
## the default goes back on first. Not a closed stdout: that is EBADF, and the
## closed-stdout row above already pins it.
awk 'BEGIN{ for (i = 0; i < 40000; i++) printf "k%d: %d\n", i, i }' > "${tmpDir}/big.shcl"
## BSD env has no --default-signal, so perl puts the default back there. With
## neither, a SIGPIPE nobody ignored needs nothing put back; yes shows which.
pipeDfl=()
#  shellcheck disable=2016  ## perl's own variables.
if env --default-signal=PIPE true 2>/dev/null; then pipeDfl=(env --default-signal=PIPE)
elif command -v perl >/dev/null 2>&1; then pipeDfl=(perl -e '$SIG{PIPE} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127')
else yesRc="$( { { yes 2>/dev/null; echo "$?" >&3; } | head -c1 >/dev/null; } 3>&1 || true)"; fi
fTest EqzuLW3 broken-pipe
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping broken-pipe (POSIX signal; not judged on windows)"
	fTestSkip
elif [[ -n "${yesRc:-}" && "${yesRc}" != 141 ]]; then
	echo "cli-regress: skipping broken-pipe (SIGPIPE is ignored here, with no env --default-signal or perl to undo it)"
	fTestSkip
else
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		##	The status is kept from inside the pipeline: under pipefail a 141 there
		##	would end this script, and the || that stops that also resets PIPESTATUS.
		{ rc=0; "${pipeDfl[@]}" "${cli}" fmt "${tmpDir}/big.shcl" 2>"${tmpDir}/err" </dev/null || rc=$?; echo "${rc}" >"${tmpDir}/rc"; } | head -c1 >/dev/null
		rc="$(<"${tmpDir}/rc")"; nRun+=1
		gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
		if [[ "${rc}" != 141 || -n "${gotErr}" ]]; then
			echo "cli-regress: broken-pipe [${name}]: exit ${rc}, expected 141 with nothing on stderr; stderr ${gotErr@Q}" >&2; nBad+=1
		fi
	done
fi

## 20260926 item 8: a new file named through a volume path, \\.\C:\dir\new,
## was refused as not a regular file: with nothing there to open, the check fell
## to the full path, and any \\.\ there read as a device.
fTest Er8M01L windows-volume-path-create
if [[ "${onWindows}" == 1 ]]; then
	winTmp="$(cygpath -w "${tmpDir}")"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		rm -f "${tmpDir}/volnew.shcl"
		rc=0; timeout "${rowSecs}" "${cli}" set --write "\\\\.\\${winTmp}\\volnew.shcl" --set=a=2 >/dev/null 2>"${tmpDir}/err" </dev/null || rc=$?
		nRun+=1
		if [[ "${rc}" != 0 || "$(cat "${tmpDir}/volnew.shcl" 2>/dev/null || true)" != *"a: 2"* ]]; then
			echo "cli-regress: windows-volume-path-create [${name}]: exit ${rc}: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		fi
	done
else
	fTestSkip
fi

## 2026092815155546: the old copy was a new file, so it took the directory's
## ACL, while the migrated file keeps the original's. A config readable by its
## owner only got a copy the directory's readers could open. The copy's DACL
## has to match the original's as it was before the run.
fDacl(){
	MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "(Get-Acl -LiteralPath '$1').GetSecurityDescriptorSddlForm('Access')" 2>/dev/null | tr -d '\r' || true
}
fTest ErMwKp1 windows-migrate-acl
if [[ "${onWindows}" == 1 ]]; then
	aclDir="${tmpDir}/migacl"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="$(realpath -- "${b#*|}")"
		rm -rf "${aclDir}"; mkdir -p "${aclDir}"
		printf 'base:[Boston]\n\tlat: 42\n' > "${aclDir}/f.shcl"
		winDir="$(cygpath -w "${aclDir}")"
		MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "${winDir}" /grant '*S-1-5-32-545:(OI)(CI)(R)' >/dev/null
		MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "${winDir}\\f.shcl" /inheritance:r /grant:r "${USERNAME}:(F)" >/dev/null
		want="$(fDacl "${winDir}\\f.shcl")"
		rc=0; (cd "${aclDir}" && timeout "${rowSecs}" "${cli}" migrate --write f.shcl >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		got="$(fDacl "${winDir}\\f_backup_20261004-001500_format-v2.shcl")"
		nRun+=1
		if [[ "${rc}" != 0 || "${want}" != D:P* || "${got}" != "${want}" ]]; then
			echo "cli-regress: windows-migrate-acl [${name}]: exit ${rc}, copy ${got@Q}, original ${want@Q}: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		fi
	done
else
	fTestSkip
fi

## 20260928 item 12: Python 3.13 and later has os.fchmod on windows, which put
## the read-only bit on the copy of a read-only file. A failed save could not
## remove that copy, and the next run refused the taken name.
fTest ErMwwHF windows-migrate-readonly
if [[ "${onWindows}" == 1 ]]; then
	roDir="${tmpDir}/migro"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="$(realpath -- "${b#*|}")"
		rm -rf "${roDir}"; mkdir -p "${roDir}"
		printf 'base:[Boston]\n\tlat: 42\n' > "${roDir}/f.shcl"
		winDir="$(cygpath -w "${roDir}")"
		MSYS_NO_PATHCONV=1 attrib +r "${winDir}\\f.shcl" >/dev/null
		rc=0; (cd "${roDir}" && timeout "${rowSecs}" "${cli}" migrate --write f.shcl >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		got="$(MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "(Get-Item -LiteralPath '${winDir}\\f_backup_20261004-001500_format-v2.shcl').IsReadOnly" 2>/dev/null | tr -d '\r' || true)"
		MSYS_NO_PATHCONV=1 attrib -r "${winDir}\\*" >/dev/null || true
		nRun+=1
		if [[ "${rc}" != 0 || "${got}" != False ]]; then
			echo "cli-regress: windows-migrate-readonly [${name}]: exit ${rc}, copy read-only ${got@Q}: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		fi
	done
else
	fTestSkip
fi

## 20260928 item 13: the name starts after a drive with no separator, so the
## copy of C:.shclrc is C:.shclrc_backup_..., not C:_backup_....shclrc. The drive is
## the fixture's own, whose current directory is the fixture. Only that argument
## is kept from path conversion, since the python wrapper's own path needs it.
fTest ErMwwZ1 windows-migrate-drive-relative
if [[ "${onWindows}" == 1 ]]; then
	drelDir="${tmpDir}/migdrel"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="$(realpath -- "${b#*|}")"
		rm -rf "${drelDir}"; mkdir -p "${drelDir}"
		printf 'base:[Boston]\n\tlat: 42\n' > "${drelDir}/.shclrc"
		drive="$(cygpath -w "${drelDir}")"; drive="${drive:0:2}"
		rc=0; (cd "${drelDir}" && MSYS2_ARG_CONV_EXCL="${drive}" timeout "${rowSecs}" "${cli}" migrate --write "${drive}.shclrc" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		if [[ "${rc}" != 0 || ! -f "${drelDir}/.shclrc_backup_20261004-001500_format-v2" || -e "${drelDir}/_backup_20261004-001500_format-v2.shclrc" ]]; then
			echo "cli-regress: windows-migrate-drive-relative [${name}]: exit ${rc}, left $(find "${drelDir}" -mindepth 1 -printf '%f '): $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		fi
	done
else
	fTestSkip
fi

## 20260716 item 26: the C CLI's own allocations went unchecked, so running out
## of memory was a segfault where the library's path exits 70. Two inputs under
## an address-space cap: one too big to read, which is the CLI's own buffer, and
## the pipe document above, which reads in about a megabyte and parses in over
## twenty, which is the library handing back NULL. The first is sparse and costs
## no disk. Only the C CLI makes this promise, and ulimit -v is POSIX.
## FreeBSD's own echo segfaults under 12 MiB, before main.
oomCapKb=12288
[[ "$(uname -s)" == FreeBSD ]] && oomCapKb=16384
fOom(){
	local doc="$1"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		[[ "${name}" == c ]] || continue
		rc=0
		(ulimit -v "${oomCapKb}"; exec "${cli}" fmt "${tmpDir}/${doc}.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
		if [[ "${rc}" != 70 || "${gotErr}" != $'shcl: out of memory\n' ]]; then
			echo "cli-regress: out-of-memory-${doc} [${name}]: exit ${rc}, expected 70; stderr ${gotErr@Q}" >&2; nBad+=1
		fi
	done
}
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping out-of-memory (POSIX fixture; not judged on windows)"
else
	truncate -s 64M "${tmpDir}/huge.shcl"
fi
fTest EqzuLW4 out-of-memory-huge
if [[ "${onWindows}" == 1 ]]; then fTestSkip; else fOom huge; fi
fTest EqzuLW5 out-of-memory-big
if [[ "${onWindows}" == 1 ]]; then fTestSkip; else fOom big; fi

## The deepest legal document inside the stack windows gives a main thread,
## 1 MB. The reference emits one frame per level, and a debug build of it grew
## past that while linux, at 8 MB, never noticed: only the windows job ran it
## (deep-nesting). fmt, and a set that keeps lines, which emits twice.
fSmallStack(){
	local cmd="$1"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		args=(fmt "${tmpDir}/deep.shcl")
		[[ "${cmd}" == set ]] && args=(set "--set=${deepPath}=2" "${tmpDir}/deep.shcl")
		rc=0
		(ulimit -s 1024; exec "${cli}" "${args[@]}" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
		if [[ "${rc}" != 0 || -n "${gotErr}" ]]; then
			echo "cli-regress: small-stack-${cmd} [${name}]: exit ${rc}, expected 0; stderr ${gotErr@Q}" >&2; nBad+=1
		fi
	done
}
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping small-stack (POSIX fixture; the windows stack is the deep-nesting row)"
fi
deepPath="n0"; for i in {1..510}; do deepPath+=".n${i}"; done; deepPath+=".leaf"
fTest Er0CdE8 small-stack-fmt
if [[ "${onWindows}" == 1 ]]; then fTestSkip; else fSmallStack fmt; fi
fTest Er0CdE9 small-stack-set
if [[ "${onWindows}" == 1 ]]; then fTestSkip; else fSmallStack set; fi

## 20261003 item 11: a Schema line's file swapped for a FIFO after the stat and
## before the open hung check, since the open waited for a writer. The stat on
## that path is held up while the swap runs, so the open meets the FIFO every
## time rather than once in a few hundred runs. The open has to meet the FIFO,
## or the swap came too early or too late and the row tested nothing; it tries
## again with more time before calling that a failure.
fSchemaSwap(){
	local d log rc gotErr hit try swapAt holdUs
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		d="${tmpDir}/swap-${name}"; log="${d}.trace"
		hit=0
		for try in "0.25 600000" "1.5 4000000"; do
			swapAt="${try% *}"; holdUs="${try#* }"
			mkdir -p "${d}"
			printf 'a: 1\n##    Schema   s.schema\n' > "${d}/cfg.shcl"
			## The last try left a FIFO here, and a write to it would wait.
			rm -f "${d}/fifo" "${d}/s.schema"; mkfifo "${d}/fifo"
			printf 'a: int\n' > "${d}/s.schema"
			( sleep "${swapAt}"; mv -f "${d}/fifo" "${d}/s.schema" ) &
			rc=0
			strace -f -qq -o "${log}" -P "${d}/s.schema" -e trace='%%stat,openat,open' \
				-e inject="%%stat:delay_exit=${holdUs}:when=1" \
				timeout -s KILL 10 "${cli}" check "${d}/cfg.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null || rc=$?
			wait "$!" || true
			gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
			## The open met the FIFO: it hung until killed, or an fstat after it
			## saw one.
			if [[ "${rc}" == 137 ]] || awk -v p="\"${d}/s.schema\", O_RDONLY" \
				'index($0, p) { opened = 1 } opened && /S_IFIFO/ { hit = 1 } END { exit !hit }' "${log}"; then
				hit=1; break
			fi
		done
		nRun+=1
		if [[ "${hit}" == 0 ]]; then
			echo "cli-regress: schema-line-fifo-swap [${name}]: the swap never landed between the stat and the open" >&2; nBad+=1
		elif [[ "${rc}" != 8 || "${gotErr}" != *"not a regular file"* ]]; then
			echo "cli-regress: schema-line-fifo-swap [${name}]: exit ${rc}, expected 8; stderr ${gotErr@Q}" >&2; nBad+=1
		fi
	done
}
fTest Erlf8t9 schema-line-fifo-swap
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping schema-line-fifo-swap (POSIX fixture; windows has no FIFO at a path)"
	fTestSkip
elif ! command -v strace >/dev/null 2>&1; then
	if [[ -n "${SHCL_GATE_STRICT:-}" && "$(uname -s)" == Linux ]]; then
		echo "cli-regress: schema-line-fifo-swap: no strace here and the gate requires it" >&2; nBad+=1
	fi
	echo "cli-regress: skipping schema-line-fifo-swap (no strace here)"
	echo "cli-regress schema-line-fifo-swap" >> "${SHCL_GATE_SKIPS:-/dev/null}"
	fTestSkip
else
	fSchemaSwap
fi

## What a save does with each thing it can find at the path, one case per row of
## the Save outcomes table in design.md, which is the rule. A FIFO, a link whose
## text names a directory and a clean of `lnk/..` were each a site fix away from
## the last one (20260918b items 3, 17 and 18). Each binding gets a fresh
## directory, since the save is what is under test, and a timeout, since the old
## code blocked reading a FIFO. POSIX fixtures: links and FIFOs.
saveDir="${tmpDir}/save"
## A group the caller is in that is not its own, for the kept-group cases.
altGroup="$(id -Gn | tr ' ' '\n' | grep -vx "$(id -gn)" | head -1 || true)"
fSaveSetup() {
	case "$1" in
		regular)  printf 'a: 1\n' > f.shcl ;;
		same)     printf 'a: 1\n' > f.shcl; fStat i f.shcl > ino ;;
		differs)  printf 'a:   1\n' > f.shcl; fStat i f.shcl > ino ;;
		group)    printf 'a:   1\n' > f.shcl; chgrp "${altGroup}" f.shcl; chmod 0640 f.shcl ;;
		nothing|missdir) : ;;
		link)     printf 'a: 1\n' > real.shcl; ln -s real.shcl f.shcl ;;
		dangling) mkdir sub; ln -s sub/x.shcl f.shcl ;;
		dotdot)   mkdir -p real/sub top; ln -s ../real/sub top/lnkdir; ln -s ../x.shcl real/sub/f.shcl ;;
		linkdir)  ln -s d/ f.shcl ;;
		cycle)    ln -s g.shcl f.shcl; ln -s f.shcl g.shcl ;;
		slash)    printf 'a: 1\n' > f.shcl ;;
		dir)      mkdir f.shcl ;;
		fifo*)    mkfifo f.shcl ;;
		device)   ln -s /dev/null f.shcl ;;
		## `base:[Boston]` alone reads clean as a one-element array now, so a
		## file that does not say it is 2.x keeps it (exit 7). A line under it
		## makes it E028 here, so these rewrite at exit 0 as they did.
		migrate)  printf 'base:[Boston]\n\tlat: 42\n' > f.shcl; chmod 0640 f.shcl ;;
		migrate-taken) printf 'base:[Boston]\n\tlat: 42\n' > f.shcl; printf 'x\n' > f_backup_20261004-001500_format-v2.shcl ;;
		migrate-stamp) printf 'a: 1\n' > f.shcl ;;
		kept-remove) printf 'x: 1\nr: [1, 2\ny: 3\n' > f.shcl ;;
		kept-lazy) printf 'a: [1\n\tb: 2\ny: 3\n' > f.shcl ;;
		kept-set)  printf 'a: [1\n\tb: 2\ny: 3\n' > f.shcl ;;
		kept-create) printf 'x: 1\na: [1\ny: 3\na: [2\n' > f.shcl ;;
		migrate-dotname) printf 'base:[Boston]\n\tlat: 42\n' > .f ;;
		migrate-dotdir) mkdir d.x; printf 'base:[Boston]\n\tlat: 42\n' > d.x/f ;;
		migrate-link) mkdir real; printf 'base:[Boston]\n\tlat: 42\n' > real/c.shcl; ln -s real/c.shcl f.shcl ;;
		migrate-setgid) mkdir sg; chgrp "${altGroup}" sg; chmod 2775 sg; printf 'base:[Boston]\n\tlat: 42\n' > sg/f.shcl; chgrp "$(id -gn)" sg/f.shcl; chmod 0640 sg/f.shcl ;;
		## BSD gives a new file the directory's group, and refuses setgid on a
		## file whose group the caller is not in.
		migrate-setid) printf 'base:[Boston]\n\tlat: 42\n' > f.shcl; chgrp "$(id -gn)" f.shcl; chmod 6755 f.shcl ;;
		migrate-rodir) mkdir ro; printf 'base:[Boston]\n\tlat: 42\n' > ro/g.shcl; chmod 0555 ro ;;
		upgrade)  printf 'base:[Boston]\n\tlat: 42\n' > f.shcl; chmod 0640 f.shcl ;;
		upgrade-taken) printf 'base:[Boston]\n\tlat: 42\n' > f.shcl; printf 'x\n' > f_backup_20261004-001500_format-v2.shcl ;;
		upgrade-link) mkdir real; printf 'base:[Boston]\n\tlat: 42\n' > real/c.shcl; ln -s real/c.shcl f.shcl ;;
		upgrade-rodir) mkdir ro; printf 'base:[Boston]\n\tlat: 42\n' > ro/g.shcl; chmod 0555 ro ;;
	esac
}
## id | argv | exit | what must hold afterwards, as a bash test run in the directory
## The last field is eval'd after the run, so its substitutions stay unexpanded.
# shellcheck disable=SC2016
saveCases=(
	'EqLbKeA|regular|set --write --set b=2 f.shcl|0|[[ -f f.shcl && ! -L f.shcl ]] && grep -qx "b: 2" f.shcl'
	'EqLbKeB|nothing|set --write --set b=2 f.shcl|0|[[ -f f.shcl && ! -L f.shcl ]] && grep -qx "b: 2" f.shcl'
	'EqLbKeC|link|set --write --set b=2 f.shcl|0|[[ -L f.shcl ]] && grep -qx "b: 2" real.shcl'
	'EqLbKeD|dangling|set --write --set b=2 f.shcl|0|[[ -L f.shcl ]] && grep -qx "b: 2" sub/x.shcl'
	'EqLbKeE|dotdot|set --write --set b=2 top/lnkdir/f.shcl|0|[[ -L real/sub/f.shcl && ! -e top/x.shcl ]] && grep -qx "b: 2" real/x.shcl'
	## 20260830 item 32: Python cleaned the `..` against a directory that is not
	## there and created f.shcl here at exit 0. The kernel refuses the path.
	'Er1zoZK|missdir|set --write --set b=2 nodir/../f.shcl|8|[[ -z "$(ls -A)" ]]'
	'EqLbKeF|linkdir|set --write --set b=2 f.shcl|8|[[ -L f.shcl && ! -e d ]]'
	'EqLbKeG|cycle|set --write --set b=2 f.shcl|8|[[ -L f.shcl && -L g.shcl ]]'
	'EqLbKeH|slash|set --write --set b=2 f.shcl/|8|[[ -f f.shcl ]] && ! grep -q b f.shcl'
	'EqLbKeI|dir|set --write --set b=2 f.shcl|8|[[ -d f.shcl ]]'
	'EqLbKeJ|fifo|set --write --set b=2 f.shcl|8|[[ -p f.shcl ]]'
	'EqLbKeK|fifo-fmt|fmt --write f.shcl|8|[[ -p f.shcl ]]'
	'EqLbKeL|device|set --write --set b=2 f.shcl|8|[[ -L f.shcl && -c /dev/null ]]'
	## 20260918b item 56: a write with nothing to write leaves the file alone,
	## inode and all, and one with something to write still replaces it.
	'EqMO8f8|same|fmt --write f.shcl|0|[[ "$(fStat i f.shcl)" == "$(cat ino)" ]]'
	'EqMO8f9|differs|fmt --write f.shcl|0|[[ "$(fStat i f.shcl)" != "$(cat ino)" ]] && grep -qx "a: 1" f.shcl'
	## 20260918b item 57: the group comes over with the mode, so a config a
	## service reads by group keeps that read.
	'EqMO8fA|group|fmt --write f.shcl|0|[[ "$(fStat G f.shcl)" == "${altGroup}" && "$(fStat a f.shcl)" == 640 ]]'
	## migrate --write ends with the new file and the original beside it, at the
	## original's mode. An earlier copy is never written over, and a file that
	## only gains the Format line gets no copy.
	'Er5ivua|migrate|migrate --write f.shcl|0|grep -qx "base: Boston" f.shcl && cmp -s f_backup_20261004-001500_format-v2.shcl <(printf "base:[Boston]\n\tlat: 42\n") && [[ "$(fStat a f_backup_20261004-001500_format-v2.shcl)" == 640 ]]'
	'Er5ivub|migrate-taken|migrate --write f.shcl|8|grep -qx "base:\[Boston\]" f.shcl && [[ "$(cat f_backup_20261004-001500_format-v2.shcl)" == x && "$(ls -A | wc -l | tr -d " ")" == 2 ]]'
	'Er5ivuc|migrate-stamp|migrate --write f.shcl|0|[[ "$(ls -A)" == f.shcl ]]'
	'Er5ivud|migrate-dotname|migrate --write .f|0|[[ -f .f_backup_20261004-001500_format-v2 ]]'
	'Er5ivue|migrate-dotdir|migrate --write d.x/f|0|[[ -f d.x/f_backup_20261004-001500_format-v2 ]]'
	## Through a link: the target gets the new text, and the copy sits beside
	## the link as a plain file.
	'Er5qICv|migrate-link|migrate --write f.shcl|0|[[ -L f.shcl && -f f_backup_20261004-001500_format-v2.shcl && ! -L f_backup_20261004-001500_format-v2.shcl && ! -e real/c_backup_20261004-001500_format-v2.shcl ]] && grep -qx "base: Boston" real/c.shcl && grep -qx "base:\[Boston\]" f_backup_20261004-001500_format-v2.shcl'
	## 20260928 items 3, 6 and 11: in a setgid directory the copy takes the
	## original's group, not the directory's. Setuid, setgid and sticky come
	## over too. A copy that cannot be made names its path once.
	'ErCrqxU|migrate-setgid|migrate --write sg/f.shcl|0|[[ "$(fStat G sg/f_backup_20261004-001500_format-v2.shcl)" == "$(id -gn)" && "$(fStat a sg/f_backup_20261004-001500_format-v2.shcl)" == 640 ]]'
	'ErCrqz4|migrate-setid|migrate --write f.shcl|0|[[ "$(fStat a f_backup_20261004-001500_format-v2.shcl)" == 6755 ]]'
	## A remove leaves the kept line beside its target (2026100307163901). Until
	## that fix the save gate refused this at 7 and left the file alone.
	'EreYYXK|kept-remove|set --write --remove y f.shcl|0|cmp -s f.shcl <(printf "x: 1\nr: [1, 2\n") && ! grep -q "refusing" "${tmpDir}/err"'
	## A field opened only by the line under it goes with that line, and its own
	## kept line stays, with no bare `a:` left behind (2026100307163907).
	'ErgTonu|kept-lazy|set --write --remove a.b f.shcl|0|cmp -s f.shcl <(printf "a: [1\ny: 3\n")'
	## A setter on that field writes its kept line as a comment with a note, so
	## the file has one `a` (2026100307163907).
	'Erlf1Is|kept-set|set --write --set a=5 f.shcl|0|cmp -s f.shcl <(printf "# a: [1  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing \x27]\x27 on the line\na: 5\n\tb: 2\ny: 3\n")'
	## A setter making `a` writes every kept `a` in the block as that comment
	## and puts the new line under the first (2026100307163907).
	'ErmXhyt|kept-create|set --write --set a=5 f.shcl|0|cmp -s f.shcl <(printf "x: 1\n# a: [1  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing \x27]\x27 on the line\na: 5\ny: 3\n# a: [2  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing \x27]\x27 on the line\n")'
	## upgrade --write backs up and writes the same way (2026100313461649).
	'Es2Rg1L|upgrade|upgrade --write f.shcl|0|grep -qx "base: Boston" f.shcl && grep -qx "##    Format   3" f.shcl && cmp -s f_backup_20261004-001500_format-v2.shcl <(printf "base:[Boston]\n\tlat: 42\n") && [[ "$(fStat a f_backup_20261004-001500_format-v2.shcl)" == 640 && "$(ls -A | wc -l | tr -d " ")" == 2 ]]'
	'Es2Rg1M|upgrade-taken|upgrade --write f.shcl|8|grep -qx "base:\[Boston\]" f.shcl && [[ "$(cat f_backup_20261004-001500_format-v2.shcl)" == x && "$(ls -A | wc -l | tr -d " ")" == 2 ]]'
	'Es2Rg1N|upgrade-link|upgrade --write f.shcl|0|[[ -L f.shcl && -f f_backup_20261004-001500_format-v2.shcl && ! -L f_backup_20261004-001500_format-v2.shcl && ! -e real/c_backup_20261004-001500_format-v2.shcl ]] && grep -qx "base: Boston" real/c.shcl && grep -qx "base:\[Boston\]" f_backup_20261004-001500_format-v2.shcl'
	'Es2Rg1O|fifo-upgrade|upgrade --write f.shcl|8|[[ -p f.shcl ]]'
	'Es2Rg1P|upgrade-rodir|upgrade --write ro/g.shcl|8|grep -qx "base:\[Boston\]" ro/g.shcl && grep -qiE "^ro/g_backup_20261004-001500_format-v2\.shcl: permission denied" "${tmpDir}/err"'
	'ErCrr0Y|migrate-rodir|migrate --write ro/g.shcl|8|grep -qx "base:\[Boston\]" ro/g.shcl && grep -qiE "^ro/g_backup_20261004-001500_format-v2\.shcl: permission denied" "${tmpDir}/err" && ! grep -q "open " "${tmpDir}/err"'
)
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping the save-target cases (POSIX fixtures; not judged on windows)"
fi
for sc in "${saveCases[@]}"; do
	IFS='|' read -r tid id argv wantRc holds <<<"${sc}"
	fTest "${tid}" "save-${id}"
	if [[ "${onWindows}" == 1 ]]; then
		fTestSkip; continue
	fi
	##	A caller in one group has nothing to tell apart. Under the gate that is a
	##	failure, as the /dev/full rows are: these two rows are the only cover the
	##	kept group has. The hosted ubuntu runner's user is in several groups.
	if [[ ( "${id}" == group || "${id}" == migrate-setgid ) && -z "${altGroup}" ]]; then
		if [[ -n "${SHCL_GATE_STRICT:-}" ]]; then
			echo "cli-regress: save-${id}: no second group for the caller and the gate requires one" >&2; nBad+=1; continue
		fi
		echo "cli-regress: skipping save-${id} (no second group for the caller)"
		echo "cli-regress save-${id}" >> "${SHCL_GATE_SKIPS:-/dev/null}"
		fTestSkip; continue
	fi
	## Root writes through a read-only directory.
	if [[ "${id}" == migrate-rodir && "$(id -u)" == 0 ]]; then
		fTestSkip; continue
	fi
	read -r -a args <<<"${argv}"
	for b in "${bindings[@]}"; do
		## Absolute, since the run is from inside the fixture directory.
		name="${b%%|*}"; cli="$(realpath -- "${b#*|}")"
		if [[ -d "${saveDir}" ]]; then chmod -R u+w "${saveDir}"; fi
		rm -rf "${saveDir}"; mkdir -p "${saveDir}"
		(cd "${saveDir}" && fSaveSetup "${id}")
		rc=0
		(cd "${saveDir}" && timeout 20 "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		if ((rc != wantRc)); then
			echo "cli-regress: save-${id} [${name}]: exit ${rc}, expected ${wantRc}: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1; continue
		fi
		if ! (cd "${saveDir}" && eval "${holds}"); then
			echo "cli-regress: save-${id} [${name}]: afterwards, not true: ${holds}" >&2; nBad+=1
		fi
	done
done

## 2026100307163904: migrate stamps a file right under its last comment, and a
## later banner on took the comment with the stamp. Run as a user would, one
## command after the other on the file, once with the migrated note and once
## without it.
infoBlock="$(printf '%b' '##\n## This config file format is SHCL.\n## "Simple Hierarchical Config Language"\n##    Format   3\n##    Home     https://github.com/yottacore/shcl\n##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n##    Legal    SHCL is Copyright \xc2\xa9 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n##\n')"
banDir="${tmpDir}/banner"
for bc in 'Erg8DKx|stamp|p: 1\n## Owner: ops team\n' 'Erg8DKy|stamp-note|base:[Boston]\n## Owner: ops team\n'; do
	IFS='|' read -r tid id text <<<"${bc}"
	fTest "${tid}" "migrate-then-banner-${id}"
	want="$(printf '%b' "${text}" | sed 's/:\[Boston\]/: Boston/')"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		rm -rf "${banDir}"; mkdir -p "${banDir}"
		printf '%b' "${text}" > "${banDir}/f.shcl"
		rc=0
		"${cli}" migrate --from-2x --write "${banDir}/f.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null || rc=$?
		if ((rc == 0)); then
			printf 'banner\ton\n' | "${cli}" set --write "${banDir}/f.shcl" >/dev/null 2>"${tmpDir}/err" || rc=$?
		fi
		nRun+=1
		if ((rc != 0)); then
			echo "cli-regress: migrate-then-banner-${id} [${name}]: exit ${rc}: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		elif [[ "$(cat "${banDir}/f.shcl"; echo .)" != "${want}"$'\n\n'"${infoBlock}"$'\n.' ]]; then
			echo "cli-regress: migrate-then-banner-${id} [${name}]: the file afterwards: $(head -c 300 "${banDir}/f.shcl")" >&2; nBad+=1
		fi
	done
done

## migrate --write makes its copy, then the save fails. The file still holds
## the original, so the copy goes too, or it would refuse the next run at 8.
## The copy fits under a 1 KiB file-size cap and the migrated text, two stamp
## lines longer, does not, so the temp file's write fails with EFBIG. SIGXFSZ
## is ignored so it is an error and not a kill. POSIX only.
fTest Er5qICw migrate-failed-save
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping migrate-failed-save (POSIX file-size limit)"
	fTestSkip
else
	failDir="${tmpDir}/migfail"
	pad="$(printf '#%.0s' {1..980})"
	printf 'base:[Boston]\n\tlat: 42\n%s\n' "${pad}" > "${tmpDir}/migfail.src"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		rm -rf "${failDir}"; mkdir -p "${failDir}"
		cp "${tmpDir}/migfail.src" "${failDir}/f.shcl"
		rc=0
		(trap '' XFSZ; ulimit -f 1; exec "${cli}" migrate --write "${failDir}/f.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		## An error naming the copy means the cap broke the copy, not the save.
		if [[ "${rc}" != 8 ]] || grep -q _backup_ "${tmpDir}/err"; then
			echo "cli-regress: migrate-failed-save [${name}]: exit ${rc}, expected 8 from the save: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		elif ! cmp -s "${failDir}/f.shcl" "${tmpDir}/migfail.src" || [[ -e "${failDir}/f_backup_20261004-001500_format-v2.shcl" ]]; then
			echo "cli-regress: migrate-failed-save [${name}]: afterwards: $(find "${failDir}" -mindepth 1 -printf '%f ')" >&2; nBad+=1
		fi
	done
fi

## The same for upgrade --write, whose fresh text, the info block added, is
## further over the cap (2026100313461649).
fTest Es2RuBA upgrade-failed-save
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping upgrade-failed-save (POSIX file-size limit)"
	fTestSkip
else
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		rm -rf "${failDir}"; mkdir -p "${failDir}"
		cp "${tmpDir}/migfail.src" "${failDir}/f.shcl"
		rc=0
		(trap '' XFSZ; ulimit -f 1; exec "${cli}" upgrade --write "${failDir}/f.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		if [[ "${rc}" != 8 ]] || grep -q _backup_ "${tmpDir}/err"; then
			echo "cli-regress: upgrade-failed-save [${name}]: exit ${rc}, expected 8 from the save: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		elif ! cmp -s "${failDir}/f.shcl" "${tmpDir}/migfail.src" || [[ -n "$(find "${failDir}" -name '*_backup_*')" ]]; then
			echo "cli-regress: upgrade-failed-save [${name}]: afterwards: $(find "${failDir}" -mindepth 1 -printf '%f ')" >&2; nBad+=1
		fi
	done
fi

## A list in a diagnostic shows its first 3 values and counts the rest
## (20261007 item 13). The H001 hint on a field repeated over 400,000 lines was
## one 3.4 MB stderr line, every run. V004 on an array read as a string printed
## the whole array the same way.
fTest Es9aIMN diag-list-cap
awk 'BEGIN{ for (i = 0; i < 20000; i++) printf "item: v%d\n", i }' > "${tmpDir}/rep20k.shcl"
printf 'field: x\n\ttype: string\n\tallowed: [a]\n' > "${tmpDir}/allowa.shcl"
printf 'x: [p, q, r, s, t]\n' > "${tmpDir}/arr5.shcl"
printf 'x: [p, q, r]\n' > "${tmpDir}/arr3.shcl"
capWant=(
	"rep20k|get ${tmpDir}/rep20k.shcl item|line 20000: Hint: H001 'item' repeats as a bare leaf - did you mean 'item: [v0, v1, v2, ...]'? (and 19997 more)"
	"rep4|check -|line 4: Hint: H001 'x' repeats as a bare leaf - did you mean 'x: [a, b, c, ...]'? (and 1 more)"
	"rep3|check -|line 3: Hint: H001 'x' repeats as a bare leaf - did you mean 'x: [a, b, c]'?"
	"v004-arr5|check --schema=${tmpDir}/allowa.shcl ${tmpDir}/arr5.shcl|line 1: Error: V004 value not allowed at 'x': [p, q, r, ...] (and 2 more)"
	"v004-arr3|check --schema=${tmpDir}/allowa.shcl ${tmpDir}/arr3.shcl|line 1: Error: V004 value not allowed at 'x': [p, q, r]"
)
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	for w in "${capWant[@]}"; do
		IFS='|' read -r what cmd want <<<"${w}"
		read -r -a cmdArgv <<<"${cmd}"
		case "${what}" in
			rep4) stdinText=$'x: a\nx: b\nx: c\nx: d\n' ;;
			rep3) stdinText=$'x: a\nx: b\nx: c\n' ;;
			*)    stdinText="" ;;
		esac
		nRun+=1
		"${cli}" "${cmdArgv[@]}" <<<"${stdinText}" >/dev/null 2>"${tmpDir}/caperr" || true
		got="$(grep -E ' (H001|V004) ' "${tmpDir}/caperr" || true)"
		size="$(wc -c <"${tmpDir}/caperr")"
		if [[ "${got}" != "${want}" ]]; then
			echo "cli-regress: diag-list-cap [${name}]: ${what}: got: $(head -c 200 <<<"${got}")" >&2; nBad+=1
		elif ((size > 1000)); then
			echo "cli-regress: diag-list-cap [${name}]: ${what}: stderr is ${size} bytes" >&2; nBad+=1
		fi
	done
done

## The help text is a column-aligned table sitting at exactly 80 wide, and it is
## hand-duplicated in four CLIs, so one added word wraps it in every terminal at
## once and nothing else here would notice. Only help is checked: about and
## donate include the copyright symbol and the author ID by design, so a byte
## count is not a column count there, and neither is aligned anyway.
maxCols=80
fTest Eq9yPCQ help-width
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	## The narrowed helps and the code table are cut from the same text and make
	## the same 80-column promise, and there are far too many of them to eyeball.
	## Both lists come from the CLI under test, so a new code or subcommand is
	## covered without a second list to keep in step.
	checks=(help --help explain)
	while read -r sub; do
		[[ -n "${sub}" ]] && checks+=("help ${sub}")
	done < <("${cli}" help 2>/dev/null </dev/null | { grep -oE '^  shcl [a-z]+' || true ;} | awk '{print $2}' | sort -u)
	while read -r code; do
		[[ -n "${code}" ]] && checks+=("explain ${code}")
	done < <("${cli}" explain 2>/dev/null </dev/null | { grep -oE '^[EHV][0-9]+' || true ;})
	## Retired codes are not in the listing; the reference's table names them.
	while read -r code; do
		[[ -n "${code}" ]] && checks+=("explain ${code}")
	done < <(sed -n '/^const RETIRED: &str = "/,/^";$/p' "${repoDir}/source/rust/src/main.rs" | { grep -oE '^[EHV][0-9]+' || true ;})
	for cmd in "${checks[@]}"; do
		read -r -a cmdArgv <<<"${cmd}"
		text="$("${cli}" "${cmdArgv[@]}" 2>/dev/null </dev/null || true)"
		nRun+=1
		## explain E023 shows the escape mark, U+25C9, which is one column wide.
		## It stands in as one ASCII byte, so anything else outside ASCII still
		## fails.
		if [[ "${cmd}" == explain* ]]; then text="${text//$'\xe2\x97\x89'/@}"; fi
		if [[ -z "${text}" ]]; then
			echo "cli-regress: help-width [${name}]: ${cmd} printed nothing" >&2; nBad+=1; continue
		fi
		## ASCII first: it is what makes the byte count a column count. One awk
		## for the three checks, since this runs for every help and code.
		while IFS= read -r wide; do
			echo "cli-regress: help-width [${name}]: ${cmd} ${wide}" >&2; nBad+=1
		done < <(LC_ALL=C awk -v m="${maxCols}" '
			/[^ -~]/ { ascii = 1 }
			/\t/ { tab = 1 }
			length($0) > m { print "line " NR " is " length($0) " columns: " substr($0, 1, 40) }
			END { if (ascii) print "is not plain ASCII"; if (tab) print "prints hard tabs" }' <<<"${text}")
	done
done

## Each option names in parentheses the subcommands it belongs to, and three of
## them used to say "all but" a list, so each new subcommand that took none of
## those options joined them unseen - three times over. What a subcommand takes
## is asked of the CLI itself, since an option it does not use is refused as
## "not valid for CMD", and the parentheses have to name exactly that set.
## "(same)", or no parentheses at all, repeats the entry above.
fTest EqM10js option-entries
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	helpText="$("${cli}" help 2>/dev/null </dev/null)"
	## Every option the completions offer must have an entry in the help. The
	## scope check below walks the entries the help prints, so an option with no
	## entry at all was invisible to it - `--write` had none for three rounds
	## (20260918b item 34). The completion table is the list check-completions
	## holds against the CLI's own.
	mapfile -t offered < <(grep -oE "echo '[^']*'" "${repoDir}/source/completions/shcl.bash" | grep -oE '\-\-[a-z0-9-]+' | sort -u)
	((${#offered[@]} >= 10)) || { echo "cli-regress: option-entries [${name}]: only ${#offered[@]} option(s) found in the completions" >&2; nBad+=1; }
	for o in "${offered[@]}"; do
		nRun+=1
		grep -qE "^  ${o}([=,[:space:]]|$)" <<<"${helpText}" || {
			echo "cli-regress: option-entries [${name}]: ${o} is offered by the completions and has no entry in the help" >&2; nBad+=1
		}
	done
done
fTest EqGfz45 option-scopes
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	helpText="$("${cli}" help 2>/dev/null </dev/null)"
	mapfile -t cmds < <(printf '%s\n' "${helpText}" | { grep -oE '^  shcl [a-z]+' || true ;} | awk '{print $2}' | { grep -vxE 'help|about' || true ;} | sort -u)
	nOpts=0
	claim=""
	while IFS=$'\t' read -r spell par; do
		opt="${spell%%=*}"
		if [[ -n "${par}" && "${par}" != "(same"* ]]; then
			claim=""
			for w in ${par//[^a-z]/ }; do
				for c in "${cmds[@]}"; do
					if [[ "${w}" == "${c}" ]]; then claim+="${c} "; fi
				done
			done
			claim="$(tr ' ' '\n' <<<"${claim}" | sort -u | xargs)"
		fi
		probe="${opt}"
		if [[ "${spell}" == *=* ]]; then
			v="${spell#*=}"
			case "${v}" in
				*'|'*) v="${v%%|*}" ;;
				*=*)   v="a=1" ;;
				*)     v="x" ;;
			esac
			probe="${opt}=${v}"
		fi
		takes=""
		for c in "${cmds[@]}"; do
			## Through a file, not a pipe into grep: under pipefail the refusal's
			## own exit 1 would fail the pipe whatever grep found. And matched with
			## a builtin, since this runs once per option per subcommand.
			"${cli}" "${c}" "${probe}" </dev/null >/dev/null 2>"${tmpDir}/said" || true
			said=""; IFS= read -r -d '' said <"${tmpDir}/said" || true
			[[ "${said}" == *"not valid for ${c}"* ]] || takes+="${c} "
		done
		takes="$(tr ' ' '\n' <<<"${takes}" | sort -u | xargs)"
		nOpts=$((nOpts + 1)); nRun+=1
		if [[ "${claim}" != "${takes}" ]]; then
			echo "cli-regress: option-scopes [${name}]: ${opt}: the help names (${claim}), the CLI takes it on (${takes})" >&2; nBad+=1
		fi
	done < <(printf '%s\n' "${helpText}" | awk '
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
	if ((nOpts < 10)); then
		echo "cli-regress: option-scopes [${name}]: only ${nOpts} option(s) found in the help" >&2; nBad+=1
	fi
done

## `help CMD` takes the full help's paragraphs that open with CMD's name. It
## took any line starting with it, so set's paragraph, rewrapped to start a line
## with "fmt writes it.", showed up as fmt's help (20261007 item 7). Every prose
## line in a narrowed help has to come from a paragraph opening with that
## command, and every such paragraph has to be there whole. The usage, type and
## option blocks are cut by their own rules and checked above.
fTest Es9aIKE help-own-paragraphs
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	"${cli}" help </dev/null >"${tmpDir}/fullhelp" 2>/dev/null || true
	## `help help` is the full text.
	mapfile -t cmds < <({ grep -oE '^  shcl [a-z]+' "${tmpDir}/fullhelp" || true ;} | awk '{print $2}' | { grep -vx help || true ;} | sort -u)
	((${#cmds[@]} >= 10)) || { echo "cli-regress: help-own-paragraphs [${name}]: only ${#cmds[@]} subcommand(s) found in the help" >&2; nBad+=1; }
	for c in "${cmds[@]}"; do
		nRun+=1
		"${cli}" help "${c}" </dev/null >"${tmpDir}/cmdhelp" 2>/dev/null || true
		while IFS= read -r stray; do
			echo "cli-regress: help-own-paragraphs [${name}]: help ${c}: ${stray}" >&2; nBad+=1
		done < <(awk -v cmd="${c} " '
			BEGIN { start = 1 }
			FNR == NR {
				if ($0 == "") { start = 1; next }
				if (start) { head = $0; start = 0; n++ }
				if (head ~ /^(shcl - |Usage:|Types \(|Options \()/) next
				owner[$0] = head; para[n] = para[n] $0 "\n"; first[n] = head
				next
			}
			{ got = got $0 "\n" }
			($0 in owner) && index(owner[$0], cmd) != 1 {
				print "line " FNR " is from the paragraph opening \"" substr(owner[$0], 1, 30) "\""
			}
			END {
				for (i = 1; i <= n; i++)
					if (index(first[i], cmd) == 1 && !index(got, para[i]))
						print "leaves out its own paragraph opening \"" substr(first[i], 1, 30) "\""
			}' "${tmpDir}/fullhelp" "${tmpDir}/cmdhelp")
	done
done

## The man page sits next to that help and had nothing holding it to the same
## width; rendered at 80 it already had one 81-column line, from an example
## block nroff does not fill. Rendered rather than read, because the source's
## line lengths are not the page's. The overstrike sequences nroff writes for
## bold come off first, or every emphasized line reads as double its width.
## Only man-db's man takes a file and these options. macOS and the BSDs have
## mandoc instead, and its width option means the same.
manPage="${repoDir}/source/man/shcl.1"
if [[ "$(man --version 2>/dev/null || true)" == "man "[0-9]* ]]; then manCmd=(env MANWIDTH=80 MAN_KEEP_FORMATTING='' man --nh --nj -l)
elif command -v mandoc >/dev/null 2>&1; then manCmd=(mandoc -T ascii -O width=80)
else manCmd=(); fi
fTest EpHH7ZQ man-width
if [[ -f "${manPage}" ]] && ((${#manCmd[@]})); then
	rendered="$("${manCmd[@]}" "${manPage}" 2>/dev/null | sed $'s/.\b//g' || true)"
	nRun+=1
	if [[ -z "${rendered}" ]]; then
		echo "cli-regress: man-width: the page rendered to nothing" >&2; nBad+=1
	else
		while IFS= read -r wide; do
			echo "cli-regress: man-width: line ${wide}" >&2; nBad+=1
		done < <(LC_ALL=C awk -v m="${maxCols}" 'length($0) > m { print NR " is " length($0) " columns: " substr($0, 1, 40) }' <<<"${rendered}")
	fi
else
	##	Under the gate a missing man is a failure, as the /dev/full rows are: this
	##	is the only check holding the page to 80 columns. Git Bash on windows has
	##	no man, which is a fact of the platform rather than a missing tool.
	if [[ -n "${SHCL_GATE_STRICT:-}" && "${onWindows}" == 0 ]]; then
		echo "cli-regress: man-width: no man-db or mandoc here and the gate requires it" >&2; nBad+=1
	fi
	echo "cli-regress: skipping the man page width check (no man-db or mandoc here)"
	fTestSkip
	echo "cli-regress man-width" >> "${SHCL_GATE_SKIPS:-/dev/null}"
fi
fTestEnd

if ((nBad)); then
	echo "cli-regress: ${nBad} of ${nRun} check(s) failed" >&2
	exit 1
fi
echo "cli-regress: OK: ${#rows[@]} row(s) across ${#bindings[@]} binding(s), ${nRun} check(s)"

##	History:
##		2026-08-30  Created, pinning the CLI defects from the 20260829 and
##		            20260830 rounds that no corpus case can express.
##		2026-08-31  Help width, after the help text was found sitting at exactly
##		            80 columns with nothing to fail on.
##		2026-09-08  Man page width, rendered at 80, after the page next to that
##		            help was found with an 81-column example line.
##		2026-09-29  Exact stderr ('=' field), for diagnostic order.
##		2026-10-06  Takes BSD stat and head, and stops with a message when there
##		            is no timeout.
##		2026-10-06  broken-pipe, migrate-taken and man-width run on BSD tools.
