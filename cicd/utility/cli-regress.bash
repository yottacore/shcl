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
##		to hold for all four.
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
startDir="${PWD}"

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
## A generator-only `default` the schema cannot spell on a value line: a raw
## block has no inline form, and a `type: raw` field's default goes out inline
## and then fails its own type check. Both used to be dropped or reported as a
## wrong type in the generated output.
printf 'field: b\n\ttype: raw\n\tdefault: hello\n\trequired: yes\n' > "${tmpDir}/rawdef.shcl"
## A `desc` with a comma in it: the value is several elements, and the comment
## used to come out missing rather than carrying the sentence.
printf 'field: a\n\tdesc: one, two\n\trequired: yes\n' > "${tmpDir}/commadesc.shcl"
## A field name carrying a line break, and a flat name carrying a dot. Both used
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
printf 'ns: 5, 20, 3\nfs: 2.0, 0.5, 4.0\n' > "${tmpDir}/outofrange.shcl"
printf '"x.y": 1\n' > "${tmpDir}/dotname.shcl"
## Schema paths and a type carrying a line break. Every code that names schema
## text printed it raw, so one diagnostic arrived as two stderr lines.
printf 'field: "a.\\"x\\ny\\""\n\trequired: yes\nfield: "b.\\"x\\ny\\""\n\ttype: int\n\tmin: 5\n\tmax: 6\n\tallowed: 5, 6, 1\n\trepeat: 3\nfield: "c.\\"x\\ny\\""\n\ttype: bool\n' > "${tmpDir}/nlschema.shcl"
printf 'b:\n\t"x\\ny": 9\n\t"x\\ny": 1\nc:\n\t"x\\ny": maybe\n' > "${tmpDir}/nldoc.shcl"
printf 'field: k\n\ttype: "in\\nt"\nfield: "d.\\"x\\ny\\"."\n' > "${tmpDir}/nlfault.shcl"
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
## A raw block against a string `allowed`: the body carries its own newlines, so
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
printf 'field: "srv[#1].port"\n\trequired: yes\n' > "${tmpDir}/idxreq.shcl"
## Two must-exist paths nothing can generate, either side of a field that
## generates fine: the refusal used to stop at the first, so fixing one only
## bought the next one's message.
printf 'field: "srv[#1].port"\n\trequired: yes\nfield: "*"\n\ttype: int\n\trepeat: 1\nfield: ok\n\ttype: int\n' > "${tmpDir}/twoblocked.shcl"
## A schema that does not build: the report is the build faults alone, not the
## faults plus what an empty document would owe the schema.
printf 'field: a\n\ttype: int\n\trequired: yes\nfield: b\n\ttype: nope\n' > "${tmpDir}/nobuild.shcl"
## An instance whose discriminator holds an '=', which is what made --set's own
## split ambiguous.
printf 'x[a=b]:\n\tc: 0\n' > "${tmpDir}/sel.shcl"
## An instance whose discriminator holds an apostrophe: ordinary text in a bare
## selector, which the split used to read as an open quote.
printf "srv[O'Brien]:\n\tport: 0\n" > "${tmpDir}/quote.shcl"
## A name a path cannot hold bare, for the traversal commands: enumerating keys
## is only useful if what comes back can be read straight back.
printf 'db:\n\thost: h\n\t"odd.key": 2\nweb:\n\tport: 1\n' > "${tmpDir}/tree.shcl"
## Two plain keys, for the edit options: what each one leaves behind is the
## whole assertion, so the document has to be small enough to spell out.
printf 'a: 1\nb: 2\n' > "${tmpDir}/two.shcl"
## Bracket text on a value line is kept verbatim and binds nothing, so the
## rewrite goes through unchanged. The 2.x selector sugar reads the same way
## now, and the line under it goes with it, so that file refuses to save until
## migrate rewrites it. The sugar file is copied fresh for every run of a row
## that names %W%, since a rewrite is the thing being tested.
printf 'ports: [80, 443]\n' > "${tmpDir}/brarray.shcl"
printf 'srv["1,000"].port: 1\n' > "${tmpDir}/selcomma.shcl"
printf 'base:[Boston]\n\tlat: 42\n' > "${tmpDir}/sugar.shcl"
## A value the two rule sets read differently: 2.x resolved the backslash and
## these rules do not, and the bytes are the same either way, so a rewrite that
## guesses damages whichever file it guessed wrong about. Copied fresh for the
## rows that rewrite, the way the sugar file is.
printf 'p: %s\n' "'C:\temp'" > "${tmpDir}/bsrc.shcl"
## An escaped comma 2.x folded into one element, so migrate re-spells the line,
## plus an empty element the load drops. The rewrite is refused, which is what
## --check has to say rather than counting the line it would have changed.
printf 'list: a\\,b, c\nother:\n  * \n' > "${tmpDir}/mlost.shcl"
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
printf 'p: %s\nnote:\n\t```\n##    Format   2\n\t```\n' "'C:\temp'" > "${tmpDir}/rawfmt2.shcl"
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
## A Format line of five thousand digits: no format will carry that number, and
## CPython refuses an int() past 4300 digits, so Python raised where the other
## three read it as this major and said there was nothing to migrate.
{ printf 'p: 1\n##    Format   '; printf '9%.0s' $(seq 5000); printf '\n'; } > "${tmpDir}/bigfmt.shcl"
## An older Format line with migrate's own stamp after it, so the first line
## found is the older one.
printf 'a: 1\n##    Format   0\n##    Format   3\n' > "${tmpDir}/twostamps.shcl"
## A default on a path whose last segment selects by value. A value after that
## selector is ignored, so generation used to write a line that failed its own
## check. One default contradicts the selector and one names it.
printf 'field: "a[b]"\n\trequired: yes\n\tdefault: hello\n' > "${tmpDir}/seldefbad.shcl"
## A schema naming a path the two-error file does not have, so validation has
## something to say that the parse does not.
printf 'field: zz\n\trequired: yes\n' > "${tmpDir}/missreq.shcl"
## Two instances whose values hold a real line break, and one plain value, so a
## listing that spans lines can be told from one that does not. Then an array
## and a scalar each holding one, for get.
printf 'srv: "a\\nb"\nsrv: "c\\nd"\nplain: x.y\narr: "a\\nb", c\none: "x\\ny"\n' > "${tmpDir}/nlvalue.shcl"
printf 'field: "a[b]"\n\trequired: yes\n\tdefault: b\n' > "${tmpDir}/seldefok.shcl"
## An optional field's line is commented, so the self-check never read its
## default. The second schema must still pass, since each line works alone;
## checked all at once, srv and srv.port make two srv against a repeat of 1.
printf 'field: port\n\ttype: int\n\tmax: 10\n\tdefault: 99\n' > "${tmpDir}/optdefbad.shcl"
printf 'field: srv\n\trepeat: 0, 1\n\tdefault: web\nfield: srv.port\n\ttype: int\n\tdefault: 80\nfield: "a[b]"\n\tdefault: c\n' > "${tmpDir}/optdefok.shcl"
## An optional field whose default names another instance than its path
## selects. Its line is commented, so the check only looked at the value.
## The second schema is the optdefok one with `a[b]` defaulting to `b`, which
## is what that one now has to say to pass.
printf 'field: env[prod]\n\tdefault: staging\n' > "${tmpDir}/optselbad.shcl"
printf 'field: srv\n\trepeat: 0, 1\n\tdefault: web\nfield: srv.port\n\ttype: int\n\tdefault: 80\nfield: "a[b]"\n\tdefault: b\n' > "${tmpDir}/optdefok2.shcl"
## An optional line with no default was never read back, so a selector whose
## value breaks the field's type went out commented at exit 0. And a valued
## parent whose array default holds a `]` has no selector a child can use.
printf 'field: "flag[on]"\n\ttype: int\n' > "${tmpDir}/optnodef.shcl"
printf 'field: tags\n\trequired: yes\n\tdefault: "a]", c\nfield: tags.x\n\trequired: yes\n' > "${tmpDir}/nosel.shcl"

## A 250-character basename. The temp file used to carry the whole name plus
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
printf 'val: 1\n\t* e\nz: 2\n' > "${tmpDir}/keepelem.shcl"
printf 'x: [1, 2]\n x:\nx.a: 2\n' > "${tmpDir}/keepgap.shcl"
printf 'a:\n\tx: 1\nb:   2\na:\n\ty: 1\n' > "${tmpDir}/keepfold.shcl"
## A schema key nothing knows, on schema line 2.
printf 'field: a\n\tbogus: 1\n' > "${tmpDir}/unkey.shcl"
## A file and a name that both start with a dash, so only `--` makes them data.
## The row that names it runs from inside the temp dir.
printf -- '-h: 7\n' > "${tmpDir}/-dash.shcl"
## A value outside ASCII, for a stdout whose locale cannot spell it.
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
##	%SV% a schema naming a path the two-error file does not have,
##	%NV% two instance values holding a line break beside one plain value,
##	%K% a fresh copy of a file kept by hand, at the path %C% names, %KL% the
##	same for a file whose load drops a line, %KE% one that drops an element
##	under a field with a value, %KG% one that drops a line between two lines
##	of one block, %KF% one whose save cannot keep its lines,
##	%W% a fresh copy of the selector-sugar file, %BS% a fresh copy of a file
##	whose value reads differently under the two rule sets, %BW% a fresh copy of
##	the bracket array, %V3% a file that already names its format,
##	%V3B% the same behind a BOM, %V03% an older Format line and then the
##	current one, %FB% a Format line of five thousand digits, %RF2%/%RF3% a raw body holding a Format line,
##	%ML% a 2.x file migrate rewrites whose migrated text still drops a line,
##	%SB%/%SC% a last-segment selector whose default contradicts it and one
##	whose default names it, %SD%/%SE% an optional field's bad default and
##	optional lines that each pass alone, %SH% an optional field whose default
##	names another instance than its path selects, %SI% the %SE% schema with a
##	default that names its instance, %SJ% an optional selector with no
##	default whose value breaks its type, %SK% a valued parent whose array
##	default has no selector spelling,
##	%C% a path with nothing at it, cleared before every binding's run, %E% an
##	empty argument, %DB% a --default carrying a line break, %LS% a long s
##	(U+017F), which Unicode upper-cases to S,
##	%L% a fresh copy of a file whose basename is 250 characters, %LW% one whose
##	basename is 245 bytes of four-byte characters,
##	%NB% a repeated field name carrying a line break, %DN%/%SN% a flat name
##	carrying a dot and a schema that declares it as nesting, %SL%/%SM% schema
##	paths and a type carrying a line break, valid and faulted, and %DL% a
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
##	PYTHONIOENCODING.
##	stdout and stderr: '-' means unchecked; an empty stdout field means exactly empty.
##	A stderr regex starting with '!' must match NO line.
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
	'EpGigIR|ops-double-cr|set %F%|string\tx\tv\r\r\n|0|a: 1\n\nx: "v\\u000D"\n|-'
	## 20260924 item 7: Windows PowerShell 5.1 puts a BOM in front of text it
	## pipes to a program, and the first op then read as unknown.
	'Er83b6G|ops-leading-bom|set %F%|\xef\xbb\xbfint\tx\t1\n|0|a: 1\n\nx: 1\n|-'
	## 20260830 item 14: Python raised a traceback, C exited nonzero. POSIX-only:
	## the row closes fd 0, and windows has no equivalent a shell can set up.
	'EoTHA7Y|closed-stdin|fmt -|@closedin|0||^$'
	'EoTHA7Z|closed-stdout|fmt %F%|@closedout|0|-|^$'
	## 20260830 item 16: C dropped the line number and the offending op.
	'EoTHA7a|bad-op-unknown|set %F%|bogus\ta\t1\n|1|-|op line 1: unknown op: bogus'
	## 20260925: the banner op takes on or off where other ops take a path.
	'Equbm1a|banner-on-off|set %F%|banner\ton\nbanner\toff\n|0|a: 1\n|-'
	'Equbm1b|banner-bad-value|set %F%|banner\tmaybe\n|1|-|op line 1: bad banner: maybe \(on or off\)$'
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
	'Eolv8m8|init-index-required|init --schema=%S4%|-|6||V097 required path cannot be generated: srv\[#1\].port \(a \[#N\] selector needs an instance'
	## 20260909 item 49: one unwritable path took the whole schema with it and
	## the message said only which path, so the reason and the other blockers
	## were both left to guesswork.
	'EqAwaj2|init-blocked-first|init --schema=%SF%|-|6||V097 required path cannot be generated: srv\[#1\].port \(a \[#N\] selector needs an instance'
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
	'EptVfIP|init-selector-default-contradicts|init --schema=%SB%|-|6||V097 generated value fails the schema that produced it: required path missing: a\[b\]'
	'EptVfIQ|init-selector-default-consistent|init --no-banner --schema=%SC%|-|0|## any, required\na: b\n|-'
	## Loose bug from 20260909 item 5: an optional field's bad default went out
	## commented at exit 0.
	'EpxsEn2|init-optional-bad-default|init --schema=%SD%|-|6||V097 generated value fails the schema that produced it: value above max 10 at .port.: 99'
	## 20260918 item 4: the same for a default that names another instance.
	'EqGXrwW|init-optional-selector-default|init --schema=%SH%|-|6||V097 generated value fails the schema that produced it: default does not name the instance its path selects: env\[prod\]$'
	## Retired 2026-09-17: a commented child of a commented valued parent now
	## selects the parent's default, so the dotted `srv.port` this row expected
	## became two instances once both lines were uncommented. The row below is
	## the same schema and exit code with the new spelling.
	# 'init-optional-defaults-ok|init --no-banner --schema=%SE%|-|0|## any, repeat 0-1\n# srv: web\n\n## int\n# srv.port: 80\n\n## any\n# a: c\n|-'
	## Retired 2026-09-18 by 20260918 item 4: its `a[b]` carried `default: c`,
	## which names another instance than the path selects, and the spec says
	## that fails generation for an optional field too. The row below is the
	## same schema with the default naming `b`.
	# 'init-optional-defaults-ok|init --no-banner --schema=%SE%|-|0|## any, repeat 0-1\n# srv: web\n\n## int\n# srv[web].port: 80\n\n## any\n# a: c\n|-'
	'EqGXrwX|init-optional-defaults-ok-named|init --no-banner --schema=%SI%|-|0|## any, repeat 0-1\n# srv: web\n\n## int\n# srv[web].port: 80\n\n## any\n# a: b\n|-'
	## 20260918b item 26: every commented line is read back, not only one
	## carrying a default. Item 27: no selector spelling is a refusal, not a
	## child under another instance.
	'EqLiw1w|init-optional-no-default-read-back|init --schema=%SJ%|-|6||V097 generated value fails the schema that produced it: wrong type at .flag\[on\].'
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
	'EqGfmq1|explain-e003|explain E003|-|0|\nE003  error       selector names an instance that does not exist\n  a[5].b where there is one a. An index selects an existing instance by\n  position and never creates one, so a binding line should select by value\n  instead. In a file the index is the bare [5], since a # opens a comment.\n\n|-'
	'EqGfmq2|explain-v097|explain V097|-|0|\nV097  error       generated output does not load, or fails its own schema\n  init checks its own output before returning it, so a starter config that\n  would fail its first check is a fault instead. A default outside its\n  field'"'"'s constraints is one cause. A required path nothing can generate is\n  the other, such as one with a [#N] selector or a * name. Line 0.\n\n|-'
	## 20260830 item 35: -h and --help after FILE were an unknown option, though
	## every other option is read there.
	'EoUxXlV|help-after-file|get %F% -h|-|0|-|-'
	'EoUxXlW|help-after-file-long|get %F% --help|-|0|-|-'
	## 20260830 item 47: at the default strictness a recovered-from typo was
	## silent unless --write was passed, so stdout carried the repair with
	## nothing said about it.
	'EoUxXlX|fmt-diags-without-write|fmt %B%|-|0|-|E015 missing colon'
	'EoUxXlY|set-diags-without-write|set --set=a=2 %B%|-|0|-|E015 missing colon'
	## 20260804: given a --set, set takes its edits from the options and leaves
	## stdin alone, or a set run from a terminal would sit waiting on it.
	'Er1zoZE|set-option-skips-stdin|set --set=a=2 %F%|int\tx\t7\n|0|a: 2\n|-'
	## 20260829 item 6: --set split PATH from VALUE at the first '=' anywhere, so
	## a selector holding one could not be addressed at all.
	'EoUxXlZ|set-eq-in-selector|set --set=x[a=b].c=1 %X%|-|0|x[a=b]:\n\tc: 1\n|-'
	## 20260905 item 3: a quote anywhere in the path was read as opening a quoted
	## piece, so an apostrophe in a bare selector left every later '=' looking
	## quoted and the option was refused while get on the same path worked.
	"Ep3OILK|set-quote-in-selector|set --set=srv[O'Brien].port=9 %Q%|-|0|srv[O'Brien]:\n\tport: 9\n|-"
	"Ep3OILL|set-default-quote-in-selector|set --set-default=srv[O'Brien].port=9 %Q%|-|0|srv[O'Brien]:\n\tport: 0\n|-"
	"Ep3OILM|set-quoted-selector-eq|set --set=x[\"k]=v\"].d=2 %X%|-|0|x[a=b]:\n\tc: 0\n\nx: \"k]=v\"\n\td: 2\n|-"
	## set writes back the lines its edits leave alone, printing or in place,
	## where fmt writes the canonical form.
	'EqutO7J|set-keeps-lines|set %K% --set=block.a=2|-|0|# note\nName:   "x"   # c\nblock:\n    a: 2\n|-'
	'EqutO7K|set-write-keeps-lines|set --write %K% --set=block.b=3|-|0|-|-|# note\nName:   "x"   # c\nblock:\n    a: 1\n    b: 3\n'
	'EqutO7L|fmt-write-rewrites-all|fmt --write %K%|-|0|-|-|# note\nname: "x"  # c\nblock:\n\ta: 1\n'
	## A dropped line refuses the write only when the save falls back to
	## canonical. Removing margin would put stray under window, so that one does.
	'EqzUbG4|set-write-keeps-dropped|set --write %KL% --set=font.size=13|-|0|-|E012|font:\n\tsize: 13\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n'
	'EqzUbG5|set-write-fallback-refused|set --write %KL% --remove=window.margin|-|7|-|dropped 1 line|font:\n\tsize: 12\nwindow:\n\t\tmargin: 4\n\tstray: 1\nlast: 1\n'
	## 20260926 item 1: a rewritten line took a dropped line with it at exit
	## 0, an element under a field with a value or an E018 line between two
	## lines of one block.
	'Er7gigM|set-write-keeps-dropped-element|set --write %KE% --set=val=9|-|7|-|dropped 1 line|val: 1\n\t* e\nz: 2\n'
	## 20260926 idea 2: a save meant to keep the lines that rewrote the whole
	## file said nothing.
	'Er8Ivln|set-write-says-canonical|set --write %KF% --set=b=3|-|0|-|rewritten in the canonical form|a:\n\tx: 1\n\ty: 1\nb: 3\n'
	'Er7gihi|set-write-keeps-dropped-between|set --write %KG% --set=x=v|-|7|-|dropped 1 line|x: [1, 2]\n x:\nx.a: 2\n'
	"Ep3OILN|set-open-quote-refused|set --set=a[\"open=1 %X%|-|1|-|bad --set value"
	## 20260909 item 13: a value built by a setter or a selector read as
	## unquoted, so quoted thousands were BadType until a save and reload.
	'EpykNRw|set-quoted-thousands|get --int --set=a=1,000 %F% a|-|0|1000\n|-'
	"EpykNRx|set-selector-thousands|get --int --set=x[\"1,000\"].y=1 %F% x|-|0|1000\n|-"
	'EpykNRy|selector-thousands|get --int %SQ% srv|-|0|1000\n|-'
	## 3.0: bracket text after the colon is one outcome, kept verbatim. The
	## 2.x selector sugar is that shape now too, and migrate is what carries
	## a file written with it across.
	## One diagnostic is one line, and a name is spelled the way the emitter
	## would write it. A line break in a name used to split one hint across
	## three stderr lines, and a flat `x.y` printed the same as `x` nesting `y`.
	'Eq4AfLV|diag-name-line-break|check %NB%|-|0|line 2: Hint: H001\nok (1 diagnostic(s))\n|^line 2: Hint: H001 ."a\\nb". repeats'
	## The value half of the same rule: the H001 hint splices the repeated
	## values into its suggestion, and a value carrying a line break used to go
	## in raw, so the hint arrived as four stderr lines.
	'EqTPxzc|diag-value-line-break|check %NV%|-|0|line 2: Hint: H001\nok (1 diagnostic(s))\n|^line 2: Hint: H001 .srv. repeats as a bare leaf - did you mean .srv: "a\\nb", "c\\nd".\?$'
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
	'Ep3QaNl|bracket-array-check|check %BA%|-|6|line 1: Error: E019\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'EpFkZy7|bracket-array-write-kept|fmt --write %BA%|-|0||-'
	'Ep3QaNm|sugar-check|check %W%|-|6|line 1: Error: E019\nline 2: Error: E018\nfailed: 2 diagnostic(s), 2 error(s)\n|-'
	'Ep3QaNn|sugar-check-strict|check --strictness=strict %W%|-|6|-|-'
	'EpFkZy8|sugar-write-refused|fmt --write %W%|-|7|-|dropped 1 line'
	'EpFkZy9|sugar-migrate|migrate %W%|-|0|base: Boston\n\tlat: 42\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	'EpFkZyA|sugar-migrate-write|migrate --write %W%|-|0||-'
	## An unknown escape in double quotes is refused and kept as written, not
	## read with the pair kept after its `\n` already turned into a newline.
	'Er1adAn|escape-unknown-check|check -|a: "C:\\work\\new"\n|6|line 1: Error: E023\nfailed: 1 diagnostic(s), 1 error(s)\n|E023 unknown escape .\\w. in double quotes; write a backslash as .\\\\. or use single quotes$'
	'Er1adAo|escape-unknown-read|get - a|a: "C:\\work"\n|3|\n|no value at that path'
	'Er1adAp|escape-unknown-literal|set %F2%|literal\tx\t"C:\\work"\n|1||^op line 1: cannot write x'
	'Er1adAq|escape-unknown-path|get - "a\w"|"a\\\\w": 1\n|3|\n|no value at that path'
	'Er1adAr|escape-doubled-path|get - "a\\w"|"a\\\\w": 1\n|0|1\n|-'
	## \u and \U name a character by its code point, and one that names none is
	## E023. Canonical output spells an invisible character as one. 2.x kept the
	## pair as written, so migrate needs to be told which rules wrote the file.
	'Er2qNPd|escape-unicode-read|get - a|a: "caf\\u00E9 \\U0001F600"\n|0|caf\u00E9 \U0001F600\n|-'
	'Er2qNPe|escape-unicode-bad|check -|a: "\\uD800"\n|6|line 1: Error: E023\nfailed: 1 diagnostic(s), 1 error(s)\n|E023 bad escape .\\u. in double quotes'
	'Er2qNPf|escape-unicode-fmt|fmt -|a: x\u200By\n|0|a: "x\\u200By"\n|-'
	'Er2qNPg|escape-unicode-name|paths -|"a\\u202Eb": 1\n|0|"a\\u202Eb"\n|-'
	'Er2qNPh|escape-unicode-migrate-refused|migrate -|q: "\\u0041"\n|7|q: "\\u0041"\n|does not say which it was written for'
	'Er2qNPi|escape-unicode-migrate-2x|migrate --from-2x -|q: "\\u0041"\n|0|q: "\\\\u0041"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## A path in double quotes whose escapes are all real still reads and saves
	## as written. The hint says so and changes nothing else.
	'Er1iG7N|path-hint-read|get - a|a: "C:\\temp"\n|0|C:\temp\n|H004 value looks like a Windows path'
	'Er1iG7O|path-hint-strict|check --strictness=strict -|a: "C:\\temp"\n|0|line 1: Hint: H004\nok (1 diagnostic(s))\n|-'
	'Er1iG7P|path-hint-set|set - --set b=1|a: "C:\\temp"\n|0|a: "C:\\temp"\n\nb: 1\n|-'
	'Er1adAs|escape-unknown-migrate|migrate -|q: "C:\\work"\n|0|q: "C:\\\\work"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## 20260909 item 4: a 3.0 file spells a backslash value the same way a 2.x
	## one does, so migrating on a guess changed a correct file at exit 0. The
	## file has to say which rules wrote it, or the caller has to.
	## Durations and sizes print whole milliseconds and bytes. --unit gives a bare
	## number its unit, --decimal makes KB to TB powers of 1000, and each is
	## refused where it cannot mean anything.
	'Er35Y6E|duration-read|get --duration - t|t: 1h 30m\n|0|5400000\n|-'
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
	## A Schema line names the schema check uses when --schema is not given,
	## read from the config file's directory. A URL is left to editors.
	'Er2thhx|schema-line-check|check %SP%|-|6|line 2: Error: V003\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'Er2thhy|schema-line-url|check %SPU%|-|0|ok (0 diagnostic(s))\n|does not fetch'
	'Er2thhz|schema-line-gone|check %SPG%|-|8||gone\.schema\.shcl'
	'Er2thi0|schema-line-overridden|check --schema=%SPS% %SPU%|-|6|line 2: Error: V003\nfailed: 1 diagnostic(s), 1 error(s)\n|-'
	'Eq4Rkv2|migrate-ambiguous-refused|migrate %BS%|-|7|-|does not say which it was written for'
	"Eq4Rkv3|migrate-ambiguous-kept|migrate %BS%|-|7|p: 'C:\\\\temp'\n|-"
	'Eq4Rkv4|migrate-ambiguous-write-refused|migrate --write %BS%|-|7|-|refusing to rewrite'
	'Eq4Rkv5|migrate-from-2x|migrate --from-2x %BS%|-|0|p: "C:\\temp"\n##    Format   3\n##    Migrated from SHCL 2.x.\n|-'
	## A file that names its format has nothing to migrate, which is what stops
	## the second run from rewriting the first run's output.
	'Eq4Rkv6|migrate-stamped-noop|migrate %V3%|-|0|p: 1\n##    Format   3\n|nothing to migrate'
	## 20260918 item 1: the version scan read raw bodies the rewrite skips.
	'EqGUXeC|migrate-format-in-raw-old|migrate %RF2%|-|7|-|does not say which it was written for'
	'EqGUXeD|migrate-format-in-raw-new|migrate %RF3%|-|7|-|does not say which it was written for'
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
	## 20260909 item 41: telling a file that needs migrating from one that does
	## not took a diff of the output, and --write said nothing either way.
	'Eq4wD3Y|migrate-check-names|migrate --check %W%|-|6||w\.shcl:1: migrate would rewrite this line'
	## 20260918b item 54: fmt --check, migrate --check's sibling.
	'EqMO8f3|fmt-check-noncanonical|fmt --check %NC%|-|6||noncanon\.shcl: not canonical; fmt --write would rewrite it'
	'EqMO8f4|fmt-check-canonical|fmt --check %F%|-|0||!.'
	'EqMO8f5|fmt-check-write|fmt --check --write %NC%|-|1|-|--check cannot be combined with --write'
	## 20260920 item 1: --check promised a rewrite --write then refused. The
	## sugar file's --write row two dozen lines up is the other half of the pair.
	'EqQSqyX|fmt-check-refused|fmt --check %W%|-|7||fmt --write would refuse: the load dropped 1 line'
	'EqQSqyY|migrate-check-refused|migrate --check %ML%|-|7||migrate --write would refuse: the migrated text drops 1 line'
	'EqQSqyZ|migrate-write-refused-lost|migrate --write %ML%|-|7|-|refusing to rewrite: the migrated text drops 1 line'
	## 20260918b item 55: a created file says so, since nothing else does.
	'EqMO8f6|create-says|set --write --no-banner %C% --set=a=1|-|0|-|created\.shcl: created|a: 1\n'
	'EqMO8f7|write-existing-quiet|fmt --write %W%|-|7|-|!created'
	'Eq4wD3Z|migrate-check-clean|migrate --check %F%|-|0||!.'
	'Eq4wD3a|migrate-check-stamped|migrate --check %V3%|-|0||nothing to migrate'
	'Eq4wD3b|migrate-check-ambiguous|migrate --check %BS%|-|7||does not say which it was written for'
	'Eq4wD3c|migrate-check-from-2x|migrate --check --from-2x %BS%|-|6||bs\.shcl:1: migrate would rewrite'
	'Eq4wD3d|migrate-check-write|migrate --check --write %W%|-|1|-|--check cannot be combined with --write'
	'Eq4wD3e|migrate-write-says|migrate --write %W%|-|0||migrated, 1 line\(s\) rewritten'
	## The kept original, named. The save cases below check the file itself,
	## but they are POSIX fixtures, so this is the one windows runs.
	'Er5qICu|migrate-write-keeps|migrate --write %W%|-|0||migrated, 1 line\(s\) rewritten; the original is .*w_old_v2\.shcl$'
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
	'EpFkZyD|tokens-fault|tokens %B%|-|0|1:0 name=0-1 sep=1 value=3-4 elem=3-4\n2:2 name=0-3\n3:0 name=0-1 fault=2:unexpected character after the path\n|-'
	## 20260923 item 20: the help and man page say each line is read on its own,
	## so a raw body line comes out as a field line.
	## 20260923 item 12: a `*` with only a blank after it is an empty element
	## to the parser (E009), and tokens called it a name fault.
	'Er84S7X|tokens-star-trailing-blank|tokens -|a:\n\t* \n\t*\t\n\t*\n|0|1:0 name=0-1 sep=1 value=2-2 elem=2-2\n2:1 star value=1-1 elem=1-1\n3:1 star value=1-1 elem=1-1\n4:1 fault=0:expected a field name\n|-'
	'EqjsQiv|tokens-raw-body|tokens %R%|-|0|1:0 name=0-1 sep=1 value=2-2 elem=2-2\n2:1 fence value=0-3 elem=0-3\n3:1 name=0-4 fault=5:unexpected character after the path\n4:1 name=0-4 fault=5:unexpected character after the path\n5:1 fence value=0-3 elem=0-3\n|-'
	## 20260830b item 18: a read below strict returned the value and said nothing
	## about a line the load had dropped, so a damaged file read clean at exit 0.
	'EoXBb4q|get-diags|get %B% a|-|0|1\n|E015 missing colon'
	'EoXBb4r|count-diags|count %B% a|-|0|1\n|E015 missing colon'
	'EoXBb4s|instances-diags|instances %B% a|-|0|1\n|E015 missing colon'
	## 20260920b item 26: a value holding a line break printed across two lines,
	## so `instances` gave four lines where `count` said two. Only such a value
	## is escaped; a plain one with a dot in it comes out as written.
	'EqT42DB|instances-one-per-line|instances %NV% srv|-|0|"a\\nb"\n"c\\nd"\n|-'
	'EqT42DC|instances-plain-unescaped|instances %NV% plain|-|0|x.y\n|-'
	## 20260923 item 4: the same for get's array and slot listings, one line per
	## element. A plain scalar read is the whole output, so it stays as it is.
	'EqnwIkU|get-array-one-per-line|get --array %NV% arr|-|0|"a\\nb"\nc\n|-'
	'EqnwIkV|get-slots-one-per-line|get --array --slots %NV% arr|-|0|Good\t"a\\nb"\nGood\tc\n|-'
	'EqnwIkW|get-slots-scalar-escaped|get --slots %NV% one|-|0|Good\t"x\\ny"\n|-'
	'EqnwIkX|get-scalar-unescaped|get %NV% one|-|0|x\ny\n|-'
	'EqoRWES|get-array-default-missing|get --array %DB% %NV% nope|-|0|"q\\nr"\n|-'
	'EqoRWET|get-array-default-slots|get --array --int %DB% %NV% arr|-|0|"q\\nr"\n"q\\nr"\n|-'
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
	'EoXIc2f|usage-bad-write-path|set --set=a[*]=1 %F%|-|1|-|wildcard path cannot be written'
	## 20260830b item 21: removal and the set-if-absent family had no option
	## form, so a one-key edit meant a printf with a literal tab piped into set.
	## The five spellings share one ordered list, so the last one on a path wins.
	'EoXHUqG|remove-option|set --remove=b %F2%|-|0|a: 1\n|-'
	'EoXHUqH|set-default-absent|set --set-default=c=3 %F2%|-|0|a: 1\nb: 2\n\nc: 3\n|-'
	'EoXHUqI|set-default-present|set --set-default=a=9 %F2%|-|0|a: 1\nb: 2\n|-'
	'EoXHUqJ|set-literal-default|set --set-literal-default=p=1,2 %F2%|-|0|a: 1\nb: 2\n\np: 1, 2\n|-'
	'EoXHUqK|set-family-order|set --set=a=5 --remove=a %F2%|-|0|b: 2\n|-'
	'EoXHUqL|remove-ephemeral|get --remove=a %F2% a|-|3|-|-'
	'EoXHUqM|remove-write-refused|fmt --write --remove=a %F2%|-|1|-|cannot be combined with --remove'
	'EoXHUqN|remove-empty-path|set --remove= %F2%|-|1|-|bad --remove value'
	##	20260923 idea 2: a path that can never parse was taken as a miss and
	##	exited 0. It is refused now, while a missing path or a wildcard still
	##	removes nothing at exit 0. The ops script's remove and clear-comments
	##	refuse the same way.
	'EqvZOh6|remove-bad-path|set --remove=b[ %F2%|-|1||^bad --remove value \(not a usable path\): b\[ \(see --help\)$'
	'EqvZOh7|remove-value-in-path|set --remove=a:1 %F2%|-|1||^bad --remove value \(not a usable path\): a:1 \(see --help\)$'
	'EqvZOh8|remove-bad-path-on-get|get --remove=a..b %F2% a|-|1||^bad --remove value \(not a usable path\)'
	'EqvZOh9|remove-missing-ok|set --remove=nope %F2%|-|0|a: 1\nb: 2\n|-'
	'EqvZOhA|remove-wildcard-ok|set --remove=a.* %F2%|-|0|a: 1\nb: 2\n|-'
	'EqvZOhB|ops-remove-bad-path|set %F2%|remove\tb[|1||^op line 1: cannot remove b\[: not a usable path$'
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
	'Eon9YY5|single-file-diags-unnamed|fmt %B%|-|0|-|^line 3: Error: E014'
	## 20260909 item 34: E014 says where on the line the path went wrong, as
	## a byte column, which the tokenizer computed and the message dropped.
	'Eq8GC80|e014-column|check %B%|-|6|-|^line 3: Error: E014 malformed line skipped: unexpected character after the path, at column 3$'
	'Eq8GC81|e014-column-bytes|check %CB%|-|6|-|^line 2: Error: E014 malformed line skipped: unexpected character after the path, at column 7$'
	## 20260918 item 15: the blank run between the indent and the text counts.
	'EqGawtE|e014-column-cr-lead|check %CR%|-|6|-|E014 .*, at column 5$'
	## 20260901b item 26: a strict failure in a lower layer ends the fold there,
	## and says which layer it was.
	'EonFb9s|layer-strict-names-the-layer|fmt --strictness=strict --layer=%B% %B2%|-|6|-|bad.shcl line 2: Error: E015'
	'EqLcx3x|layer-strict-names-the-layer-set|set --set=q=1 --strictness=strict --layer=%B% %B2%|-|6|-|bad.shcl line 2: Error: E015'
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
	'EqBBQ57|ops-raw-bad-body|set %F%|raw\tk\tc\tbody\r\\nmore\n|1|-|the block body has no spelling that reads back'
	'EomzUyo|ops-extra-fields-int|set %F%|int\tk\t1\textra\n|1|-|int takes 3 tab-separated'
	'EomzUyp|ops-array-takes-any|set %F%|int-array\tk\t1\t2\t3\n|0|a: 1\n\nk: 1, 2, 3\n|-'
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
	'Er1zoZH|onbad-error-names-value|get --int --on-bad=error - a|a: 12 cats\n|4||^cannot read a as int: value "12 cats" is not a valid int \(in -\)$'
	'Er1zoZI|bad-int-raw-one-line|get --int %R% b|-|4|0\n|^cannot read b as int: value "line one\\nline two" is not a valid int \(in [^)]*rawval\.shcl\)$'
	'EqSNyFl|default-clash|get --int --default=7 --default=8 %F% nope|-|1|-|^--default=7 cannot be combined with --default=8 \(see --help\)$'
	'EqSNyFm|default-repeat-ok|get --int --default=7 --default=7 %F% nope|-|0|7\n|-'
	'EqSNyFn|schema-clash|check --schema=%S% --schema=%S2% %F%|-|1|-|^--schema=.* cannot be combined with --schema=.* \(see --help\)$'
	'EqSNyFo|layer-repeats|get --int --layer=%F% --layer=%F% %F% a|-|0|1\n|-'
	'EqSNyFp|set-repeats-last-wins|get --int --set=a=1 --set=a=2 %F% a|-|0|2\n|-'
	## 20260902 item 15: a refused edit returned before the load's diagnostics
	## were printed, so a damaged file said nothing about the damage.
	'EoloRK4|refused-set-still-reports|get --set=a[*]=1 %B% a|-|1|-|E015 missing colon'
	'EoloRK5|refused-op-still-reports|set %B%|int\ta[*]\t1\n|1|-|E015 missing colon'
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
	## Found working 20260830b item 18: a merge does not carry diagnostics, so
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
	## the float row pins that the bound is spelled the way the annotation line
	## spells it, so `min: 1.0` reads as 1.
	'EqAaU1B|range-max-names-value|check --schema=%SG% %DG%|-|6|line 1: Error: V006\nline 2: Error: V005\nfailed: 2 diagnostic(s), 2 error(s)\n|V006 value above max 10 at .ns.: 20$'
	'EqAaU1C|range-min-names-bound|check --schema=%SG% %DG%|-|6|-|V005 value below min 1 at .fs.: 0\.5$'
	## 20260802 item 12: the whole command line was scanned for help and version
	## flags, so a value spelled like one printed the help at exit 0.
	'EqzuLVo|help-flag-as-default|get --default -h %F% nope|-|0|-h\n|-'
	'EqzuLVp|version-flag-as-default|get --default --version %F% nope|-|0|--version\n|-'
	## 20260923 item 17: the word forms ignored whatever came after them. An
	## option a command does not use is a usage error; the flags still work
	## anywhere.
	'Er863PI|version-word-refuses-extra|version --int|-|1||^usage: shcl version '
	'Er863Qj|about-word-refuses-extra|about extra|-|1||^usage: shcl about '
	'Er863S3|donate-word-refuses-extra|donate --int|-|1||^usage: shcl donate '
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
	argv="${argv//%V3B%/${tmpDir}/bomstamped.shcl}"
	argv="${argv//%V03%/${tmpDir}/twostamps.shcl}"
	argv="${argv//%FB%/${tmpDir}/bigfmt.shcl}"
	argv="${argv//%RF2%/${tmpDir}/rawfmt2.shcl}"
	argv="${argv//%RF3%/${tmpDir}/rawfmt3.shcl}"
	argv="${argv//%ML%/${tmpDir}/mlost.shcl}"
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
	## a closed stdout is an invalid handle each runtime spells its own way, so
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
	if [[ "${onWindows}" == 1 && ( "${stdinSpec}" == @full* || "${stdinSpec}" == @closedout || "${stdinSpec}" == @appear || "${stdinSpec}" == @change || "${argv}" == *%XF%* ) ]]; then
		echo "cli-regress: skipping ${id} (POSIX fixture; not judged on windows)"
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
		## migrate --write keeps the original beside the file, and refuses when a
		## copy from the last binding's run is still there.
		rm -f "${tmpDir}/w_old_v2.shcl" "${tmpDir}/bs_old_v2.shcl" "${tmpDir}/bw_old_v2.shcl"
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
		if [[ -n "${runIn}" ]]; then cli="$(realpath -- "${cli}")"; cd -- "${runIn}"; fi
		rc=0
		case "${stdinSpec}" in
			@closedin)  timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" 0<&- || rc=$? ;;
			@closedout) timeout "${rowSecs}" "${cli}" "${args[@]}" 2>"${tmpDir}/err" >&- || rc=$?; : >"${tmpDir}/out" ;;
			@fullout)   timeout "${rowSecs}" "${cli}" "${args[@]}" 2>"${tmpDir}/err" >/dev/full || rc=$?; : >"${tmpDir}/out" ;;
			@fullerr)   timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>/dev/full || rc=$?; : >"${tmpDir}/err" ;;
			-)          timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$? ;;
			@asciilocale) PYTHONIOENCODING=ascii LC_ALL=C timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" </dev/null || rc=$? ;;
			## The file turns up while the command waits on stdin: after its
			## notice and before the ops, so the create has already been decided.
			## @change: the file is there first and changes during the wait.
			@appear|@change)
				[[ "${stdinSpec}" == @change ]] && printf 'a: 1\n' >"${tmpDir}/created.shcl"
				rm -f "${tmpDir}/in.fifo"; mkfifo "${tmpDir}/in.fifo"
				timeout "${rowSecs}" "${cli}" "${args[@]}" >"${tmpDir}/out" 2>"${tmpDir}/err" <"${tmpDir}/in.fifo" &
				appearPid=$!
				exec {fifoFd}>"${tmpDir}/in.fifo"
				for ((w = 0; w < 200; w++)); do
					grep -q 'reading write-ops' "${tmpDir}/err" && break
					sleep 0.05
				done
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
			## The stdin notice is a prompt, not a diagnostic; it is not what a row is about.
			gotErr="$(grep -v 'reading write-ops from stdin' "${tmpDir}/err" || true)"
			if [[ "${wantErr}" == !* ]]; then
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
## row loop drops the stdin notice from stderr, so it is checked here.
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
fTest EqzuLW2 set-stdin-notice
for b in "${bindings[@]}"; do
	name="${b%%|*}"; cli="${b#*|}"
	rc=0; "${cli}" set "${tmpDir}/ok.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null || rc=$?
	nRun+=1
	gotErr=""; IFS= read -r -d '' gotErr <"${tmpDir}/err" || true
	if [[ "${rc}" != 0 || "${gotErr}" != $'shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)\n' ]]; then
		echo "cli-regress: set-stdin-notice [${name}]: exit ${rc}, stderr ${gotErr@Q}" >&2; nBad+=1
	fi
done

## 20260716 item 25: a reader that leaves early got three exit codes, 134 from
## the reference's abort, 141 from Go and 0 from Python. Settled as dying of
## SIGPIPE the way cat and head do, with nothing on stderr. The document has to
## outlast the pipe buffer, or the write is done before the reader goes. An
## ignored SIGPIPE carries through exec and would let Go and C exit quietly, so
## the default goes back on first. Not a closed stdout: that is EBADF, and the
## closed-stdout row above already pins it.
awk 'BEGIN{ for (i = 0; i < 40000; i++) printf "k%d: %d\n", i, i }' > "${tmpDir}/big.shcl"
fTest EqzuLW3 broken-pipe
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping broken-pipe (POSIX signal; not judged on windows)"
	fTestSkip
else
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		##	The status is kept from inside the pipeline: under pipefail a 141 there
		##	would end this script, and the || that stops that also resets PIPESTATUS.
		{ rc=0; env --default-signal=PIPE "${cli}" fmt "${tmpDir}/big.shcl" 2>"${tmpDir}/err" </dev/null || rc=$?; echo "${rc}" >"${tmpDir}/rc"; } | head -c1 >/dev/null
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

## 20260716 item 26: the C CLI's own allocations went unchecked, so running out
## of memory was a segfault where the library's path exits 70. Two inputs under
## an address-space cap: one too big to read, which is the CLI's own buffer, and
## the pipe document above, which reads in about a megabyte and parses in over
## twenty, which is the library handing back NULL. The first is sparse and costs
## no disk. Only the C CLI makes this promise, and ulimit -v is POSIX.
fOom(){
	local doc="$1"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		[[ "${name}" == c ]] || continue
		rc=0
		(ulimit -v 12288; exec "${cli}" fmt "${tmpDir}/${doc}.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
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

## What a save does with each thing it can find at the path, one case per row of
## the Save outcomes table in design.md, which is the rule. A FIFO, a link whose
## text names a directory and a clean of `lnk/..` were each a site fix away from
## the last one (20260918b items 3, 17 and 18). Each binding gets a fresh
## directory, since the save is what is under test, and a timeout, since the old
## code blocked reading a FIFO. POSIX fixtures: links and FIFOs.
saveDir="${tmpDir}/save"
## A group the caller is in that is not its own, for the group-carry case. A
## runner with one group has nothing to tell apart, so the case drops out.
altGroup="$(id -Gn | tr ' ' '\n' | grep -vx "$(id -gn)" | head -1 || true)"
fSaveSetup() {
	case "$1" in
		regular)  printf 'a: 1\n' > f.shcl ;;
		same)     printf 'a: 1\n' > f.shcl; stat -c %i f.shcl > ino ;;
		differs)  printf 'a:   1\n' > f.shcl; stat -c %i f.shcl > ino ;;
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
		migrate)  printf 'base:[Boston]\n\tlat: 42\n' > f.shcl; chmod 0640 f.shcl ;;
		migrate-taken) printf 'base:[Boston]\n' > f.shcl; printf 'x\n' > f_old_v2.shcl ;;
		migrate-stamp) printf 'a: 1\n' > f.shcl ;;
		migrate-dotname) printf 'base:[Boston]\n' > .f ;;
		migrate-dotdir) mkdir d.x; printf 'base:[Boston]\n' > d.x/f ;;
		migrate-link) mkdir real; printf 'base:[Boston]\n' > real/c.shcl; ln -s real/c.shcl f.shcl ;;
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
	'EqMO8f8|same|fmt --write f.shcl|0|[[ "$(stat -c %i f.shcl)" == "$(cat ino)" ]]'
	'EqMO8f9|differs|fmt --write f.shcl|0|[[ "$(stat -c %i f.shcl)" != "$(cat ino)" ]] && grep -qx "a: 1" f.shcl'
	## 20260918b item 57: the group comes over with the mode, so a config a
	## service reads by group keeps that read.
	'EqMO8fA|group|fmt --write f.shcl|0|[[ "$(stat -c %G f.shcl)" == "${altGroup}" && "$(stat -c %a f.shcl)" == 640 ]]'
	## migrate --write ends with the new file and the original beside it, at the
	## original's mode. An earlier copy is never written over, and a file that
	## only gains the Format line gets no copy.
	'Er5ivua|migrate|migrate --write f.shcl|0|grep -qx "base: Boston" f.shcl && cmp -s f_old_v2.shcl <(printf "base:[Boston]\n\tlat: 42\n") && [[ "$(stat -c %a f_old_v2.shcl)" == 640 ]]'
	'Er5ivub|migrate-taken|migrate --write f.shcl|8|grep -qx "base:\[Boston\]" f.shcl && [[ "$(cat f_old_v2.shcl)" == x && "$(ls -A | wc -l)" == 2 ]]'
	'Er5ivuc|migrate-stamp|migrate --write f.shcl|0|[[ "$(ls -A)" == f.shcl ]]'
	'Er5ivud|migrate-dotname|migrate --write .f|0|[[ -f .f_old_v2 ]]'
	'Er5ivue|migrate-dotdir|migrate --write d.x/f|0|[[ -f d.x/f_old_v2 ]]'
	## Through a link: the target gets the new text, and the copy sits beside
	## the link as a plain file.
	'Er5qICv|migrate-link|migrate --write f.shcl|0|[[ -L f.shcl && -f f_old_v2.shcl && ! -L f_old_v2.shcl && ! -e real/c_old_v2.shcl ]] && grep -qx "base: Boston" real/c.shcl && grep -qx "base:\[Boston\]" f_old_v2.shcl'
)
if [[ -z "${altGroup}" ]]; then
	echo "cli-regress: skipping the save-group case (the caller is in one group only)"
fi
if [[ "${onWindows}" == 1 ]]; then
	echo "cli-regress: skipping the save-target cases (POSIX fixtures; not judged on windows)"
fi
for sc in "${saveCases[@]}"; do
	IFS='|' read -r tid id argv wantRc holds <<<"${sc}"
	fTest "${tid}" "save-${id}"
	if [[ "${onWindows}" == 1 || ( "${id}" == group && -z "${altGroup}" ) ]]; then
		fTestSkip; continue
	fi
	read -r -a args <<<"${argv}"
	for b in "${bindings[@]}"; do
		## Absolute, since the run is from inside the fixture directory.
		name="${b%%|*}"; cli="$(realpath -- "${b#*|}")"
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
	printf 'base:[Boston]\n%s\n' "${pad}" > "${tmpDir}/migfail.src"
	for b in "${bindings[@]}"; do
		name="${b%%|*}"; cli="${b#*|}"
		rm -rf "${failDir}"; mkdir -p "${failDir}"
		cp "${tmpDir}/migfail.src" "${failDir}/f.shcl"
		rc=0
		(trap '' XFSZ; ulimit -f 1; exec "${cli}" migrate --write "${failDir}/f.shcl" >/dev/null 2>"${tmpDir}/err" </dev/null) || rc=$?
		nRun+=1
		## An error naming the copy means the cap broke the copy, not the save.
		if [[ "${rc}" != 8 ]] || grep -q _old_v2 "${tmpDir}/err"; then
			echo "cli-regress: migrate-failed-save [${name}]: exit ${rc}, expected 8 from the save: $(head -c 200 "${tmpDir}/err")" >&2; nBad+=1
		elif ! cmp -s "${failDir}/f.shcl" "${tmpDir}/migfail.src" || [[ -e "${failDir}/f_old_v2.shcl" ]]; then
			echo "cli-regress: migrate-failed-save [${name}]: afterwards: $(find "${failDir}" -mindepth 1 -printf '%f ')" >&2; nBad+=1
		fi
	done
fi

## The help text is a column-aligned table sitting at exactly 80 wide, and it is
## hand-duplicated in four CLIs, so one added word wraps it in every terminal at
## once and nothing else here would notice. Only help is checked: about and
## donate carry the copyright symbol and the author ID by design, so a byte
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
	for cmd in "${checks[@]}"; do
		read -r -a cmdArgv <<<"${cmd}"
		text="$("${cli}" "${cmdArgv[@]}" 2>/dev/null </dev/null || true)"
		nRun+=1
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
## "(same)", or no parentheses at all, carries the entry above.
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

## The man page sits next to that help and had nothing holding it to the same
## width; rendered at 80 it already carried one 81-column line, from an example
## block nroff does not fill. Rendered rather than read, because the source's
## line lengths are not the page's. The overstrike sequences nroff writes for
## bold come off first, or every emphasized line reads as double its width.
manPage="${repoDir}/source/man/shcl.1"
fTest EpHH7ZQ man-width
if [[ -f "${manPage}" ]] && command -v man >/dev/null 2>&1; then
	rendered="$(MANWIDTH=80 MAN_KEEP_FORMATTING='' man --nh --nj -l "${manPage}" 2>/dev/null | sed 's/.\x08//g' || true)"
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
		echo "cli-regress: man-width: no man here and the gate requires it" >&2; nBad+=1
	fi
	echo "cli-regress: skipping the man page width check (no man here)"
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
##		            help was found carrying an 81-column example line.
