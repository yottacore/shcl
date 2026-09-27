<!-- markdownlint-disable MD010 MD033 MD041 -->
# Conformance corpus

Golden cases that pin every released SHCL binding to identical behavior. Each independent parser runs this corpus in CI; drift on any case means the binding is non-conformant and is not released. (CLI-wrapper bindings and companion typed surfaces inherit conformance from their core.)

## Case layout

Each case is a directory `NNN-short-name/` containing:

- `input.shcl` - the source, usually deliberately messy.

- `expected.shcl` - the canonical formatter output for that input (block form, tabs, insertion order, minimal quoting, redundancy collapsed), at Standard strictness.

- `reads.tsv` - expected typed reads (required). Columns, tab-separated: `query` `type` `expected` `status` `[level]` `[slots]`. `type` uses `int|float|bool|datetime|string|raw|rawinfo` and `[]` for array forms (except `raw`/`rawinfo`, which have no array form), or the pseudo-calls `count`/`instances`/`load`/`lost`/`children`/`paths`/`instance_paths`/`comments`. `rawinfo` reads a raw block's info-string (the fence tag) rather than its content. `expected` is the value (`-` when not applicable); `status` is one of `Good|Empty|NotFound|BadType|Multiple`. The optional fifth column is the strictness level (`loose|standard|strict`), default `standard`. The optional sixth column (requires the fifth) pins the per-slot statuses of an array read, `|`-joined in slot order; the row's `status` is then the worst slot. The `load` pseudo-call asserts whether the document loads at that level: query `-`, expected `ok` or `fail`, status `-`. The `lost` pseudo-call asserts the document's lost count: query `-`, expected the number, status `-`. The `children` pseudo-call lists a path's children in file order, repeats kept, `|`-joined: an empty query is the root, a missing path lists nothing, status `-`. The `paths` pseudo-call lists every path in the document once, `|`-joined and quoted where a name needs it: query `-`, status `-`. The `instance_paths` pseudo-call lists every binding's path once, in the same spelling with `[#i]` on each name its parent repeats: query `-`, status `-`. The `comments` pseudo-call lists the comment lines above the node(s) at a path, each from its `#` on, `|`-joined, status `-`. In `expected`, a newline inside a raw-block value is written `\n` (a literal newline or tab would break the TSV).

- `expected-diags.txt` - the diagnostic golden (required): the exact `check` stdout at Standard strictness - one `line N: Severity: CODE` line per diagnostic in emission order, then the summary line (`ok (N diagnostic(s))`, or `failed: N diagnostic(s), M error(s)` when errors are present). Pins count, line, severity, and stable code per case, including the mandatory repeated-leaf hint (`H001`) and the zero-diagnostic cases.

- `write.ops` + `expected-write.shcl` (optional, as a pair) - the **Writer** dimension. `write.ops` is a script of write operations (one per line, tab-separated); each binding applies it to `input.shcl` via its library Writer and must produce `expected-write.shcl` byte-for-byte, and that output must be a formatter fixpoint. A blank line or one starting with `#` is skipped. Op grammar (`<T>` = `int|float|bool|string|datetime`):
	- `<T><TAB>PATH<TAB>VALUE` - set a scalar. `datetime` VALUE is any accepted spelling and is stored canonically.
	- `<T>-array<TAB>PATH<TAB>V1<TAB>V2...` - set an inline array (no elements = an empty value).
	- `<T>[-array]-default<TAB>...` - set only if the path does not already resolve.
	- `literal<TAB>PATH<TAB>TEXT` (and `literal-default`) - set from value syntax rather than data, so `80, 443` stores a two-element array where the `string` op would store one quoted string. `TEXT` is read as the value half of a line: it is trimmed, a `#` outside quotes ends it wherever it sits, and text carrying a line break, an unclosed quote or a leading `[` is rejected.
	- `raw<TAB>PATH<TAB>INFO<TAB>CONTENT` (and `raw-default`) - set a raw block; `INFO` may be empty. `INFO` is taken as written - the escape decode below is for `CONTENT` only.
	- `empty<TAB>PATH`, `comment<TAB>PATH<TAB>TEXT`, `clear-comments<TAB>PATH`, `remove<TAB>PATH`.
	- `banner<TAB>on` puts the info block at the end, taking an old one off first. `banner<TAB>off` only takes it off.
	- `string` and `raw` `CONTENT` values decode `\n` `\t` `\\` (so a multi-line value fits on one op line); no other escapes are interpreted. A `comment` value decodes them too, but a comment is one line, so a decoded `\n` only gets the op refused. The setters re-encode for storage, so a value read back equals the logical value it was set from.
	- Op values are gated with the reference's grammar before any write: an int is an optional sign plus ASCII digits within i64 range; a float follows the Rust `f64` grammar (sign, `inf`/`infinity`/`nan` case-insensitive, or decimal digits with optional `.`/exponent - no underscores, hex, padding, or non-ASCII digits, and a value that overflows to an infinity is refused with every other infinity and NaN). A malformed value, a bad datetime, or an unusable path (wildcard, missing `[#N]`) rejects the op: the CLI exits 1 with empty stdout.

- `expected-keep.shcl` (required beside `write.ops`) - the **keep-lines** dimension. Each binding loads `input.shcl` keeping its text, applies the same ops, and saves the way `set` does: each line no op touched as written, a changed value in its own line, new lines at the indent of the lines around them. The output must match byte for byte and load back as `expected-write.shcl`, and where the save cannot keep lines it is `expected-write.shcl` itself. Every runner also checks that each case's input, loaded that way and saved with no edits, is its own text again.

- `write-bad.ops` (optional) - the **bad-op** dimension. Each line (same grammar as `write.ops`; blank/`#` skipped), applied ALONE to a fresh parse of `input.shcl`, must be rejected and leave the document unchanged. The differential harness replays each line through every CLI's `set` and compares stdout and exit code.

- `schema.shcl` + `expected-validate.txt` (optional, as a pair) - the **schema validation** dimension (spec.md "Schema validation"). `schema.shcl` is a schema (itself plain SHCL); `expected-validate.txt` is the exact `check --schema schema.shcl input.shcl` stdout at Standard strictness - the document's parse diagnostics, then the validation diagnostics (`V###` codes), then the summary line, under the same format as `expected-diags.txt`. Each binding replays it via its library `Validate`; a schema that does not itself load cleanly must yield the single `line 0: Error: V099` diagnostic, mirroring the CLI.

- `init-schema.shcl` + `expected-init.shcl` (optional, as a pair) - the **generation** dimension (spec.md "Schema-driven generation"). `init-schema.shcl` is a schema (with the generator-only `desc`/`default` vocabulary); `expected-init.shcl` is the exact `init --schema=init-schema.shcl` stdout. Each binding runs its library `generate` and matches the golden byte-for-byte; the golden must itself load with no error diagnostics AND validate clean against the schema that produced it; the differential harness replays `init --schema=...` across every CLI, with and without `--no-banner`. The golden carries the format footer, since that is what a default run writes; each runner also generates with `no_banner` set and checks that what comes back is exactly the golden minus the footer, so the flag needs no goldens of its own.

- `expected-migrate.shcl` + `expected-migrate-diags.txt` (optional, as a pair) - the **migration** dimension. `expected-migrate.shcl` is the exact `migrate` output for `input.shcl`, byte for byte. `expected-migrate-diags.txt` is the load diagnostics of that output at Standard strictness, in `expected-diags.txt`'s format, so a rewrite that no longer loads cannot pass. Each binding runs its library `migrate` and matches both, telling it the input is a 2.x file, since every case here is one by construction and that is the one thing migrate cannot read off the text. The output therefore carries the `Format` line migrate stamps a file it rewrote. A `fmt` fixpoint is not required, because migrate keeps the author's layout, but `migrate` on its own output must change nothing, and every runner checks that over every case. The differential harness replays `migrate` across every CLI both ways, with and without `--from-2x`, since the two take different arms.

- `expected-merged.shcl` (optional; triggers the **layered-load** dimension) - the canonical form of merging any `layer*.shcl` files (read in filename order, which is priority order, lowest first) under `input.shcl` (the highest file layer) via the library `merge`, then applying the `merge.sets` overrides (optional; one `path=value` per line, `#` comments skipped) as the top layer. Each binding folds the layers with `merge` and matches the golden byte-for-byte, which must also be a formatter fixpoint; the differential harness replays `fmt --layer=... --set=... input.shcl` across every CLI. A later layer's leaf name replaces earlier same-named leaves (real override for scalars, arrays, raw blocks); container instances merge by `(name, value)` like the in-file rule.

## Notes

Case `001` corrects the autoformat shown in `../../../notes.txt`: instances are kept in **insertion order** (Chicago, Cleveland, Boston, Philly), not sorted alphabetically, and values are **minimally quoted** (city names stay bare unless a reserved char forces quotes). Those two points are the intentional divergence from the original by-example draft.

Case `002` pins the stacked (`*`) array form: an inline comma array and the `*`-per-line form read byte-identical and both canonicalize to the inline form, while repeated leaf lines stay separate **instances** (not an array).

Case `003` pins the strictness bundles on coercion: currency, `%`, float->int rounding, and the widened boolean set exist only at `loose`; `strict` narrows booleans to `true`/`false`.

Case `004` pins load behavior per level: a malformed line is skipped with a diagnostic at `loose`/`standard` (the rest of the file still reads), and fails the whole load at `strict`.

Case `005` pins raw-block binding: a fence is a value line for its parent field - both spellings (same-line and the canonical child-indent) bind as the field's value; a fence under an already-valued field creates a new instance, addressed with the normal `[0]`/`[#N]` selectors.

Case `006` pins forgiving inline arrays: stray commas never error. Leading, doubled, and trailing commas drop their empty slots (`red,,blue` -> `red, blue`), an all-comma value (`,,,`) is the empty array, and a `""`-quoted element is the one way to keep a deliberately empty slot.

Case `007` also pins that a multibyte char inside a time-shaped value's zone tail is a plain `BadType`, never a crash.

Case `008` pins 10-element typed arrays of every kind (int, float, bool, datetime) - large enough to force output-buffer growth in the CLIs, which is where per-element formatted output can go stale.

Case `009` pins wildcard slot alignment: a missing sub-path keeps its slot (per-slot `NotFound`, value zero/default), an uncoercible one reads `BadType`, the aggregate status is the worst slot, and `count`/`instances` stay index-aligned with the read (unresolved slots enumerate as "").

Case `010` pins uniform-or-nothing: mixing `*` elements and field children under one parent is not a block array - the first mixed field diagnoses an Error (and keeps the field), every `*` line after a field child is an Error and is dropped, and the document loads at `standard` but fails at `strict`.

Case `011` pins selector-vs-instance matching on the display form: `base[Boston, MA]` selects the existing array-valued instance `base: Boston, MA` instead of creating a second one. It also pins array-as-string: a multi-element value read as one string is the canonical inline form (minimal quoting, escapes intact), while the array-of-strings read unquotes and applies escapes per element.

Case `012` pins raw-block identity: the info-string is part of a block's value, so equal bodies with `sql` and `python` infos are two instances (never a silent merge that drops an info).

Cases `014`-`016` pin the **Writer**. `014` builds a document from an empty base (scalars, arrays, a comment above a later-set field, an empty section, and a `-default` that no-ops when the field already exists). `015` edits an existing document (overwrite the first instance of a leaf, `-default` that keeps the present value, `remove`, and a `[value]` selector that adds children under the matching instance). `016` pins the emit hazards: raw blocks (info string as identity), a string that looks like a fence, tricky strings (tab/quote/backslash and a fence-lookalike, minimally quoted so they read back verbatim), an explicit empty string (`""`, distinct from an empty value), and a bare 8-digit date stored canonically.

Case `013` pins comment preservation through `fmt`: a whole-line comment re-emits above the node bound by the next line (merged instances concatenate theirs), a trailing comment stays on its line (a second one from a merged instance moves above), comments among `*` elements ride the field line, a comment between a bare header and its fence attaches to that field, `#` inside a raw block stays content, and comments after the last binding line re-emit at the end. The older cases' expected files carry their inputs' comments too.

Case `017` pins merge-key injectivity: a single element holding a literal NUL (`x: "a<NUL>b"`) stays distinct from the two-element array `x: a, b` (`count = 2`), where a bare-NUL-joined key would merge them and drop the second. The input carries an actual NUL byte, so the cross-binding differential skips it (bash cannot hold a NUL) and the four native runners do the pinning.

Case `018` pins `field[disc]: value`: a value after a last-segment selector is an `error` (the instance is created from the discriminator, the value dropped), so the document loads at `standard` but fails at `strict`, and `city` ends up with the two discriminator instances.

Case `019` pins i64 bounds across hex and decimal spellings: the int read parses the magnitude as u64 and range-checks it against the sign, so `-0x8000000000000000` reads i64-min like its decimal spelling, `0x7fffffffffffffff` reads i64-max, and the positive `0x8000000000000000` overflows to `BadType`.

Case `020` pins the accessor surface that ports diverge on: wildcard reads across instances (`server[*].port`, and `server[*].region` where one instance lacks the sub-path, so a slot is `NotFound` and the aggregate is the worst slot), a `[value]` selector read, and a raw block read both ways (`raw` for content, `rawinfo` for the `sql` info-string).

Cases `021`-`024` pin the schema validation dimension. `021` is the all-pass sweep (every constraint kind satisfied, including a quoted wildcard path, constraints for one path split across two merged `field` instances, and an empty value passing `type: bool`). `022` produces every data-validation code `V001`-`V007` at least once - unknown fields with and without a "did you mean" suggestion, `required` missing at document scope (line 0) and per wildcard instance (that instance's line), `repeat` violated at both scopes, plus the `H001` hint riding along in the combined output. `023` produces the schema-fault codes (`V090`-`V093`) and pins that a broken schema suppresses data validation (the document's own violation must NOT be reported). `024` pins `V099`: a schema that does not parse cleanly yields exactly one line-0 diagnostic.

Case `041` pins generation over fragments: `desc`/`default` flow through the mount expansion, both mounts of the shared `node` fragment generate one full level, and the recursive `children` mounts go in the trailing block with the fragment's name in the type column; the golden validates clean against its own schema.

Case `040` pins fragment faults: `inherits` naming no declared fragment is `V095`, a nameless declaration and a non-`field` key inside one are `V094`, all at schema lines. The surviving constraint checks nothing here (its mount names the missing fragment), and the unknown-field sweep is off under faults, so the document's unknown fields draw no `V001`.

Case `039` pins fragments end to end: a self-recursive `node` fragment validates a 10-level layout tree clean, the same fragment mounted at `doc.layout` (an alias) still flags an unknown field beneath it, and a `repeat` declared on a fragment field disavows the document's `H001` under `--schema` (the plain-`check` golden keeps the hint).

Case `038` pins open-section schema validation: a `*` name segment in a schema path resolves every child of `indicators` regardless of name, so `required: yes` on `indicators.*.period` fires per child (the `V002` anchors at the offending child's own line), a field outside the declared shape is still `V001`, and children of any name are legal without enumeration.

Case `037` pins the name wildcard in lookups: `*` slots across children of any name with per-slot statuses (a childless slot keeps `NotFound`), composes with `[value]` selectors, keeps `count`/`instances` slot-aligned, scalar reads on it stay `Multiple`, and a field literally named `*` is addressed quoted (`"*"`), never by the wildcard. The write ops pin `remove` across wildcard slots, and `write-bad.ops` pins that setters refuse `*` paths (path validated whole, document unchanged).

Case `036` pins schema-declared repeat suppression: with `--schema`, an `H001` whose field declares a repeat upper bound above 1 is dropped (repetition is that field's instance mechanism by declaration) while an undeclared repeat keeps its hint; the plain `check` goldens keep both.

Case `035` pins the `H002` merge hint: a binding that merges with a non-adjacent earlier one is hinted at the later line. Adjacent re-mentions and dotted redundant-path re-opens stay silent. Its strict `load ok` row is one of the two that pin the strictness table's hint row - a hint never fails a load at any level.

Case `034` pins comment placement fidelity: a comment run written deeper than the next binding hangs on the block it sits in (re-emitted after that block's last child, at the block's indent), an over-deep comment normalizes to its block's level, and end-of-file comment regions keep the blank lines between them.

Case `033` pins escape-applied selector matching: a `["q\"uote"]` selector finds an instance written `'q"uote'` (and a bare `[it's]` finds `"it\'s"`) - the match is logical string against logical string, whichever spelling either side used. The write op does the same through the writer's place walk: the set applies to the existing instance instead of creating a spurious second one.

Case `032` pins blank-line grouping: a run of blanks collapses to one, a blank before a comment group stays with the group, and the blank survives the format round-trip (the file never starts with one).

Case `031` pins the unterminated-quote diagnostic (`E017`): a value that opens a quote it never closes, where the trailing comment still ends it, and an array-looking one, where the comma still splits the elements. Each draws one error, the pieces are kept as written (fmt re-quotes them), and the load still succeeds at Standard and fails at Strict.

Case `030` pins the generator's edge handling: an `[#N]` path and an unmaterialized optional wildcard go in the trailing not-generated block (an emitted `#` would start a comment), and a newline smuggled through an `allowed` value or a `default` stays escaped (`\n` in the annotation; the quoted spelling on the value line) instead of injecting a line. The golden validates clean against its own schema like every generation golden.

Case `029` pins the write-op value gates and unusable-path rejection: the good script covers the boundary values every binding must ACCEPT (`.5`, `5.`, i64 min, a `+` sign) and `write-bad.ops` covers what every binding must REJECT identically (hex, junk, trailing garbage, out-of-range, underscores, padding, non-ASCII digits, empty, malformed floats, every infinity and NaN spelling including `1e400`, a bad datetime, a wildcard path, a missing `[#N]`).

Case `043` pins the cost of a recursive schema: a shape mounted from two paths that both reach the same node is checked once, not once per path. Without that, a document a couple of dozen levels deep doubles the work per level and validation stops finishing, so a regression here shows up as a case that hangs rather than one that fails. The generator's own limits are pinned by a reference unit test instead - a schema long enough to reach them would be a corpus file nobody could read.

Case `042` pins the late-merge rule: a value that only becomes final after its siblings were keyed - a stacked list closing onto an earlier instance's value, a fence filling an empty field that matches an earlier block - still merges, and merging two parents merges the identical children they now share. Its layer file also pins the trivia side of a merge: the higher layer's section comment and trailing comment survive onto the matched base node, and a footer comment both files carry appears once.

Case `028` pins the 512-level nesting cap: a 513-segment dotted path draws exactly one `E016` and is skipped (the sibling line survives, strict load fails). The at-cap boundary and the Writer's refusal to create deeper are pinned by a reference unit test - an at-cap golden would be a 130 KB file for no extra coverage.

Case `027` pins the layered-merge wrapper rule: a childless over-node whose base-side name group has a container instance merges instead of replacing - bare `server:` appends an empty instance, `server: web1` with no body leaves both base servers untouched - while a childless leaf group still overrides (`mode:` clears `mode: fast`). The over layer's trailing comment-only body rides through as an orphan.

Case `026` pins schema-driven generation: `init-schema.shcl` carries `desc`/`default` on required and optional fields, an `allowed` set (rendered `one of: ...`), int and float ranges, a `repeat` bound, and a required `server[*].host` wildcard. The golden `expected-init.shcl` shows must-exist fields live (required, and `replicas` via its repeat lower bound), optional fields commented out, and the wildcard filled in dotted form (`server.host:`) because `server.port` materializes its parent - so the golden validates clean against its own schema.

Case `025` pins layered loading: a defaults layer, a site layer, and `input.shcl` as the user layer are merged bottom-up, then a `merge.sets` override. It exercises scalar override (`port`), repeated-leaf override (the whole `tags` list is replaced, not appended), container merge by `(name, value)` (both layers' children of `server: web1` combine), a new container instance from a higher layer (`server: web3`), and a `--set` override applied last.

Note when reading comparison counts: the fuzz seed set includes the corpus inputs, so adding a case shifts every mutated input after it and moves the derived total either way. The count is a per-tree constant, not a coverage score; the corpus-only count is the one that tracks coverage.

Case `046` pins partial validation under a schema fault: a bad `min` is a `V092` at its schema line, the surviving constraints still flag a wrong type and a missing required field, and the unknown field draws no `V001` (the sweep needs a fault-free schema).

Case `047` pins that a schema fault which loses a path (`field: workers, extra`, `V093`) still holds the unknown-field sweep back, so `mystery` draws no `V001`.

Case `048` pins `H002` three levels deep: re-opening `table: users` hints at the reopened line and at each nested re-mention, beside the `H001` for the repeated `col`. Under the schema, `reopen: true` drops the top hint and `repeat` drops the `H001`, while the nested hints stay.

Case `049` pins retained lines: a malformed line inside a block and one at the top level (`E014`, `E013`) are kept verbatim, written back where they sat, and count nothing lost.

Case `050` pins that quoting decides a value's elements: `x: "a, b"` is one element and `x: a, b` two, so they are two instances (`H001`) and `x["a, b"]` selects the first.

Case `051` pins a selector that reaches an instance spelled another way: a bare `x[a"b, c]` finds the two-element instance and a quoted `x["a\"b, c"]` the one-element one, while `y["p, r"]` and `z["m, n"]` match nothing and create an instance.

Case `052` pins edge whitespace through the writer: a value set with a no-break space, a vertical tab, a form feed or another Unicode space at an edge is quoted on output, so it reads back whole.

Case `053` pins blank lines in a raw body: a line longer than the closing fence's indent keeps the rest, a shorter one keeps what it has, and an empty line stays empty.

Case `054` pins escapes in names: `"a\"b"` and `'a"b'` are one name, so the two lines are a repeated leaf (`H001`), and a tab, a backslash and an apostrophe in a quoted name read back, from a lookup and from a schema path quoted twice.

Case `055` pins a raw block whose body is whitespace only: each line loses just what it shares with the closing fence's indent and keeps the rest, so the spacing survives a round trip and the block cannot gain a level per pass.

Case `056` pins the merge rule for an empty binding: a raw block in the higher layer fills a same-named empty binding below (`blk`), exactly as a fence line fills one inside a single file, while a valued binding still appends beside it (`two`). The merged golden is what parsing the two layers run together produces, which is what makes it a formatter fixpoint.

Case `057` pins that a skipped binding line keeps its indent level (`E018`): the lines written under it are skipped with it instead of attaching one level up, the next line at its own indent still binds where it should, and a malformed line that is retained as trivia loses its block the same way. The strict load fails.

Case `058` pins raw-block nesting: the closing fence's indent is what comes off each body line, so a body whose lines all sit past the fence keeps that shared indent, a line flush left keeps nothing, and the write op stores an info-string trimmed the way a fence line reads it.

Case `059` pins the two raw-block errors: a fence with no parent field (`E006`, the block is dropped) and a block that never closes (`E005`, the content runs to the end of the file and the block still binds).

Case `060` pins the stacked-list errors: an element with no parent field (`E007`), an empty element (`E009`, a `*` followed only by a comment), a bare comma in an element (`E010`), and an element under a field that already holds a value (`E011`). The survivors still read as the list.

Case `061` pins `E012`: a dedent to a column that matches no open level is skipped and written back as it was, and the next line at a real level binds where it belongs.

Case `062` pins a writer fold: `empty b` clears the value of `b: 1, 2`, which then merges with the `b` below it. The `int b.c 5` before it names which `b` the setter picked, since the merged order differs by instance; the op it replaced set a value the `b` below already had, so the golden read the same either way.

Case `063` pins `remove` followed by a `-default` on the same path: the default finds the path gone and writes it again, at the end.

Case `064` pins that `raw` refuses an info string holding a `#`, which the fence line would read as a comment.

Case `065` pins bracket text after the colon (`ports: [80, 443]`): `E019`, kept as written, nothing read and nothing lost. Its `write-bad.ops` refuses the same text from `literal`, in the default form, behind a comment and with no closing bracket, and `write.ops` accepts the quoted string.

Case `066` pins comment text through the writer: a trailing space comes off, a trailing no-break space stays, and an empty comment is a bare `#`.

Case `067` pins the i64 edge at the loose float fallback: `9223372036854775807.0` lands on 2^63 as a double and is `BadType` as an int, while `-9223372036854775808.0` reads.

Case `068` pins a `#` on a fence line in both spellings: it ends the label and opens the line's comment, so ```` ```c# ```` labels the block `c`.

Case `069` pins traversal through the `children`, `paths` and `instance_paths` rows: children in file order with repeats kept, each instance's in turn where a path has several, nothing for a missing path, every path once, quoted where a name needs it, and every binding once with `[#i]` on a name its parent repeats.

Case `070` pins a selector over a raw block and a scalar with the same display: `x[hi]` binds the raw block and `x["hi"]` the scalar, and a read of `x[hi]` counts both.

Case `071` pins the schema-fault arms: a constraint given two values where it takes one (`type`, `repeat`, `inherits`, `min`, `max`), given twice (`allowed`), or given a value it cannot take (`maybe`, `abc`, a `min` on a string) draws `V092` at its schema line.

Case `072` pins `allowed` on typed fields: a raw block against a string list, a float array beside `min` and `max`, a bool, a datetime and an int are each compared by type.

Case `073` pins `init` for a valued parent: the child lines select the instance by its value (`srv[web].port`), a quoted default stays quoted in the selector, and the output validates against its own schema.

Case `074` pins the float range: a value past the double range is `BadType` at every level, as a scalar, an array element or loose currency, the largest double reads, and an underflow reads as 0.

Case `075` pins that a skipped line holds its indent level in the other two skip shapes too: a line refused with `E012`, and a `*` line with no space (`E013`). What is written under either is skipped with it (`E018`), a fence line at a bad indent takes its whole body with it, and a second line at the same bad indent is refused the same way rather than binding one level up. The `E012` lines and the lines under them are kept as written, since their indents hold a space. The fence and its body, and the lines under the `E013` line, are lost.

Case `076` pins a value written after an index selector on the last segment (`a[0]: 2`): the instance is selected and the value is reported (`E002`) and counted as lost, exactly as after a value selector, so a save cannot quietly delete it. A same-line fence there is the same case. A value after an index that is not last still binds the deeper leaf.

Case `077` pins that a fragment mounted at one node by two schema paths (`srv` and `srv[*]` both inheriting `unit`) runs once per node: each fault under it is reported once, not once per path.

Case `078` pins what a schema disavows: a `repeat` above 1 drops the `H001` hint for a field whose path carries an escaped quote, a `reopen: true` drops the `H002` hint, and a `repeat` or `reopen` that faults (`V092`) disavows nothing, so the hint stays beside the fault.

Case `079` pins the order a merge appends in: unmatched higher-layer nodes keep that file's order (`c, a, b, a`) rather than regrouping by name, and a footer line the layer repeats itself is kept twice, while one the base already carries is carried over once.

Case `080` pins float spelling on the values where shortest-round-trip formatters are allowed to differ: powers of two, whose rounding interval is lopsided so the closest short spelling does not read back and the neighbor does, and exact ties between two spellings of the shortest length, which round to even. Every binding writes the same digits.

Case `081` pins wildcards that compose: `server[*].*` reads every child of every instance, `*.port` keeps a slot per top-level field with the worst status as the aggregate, a wildcard on a missing parent is `NotFound` with a count of zero, and the write removes `server[*].*`.

Case `082` pins `init` over wildcards: a filled wildcard is itself a valued parent (`a.b[bee].c`), an all-digit default is quoted inside a selector (`num["8"]`), and a trailing wildcard fills from its own line. The golden validates against its schema.

Case `083` pins a merge with layers that start with blank lines, one of them holding only a comment: the result equals merging the layers' canonical forms.

Case `084` pins value identity across spellings: `"q\"uote"` and `'q"uote'` are one instance, and so are `nobs` and `'nobs'`. A selector in either spelling finds it, and a layer merges into it.

Case `085` pins `allowed` on a time: `Z`, `+00:00` and `-00:00` are all the moment `12:00:00Z`, a zero fraction matches the same clock without one, and a time with no offset is not the `Z` moment (`V004`).

Case `086` pins a bare index on a binding line that names no instance: `a[5].b` is `E003`, dropped and counted lost, while `c[1].d` reaches the second `c`.

Case `087` pins where a merge puts a layer holding only a comment: above the base's trailing comment, after the field. The field is spelled without a colon (`E015`) and still binds.

Case `088` pins a quote in the middle of a bare value as content: `don't panic` leaves its trailing comment a comment, and apostrophes, mid-text double quotes and a quoted `#` read as written.

Case `089` pins bracket text behind a colon that is not the field's own: after a quoted name holding one, a selector holding one, and selector sugar, `[80, 443]` is still `E019`, kept, with nothing lost.

Case `090` pins a crossed range (`min` above `max`): `V092` at its schema line, while the other constraints still apply and the unknown-field sweep still names `bogus` and `other`.

Case `091` pins a leaf override in a merge: the base leaf's value goes, but a retained bad line above it and a bad `*` line under an overridden field stay in the merged file.

Case `092` pins that a default form refuses a wildcard path whether or not its slots resolve, while the same default on a named instance writes only what is missing.

Case `093` pins `allowed` on a datetime with an offset: the same instant written at another offset matches, across a day boundary too, and the same clock at another offset does not.

Case `094` pins what trimming takes off a bare piece: a space, a tab and a carriage return. A no-break space, a line separator, a vertical tab or a form feed at an edge is content, kept and quoted on output.

Case `095` pins that a dropped element holds its level: what is written under an `E008`, `E009` or `E011` element is `E018` and lost with it.

Cases `096` and `097` pin a raw block that never closes, with and without a final newline: `E005`, and the block reads `body` either way.

Case `098` pins a comment added to a node that already has one, with a blank line above the node: the new comment goes under the old one, and the blank moves above both.

Case `099` pins `literal` on text that only looks like syntax: a fence opener and a spaced string are stored as quoted strings, while an unclosed quote in the first or a later piece and a leading `[` are refused.

Case `100` pins integers past the i64 range: hex, decimal and quoted-thousands spellings read as floats and are `BadType` as ints.

Case `101` pins an empty name: two `""` leaves are a repeated leaf (`H001`), and a schema declaring `repeat: 1, 5` on the field drops the hint. It carries the `H001` half of the strict `load ok` pair described under case `035`.

Case `102` pins one field spelled twice in a schema (`w` and `w[*]`): `init` writes one line.

Case `103` pins an all-digit selector past the u64 range: an index naming no instance, so the binding line is `E003` and lost, a read is `NotFound`, and a write through it is refused.

Case `104` pins an element with no parent field at the top of a file (`E007`, dropped): its trailing comment is kept.

Case `105` pins bare selector bodies holding an apostrophe, a mid-text quote or a trailing backslash, and quoted ones spanning a `]` or holding a `#`, each followed by a comment that stays a comment. No diagnostics and nothing lost.

Case `106` pins the 2.x selector sugar under the 3.0 rules: `base:[Boston]` is bracket text, `E019` and kept, the line under it is `E018`, and the load fails at Strict.

Case `107` pins recursive fragment mounts under the validation memo: a type fault seven mounts down (`V003`), a star path through a mount, and an unknown leaf at the bottom (`V001`) are all still reported.

Case `108` pins bracket text holding an index or a wildcard (`[80]`, `[*]`): `E019`, kept, nothing lost.

Case `109` pins a `#` in a bare selector body on a file line: it opens a comment, the selector is left unterminated (`E014`), and the line is kept with nothing lost. `[#N]` is a lookup spelling only.

Case `110` pins `init` for a schema listed out of tree order, a parent after its child with another field between: the output keeps tree order and loads with no diagnostics, hints included.

Case `111` pins a backslash in a bare selector body as a character: `p[C:\temp]` and `r[a\nb]` select the instances already there rather than creating second ones.

Case `112` pins three setters through the tokenizer: a comment's trailing blanks come off, a raw info string keeps its leading blank, and a quoted `#` given to `literal` stays in the value. A comment holding a line break is refused.

Case `113` pins `init` spelling a line break in a by-value selector and in a name escaped, so neither starts a new line. It carries both schema spellings: the escaped one, and the real line break that `\n` inside a double-quoted schema value resolves to. The second used to be kept as written and generated two lines that the self-check then refused.

Case `114` pins raw reads: an empty binding is `Empty` for `raw` and `rawinfo`, a value that is not a block is `BadType`, and a block reads its body and label.

Case `115` pins a carriage return as a blank outside a raw body: trimmed at the edge of a name, a selector, a value, an element and a comment, and content in the middle of one.

Case `116` pins a selector body that opens a quote it never closes: `E017`, kept as bare text quotes and all, so `srv["prod]` is its own instance and not `srv[prod]`, and a line whose selector and value both open one reports each.

Case `045` pins comment depth under childless headers: a header whose children are all commented keeps them indented under it (top-level, nested, and at end of file), while a commented line trailing a live child keeps the existing trails-the-binding placement.

Case `044` pins the value-syntax setter: an array, a single element, a quoted element keeping its internal comma, trimming, a `#` outside quotes ending the value wherever it sits (`#ff0000` leaves it empty, `a#b` keeps `a`, `x#` keeps `x`), an empty value, and the only-if-absent form both skipping an existing path and creating a new one. Its `write-bad.ops` pins the two rejections - a value opening a quote it never closes (the same text the parser reports `E017` for) and a wildcard path.

Case `117` pins how `migrate` spells a 2.x `name:[disc]` line on a last segment. A discriminator carrying a fence run or a leading `[` is quoted when the sugar becomes a value, so the rewrite opens no raw block and no bracket text, at top level, nested, spaced, with a trailing comment and with children below. An ordinary discriminator stays bare (`plain: Boston`), one the formatter would quote is quoted (`city: "New York"`), and the author's quotes are kept. The input itself is refused line by line under the current rules, which is the damage migrate exists to prevent.

Cases `118` and `119` pin how `migrate` spells a piece holding a backslash: always in double quotes, in a value, a star element, a selector and the sugar arm. 2.x read a backslash in bare and single-quoted text as an escape, so the migrated file reads the same under 2.x, and a second run changes nothing. `118` also pins a bare backslash before a comma, the line end and a comment, where a spelling that reads right alone would shield what follows it. `119` also pins a quoted discriminator with text between its closing quote and the `]`, which 2.x refused as a malformed line, so `migrate` leaves it as written.

Cases `122` and `123` pin a backslash in a selector body, which 2.x shielded inside quotes only: a bare body runs to its first `]`, so the line still reads and the rest of it migrates. `122` is clean under 2.x, so the migrate gate compares it document by document; `123` carries the sugar spellings, where a comma behind a backslash never made the brackets an array, and a real two-element bracket array stays as written.

Case `124` pins a CRLF file whose raw block closes before a line `migrate` rewrites. The closing fence ends in a carriage return, and the block still has to close there, or the sugar and the backslash value after it are taken as block content and left as written.

Case `120` pins `init` on a last-segment by-value selector with a default: the line is spelled as the bare path carrying the default (`env: prod`), and without a default the selector line stays.

Case `121` pins that a default form judges the value as well as the path. Its `write-bad.ops` gives bracket text and an open quote on paths that already resolve, where the form writes nothing, and bracket text again on a path that does not. Every line is refused either way.

Case `125` pins an optional child of an optional valued field in `init`: the commented child selects the parent by its default (`# srv[web].port: 80`), so uncommenting both lines names one instance. The input is that output with both lines uncommented.

Case `126` pins a skipped field line whose value opens a raw block, under a skipped parent (`E018`) and at an indent that matches no open level (`E012`). The body goes with the line. Read as lines, it bound its own `port` and `name`, and its closing fence opened a block that ran to the end of the file.

Case `130` pins a wildcard remove over a leaf that repeats under one instance. A read calls such a slot ambiguous, and the remove used to skip it, leave the data and exit 0. Its reads still expect the ambiguous slot, so the two answers are pinned apart.

Case `129` pins a remove that matches many nodes at once. One path takes every child of a parent, another takes several top-level instances, a third matches nothing, and a write after them shows the parent and the name index still answer. Each match used to be dropped on its own, rebuilding the parent's whole child list every time.

Case `128` pins the column a kept `*` element holds, beside case `095`'s dropped one (20260918b item 28). A field written deeper binds under the field (`E001`), the next field at the element's column binds as its sibling, and an element after a field child is `E008`. Every later sibling used to be `E012` and lost.

Case `127` pins the `init` shapes where the generator guessed what the scanner would read (20260918b items 6, 7, 8, 25, 26 and 27). The first of two lines on one path is the instance its child selects. Two by-value fields with different values are two instances. An all-digit value past 64 bits is a quoted body, since bare it reads as an index. A quoted array element selects by the elements joined. A `#` in a selector body is quoted. A fragment name holding a line break stays inside the trailing block. The input is the output with every line uncommented, and its reads count the instances.

Case `131` pins the fence a writer picks for a raw body that already holds one. A body with a three-backtick line gets a four-backtick fence, one with three and four gets five, a tilde run leaves the backtick fence at three, and a run with text after it is content and counts for nothing. The read half is in the same input: a five-backtick opener, a closing fence indented deeper than its opener, a backtick line with trailing text that does not close, and a tilde line inside a backtick block.

Case `132` pins a space-indented file and a subtree indented tab-then-spaces, which the spec allows and which anyone coming from YAML writes. Nothing else in the corpus indents with spaces except `075`, where they are the fault under test.

Case `133` pins a leading UTF-8 BOM, the ASCII-only case fold, and non-ASCII field names. `Srv` and `srv` are one container and an uppercase lookup finds it. `"clé"` and `"Clé"` fold together; `"CLÉ"` folds to `"clÉ"` and is a different field, because the fold is A-Z only and C counts bytes. A bare non-ASCII name is `E014` at the byte column where the name stops being bare.

Case `134` pins real override for a raw block and an inline array, which `design.md` promises and the merge dimension only ever pinned for scalars and repeated leaves. The base layer's shell block and three-element array are replaced whole by the top layer's python block and single element, and a raw over-value fills the base's empty binding.

Case `135` pins a schema path carrying a value selector, and the `bool-array` and `datetime-array` types, which no other schema names. The `max` on `srv[web1].port` leaves `srv[web2]`'s larger port alone, so a selector read as a wildcard shows up as an extra diagnostic.

Case `136` pins the number spellings a hand-edited file carries - `007`, `+5`, `-0`, `+0009` - which read as integers and keep the spelling the author wrote. Beside them, a closed quote followed by bare text (`"abc"def`) is `E017` and the whole text is the value, and the path spellings that resolve to nothing: an empty selector, a leading dot, a trailing dot and a doubled dot.

Case `137` pins that a line matching no open level (`E012`) closes none of the levels open before it. A space-indented line in a tab-indented block used to drop every later sibling in the block. The siblings bind now, and so does the first child of a leaf written after the bad line. A line deeper than the bad line is still `E018`, as `075` pins. Every bad line is kept as written, so nothing is lost.

Case `138` pins that a run of whole-line comments keeps its order and its nesting. A commented-out header and its commented-out child, at the top level, inside a block and at the end of the file, and a run whose later comments sit deeper than the block the first one trails. The input is its own canonical form. The deeper comment used to hang on an earlier block and come back ahead of the comments written before it.

Case `139` pins a comment and a malformed line written under a stacked list whose field ends up equal to an earlier instance, `q: 3` then `q:` with `* 3`. The field folds into the first `q` at the end of the load. Both lines were filed on the instance that went away and were not written back.

Case `140` pins where a comment inside a block goes when the block has children. The input's comment sits between the block's column and its child's, so the load files it on the block, where a reload of the canonical text files it on the last child. The merged golden has the comment right after `b`. Filed on the block, it went after the base layer's `c`, while the canonical form merged with it after `b`. Both layers also end on the same commented-out footer, nested one level deeper in the top one. The merge keeps one copy of each repeated line, and the top layer's last line comes one level past the base's line before it, since a reload would read no deeper.

Case `141` pins the order of a fold inside a fold. The second `x` fills from a fence and folds into the first, and inside it the second `a` does the same to the first `a`. Each `a` has a trailing comment, and so does the surviving one. The two demoted comments come out as `# A` then `# B`. Folding the inner pair before the outer one gives them the other way round.

Case `142` pins a comment left above a block's later instance. `# c` follows `p` at `p`'s level, and then `m` opens again and adds `s`. A reload of the canonical text files `# c` on `s`, so the load does too, and the merged golden has it just above `s`. Left on `p`, it went after `p` at the end of `m`, while the canonical form merged with it above `s`.

Case `143` pins where comments go once a merge or a write changes a block, which must be where a reload of the saved text puts them. Three layers merged at once keep `# inside` right after `c`, above the top layer's `d`, as merging two and then the third from saved text does. Two children written into `k`, whose only line is a comment, get the comment between them, as two separate runs of `set` do. And a raw block after an empty `b` has its trailing comment written on the line above it, which a reload files as a leading comment, so it stays there once the empty `b` is set to 5.

Case `144` pins the `H003` hint (20260923 item 18). A bare stacked element spelled `name: value` or `name:` is one string, and the load says so, since a list of objects in the YAML style reads that way without a word. Text with a blank before its colon, a colon with no blank after it, and a quoted element get no hint.

Case `145` pins which misplaced lines a save keeps. An `E012` line whose indent holds a space is written back as it was, and so is an `E018` line under it. An `E012` line indented with tabs alone would bind on a reload, so it is lost. A kept line that a re-opened block carries up to the top of the file would bind there as written, so it is written as a comment instead.

Case `146` pins a stacked list holding kept lines among its elements and after the last one. The list stays stacked with each line where it was, so a line fixed by hand is still inside the list. Without them the same list is written inline.

Case `147` pins how a misplaced line fares by indent style (`design.md` -> Load outcomes). Output is always tabs, so a stray space in a tab-indented block and a miscounted run of spaces in a space-indented block are kept as written. A tab line in a block that skips a level and a stray tab in a space-indented block would line up with a tab level on a reload, so both are lost and a save refuses.

Case `148` pins `clear-comments`: every comment line above a node comes off, a group heading included, while the comment on its own line stays. The blank that set the run off stays with the node, so a comment set after it sits where the old one did. A path that reaches nothing changes nothing.

Case `149` pins `banner on`: an old info block in the footer comes off, found by its version line, not its links, and so does a bare version stamp from `migrate`. A `##` comment set off by a blank line stays. A second `banner on` changes nothing. Its `write-bad.ops` refuses a value other than `on` or `off`.

Case `150` pins the save that keeps lines on a file kept by hand: four-space indents, padded values, a quoted value and capital letters in names. A changed value goes into its own line with the spacing and comment around it left alone, a new child takes its siblings' indent, a removed field takes its lines with it, and a rewritten raw block keeps the name's spelling. A stacked list given new values comes back inline.

Case `151` pins the edges of a file: a byte-order mark, CRLF line ends and no newline at the end all stay, and a new line gets CRLF too.

Case `152` pins two edits that give the canonical form: a child added under flat dotted lines, and a value changed where a selector elsewhere names it.

Case `153` pins a comment above a flat dotted line and above a selector line. The canonical form writes each comment inside the block the line makes, and the save keeps both as written. A changed value on either line goes into the line.

Case `154` pins a child under a stacked list. Kept stacked, the list would reload with `E001`, so the save gives the canonical form. There the list goes inline, and a malformed line kept among its elements moves above it.

Case `155` pins a selector that puts a child under an earlier block. The canonical order differs from the file's, so an edit anywhere gives the canonical form.

Case `156` pins a repeated block header and a repeated field between two kept lines. Both stay where they were.

Case `157` pins a repeated block header after a line that gains a new child. The child goes above the header, which stays as written.

Case `158` pins a repeated field at the end with a new field written after it. The repeat stays as written, above the new field.

Case `159` pins a line the load dropped, a tab-only indent that matches no level. A save that keeps lines writes it back as it was, with a new child of the block above it written above it.

Case `160` pins a dropped list element between two instances of a block, kept as written when the second one is edited.

Case `161` pins info blocks a hand edit moved out of the footer, one above a plain field and one above a dotted line. `banner on` takes both off and adds one at the end. A comment nested under a footer block moves out to the column the block was at.

Case `162` pins the `comments` read: the lines above a node from the `#` on, both instances' lines for a repeated leaf, nothing for a node with none or a missing path.

Case `163` pins a comment at an element's column after a stacked list's last element: it stays inside the list, under an inline list and under one a malformed element keeps stacked.

Case `164` pins quoted data values in canonical output: a quoted int, float, bool or date comes back bare, element by element, while a quoted plain string keeps its quotes.

Case `165` pins a comment set on a node the writer just created at the top level: the blank line goes above the comment, not between it and the node.

Case `166` pins numbers far past any type's width, 5000 digits: an int value, a quoted one, a day inside a quoted date, a selector index and a schema `repeat` bound all read as out of range, and a small value behind 5000 zeros still reads.

Case `167` pins generation over a wildcard spelled with blanks inside its brackets, which fills exactly like `[*]`.

Case `168` pins validation of a schema path whose `[#N]` index is past every int width: it finds nothing, and the required one reports missing.

Case `169` pins the writer's fold two levels down: emptying a block value makes it equal to a later block, and the children the two now share fold at each level, as a reload would.

Case `170` pins an unknown escape in double quotes: `E023` in a value, a quoted name, a selector body and a stacked element. Each line is kept as written and binds nothing, while single quotes, bare text, a doubled backslash and a raw block's info string read clean. Its `write-bad.ops` refuses the pair from `literal` and in a setter path, and its migrate golden doubles each backslash.

Case `171` pins the Windows path hint `H004`: a drive or share path in double quotes whose `\t` or `\n` is real gets the hint on a value, an inline array element and a stacked element. The document still loads clean at Strict, loses nothing, and keeps every line through a write. A doubled backslash, single quotes and a message with a `\n` get no hint.

Case `172` pins a quoted number with a leading zero: it keeps its quotes through canonical output, element by element, while a bare one stays bare and a quoted `0.5`, `0` or hex value comes back bare. Int and float reads drop the zeros, and a string read keeps them.

Case `173` pins the `0x`, `0o` and `0b` integer prefixes in either case and with a sign, a bare leading zero read as decimal, bad digits and an empty prefix as `BadType`, the int range at both ends, and a float read past it.

Beyond the fixed corpus, the differential harness (`cicd/utility/crosscheck.bash`) also derives accessor coverage over the fuzz set: the reference's fuzz dump writes a `<name>.reads.tsv` beside each dumped input (paths it knows exist, cycling type and strictness), which the `--extra` replay runs through the same row machinery. Every scalar read row - corpus and fuzz-derived - is additionally replayed under `--on-bad=error` (an exit-code differential) and `--default=<x>` (a stdout differential), so the on-bad/default policy surface is pinned cross-binding too. It also runs three `set` edits (a changed value, a new child, a removal) on the first paths of every input, corpus and fuzz alike, so the save that keeps lines is compared well past the goldens.

Not yet modeled natively (as golden files): the on-bad/default outputs (covered cross-binding via the harness above, not by per-row `expected`). Diagnostic expectations are modeled natively via `expected-diags.txt` (above) and cross-binding via the `load` rows.
