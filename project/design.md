<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Design

Design, requirements, and direction. The task list is in `backlog.md`. The full language definition is in `spec.md` (with `grammar.abnf`); this file stays high-level - the *why*, not the letter of the rules.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Assumptions](#assumptions)
- [Guiding principles and decisions](#guiding-principles-and-decisions)
- [Architecture](#architecture)
	- [Software stack](#software-stack)
	- [Configuration model](#configuration-model)
	- [Consumer API](#consumer-api)
	- [Integration modes](#integration-modes)
	- [Power layer (library-level, grammar untouched)](#power-layer-library-level-grammar-untouched)
	- [Schema validation](#schema-validation)
	- [Formatter](#formatter)
	- [Saving a file](#saving-a-file)
	- [Save outcomes](#save-outcomes)
	- [Load outcomes](#load-outcomes)
	- [Lexical edges](#lexical-edges)
	- [Write outcomes](#write-outcomes)
	- [Kept lines under edits](#kept-lines-under-edits)
	- [Generation outcomes](#generation-outcomes)
	- [Testing](#testing)
	- [Format comparison](#format-comparison)
	- [CI/CD](#cicd)
	- [Reference implementation](#reference-implementation)
	- [Go binding (Tier 2)](#go-binding-tier-2)
	- [C binding (Tier 2)](#c-binding-tier-2)
	- [Shell wrappers](#shell-wrappers)
	- [Man page and completions](#man-page-and-completions)

<!-- /TOC -->

## Assumptions

- The language began by worked example, before the spec existed. Where the early examples and the spec disagree (and they do), `spec.md` wins.

- The language is delivered as tiered bindings, plus single-file drop-in source and compiled binaries per platform.

	- The guarantee is the corpus, not the binding count. Every released binding is corpus-green, and nothing is released before it is.

	- Tier 1: the Rust reference and the `shcl` CLI built from it. Rust wins on the stated priorities: small binary, instant CLI startup, a clean shared-library build, and compile-time strictness that forces spec precision.

	- Tier 2: Go, C (with C++ over it), Python.

	- Tier 3: the rest (C#, Java with Kotlin, JavaScript), deferred for now, corpus-gated, designed for from the start.

	- Bash and PowerShell are thin wrappers around the CLI, not independent parsers. They inherit conformance for free. The companion typed surfaces (C++, Kotlin) are one core plus an interface of their own, not separate parsers.

## Guiding principles and decisions

The inescapable core tradeoff (for any config language) is to acknowledge and optimally balance "simplest possible" versus "expressive enough for anything" - including a simple DDL language. Ultimately it comes down to two factors:

1. Ideologically-driven opinion on where the balance should be - informed by technical experience, related PTSD gained along the way, childhood trauma - all of it.

1. The observation that processing power is now dirt-cheap even on the smallest embedded systems, validation and "correctness" tools are now incredibly powerful - and the subsequent decision to move as much of the heavy-lifting of the language on to this code, and away from end users and programmers.

Other points

- Optimize for the hand-authoring user and the value-consuming programmer; burden neither. Any ambiguity a modern parser can resolve from context, it must - the user is never made to satisfy the machine.

- The data model is relational, not a map. The left-of-colon token is a *field* (column), not a unique key; repeating it with different values yields *instances*. One rule covers wrappers, leaves, and valued instances: nodes are `(name, value, children)` and merge on matching `(name, value)`.

- Typing is accessor-driven: the parser stores raw text and never guesses; the consumer requests a type on read and the library coerces intelligently but safely, reporting problems without ever refusing to keep working.

- Forgiveness is a feature: never bail on a whole file for one bad line; skip/repair and diagnose; never error when a value is legitimately reachable.

- Forgiveness is also a knob, not dogma. There are three strictness levels (Loose/Standard/Strict, per-document, default Standard) instead of a binary strict flag. Standard keeps the defaults clean (no currency stripping, no `%` fractions, no float->int rounding, trimmed boolean set); Loose re-admits those conversions as a closed list for those who want maximum forgiving; Strict fails the load on any error diagnostic, the StrictYAML-style answer. Defaults are what adopters judge; the party tricks survive as opt-in. The normative bundle table is in `spec.md`.

- The knob belongs to the consuming program, not to the end user. Strictness and bad-read handling are part of the contract an application makes about its own config handling, so they are set at the call site (or the CLI flag) and nowhere else. A per-user defaults file was considered and rejected: it would let a user silently weaken guarantees an app relies on, and would make an identical `shcl` invocation mean different things on different machines - the `GREP_OPTIONS` mistake. Nothing else the CLI exposes is presentation-only, so SHCL has no user config file at all.

- Coercion earns trust by refusing to surprise: silent lossy conversion (rounding a float on an int read, `$1200` as a number) was cut from the default level for exactly that reason. Same logic killed the fehu anti-escape rune (raw blocks are the verbatim escape hatch) and restricted field-name case folding to ASCII (full Unicode folding is a locale trap and a cross-binding parity risk).

- Name identity normalizes by escape resolution, as of 2.0.
	- A name used to be compared and emitted in its escaped spelling, so `"a\"b"` and `'a"b'` were two fields while those same two spellings as values were one string - the two halves of the language disagreed on what a quoted string means, and a consumer splicing user text into a path had to know which half it was in.
	- Escapes now resolve on names too: they already normalized once (ASCII case folds), so this finishes a rule the language started rather than inventing one.
	- It waited for the 2.0 major because it moves canonical output for a spelling already published, and because two fields that were distinct merge - the same class of merge case folding already performs.
	- The as-authored accessor is deliberately the one call that still hands back the source spelling; that is what it is for.
	- Emitting needed a real escaper rather than the value one, which picks a quote style to *avoid* escaping and never escapes a backslash - correct for a value, which is stored in its escaped spelling, and wrong for a name, which is stored resolved.
	- One consequence fell out for free: a line break in a name is now writable, because the name escaper writes it as `\n`, where before it had to be refused. A line break in a `[value]` selector is still refused, since the value emitter has no such spelling.

- Raw (fenced) blocks give verbatim escape hatches (DDL, code, templates) without contorting the config syntax.

- A fence is just a value line for its parent field. The same-line spelling (`name: ~~~sql`) read badly, so the canonical spelling puts the fence on the next line at child indent - and rather than special-case that, the rule is uniform. A fence fills the parent's empty value, or creates a new instance if the parent already has one (the repeated-leaf rule). Blocks are then ordinary instances: no index-addressing syntax to invent, and the existing `[0]`/`[#N]` selectors just work.

- Parity over idiom in the bindings: each port deliberately mirrors the reference's structure - same function inventory, same call flow, same contract strings - even where the host language would idiomatically do it differently. Byte-for-byte agreement is the product's core guarantee, and structural parallelism is what makes it maintainable: a fix ports by mechanical diff instead of re-derivation. Per-language idiom keeps the surface (formatters, naming case, doc comments); it yields on structure. The full rules and each accepted deviation live in `style-guide_code.md`.

- Positioning: the pitch is "forgiving to write, predictable to read", with a read API built junior-first - not "simplest possible", which overpromises and invites the takedown. Versus schema-bearing languages (Pkl, CUE): the file stays dumb, the library is powerful (see Power layer).

- The CLI's informational outputs are flags: `-h`/`--help`, `-v`/`-V`/`--version`, `--about` and `--donate` (2026-09-28). `help` also stays a word, since it takes a topic (`help CMD`). The words `version`, `about` and `donate` went, and a leftover one gets the did-you-mean hint. The flags are recognized anywhere in option position, after FILE included, since where on the line a person types `-h` says nothing about what they want; only a value slot and anything after `--` are data.
	- Several asked in one run each print once, in the order asked, with one blank line before, between and after. `--about` covers `--version`, since it opens with the version line. A lone `--version` stays one bare line, for scripts.
	- `help` refuses anything after it but one topic and the informational flags.

- It was decided that `-` (stdin) may be named only once across FILE, `--layer` and `--schema`. There is one stream, so two names for it each read part of a document, and which name got the real content depended on read order; the second name is a usage error instead.

- **Nothing on the command line resolves last-wins.** Two options asking for different answers are a usage error whichever order they came in, and the message names both. The rule covers two different type options on `get` and one value option given two different values; a repeat with the same value competes with nothing, and `--layer` and `--set` are ordered lists, so they repeat by design. The rule is what a new option is judged against, not the list of pairs.
	- Why: `get --raw --int` printed the int and `get --int --raw` failed at exit 4, so the same two flags gave two answers and neither said anything. `--default` against `--on-bad=error` had already been fixed the same way, one pair at a time. The rule closes the class instead.

- Those outputs print with a blank line above and below, so the block does not butt up against the shell prompts either side of it. Bare `shcl` counts as asking: it prints the same padded help as `shcl help` and exits 0. `version` stays unpadded on purpose, a single bare line so a script can still capture it cleanly. The rule is "padded when a person asked for it", not "padded when it is long".

- The lexical rules are few, and a byte's position decides what it means. The rule table is under Lexical edges below; `spec.md` has the normative wording.
	- Why: the same lexical rule lived in seven scanners per binding, and every scanner defect since July was two of them disagreeing. A fix reached the copies that were reproduced. One tokenizer per binding replaces them, and fewer rules leave it less to get wrong.
	- What changed at 3.0, and what `migrate` rewrites a 2.x file for: escapes are processed inside double quotes only, single quotes are literal, and bare text never processes a backslash, which is TOML's and YAML's rule. A quoted piece opens with a quote as its first character and closes at the next matching quote, which has to be the last thing in the piece; anywhere else a quote is a character. The `field:[disc]` sugar is gone, so a `[` right after a name is a selector and a `[` first after the colon is bracket text.
	- Escapes, quoting, arrays and the hidden-character list moved to [the value syntax design](design_docs/value-syntax.md), with what replaces the backslash escapes, `E023` as it is now and `E024`. The build still has those until that design is built.
	- The cost, said once: a bare `\n` or `\t` and a single-quoted escape change meaning, and a bracket array 2.x folded into one string binds nothing. `migrate` rewrites a file in one pass, and a 2.x reader is unaffected by the migrated file. There is no 2.1.0; everything since 2.0.0 goes out in 3.0.0.
	- What did not change: the comment rule is 2.x's, so a 2.x file's comments and values read the same before and after. Three edges do read differently, and `migrate` leaves all three: a fence label holding a `#`, which 2.x ran to the end of the line and which has no quoting; a carriage return at a piece's edge in the middle of a line, which 2.x kept and which is a blank now; and an indent landing on no open level's column, which 2.x placed by a looser comparison and which is `E012` now, since `migrate` rewrites spellings and not layout.
	- Which rules wrote a file is not in the text, so the info block has a `Format` line naming the format's major and `migrate` is the only command that reads it. `format_version` hands a program the same answer, so it can ask before it rewrites anything. A file with the current major has nothing to migrate; one with an older major, or a caller passing `--from-2x`, gets the backslash re-spellings; anything else gets every other rewrite and leaves those pieces as written, at exit 7. A rewritten file is stamped with the line and a migrated-from note, which is what makes a second run a no-op rather than a second rewrite of the first one's output. The library never adds the whole block, since that would write bytes the document does not hold, and it does not stamp a file that never closes a raw block under either rule set, since the line would end up inside the block as content. `shcl migrate` refuses that file at 7 rather than write it unstamped, which would leave the next run unable to tell it was migrated. `migrate_unstamped` leaves the stamp off for a program that writes the whole block itself as its footer, which then includes the line.
	- `migrate` reports what it could not convert rather than exiting 0 over it: the pieces it could not decide between the two rule sets, and the one form 2.x bound that nothing binds now, bracket text after the colon. Both are exit 7, and each has its own override - `--from-2x` for the first, `--lossy` for the second on a rewrite - because one is a question the text cannot answer and the other is a real loss.
	- `migrate --write` ends with two files rather than one converted in place: the new text at the path, and the original bytes beside it as `NAME_old_v2.EXT` (2026-09-27). The copy is made only when a line is rewritten, since a file that only gains the Format line reads the same under both rule sets and may be a 3.0 file nobody stamped. It is an exclusive create, synced, at the original's mode, and it is written before the save starts. A taken name is exit 8, never an overwrite. If the save then fails and the file still holds the original, the copy is removed so the next run is not blocked; if the file does not, as after a replace that failed part way on windows, the copy stays and the error names it.
	- `migrate --check` compares the input and the migrated text line by line, in the CLI. The rewrite never adds or drops a line ahead of its stamp, so line N is line N on both sides, and the library needs nothing new. A line to rewrite is exit 6, the code `check` uses for a file with something to fix, and exit 7 still wins when `migrate` could not finish or when the save gate would refuse the rewrite. `fmt --check` asks that gate the same way.

- One tokenizer per binding is the only reader of a line's parts. It takes text and a separator and hands back spans: per segment a name and an optional selector body, each with how it was quoted; the separator; the value and its elements; the comment; or the fault that makes the line malformed. Nothing is copied. The parser's line dispatch, the path scanner behind every lookup and setter, `SetLiteral`, `SetRaw`'s info check and the CLI's `--set` split all read those spans, and the seven scanners they replaced are deleted rather than wrapped. A 2.x flag on the same tokenizer is what `migrate` reads with, so the old rules live in one place too.
	- Pinned by a `tokens` subcommand on every CLI, compared four ways over the corpus and the fuzz soup, and by a generator in the reference that builds lines from the grammar with their spans known and asserts the tokenizer returns exactly those.

The itemized decisions are recorded in this file as they are made; `spec.md` is their normative form.

## Architecture

### Software stack

Many bindings with a shared conformance corpus (`conformance/`) as the contract between them. One portability constraint shapes the Accessor: the requested value type is expressed by a typed entry point or a compile-time generic, never a runtime `type` field, because static languages (Go, Rust, C, C++, C#) cannot let a runtime value drive a return type. Prebuilt binaries cover Linux and Windows, on x86_64 and ARM64, and FreeBSD on x86_64. FreeBSD cross-builds with zig, the same way as Linux ARM64. Rust has no prebuilt std for FreeBSD on ARM64 or for OpenBSD, and cargo-zigbuild does not take NetBSD, so those build from source. So does macOS, since there is no Apple SDK on the build box.

### Configuration model

See `spec.md` - fields/instances, accessor-driven types, arrays vs instances, raw blocks.

### Consumer API

The consumer-facing surface is the **Accessor** (read) and the **Writer** (emit).

- The Accessor's one conceptual operation is a **lookup** (query) - get a value at a path, coerced to a type, with a default and an on-bad policy - realized idiomatically per language.

- The type is chosen by a typed entry point or compile-time generic (not a runtime field), so results go into a strongly-typed variable with no consumer cast everywhere.

- For consuming a file as a whole there is **traversal** (scan): materialize the document - merge duplicates, order deterministically - then walk it (wildcards, instance enumeration).

- The Writer is the reverse: write out defaults, values, and comments. Structured diagnostics ride alongside.

The consuming programmer is assumed to be a junior in *every* binding, not just the dynamic ones, so ergonomics are a design constraint, not an afterthought. Decided:

- Two tiers, junior-first. A convenience tier is the documented default: one value, one baked-in fallback, one return, no status to inspect. The full tier, the status-returning form, is there when the caller needs to know *why* a read failed. Every binding names the convenience tier `_or`, so a routine ported between two of them cannot keep the call name while changing tier; each language's native idiom for the same thing still works where it has one (Rust `unwrap_or`, Python's default argument, the CLI's `--default=`).

- A supplied default implies default-behavior. The caller never writes a fallback *and* an explicit on-bad - which is why the libraries have no on-bad parameter at all: the tier you call *is* the mode. `Error` mode has no library form, because a read that cannot reach a value is a normal outcome rather than a fault, and a caller who wants a throw already has the status to raise on. The CLI keeps the explicit `--on-bad`, having no tiers to choose between.

- The convenience tier defuses the one real hazard of a forgiving accessor - a junior discarding the status and trusting a `0`/`""` that was actually empty or missing. Making the fallback mandatory and visible at the call site means an unwanted zero can't slip in unseen.

- Portability is unaffected: the type is still fixed by the entry point/generic, and the fallback is an ordinary parameter.

- **Resource caps are the caller's, not constants.** The depth cap is a constant because no legitimate document is 512 deep, but a legitimate large config genuinely has millions of nodes, so one built-in number would either refuse real documents or sit too high to protect anything. Decided: `ParseLimited` takes a node cap, an array-element cap and a diagnostics cap (0 = uncapped), new API surface added the same way in every binding.
	- At the node cap the parse stops and reports once (`E020`), with the unparsed remainder counted as lost. Skipping line by line, the way the depth cap recovers, would emit one diagnostic per remaining line on exactly the input the cap exists for.
	- An over-long array refuses its whole line (`E021`). Truncating it would leave a value the author never wrote, checking clean forever after - the bracket-array lesson.
	- Past the diagnostics cap the list ends with one `E022` counting the rest. A document of nothing but bad lines otherwise costs a diagnostic per line, which is the cost the element cap alone cannot bound.
	- The depth cap keeps its skip-and-continue recovery. It was weighed against stopping there too and left alone: a deep line already loses only its own subtree, every dropped line is diagnosed and counted lost, and the save gate refuses to rewrite the file - while stopping would also discard everything after the deep line, which is more loss, not less.

- **Reading a whole config into one structure is declined, not overlooked.** Every binding is path-at-a-time, so a forty-key config is forty call sites - and users arriving from libraries that decode a document into a typed struct in one call will notice.
	- It was considered and turned down, because the reference cannot implement it: a derive-based decoder needs a proc-macro, which is a second crate, and one file per binding with no dependencies is what the product *is*.
	- Hand-writing the reflection instead would give each binding its own machinery with nothing in the reference to mirror - the parity rule inverted, and the thing that keeps a fix portable by mechanical diff.
	- A binding-local decoder in the two languages that could do it cheaply would be worse than none, since the same config would then load two different ways depending on the language.
	- The plain answer is that the forty call sites are one loader function a consumer writes once, and `Children`/`Paths` plus the typed reads are the material for it.

### Integration modes

One question - "how do you pull SHCL into your project?" - with two kinds of answer: *run it* or *embed it*. Named plainly and ordered easiest-first, so a beginner starts at the top:

- **Command**. Run the `shcl` CLI from a shell or script. Nothing to compile, nothing to link.

- **Drop-in**. Copy one source file into your project. No dependency and no build step. You own the copy.

- **Package**. Add it as an ordinary dependency and let the package manager fetch it (`go get`, `pip install`, `cargo add`, and so on).

- **Shared library**. Compile a drop-in source file into a `.so`, `.dll`, or `.dylib` and link it at runtime. The library stays a separate file.

- **Bundled**. Compile the same source into your binary, so you distribute one self-contained file.

The last two are the same code compiled two ways - "shared" stays a separate file loaded at runtime, "bundled" is baked into your binary. Neither is published as a prebuilt artifact, and that is a decision rather than a gap. A release includes the CLI binaries, the packages and the drop-in sources. Shipping a shared object means an ABI to keep: a soname, symbol versioning, a separate headers package, and a promise that a caller built against an old one keeps working. All of that pulls against the one-file zero-dependency premise, and the C header exports plain externs with no export macro, so a Windows DLL would need one anyway. Every mode reaches the same Accessor/Writer surface; the choice is packaging, not capability.

### Power layer (library-level, grammar untouched)

Compared to schema-bearing config languages (Pkl, CUE), SHCL is deliberately weaker in-language - that is the simplicity trade. To close most of the practical gap - the power lives in the library, never in the grammar: Pkl makes the config file powerful; SHCL keeps the file dumb and makes the library powerful. Everything below is optional - a consumer doing a bare `GetIntOr` never sees any of it - and none of it adds a rule a file author must learn.

- **Schema-as-SHCL validation.** A schema is itself a plain SHCL file describing expected paths (type, required, allowed values, ranges). One library call - `Validate(doc, schemaDoc)` - returns the same structured diagnostics loading already produces.
	- The schema vocabulary (`int`, `required`, ...) is interpreted by the validator, not the parser, so the core language stays free of reserved words (same pattern as the fence info-string).
	- This also closes the forgiving-parser typo hazard: the schema knows the legal field names, so unknown/misspelled fields get caught ("unknown field `enabeld`, did you mean `enabled`?"). Design below.

- **Layered loading.** (Implemented; see spec.md "Layered loading".) `Load(defaults, site, user, ...)` is a left fold of `merge(base, over)` across files.
	- Container instances merge on matching `(field-name, value)` - the existing in-file rule - but a leaf name in a higher layer *overrides* (replaces) the lower layer's same-named leaves, so defaults-plus-override works for scalars, arrays, and raw blocks, not just structure.
	- CLI `--set PATH=VALUE` sits on top as the final layer, written through the Writer as data: `--set='x=80, 443'` stores the one string `80, 443`, where `--set-literal` stores the two-element array.
	- Env-var mapping was deliberately dropped: the env namespace and its convention belong to the consuming program, which can map env onto `--set` itself (the same reasoning that canceled the per-user config file). `check` takes no layers - its diagnostics are single-file.

	- On `set`, a `--set` is an edit rather than a layer, so `set --write` persists it. That closed the only route to a shell-driven write being a tab-separated script on stdin, which no shell writes comfortably and no editor preserves. A family of typed options (`--int`, `--string`, ...) was measured first and rejected: the type already follows the text, so the typed forms produced identical output. One gate moved, rather than twenty options added.

	- `--set-literal PATH=TEXT` is the same option reading its argument as value syntax instead of data, which is what lets an array be written as an option at all. It parses the text rather than splicing it in, so the outcome is a value or a rejection - output stays canonical, a written document is still a formatter fixpoint, and there is no way to inject syntax through it.

- **Schema-driven generation.** (Implemented; see spec.md "Schema-driven generation".) `generate(schema, no_banner)` + `shcl init --schema` emit a commented, typed starter config.
	- `desc` becomes a comment, a generated annotation line summarizes type/constraints, required fields are live (their `default` or an empty value), optional fields are the same line commented out, and wildcard paths go in a trailing comment block.
	- Output is flat dotted form (mirrors the schema shape) and always loads clean, and ends with a footer naming the format and linking its spec.
	- A path whose last segment selects by value, with a `default`, is written as the bare path with the default (`env[prod]` with `default: prod` is `env: prod`), since a value after that selector is ignored. Validation decides whether the default names the selected instance. Refusing every such default was rejected, because it faults satisfiable schemas. Writing `env[prod]:` and dropping the default was rejected, because a dropped schema input is what the raw-default `V092` fault exists to stop. Comparing the default with the selector inside the generator was rejected as a second copy of a match the validator already owns. The self-check reads the load's error diagnostics before validation's, so a line that does not load is `V097` as well.
	- An optional field's commented line gets the same check: the line is read back alone and its value checked against its own field. Uncommenting every optional line and validating the whole text was rejected. A valued parent and a dotted child written as two lines name two instances, so a schema whose lines each work would fault.
	- The annotation line and the footer are both byte-for-byte cross-binding contracts, so their format is fixed and the annotation's numbers use the canonical formatters.
	- Among the options for the footer it was decided to write it by default and name the knob negatively (`no_banner`, `--no-banner`): a generated file is usually the first SHCL a person ever sees, so the pointer to the spec earns its place, and a negative flag means the useful behavior is what a caller gets by saying nothing. It goes at the bottom so the settings, not the boilerplate, are what the file opens with.
	- Its `Legal` line leads with SHCL as the subject rather than with the copyright, so a reader cannot take it as a claim over the config it sits in.
	- Prose the generator writes has `##`, a commented-out setting a single `# `. A starter config is mostly comment, and one `#` for both left the reader sorting prose from settings by eye. Nothing keys on the difference: to the language both are comments, and a config author may write a comment however they like. The banner is a public constant in every binding, so the CLI writing it into a created file is not a second copy of it.
	- `set --write` creating a file writes the same block, since that is the other way a new config file comes into being. It is seeded as the created document's text rather than appended after the fact, so the edits go above it and the write still runs through the library's save gate.

Explicitly out of scope, with finality unless something big changes: in-language expressions, functions, inheritance, interpolation, imports, anchors/references. The moment config files can compute, they need debugging - that is the complexity cliff to avoid.

### Schema validation

The schema is a plain SHCL file, read with the ordinary parser and the ordinary Accessor. No grammar change, no reserved words, no new parser feature.

**Layout: a flat list of path descriptions, not a mirror of the document.** Each constraint is one instance of a field named `field`, whose *value* is the path it describes and whose children are the constraints:

~~~shcl
field: server.port
	type: int
	required: yes
	min: 1
	max: 65535

field: "server[*].host"
	type: string
~~~

The alternative (a schema that mirrors the document's tree, with constraints as children of each leaf) was rejected: it cannot tell a constraint named `type` from a real document field named `type`, so the schema vocabulary would collide with the user's namespace. The flat form has no such ambiguity, because the document's paths appear as *values*, never as field names. It also falls straight out of the relational model the language is already built on - `field` is the column, each path is a row - and reads as an ordinary SHCL file to someone who has never seen a schema.

Consequences of the flat form:

- The validator needs no new lookup machinery: `Instances("field")` enumerates the described paths, and `field[<path>].type` reads a constraint.

- A path containing a bracket selector must be quoted (`field: "server[*].host"`), because a bare selector's scan ends at the first `]`. The canonical form writes the path as a value rather than a selector, so the formatter applies that quoting itself.

- A schema file is a formatter fixpoint like any other SHCL document, so `shcl fmt` works on schemas for free.

**Wildcards cover the repeated-instance story.** `server[*].port` constrains every instance of `server`, which is how a schema says "each server needs a port" in a language whose core idea is repeated instances. `repeat` (on the parent path) bounds the instance count itself - the one constraint with no equivalent in tree-shaped schema languages.

**The vocabulary stays small and closed**, in the same spirit as the Loose coercion list: `type`, `required`, `allowed` (an enum, written as an ordinary array), `min`/`max` (numeric ranges, inclusive), `repeat`, plus `default` and `desc` which only the generator reads.

- Fragments later added `inherits` as a constraint key, alongside the top-level `fragment:` declaration. Nothing joins that list without a spec change.

- Datetime ranges were considered and dropped for the same reason as regex below: comparing datetimes across zone suffixes needs calendar arithmetic (an offset can roll the date), no parser has any, and four hand-written implementations of it is a parity minefield.

**Regular-expression constraints are rejected outright**, and this is the one real capability given up. No two of the target languages share a regex engine - character classes, Unicode properties, and anchoring all differ - so a `pattern` key could not hold byte-for-byte agreement across bindings, which is the product's core guarantee. An enum covers the common case; anything past that belongs in the consuming program.

**Validation reuses the reads, so strictness composes automatically.** `type: int` against `3.5` passes at Loose (which rounds) and fails at Standard. That falls out of the validator calling the same typed reads a consumer would, and it is the correct behavior: the schema says what the program needs, and strictness says how forgiving that program is about getting it.

**Diagnostics reuse the existing structure** (line, severity, stable code, prose message), so a consumer inspects validation results exactly as it inspects load results. Two additions:

- A `V###` code range, disjoint from the parser's `E###`/`H###`, so a validation failure is never confused with a parse failure. Unknown field, missing required, wrong type, value outside the allowed set, out of range, and wrong instance count each get one.

- Line 0 means "no line" - the document-scope report a missing-required-field diagnostic needs, since the whole point is that nothing was written.

The "did you mean `enabled`?" suggestion rides in the prose message, not the code. Edit-distance implementations would otherwise have to agree byte-for-byte across four bindings for a string that is explicitly per-binding voice.

**A field name in a diagnostic appears the way the emitter would write it.** Pasting the stored name in raw let a name with a line break split one diagnostic across two lines, and printed a flat `a.b` exactly like `a` nesting `b` - the ambiguity `paths` output and `QuoteSegment` already avoid by quoting. Every site that names a field now goes through one helper, so the `H001` and `H002` suppressors still match the head their builder emitted. A carriage return is escaped for display only: the name parse has no `\r` escape to read back, so the emitter cannot write one.

**A broken schema is reported against the schema.** Codes `V090+` cover schema faults (unknown constraint key, unusable type name), and their line numbers refer to the schema file.

- Originally any fault suppressed data validation entirely; after consumer feedback we decided a fault must not mask real violations - the schema builder already drops a broken key or field individually, so the surviving constraints now check the document too, with the faults listed first.

- The unknown-field sweep needs the complete declared vocabulary of names, but a key-level fault keeps its entry's path. So after a second round of the same feedback we decided the sweep runs through key-level faults. It skips only when a fault cost a path spelling outright (an unreadable `field:` path, or a mount naming no declared fragment), the two classes that would make declared fields read as unknown.

- Generation keeps the all-or-nothing rule - a partial starter file would be worse than an error.

**CLI surface: `shcl check --schema SCHEMA FILE`**, rather than a new subcommand. Loading and validating are the same question ("is this file good?"), the output shape and exit codes are already defined by `check`, and folding it in avoids a second nearly identical command.

Both open points are settled:

- `Validate` lives in each binding's single drop-in file. The one-file promise the README leads with outranks keeping the core lean; a schema user copying two files would quietly break the pitch.

- No string/array length bounds. They would reopen the byte-versus-code-point metric already settled for merge keys, for modest benefit; an `allowed` enum or the consuming program covers the need.

**Fragments close the recursion gap with one construct: `fragment:` declares, `inherits:` mounts.** The data language nests freely, but a flat path list cannot describe a tree whose nodes contain their own kind. Consumers were generating schema entries to a fixed depth, past which correct keys reported as unknown: validation returning false errors on valid files, in the tool CI gates on.

- Every mature schema language grew a named-shape reference for this reason; declining it would mean telling tree-shaped configs to flatten into instances with parent pointers, which makes the file serve the schema tool instead of the reader.

- Naming: `use` was rejected as overloaded English (verb-directive or "purpose"); `parent` collides with the parent/child vocabulary of a nesting language; `inherits` reads as a single plain word beside `type`/`required`/`allowed` and is accurate - the mount inherits the fragment's fields and can add its own.

- Design properties to keep: expansion is demand-driven (a mount is followed only where the document has nodes), so recursion has no depth limit, needs no cycle detection, and costs document-proportional time and memory; the generator is the one place expansion could run away, and it cuts exactly where a fragment would re-enter itself. Two places had to be taught not to walk the same mount twice: the mount evaluation, where two constraint paths matching one node both mount the same fragment, and the unknown-field sweep's chain matcher, where a fragment mounted by two paths offers two ways to consume the same chain. Each remembers the (fragment, depth) states it has finished, so a chain that ends unknown costs the schema's size per level rather than doubling per level.

- Suggestions do not descend mounts, same rationale as below stars.

**Open sections use a name-position wildcard, and it lives in the lookup grammar, not just the schema.** A map-shaped section ("any child name under `indicators`, each shaped like this") had no schema spelling at all - wildcards selected instances, never names.

- Among the candidates (a `*` name segment, an `open:` constraint key, glob patterns), the bare `*` segment won: it reads exactly like the `[*]` story one level up, needs no new vocabulary word, and composes with deeper paths (`indicators.*.period`) without a second construct.

- We decided it also belongs in reads, not only schemas, so the query language stays one language: `Get("*.port")` slots across children of any name the way `[*]` slots across instances. The Writer refuses it like any wildcard (paths must name their target to be writable). A field literally named `*` stays addressable quoted (`"*"`), which is never a wildcard.

- Suggestions ("did you mean") do not reach below a `*`, since there is no fixed sibling list to suggest from, and a `repeat` on a `*` leaf disavows no `H001`.

- A wildcard after a wildcard flattens. `server[*].*` used to report every slot `Multiple`, because the per-instance sub-resolution collapsed anything that was not exactly one node, and a nested slot list is never one node - so `Remove` on such a path removed nothing and a read of it could not answer. Among the options (call a nested list of one that slot and a nested list of none `NotFound`, or splice the inner slots into the outer run), splicing was decided: it is what "the two compose" already promised, it keeps `count`, `instances` and the read aligned with each other, and it makes the result one slot per resolved leaf, which is what a caller writing `server[*].*` is asking for. A repeated leaf under one instance stays `Multiple`, since that ambiguity is the same one a path with no wildcard has.

- `Remove` and `Exists` take every node behind such a slot instead of skipping it. Both act on the whole match rather than reading one value per instance, so a read's ambiguity is not theirs. Skipping left the data in place and still exited 0, which is the wrong answer under either reading of the spec sentence. The switch is one flag on the resolve walk, off for the reads.

**Value identity resolves escapes.** Two spellings of one string - `a: "q\"uote"` and `a: 'q"uote'` - used to be two instances, while `a["q\"uote"]` matched both, so one selector addressed two nodes and neither `count` nor a read could answer. Among the options (resolve escapes in the identity key, or say in the spec that a selector may address several spellings), resolving won: the selector already matches on the resolved text, names have resolved escapes since 2.0, and quoting was never part of identity anyway (`a: x` and `a: "x"` have always been one instance). The common element has no backslash and the key is the text itself, so the parse pays nothing for it.

**A quoted by-value selector is scalar-only.** By-value matching is against the display form, and an inline array's display joins elements with `, ` - so the scalar `"a, b"` and the list `a, b` met the same selector and a read could only answer Multiple.

- Among the candidates (a scalar-only quoted spelling, an IndexOf companion, leaving it documented) we decided the quoted spelling wins: quoting already forces a value match over an index and already escapes sentinels and formats elsewhere this round, so "quoted selects the scalar spelling only" extends one rule instead of adding a second construct.

- Bare selectors keep the whole-display match, so existing paths behave identically; the parser's accelerator keeps the first same-display child, with a rare fallback scan when a quoted selector needs the scalar sibling instead.

**Hand-edited configs are structurally safe across a round trip: retain what can be retained, gate the save on the rest.** A malformed line used to be diagnosed and dropped, so a stray typo plus one settings change equaled a silently vanished hand-written line.

- The full fix splits by what is provably safe. A content-malformed line (unreadable at any position) is retained as inert trivia and re-emitted in place; it re-diagnoses identically and can never read as a live binding. A line the parser could read but not apply (bad indent, unusable selector, depth cap) cannot be made inert: re-emitted, it might parse as live content and invent data, which happens for BOM-led lines.

- A skipped line holds its indent level, so the lines written under it are skipped with it rather than re-parenting one level up. That covers a `*` element line whose element was dropped as much as a malformed one: `* small` under a parent with field children and `*small` are two spellings of one mistake, and giving them different answers (one re-parenting its block, the other losing it) was decided against in favor of the one rule.

- Those instead count into `LostCount`, and the file tier's save refuses while it is nonzero, with an explicit lossy variant as the override - so deleting a user's line is always a stated choice. We considered retaining everything verbatim and rejected it on the invented-content risk.

- The CLI's in-place write goes through the same gate: it was first left alone on the grounds that a person sees the diagnostics on stderr, which turned out to be false - at the default strictness the load recovers and prints nothing, so `--write` deleted the line at exit 0 in silence. It now prints the load's diagnostics and refuses while `LostCount` is nonzero, with `--lossy` as the stated override.

- The CLIs call `SaveFile` rather than having their own copy of the rule, so the command line and a consumer program cannot disagree about which rewrites are safe.

- The refusal is a value, not prose: every binding reports it distinguishably from a failed write, because only one of the two is the caller's to reverse - and Python raises rather than returning a message, since a message a caller may ignore turns the safest spelling of the call into a silent no-op that reports success.

**The library has an optional file tier; file lifecycle is where consumer bugs live.** Consumer feedback showed every program that persists a config re-implementing the same load/save dance and making the same mistakes independently - confusing absent with unreadable, fumbling buffer lengths, tearing a config with a plain overwrite.

- We decided on a small companion tier. The load never fails and returns a four-way status (clean / had-errors / not-found / unreadable) beside an always-usable document. The save writes canonical text through the same atomic temp-and-rename the CLI's `--write` already used, moved into the library so the CLIs call it and the two cannot drift.

- It stays a companion, not core: C guards it behind `SHCL_NO_FILE_IO` so embedded consumers keep a file-I/O-free build.

**H002 reports every merged level, and a schema can disavow it per section with `reopen:`.** The first cut hinted only the outermost re-open: inner merges looked adjacent at their own scope, because the newest-child test cannot see that the whole region arrived by re-opening. That made consumer-side filtering unsound - allowing one section's hint silently waved through everything nested under it.

- We decided merges under a hinted container hint too, each naming its own earlier line (the parser passes the re-open line down, so text the re-opened region itself wrote stays silent).

- The disavowal is a dedicated `reopen:` key rather than an overload of `repeat` - "many instances" and "one section written in parts" are different declarations.

- Suppression mechanics mirror the H001 one exactly: single wording site, leaf-name match, dropped where diagnostics and a schema meet.

**`* key: value` is a string with a hint (`H003`), not an error.** It is how YAML writes a list of objects, and it loaded silently as the string `key: value`, while the spec said an element was colon-less.

- An error would refuse a value the bare-value rule takes everywhere else. `a: b: c` binds `b: c`, and `* note: text` means the same text.

- A hint changes no load, no read and no exit code, so no existing file breaks. It fires only on a bare element whose text up to its first colon has no blank, with a blank or the end after the colon. `* 14:30`, `* http://x` and `* note to self: x` stay quiet.

- The fix it points at is to quote the element, which `fmt` already does, since a colon is reserved in canonical output.

**A config file names its own schema on a `##    Schema   REF` comment line** (2026-09-26). The model is JSON's `$schema` and the YAML language server's schema comment, so an editor can find the schema with nothing else to go on.

- It is written like the `Format` line so it reads as part of the same family, and a comment changes nothing about the document.

- `check` reads a path from the config file's directory, the way an editor does, and a `--schema` on the command line wins.

- The line counts at any indent (2026-09-28). The formatter indents a comment to the field below it, and a match at column 0 only meant `fmt` could turn a file's check off.

- `check` reads only a regular file there, and on Windows refuses a path starting with two separators or `\??\` (2026-09-28). The file may come from someone else, and a device, a FIFO or a network share would make an unattended check run out of memory, hang, or connect to another host.
	- The read stops past 16 MiB (2026-10-01). A regular file can still read without end: Linux's `/proc/self/pagemap` has size 0 and reads as hundreds of GiB. A real schema is far smaller.

- A URL is left to editors. A check that goes to the network because of a line in a file is not one to run unattended, so `check` says it skipped it and validates nothing.

- `set_banner` keeps the line when it sits inside the info block, since the author wrote it there and the block is rewritten whole.

**Durations and sizes are read-time types, like dates** (2026-09-26). `timeout: 30s` and `cache: 512MB` read as whole milliseconds and whole bytes, so a program never parses a unit itself.

- A bare number takes its unit from the field name (`timeout-ms`, `cache_mb`), else from the program. The parser does the work, and a name that already says the unit is enough.

- Only a `-` or `_` marks where the unit starts. A camelCase boundary was tried and dropped: names fold to lower case, so `fmt` turned `ttlHours: 1.5` into `ttlhours: 1.5`, and the same line read 1.5 hours before and 1.5 seconds after.

- `KB` to `TB` are powers of 1024 unless the program asks for 1000. Guessing the base from words such as `disk` or `network` in the name was turned down: `cache-size` or `chunk` fit either, and two programs would read one line two ways with no error.

- A value with its own unit wins over the name, with the hint `H005` when they differ. A read cannot include a diagnostic and validation reports only errors, so the hint comes from the load.

- A schema `min` or `max` is read the same way as the value it bounds (2026-09-29): its own unit, then the field name's, then the schema's `unit`, which stands in for the program's. Taking the schema's `unit` before the name was turned down, since `wait-seconds` with `unit: ms` would then read `min: 2` as 2 ms and the value `wait-seconds: 1` as 1 s. The name is the last segment of the field's path, so a path ending in `*` gives none.

- A fraction has to come out whole, and at most 18 digits after the point count, so the arithmetic is exact in 64 bits in every binding with no wider type.

### Formatter

Structure-only canonicalizer: block form, tabs, insertion order, minimal quoting, redundancy collapsed, value text untouched (it cannot know types).

**Author quoting on plain strings survives canonical output; quoted data-format values still normalize to bare.** Moved to [the value syntax design](design_docs/value-syntax.md), under Canonical output.

**A raw block's nesting is the closing fence's own indent, and the rule is symmetric.** The nesting used to be the common indent of the body's non-blank lines, which made a shared body indent unrepresentable and needed an emit exception for a body with no non-blank line at all - the case that once grew by a level per pass.

- It was decided that the fence, not the body, defines the nesting: each body line loses only what it shares with the closing fence's indent (the opening line's when the block never closes), and emit pads every non-empty body line by that same indent.

- Strip and pad mirror each other exactly, so no special case is left: a body's shared extra indent survives as content, and a whitespace-only body keeps its spacing for the same reason as any other line - a raw block promising verbatim content should not be the place that quietly rewrites it.

**`SetRaw` refuses an info-string an emitted fence line cannot contain.** A line break, or a `#`: the fence line would read the `#` as opening a comment, so the block would come back with a different info-string than the one written. The info-string is also trimmed the way a fence line reads it back, and the op script's `raw` op shares the gate.

**A raw block in a higher layer fills a same-named empty binding below.** Merge matched instances by `(name, value)` only, so a bare `blk:` in the base and a `blk:` with a block in the overlay both survived a merge, where parsing the two run together folds them.

- That made merged output not a formatter fixpoint, and dragged in a second defect, since the emitter's workaround for the resulting pair writes the fence on the name's line and loses an info string containing `#`.

- It was decided that merge adopts the parser's own empty-fill rule, so a merge and a parse of the concatenation agree. The fill is limited to raw blocks because that is the limit of the parser's rule: a valued instance still appends.

**A run of whole-line comments keeps its written order and its nesting.** A comment written deeper than the next binding hangs on the block it sits in, and the rest of the run goes to the next binding. Each comment chose its block alone, so one could end up ahead of the comments written before it: a commented-out header followed by its commented-out child came back child first, and once both were uncommented the child sat under the wrong field.

- It was decided that a comment never goes ahead of the one before it. Once one stays for the next binding, every later one stays too, and one whose block is written out before the last one's goes there with it. Order is the one thing a reader of a commented-out block cannot fix by eye.

- A comment kept away from its own block keeps its depth under the comment or kept field line before it, one tab per level. A comment no deeper than the place it ends up sits at that place's level, as before, which also keeps a run's first comment there, so a reload files the run the same way.

- A malformed line kept verbatim keeps the place's level. It holds its level on a reload, so written deeper it would move the lines after it. The exception is a line under a field line refused for its value alone, which a reload holds open: it goes one level under that line, so it reads at the same path once its value is fixed.

- A reload puts a comment at most one level past the comment or kept field line before it. A merge that drops a layer's repeated footer line can drop the one the next line sat under, so that line comes no deeper than one level past what it now follows.

- A block's inside comments are written out after its last child's block, at that child's level, and a reload files them on that child. The load files them there too, once the tree is final, since a merge treats the two differently. It has to wait for the end: a block reopened later gains children, and filed on the child it had at the time, the comment would end up ahead of them.

- A block reopened later in the file gains children after the one that was last. That child's comments at its own level then sit right above a sibling, and a reload files them on the sibling, so the load moves them there too, once the tree is final.

- Tail comments are filed before the end-of-load fold of late duplicates, not after. The fold moves a dropped instance's comments over to the one it joins; after it, they were filed on the dropped one and lost.

- A merge, a new child and the writer's fold change child lists after the load, so each files comments by the same rules where it changed one. Otherwise the next step put a comment in one place on the document and in another on its saved text, and whether a file was saved between two edits decided where the comment went. The same holds for the blank the emitter drops on the first line, and for a raw block's trailing comment, which goes on its own line above when an empty binding of its name comes first.

**A float is written with the fewest digits that read back, and an exact tie between two such spellings rounds to even.** Shortest-round-trip formatters agree on every double except two cases, and both had leaked into the output: at a power of two the rounding interval is lopsided, so the closest short spelling can fall outside it while its neighbor reads back, and on an exact tie between two spellings of the shortest length Rust's formatter rounds away from zero where Go's, Python's and glibc's round to even.

- We decided on round to even: it is IEEE 754's own tie rule, what three of the four bindings already did, and what `repr` in Python and `strconv` in Go print, so a value read from another tool's output is written the same here. The reference takes the correctly rounded spelling of the shortest length whenever it reads back, and keeps its own shortest spelling only when it does not.

- C tries the last-digit neighbors before adding a digit, which is what the shortest-digits algorithms find at a power of two. Every power of two and a fixed set of random doubles go through a float write in every binding in the cross-binding check, so a formatter that drifts on either case is caught there.

### Saving a file

- **A save publishes a new file in the old one's place.** Write a temp file beside the target, then move it over. That is what makes an interrupted save unable to truncate a config, and it is also the source of every limitation below: the bytes are new, so anything the old file had outside its contents has to be deliberately copied across or it is gone.

- **The temp file borrows at most the first 64 bytes of the target's name, cut where a character starts.** It used to include the whole name plus the process id, which put it over the 255-byte limit for a target name in the low 240s - and moved the exact cut-off with the width of the pid, so the same file saved on one machine and failed on another. A fixed-width stem removes the band. The cap counted characters at first, and a name of four-byte characters pushed the temp past the limit again. Two long names sharing a 64-byte prefix can want the same temp; the exclusive create and the eight attempts already answer that.

- **What is kept, and what is not.** The permission bits are copied deliberately, and the group is kept best effort with them, since a `me:www-data 0640` config that comes back with the saver's group loses the service its read. The owner is not kept: a save that is not root cannot set it, and trying was decided against. On POSIX that is the whole of what gets copied: ACLs, extended attributes, the SELinux label and any other xattr are lost, as are other hard links to the old file.
	- None of that is fixable at this layer, since a rename cannot preserve what a rename replaces, so it is documented in the spec rather than papered over.
	- A relabeled config on an SELinux host is the case worth knowing about: the new file takes the label its parent directory and the writing process imply, which is the same label in the ordinary case and not the same one after a `chcon`.

- **Windows goes through `ReplaceFile` instead**, because it does not have the same constraint. `ReplaceFile` exists for exactly this publish step and copies the destination's ACLs, security attributes and named streams onto the replacement, which is the gap a plain move leaves. Its documented preserve list stops short of the basic attributes, so hidden and system are re-applied by hand after the publish, the way read-only already was; without that a hidden config came back visible. It needs a destination to replace, and it fails outright rather than skip a merge it cannot perform, so a create and any failure fall back to the replacing move - the behavior that was there before, never worse.
	- `ReplaceFile` is given a backup name. It works in two moves, the old file out and the new one in, and without a backup name a failure between them is documented to delete the old file (1176) or leave it under a name nobody is told (1177). With one, 1177 leaves the old file at the backup and nothing at the path. The save moves it back, and if that fails too it keeps both files and names them in the error.
	- The backup is the temp name with `.tmp` swapped for `.bak`, so it sits beside the temp and has the same length limit. It is removed after a good publish.
	- A publish that is refused is tried again, five tries 50 ms apart. A scanner or an indexer that opens the fresh temp file blocks the replace and the move both for a moment, and one try made that a failed save. A permanent refusal costs a fifth of a second before the error.
	- The fix does not depend on a given Windows build. It follows the documented behavior, which is what any build is allowed to do.
	- The temp file is created with the target's DACL rather than the directory's. A plain create inherited the directory's ACEs, so the new text of a private config sat under a wider ACL until the replace, and a fallback move published that wider ACL. The create drops the auto-inherited mark, so the DACL is set again with the mark requested when the target's had it.

- **The C file tier reaches Windows through the wide API, and splits a path on either slash.** Both came out of the first consumer to embed the C header on Windows. The narrow file calls read a path in the process's active code page, so a path with a character outside it either failed to open or, worse, was written under a mojibake name that the same narrow read found again. Every call is the wide one now, and a path that is not valid UTF-8 is refused rather than folded to a different name. The temp name was derived from the last `/`, and a path built with the platform separator has none, so every save through one failed. A drive-relative `C:x` splits after the colon, where the reference's `Path::parent` splits it. The other three bindings' runtimes already did all of this.

- **The Go binding reaches it through a hook rather than a build-tagged pair.** Go has no way to name a windows-only symbol from a file that also compiles elsewhere, and `shcl.go` promises to work when copied into a tree on its own.
	- So the publish step is a package-level variable holding the plain rename, and a small windows-only file swaps in the `ReplaceFile` version. Dropping the one file still works everywhere; taking the whole module gets the better windows publish.
	- The consequence to remember is that the lint stage only ever sees the host's `GOOS`, so the windows file is compiled and vetted in the cross stage instead - it is the only thing that looks at it at all.

- **The directory is synced after the move, not just the file before it.** The file's own `fsync` only promises the contents reached the disk; the move is a change to the directory, and without a sync there a power cut can lose the publish and leave the old content. It is best effort in every binding (a filesystem that refuses an `fsync` on a directory is not a reason to fail a save that already succeeded) and it is POSIX-only, since Windows has no equivalent. `ReplaceFile` is asked to write through, but Microsoft documents that flag as unsupported there, so on Windows the durability that is actually promised is the file's own flush before the publish.

- **A file the save had to create takes the mode an ordinary create would**, `0666` narrowed by the umask, rather than a private `0600`. Among the options it was decided that a library should not quietly make a decision the user cannot see: a config that must be private needs that from the umask or a `chmod`, which are the mechanisms a person already reaches for. An existing file still keeps its own mode, and that case is why the temp file is born private - the copy is never briefly readable to anyone the original was not.

- **A save can keep the lines no edit touched.** Among a second save that keeps the file's own text (kdl-rs keeps a document's formatting and has an `autoformat` beside it), working out the smallest text edit for each change and splicing it in (how VS Code's jsonc-parser edits `settings.json`), and canonical output only, it was decided to take the first two together: a separate save the program asks for, built by splicing (the user, 2026-09-25). The plain save and `fmt` stay canonical.
	- It lines up the two canonical texts, not the writes. The emitter tags each line with the source line it came from, and the loaded text is parsed again and emitted the same way. The lines one source line gave, and whatever the canonical form writes between them, are one group. A group of the edited text that matches the loaded one exactly takes the source's own lines. A dotted line with a comment above it is such a group, since the canonical form writes the comment inside the block the line makes. A run whose only change is its last value gets the new value written into its source line. Anything else is written as canonical text, indented the way the lines around it are, with the source's name spelling on a rewritten binding line. No setter, `remove` or comment call had to learn about it, in any binding.
	- The result has to reload as the edited document, losing no line the file did not already lose and with no error it did not already have. When it does not, the save writes the canonical form and says so (the user, 2026-09-25). That check is what lets the line-up be simple: it decides how much of the file stays as it was, never what the file says.
	- A load keeps the text only when asked. A merge drops it, since the layer's lines are not that text's.
	- `set` saves this way from 3.0, printing and with `--write` (the user, 2026-09-25). A file `set --write` creates has no text to keep, so it is canonical, with the info block.
	- What falls back today: a child added under a flat dotted line or under a list written as `*` lines, and a value changed where a selector elsewhere names it. So does any edit to a file whose canonical order is not its own, as with blocks folded together from separate places or a selector that puts a child under an earlier block. Keeping some of those lines would move the rest. A line no binding stands for, as a repeated header or field the load folded, or a line the load dropped, stays where it was after the line above it. A new line goes above it when it is indented past it, since a line written under a dropped line is dropped too, and below it otherwise. When the line above it goes or is rewritten, the save falls back.
	- A line the load dropped (`LostCount`) comes back as written this way, so the save gate refuses a save that keeps lines only when it falls back to the canonical form (SilkTerm and gitsby, 2026-09-25). Nothing is deleted, and the reload shows the same line dropped again.

- **A save that found nothing at the path publishes without replacing.** `set --write` decides it is creating a file before it waits on stdin, and a file made during that wait used to be replaced by the info block and the edits, at exit 0. The CLI looks again just before the save, and the save publishes through a hard link, which fails on anything at the target, then drops the temp name. A filesystem with no hard links gets a check and a rename, so a short gap is left there. Windows moves without the replace flag, which refuses the same way. No new call was added: which publish to use follows from what the save found, so a consumer has nothing to choose.

- **`set --write` creates a FILE that is not there yet.** `--write` names the file the command produces, so reporting it missing was an obstacle rather than a safeguard - the workaround was to `touch` it first, which is the same act with an extra step. `fmt --write` deliberately does not, having nothing to format. A file that exists but cannot be read stays an error in both, since the alternative is writing over something unread.

- **Bracket text after the colon is retained, never read.** A `[` first after the colon has one meaning: the JSON habit. The line is kept verbatim like any other malformed line, binds nothing, and counts nothing lost, the way a pasted YAML `- item` line already was. An error rather than a hint, because the value is not there to read.

- **A refused in-place write exits 7, its own code.** It shared 1 with usage and I/O errors, so a script could not tell "pass `--lossy` or fix the file" apart from "the command line is wrong" - and the refusal is the one failure whose remedy is a decision rather than a correction.

- **A file or stream that cannot be read or written exits 8, and 1 is now the usage code alone.** The same reasoning as exit 7, applied to what was left in the catch-all. The two remedies have nothing in common: one is fixing the command line, the other is fixing a path, a permission or a disk. A path a write option refuses (a wildcard, an index naming no instance) stays at 1, because what has to change there is the option's value.

- **Every subcommand that loads a document prints the load's diagnostics to stderr, once per run.** It was decided that neither where the canonical text goes nor which subcommand asked for the load should decide whether a recovered-from typo is mentioned. This started as `fmt` and `set` in both modes, with the read subcommands left quiet; that half was reversed, because a read below strict returns the value and says nothing at all, which is the case where silence costs most. stdout has the same bytes either way.

- **The mode is applied to the temp file again after its data is written.** The kernel clears setuid and setgid on a write by a process without the right capability, so giving the temp file the target's mode before filling it silently dropped those bits - the copied mode has to land last, after write and fsync, before the publish.

- **The write target is resolved on Windows too.** Rust and Go get it from their standard libraries; the C binding used the path as given, so a save through a linked-in config replaced the link with a regular file - the one thing resolving the target exists to prevent. It now asks Windows for the final path, which follows a symlink or junction and comes back long-path-prefixed. The prefix stays only when the name plus the temp file's suffix would otherwise be too long, so an ordinary save writes the plain name it always did and a path past the old limit works at all.

- **A symlink cycle at the write target is an error.** Resolving the target is what makes a linked-in config written through rather than replaced, and a cycle used to fall out of the resolver as "no target", which quietly replaced the link with a regular file. A loop is reported as what it is - too many levels of symbolic links - and nothing is written.

### Save outcomes

What a save does with each thing it can find at the path. The same answer comes from the library's save in every binding and from the CLI's `--write`, and the CLI reports every refusal at exit 8. The table is the rule. A case answered at one site and not its sibling is the usual defect here, so a new case gets a row before it gets code.

| At the path, after links are followed                                   | A save
| :---                                                                    | :---
| A regular file                                                          | Replaces it. The mode and the group come over. What does not is under Saving a file.
| Nothing, in a directory that exists                                     | Creates it, at `0666` narrowed by the umask. Anything that turns up before the publish is left alone and the save fails.
| A link to a regular file                                                | Replaces the file the link reaches. The link stays.
| A dangling link                                                         | Creates the file where the link points. The link stays. The walk joins each link's text to the directory the link sits in as written, never cleaned, since the kernel follows `lnk` in `lnk/..` before it goes up.
| A link whose text ends in a separator, `.` or `..`                      | Refused: is a directory. That text can only reach a directory, and the kernel refuses to create a file through it.
| A link cycle                                                            | Refused: too many levels of symbolic links.
| A path ending in a separator, `.` or `..`                               | Refused: is a directory.
| A directory                                                             | Refused: is a directory.
| A FIFO, a socket, a device, or anything else that is not a regular file | Refused: not a regular file. A rename would swap it for a regular file. The CLI asks before it reads FILE, since reading a FIFO takes what was written to it.
| A regular file whose bytes changed since the CLI read it                | Refused under `--write`: changed since it was read. The CLI reads FILE again just before the save. The library's save does not look, since its caller holds the text and knows when it read it. A gap the width of one save is left.
| A regular file whose canonical bytes equal what the save would write    | No write under `--write`, at exit 0. The file keeps its inode, its mtime and its hard links. The library's save always writes, since its caller may want the publish.
| Nothing at the path, under the CLI's `--write`                          | Created as above, plus `FILE: created` on stderr, so a mistyped name is not a silent new file at exit 0.

### Load outcomes

Every load-time code has one outcome, and the parser derives the lost count and the held indent level from that outcome alone. Each diagnosing arm names its code and its outcome and does nothing else; one function records the diagnostic, counts, and holds the level. Before this, every arm counted and pushed by hand, and an arm that skipped one or the other was a repeat defect. A line has one of five outcomes:

- **Bound**. The line binds as written. The diagnostic describes something about it, and nothing is counted or held.

- **Retained**. Content-malformed at any position, so kept verbatim as trivia and written back in place, where it re-diagnoses identically and can never read as a binding. Counts nothing. Holds its indent level, so what is written deeper is `E018`.
	- Except a field line refused for its value alone: `E019`, `E023` in a value, `E024`. Its path is fine, so its level stays open, and the first line under it that binds opens the path as `name:` with nothing after the colon would, then binds there. A line under it that is itself refused opens nothing, so a field with no line under it that binds is still not there. A read on it is `NotFound` then, and `Empty` once a line under it binds. One typo in a value used to take its whole block with it, a silent wrong answer for every key under it (SilkTerm, 2026-10-01). A path with an index or wildcard selector, or one past the nesting cap, could fail to place, so it still holds a dead level.
	- A retained line whose value opens a raw block keeps the body and its closing fence with it, as one kept line. Read as lines, the body bound as fields at exit 0, and its closing fence opened a block that took the rest of the file (review 20261003 item 2; 20260918b had declined it as a file that fails `check` anyway). Throwing the line and body out instead would refuse every later save over one typo in a name. The closing fence's indent comes off each body line, as in a field's block, and canonical output writes the body one level under the line, so the block moves with it. A block that never closed gets its closing fence, or whatever is written after it would read as its body.
	- Canonical output writes the kept line in place of the opened field's bare `name:` line when it is the field's last leading line and names just that field, since a reload opens the field from it the same way. A field the edits left with nothing under it keeps its own `name:` line too, since nothing would open it. The emitter's model of the reload's stack holds such a line's level open the same way, so a kept misplaced line under it is judged the way the parser will.

- **Dropped**. Read but not applicable where it sits; re-emitted it could bind somewhere else, so it is gone. Counts one lost. Holds its indent level the same way.

- **Kept as written**. Refused for where it sits, with an indent that holds a space. No level canonical output opens is written with one, so written back exactly as it was, indent included, a reload refuses it the same way. Counts nothing. Holds its indent level the way a dropped line does.

- **Value dropped**. The line binds, but a value on the line had nowhere to go. Counts one lost; the level is the bound node's.

The table is the rule. If a code's behavior ever disagrees with its row, the code is wrong.

| Code   | Severity      | Outcome
| :---   | :---          | :---
| `E001` | error         | bound
| `E002` | error         | value dropped
| `E003` | error         | dropped
| `E004` | error         | dropped
| `E005` | error         | bound
| `E006` | error         | dropped
| `E007` | error         | dropped
| `E008` | error         | dropped
| `E009` | error         | dropped
| `E010` | error         | dropped
| `E011` | error         | dropped
| `E012` | error         | kept as written when the indent holds a space and the line opens no raw block; dropped otherwise
| `E013` | error         | retained
| `E014` | error         | retained, with any raw block it opens; dropped when the line begins with a BOM, which the file-start strip would rewrite into something that can bind
| `E015` | error         | bound
| `E016` | error         | dropped
| `E017` | error         | bound
| `E018` | error         | kept as written under a kept `E012` line when it opens no raw block; dropped otherwise
| `E019` | error         | retained; holds its level open
| `E020` | error         | the parse stopped: every later non-blank line is dropped, and no level is held
| `E021` | error         | dropped
| `E022` | error or hint | bound (about the list, not a line)
| `E023` | error         | retained; a value fault holds its level open, and a name fault keeps any raw block it opens
| `E024` | error         | retained; holds its level open
| `H001` | hint          | bound
| `H002` | hint          | bound
| `H003` | hint          | bound
| `H004` | hint          | retired: became `E024`

- Rows `E013`, `E014`, `E017`, `E019`, `E023`, `E024` and `H003` change, and `E025` to `E028` come in, with [the value syntax design](design_docs/value-syntax.md). This table changes when that is built.

- A line that qualifies for more than one refusal takes the first that applies, in this order: where it sits (`E012`, `E018`), then what it is (`E014`, `E019`, `E023`, `E024`, and on an element line `E007` to `E011`), and only then the element cap (`E021`). A cap refuses only a line that would otherwise bind. Bracket text under a cap is `E019` and kept, and an element under a field that already has a value is `E011`. The bracket test reads the value's first piece, which a capped scan keeps, not the value span, which it empties. The fuzz property `a_cap_refuses_only_a_line_that_would_bind` holds the order.

- A kept `*` element holds its column, with its field as the level's node, the way a dropped one holds its own. Without that no level was open at the element's column, so the list's next sibling - a field or another element - was `E012`, "matches no open level", two lines under the level that opened it. One mistake cost every later line of the list. Dropped elements were settled first, and kept ones later.

- The one thing the table changed when it was written: a raw fence with no parent field (`E006`) never held its level, so a line written deeper than it bound to the root. It holds it now, like every other dropped line.

- An indent that matched no open level (`E012`) already holds an unopened level from the resolve, which refuses a sibling at the same indent the same way. The funnel leaves that one in place rather than stacking a dead level on it.

- The unopened level sits on top of the levels open before it and closes none of them. Popping every level its indent did not extend was rejected: one stray space-indented line in a tab-indented block then dropped every later sibling in that block, which 2.0.0 read fine. It holds until a line comes that is neither under it nor at its column, so the stack has one at most.

- Among dropping a misplaced line (which stopped every later save of the file), writing it back as a comment, and writing it back as it was, it was decided that it goes back as it was, and as a comment only where it would bind as written. A comment would hide an error the line still has, and one stray space in a hand-edited config should not stop a program saving its window size (the SilkTerm report, 2026-09-24). A tab-only indent is always one a level can be written with, so that line is still dropped.

- Canonical output indents with tabs whatever the input used, and a save keeps a misplaced line when its indent holds the other character. Among that, writing the file back in its own style (tabs or spaces, whichever it uses more), and writing a tab-only misplaced line as a comment, it was decided that output stays tabs and a tab-only line stays lost, so the save refuses (the user, 2026-09-24).
	- In its own style the kept and lost cases only trade places. A space-indented file's likely typo, a miscounted run of spaces, is kept now, and in 4-space output it could line up with a level and would have to be lost. A stray tab in a space file, the case that is lost now, is the rarer typo. A tab file's tab-count mistake lands on no level only when the file itself skips one.
	- One output keeps canonical form one form: the goldens, the cross-binding comparison, and a merge of a tab file with a space file all rest on it. A space unit would also have to be guessed, and a file whose levels do not step evenly has none.
	- A comment would let the save through, but nothing would flag the line again. A refusal changes nothing and says why.
	- Corpus case `147-indent-styles` pins all four: a stray space in a tab block and a miscounted space run in a space block are kept, and a tab line in a block that skips a level and a stray tab in a space block are lost. It is a release gate: change the rule and the case, and this entry, together.

- A kept misplaced line never hangs on a block, and a line refused for where it sits never hangs the comments before it. Its indent is not one canonical output writes levels with, so the block it matches in the source is not the one it matches on a reload, and comments it measured differently moved on the next load. It waits for the next binding line, and whatever follows it waits with it.

- The emitter asks the reload before it writes one. It runs the parser's own resolve on a model of the level stack the reload will have at that line: the levels up to the last binding line, and what the lines refused since then pushed. The line goes out as written only where the parser would keep it again. A merge or an edit can move a kept line to where it would bind, and there it is written as a comment. The document settles to that comment after every load and edit, so the next step gives the same result whether or not the file was saved in between. Whether a kept line binds depends only on the lines between it and the binding line above it. An edit that changes none of those skips the settle, so a kept line far away costs an edit nothing.

- `migrate` refuses a rewrite that leaves a misplaced line, even kept. 2.x placed some such lines by a looser rule and read them, so the migration would lose a binding at exit 0.

- A malformed or misplaced line kept among a stacked list's elements stays where it sat, and keeps the list in the stacked spelling. It used to ride the field line like a comment, so a fix typed into it ended up outside the list (the SilkTerm report). Comments among the elements still ride the field line. A setter that replaces the list's value moves the kept lines above it, and so does a list after an empty binding of its name, whose bare header would merge into that binding on a reload.

- A comment at a list element's column after the last element belongs inside the list's block. The element's column entry has the list as its node, which read as the list's own level, so the comment went out a level up. Nothing showed while lists were always written inline; a stacked one moved the comment on its first reload.

### Lexical edges

Where a byte sits decides whether it is content or trivia, and this table is the rule. The tokenizer, the emitter and every setter follow it; if any of them disagrees with a row, that code is wrong. Three positions cover everything: bare text (a name, a selector body, a value or element, a fence label, a comment - anything outside quotes), inside matching quotes (a piece that opens with a quote and closes with the same quote as its last character), and a raw body (the lines between fences).

The rows for quotes, the backslash, the comma, the bracket and the line break change with [the value syntax design](design_docs/value-syntax.md), which is the source of truth for them. This table changes when that is built.

| Byte                        | Bare text                                                                                            | Inside matching quotes                                                                          | Raw body
| :---                        | :---                                                                                                 | :---                                                                                            | :---
| `#`                         | opens a comment, whatever sits before it                                                             | content                                                                                         | content
| space, tab, carriage return | trimmed at a piece's edge, content in the middle                                                     | content                                                                                         | content; only the trailing carriage-return run comes off each line
| `"` or `'`                  | content, unless first in the piece, where it opens a quoted piece                                    | ends the piece when it is the matching quote and the last thing in the piece; content otherwise | content
| `\`                         | content                                                                                              | starts an escape inside double quotes; content inside single quotes                             | content
| `,`                         | ends an element                                                                                      | content                                                                                         | content
| `[`                         | after a name opens a selector; first after the colon is bracket text (`E019`); content anywhere else | content                                                                                         | content
| line break                  | ends the line                                                                                        | none; a setter writes one as `\n` in a name or a selector                                       | ends the body line

What follows from the table:

- A `#` is a comment anywhere outside quotes and outside a raw body, whether or not whitespace precedes it. `color: "#ff0000"` and `url: "http://x/y#frag"` are the spellings for a value holding one. `a[#0]` in a file is a selector cut off by a comment, so the `[#N]` index selector is a path spelling for the API and the CLI; a file addresses an instance by value. A fence line's info string ends where a comment starts, so ```` ```c# ```` labels the block `c`.

- `##` for prose and `# ` for a disabled setting are conventions. To the language both are comments, and a config author may write one with any number of `#` and any spacing.

- A carriage return is a blank outside a raw body, and does whatever a blank does where it sits: it is trimmed at the end of a line, a name, a selector body, a value, an element, a comment or a fence label, and it is content in the middle of one. Inside a raw body the trailing run comes off each line and a carriage return mid-line is content.

- A field line that cannot be read still opens a raw block when a fence follows its first colon past where reading stopped, and no `#` comes before that colon. Quotes past that point are not read as quotes, since none there parse. Bracket text (`E019`) opens nothing, since its value starts with `[`.

- Bracket text after the colon (`ports: [80, 443]`) is one thing: the JSON habit. The line is `E019`, kept as written, binds nothing and counts nothing lost, so `check` reports it and an in-place write goes through unchanged, the way a pasted YAML `- item` line already does. `x:[y]` is never a selector.

- The writer writes what the table lets it write and refuses the rest. A value holding a `#`, a comma, a leading quote or a leading `[` is quoted; a line break in a name or a selector is escaped. What has no spelling is refused whole: a fence label holding a `#` or a line break, a comment holding a line break, a raw body line ending in a carriage return. Nothing on the write side trims or quotes its way around a byte the table calls content.

### Write outcomes

The mirror of the load outcomes, on the write side. A setter builds its line text through the emitter, hands it to the tokenizer, and refuses unless what comes back is the value it was given. Nothing else on the write side decides what a quote, a `#`, a comma or a carriage return means, so a setter added later has no rule of its own and cannot disagree with the parser. The table under Lexical edges is what both sides read.

- The refusals follow from the lexical rules rather than from a list. A raw block's info string may not hold a line break or a `#`, because the fence line would read the `#` as opening a comment. A raw body line may not end in a carriage return, because the load takes the trailing run off every line. A comment may not hold a line break, because a comment is one line and keeping the first would drop the rest with nothing to say so.

- What the load normalizes, the setter normalizes too, and stores the normalized form: a comment line and a fence label are trimmed at the end the way the load trims every line. A raw body line is payload, so it is refused rather than trimmed - stripping a carriage return from each line of a block would quietly convert a CRLF payload to LF.

- The typed setters keep their render-and-parse-back on top of the round trip. It answers a different question: the round trip asks whether the same text comes back, and a float or a datetime has to come back as that type. `inf` reads back as the text `inf` and as no float at all.

- `SetLiteral` takes syntax rather than data, so whatever a file line gives with its text is what gets stored - a trailing blank comes off and a `#` outside quotes ends the value. What it refuses is what a file reports as an error, since a setter has no diagnostic to report one with: a line break, an unterminated quote (`E017`), bracket text (`E019`).

- A path may have a line break in either half. A name emits through the name escaper and a selector value through the value emitter, and both write one as `\n` and read it back. The selector was refused until the tokenizer cut, while elements were still stored in their source spelling and the value emitter had nothing to escape with.

### Kept lines under edits

What each edit does with the kept lines near its target. A kept line is one the load kept as written: retained for its content, or kept for where it sits. The table is the rule. Edits lost these lines one site at a time, each at exit 0, so a new edit gets a row before it gets code.

Where a kept line sits is read from canonical output before the edit. Under the target means written inside its block. Heading the target means written in place of its `name:` line, which canonical output does for a field opened from a line kept for its value. Beside it is anything else.

| Edit                                                         | Beside the target                                                                                                     | Heading the target | Under the target
| :---                                                         | :---                                                                                                                  | :---               | :---
| `Remove`                                                     | stays                                                                                                                 | goes               | goes
| Every setter, the default forms included                     | stays, except a field line kept for its value that names just the target's field, which becomes a comment             | becomes a comment  | stays
| `SetComment`, `ClearComments`                                | stays                                                                                                                 | stays              | stays
| `SetBanner`                                                  | stays                                                                                                                 | stays              | stays
| `Merge`, the base's lines                                    | stays, except one the settle wrote as a comment among the comments of a leaf the layer replaces, which goes with them | stays              | stays
| `Merge`, the layer's lines                                   | comes in                                                                                                              | comes in           | comes in, except a footer line the base already has, unless kept lines sit under it

- A remove only takes lines away. It writes no line the document did not write before, so a field opened from a kept line does not leave a bare `name:` behind.

- A field opened from a kept line goes with the last line under it, and the kept line stays where it was. A raw block of the same name after it had its fence on the name's line only because of that empty field, so the fence moves to a line of its own. That is the one rewrite a remove makes.

- A remove takes the comments written against its target: above it, those after the last kept line; below it, those before the first. A comment on the far side of a kept line stays with that line. A kept line the settle wrote as a comment counts as kept here, though a reload of the canonical text reads it as a plain comment.

- A repeated header goes when the last line under it is removed, since an earlier block already has that instance, and the blank line above it goes too. While anything stays under it, the header and its blank line both stay.

- The kept lines beside a target that was the last field in its block stay at the end of that block. A misplaced line among them has no level there, so it goes down to just above the next field line, with the comments after it, which is where a reload files them.

- A setter that replaces a stacked list's value moves the kept lines among its elements above it, as under Load outcomes. A move is not a loss.

- A setter writing a field writes every kept line at that level of its block that names just that field as a comment. That includes the one heading it when the field was opened from a kept line. So once those lines are fixed by hand, the field does not read as Multiple. Only a field line refused for its value alone counts, since its name reads, and not one with a raw body, which cannot be commented out as one line. Then the setter changes the field in place. Where there is no field of that name, the new one goes right under the first of those comments. The lines written under that kept line go under the new field, where a reload files them. A field made on the way to the target does the same. Two valid lines of one name stay as they are.

- Two kinds of kept line stay as they are. One has a kept line written under it and is not where a new field goes, since as a comment it would leave that line under the field above. The other has a misplaced line under it, since a misplaced line is filed by its own text and cannot move with it. The first comment is then the first of the others. `SetComment` makes a missing field without touching any of these lines.

- A line the load dropped right after the kept line a new field goes under is not placed by the save that keeps lines, since the lines before it are all new. That save falls back to canonical and refuses, as for any dropped line, and `--lossy` writes it.

- The note on each comment says why and when: `# a: [1]  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 bracket array syntax`. It names the path the setter was given, the local time with the zone's short name, and the code and reason the load gave, without the advice after the reason. A zone with no short name, such as one named `+03`, is written as its offset, `UTC+03:00`. Windows names a zone only in full, so there it is always the offset. The line is a plain comment from then on, as a reload reads it. It is no longer owed to the save gate, and `ClearComments` and a remove of the field take it like any comment on the field. The default forms write nothing on a path that exists, so they never get here.

- `SHCL_TEST_CLOCK`, in the form `YYYY-mm-DD HH:MM:SS OFFSET_MINUTES [NAME]`, stands in for the clock and zone in that note, so tests can pin it. `cli-regress.bash` and `crosscheck.bash` set it.

- A kept line's raw body is part of the line. Every edit keeps or takes the two together.

- The merge exception for a settled line on a replaced leaf was decided on 2026-09-28: the line goes the way it would in a merge onto the reload of the saved base, where it is a comment.

- A leaf's comments, for a merge that replaces it, are the ones a remove would take: above it those after its last kept line, below it those before its first. A settled line counts as the comment a reload reads it as. A comment or a settled line past a kept line beside the leaf stays with that line.

- The save gate counts kept lines. The load records how many it kept, and each edit takes off only what this table lets it. A document holding fewer than that counts the rest as lost, so `LostCount` includes them, the save refuses, and the save that keeps lines falls back and refuses with it. `--lossy` writes anyway, as for a dropped line. Among checking each edit site and checking the count at the save, the count was chosen, since the sites were the problem.

- A fuzz property holds all four bindings to it: after any edits, every kept line no edit's target took is still in the saved text, or the save refuses, and a remove adds no line. The other three are held through the cross-binding check, which replays its inputs and edits through each CLI's `set --write`.

### Generation outcomes

What `init` writes for each kind of line, and what proves the line reads back. The table is the rule. `init` output that failed its own check was a long-running class of defect, and every one was the generator predicting what the scanner would read. It does not predict now: each spelling it picks is scanned back as a file line first, the way the load will scan it, and every line it writes is read back.

| A generated line           | How it is written                                                                                                                                                                                            | How it is checked
| :---                       | :---                                                                                                                                                                                                         | :---
| A field's path             | The schema's own spelling when a file line reads it back as the same path, else rendered from the path's segments.                                                                                           | The whole output loads with no error and validates clean against the schema.
| A child of a valued parent | Selects the parent by its value. The body is the first candidate a file line reads back as a value selector for that value: a single element as written, bare, then quoted. An array has only the bare body. | No candidate reads back: `V097`.
| Two lines on one path      | The first is written, and its value is the instance the children select. Two by-value fields with different values are two instances, and both are written.                                                  | The same as a field's path.
| An optional field's line   | Commented, with or without a default.                                                                                                                                                                        | Read back alone, and its value checked against its own field.
| Text in the trailing block | Every schema string through `schema_text`, so a line break stays inside the comment.                                                                                                                         | Nothing reads the block back; the escaper is the rule.

### Testing

The conformance corpus is the primary cross-language guarantee. Each case is an input, its canonical formatting, and the expected typed reads with status sentinels. Every parser runs it in CI.

Passing the corpus independently is necessary but not sufficient once there is more than one binding. Two implementations can each satisfy the expectations yet still disagree on details the corpus never pinned, like float rendering or diagnostic-free edge behavior. So the pipeline also runs a differential check:

- Every binding's CLI is replayed over the same inputs: the whole corpus plus a freshly generated fuzz set.

- All bindings must agree with the reference byte-for-byte on stdout and exit code. The reference is Rust.

- stderr is deliberately outside the contract. Diagnostic wording and OS error text are per-binding voice. stdout and exit codes are the contract.

Both of those run on small inputs, which leaves a whole class of defect unwatched: anything that only appears at scale. A parser that is accidentally quadratic, a buffer that grows wrong past a few megabytes, or a memory profile that puts a real config out of reach all pass a corpus of few-hundred-byte cases. So the pipeline also formats one large generated document - 100 MiB by default - through every binding:

- The bindings must agree on the result byte for byte, exactly as on the corpus. The document is generated rather than stored: a fixture that size has no business in a repo, and the shape matters more than the bytes.

- Each binding is held to a wall-clock and a peak-memory ceiling, expressed per input MiB so they follow the configured size. The ceilings are set to catch a change in growth rate, not to time a machine - the time ones have wide headroom, because the pipeline runs the reference unoptimized and a hosted runner is slower again. Memory is held closer, since peak usage barely moves between machines.

- At that size the reference also has to prove formatting is a fixpoint and that a long array reads back whole, both of which are cheap to state and impossible for a small case to check.

- Python formats a 16 MiB copy instead, and has to match the reference's output for that copy. At 100 MiB it took two minutes and more and was the whole gate's critical path. At 16 MiB a quadratic parse or a bad buffer still shows, and the run takes about 20 seconds.

The size is deliberately a floor rather than a target. It was chosen because it is roughly where memory stops being free: every binding holds tens of times the input size in memory while parsing, so a document this big is the first one whose cost is worth a decision.

All of that runs on Linux, which was enough while every binding did the same thing everywhere. The file tier ended that: publishing a written file is a different code path on Windows in all four bindings, so the platform-specific half was covered only where it never executes. A second CI job runs the runners and the veneer smoke on Windows.

Its scope is deliberately narrow, and it is not a second definition of passing. The corpus goldens, the differential check, the large document and every lint gate stay on the Linux job, where they are defined. The Windows job is there for the code that only exists there.

Two supporting decisions came with it. The C runner walks the corpus with `dirent.h`, which MSVC does not have, so the compiler is gcc. And end-of-line conversion is turned off repo-wide: Git for Windows defaults it on, the goldens are compared byte for byte, and some of them are about line endings specifically.

Two portability rules bind every binding:

- Floats render as shortest round-trip decimal, never scientific notation. This matches the reference's native float formatting.

- Diagnostic order must be deterministic: a load's list is in line order, and in first-appearance order within a line. A port can match a rule, but not a coin flip.

### Format comparison

The feature comparison on the front page says how SHCL differs from JSON, YAML, TOML and XML. Nothing said what any of it costs, so `cicd/utility/comparison/` measures that, and the numbers README quotes come from there.

Method, and why each part of it is the way it is:

- **The language is held constant within a tier.** Every format in a tier is read by a library from that ecosystem, built the same way. Measuring SHCL's C binding against a JSON parser in Python would compare implementations and call the answer a property of the formats.

- **Two tiers, never ranked against each other.** Rust is the headline, because there every format has a mature native parser and the comparison is as close to formats-only as it gets.
	- Python then repeats the exercise over the same documents, to answer the question one tier cannot: how much of a format's cost is the format and how much is one implementation of it.
	- Most of what Python reaches for is a C extension wearing a Python name - `json`, `ElementTree`, PyYAML's `CSafeLoader` - while this project's Python binding is pure Python, so the row that matters there is `tomllib`, which is also pure Python.
	- That pair is the tier's only like-for-like comparison, and every entry records which side of the line it is on. Python libraries that are not installed are skipped and named rather than failing the run.

- **One abstract model per document, five encoders.** Each shape is built once as a small tree and then encoded five ways, so the files hold the same data by construction rather than by five hand-written generators happening to agree. Each encoding is the spelling a person would really use - SHCL raw blocks against YAML block scalars against XML CDATA - because a number taken from an unidiomatic encoding is not measuring the format.

- **A pre-flight equivalence check.** At a small scale, every library in both tiers has to parse its own file and find the same number of scalar values in it. One model does not rule out an escaping mistake in one encoder, and a size or speed number taken from documents that are not the same data is worth nothing. The python tier answers through its worker's `--count` mode rather than while measuring, so the walk costs the timings and the memory figures nothing. Both tiers also refuse a document their parse did not read whole, which is the half that catches a binding defect.

- **One process per measurement.** Peak resident memory is only attributable that way: a process that parsed six documents says nothing about what any one of them cost.

- **Six shapes**, because one document shape hides most of what separates these formats. Four of them scale to whatever size the run asks for: long and flat, wide and deep, an array of records, and multi-line text blocks. The other two have their own realistic size instead - a hand-edited application config of a couple of kilobytes, and a schema definition file of a few hundred. A config file measured at 64 MiB is not a config file anybody has, and the scaling shapes measured at two kilobytes would be measuring process startup.

- **The run count scales with the document.** Best of three says nothing when the parse takes microseconds, so a small document gets proportionally more timed runs, up to 200 times the count the run asked for. The count actually used is recorded beside each shape.

Several choices deliberately cut against SHCL, so that a favorable result stays one:

- **No comments in any document.** Four of the five formats take them and JSON does not, so any comment at all would compare different documents - and comment retention is exactly the difference SHCL would most like to show off.

- **JSON is pretty-printed and XML is indented**, since the premise is a file a person edits. JSON also gets `preserve_order`, because a config loader that silently sorts the file's keys is not one anybody would ship.

- **TOML and XML each get two libraries.** `toml_edit` is the only mainstream non-SHCL parser here that keeps the file as written, which makes it the one genuinely like-for-like comparison. XML is measured both by the fastest tree in Rust and by the tree you can write back.

- **The generated SHCL is canonical**, a `fmt` fixpoint, so the round-trip column reports what the format does rather than how the generator chose to space things.

Rows are ordered by the geometric mean of each library's parse time across every shape, fastest first - one order used for every printed table and for the results file, so a row keeps its place from shape to shape. The geometric mean rather than the arithmetic one, so a single large shape cannot decide the whole order; the number it sorts on is recorded beside each library, so the ordering can be re-derived rather than trusted. SHCL sorts fifth of seven in Rust and last in Python; that is the measured result, and the reason the order is stated rather than chosen.

Reading a value by path is deliberately not measured. The five lookup APIs differ enough that the harness would have to write the walk itself for most of them, and the result would be a measurement of harness code.

It is not a pipeline gate. Benchmarks are noisy and slow, and a red build caused by a busy machine teaches nobody anything. It runs on demand, and its results accumulate in `results.shcl` - which is the tooling's storage format as well as its subject, written, pruned and read back through this repo's own library.

One thing the tool found about a library rather than a format, recorded so nobody re-derives it: `lxml` goes quadratic on the long-and-flat shape, dropping from 59 MiB/s at 3 MiB to 5.7 at 26 - measured with and without `huge_tree`, which makes no difference, so it is not the flag that lifts libxml2's size ceilings. The likely cause is the shape's millions of *distinct* element names against libxml2's name dictionary; the shapes whose names repeat show nothing of the sort, and no other library in either tier does this. It is a good argument for measuring more than one document shape.

What it found, at 64 MiB per shape (rerun on 2026-10-02; runs before 2026-09-19 read the memory figure with two documents alive for five of the seven Rust libraries):

- SHCL writes the smallest file of the five in three shapes of four, and the gap widens with nesting - half the size of JSON and of XML on deep structure. Gzipped, SHCL is within 3% of the smallest file on every shape, so the win is a plain-text one.

- SHCL loads fifth of seven in Rust and last in Python by aggregate, three to six times behind `serde_json`. On memory it sits in the middle: below YAML on three shapes of four, below TOML on two, above JSON on all four, and below `toml_edit` on all four, about 40% of it on the records. `toml_edit` is the one other parser that keeps the file.

- The Python tier puts SHCL 4.2x behind `tomllib`, the tier's one other pure-Python parser, against 1.3x behind `toml` in Rust, so part of the Python gap is the implementation rather than the format. The rest of the trade is the design working as intended rather than a defect.

- At the two realistic sizes the size result holds and the speed result stops mattering: SHCL writes the smallest file of the five for both the config and the schema definition, and reads them in 0.04 ms and 6 ms.

### CI/CD

The responsibility is split rather than duplicate the pipeline:

- The GitHub workflow (`.github/workflows/ci.yml`) is a correctness gate only - format check, build, lint, tests on pushes to `main`, on pull requests, and by hand. Minimal permissions, cancels superseded runs, times out.
	- The cross checks run there too. They build nothing anyone downloads - the C library and CLI for windows through mingw, the C library with file I/O compiled out, and the Go library for windows - so they belong with the other checks rather than with the release artifacts. Inside the release branch, `--ci` never reached them. `--no-cross` turns them off with the cross targets.

- `dev` is not gated, by the hook or by the hosted workflow. The pre-push hook runs `cicd.bash --ci --no-largedoc` on a commit bound for `main`, and skips one whose tree a run already passed. Each run that gets through the tests and the cross checks records the tree it tested, unless it ran `--quick`, `--no-fmt`, `--no-lint` or `--no-cross`, or skipped a missing tool. Before this, one change to `dev` went through a full local run, then the same gate again in the hook, then about half an hour of hosted CI.
	- A tree hash, not a commit hash. The publish stage commits after the tests run, and a `--no-ff` merge makes a new commit holding the same files.
	- Gating `dev` was dropped. Work merges there several times a day, and a ten-minute wait on each merge only re-ran what the branch had already passed. Building and testing before the merge is the check that counts there. `main` still gates every commit.
	- Making the hook opt-in was rejected, since nothing would then gate a commit that never went through a run. So was keeping hosted runs on `dev` behind a `[skip ci]` marker, which would have to be typed on nearly every push.
	- The cost: a failure only the runner shows, such as a tool its image lacks or a Windows-only defect, now waits for the next push to `main`. `gh workflow run ci --ref dev` gets a hosted run sooner.

- Everything else (cross-compile, packaging, publish) stays in the local pipeline, `cicd/cicd.bash`, config-driven via `cicd/config.bash`.

- Both share one definition of "passing": the workflow runs `cicd.bash --ci` on Linux, plus a Windows job for the binding runners. Per-language toolchain setup lives in the workflow YAML; what passing means lives in the engine, so the two cannot drift.

- The formatter rewrites in place locally but is check-only (fail on diff) in CI.

- Branch flow: `dev` is the integration target (feature branches merge there, `--no-ff`); `main` is release-only. A dev -> main merge is normally a release cut.
	- The exception is a merge that changes no product code - documentation, the demo asset, the pipeline. Those go to `main` on their own so the front page and the install one-liners (which read from `main`) stay current, and the version stays where it is. Cutting a tag for them would publish a second set of binaries that behave identically to the last one, which tells a reader nothing.
	- The three installer scripts count as front-page material for that rule, not as product code. Nothing ships them - no package, no release asset includes them - and the one-liners fetch them from `main` at the moment somebody runs one, so a fix that sits on `dev` reaches nobody. The alternative was to fetch them at a tag, which was rejected: it would freeze an installer's bugs into every release that shipped with them, and the installer's job is to fetch the newest release, not to be part of one. So an installer fix may go to `main` on its own, under the same no-tag, no-version-bump, no-changelog-entry rule as a docs merge.

- One canonical version source: `source/rust/Cargo.toml`. The pipeline reads it for artifact names and release tags. (An automatic bump-before-push guard was tried and dropped: dev is the integration branch, and versions there are cut deliberately at release time, not policed per push.)
	- The Go/Python/C CLI version strings and `source/python/pyproject.toml` are hand-kept mirrors of it, moved together at a cut along with the changelog heading and the front-page README's literal version strings.
	- A release binary prints a build number after its version, as in `shcl v3.0.0 build dd2f6`. It is the minutes from 2000 to the commit's time, in lower-case Crockford base32. It comes from the commit rather than the clock, so a rebuild of one commit still gives the same bytes. Only the pipeline's release builds are stamped. A `cargo install` from crates.io has no git history to read, so it prints the version alone, and so do the other three CLIs, which are compared byte for byte against an unstamped build.
	- Two tags per cut, not one: `vX.Y.Z` for the release, and `source/go/vX.Y.Z` for the Go module. Go resolves a module in a subdirectory only through a path-prefixed tag, so skipping the second one silently strands every Go consumer on a pseudo-version.
	- Release assets are signed before the release is published: both installers refuse a release whose sums file has no valid signature, so publishing first would offer an install nothing can verify.
	- A registry publish cannot be taken back. Neither crates.io nor PyPI allows reuploading a version, and each bakes in the README it was given at that moment - so the per-binding READMEs (`source/rust/README.md`, `source/python/README.md`) get their example code compiled and run against the packaged artifact before the upload, not after. Those files exist separately from the front-page README because relative links and images break on a package page, and Cargo cannot reach above the crate root anyway.
	- Binding versions move in lockstep with the product version, deliberately. The bindings are byte-for-byte equivalent by design, so a single number across all of them means a consumer reading `2.1` in any language knows exactly what behavior they have. It also lets each ecosystem's ordinary compatible-version operator (`shcl = "2"`, `shcl~=2.0`, Go's major-version import rule) do the tracking, with no scheme of our own to explain or maintain.

- Installer packages ride the release stage, not a separate pipeline: `cicd/utility/package.bash` builds .deb/.rpm (nfpm, one sed-rendered template) per Linux binary and an NSIS setup per Windows binary, into the same versioned artifact family before the checksums are written. Package layout follows distro convention (/usr/bin + /usr/share/shcl) rather than the /opt layout the standalone install.bash uses - packages answer to distro policy, the script answers to the spec. Payload matches install.bash: binary + code/ drop-ins + scripts/ wrappers.

- Release trust root: the sha256sums file is signed offline with an RSA-4096 key, and both installers include the public half inlined and check it before reading a checksum out of the file. Decisions behind it:
	- Order matters more than the algorithm - a checksum taken from an unverified sums file proves nothing, so the signature is checked first or not at all.
	- The threat addressed is release-asset replacement (a leaked token with release scope, a compromised CI job), not full repo compromise: an attacker who can rewrite `install.bash` on `main` can also delete the check. Those are different access paths, and separating them is the point.
	- The key is offline and signing is manual. A key in CI secrets would be reachable by exactly the compromise being defended against, which would make the signature decorative.
	- The key is inlined, not fetched. A key downloaded over the same channel as the artifact authenticates nothing.
	- RSA, not the more fashionable Ed25519, purely on verifier availability: `openssl` covers Unix, and .NET's RSA covers Windows PowerShell 5.1, where Ed25519 is absent. Any scheme needing a tool the box does not already have (minisign, cosign, gpg) loses to the bootstrap problem - verifying the verifier.
	- `openssl` became a hard prerequisite of `install.bash` alongside curl/wget. Installing unverified is not offered as a fallback; the DIY path is there for a box that genuinely lacks it.
	- Rotation is expensive by construction, since old installers have the old key. Treat a key change as a breaking change: new installer, and a release note.
	- The Go binding gets tamper-evidence free from `sum.golang.org`, so this covers the binaries and drop-in payload, which have no equivalent backstop.

- Toolchain pins: `rust-toolchain.toml` (rustc + clippy + cross targets) and warn-only pins for cargo-installed helpers, so a box update cannot silently change results.

- Release builds are reproducible. On the pinned toolchain in `rust-toolchain.toml`, building a given commit produces a byte-identical binary on any machine, from any directory, for all four release targets. The packages and the drop-ins tarball rebuild byte-identical too. So a release tag can be built and checked against the published checksum rather than taken on trust.

- Fuzzing lives in the regression suite, not a separate rig. A deterministic mutator over the corpus asserts two invariants for any input: never panic at any strictness, and the formatter is a fixpoint. The same mutator generates the inputs for the differential check above.

- Profiling is a standing stage. Every full run samples an optimized build over a heavy parse-and-format workload and emits a flamegraph plus a hot-spot summary, so a performance regression shows up in the artifacts the run it happens in. Sampling is in-process, feature-gated, and never reaches a release binary.

### Reference implementation

- Rust crate at `source/rust/`, zero dependencies, single-file library (`src/lib.rs`) so the drop-in integration mode stays real; the `shcl` CLI builds from the same crate. Later bindings get sibling folders (`source/go/`, ...).

- The conformance runner and fuzz smoke are plain `cargo test` targets, so "the corpus passes" and "the build passes" are the same command everywhere.

### Go binding (Tier 2)

- Module at `source/go/`: single-file library (`shcl.go`, zero dependencies, generics for the typed reads). The CLI under `cmd/` is its own module, so it stays out of the published one - same flags, output, and exit codes as the reference, but it exists to be driven by the differential check rather than installed.

- Conformance runs natively as `go test` (a port of the Rust runner over the same corpus), so the Go binding is corpus-green on its own, and the cicd crosscheck holds it byte-for-byte to the reference besides.

- The pipeline stays engine-generic: the Go fmt/build/vet/test commands ride the config's per-stage extras, and the binding registers in `BINDING_CLIS` - a pattern each further binding (C, Python) repeats without engine changes.

### C binding (Tier 2)

- Sources at `source/c/`: a single-header drop-in library (`shcl.h`, C11, zero dependencies) plus the CLI under `cmd/shcl/` - same flags, output, and exit codes as the reference. The single-header story is the C analog of the other bindings' single-file libraries: copy `shcl.h` into a tree and, in one translation unit, `#define SHCL_IMPLEMENTATION` before including it.

- The C++ interface (`shcl.hpp`) is not a second parser. It is the reference's API in std types, `get<T>()` included, with every call going to the same C functions, so it inherits the core's conformance and needs only a compile-plus-behavior smoke to stay correct. A C++ caller sees none of the C interface: the calls into C are compiled in one file, the way `shcl.h` compiles its implementation.

- Among making every const member of the C++ `Document` hold a lock, saying a Document is not shared across threads, and taking `const` off the reads, it was decided that const members lock. Every call into the core writes to the document behind it, its read and scratch arenas and its index, so two threads reading one const Document raced. A C++ reader takes const to mean safe to call at once, and the Rust `Document` is `Sync`. The locks are a fixed set picked by the document's address and recursive, and a call that reads two documents takes both together. Writes stay the caller's to keep to one thread.

- Conformance runs natively (a C port of the runner over the same corpus), so the C binding is corpus-green on its own, and the cicd crosscheck holds it byte-for-byte to the reference besides.

- Memory is a per-document bump arena, so teardown is a single free with no per-object bookkeeping. A short-lived-tool trade that keeps the port readable.

	- Nothing a document has finished with is reclaimed until it is freed: a replaced value, a removed node, a parent a merge rebuilt. `shcl_compact` rebuilds the document into fresh arenas and gives the old ones back, and the merge is what makes it worth calling - hundreds of kilobytes a fold on a large base, against dozens of bytes for one write. The other three bindings have no such call and need none, since reloading the canonical text is a cheap and ordinary thing to do there; each one's `remove` says so.

	- `shcl_reads_release` levels off rather than going to zero. The read arena keeps its largest block on reset, so a polling process reuses it instead of asking the system on every pass. What is left at rest is the biggest single result the process has ever taken, which for a `shcl_to_canonical` of a large document is the size of that document.

- An allocation failure ends a parse, not the process. A parse and a validate arm a recovery point before they start, so a failed allocation unwinds out of them and the call returns NULL with everything it held given back. Among the options it was decided this is worth deviating from parity for: the other three bindings abort on allocation failure because their languages do, so there is nothing there to mirror, and what a library must not do is end a process that is not its own. Everywhere else - a read, a write, a merge on a document already built - the `SHCL_OOM()` hook is the answer, and its default is still the CLI's print-and-exit-70; an embedder defines it before the implementation and takes it from there (longjmp out, log, abort). Nothing is unwound first, so a hook that returns leaks the document being built, and then aborts, because the allocation it was called for still failed. A hook that longjmps arms its recovery point with `SHCL_SETJMP`, which the header provides because that unwind crosses the library's own frames and mingw needs it done a particular way (see `style-guide_code.md`).

	- Carrying on with a fallback block, rather than unwinding, was tried first and does not work. A bump arena holds its vectors' bookkeeping, so an allocation served out of nowhere hands back node indices that are no longer node indices, and the next tree walk reads off the end of the node array.

- Two portability details the reference gets for free but C makes explicit: UTF-8 is iterated by codepoint (plain byte scanning would mishandle multibyte text), and float output reproduces the reference's shortest-decimal, never-scientific rule.

- C has no committed zero-dependency formatter, so its quality gate is a warning-clean compile rather than a separate format stage.

### Shell wrappers

- The shell binding wraps the `shcl` CLI, not a parser, so it inherits conformance for free.

- Bash 3.2 (`source/bash/shcl.bash`) was targeted rather than POSIX sh (mostly defined in 1979). The wrapper earns its keep by being dual-purpose: run it as a script, or source it and call functions. That dual mode and the typed helpers read far cleaner with Bash's arrays and `local` than with portable sh. A thin passthrough would give a sourcing caller nothing over the binary itself.

- PowerShell (`source/powershell/shcl.ps1`) is the second wrapper, built to the same design: dual-mode (run, or dot-source for the identical `shcl`/`shcl_*` helper names), the same binary-resolution order, and exit codes passed through into `$LASTEXITCODE`. It deliberately has no script-level param block - one would try to bind subcommand words - so every argument arrives in `$args` verbatim. Like the Bash wrapper it forwards rather than parses, so it is not in the cross-binding differential.

- One `shcl` function is the whole CLI. `shcl_get`, `shcl_int`, `shcl_bool`, and friends are one-line typed sugar. `shcl_duration` and `shcl_size` hand back milliseconds and bytes, as `get --duration` and `get --size` do. Both modes take the same arguments and return the binary's exit code unchanged, so a not-found or empty read stays a distinct nonzero.

- Two things a sourced tool must not do, and doesn't:

	- Leak shell options into the caller. Strict mode is armed only on the run path.

	- Let its own `shcl` function shadow the binary during lookup. The binary is resolved via `$SHCL_BIN`, a co-located `shcl`, PATH, then the repo build, so a dogfooded install and in-repo dev both work without configuration.

### Man page and completions

- `source/man/shcl.1` is roff by hand rather than generated from the help text. The help is a byte-for-byte contract across the four CLIs and is shaped by an 80-column terminal; a man page has different obligations - sections a reader can jump to, and room to say why a refusal exists. Generating one from the other would either bloat the help or flatten the page.

- The man page has no version string, so the release bump stays the same eight files it has always been. What it does have is a revision date.

- The completions mirror the CLI's own per-subcommand option table rather than inventing one. Offering an option the subcommand rejects is worse than offering none, because the CLI treats an unusable option as a usage error rather than ignoring it. `cicd/utility/check-completions.bash` diffs the CLI's table against both completion files at lint time, so the three cannot drift apart silently.

- Bash and zsh completion files are kept structurally parallel - the same table, the same helper names, the same positional-counting loop - for the same reason the bindings are: a fix ports across by mechanical diff.

- Neither completion offers anything for a `PATH` argument. Nothing can enumerate the paths in a document without reading it, and filenames - the obvious fallback - would be wrong every single time.

- **Where each channel installs them.** Among the options it was decided that the packages and the installer should behave differently, because they are different kinds of thing:

	- The `.deb` and `.rpm` put the man page and both completions in the distribution's own directories, where each shell already looks. That is what a package is for, and it is the only channel that can do it without stepping on the package manager.

	- The installer symlinks the man page into the target's `man1` directory, mirroring the binary symlink exactly - the same trick, and it makes `man shcl` work as soon as the install directory is on `PATH`, since man derives its search path from the `bin` directories there.

	- The installer leaves the completions under the install directory and prints the line to paste for each shell. There is no one directory that works: bash's autoload directory varies with the bash-completion version, zsh needs a directory already on `$fpath`, and writing into the distribution's own would collide with the packaged copy. Printing the line is the same bargain the `PATH` note already strikes - plain about what was not done, with the fix one paste away.

	- Uninstall removes only what a matching install laid down, and the man symlink only when it points back into the install directory. One that does not came from a package, and removing it would break a working install.
