<!-- markdownlint-disable MD010 MD033 MD041 -->
# Conformance corpus

Golden cases that pin every released SHCL binding to identical behavior. Each independent parser runs this corpus in CI; drift on any case means the binding is non-conformant and is not released. (Shell scripts that call the CLI, and companion typed surfaces, inherit conformance from their core.)

## Case layout

Each case is a directory `NNN-short-name/` containing:

- `input.shcl` - the source, usually deliberately messy.

- `expected.shcl` - the canonical formatter output for that input (block form, tabs, insertion order, minimal quoting, redundancy collapsed), at Standard strictness.

- `reads.tsv` - expected typed reads (required). Columns, tab-separated: `query` `type` `expected` `status` `[level]` `[slots]`. `type` uses `int|float|bool|datetime|string|raw|rawinfo` and `[]` for array forms (except `raw`/`rawinfo`, which have no array form), or `duration[@UNIT]` and `size[@UNIT][+decimal]` for a duration in milliseconds or a size in bytes, with the unit a bare number takes and KB to TB in powers of 1000, or the pseudo-calls `count`/`instances`/`load`/`lost`/`children`/`paths`/`instance_paths`/`comments`/`schema`. `rawinfo` reads a raw block's info-string (the fence tag) rather than its content. `expected` is the value (`-` when not applicable); `status` is one of `Good|Empty|NotFound|BadType|Multiple|BadPath`. The optional fifth column is the strictness level (`loose|standard|strict`), default `standard`. The optional sixth column (requires the fifth) pins the per-slot statuses of an array read, `|`-joined in slot order; the row's `status` is then the worst slot. The `load` pseudo-call asserts whether the document loads at that level: query `-`, expected `ok` or `fail`, status `-`. The `lost` pseudo-call asserts the document's lost count: query `-`, expected the number, status `-`. The `children` pseudo-call lists a path's children in file order, repeats kept, `|`-joined: an empty query is the root, a missing path lists nothing. For `count`, `instances` and `children`, a status other than `-` pins the status twin's (`read_count`, `read_instances`, `read_children`) status and value too: `NotFound` for a path that matches nothing, `BadPath` for one that cannot be read as a path. The `paths` pseudo-call lists every path in the document once, `|`-joined and quoted where a name needs it: query `-`, status `-`. The `instance_paths` pseudo-call lists every binding's path once, in the same spelling with `(i)` on each name its parent repeats: query `-`, status `-`. The `schema` pseudo-call reads the reference the file's Schema line names: query `-`, expected the reference or `-` for none, status `-`. The `comments` pseudo-call lists the comment lines above the node(s) at a path, each from its `#` on, `|`-joined, status `-`. In `expected`, a newline inside a raw-block value is written `\n` (a literal newline or tab would break the TSV).

- `expected-diags.txt` - the diagnostic golden (required): the exact `check` stdout at Standard strictness - one `line N: Severity: CODE` line per diagnostic in emission order, then the summary line (`ok (N diagnostic(s))`, or `failed: N diagnostic(s), M error(s)` when errors are present). Pins count, line, severity, and stable code per case, including the mandatory repeated-leaf hint (`H001`) and the zero-diagnostic cases.

- `write.ops` + `expected-write.shcl` (optional, as a pair) - the **Writer** dimension. `write.ops` is a script of write operations (one per line, tab-separated); each binding applies it to `input.shcl` via its library Writer and must produce `expected-write.shcl` byte-for-byte, and that output must be a formatter fixpoint. A blank line or one starting with `#` is skipped. Op grammar (`<T>` = `int|float|bool|string|datetime`):
	- `<T><TAB>PATH<TAB>VALUE` - set a scalar. `datetime` VALUE is any accepted spelling and is stored canonically.
	- `<T>-array<TAB>PATH<TAB>V1<TAB>V2...` - set an array, written in brackets whatever its length (no elements = `[]`).
	- `<T>[-array]-default<TAB>...` - set only if the path does not already resolve.
	- `literal<TAB>PATH<TAB>TEXT` (and `literal-default`) - set from value syntax rather than data, so `[80, 443]` stores a two-element array where the `string` op would store one quoted string. `TEXT` is read as the value half of a line: it is trimmed, a `#` outside quotes ends it wherever it sits, and text with a line break, an unclosed quote, a bare comma or a malformed array is rejected.
	- `raw<TAB>PATH<TAB>INFO<TAB>CONTENT` (and `raw-default`) - set a raw block; `INFO` may be empty. `INFO` is taken as written. The escapes below are read in `CONTENT` only.
	- `empty<TAB>PATH`, `comment<TAB>PATH<TAB>TEXT`, `clear-comments<TAB>PATH`, `remove<TAB>PATH`.
	- `banner<TAB>on` puts the info block at the end, taking an old one off first. `banner<TAB>off` only takes it off.
	- `string` and `raw` `CONTENT` values read the file's escapes, `◉TAB◉`, `◉NEWLINE◉` and the rest of the names, so a multi-line value fits on one op line. A backslash is text. An unknown name or a lone mark gets the op refused, as `E023` would in a file. A `comment` value reads them too, but a comment is one line, so a `◉NEWLINE◉` there only gets the op refused. The setters escape again for storage, so a value read back equals the logical value it was set from.
	- Op values are gated with the reference's grammar before any write: an int is an optional sign plus ASCII digits within i64 range; a float follows the Rust `f64` grammar (sign, `inf`/`infinity`/`nan` case-insensitive, or decimal digits with optional `.`/exponent - no underscores, hex, padding, or non-ASCII digits, and a value that overflows to an infinity is refused with every other infinity and NaN). A malformed value, a bad datetime, or an unusable path (wildcard, an index with no instance) rejects the op: the CLI exits 1 with empty stdout.

- `expected-keep.shcl` (required beside `write.ops`) - the **keep-lines** dimension. Each binding loads `input.shcl` keeping its text, applies the same ops, and saves the way `set` does: each line no op touched as written, a changed value in its own line, new lines at the indent of the lines around them. The output must match byte for byte and load back as `expected-write.shcl`, and where the save cannot keep lines it is `expected-write.shcl` itself. Every runner also checks that each case's input, loaded that way and saved with no edits, is its own text again.

- `write-bad.ops` (optional) - the **bad-op** dimension. Each line (same grammar as `write.ops`; blank/`#` skipped), applied ALONE to a fresh parse of `input.shcl`, must be rejected and leave the document unchanged. The differential harness replays each line through every CLI's `set` and compares stdout and exit code.

- `schema.shcl` + `expected-validate.txt` (optional, as a pair) - the **schema validation** dimension (spec.md "Schema validation"). `schema.shcl` is a schema (itself plain SHCL); `expected-validate.txt` is the exact `check --schema schema.shcl input.shcl` stdout at Standard strictness - the document's parse diagnostics, then the validation diagnostics (`V###` codes), then the summary line, under the same format as `expected-diags.txt`. Each binding replays it via its library `Validate`; a schema that does not itself load cleanly must yield the single `line 0: Error: V099` diagnostic, mirroring the CLI.

- `init-schema.shcl` + `expected-init.shcl` (optional, as a pair) - the **generation** dimension (spec.md "Schema-driven generation"). `init-schema.shcl` is a schema (with the generator-only `desc`/`default` vocabulary); `expected-init.shcl` is the exact `init --schema=init-schema.shcl` stdout. Each binding runs its library `generate` and matches the golden byte-for-byte; the golden must itself load with no error diagnostics AND validate clean against the schema that produced it; the differential harness replays `init --schema=...` across every CLI, with and without `--no-banner`. The golden has the format footer, since that is what a default run writes; each runner also generates with `no_banner` set and checks that what comes back is exactly the golden minus the footer, so the flag needs no goldens of its own.

- `expected-migrate.shcl` + `expected-migrate-diags.txt` (optional, as a pair) - the **migration** dimension. `expected-migrate.shcl` is the exact `migrate` output for `input.shcl`, byte for byte. `expected-migrate-diags.txt` is the load diagnostics of that output at Standard strictness, in `expected-diags.txt`'s format, so a rewrite that no longer loads cannot pass. Each binding runs its library `migrate` and matches both, telling it the input is a 2.x file, since every case here is one by construction and that is the one thing migrate cannot read off the text. The output therefore has the `Format` line migrate stamps a file it rewrote. A `fmt` fixpoint is not required, because migrate keeps the author's layout, but `migrate` on its own output must change nothing, and every runner checks that over every case. The differential harness replays `migrate` across every CLI both ways, with and without `--from-2x`, since the two take different arms.

- `expected-merged.shcl` (optional; triggers the **layered-load** dimension) - the canonical form of merging any `layer*.shcl` files (read in filename order, which is priority order, lowest first) under `input.shcl` (the highest file layer) via the library `merge`, then applying the `merge.sets` overrides (optional; one `path=value` per line, `#` comments skipped) as the top layer. Each binding folds the layers with `merge` and matches the golden byte-for-byte, which must also be a formatter fixpoint; the differential harness replays `fmt --layer=... --set=... input.shcl` across every CLI. A later layer's leaf name replaces earlier same-named leaves (real override for scalars, arrays, raw blocks); container instances merge by `(name, value)` like the in-file rule.

## Notes

Case `001` corrects the autoformat shown in `../../../notes.txt`: instances are kept in **insertion order** (Chicago, Cleveland, Boston, Philly), not sorted alphabetically, and values are **minimally quoted** (city names stay bare unless a reserved char forces quotes). Those two points are the intentional divergence from the original by-example draft.

Case `002` pins the stacked (`- `) array form: a bracket array and the `- `-per-line form read byte-identical, `fmt` keeps each in the form it was written, and repeated leaf lines stay separate **instances** (not an array).

Case `003` pins the strictness bundles on coercion: currency, `%`, float->int rounding, and the widened boolean set exist only at `loose`; `strict` narrows booleans to `true`/`false`.

Case `004` pins load behavior per level: a malformed line is skipped with a diagnostic at `loose`/`standard` (the rest of the file still reads), and fails the whole load at `strict`.

Case `005` pins raw-block binding: a fence is a value line for its parent field - both spellings (same-line and the canonical child-indent) bind as the field's value; a fence under an already-valued field creates a new instance, addressed with the normal `(0)` index selectors.

Case `006` pins comma edges: a bare comma with a space or the end after it, outside brackets, is `E026`, and an empty element inside them is `E019`, leading, doubled or trailing. Each line is kept as written and nothing is lost. Spacing inside brackets is not kept, and a `""`-quoted element is the one way to write an empty one.

Case `007` also pins that a multibyte char inside a time-shaped value's zone tail is a plain `BadType`, never a crash.

Case `008` pins 10-element typed arrays of every kind (int, float, bool, datetime) - large enough to force output-buffer growth in the CLIs, which is where per-element formatted output can go stale.

Case `009` pins wildcard slot alignment: a missing sub-path keeps its slot (per-slot `NotFound`, value zero/default), an uncoercible one reads `BadType`, the aggregate status is the worst slot, and `count`/`instances` stay index-aligned with the read (unresolved slots enumerate as "").

Case `010` pins uniform-or-nothing: mixing `- ` items and field children under one parent is not a block array - the first mixed field diagnoses an Error (and keeps the field), every `- ` line after a field child is an Error and is dropped, and the document loads at `standard` but fails at `strict`.

Case `011` pins array-as-string: an array read as one string is its canonical bracket form (minimal quoting, escapes intact), while the array-of-strings read unquotes and applies escapes per element. Its `base(Boston, MA)` line, once in brackets, selected the array-valued instance by its display form; a bare selector body cannot hold a space now (`E025`), so the line is kept and takes its block with it.

Case `012` pins raw-block identity: the info-string is part of a block's value, so equal bodies with `sql` and `python` infos are two instances (never a silent merge that drops an info).

Cases `014`-`016` pin the **Writer**. `014` builds a document from an empty base (scalars, arrays, a comment above a later-set field, an empty section, and a `-default` that no-ops when the field already exists). `015` edits an existing document (overwrite one instance of a repeated leaf by its index, `-default` that keeps the present value, `remove`, and a `(value)` selector that adds children under the matching instance). `016` pins the emit hazards: raw blocks (info string as identity), a string that looks like a fence, tricky strings (tab/quote/backslash and a fence-lookalike, minimally quoted so they read back verbatim), an explicit empty string (`""`, distinct from an empty value), and a bare 8-digit date stored canonically.

Case `013` pins comment preservation through `fmt`: a whole-line comment re-emits above the node bound by the next line (merged instances concatenate theirs), a trailing comment stays on its line (a second one from a merged instance moves above), a comment among `- ` items or on one stays where it was, a comment between a bare header and its fence attaches to that field, `#` inside a raw block stays content, and comments after the last binding line re-emit at the end. The older cases' expected files have their inputs' comments too.

Case `017` pins merge-key injectivity: a single element holding a literal NUL (`x: "a<NUL>b"`) stays distinct from the two-element array `x: [a, b]` (`count = 2`), where a bare-NUL-joined key would merge them and drop the second. The input contains an actual NUL byte, so the cross-binding differential skips it (bash cannot hold a NUL) and the four native runners do the pinning.

Case `018` pins `field(disc): value`: a value after a last-segment selector is an `error` (the instance is created from the discriminator, the value dropped), so the document loads at `standard` but fails at `strict`, and `city` ends up with the two discriminator instances.

Case `019` pins i64 bounds across hex and decimal spellings: the int read parses the magnitude as u64 and range-checks it against the sign, so `-0x8000000000000000` reads i64-min like its decimal spelling, `0x7fffffffffffffff` reads i64-max, and the positive `0x8000000000000000` overflows to `BadType`.

Case `020` pins the accessor surface that ports diverge on: wildcard reads across instances (`server(*).port`, and `server(*).region` where one instance lacks the sub-path, so a slot is `NotFound` and the aggregate is the worst slot), a `(value)` selector read, and a raw block read both ways (`raw` for content, `rawinfo` for the `sql` info-string).

Cases `021`-`024` pin the schema validation dimension. `021` is the all-pass sweep (every constraint kind satisfied, including a quoted wildcard path, constraints for one path split across two merged `field` instances, and an empty value passing `type: bool`). `022` produces every data-validation code `V001`-`V007` at least once - unknown fields with and without a "did you mean" suggestion, `required` missing at document scope (line 0) and per wildcard instance (that instance's line), `repeat` violated at both scopes, plus the `H001` hint riding along in the combined output. `023` produces the schema-fault codes (`V090`-`V093`) and pins that a broken schema suppresses data validation (the document's own violation must NOT be reported). `024` pins `V099`: a schema that does not parse cleanly yields exactly one line-0 diagnostic.

Case `041` pins generation over fragments: `desc`/`default` flow through the mount expansion, both mounts of the shared `node` fragment generate one full level, and the recursive `children` mounts go in the trailing block with the fragment's name in the type column; the golden validates clean against its own schema.

Case `040` pins fragment faults: `inherits` naming no declared fragment is `V095`, a nameless declaration and a non-`field` key inside one are `V094`, all at schema lines. The surviving constraint checks nothing here (its mount names the missing fragment), and the unknown-field sweep is off under faults, so the document's unknown fields draw no `V001`.

Case `039` pins fragments end to end: a self-recursive `node` fragment validates a 10-level layout tree clean, the same fragment mounted at `doc.layout` (an alias) still flags an unknown field beneath it, and a `repeat` declared on a fragment field disavows the document's `H001` under `--schema` (the plain-`check` golden keeps the hint).

Case `038` pins open-section schema validation: a `*` name segment in a schema path resolves every child of `indicators` regardless of name, so `required: yes` on `indicators.*.period` fires per child (the `V002` anchors at the offending child's own line), a field outside the declared shape is still `V001`, and children of any name are legal without enumeration.

Case `037` pins the name wildcard in lookups: `*` slots across children of any name with per-slot statuses (a childless slot keeps `NotFound`), composes with `(value)` selectors, keeps `count`/`instances` slot-aligned, scalar reads on it stay `Multiple`, and a field literally named `*` is addressed quoted (`"*"`), never by the wildcard. The write ops pin `remove` across wildcard slots, and `write-bad.ops` pins that setters refuse `*` paths (path validated whole, document unchanged).

Case `036` pins schema-declared repeat suppression: with `--schema`, an `H001` whose field declares a repeat upper bound above 1 is dropped (repetition is that field's instance mechanism by declaration) while an undeclared repeat keeps its hint; the plain `check` goldens keep both.

Case `035` pins the `H002` merge hint: a binding that merges with a non-adjacent earlier one is hinted at the later line. Adjacent re-mentions and dotted redundant-path re-opens stay silent. Its strict `load ok` row is one of the two that pin the strictness table's hint row - a hint never fails a load at any level.

Case `034` pins comment placement fidelity: a comment run written deeper than the next binding hangs on the block it sits in (re-emitted after that block's last child, at the block's indent), an over-deep comment normalizes to its block's level, and end-of-file comment regions keep the blank lines between them.

Case `033` pins escape-applied selector matching: a `("q◉DQUOTE◉uote")` selector finds an instance written `'q"uote'`, and `("it's")` finds `"it's"` - the match is logical string against logical string, whichever spelling either side used. A bare `(it's)` in a lookup has a quote in it (`E025`), so the read is `BadPath`. The write op does the same through the writer's place walk: the set applies to the existing instance instead of creating a spurious second one.

Case `032` pins blank-line grouping: a run of blanks collapses to one, a blank before a comment group stays with the group, and the blank survives the format round-trip (the file never starts with one).

Case `031` pins the unterminated-quote diagnostic (`E017`) on a value: one that opens a quote it never closes, where the trailing comment still ends it, and an array-looking one. Each line is kept as written and binds nothing, and the load still succeeds at Standard and fails at Strict.

Case `030` pins the generator's edge handling: an index path and an unmaterialized optional wildcard go in the trailing not-generated block (an index needs an instance that does not exist yet), and a newline smuggled through an `allowed` value or a `default` stays escaped (`\n` in the annotation; the quoted spelling on the value line) instead of injecting a line. The golden validates clean against its own schema like every generation golden.

Case `029` pins the write-op value gates and unusable-path rejection: the good script covers the boundary values every binding must ACCEPT (`.5`, `5.`, i64 min, a `+` sign) and `write-bad.ops` covers what every binding must REJECT identically (hex, junk, trailing garbage, out-of-range, underscores, padding, non-ASCII digits, empty, malformed floats, every infinity and NaN spelling including `1e400`, a bad datetime, a wildcard path, an index with no instance).

Case `043` pins the cost of a recursive schema: a shape mounted from two paths that both reach the same node is checked once, not once per path. Without that, a document a couple of dozen levels deep doubles the work per level and validation stops finishing, so a regression here shows up as a case that hangs rather than one that fails. The generator's own limits are pinned by a reference unit test instead - a schema long enough to reach them would be a corpus file nobody could read.

Case `042` pins the late-merge rule: a value that only becomes final after its siblings were keyed - a stacked list closing onto an earlier instance's value, a fence filling an empty field that matches an earlier block - still merges, and merging two parents merges the identical children they now share. Its layer file also pins the trivia side of a merge: the higher layer's section comment and trailing comment survive onto the matched base node, and a footer comment both files have appears once.

Case `028` pins the 512-level nesting cap: a 513-segment dotted path draws exactly one `E016` and is skipped (the sibling line survives, strict load fails). The at-cap boundary and the Writer's refusal to create deeper are pinned by a reference unit test - an at-cap golden would be a 130 KB file for no extra coverage.

Case `027` pins the layered-merge wrapper rule: a childless over-node whose base-side name group has a container instance merges instead of replacing - bare `server:` appends an empty instance, `server: web1` with no body leaves both base servers untouched - while a childless leaf group still overrides (`mode:` clears `mode: fast`). The over layer's trailing comment-only body rides through as an orphan.

Case `026` pins schema-driven generation: `init-schema.shcl` has `desc`/`default` on required and optional fields, an `allowed` set (rendered `one of: ...`), int and float ranges, a `repeat` bound, and a required `server(*).host` wildcard. The golden `expected-init.shcl` shows must-exist fields live (required, and `replicas` via its repeat lower bound), optional fields commented out, and the wildcard filled in dotted form (`server.host:`) because `server.port` materializes its parent - so the golden validates clean against its own schema.

Case `025` pins layered loading: a defaults layer, a site layer, and `input.shcl` as the user layer are merged bottom-up, then a `merge.sets` override. It exercises scalar override (`port`), repeated-leaf override (the whole `tags` list is replaced, not appended), container merge by `(name, value)` (both layers' children of `server: web1` combine), a new container instance from a higher layer (`server: web3`), and a `--set` override applied last.

Note when reading comparison counts: the fuzz seed set includes the corpus inputs, so adding a case shifts every mutated input after it and moves the derived total either way. The count is a per-tree constant, not a coverage score; the corpus-only count is the one that tracks coverage.

Case `046` pins partial validation under a schema fault: a bad `min` is a `V092` at its schema line, the surviving constraints still flag a wrong type and a missing required field, and the unknown field draws no `V001` (the sweep needs a fault-free schema).

Case `047` pins that a schema fault which loses a path (`field: "[workers, extra]"`, `V093`) still holds the unknown-field sweep back, so `mystery` draws no `V001`.

Case `048` pins `H002` three levels deep: re-opening `table: users` hints at the reopened line and at each nested re-mention, beside the `H001` for the repeated `col`. Under the schema, `reopen: true` drops the top hint and `repeat` drops the `H001`, while the nested hints stay.

Case `049` pins retained lines: a malformed line inside a block and one at the top level (`E014`, `E013`) are kept verbatim, written back where they sat, and count nothing lost.

Case `050` pins that quoting decides a value's elements: `x: "a, b"` is one element and `x: [a, b]` an array, so they are two instances and `x("a, b")` selects the first.

Case `051` pins a selector that reaches an instance written another way: a quoted `x('a"b, c')` finds the one-element instance, while `y("p, r")` and `z("m, n")` match nothing and create an instance. A bare `x(a"b, c)` on a file line is `E025` and takes its block with it. In a lookup it is refused the same way, and the read is `BadPath`.

Case `052` pins edge whitespace through the writer: a value set with a no-break space, a vertical tab, a form feed or another Unicode space at an edge is quoted on output, so it reads back whole.

Case `053` pins blank lines in a raw body: a line longer than the closing fence's indent keeps the rest, a shorter one keeps what it has, and an empty line stays empty.

Case `054` pins escapes in names: `"a◉DOUBLE_QUOTE◉b"` and `'a"b'` are one name, so the two lines are a repeated leaf (`H001`), and a tab, a backslash and an apostrophe in a quoted name read back, from a lookup and from a schema path quoted twice.

Case `055` pins a raw block whose body is whitespace only: each line loses just what it shares with the closing fence's indent and keeps the rest, so the spacing survives a round trip and the block cannot gain a level per pass.

Case `056` pins the merge rule for an empty binding: a raw block in the higher layer fills a same-named empty binding below (`blk`), exactly as a fence line fills one inside a single file, while a valued binding still appends beside it (`two`). The merged golden is what parsing the two layers run together produces, which is what makes it a formatter fixpoint.

Case `057` pins that a skipped binding line keeps its indent level (`E018`): the lines written under it are skipped with it instead of attaching one level up, the next line at its own indent still binds where it should, and a malformed line that cannot be read, retained as trivia, loses its block the same way. The strict load fails.

Case `058` pins raw-block nesting: the closing fence's indent is what comes off each body line, so a body whose lines all sit past the fence keeps that shared indent, a line flush left keeps nothing, and the write op stores an info-string trimmed the way a fence line reads it.

Case `059` pins the two raw-block errors: a fence with no parent field (`E006`, the block is dropped) and a block that never closes (`E005`, the content runs to the end of the file and the block still binds).

Case `060` pins the stacked-list errors: an item with no parent field (`E007`), an empty item (`E009`, a `-` followed only by a comment), a bare comma in an item (`E026`, kept among the items), and an item under a field that already holds a value (`E011`). The survivors still read as the list.

Case `061` pins `E012`: a dedent to a column that matches no open level is skipped and written back as it was, and the next line at a real level binds where it belongs.

Case `062` pins a writer fold: `empty b` clears the value of `b: 1`, which then merges with the `b` below it. The `int b(0).c 5` before it names which `b` the setter writes, since the merged order differs by instance; the op it replaced set a value the `b` below already had, so the golden read the same either way.

Case `063` pins `remove` followed by a `-default` on the same path: the default finds the path gone and writes it again, at the end.

Case `064` pins that `raw` refuses an info string holding a `#`, which the fence line would read as a comment.

Case `065` pins `literal` on bracket arrays: `[80, 8080]`, `[1]`, `[]`, the default form and a trailing comment all store an array, and the quoted string `"[80, 443]"` stays a string. Its `write-bad.ops` refuses a missing `]`, an empty element, text after the `]`, a nested array and a bare comma.

Case `066` pins comment text through the writer: a trailing space comes off, a trailing no-break space stays, and an empty comment is a bare `#`.

Case `067` pins the i64 edge at the loose float fallback: `9223372036854775807.0` lands on 2^63 as a double and is `BadType` as an int, while `-9223372036854775808.0` reads.

Case `068` pins a `#` on a fence line in both spellings: it ends the label and opens the line's comment, so ```` ```c# ```` labels the block `c`.

Case `069` pins traversal through the `children`, `paths` and `instance_paths` rows: children in file order with repeats kept, each instance's in turn where a path has several, nothing for a missing path, every path once, quoted where a name needs it, and every binding once with `(i)` on a name its parent repeats.

Case `070` pins a selector over a raw block and a scalar with the same display: a selector matches one plain value, so `x(hi)` and `x("hi")` both bind the scalar and a read of `x(hi)` counts one.

Case `071` pins the schema-fault arms: a constraint given two values where it takes one (`type`, `repeat`, `inherits`, `min`, `max`), given twice (`allowed`), or given a value it cannot take (`maybe`, `abc`, a `min` on a string) draws `V092` at its schema line.

Case `072` pins `allowed` on typed fields: a raw block against a string list, a float array beside `min` and `max`, a bool, a datetime and an int are each compared by type.

Case `073` pins `init` for a valued parent: the child lines select the instance by its value (`srv(web).port`), a quoted default stays quoted in the selector, and the output validates against its own schema.

Case `074` pins the float range: a value past the double range is `BadType` at every level, as a scalar, an array element or loose currency, the largest double reads, and an underflow reads as 0.

Case `075` pins that a skipped line holds its indent level in the other two skip shapes too: a line refused with `E012`, and a `*` line with no space (`E013`). What is written under either is skipped with it (`E018`), a fence line at a bad indent takes its whole body with it, and a second line at the same bad indent is refused the same way rather than binding one level up. The `E012` lines and the lines under them are kept as written, since their indents hold a space. The fence and its body, and the lines under the `E013` line, are lost.

Case `076` pins a value written after an index selector on the last segment (`a(0): 2`): the instance is selected and the value is reported (`E002`) and counted as lost, exactly as after a value selector, so a save cannot quietly delete it. A same-line fence there is the same case. A value after an index that is not last still binds the deeper leaf.

Case `077` pins that a fragment mounted at one node by two schema paths (`srv` and `srv(*)` both inheriting `unit`) runs once per node: each fault under it is reported once, not once per path.

Case `078` pins what a schema disavows: a `repeat` above 1 drops the `H001` hint for a field whose path has an escaped quote, a `reopen: true` drops the `H002` hint, and a `repeat` or `reopen` that faults (`V092`) disavows nothing, so the hint stays beside the fault.

Case `079` pins the order a merge appends in: unmatched higher-layer nodes keep that file's order (`c, a, b, a`) rather than regrouping by name, and a footer line the layer repeats itself is kept twice, while one the base already has is kept once.

Case `080` pins float spelling on the values where shortest-round-trip formatters are allowed to differ: powers of two, whose rounding interval is lopsided so the closest short spelling does not read back and the neighbor does, and exact ties between two spellings of the shortest length, which round to even. Every binding writes the same digits.

Case `081` pins wildcards that compose: `server(*).*` reads every child of every instance, `*.port` keeps a slot per top-level field with the worst status as the aggregate, a wildcard on a missing parent is `NotFound` with a count of zero, and the write removes `server(*).*`. The status twins of `count`, `instances` and `children` say `NotFound` there too, and `Good` on `*.port`, whose unresolved slots still count.

Case `082` pins `init` over wildcards: a filled wildcard is itself a valued parent (`a.b(bee).c`), an all-digit default is quoted inside a selector (`num("8")`), and a trailing wildcard fills from its own line. The golden validates against its schema.

Case `083` pins a merge with layers that start with blank lines, one of them holding only a comment: the result equals merging the layers' canonical forms.

Case `084` pins value identity across spellings: `"q◉DOUBLE_QUOTE◉uote"` and `'q"uote'` are one instance, and so are `nobs` and `'nobs'`. A selector in either spelling finds it, and a layer merges into it.

Case `085` pins `allowed` on a time: `Z`, `+00:00` and `-00:00` are all the moment `12:00:00Z`, a zero fraction matches the same clock without one, and a time with no offset is not the `Z` moment (`V004`).

Case `086` pins a bare index on a binding line that names no instance: `a(5).b` is `E003`, dropped and counted lost, while `c(1).d` reaches the second `c`.

Case `087` pins where a merge puts a layer holding only a comment: above the base's trailing comment, after the field. The field is written without a colon (`E015`) and still binds.

Case `088` pins a quote in the middle of a bare value as an error (`E025`), on a field line and a stacked element: each line is kept as written, a trailing comment stays a comment, and a quoted `#` reads as written.

Case `089` pins that a colon before the field's own colon does not hide a bracket array: after a quoted name holding one and a selector holding one, `[80, 443]` reads as an array, and one with text after its `]` is `E019`, kept, with nothing lost.

Case `090` pins a crossed range (`min` above `max`): `V092` at its schema line, while the other constraints still apply and the unknown-field sweep still names `bogus` and `other`.

Case `091` pins a leaf override in a merge: the base leaf's value goes, but a retained bad line above it and a bad `*` line under an overridden field stay in the merged file.

Case `092` pins that a default form refuses a wildcard path whether or not its slots resolve, while the same default on a named instance writes only what is missing.

Case `093` pins `allowed` on a datetime with an offset: the same instant written at another offset matches, across a day boundary too, and the same clock at another offset does not.

Case `094` pins what trimming takes off a bare piece: a space, a tab and a carriage return. A no-break space, a line separator, a vertical tab or a form feed left at an edge is whitespace inside the piece, so the line is `E025` and kept as written.

Case `095` pins that a dropped item holds its level: what is written under an `E008`, `E009` or `E011` item is `E018` and lost with it.

Cases `096` and `097` pin a raw block that never closes, with and without a final newline: `E005`, and the block reads `body` either way.

Case `098` pins a comment added to a node that already has one, with a blank line above the node: the new comment goes under the old one, and the blank moves above both.

Case `099` pins `literal` on text that only looks like syntax: a fence opener is stored as a quoted string, while a bare string with a colon then a space (`E025`), an unclosed quote in the first or a later piece and a leading `[` are refused.

Case `100` pins integers past the i64 range: hex, decimal and quoted-thousands spellings read as floats and are `BadType` as ints.

Case `101` pins an empty name: two `""` leaves are a repeated leaf (`H001`), and a schema declaring `repeat: 1, 5` on the field drops the hint. It has the `H001` half of the strict `load ok` pair described under case `035`.

Case `102` pins one field written twice in a schema (`w` and `w(*)`): `init` writes one line.

Case `103` pins an all-digit selector past the u64 range: an index naming no instance, so the binding line is `E003` and lost, a read is `NotFound`, and a write through it is refused.

Case `104` pins an item with no parent field at the top of a file (`E007`, dropped): its trailing comment is kept.

Case `105` pins bare selector bodies holding an apostrophe or a mid-text quote as `E025`, a trailing backslash as text, and quoted ones holding a `]` or a `#`, each followed by a comment that stays a comment. A refused line is kept and takes its block with it.

Case `106` pins the 2.x selector sugar under the 3.0 rules: `base:[Boston]` is an array on a field with a line under it, `E028`, kept, so `base` reads Empty, `base.lat` reads under it and `base(Boston).lat` does not, `[prod]` and `["a, b"]` are arrays, and `srv:[web].name: [Boston]` is `E019` for the text after its first `]`, kept, with nothing lost. The load fails at Strict.

Case `107` pins recursive fragment mounts under the validation memo: a type fault seven mounts down (`V003`), a star path through a mount, and an unknown leaf at the bottom (`V001`) are all still reported.

Case `108` pins a bracket array holding an index or a wildcard (`[80]`, `[*]`): an ordinary array of that text, with nothing lost.

Case `109` pins a `#` in a bare selector body. On a file line it opens a comment, the selector is left unterminated (`E014`), and the line is kept with nothing lost. In a lookup a body that starts with `#` is refused, so `b(#5).c` reads `BadPath`, since the old `[#N]` index is gone.

Case `110` pins `init` for a schema listed out of tree order, a parent after its child with another field between: the output keeps tree order and loads with no diagnostics, hints included.

Case `111` pins a backslash in a bare selector body as a character: `p(\\srv\temp)` and `r(a\nb)` select the instances already there rather than creating second ones.

Case `112` pins three setters through the tokenizer: a comment's trailing blanks come off, a raw info string keeps its leading blank, and a quoted `#` given to `literal` stays in the value. A comment holding a line break is refused.

Case `113` pins `init` spelling a line break in a by-value selector and in a name escaped, so neither starts a new line. It has both schema spellings: the escaped one, and the real line break that `\n` inside a double-quoted schema value resolves to. The second used to be kept as written and generated two lines that the self-check then refused.

Case `114` pins raw reads: an empty binding is `Empty` for `raw` and `rawinfo`, a value that is not a block is `BadType`, and a block reads its body and label.

Case `115` pins a carriage return as a blank outside a raw body: trimmed at the edge of a name, a selector, a value, an element and a comment. In the middle of a bare value it is whitespace, so that line is `E025` and kept as written.

Case `116` pins a selector body that opens a quote it never closes: `E017`, and the line is kept as written and takes its block with it, so `srv("prod)` binds nothing. A line whose selector and value both open one reports the selector.

Case `045` pins comment depth under childless headers: a header whose children are all commented keeps them indented under it (top-level, nested, and at end of file), while a commented line trailing a live child keeps the existing trails-the-binding placement.

Case `044` pins the value-syntax setter: an array, a single element, a quoted element keeping its internal comma, trimming, a `#` outside quotes ending the value wherever it sits (`#ff0000` leaves it empty, `a#b` keeps `a`, `x#` keeps `x`), an empty value, and the only-if-absent form both skipping an existing path and creating a new one. Its `write-bad.ops` pins the rejections: a value opening a quote it never closes (the same text the parser reports `E017` for), a wildcard path, a bare comma (`E026`), and a malformed array (`E019`), with no closing `]` or with text after it.

Case `117` pins how `migrate` rewrites a 2.x `name:[disc]` line on a last segment. A discriminator with a fence run or a leading `[` is quoted when the sugar becomes a value, so the rewrite opens no raw block and no bracket text, at top level, nested, spaced, with a trailing comment and with children below. An ordinary discriminator stays bare (`plain: Boston`), one the formatter would quote is quoted (`city: "New York"`), and the author's quotes are kept. The input itself is refused line by line under the current rules, which is the damage migrate exists to prevent.

Cases `118` and `119` pin how `migrate` writes a piece holding a backslash: always in double quotes, in a value, a star element, a selector and the sugar arm. 2.x read a backslash in bare and single-quoted text as an escape, so the migrated file reads the same under 2.x, and a second run changes nothing. `118` also pins a bare backslash before a comma, the line end and a comment, where a spelling that reads right alone would shield what follows it. `119` also pins a quoted discriminator with text between its closing quote and the `]`, which 2.x refused as a malformed line, so `migrate` leaves it as written.

Cases `122` and `123` pin a backslash in a selector body, which 2.x shielded inside quotes only: a bare body runs to its first `]`, so the line still reads and the rest of it migrates. `122` is clean under 2.x, so the migrate gate compares it document by document. Loaded as it is, each of its selector lines is `E029` now, since brackets are the 2.x spelling; `123` has the sugar spellings, where a comma behind a backslash never made the brackets an array, and a real two-element bracket array stays as written.

Case `124` pins a CRLF file whose raw block closes before a line `migrate` rewrites. The closing fence ends in a carriage return, and the block still has to close there, or the sugar and the backslash value after it are taken as block content and left as written.

Case `120` pins `init` on a last-segment by-value selector with a default: the line is written as the bare path with the default (`env: prod`), and without a default the selector line stays.

Case `121` pins that a default form judges the value as well as the path. Its `write-bad.ops` gives a malformed array and an open quote on paths that already resolve, where the form writes nothing, and a malformed array and a bare comma on a path that does not. Every line is refused either way.

Case `125` pins an optional child of an optional valued field in `init`: the commented child selects the parent by its default (`# srv(web).port: 80`), so uncommenting both lines names one instance. The input is that output with both lines uncommented.

Case `126` pins a skipped field line whose value opens a raw block, under a parent skipped for an escape in its name (`E018`) and at an indent that matches no open level (`E012`). The body goes with the line. Read as lines, it bound its own `port` and `name`, and its closing fence opened a block that ran to the end of the file.

Case `130` pins a wildcard remove over a leaf that repeats under one instance. A read calls such a slot ambiguous, and the remove used to skip it, leave the data and exit 0. Its reads still expect the ambiguous slot, so the two answers are pinned apart.

Case `129` pins a remove that matches many nodes at once. One path takes every child of a parent, another takes several top-level instances, a third matches nothing, and a write after them shows the parent and the name index still answer. Each match used to be dropped on its own, rebuilding the parent's whole child list every time.

Case `128` pins the column a kept `- ` item holds, beside case `095`'s dropped one (20260918b item 28). A field written deeper binds under the field (`E001`), the next field at the item's column binds as its sibling, and an item after a field child is `E008`. Every later sibling used to be `E012` and lost.

Case `127` pins the `init` shapes where the generator guessed what the scanner would read (20260918b items 6, 7, 8, 25, 26 and 27). The first of two lines on one path is the instance its child selects. Two by-value fields with different values are two instances. An all-digit value past 64 bits is a quoted body, since bare it reads as an index. A `#` in a selector body is quoted. A fragment name holding a line break stays inside the trailing block. The input is the output with every line uncommented, and its reads count the instances. A child of an array value had a selector of the elements joined, which a bare body cannot spell now, so those fields are commented out of its schema.

Case `131` pins the fence a writer picks for a raw body that already holds one. A body with a three-backtick line gets a four-backtick fence, one with three and four gets five, a tilde run leaves the backtick fence at three, and a run with text after it is content and counts for nothing. The read half is in the same input: a five-backtick opener, a closing fence indented deeper than its opener, a backtick line with trailing text that does not close, and a tilde line inside a backtick block.

Case `132` pins a space-indented file and a subtree indented tab-then-spaces, which the spec allows and which anyone coming from YAML writes. Nothing else in the corpus indents with spaces except `075`, where they are the fault under test.

Case `133` pins a leading UTF-8 BOM, the ASCII-only case fold, and non-ASCII field names. `Srv` and `srv` are one container and an uppercase lookup finds it. `"clé"` and `"Clé"` fold together; `"CLÉ"` folds to `"clÉ"` and is a different field, because the fold is A-Z only and C counts bytes. A bare non-ASCII name is `E014` at the byte column where the name stops being bare.

Case `134` pins real override for a raw block and a bracket array, which `design.md` promises and the merge dimension only ever pinned for scalars and repeated leaves. The base layer's shell block and three-element array are replaced whole by the top layer's python block and single element, and a raw over-value fills the base's empty binding.

Case `135` pins a schema path with a value selector, and the `bool-array` and `datetime-array` types, which no other schema names. The `max` on `srv(web1).port` leaves `srv(web2)`'s larger port alone, so a selector read as a wildcard shows up as an extra diagnostic.

Case `136` pins the number spellings a hand-edited file has - `007`, `+5`, `-0`, `+0009` - which read as integers and keep the spelling the author wrote. Beside them, a closed quote followed by bare text (`"abc"def`) is `E017` and the line is kept as written, and the path spellings a lookup refuses as `BadPath`: an empty selector, a leading dot, a trailing dot and a doubled dot.

Case `137` pins that a line matching no open level (`E012`) closes none of the levels open before it. A space-indented line in a tab-indented block used to drop every later sibling in the block. The siblings bind now, and so does the first child of a leaf written after the bad line. A line deeper than the bad line is still `E018`, as `075` pins. Every bad line is kept as written, so nothing is lost.

Case `138` pins that a run of whole-line comments keeps its order and its nesting. A commented-out header and its commented-out child, at the top level, inside a block and at the end of the file, and a run whose later comments sit deeper than the block the first one trails. The input is its own canonical form. The deeper comment used to hang on an earlier block and come back ahead of the comments written before it.

Case `139` pins a comment and a malformed line written under a stacked list whose field ends up equal to an earlier instance, `q: [3]` then `q:` with `- 3`. The field folds into the first `q` at the end of the load. Both lines were filed on the instance that went away and were not written back.

Case `140` pins where a comment inside a block goes when the block has children. The input's comment sits between the block's column and its child's, so the load files it on the block, where a reload of the canonical text files it on the last child. The merged golden has the comment right after `b`. Filed on the block, it went after the base layer's `c`, while the canonical form merged with it after `b`. Both layers also end on the same commented-out footer, nested one level deeper in the top one. The merge keeps one copy of each repeated line, and the top layer's last line comes one level past the base's line before it, since a reload would read no deeper.

Case `141` pins the order of a fold inside a fold. The second `x` fills from a fence and folds into the first, and inside it the second `a` does the same to the first `a`. Each `a` has a trailing comment, and so does the surviving one. The two demoted comments come out as `# A` then `# B`. Folding the inner pair before the outer one gives them the other way round.

Case `142` pins a comment left above a block's later instance. `# c` follows `p` at `p`'s level, and then `m` opens again and adds `s`. A reload of the canonical text files `# c` on `s`, so the load does too, and the merged golden has it just above `s`. Left on `p`, it went after `p` at the end of `m`, while the canonical form merged with it above `s`.

Case `143` pins where comments go once a merge or a write changes a block, which must be where a reload of the saved text puts them. Three layers merged at once keep `# inside` right after `c`, above the top layer's `d`, as merging two and then the third from saved text does. Two children written into `k`, whose only line is a comment, get the comment between them, as two separate runs of `set` do. And a raw block after an empty `b` has its trailing comment written on the line above it, which a reload files as a leading comment, so it stays there once the empty `b` is set to 5.

Case `144` pinned the `H003` hint, now retired. A stacked item written `name: value` is `E027` and kept as written, so is `- flag:`, text with a colon and no blank reads as a plain item, and the list stays stacked around the kept lines.

Case `145` pins which misplaced lines a save keeps. An `E012` line whose indent holds a space is written back as it was, and so is an `E018` line under it. An `E012` line indented with tabs alone would bind on a reload, so it is lost. A kept line that a re-opened block moves up to the top of the file would bind there as written, so it is written as a comment instead.

Case `146` pins a stacked list holding kept lines among its items and after the last one, here `*` lines in the old marker (`E013`). The list stays stacked with each line where it was, so a line fixed by hand is still inside the list.

Case `147` pins how a misplaced line fares by indent style (`design.md` -> Load outcomes). Output is always tabs, so a stray space in a tab-indented block and a miscounted run of spaces in a space-indented block are kept as written. A tab line in a block that skips a level and a stray tab in a space-indented block would line up with a tab level on a reload, so both are lost and a save refuses.

Case `148` pins `clear-comments`: every comment line above a node comes off, a group heading included, while the comment on its own line stays. The blank that set the run off stays with the node, so a comment set after it sits where the old one did. A path that reaches nothing changes nothing.

Case `149` pins `banner on`: an old info block in the footer comes off, found by its version line, not its links, and so does a bare version stamp from `migrate`. A `##` comment set off by a blank line stays. A second `banner on` changes nothing. Its `write-bad.ops` refuses a value other than `on` or `off`.

Case `150` pins the save that keeps lines on a file kept by hand: four-space indents, padded values, a quoted value and capital letters in names. A changed value goes into its own line with the spacing and comment around it left alone, a new child takes its siblings' indent, a removed field takes its lines with it, and a rewritten raw block keeps the name's spelling. A stacked list given new values stays stacked, as an overwrite keeps quotes.

Case `151` pins the edges of a file: a byte-order mark, CRLF line ends and no newline at the end all stay, and a new line gets CRLF too.

Case `152` pins two edits that give the canonical form: a child added under flat dotted lines, and a value changed where a selector elsewhere names it.

Case `153` pins a comment above a flat dotted line and above a selector line. The canonical form writes each comment inside the block the line makes, and the save keeps both as written. A changed value on either line goes into the line.

Case `154` pins an array setter over a list written stacked: the list stays stacked, as an overwrite keeps quotes, and a malformed line kept among its items moves above it. A setter that would put a field under a list is refused, since that is `E028` on a reload.

Case `155` pins a selector that puts a child under an earlier block. The canonical order differs from the file's, so an edit anywhere gives the canonical form.

Case `156` pins a repeated block header and a repeated field between two kept lines. Both stay where they were.

Case `157` pins a repeated block header after a line that gains a new child. The child goes above the header, which stays as written.

Case `158` pins a repeated field at the end with a new field written after it. The repeat stays as written, above the new field.

Case `159` pins a line the load dropped, a tab-only indent that matches no level. A save that keeps lines writes it back as it was, with a new child of the block above it written above it.

Case `160` pins a dropped list item between two instances of a block, kept as written when the second one is edited.

Case `161` pins info blocks a hand edit moved out of the footer, one above a plain field and one above a dotted line. `banner on` takes both off and adds one at the end. A comment nested under a footer block moves out to the column the block was at.

Case `162` pins the `comments` read: the lines above a node from the `#` on, both instances' lines for a repeated leaf, nothing for a node with none or a missing path.

Case `163` pins a comment at an item's column after a stacked list's last item: it stays inside the list, with and without an old-marker line kept among the items.

Case `164` pins quoted data values in canonical output: a quoted int, float, bool or date keeps its quotes and its quote kind, element by element, the same as a quoted plain string. Typed reads don't care about them.

Case `165` pins a comment set on a node the writer just created at the top level: the blank line goes above the comment, not between it and the node.

Case `166` pins numbers far past any type's width, 5000 digits: an int value, a quoted one, a day inside a quoted date, a selector index and a schema `repeat` bound all read as out of range, and a small value behind 5000 zeros still reads.

Case `167` pins generation over a wildcard written with blanks inside its parens, which fills exactly like `(*)`.

Case `168` pins validation of a schema path whose index is past every int width: it finds nothing, and the required one reports missing.

Case `169` pins the writer's fold two levels down: emptying a block value makes it equal to a later block, and the children the two now share fold at each level, as a reload would.

Case `170` held unknown backslash escapes, each `E023` before the value syntax. A backslash is text now, so every line reads clean as written: values, a quoted name, a selector body, a stacked element and a raw block's info string. Its `write-bad.ops` lines are commented out, since each one is written now. Its migrate golden writes what 2.x read, a line break as the `NEWLINE` escape. Its selector line is in brackets, the 2.x spelling, so loaded as it is that line is `E029` now.

Case `171` held drive and share paths in double quotes, each `E024` before the value syntax. A backslash is text now, so every path reads as written and the load passes at Strict. Its `write.ops` writes a drive and a share path as typed, and its `write-bad.ops` lines are commented out.

Case `172` pins a quoted number with a leading zero: it keeps its quotes through canonical output, element by element, while a bare one stays bare. A quoted `0.5`, `0` or hex value keeps its quotes too. Int and float reads drop the zeros, and a string read keeps them.

Case `173` pins the `0x`, `0o` and `0b` integer prefixes in either case and with a sign, a bare leading zero read as decimal, bad digits and an empty prefix as `BadType`, the int range at both ends, and a float read past it.

Case `174` held `\u` and `\U` escapes in double quotes. A backslash is text now, so each one reads as the characters written, in values, a quoted name, a selector body and a lookup path, and the load passes at Strict. Its selector line is in brackets, the 2.x spelling, so loaded as it is that line is `E029` now. Canonical output still writes a zero-width space, an override and a NUL its setters stored as escapes. Its `write-bad.ops` lines are commented out.

Case `175` pins the Schema line: the first one outside a raw body is what the file names, one in a raw body is content, and `banner on` keeps a Schema line that sat in the old info block. The schema beside it is one the file passes, since the CLI's `check` follows the line.

Case `176` pins duration and size reads: units from the value, from a field name ending after a `-` or `_` in any case, and from the caller; parts out of order, repeated, signed or upper case; a fraction that does not come out whole; the 18-digit fraction cap; both ends of the duration range; base 10 on request; `Mb` refused; and `H005` on a field line, an inline array and a stacked element.

Case `177` pins the `duration` and `size` schema types: `unit`, `decimal`, and `min` and `max` in the type's units, a bare number read by the field name first, the faults for `unit` or `decimal` on another type and for `allowed` on these, and `init` writing their annotations and defaults.

Case `178` pins a misplaced line kept as written that turned into a comment, once from the load under a line skipped for an escape in its name, since as written it would bind, and once from a setter that unstacks the list it sat in. `clear-comments` takes the real comment above it and leaves it, and `comments` does not list it.

Case `179` pins that a merge writes every list in brackets, whatever form its layers used, so a merge of the merged text gives the same text. A line kept among the items and a comment on one go above the list.

Case `180` pins `banner on` with an info block above the first field's first child. A dotted first line hangs a block at the top of the file on its last name, and a saved file writes that name as the first field's first child, so the two cannot be told apart after a save. The block stays, and the new one goes at the end.

Case `181` pins the `H002` hint on a late fold: a stacked list that closes onto an earlier sibling's value folds into it after the parse, and hints under a hinted re-open and when another field stands between the two, as a merge at parse time does.

Case `182` pins a Schema line indented under a field, which is where `fmt` puts one written at column 0 above an indented field. A quoted value holding a fence run opens no raw block, and one after a colon does.

Case `183` pins which characters canonical output escapes: both ends of every range past the controls and a neighbor on each side, a soft hyphen, the annotation marks, hidden tag text, and names. It also pins what stays as written: the joiners, a variation selector after a visible character (an emoji, an ideograph, a Mongolian letter), and subdivision flags of three and seven tags. A selector at the start, after a blank, a joiner, an escaped character or another selector is escaped, and so are a flag with two or eight tags, capital tags, no cancel tag or no black flag. Each escape is the code point between two marks, at least four hex digits. Its write ops set hidden tags, a flag, a selector run and a soft hyphen through the setters.

Case `184` pins a bare duration or size `min` and `max` read the way the value is: the bound's own unit, then the field name's, then the schema's `unit`. A name ending in `-ms`, `_mb` or a decimal `-kb` gives the bound its unit, the name wins over `unit`, and a bound with its own unit keeps it. With no unit from either, and on a path ending in `*`, a bare bound is still `V092`.

Case `185` pins the order of a load's diagnostics: by line, with a late-fold `H002` and an `H001` in their lines' places rather than after every other diagnostic, and an `H005` found in the pass ahead of the `H001` that shares its line.

Case `186` pins a misplaced line kept as written that the load turns into a comment and moves above the first list in the file. The blank line above it goes, as it would before the first line of any file, so merging the file under another layer gives what merging its canonical form does.

Case `187` pins a field line refused for its value alone, `E019`, `E023` in a value and `E025`: it binds nothing, and the lines under it load under the field with no value, nested ones and stacked items included. A field with nothing under it stays absent, and a line with an escape in its name still takes its block with it (`E018`). Canonical output writes the kept line in place of the bare `name:` line, and both saves keep it as written.

Case `188` pins where a line refused for its value alone is written back: under the line it sat under, so it reads at the same path once its value is fixed. That holds under another such line, before a dotted line, after a comment at column 0 inside a block, before a child fence and among stacked items. Its write ops change a value and add a field, and the save that keeps lines writes every other line as it was.

Case `189` pins a Schema line and a Format line in a raw body opened by the single-quoted name `'C:\'`. Under 2.x a backslash escaped the closing quote, so a line walk that read the file that way missed the block and took the Schema line in its body as the file's.

Case `190` pins `banner on` keeping the file's own `##` comments written right against an old info block: above it, under it, and under a `migrate` stamp. The block comes off from the lone `##` above its first line to the next one, or after its last line written the block's way when that closing line is gone. The stamp comes off with the migrated note under it.

Case `191` pins a field line refused for its name (`E014`, `E023` in a name) whose value opens a raw block: the body is kept with the line, so it never reads as fields and the closing fence opens nothing. A name that breaks only the spelling rule holds its level open as well. Canonical output writes the body one level under the line, a block that never closes gets its fence, and a remove of the field above takes the line and its body. A misplaced line that cannot be read but opens a block takes its body too, and is lost (`E012`).

Case `192` pins the escape mark: names from the list in any case, aliases, every code point prefix, escapes in bare, single- and double-quoted values, a quoted name, a selector body and a stacked item, and the mark as text in a comment and a raw block. An unknown name, a lone mark, a surrogate, a code point past U+10FFFF or with seven digits, an empty pair and a name with a space are `E023`, kept as written; one in a value keeps its block, one in a name or selector takes it. Its write ops pin the writer's escapes: `TAB`, `NEWLINE`, `CR`, `CRLF`, `ESCAPE_CHAR`, the named controls, a code point for the rest, and `DOUBLE_QUOTE` in text holding both quotes.

Case `193` pins `E025`: a tab, a quote or whitespace other than a space in a bare value, and any whitespace in an array element or a bare selector body. A bare value or stacked item may hold spaces, edge whitespace is trimmed first, and a colon inside a value is text, so a time, a URL and a dash-separated date stay bare. `x, y z` is `E026` for its comma. A line refused for its value keeps its block, and so does an open quote (`E017`); a refused selector takes it. Its write ops store spaced text as data, and the writer quotes a value with a space or a colon.

Case `194` pins the bare name rule (`E014`): a name not led by an ASCII letter, or holding a space or a non-ASCII letter, still reads, so its line is kept and the lines under it load under that name, a dotted segment included. A line with no colon reads that way too, and a clean name alone is `E015`. A name that cannot be read takes its block with it.

Case `195` pins backtick values: raw text, with no escapes and with a `#`, a comma, quotes and the escape mark as text, kept in backticks on output and in a bracket array. An unclosed backtick is `E017`, and one inside a bare value or a selector body is `E025`. Its write ops pin that an overwrite keeps a backtick, single or double quoted value in its kind when the new text fits, and the writer picks quotes when it does not.

Case `196` pins bracket arrays and the read table in the value syntax doc: `80` and `[80]` read alike as an int or an int array and differ as a string, `[]` and a bare `name:` both read as the empty array, Good for `[]` and Empty for the bare name. Spacing inside the brackets is not kept, a quoted element keeps its quotes and a backtick element its backticks, and `x: 80` and `x: [80]` are two instances. Its schema pins that a string field's allowed set sees an array's bracket text while an int field reads `[80]` as 80, and its write ops that an array setter writes brackets for one element and for none, while a scalar setter writes no brackets.

Case `197` pins the malformed array (`E019`): text after the `]`, a nested `[`, an empty element in three places, and no closing `]`. A bare comma is `E026`, and each element follows the value rules (`E025`, `E017`, `E023`). Every line is kept as written with nothing lost, and the lines under one still load under the field with no value.

Case `198` pins the stacked list's `- ` marker: `fmt` keeps the list stacked, a one-item list is still an array, an old `*` line is `E013` and kept among the items that still load, `- name:` is `E027` while `- "name:"`, `- localhost:8080` and `- -5` are items, `- name: value` is `E027` too, a nested array is `E019`, an item with a space is fine, and `-x: y` is a field line (`E014`) that holds its level. Its write ops pin that an array setter keeps a stacked list stacked.

Case `199` pins `E028`: an array on a field with fields under it is kept as written, in place of the field's own line, and the fields under it load under the field with no value, a trailing comment and `[]` included. A kept line under an array binds nothing, so the array stands. An array line that joined an earlier binding of its value leaves that one its value and opens a field of its own. Its write ops pin that a field opened this way takes new fields.

Case `200` pins that a selector matches one plain value, quoted or not: `srv(a)` and `srv("a")` find the scalar `a` and never the array `[a]` or a raw block holding `a`. A bare selector body with a space is `E025` on a file line, which takes the block under it, and in a lookup it reads `BadPath`.

Case `201` pins a list with a field under it that a merge adds after an empty binding of its name in a lower layer, with a comment and a kept line between the two. A reload of the merged text joins the list to the binding and puts the two lines above it, so the merge does the same.

Case `202` pins spaces, colons and commas in bare text. A bare value or stacked item keeps its spaces as typed, and canonical output quotes it. A colon or comma with something other than a blank after it is text, so `rw,noatime`, `:0`, a URL and `80,443` stay bare, and the last is a string that a typed int read refuses. A colon then a space or the end is `E025` in a value and `E027` in an item, and a comma then a space or the end is `E026`. A tab or a bracket in a bare value and a space in an array element are `E025`. Inside brackets every comma splits. The writer quotes any value, item or element with a space, colon or comma, so canonical output puts all of these in quotes.

Case `203` pins a selector in brackets, the old spelling, as `E029`: the line is kept as written and binds nothing. When it selects by value, the lines under it load under that instance, so `srv[web]:` with `host: h` under it adds `host` to `srv: web`. An index in brackets opens nothing, so the line under `item[0]:` is dropped (`E018`), as under a refused `item(0):`. A lookup in brackets reads `BadPath`, and so does one whose body starts with `#`. The status twins of `count`, `instances` and `children` give `BadPath` for it too, and `NotFound` for `srv(db)`, which matches nothing. A field with no lines under it has no children and reads `Good`. A `(` in a bare body is `E025`. A nested pair, `pick(a(b))`, ends the body at the first `)`, so the line is `E014`.

Beyond the fixed corpus, the differential harness (`cicd/utility/crosscheck.bash`) also derives accessor coverage over the fuzz set: the reference's fuzz dump writes a `<name>.reads.tsv` beside each dumped input (paths it knows exist, cycling type and strictness), which the `--extra` replay runs through the same row machinery. Every scalar read row - corpus and fuzz-derived - is additionally replayed under `--on-bad=error` (an exit-code differential) and `--default=<x>` (a stdout differential), so the on-bad/default policy surface is pinned cross-binding too. It also runs three `set` edits (a changed value, a new child, a removal) on the first paths of every input, corpus and fuzz alike, so the save that keeps lines is compared well past the goldens. The reference's line-ending fuzz dumps up to 100 more inputs, each mixing LF and CRLF with its edits as a write-ops script, into an `eol/` folder beside the rest. Each goes through `set --write` in every binding, and the files left on disk must match byte for byte.

Not yet modeled natively (as golden files): the on-bad/default outputs (covered cross-binding via the harness above, not by per-row `expected`). Diagnostic expectations are modeled natively via `expected-diags.txt` (above) and cross-binding via the `load` rows.
