<!-- markdownlint-disable MD010 MD033 MD041 -->
# Conformance corpus

These golden cases pin every released SHCL binding to the same behavior. Each independent parser runs this corpus in CI, and a binding that drifts on any case isn't conformant and isn't released. Shell scripts that call the CLI, and typed companion layers, get their conformance from their core.

## Case layout

Each case is a directory `NNN-short-name/` containing:

- `input.shcl` is the source, usually messy on purpose.

- `expected.shcl` has the canonical formatter output for that input, at Standard strictness. That means block form, tabs, insertion order, minimal quoting, and redundancy collapsed.

- `reads.tsv` has the expected typed reads, and every case needs one. Its columns are tab-separated: `query` `type` `expected` `status` `[level]` `[slots]`. `type` uses `int|float|bool|datetime|string|raw|rawinfo` and `[]` for array forms, except for `raw` and `rawinfo`, which have no array form. It also takes `duration[@UNIT]` and `size[@UNIT][+decimal]` for a duration in milliseconds or a size in bytes, where the unit is the one a bare number takes and KB to TB go in powers of 1000. Otherwise it names one of the pseudo-calls `count`, `instances`, `load`, `lost`, `children`, `paths`, `instance_paths`, `comments`, and `schema`. `rawinfo` reads a raw block's info string, which is the fence tag, rather than its content. `expected` is the value, or `-` when it doesn't apply. `status` is one of `Good|Empty|NotFound|BadType|Multiple|BadPath`. The optional fifth column is the strictness level (`loose|standard|strict`), and it defaults to `standard`. The optional sixth column needs the fifth, and it pins the per-slot statuses of an array read, joined with `|` in slot order. The row's `status` is then the worst slot. The `load` pseudo-call asserts whether the document loads at that level, with query `-`, expected `ok` or `fail`, and status `-`. The `lost` pseudo-call asserts the document's lost count, with query `-`, the number as expected, and status `-`. The `children` pseudo-call lists a path's children in file order, with repeats kept, joined with `|`. An empty query is the root, and a missing path lists nothing. For `count`, `instances`, and `children`, a status other than `-` also pins the status and value of the status twin (`read_count`, `read_instances`, `read_children`). That's `NotFound` for a path that matches nothing, and `BadPath` for one that can't be read as a path. The `paths` pseudo-call lists every path in the document once, joined with `|` and quoted where a name needs it, with query `-` and status `-`. The `instance_paths` pseudo-call lists every binding's path once, written the same way, with `(i)` on each name its parent repeats, and with query `-` and status `-`. The `schema` pseudo-call reads the reference that the file's Schema line names, with query `-`, the reference or `-` for none as expected, and status `-`. The `comments` pseudo-call lists the comment lines above the nodes at a path, each from its `#` on, joined with `|`. A status other than `-` pins `read_comments` too. That's `NotFound` for a path that finds no node, including a wildcard whose slots all miss, and `BadPath` for one that can't be read as a path. In `expected`, a newline inside a raw-block value is written `\n`, since a literal newline or tab would break the TSV.

- `expected-diags.txt` is the diagnostic golden, and every case needs one. It has the exact `check` stdout at Standard strictness, which is one `line N: Severity: CODE` line per diagnostic in the order they're emitted, then the summary line. The summary is `ok (N diagnostic(s))`, or `failed: N diagnostic(s), M error(s)` when there are errors. The file pins the count, line, severity, and stable code per case, including the repeated-leaf hint (`H001`), which is always given, and the cases with no diagnostics.

- `write.ops` and `expected-write.shcl` are an optional pair for the Writer dimension. `write.ops` is a script of write operations, one per line and tab-separated. Each binding applies it to `input.shcl` through its library Writer and must produce `expected-write.shcl` byte for byte, and that output must be a formatter fixpoint. A line with only spaces, tabs, or carriage returns is skipped, and so is one that starts with `#`, indented or not. This is the op grammar, where `<T>` is `int|float|bool|string|datetime`:
	- `<T><TAB>PATH<TAB>VALUE` sets a scalar. A `datetime` VALUE is any accepted spelling and is stored canonically.
	- `<T>-array<TAB>PATH<TAB>V1<TAB>V2...` sets an array, written in brackets whatever its length. No elements give `[]`.
	- `<T>[-array]-default<TAB>...` is the library's default form. It sets the value where the path is missing, empty, or doesn't read as that type, and a replaced value is kept above as a comment.
	- `literal<TAB>PATH<TAB>TEXT` and `literal-default` set from value syntax rather than data, so `[80, 443]` stores an array of 2 elements where the `string` op would store one quoted string. `TEXT` is read as the value half of a line. It's trimmed, a `#` outside quotes ends it wherever it sits, and text with a line break, an unclosed quote, a bare comma, or a malformed array is rejected.
	- `raw<TAB>PATH<TAB>INFO<TAB>CONTENT` and `raw-default` set a raw block. `INFO` may be empty, and it's taken as written. The escapes below are read in `CONTENT` only.
	- `empty<TAB>PATH`, `comment<TAB>PATH<TAB>TEXT`, `clear-comments<TAB>PATH`, `remove<TAB>PATH`.
	- `banner<TAB>on` puts the info block at the end, after it takes an old one off. `banner<TAB>off` only takes it off.
	- `string` and `raw` `CONTENT` values read the file's escapes, `◉TAB◉`, `◉NEWLINE◉` and the rest of the names, so a multi-line value fits on one op line. A backslash is text. An unknown name or a lone mark gets the op refused, as `E023` would in a file. A `comment` value reads them too, but a comment is one line, so a `◉NEWLINE◉` there only gets the op refused. The setters escape again for storage, so a value read back equals the logical value it was set from.
	- Op values are checked against the reference's grammar before any write. An int is an optional sign plus ASCII digits within i64 range. A float follows the Rust `f64` grammar, which is an optional sign, then `inf`, `infinity`, or `nan` in any case, or decimal digits with an optional `.` and exponent. It doesn't allow underscores, hex, padding, or non-ASCII digits, and a value that overflows to an infinity is refused along with every other infinity and NaN. A malformed value, a bad datetime, or a path that can't be used, such as a wildcard or an index with no instance, gets the op rejected, and the CLI exits 1 with empty stdout.

- `expected-keep.shcl` is required beside `write.ops`, for the keep-lines dimension. Each binding loads `input.shcl` with its text kept, applies the same ops, and saves the way `set` does. Each line that no op touched is written as it was, a changed value goes in its own line, and new lines take the indent of the lines around them. The output must match byte for byte and load back as `expected-write.shcl`, and where the save can't keep lines, it's `expected-write.shcl` itself. Every runner also checks that each case's input, loaded that way and saved with no edits, is its own text again.

- `write-bad.ops` is optional, for the bad-op dimension. Each line uses the `write.ops` grammar, with blank and `#` lines skipped. Each one is applied alone to a fresh parse of `input.shcl`, and it must be rejected and leave the document unchanged. The differential harness replays each line through every CLI's `set` and compares stdout and exit code.

- `schema.shcl` and `expected-validate.txt` are an optional pair for the schema validation dimension, which spec.md describes under "Schema validation". `schema.shcl` is a schema, and a schema is plain SHCL itself. `expected-validate.txt` is the exact `check --schema schema.shcl input.shcl` stdout at Standard strictness, in the same format as `expected-diags.txt`. It lists the document's parse diagnostics, then the validation diagnostics (`V###` codes), then the summary line. Each binding replays it through its library `Validate`. A schema that doesn't load cleanly itself must give the single `line 0: Error: V099` diagnostic, as the CLI does.

- `init-schema.shcl` and `expected-init.shcl` are an optional pair for the generation dimension, which spec.md describes under "Schema-driven generation". `init-schema.shcl` is a schema that may use the `desc` and `default` words, which only the generator reads. `expected-init.shcl` is the exact `init --schema=init-schema.shcl` stdout. Each binding runs its library `generate` and matches the golden byte for byte. The golden must load with no error diagnostics, and it must also validate clean against the schema that produced it. The differential harness replays `init --schema=...` across every CLI, with and without `--no-banner`. The golden has the format footer, since a default run writes one. Each runner also generates with `no_banner` set and checks that the result is exactly the golden minus the footer, so the flag doesn't need any goldens of its own.

- `expected-migrate.shcl` and `expected-migrate-diags.txt` are an optional pair for the migration dimension. `expected-migrate.shcl` is the exact `migrate` output for `input.shcl`, byte for byte. `expected-migrate-diags.txt` has the load diagnostics of that output at Standard strictness, in `expected-diags.txt`'s format, so a rewrite that no longer loads can't pass. Each binding runs its library `migrate` and matches both. The runner tells `migrate` that the input is a 2.x file, since every case here is one by construction, and that's the one thing migrate can't read off the text. The output therefore has the `Format` line that migrate stamps on a file it rewrote. A `fmt` fixpoint isn't required, because migrate keeps the author's layout, but `migrate` on its own output must change nothing, and every runner checks that over every case. The differential harness replays `migrate` across every CLI both ways, with and without `--from-2x`, since the two take different arms.

- `expected-merged.shcl` is optional, and it turns on the layered-load dimension. It's the canonical form of merging any `layer*.shcl` files under `input.shcl` through the library `merge`, then applying the `merge.sets` overrides as the top layer. The layers are read in filename order, which is priority order with the lowest first, and `input.shcl` is the highest file layer. `merge.sets` is optional, with one `path=value` per line and `#` comments skipped. Each binding folds the layers with `merge` and matches the golden byte for byte, and the golden must also be a formatter fixpoint. The differential harness replays `fmt --layer=... --set=... input.shcl` across every CLI. A later layer's leaf name replaces earlier leaves with the same name, which is real override for scalars, arrays, and raw blocks. Container instances merge by `(name, value)`, like the rule inside one file.

## Notes

Case `001` corrects the autoformat shown in `../../../notes.txt`. Instances are kept in insertion order (Chicago, Cleveland, Boston, Philly) rather than sorted alphabetically, and values are minimally quoted, so city names stay bare unless a reserved char forces quotes. Those 2 points are where the case departs on purpose from the original draft by example.

Case `002` pins the stacked (`- `) array form. A bracket array and the form with a `- ` per line read byte-identical, `fmt` keeps each in the form it was written in, and repeated leaf lines stay separate instances rather than an array.

Case `003` pins the strictness bundles on coercion. Currency, `%`, float->int rounding, and the widened boolean set exist only at `loose`, and `strict` narrows booleans to `true` and `false`.

Case `004` pins load behavior per level. A malformed line is skipped with a diagnostic at `loose` and `standard`, where the rest of the file still reads, and it fails the whole load at `strict`.

Case `005` pins raw-block binding. A fence is a value line for its parent field, so both the same-line spelling and the canonical child-indent spelling bind as the field's value. A fence under a field that already has a value creates a new instance, which is addressed with the normal `(0)` index selectors.

Case `006` pins comma edges. A bare comma with a space or the end after it, outside brackets, is `E026`, and an empty element inside them is `E019`, whether it's leading, doubled, or trailing. Each line is kept as written and nothing is lost. Spacing inside brackets isn't kept, and a `""`-quoted element is the one way to write an empty one.

Case `007` also pins that a multibyte char inside a time-shaped value's zone tail is a plain `BadType`, never a crash.

Case `008` pins 10-element typed arrays of every kind (int, float, bool, datetime). They're large enough to force output-buffer growth in the CLIs, which is where per-element formatted output can go stale.

Case `009` pins wildcard slot alignment. A missing sub-path keeps its slot, with a per-slot `NotFound` and a zero or default value, and an uncoercible one reads `BadType`. The aggregate status is the worst slot, and `count` and `instances` stay index-aligned with the read, where unresolved slots are listed as "".

Case `010` pins the uniform-or-nothing rule. A field line after `- ` items is `E001`, and an item after a field child is `E008`. Each is kept as written and binds nothing, the items around the field line still join the list, nothing is lost, and the document loads at `standard` but fails at `strict`.

Case `011` pins an array read as a string. An array read as one string is its canonical bracket form, with minimal quoting and escapes intact, while the array-of-strings read unquotes and applies escapes per element. Its `base(Boston, MA)` line was once in brackets, and it selected the array-valued instance by its display form. A bare selector body can't contain a space now (`E025`), so the line is kept and takes its block with it.

Case `012` pins raw-block identity. The info string is part of a block's value, so equal bodies with `sql` and `python` infos are two instances, and they never merge silently in a way that drops an info.

Cases `014`-`016` pin the Writer. `014` builds a document from an empty base, with scalars, arrays, a comment above a field set later, an empty section, and a `-default` that does nothing when the field already exists. `015` edits an existing document. It overwrites one instance of a repeated leaf by its index, runs a `-default` that keeps the present value, runs `remove`, and adds children under the matching instance through a `(value)` selector. `016` pins the emit hazards, which are raw blocks with the info string as identity, a string that looks like a fence, tricky strings, an explicit empty string, and a bare 8-digit date stored canonically. The tricky strings have a tab, a quote, a backslash, and a fence lookalike, and they're minimally quoted so they read back verbatim. The explicit empty string is `""`, which differs from an empty value.

Case `013` pins comment preservation through `fmt`. A whole-line comment is written again above the node that the next line binds, and merged instances join their comments. A trailing comment stays on its line, though a second one from a merged instance moves above. A comment among `- ` items or on one stays where it was, a comment between a bare header and its fence attaches to that field, and a `#` inside a raw block stays content. Comments after the last binding line are written again at the end. The older cases' expected files have their inputs' comments too.

Case `017` pins merge-key injectivity. A single element with a literal NUL (`x: "a<NUL>b"`) stays distinct from the two-element array `x: [a, b]` (`count = 2`), where a key joined with a bare NUL would merge them and drop the second. The input contains an actual NUL byte, so the cross-binding differential skips it, since bash can't store a NUL, and the 4 native runners do the pinning.

Case `018` pins `field(disc): value`. A value after a selector on the last segment is an `error`. The instance is created from the discriminator and the value is dropped, so the document loads at `standard` but fails at `strict`, and `city` ends up with the two discriminator instances.

Case `019` pins i64 bounds across hex and decimal spellings. The int read parses the magnitude as u64 and range-checks it against the sign, so `-0x8000000000000000` reads i64-min like its decimal spelling, `0x7fffffffffffffff` reads i64-max, and the positive `0x8000000000000000` overflows to `BadType`.

Case `020` pins the accessors that ports differ on. It has wildcard reads across instances, a `(value)` selector read, and a raw block read both ways, with `raw` for content and `rawinfo` for the `sql` info string. The wildcard reads are `server(*).port`, and `server(*).region` where one instance lacks the sub-path, so a slot is `NotFound` and the aggregate is the worst slot.

Cases `021`-`024` pin the schema validation dimension. `021` is the sweep where everything passes. Every constraint kind is satisfied, including a quoted wildcard path, constraints for one path split across two merged `field` instances, and an empty value that passes `type: bool`. `022` produces every data-validation code `V001`-`V007` at least once. It has unknown fields with and without a "did you mean" suggestion, `required` missing at document scope (line 0) and per wildcard instance (that instance's line), and `repeat` violated at both scopes, plus the `H001` hint that comes along in the combined output. `023` produces the schema-fault codes (`V090`-`V093`) and pins that a broken schema suppresses data validation, so the document's own violation must not be reported. `024` pins `V099`, where a schema that doesn't parse cleanly gives exactly one line-0 diagnostic.

Case `041` pins generation over fragments. The `desc` and `default` words flow through the mount expansion, both mounts of the shared `node` fragment generate one full level, and the recursive `children` mounts go in the trailing block with the fragment's name in the type column. The golden validates clean against its own schema.

Case `040` pins fragment faults. An `inherits` that names no declared fragment is `V095`, and a nameless declaration and a non-`field` key inside one are `V094`, all at schema lines. The surviving constraint checks nothing here, since its mount names the missing fragment. The unknown-field sweep is off under faults, so the document's unknown fields don't draw a `V001`.

Case `039` pins fragments end to end. A self-recursive `node` fragment validates a 10-level layout tree clean, and the same fragment mounted at the alias `doc.layout` still flags an unknown field beneath it. A `repeat` declared on a fragment field disavows the document's `H001` under `--schema`, while the plain `check` golden keeps the hint.

Case `038` pins open-section schema validation. A `*` name segment in a schema path resolves every child of `indicators` whatever its name, so `required: yes` on `indicators.*.period` fires per child, and the `V002` is anchored at the offending child's own line. A field the schema doesn't declare is still `V001`, and children of any name are legal without being listed.

Case `037` pins the name wildcard in lookups. A `*` slots across children of any name with per-slot statuses, and a childless slot keeps `NotFound`. It composes with `(value)` selectors and keeps `count` and `instances` slot-aligned, scalar reads on it stay `Multiple`, and a field literally named `*` is addressed quoted (`"*"`), never by the wildcard. The write ops pin `remove` across wildcard slots, and `write-bad.ops` pins that setters refuse `*` paths, with the path checked whole and the document unchanged. `server.host` reads `a.example`, since only `web1` has one, yet a setter on it is refused, since the write would have to pick a `server`. spec.md: "That holds where a read of the whole path finds one node".

Case `036` pins schema-declared repeat suppression. With `--schema`, an `H001` is dropped when its field declares a repeat upper bound above 1, since by declaration repetition is that field's instance mechanism. An undeclared repeat keeps its hint, and the plain `check` goldens keep both.

Case `035` pins the `H002` merge hint. A binding that merges with an earlier one that isn't adjacent is hinted at the later line. Adjacent re-mentions and dotted redundant-path re-opens stay silent. Its strict `load ok` row is one of the two that pin the strictness table's hint row, since a hint never fails a load at any level.

Case `034` pins comment placement. A comment run written deeper than the next binding hangs on the block it's in, and it's written again after that block's last child, at the block's indent. A comment that's too deep moves to its block's level, and comment regions at the end of the file keep the blank lines between them.

Case `033` pins selector matching after escapes are applied. A `("q◉DQUOTE◉uote")` selector finds an instance written `'q"uote'`, and `("it's")` finds `"it's"`. The match compares logical string to logical string, whichever spelling either side used. A bare `(it's)` in a lookup has a quote in it (`E025`), so the read is `BadPath`. The write op does the same through the writer's place walk, so the set applies to the existing instance instead of creating a spurious second one.

Case `032` pins blank-line grouping. A run of blanks collapses to one, a blank before a comment group stays with the group, and the blank survives the format round trip, though the file never starts with one.

Case `031` pins the unterminated-quote diagnostic (`E017`) on a value. It has a value that opens a quote it never closes, one where the trailing comment still ends it, and one that looks like an array. Each line is kept as written and binds nothing, and the load still succeeds at Standard and fails at Strict.

Case `030` pins how the generator handles edges. An index path and an optional wildcard that isn't materialized go in the trailing not-generated block, since an index needs an instance that doesn't exist yet. A newline smuggled through an `allowed` value or a `default` stays escaped instead of adding a line. It's `\n` in the annotation, and the quoted spelling on the value line. The golden validates clean against its own schema like every generation golden.

Case `029` pins the write-op value gates and the rejection of unusable paths. The good script covers the boundary values every binding must accept (`.5`, `5.`, i64 min, a `+` sign), and `write-bad.ops` covers what every binding must reject the same way. That's hex, junk, trailing garbage, out-of-range, underscores, padding, non-ASCII digits, empty, malformed floats, every infinity and NaN spelling including `1e400`, a bad datetime, a wildcard path, an index with no instance, and a line with too few fields for each op. Its good script has a tab-only line and a line of spaces and a tab, which are skipped.

Case `043` pins the cost of a recursive schema. A shape mounted from two paths that both lead to the same node is checked once rather than once per path. Without that, a document a couple of dozen levels deep doubles the work per level and validation stops finishing, so a regression here shows up as a case that hangs rather than one that fails. The generator's own limits are pinned by a reference unit test instead, because a schema long enough to hit them would make a corpus file nobody could read.

Case `042` pins the late-merge rule. A value that only becomes final after its siblings were keyed still merges. That includes a stacked list that closes onto an earlier instance's value, and a fence that fills an empty field matching an earlier block. Merging two parents merges the identical children they now share. Its layer file also pins how a merge treats comments. The higher layer's section comment and trailing comment survive onto the matched base node, and a footer comment both files have appears once.

Case `028` pins the 512-level nesting cap. A 513-segment dotted path draws exactly one `E016` and is skipped, while the sibling line survives and the strict load fails. The at-cap boundary and the Writer's refusal to create deeper levels are pinned by a reference unit test, since an at-cap golden would be a 130 KB file for no extra coverage.

Case `027` pins the layered-merge wrapper rule. A childless over-node whose base-side name group has a container instance merges instead of replacing. A bare `server:` appends an empty instance, and `server: web1` with no body leaves both base servers untouched. A childless leaf group still overrides, so `mode:` clears `mode: fast`. The over layer's trailing body with only comments is kept as an orphan.

Case `026` pins schema-driven generation. `init-schema.shcl` has `desc` and `default` on required and optional fields, an `allowed` set (rendered `one of: ...`), int and float ranges, a `repeat` bound, and a required `server(*).host` wildcard. The golden `expected-init.shcl` writes the fields that must exist as live lines, which are the required ones and `replicas` through its repeat lower bound. Optional fields are commented out. The wildcard is filled in dotted form (`server.host:`) because `server.port` materializes its parent, so the golden validates clean against its own schema.

Case `025` pins layered loading. A defaults layer, a site layer, and `input.shcl` as the user layer are merged from the bottom up, then a `merge.sets` override is applied. It tests scalar override (`port`), and repeated-leaf override, where the whole `tags` list is replaced rather than appended. It also tests container merge by `(name, value)`, where both layers' children of `server: web1` combine, a new container instance from a higher layer (`server: web3`), and a `--set` override applied last.

When reading comparison counts, note that the fuzz seed set includes the corpus inputs, so adding a case shifts every mutated input after it and moves the derived total either way. The count is a constant for each tree rather than a coverage score, and the count over the corpus alone is the one that tracks coverage.

Case `046` pins partial validation under a schema fault. A bad `min` is a `V092` at its schema line, and the surviving constraints still flag a wrong type and a missing required field. The unknown field doesn't draw a `V001`, since the sweep needs a schema without faults.

Case `047` pins that a schema fault which loses a path (`field: "[workers, extra]"`, `V093`) still stops the unknown-field sweep, so `mystery` doesn't draw a `V001`.

Case `048` pins `H002` 3 levels deep. Re-opening `table: users` hints at the reopened line and at each nested re-mention, beside the `H001` for the repeated `col`. Under the schema, `reopen: true` drops the top hint and `repeat` drops the `H001`, while the nested hints stay.

Case `049` pins retained lines. A malformed line inside a block and one at the top level (`E014`, `E013`) are kept verbatim, written back where they sat, and count nothing lost.

Case `050` pins that quoting decides a value's elements. `x: "a, b"` is one element and `x: [a, b]` an array, so they are two instances and `x("a, b")` selects the first.

Case `051` pins a selector that finds an instance written another way. A quoted `x('a"b, c')` finds the one-element instance, while `y("p, r")` and `z("m, n")` match nothing and create an instance. A bare `x(a"b, c)` on a file line is `E025` and takes its block with it. In a lookup it is refused the same way, and the read is `BadPath`.

Case `052` pins edge whitespace through the writer. A value set with a no-break space, a vertical tab, a form feed or another Unicode space at an edge is quoted on output, so it reads back whole.

Case `053` pins blank lines in a raw body. A line longer than the closing fence's indent keeps the rest, a shorter one keeps what it has, and an empty line stays empty.

Case `054` pins escapes in names. `"a◉DOUBLE_QUOTE◉b"` and `'a"b'` are one name, so the two lines are a repeated leaf (`H001`), and a tab, a backslash and an apostrophe in a quoted name read back, from a lookup and from a schema path quoted twice.

Case `055` pins a raw block whose body is whitespace only. Each line loses only what it shares with the closing fence's indent and keeps the rest, so the spacing survives a round trip and the block can't gain a level per pass.

Case `056` pins the merge rule for an empty binding. A raw block in the higher layer fills a same-named empty binding below (`blk`), exactly as a fence line fills one inside a single file, while a valued binding still appends beside it (`two`). The merged golden is what parsing the two layers run together produces, which is what makes it a formatter fixpoint.

Case `057` pins that a skipped binding line keeps its indent level (`E018`). The lines written under it are skipped with it instead of attaching one level up, the next line at its own indent still binds where it should, and a malformed line that can't be read, which is retained as trivia, loses its block the same way. The strict load fails. The `E004` wildcard line is kept as written too.

Case `058` pins raw-block nesting. The closing fence's indent is what comes off each body line, so a body whose lines all sit past the fence keeps that shared indent, a line flush left keeps nothing, and the write op stores an info-string trimmed the way a fence line reads it.

Case `059` pins the two raw-block errors. One is a fence with no parent field (`E006`, the block is dropped) and the other is a block that never closes (`E005`, the content runs to the end of the file and the block still binds).

Case `060` pins the stacked-list errors. They're an item with no parent field (`E007`), an empty item (`E009`, a `-` followed only by a comment, kept among the items), a bare comma in an item (`E026`, kept among the items), and an item under a field that already has a value (`E011`). The `E007` and `E011` items are kept as written, nothing is lost, and the survivors still read as the list.

Case `061` pins `E012`. A dedent to a column that matches no open level is skipped and written back as it was, and the next line at a real level binds where it belongs.

Case `062` pins a writer fold. `empty b` clears the value of `b: 1`, which then merges with the `b` below it. The `int b(0).c 5` before it names which `b` the setter writes, since the merged order differs by instance. The op it replaced set a value the `b` below already had, so the golden read the same either way.

Case `063` pins `remove` followed by a `-default` on the same path. The default finds the path gone and writes it again, at the end.

Case `064` pins that `raw` refuses an info string with a `#`, which the fence line would read as a comment.

Case `065` pins `literal` on bracket arrays. `[80, 8080]`, `[1]`, `[]`, the default form and a trailing comment all store an array, and the quoted string `"[80, 443]"` stays a string. Its `write-bad.ops` refuses a missing `]`, an empty element, text after the `]`, a nested array and a bare comma.

Case `066` pins comment text through the writer. A trailing space comes off, a trailing no-break space stays, and an empty comment is a bare `#`.

Case `067` pins the i64 edge at the loose float fallback. `9223372036854775807.0` rounds to 2^63 as a double and is `BadType` as an int, while `-9223372036854775808.0` reads.

Case `068` pins a `#` on a fence line in both spellings. It ends the label and opens the line's comment, so ```` ```c# ```` labels the block `c`. A `#` against the label like that gets the hint `H008`; one after a blank gets none.

Case `069` pins traversal through the `children`, `paths` and `instance_paths` rows. It has children in file order with repeats kept, each instance's in turn where a path has several, nothing for a missing path, every path once, quoted where a name needs it, and every binding once with `(i)` on a name its parent repeats.

Case `070` pins a selector over a raw block and a scalar with the same display. A selector matches one plain value, so `x(hi)` and `x("hi")` both bind the scalar and a read of `x(hi)` counts one.

Case `071` pins the schema-fault arms. A constraint given two values where it takes one (`type`, `repeat`, `inherits`, `min`, `max`), given twice (`allowed`), or given a value it can't take (`maybe`, `abc`, a `min` on a string) draws `V092` at its schema line.

Case `072` pins `allowed` on typed fields. A raw block against a string list, a float array beside `min` and `max`, a bool, a datetime and an int are each compared by type.

Case `073` pins `init` for a valued parent. The child lines select the instance by its value (`srv(web).port`), a quoted default stays quoted in the selector, and the output validates against its own schema.

Case `074` pins the float range. A value past the double range is `BadType` at every level, as a scalar, an array element or loose currency, the largest double reads, and an underflow reads as 0.

Case `075` pins that a skipped line keeps its indent level in the other two kinds of skip too. They're a line refused with `E012`, and a `*` line with no space (`E013`). What is written under either is skipped with it (`E018`), a fence line at a bad indent takes its whole body with it, and a second line at the same bad indent is refused the same way rather than binding one level up. The `E012` lines and the lines under them are kept as written, since their indents contain a space. The fence and its body, and the lines under the `E013` line, are lost.

Case `076` pins a value written after an index selector on the last segment (`a(0): 2`). The instance is selected and the value is reported (`E002`) and counted as lost, exactly as after a value selector, so a save can't quietly delete it. A same-line fence there is the same case. A value after an index that isn't last still binds the deeper leaf.

Case `077` pins that a fragment mounted at one node by two schema paths (`srv` and `srv(*)` both inheriting `unit`) runs once per node. Each fault under it is reported once rather than once per path.

Case `078` pins what a schema disavows. A `repeat` above 1 drops the `H001` hint for a field whose path has an escaped quote, a `reopen: true` drops the `H002` hint, and a `repeat` or `reopen` that faults (`V092`) disavows nothing, so the hint stays beside the fault.

Case `079` pins the order a merge appends in. Unmatched higher-layer nodes keep that file's order (`c, a, b, a`) rather than regrouping by name, and a footer line the layer repeats itself is kept twice, while one the base already has is kept once.

Case `080` pins float spelling on the values where shortest-round-trip formatters are allowed to differ. Those are powers of two, whose rounding interval is lopsided so the closest short spelling doesn't read back and the neighbor does, and exact ties between two spellings of the shortest length, which round to even. Every binding writes the same digits.

Case `081` pins wildcards that compose. `server(*).*` reads every child of every instance, `*.port` keeps a slot per top-level field with the worst status as the aggregate, a wildcard on a missing parent is `NotFound` with a count of zero, and the write removes `server(*).*`. The status twins of `count`, `instances` and `children` say `NotFound` there too, and `Good` on `*.port`, whose unresolved slots still count.

Case `082` pins `init` over wildcards. A filled wildcard is itself a valued parent (`a.b(bee).c`), an all-digit default is quoted inside a selector (`num("8")`), and a trailing wildcard fills from its own line. The golden validates against its schema.

Case `083` pins a merge with layers that start with blank lines, one of them with only a comment. The result equals merging the layers' canonical forms.

Case `084` pins value identity across spellings. `"q◉DOUBLE_QUOTE◉uote"` and `'q"uote'` are one instance, and so are `nobs` and `'nobs'`. A selector in either spelling finds it, and a layer merges into it.

Case `085` pins `allowed` on a time. `Z`, `+00:00` and `-00:00` are all the moment `12:00:00Z`, a zero fraction matches the same clock without one, and a time with no offset isn't the `Z` moment (`V004`).

Case `086` pins a bare index on a binding line that names no instance. `a(5).b` is `E003`, kept as written, and nothing is lost, while `c(1).d` selects the second `c`.

Case `087` pins where a merge puts a layer with only a comment. It goes above the base's trailing comment, after the field. The field is written without a colon (`E015`) and still binds.

Case `088` pins a quote in the middle of a bare value. An apostrophe inside a word is text, on a field line and a stacked item, and the writer quotes it. A double quote there is an error (`E025`), and `it's fine, ok` is `E026` for its comma. Each refused line is kept as written, a trailing comment stays a comment, and a quoted `#` reads as written.

Case `089` pins that a colon before the field's own colon doesn't hide a bracket array. After a quoted name with one and a selector with one, `[80, 443]` reads as an array, and one with text after its `]` is `E019`, kept, with nothing lost.

Case `090` pins a crossed range (`min` above `max`). It's `V092` at its schema line, while the other constraints still apply and the unknown-field sweep still names `bogus` and `other`.

Case `091` pins a leaf override in a merge. The base leaf's value goes, but a retained bad line above it and a bad `*` line under an overridden field stay in the merged file, the `*` line under the field that replaced it (2026102821530643).

Case `092` pins that a default form refuses a wildcard path whether or not its slots resolve, while the same default on a named instance writes only what is missing.

Case `093` pins `allowed` on a datetime with an offset. The same instant written at another offset matches, across a day boundary too, and the same clock at another offset doesn't.

Case `094` pins what trimming takes off a bare piece, which is a space, a tab and a carriage return. A no-break space, a line separator, a vertical tab or a form feed left at an edge is whitespace inside the piece, so the line is `E025` and kept as written.

Case `095` pins that a refused item keeps its level. What is written under an `E008`, `E009` or `E011` item is `E018` and lost with it. The items themselves are kept.

Cases `096` and `097` pin a raw block that never closes, with and without a final newline. It's `E005`, and the block reads `body` either way.

Case `098` pins a comment added to a node that already has one, with a blank line above the node. The new comment goes under the old one, and the blank moves above both.

Case `099` pins `literal` on text that only looks like syntax. A fence opener is stored as a quoted string, while a bare string with a colon then a space (`E025`), an unclosed quote in the first or a later piece and a leading `[` are refused.

Case `100` pins integers past the i64 range. Hex and decimal spellings read as floats and are `BadType` as ints. A quoted thousands spelling is text, `BadType` as either, except at Loose, where it reads as a float and is still `BadType` as an int.

Case `101` pins an empty name. Two `""` leaves are a repeated leaf (`H001`), and a schema declaring `repeat: 1, 5` on the field drops the hint. It has the `H001` half of the strict `load ok` pair described under case `035`.

Case `102` pins one field written twice in a schema (`w` and `w(*)`). `init` writes one line.

Case `103` pins an all-digit selector past the u64 range. It's an index that names no instance, so the binding line is `E003` and kept as written, a read is `NotFound`, and a write through it is refused.

Case `104` pins an item with no parent field at the top of a file (`E007`). It's kept as written, its trailing comment with it.

Case `105` pins bare selector bodies with an apostrophe or a mid-text quote as `E025`, a trailing backslash as text, and quoted ones with a `]` or a `#`, each followed by a comment that stays a comment. A refused line is kept and takes its block with it.

Case `106` pins the 2.x selector sugar under the 3.0 rules. `base:[Boston]` is an array on a field with a line under it, `E028`, kept, so `base` reads Empty, `base.lat` reads under it and `base(Boston).lat` doesn't, `[prod]` and `["a, b"]` are arrays, and `srv:[web].name: [Boston]` is `E019` for the text after its first `]`, kept, with nothing lost. The load fails at Strict.

Case `107` pins recursive fragment mounts under the validation memo. A type fault 7 mounts down (`V003`), a star path through a mount, and an unknown leaf at the bottom (`V001`) are all still reported.

Case `108` pins a bracket array with an index or a wildcard (`[80]`, `[*]`). It's an ordinary array of that text, with nothing lost.

Case `109` pins a `#` in a bare selector body. On a file line it opens a comment, the selector is left unterminated (`E014`), and the line is kept with nothing lost. In a lookup a body that starts with `#` is refused, so `b(#5).c` reads `BadPath`, since the old `[#N]` index is gone. Each line gets the hint `H008` ahead of its `E014`, since the `#` is against text.

Case `110` pins `init` for a schema listed out of tree order, a parent after its child with another field between. The output keeps tree order and loads with no diagnostics, hints included.

Case `111` pins a backslash in a bare selector body as a character. `p(\\srv\temp)` and `r(a\nb)` select the instances already there rather than creating second ones.

Case `112` pins 3 setters through the tokenizer. A comment's trailing blanks come off, a raw info string keeps its leading blank, and a quoted `#` given to `literal` stays in the value. A comment holding a line break is refused.

Case `113` pins `init` spelling a line break in a by-value selector and in a name escaped, so neither starts a new line. It has both schema spellings, which are the escaped one and the real line break that `\n` inside a double-quoted schema value resolves to. The second used to be kept as written and generated two lines that the self-check then refused.

Case `114` pins raw reads. An empty binding is `Empty` for `raw` and `rawinfo`, a value that isn't a block is `BadType`, and a block reads its body and label.

Case `115` pins a carriage return as a blank outside a raw body. It's trimmed at the edge of a name, a selector, a value, an element and a comment. In the middle of a bare value it is whitespace, so that line is `E025` and kept as written.

Case `116` pins a selector body that opens a quote it never closes. It's `E017`, and the line is kept as written and takes its block with it, so `srv("prod)` binds nothing. A line whose selector and value both open one reports the selector.

Case `045` pins comment depth under childless headers. A header whose children are all commented keeps them indented under it (top-level, nested, and at end of file), while a commented line trailing a live child keeps the existing trails-the-binding placement.

Case `044` pins the value-syntax setter. It has an array, a single element, a quoted element keeping its internal comma, trimming, a `#` outside quotes ending the value wherever it sits (`#ff0000` leaves it empty, `a#b` keeps `a`, `x#` keeps `x`), an empty value, and the only-if-absent form both skipping an existing path and creating a new one. Its `write-bad.ops` pins the rejections, which are a value that opens a quote it never closes, a wildcard path, a bare comma (`E026`), and a malformed array (`E019`), with no closing `]` or with text after it. The open quote is the same text the parser reports `E017` for.

Case `117` pins how `migrate` rewrites a 2.x `name:[disc]` line on a last segment. A discriminator with a fence run or a leading `[` is quoted when the sugar becomes a value, so the rewrite opens no raw block and no bracket text, at top level, nested, spaced, with a trailing comment and with children below. An ordinary discriminator stays bare (`plain: Boston`), one the formatter would quote is quoted (`city: "New York"`), and the author's quotes are kept. The input itself is refused line by line under the current rules, which is the damage migrate exists to prevent.

Cases `118` and `119` pin how `migrate` writes a piece with a backslash, in a value, a star element, a selector and the sugar arm. 2.x read a backslash pair as an escape, bare or in either quote, so the migrated text has the text 2.x read, with a tab or a line break as its escape, and a second run changes nothing. `118` also pins a bare backslash before a comma, the line end and a comment, and two quoted names with a backslash pair, which stay as written and count as lost. `119` also pins a quoted discriminator with text between its closing quote and the `]`, which 2.x refused as a malformed line, so `migrate` leaves it as written.

Cases `122` and `123` pin a backslash in a selector body, which 2.x shielded inside quotes only. A bare body runs to its first `]`, so the line still reads and the rest of it migrates. `122` is clean under 2.x, so the migrate gate compares it document by document. Loaded as it is, each of its selector lines is `E029` now, since brackets are the 2.x spelling. `123` has the sugar spellings, where a comma behind a backslash never made the brackets an array, and a real two-element bracket array stays as written.

Case `124` pins a CRLF file whose raw block closes before a line `migrate` rewrites. The closing fence ends in a carriage return, and the block still has to close there, or the sugar and the backslash value after it are taken as block content and left as written.

Case `120` pins `init` on a last-segment by-value selector with a default. The line is written as the bare path with the default (`env: prod`), and without a default the selector line stays.

Case `121` pins that a default form judges the value as well as the path. Its `write-bad.ops` gives a malformed array and an open quote on paths that already resolve, where the form writes nothing, and a malformed array and a bare comma on a path that doesn't. Every line is refused either way.

Case `125` pins an optional child of an optional valued field in `init`. The commented child selects the parent by its default (`# srv(web).port: 80`), so uncommenting both lines names one instance. The input is that output with both lines uncommented.

Case `126` pins a skipped field line whose value opens a raw block, under a parent skipped for an escape in its name (`E018`) and at an indent that matches no open level (`E012`). The body goes with the line. Read as lines, it bound its own `port` and `name`, and its closing fence opened a block that ran to the end of the file.

Case `130` pins a wildcard remove over a leaf that repeats under one instance. A read calls such a slot ambiguous, but the remove used to skip it, leave the data and exit 0. Its reads still expect the ambiguous slot, so the two results are pinned apart.

Case `129` pins a remove that matches many nodes at once. One path takes every child of a parent, another takes several top-level instances, a third matches nothing, and a write after them shows the parent and the name index still work. Each match used to be dropped on its own, and the parent's whole child list was rebuilt every time.

Case `128` pins the column a kept `- ` item keeps, beside case `095`'s dropped one (20260918b item 28). A field line written deeper or back at the item's column is kept and binds nothing (`E001`), and the items after it still join the list. Every later sibling used to be `E012` and lost.

Case `127` pins the `init` cases where the generator guessed what the scanner would read (20260918b items 6, 7, 8, 25, 26 and 27). The first of two lines on one path is the instance its child selects. Two by-value fields with different values are two instances. An all-digit value past 64 bits is a quoted body, since bare it reads as an index. A `#` in a selector body is quoted. A fragment name with a line break stays inside the trailing block. The input is the output with every line uncommented, and its reads count the instances. A child of an array value had a selector of the elements joined, which a bare body can't write now, so those fields are commented out of its schema.

Case `131` pins the fence a writer picks for a raw body that already contains one. A body with a 3-backtick line gets a 4-backtick fence, one with 3 and 4 gets 5, a tilde run leaves the backtick fence at 3, and a run with text after it is content and counts for nothing. The read half is in the same input: a 5-backtick opener, a closing fence indented deeper than its opener, a backtick line with trailing text that doesn't close, and a tilde line inside a backtick block.

Case `132` pins a space-indented file and a subtree indented tab-then-spaces, which the spec allows and which anyone coming from YAML writes. Nothing else in the corpus indents with spaces except `075`, where they are the fault under test.

Case `133` pins a leading UTF-8 BOM, the ASCII-only case fold, and non-ASCII field names. `Srv` and `srv` are one container and an uppercase lookup finds it. `"clé"` and `"Clé"` fold together. `"CLÉ"` folds to `"clÉ"` and is a different field, because the fold is A-Z only and C counts bytes. A bare non-ASCII name is `E014` at the byte column where the name stops being bare.

Case `134` pins real override for a raw block and a bracket array, which `design.md` promises and the merge dimension only ever pinned for scalars and repeated leaves. The base layer's shell block and 3-element array are replaced whole by the top layer's python block and single element, and a raw over-value fills the base's empty binding.

Case `135` pins a schema path with a value selector, and the `bool-array` and `datetime-array` types, which no other schema names. The `max` on `srv(web1).port` leaves `srv(web2)`'s larger port alone, so a selector read as a wildcard shows up as an extra diagnostic.

Case `136` pins the number spellings a hand-edited file has, such as `007`, `+5`, `-0`, and `+0009`. They read as integers and keep the spelling the author wrote. Beside them, a closed quote followed by bare text (`"abc"def`) is `E017` and the line is kept as written, and the path spellings a lookup refuses as `BadPath`: an empty selector, a leading dot, a trailing dot and a doubled dot.

Case `137` pins that a line matching no open level (`E012`) closes none of the levels open before it. A space-indented line in a tab-indented block used to drop every later sibling in the block. The siblings bind now, and so does the first child of a leaf written after the bad line. A line deeper than the bad line is still `E018`, as `075` pins. Every bad line is kept as written, so nothing is lost.

Case `138` pins that a run of whole-line comments keeps its order and its nesting. A commented-out header and its commented-out child, at the top level, inside a block and at the end of the file, and a run whose later comments sit deeper than the block the first one trails. The input is its own canonical form. The deeper comment used to hang on an earlier block and come back ahead of the comments written before it.

Case `139` pins a comment and a malformed line written under a stacked list whose field ends up equal to an earlier instance, `q: [3]` then `q:` with `- 3`. The field folds into the first `q` at the end of the load. Both lines were filed on the instance that went away and weren't written back.

Case `140` pins where a comment inside a block goes when the block has children. The input's comment sits between the block's column and its child's, so the load files it on the block, where a reload of the canonical text files it on the last child. The merged golden has the comment right after `b`. Filed on the block, it went after the base layer's `c`, while the canonical form merged with it after `b`. Both layers also end on the same commented-out footer, nested one level deeper in the top one. The merge keeps one copy of each repeated line, and the top layer's last line comes one level past the base's line before it, since a reload would read no deeper.

Case `141` pins the order of a fold inside a fold. The second `x` fills from a fence and folds into the first, and inside it the second `a` does the same to the first `a`. Each `a` has a trailing comment, and so does the surviving one. The two demoted comments come out as `# A` then `# B`. Folding the inner pair before the outer one gives them the other way round.

Case `142` pins a comment left above a block's later instance. `# c` follows `p` at `p`'s level, and then `m` opens again and adds `s`. A reload of the canonical text files `# c` on `s`, so the load does too, and the merged golden has it right above `s`. Left on `p`, it went after `p` at the end of `m`, while the canonical form merged with it above `s`.

Case `143` pins where comments go once a merge or a write changes a block, which must be where a reload of the saved text puts them. A merge of 3 layers at once keeps `# inside` right after `c`, above the top layer's `d`, as merging two and then the third from saved text does. When 2 children are written into `k`, whose only line is a comment, the comment goes between them, as two separate runs of `set` do. And a raw block after an empty `b` has its trailing comment written on the line above it, which a reload files as a leading comment, so it stays there once the empty `b` is set to 5.

Case `144` pinned the `H003` hint, now retired. A stacked item written `name: value` is `E027` and kept as written, so is `- flag:`, text with a colon and no blank reads as a plain item, and the list stays stacked around the kept lines.

Case `145` pins which misplaced lines a save keeps. An `E012` line whose indent contains a space is written back as it was, and so is an `E018` line under it. An `E012` line indented with tabs alone would bind on a reload, so it is lost. A kept line read beside the block opened again at the end stays at the end of the file, where it was, rather than going up to the top with the block (2026110315051536).

Case `146` pins a stacked list with kept lines among its items and after the last one, here `*` lines in the old marker (`E013`). The list stays stacked with each line where it was, so a line fixed by hand is still inside the list.

Case `147` pins how a misplaced line fares by indent style (`design.md` -> Load outcomes). Output is always tabs, so a stray space in a tab-indented block and a miscounted run of spaces in a space-indented block are kept as written. A tab line in a block that skips a level and a stray tab in a space-indented block would line up with a tab level on a reload, so both are lost and a save refuses. Its children pin the direction of spec.md's indent rule: "a line whose indent has the open one's as a proper prefix is a child".

Case `148` pins `clear-comments`. Every comment line above a node comes off, a group heading included, while the comment on its own line stays. The blank that set the run off stays with the node, so a comment set after it sits where the old one did. A path that finds nothing changes nothing.

Case `149` pins `banner on`. An old info block in the footer comes off, found by its version line rather than its links, and so does a bare version stamp from `migrate`. A `##` comment set off by a blank line stays. A second `banner on` changes nothing. Its `write-bad.ops` refuses a value other than `on` or `off`.

Case `150` pins the save that keeps lines on a file kept by hand, with 4-space indents, padded values, a quoted value and capital letters in names. A changed value goes into its own line with the spacing and comment around it left alone, a new child takes its siblings' indent, a removed field takes its lines with it, and a rewritten raw block keeps the name's spelling. A stacked list given new values stays stacked, as an overwrite keeps quotes.

Case `151` pins the edges of a file. A byte-order mark, CRLF line ends and no newline at the end all stay, and a new line gets CRLF too.

Case `152` pins two edits that give the canonical form. They're a child added under flat dotted lines, and a value changed where a selector elsewhere names it.

Case `153` pins a comment above a flat dotted line and above a selector line. The canonical form writes each comment inside the block the line makes, and the save keeps both as written. A changed value on either line goes into the line.

Case `154` pins an array setter over a list written stacked. The list stays stacked, as an overwrite keeps quotes, and a malformed line kept among its items moves above it. A setter that would put a field under a list is refused, since that is `E028` on a reload.

Case `155` pins a selector that puts a child under an earlier block. The canonical order differs from the file's, so an edit anywhere gives the canonical form.

Case `156` pins a repeated block header and a repeated field between two kept lines. Both stay where they were.

Case `157` pins a repeated block header after a line that gains a new child. The child goes above the header, which stays as written.

Case `158` pins a repeated field at the end with a new field written after it. The repeat stays as written, above the new field.

Case `159` pins a line the load dropped, a tab-only indent that matches no level. A save that keeps lines writes it back as it was, with a new child of the block above it written above it.

Case `160` pins a list item with no parent field between two instances of a block (`E007`), kept as written when the second one is edited.

Case `161` pins info blocks a hand edit moved out of the footer, one above a plain field and one above a dotted line. `banner on` takes both off and adds one at the end. A comment nested under a footer block moves out to the column the block was at.

Case `162` pins the `comments` read. It lists the lines above a node from the `#` on, both instances' lines for a repeated leaf, and nothing for a node without any or for a missing path. Its status twin says `Good` for a node without any, `NotFound` for a missing path and for `e(*).x`, whose slots all miss, and `BadPath` for `e[0]` and `e(1`.

Case `163` pins a comment at an item's column after a stacked list's last item. It stays inside the list, with and without an old-marker line kept among the items.

Case `164` pins quoted data values in canonical output. A quoted int, float, bool or date keeps its quotes and its quote kind, element by element, the same as a quoted plain string. Typed reads don't care about them.

Case `165` pins a comment set on a node the writer has created at the top level. The blank line goes above the comment rather than between it and the node.

Case `166` pins numbers far past any type's width, with 5000 digits. An int value, a quoted one, a day inside a quoted date, a selector index and a schema `repeat` bound all read as out of range, and a small value behind 5000 zeros still reads.

Case `167` pins generation over a wildcard written with blanks inside its parens, which fills exactly like `(*)`.

Case `168` pins validation of a schema path whose index is past every int width. It finds nothing, and the required one reports missing.

Case `169` pins the writer's fold two levels down. Emptying a block value makes it equal to a later block, and the children the two now share fold at each level, as a reload would.

Case `170` held unknown backslash escapes, each `E023` before the value syntax. A backslash is text now, so every line reads clean as written, which covers values, a quoted name, a selector body, a stacked element and a raw block's info string. Its `write-bad.ops` lines are commented out, since each one is written now. Its migrate golden writes what 2.x read, a line break as the `NEWLINE` escape. Its selector line is in brackets, the 2.x spelling, so loaded as it is that line is `E029` now.

Case `171` held drive and share paths in double quotes, each `E024` before the value syntax. A backslash is text now, so every path reads as written and the load passes at Strict. Its `write.ops` writes a drive and a share path as typed, and its `write-bad.ops` lines are commented out.

Case `172` pins a quoted number with a leading zero. It keeps its quotes through canonical output, element by element, while a bare one stays bare. A quoted `0.5`, `0` or hex value keeps its quotes too. Int and float reads drop the zeros, and a string read keeps them.

Case `173` pins the `0x`, `0o` and `0b` integer prefixes in either case and with a sign, a bare leading zero read as decimal, bad digits and an empty prefix as `BadType`, the int range at both ends, and a float read past it.

Case `174` held `\u` and `\U` escapes in double quotes. A backslash is text now, so each one reads as the characters written, in values, a quoted name, a selector body and a lookup path, and the load passes at Strict. Its selector line is in brackets, the 2.x spelling, so loaded as it is that line is `E029` now. Canonical output still writes a zero-width space, an override and a NUL its setters stored as escapes. Its `write-bad.ops` lines are commented out.

Case `175` pins the Schema line. The first one outside a raw body is what the file names, one in a raw body is content, and `banner on` keeps a Schema line that sat in the old info block. The schema beside it is one the file passes, since the CLI's `check` follows the line.

Case `176` pins duration and size reads. It has units from the value, from a field name ending after a `-` or `_` in any case, and from the caller. It has parts out of order, repeated, signed or upper case, and a fraction that doesn't come out whole. It also has the 18-digit fraction cap, both ends of the duration range, base 10 on request, `Mb` refused, and `H005` on a field line, an inline array and a stacked element.

Case `177` pins the `duration` and `size` schema types. It has `unit`, `decimal`, and `min` and `max` in the type's units, a bare number read by the field name first, the faults for `unit` or `decimal` on another type and for `allowed` on these, and `init` writing their annotations and defaults.

Case `178` pins a misplaced line kept as written that turned into a comment, once from the load under a line skipped for an escape in its name, since as written it would bind, and once from a setter that unstacks the list it sat in. `clear-comments` takes the real comment above it and leaves it, and `comments` doesn't list it.

Case `179` pins that a merge writes every list in brackets, whatever form its layers used, so a merge of the merged text gives the same text. A line kept among the items and a comment on one go above the list.

Case `180` pins `banner on` with an info block above the first field's first child. A dotted first line hangs a block at the top of the file on its last name, and a saved file writes that name as the first field's first child, so the two can't be told apart after a save. The block stays, and the new one goes at the end.

Case `181` pins the `H002` hint on a late fold. A stacked list that closes onto an earlier sibling's value folds into it after the parse, and hints under a hinted re-open and when another field stands between the two, as a merge at parse time does.

Case `182` pins a Schema line indented under a field, which is where `fmt` puts one written at column 0 above an indented field. A quoted value with a fence run opens no raw block, and one after a colon does.

Case `183` pins which characters canonical output escapes. They're both ends of every range past the controls and a neighbor on each side, a soft hyphen, the annotation marks, hidden tag text, and names. It also pins what stays as written: the joiners, a variation selector after a visible character (an emoji, an ideograph, a Mongolian letter), and subdivision flags of 3 and 7 tags. A selector at the start, after a blank, a joiner, an escaped character or another selector is escaped, and so are a flag with 2 or 8 tags, capital tags, no cancel tag or no black flag. Each escape is the code point between two marks, at least 4 hex digits. Its write ops set hidden tags, a flag, a selector run and a soft hyphen through the setters.

Case `184` pins a bare duration or size `min` and `max` read the way the value is. That's the bound's own unit, then the field name's, then the schema's `unit`. A name ending in `-ms`, `_mb` or a decimal `-kb` gives the bound its unit, the name wins over `unit`, and a bound with its own unit keeps it. With no unit from either, and on a path ending in `*`, a bare bound is still `V092`.

Case `185` pins the order of a load's diagnostics. They go by line, with a late-fold `H002` and an `H001` in their lines' places rather than after every other diagnostic, and an `H005` found in the pass ahead of the `H001` that shares its line.

Case `186` pins a misplaced line kept as written that the load turns into a comment and moves above the first list in the file. The blank line above it goes, as it would before the first line of any file, so merging the file under another layer gives what merging its canonical form does.

Case `187` pins a field line refused for its value alone, `E019`, `E023` in a value and `E025`. It binds nothing, and the lines under it load under the field with no value, nested ones and stacked items included. A field with nothing under it stays absent, and a line with an escape in its name still takes its block with it (`E018`). Canonical output writes the kept line in place of the bare `name:` line, and both saves keep it as written.

Case `188` pins where a line refused for its value alone is written back. It goes under the line it sat under, so it reads at the same path once its value is fixed. The same is true under another such line, before a dotted line, after a comment at column 0 inside a block, before a child fence and among stacked items, where it keeps its own code. Its write ops change a value and add a field, and the save that keeps lines writes every other line as it was.

Case `189` pins a Schema line and a Format line in a raw body opened by the single-quoted name `'C:\'`. Under 2.x a backslash escaped the closing quote, so a line walk that read the file that way missed the block and took the Schema line in its body as the file's.

Case `190` pins `banner on` keeping the file's own `##` comments written right against an old info block, which means above it, under it, and under a `migrate` stamp. The block comes off from the lone `##` above its first line to the next one, or after its last line written the block's way when that closing line is gone. The stamp comes off with the migrated note under it.

Case `191` pins a field line refused for its name (`E014`, `E023` in a name) whose value opens a raw block. The body is kept with the line, so it never reads as fields and the closing fence opens nothing. A name that breaks only the spelling rule keeps its level open as well. Canonical output writes the body one level under the line, a block that never closes gets its fence, and a remove of the field above takes the line and its body. A misplaced line that can't be read but opens a block takes its body too, and is lost (`E012`).

Case `192` pins the escape mark. It has names from the list in any case, aliases, every code point prefix, escapes in bare, single- and double-quoted values, a quoted name, a selector body and a stacked item, and the mark as text in a comment and a raw block. An unknown name, a lone mark, a surrogate, a code point past U+10FFFF or with 7 digits, an empty pair and a name with a space are `E023`, kept as written. One in a value keeps its block, one in a name or selector takes it. Its write ops pin the writer's escapes: `TAB`, `NEWLINE`, `CR`, `CRLF`, `ESCAPE_CHAR`, the named controls, a code point for the rest, and `DOUBLE_QUOTE` in text with both quotes.

Case `193` pins `E025`. That's a tab, a quote other than an apostrophe inside a word, or whitespace other than a space in a bare value, and any whitespace in an array element or a bare selector body. A bare value or stacked item may contain spaces, edge whitespace is trimmed first, and a colon inside a value is text, so a time, a URL and a dash-separated date stay bare. `x, y z` is `E026` for its comma. A line refused for its value keeps its block, and so does an open quote (`E017`), but a refused selector takes it. Its write ops store spaced text as data, and the writer quotes a value with a space or a colon.

Case `194` pins the bare name rule (`E014`). A name not led by an ASCII letter, or with a space or a non-ASCII letter, still reads, so its line is kept and the lines under it load under that name, a dotted segment included. A line with no colon reads that way too, and a clean name alone is `E015`. A name that can't be read takes its block with it.

Case `195` pins backtick values. They're raw text, with no escapes and with a `#`, a comma, quotes and the escape mark as text, kept in backticks on output and in a bracket array. An unclosed backtick is `E017`, and one inside a bare value or a selector body is `E025`. Its write ops pin that an overwrite keeps a backtick, single or double quoted value in its kind when the new text fits, and the writer picks quotes when it doesn't.

Case `196` pins bracket arrays and the read table in the value syntax doc. `80` and `[80]` read alike as an int or an int array and differ as a string, `[]` and a bare `name:` both read as the empty array, Good for `[]` and Empty for the bare name. Spacing inside the brackets isn't kept, a quoted element keeps its quotes and a backtick element its backticks, and `x: 80` and `x: [80]` are two instances. Its schema pins that a string field's allowed set sees an array's bracket text while an int field reads `[80]` as 80, and its write ops that an array setter writes brackets for one element and for none, while a scalar setter writes no brackets.

Case `197` pins the malformed array (`E019`). That's text after the `]`, a nested `[`, an empty element in 3 places, and no closing `]`. A bare comma is `E026`, and each element follows the value rules (`E025`, `E017`, `E023`). Every line is kept as written with nothing lost, and the lines under one still load under the field with no value.

Case `198` pins the stacked list's `- ` marker. `fmt` keeps the list stacked, a one-item list is still an array, an old `*` line is `E013` and kept among the items that still load, `- name:` is `E027` while `- "name:"`, `- localhost:8080` and `- -5` are items, `- name: value` is `E027` too, a nested array is `E019`, an item with a space is fine, and `-x: y` is a field line (`E014`) that keeps its level. Its write ops pin that an array setter keeps a stacked list stacked.

Case `199` pins `E028`. An array on a field with fields under it is kept as written, in place of the field's own line, and the fields under it load under the field with no value, a trailing comment and `[]` included. A kept line under an array binds nothing, so the array stands. An array line that joined an earlier binding of its value leaves that one its value and opens a field of its own. Its write ops pin that a field opened this way takes new fields.

Case `200` pins that a selector matches one plain value, quoted or not. `srv(a)` and `srv("a")` find the scalar `a` and never the array `[a]` or a raw block containing `a`. A bare selector body with a space is `E025` on a file line, which takes the block under it, and in a lookup it reads `BadPath`.

Case `201` pins a list with a kept field line under it (`E001`) that a merge adds after an empty binding of its name in a lower layer. The merge puts the list in brackets and joins it to the binding, and the kept line, which would bind under the brackets, goes out as a comment.

Case `202` pins spaces, colons and commas in bare text. A bare value or stacked item keeps its spaces as typed, and canonical output quotes it. A colon or comma with something other than a blank after it is text, so `rw,noatime`, `:0`, a URL and `80,443` stay bare, and the last is a string that a typed int read refuses. A quoted `"1,000"` is text too, but at Loose it reads as 1000, while the bare `80,443` stays text there. The writer leaves `80,443` bare, so a save can't change that. A colon then a space or the end is `E025` in a value and `E027` in an item, and a comma then a space or the end is `E026`. A tab or a bracket in a bare value and a space in an array element are `E025`. Inside brackets every comma splits. The writer quotes any value, item or element with a space, colon or comma, so canonical output puts all of these but `80,443` in quotes.

Case `203` pins a selector in brackets, the old spelling, as `E029`. The line is kept as written and binds nothing. When it selects by value, the lines under it load under that instance, so `srv[web]:` with `host: h` under it adds `host` to `srv: web`. An index in brackets opens nothing, so the line under `item[0]:` is dropped (`E018`), as under a refused `item(0):`. A lookup in brackets reads `BadPath`, and so does one whose body starts with `#`. The status twins of `count`, `instances` and `children` give `BadPath` for it too, and `NotFound` for `srv(db)`, which matches nothing. A field with no lines under it has no children and reads `Good`. A `(` in a bare body is `E025`. A nested pair, `pick(a(b))`, ends the body at the first `)`, so the line is `E014`.

Cases `204` and `205` pin the hints for a Format line naming another major than this one. It's `H006` on the stamp's line for a newer one, `H007` for an older one. Either is a hint, so the load goes on as usual and a Strict load still passes. A Format line inside a raw body is the block's content and gets none. The older file reads by these rules, so its backslash is text and `a,b` is one string.

Case `206` pins the Loose read of a quoted thousands number. Exact 3-digit groups, a currency symbol, a sign, a decimal part, a trailing `.` and a `%` read as a number, and `"1, 200"`, `"1,2,3"` and `".1,200"` stay text. Bare `1,200` is text at every level, and Standard and Strict read none of them. `fmt` and the setters leave a bare one bare, and a stacked item like that goes in quotes when a merge puts the list in brackets.

Case `207` pins the hint `H008` for a `#` against text. That's text right before it in a value, a stacked item or a fence label, or an empty value with text right after it, as in `color: #fff` and `tight:#x`. The reads are what the comment leaves, and a Strict load still passes. A blank before the `#`, a closing quote or `]` before it, or a blank or another `#` after it gets none. Canonical output puts a blank before the comment, so the two empty values still hint after a save and the others don't.

Case `208` pins `H008` on lines that are refused anyway, which are an array element, a piece after a loose comma, and text after a closing `]`. The hint comes first on its line, ahead of the `E019` or `E026`, and the lines are kept as they would be without it.

Case `209` pins an apostrophe inside a word as text in a bare value and a stacked item, `O'Brien`, `Jim's Server` and `rock'n'roll` included, with the writer quoting each. One next to a space or at the end, a double quote or backtick mid-word, and an apostrophe in an array element or a selector body are `E025`. A quote first in a value still opens a piece, so `'O'Brien` is `E017`. The setters quote a value holding one, and a literal `Brien'` or `[O'Brien]` is refused.

Case `210` pins how `migrate` reads a quote in the middle of a 2.x value piece. 2.0 read it as text, but a comma or a `#` before its close didn't end the piece, so `title="a, b"` is one element and `title="c # d"` keeps its `#`. The piece is quoted whole, `'title="a, b"'`. A quote that never closes is text, so `don't, stop` is still two elements.

Case `211` pins the two codes kept for their content wherever they sit. A wildcard selector on a binding line (`E004`) is kept, opens none of its path's fields, and keeps the raw block it opens. A `-` alone is an empty item (`E009`) with or without a blank after it, kept at the root before the `E007` it used to get, and kept among a list's items. A bare name that breaks the spelling rule is still `E014` with a wildcard after it, and the lines under it go with it.

Case `212` pins the two items kept for where they sit, beside `E008`. An item at the root (`E007`) and an item under a field that has a value (`E011`) are kept as written, and nothing is lost. An edit that empties the field writes its item as a comment, since as written the field would take it, and a field that keeps a value keeps its item as written.

Case `213` pins where the load puts the kept lines read beside a second instance of one name and value, which folds into the first. Each stays above the next line of its block read after it, or at the end of the block, and the lines of 2 folds keep their order. The comments written against the second instance go along to the first.

Case `214` pins a fold that leaves the first line of the file without the kept line it had above it. The blank line before the second `a:` has nothing left to separate at the top, so merging the file under a layer gives what merging its canonical form gives.

Case `215` pins how `migrate` trims a 2.x piece. 2.x trimmed every whitespace character at a piece's edges, so a no-break space, a vertical tab or an ideographic space there goes, after a value, before one, before a comment, after a comma, after a closing quote and after a `*` item. A value that is only such a character is empty, and no blank is left after its colon. One inside a value stays, and the value is quoted. Loaded as it is, each of those lines is `E025` or `E017` now, and the `*` item is `E013`.

Case `216` pins a `#` outside quotes in a lookup path. It opens a comment, as on a file line, so `colors#primary` and `colors #primary` are `BadPath` on a read, a remove, a comment clear and every setter, and nothing changes: `colors` and its fields stay. Quoted, `"colors#primary"` names the field whose name has the `#`, and a setter and a remove act on that field alone. A bare selector body that starts with `#`, or has an unclosed quote (`E017`) or a bad escape (`E023`), is `BadPath` too, as spec.md says: "In a lookup path a bare selector body that starts with `#` is refused, as `BadPath`."

Case `217` pins `banner on` over an info block that already reads as the block this release writes, with a line its author added in it. The block stays as it is, the line in it, so the save changes nothing.

Case `218` pins `banner off` keeping a line an author added inside an info block, in an older block above a field and in the one at the end. Each line stays where its block was. Only the lines the block writes come off.

Case `219` pins a remove of one field of a dotted pair. The other line stays as written, and the names the two shared get no line of their own, since the line left names them again. The same is true through two names, for an instance named by its value, and under a block.

Case `220` pins the schema check through a fragment that mounts itself, 60 levels down. It has a legal chain, an unknown leaf, a wrong type, a wrong name halfway, and a mount whose path is two names, followed 20 times and then cut short. Only the topmost unknown name is reported. The cost at depth is timed by `mem_bounds` (`df080`), since C used to compare each path against the whole rest of the chain at every level.

Case `221` pins where a replaced stacked list's comments go. A setter writing the list anew, and a merge, put the comments among its items and on them right above the field, with the field's blank line above them. The same is true after a comment of the field's own, with a blank among the items, and in a block.

Beyond the fixed corpus, the differential harness (`cicd/utility/crosscheck.bash`) also derives accessor coverage over the fuzz set. The reference's fuzz dump writes a `<name>.reads.tsv` beside each dumped input, with paths it knows exist and a type and strictness that cycle, and the `--extra` replay runs it through the same row machinery. Every scalar read row, from the corpus and from the fuzz set, is also replayed under `--on-bad=error` as an exit-code differential and under `--default=<x>` as a stdout differential, so the on-bad and default policy is pinned across bindings too. The harness also runs 3 `set` edits (a changed value, a new child, and a removal) on the first paths of every input, corpus and fuzz alike, so the save that keeps lines is compared well past the goldens. The reference's line-ending fuzz dumps up to 100 more inputs into an `eol/` folder beside the rest, and each one mixes LF and CRLF and has its edits as a write-ops script. Each goes through `set --write` in every binding, and the files left on disk must match byte for byte.

The on-bad and default outputs aren't modeled natively as golden files yet. The harness above covers them across bindings, rather than per-row `expected`. Diagnostic expectations are modeled natively through `expected-diags.txt`, above, and across bindings through the `load` rows.
