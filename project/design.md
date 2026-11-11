<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Design

Design, requirements, and direction. The task list is in `backlog.md`. The full language definition is in `spec.md`, with `grammar.abnf`. This file stays high-level and gives the reasons rather than the letter of the rules. The next major is drafted in [the v4 design](design_docs/20261015-072055_v4.md).

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
	- [Lines an edit takes from their node](#lines-an-edit-takes-from-their-node)
	- [Default forms](#default-forms)
	- [Generation outcomes](#generation-outcomes)
	- [Testing](#testing)
	- [Format comparison](#format-comparison)
	- [CI/CD](#cicd)
	- [Reference implementation](#reference-implementation)
	- [Go binding (Tier 2)](#go-binding-tier-2)
	- [C binding (Tier 2)](#c-binding-tier-2)
	- [Shell wrappers (retired)](#shell-wrappers-retired)
	- [Man page and completions](#man-page-and-completions)
- [Copyright and license](#copyright-and-license)

<!-- /TOC -->

## Assumptions

- The language began by worked example, before the spec existed. Where the early examples and the spec disagree (and they do), `spec.md` wins.

- The language is delivered as tiered bindings, plus single-file drop-in source and compiled binaries per platform.

	- The corpus is the guarantee, whatever the binding count. Every released binding is corpus-green, and none is released before it is.

	- Tier 1: the Rust reference and the `shcl` CLI built from it. Rust wins on the stated priorities: small binary, instant CLI startup, a clean shared-library build, and compile-time strictness that forces spec precision.

	- Tier 2: Go, C with C++ over it, and Python.

	- Tier 3: the rest, which are C#, Java with Kotlin, and JavaScript. They're deferred for now and corpus-gated, and they're designed for from the start.

	- Bash and PowerShell scripts call the CLI, so they inherit its conformance for free. The wrappers that used to sit between them and the CLI are retired, as [Shell wrappers (retired)](#shell-wrappers-retired) explains. The companion typed APIs for C++ and Kotlin are each one core plus an interface of their own rather than separate parsers.

## Guiding principles and decisions

The inescapable core tradeoff (for any config language) is to acknowledge and optimally balance "simplest possible" versus "expressive enough for anything" - including a simple DDL language. Ultimately it comes down to two factors:

1. Ideologically-driven opinion on where the balance should be - informed by technical experience, related PTSD gained along the way, childhood trauma - all of it.

1. The observation that processing power is now dirt-cheap even on the smallest embedded systems, validation and "correctness" tools are now incredibly powerful - and the subsequent decision to move as much of the heavy-lifting of the language on to this code, and away from end users and programmers.

Other points

- Optimize for the hand-authoring user and the value-consuming programmer; burden neither. Any ambiguity a modern parser can resolve from context, it must - the user is never made to satisfy the machine.

- The data model is relational, not a map. The left-of-colon token is a *field* (column), not a unique key; repeating it with different values yields *instances*. One rule covers wrappers, leaves, and valued instances: nodes are `(name, value, children)` and merge on matching `(name, value)`.

- Typing is accessor-driven: the parser stores raw text and never guesses; the consumer requests a type on read and the library coerces intelligently but safely, reporting problems without ever refusing to keep working.

- Forgiveness is a feature: never bail on a whole file for one bad line; skip/repair and diagnose; never error when a value is legitimately reachable.

- Forgiveness is also a knob rather than dogma. There are 3 strictness levels instead of a binary strict flag, which are Loose, Standard, and Strict. They're set per document, and Standard is the default. Standard keeps the defaults clean. It doesn't strip currency, read `%` as a fraction, or round a float on an int read, and its boolean set is trimmed. Loose lets those conversions back in as a closed list, for anyone who wants the most forgiving reads. Strict fails the load on any error diagnostic, which is the StrictYAML-style answer. Adopters judge a language by its defaults, so the party tricks stay in as opt-in. The normative bundle table is in `spec.md`.

- The knob belongs to the consuming program rather than the end user. Strictness and bad-read handling are part of the contract an application makes about its own config handling, so they're set at the call site or by the CLI flag and nowhere else. A per-user defaults file was considered and rejected. It would let a user silently weaken guarantees an app relies on, and it would make an identical `shcl` invocation mean different things on different machines, which was the `GREP_OPTIONS` mistake. Nothing else the CLI exposes is presentation-only, so SHCL doesn't have a user config file at all.

- Coercion earns trust by refusing to surprise. Silent lossy conversion, such as rounding a float on an int read or reading `$1200` as a number, was cut from the default level for that reason. For the same reason the fehu anti-escape rune was dropped, since raw blocks are the verbatim escape hatch, and field-name case folding was restricted to ASCII, because full Unicode folding is a locale trap and a risk to parity between bindings.

- Since 2.0, names are compared after their escapes are resolved.
	- A name used to be compared and emitted in its escaped spelling, so `"a\"b"` and `'a"b'` were 2 fields, while the same 2 spellings as values were one string. Names and values meant different things by a quoted string, and a consumer who spliced user text into a path had to know which of the 2 it was in.
	- Escapes are resolved on names now too. Names were already normalized once, by ASCII case folding, so this finished a rule the language had started rather than inventing a new one.
	- The change waited for the 2.0 major because it moves canonical output for a spelling that was already published. It also merges 2 fields that used to be distinct, which is the same kind of merge case folding already does.
	- The as-authored accessor is the one call that still returns the source spelling, since that's what it's for.
	- Emitting needed a real escaper rather than the value one. The value escaper picks a quote style so it doesn't have to escape, and it never escapes a backslash. That's right for a value, which is stored in its escaped spelling, but wrong for a name, which is stored resolved.
	- A line break in a name became writable as a side effect, because the name escaper writes it as `\n`. Before, it had to be refused. A line break in a `[value]` selector is still refused, since the value emitter has no way to write one.
	- Format 3 kept the rule and changed the spelling. Escapes are `◉` names now, so `"a◉DOUBLE_QUOTE◉b"` and `'a"b'` are one field. Names and values go through one quoter, which writes a line break as `◉NEWLINE◉` in a name, a value or a selector.

- Raw (fenced) blocks give verbatim escape hatches (DDL, code, templates) without contorting the config syntax.

- A fence is just a value line for its parent field. The same-line spelling (`name: ~~~sql`) read badly, so the canonical spelling puts the fence on the next line at child indent - and rather than special-case that, the rule is uniform. A fence fills the parent's empty value, or creates a new instance if the parent already has one (the repeated-leaf rule). Blocks are then ordinary instances: no index-addressing syntax to invent, and the existing index selectors, `(0)` today, just work.

- Parity over idiom in the bindings. Each port mirrors the reference's structure, with the same function inventory, call flow, and contract strings, even where the host language would do it differently. Byte-for-byte agreement is the product's core guarantee, and the parallel structure is what makes it maintainable, because a fix ports by mechanical diff instead of being worked out again. Per-language idiom still decides formatters, naming case, and doc comments, but it gives way on structure. The full rules and each accepted deviation are in `style-guide_code.md`.

- Positioning: the pitch is "forgiving to write, predictable to read", with a read API built junior-first. It isn't "simplest possible", which overpromises and invites the takedown. Against schema-bearing languages such as Pkl and CUE, the file stays dumb and the library is powerful, as Power layer describes.

- The CLI's informational outputs are the flags `-h`/`--help`, `-v`/`-V`/`--version`, `--about`, and `--donate` (2026-09-28). `help` also stays as a word, since it takes a topic, as in `help CMD`. The words `version`, `about`, and `donate` were removed, and a leftover one gets the did-you-mean hint. The flags are recognized anywhere in option position, after FILE included, since where a person types `-h` on the line doesn't say anything about what they want. Only a value slot and anything after `--` are data.
	- When several are asked for in one run, each prints once, in the order asked, with one blank line before, between, and after. `--about` includes `--version`, since it opens with the same 2 lines. A lone `--version` prints those 2 lines bare for scripts, the version line and then the copyright line (2026102416250100).
	- `help` refuses anything after it except one topic and the informational flags.

- `-` for stdin may be named only once across FILE, `--layer`, and `--schema`. There's only one stream, so 2 names for it each read part of a document, and which name got the real content depended on read order. The second name is a usage error now.

- **Nothing on the command line resolves last-wins.** A pair of options that ask for different answers is a usage error in either order, and the message names both. The rule applies to 2 different type options on `get`, and to one value option given 2 different values. A repeat with the same value doesn't compete with anything, and `--layer` and `--set` are ordered lists, so they repeat by design. A new option is judged against the rule rather than against the list of pairs.
	- Why: `get --raw --int` printed the int, but `get --int --raw` failed at exit 4, so the same 2 flags gave 2 answers and neither one said anything. `--default` against `--on-bad=error` had already been fixed the same way, one pair at a time. The rule fixes the whole class instead.

- The informational outputs print with a blank line above and below, so the block doesn't butt up against the shell prompts on either side of it. Bare `shcl` counts as asking. It prints the same padded help as `shcl help` and exits 0. `--version` stays unpadded on purpose, so a script can still capture its 2 lines cleanly. Output is padded when a person asked for it, whatever its length.

- There are few lexical rules, and what a byte means depends on its position. The rule table is under Lexical edges below, and `spec.md` has the normative wording.
	- Why: the same lexical rule was in 7 scanners per binding, and every scanner defect since July was 2 of them disagreeing. A fix went only into the copies where the defect was reproduced. One tokenizer per binding replaces them, and with fewer rules it has less to get wrong.
	- This is what changed at 3.0, and what `migrate` rewrites a 2.x file for. The first tokenizer cut kept backslash escapes, inside double quotes only. The value syntax design then dropped them. A backslash is text everywhere, and an escape is a `◉` name from a closed list. A quote, a tab, or a bracket inside a bare piece is an error. An array is written in brackets or as `- ` lines. A quoted piece opens with a quote as its first character and closes at the matching quote, which has to be the last thing in the piece. The `field:[disc]` sugar is gone, and a selector is written in parens, `base(Boston)` (2026100610073400), so a bracket always means an array. A `[` first after the colon opens one, and a `[` right after a name is the old selector spelling, `E029`.
	- Escapes, quoting, bare values, arrays, lists, and the hidden-character list are in `spec.md`. The reasons for them, and what was weighed and turned down, are in [the value syntax design](design_docs/20261002-132445_value-syntax.md). The Rust reference has them, and the Go, Python, and C ports follow before the cut.
	- Some 2.x text reads differently now. A 2.x backslash escape reads as written, a 2.x comma list is one string or an error, a `*` item is `E013`, a selector in brackets is `E029`, and 4 forms that 2.x bound don't bind anything now, as listed below. `migrate` rewrites a file in one pass, and writes a backslash pair as the text 2.x read (2026101911300000). The migrated file is for 3.0 readers only, since 2.x can't read its brackets, its parens, or its `- ` lines. There's no 2.1.0, and everything since 2.0.0 goes out in 3.0.0.
	- The comment rule didn't change. It's 2.x's, so a 2.x file's comments and values read the same before and after. There are 3 edges that read differently, and `migrate` leaves each one as it is. A fence label with a `#` ran to the end of the line in 2.x and has no quoting. A carriage return at a piece's edge in the middle of a line was kept by 2.x and is a blank now. An indent that isn't on any open level's column was placed by a looser comparison in 2.x and is `E012` now, since `migrate` rewrites spellings rather than layout.
	- The text doesn't say which rules a file was written by, so the info block has a `Format` line naming the format's major, and `migrate` and `upgrade` are the only commands that act on it. `format_version` gives a program the same answer, so it can ask before it rewrites anything, and `read_format_version` says why there isn't one, either no line or a line whose number doesn't read (2026100912352401). A file with the current major has nothing to migrate. One with an older major, or a call that passes `--from-2x`, gets every rewrite. Anything else gets the rewrites of lines these rules already refuse, including every line with a selector in brackets. Any piece that both rule sets read cleanly but differently is left as written, at exit 7, such as `a,b`, a `◉` escape, a backtick value, `[a]`, or a `- ` item. A rewritten file is stamped with the line and a migrated-from note, which is what makes a second run a no-op rather than a second rewrite of the first one's output. An older Format line is written over where it is, so the file names one format (2026100916475300). The new line stays there only when it reads back as the file's stamp through the same reading. Otherwise it's added at the end, as for a file without one. The library never adds the whole block, since that would write bytes that aren't in the document. It also doesn't stamp a file that never closes a raw block under either rule set, since the line would end up inside the block as content. `shcl migrate` refuses that file at 7 rather than write it unstamped, which would leave the next run unable to tell it was migrated. `migrate_unstamped` leaves the stamp off for a program that writes the whole block itself as its footer, which then includes the line.
	- A load gives a hint when the line names another major (2026100717500017, OK'd 2026-10-08). It's `H006` for a newer one, since this reader can only guess at a later format's rules, and `H007` for an older one. `upgrade` leaves a clean file stamped with an older major alone unless it's told the file is 2.x, so `H007` names `upgrade --from-2x`. With that flag, a file with nothing else to change gets this format on its Format line and is backed up like any upgrade, so following the advice clears the hint (JC, 2026-10-09). That reverses part of 2026100313461649's call, which left such a file alone. A hint doesn't change any load outcome, so a file that loaded clean still does. The hint and `read_format_version` share one reading of the line, so they can't disagree. The hint quotes the number as written, since the read caps one past 32 bits (JC, 2026-10-16). A line whose number doesn't read doesn't get a hint, and the status says so.
	- No save writes a document whose Format line names a newer major (2026102910482344, pulled into 3.0.0-beta1 by JC). A save would write each line by these rules under a Format line that says otherwise, so a line that the newer format reads another way could change without any error. Each binding reports it through its own spelling of `newer_format`, from the same reading `H006` comes from, for a load and a parse alike. Every save of such a document is refused, wherever it goes, with its own kind, which is Rust `SaveError::TooNew`, Go `*SaveTooNew`, Python `SaveTooNew`, C `SHCL_SAVE_TOO_NEW`, or C++ `SaveResult::TooNew`. It's checked first, before the lost-content gate, and no option overrides it, since nothing the caller knows makes these rules right for that file. A merge picks up a newer layer's status, since that layer's lines are then the document's, read by these rules. Reads and edits work as usual, so a program that only reads still gets its settings. `write_file_atomic` writes the text it's given, and `upgrade_file` and `migrate` already leave such a file alone. The CLI's `--write`, `fmt --check`, and `set`'s print refuse at exit 7, as for a lost line, and `fmt` to stdout still prints, since it writes nothing.
		- Decided against: shclwrap's `ReadOnly` as the name, since `ReadOnly` is already a write status for a read-only filesystem, and a term has one meaning. Also against refusing only a save over the file the load read, since a newer document's lines are this reader's guess wherever they go, and against an override, as `create` doesn't have one either.
	- `migrate` reports what it couldn't convert rather than exiting 0 over it. Those are the pieces it couldn't decide between the 2 rule sets, and the forms 2.x bound that nothing binds now, which are bracket text after the colon, a selector with a comma, a comma list on a field with lines under it, and a quoted name with a backslash pair, which 1.2 read as typed and 2.0 resolved. Both are exit 7, and each has its own override, `--from-2x` for the first and `--lossy` for the second on a rewrite, because one is a question the text can't answer and the other is a real loss.
	- `migrate --write` ends with 2 files rather than one converted in place. The new text is at the path, and the original bytes are beside it (2026-09-27). The copy was `NAME_old_v2.EXT` until 2026-10-07. It now has the one backup name `upgrade` uses too, `NAME_backup_YYYYmmDD-HHMMSS_format-vN.EXT`, in local time, with N the format the file was written for, so a user finds every backup by one pattern and a second run on another day doesn't stop on the first one's copy. The copy is made only when a line is rewritten, since a file that only gains the Format line reads the same under both rule sets and may be a 3.0 file nobody stamped. An older Format line written over is a rewritten line, so that file gets a copy. The copy is an exclusive create, synced, at the original's mode, and it's written before the save starts. A taken name is exit 8, never an overwrite. If the save then fails and the file still has the original, the copy is removed so the next run isn't blocked. If it doesn't, as after a replace that failed part way on Windows, the copy stays and the error names it.
	- `upgrade_file` (2026100313461649) is for the program whose own shcl upgrade leaves it with a config file it can't load. It's opt-in, since some programs keep their own backups. It never writes a file that names this format, or one that loads without any error, because a program calls it on every start and must not rewrite a good file. The one exception is a caller that passes `from_v2`, which says the file is 2.x. Then a file that loads clean but that `migrate` would change is made over too, such as `p: a,b`, which is an array under 2.x. One that `migrate` wouldn't change but whose Format line names an older format gets only that line rewritten, after the backup, since that's all it needs. That leaves out a file that a beta build of 3.0 wrote. A beta stamped the same Format line and info block as a release, so the stamp can't tell them apart, and a guess from the content would rewrite a current file with a typo, such as turning `a,b` into an array. The caller can tell them apart, so `from_v2` takes one that loads with an error as 2.x (2026101407100010), backed up under `format-v3`. A file that loads clean stays. With `from_v2`, a file whose fresh file wouldn't load clean is refused, with a Format line or without, and the lines still in error are reported (2026101515372401), since a second run with `from_v2` would then convert the result again and mangle `◉TAB◉` and the like each time. `from_v2` is for a file the caller knows is old, never for every start, since a file this format wrote that picks up an error later would be read by 2.x rules too (2026101419280001). `migrate` still leaves such a file alone for the same reason, since its output can keep a line with an error. Anything else goes through `migrate_unstamped`, then the canonical writer, and gets the block `init` writes, with 2.x's `#` block taken off, so the result reads as a fresh file. It's the one library write that adds the block. The original is copied under the backup name by an exclusive create before the save's temp file and rename replace it, so the path always has one or the other and a taken name is never written over. It's a copy rather than a rename, since a rename on POSIX replaces whatever is at the new name. Unlike `migrate --write`, `upgrade_file` doesn't stop on a line the fresh file can't contain. The backup has every byte, and the request was for a fresh file with whatever converts. It still stops on text that reads 2 ways, since there it would have to guess what the file means.
	- `migrate --check` compares the input and the migrated text line by line, in the CLI. The rewrite never adds or drops a line ahead of its stamp, so line N is line N on both sides, and the library doesn't need anything new. A line to rewrite is exit 6, the code `check` uses for a file with something to fix, and exit 7 still wins when `migrate` couldn't finish or when the save gate would refuse the rewrite. `fmt --check` asks that gate the same way.

- An upgrade path is part of the product, for this format change and any later one, and it's kept simple (JC, 2026-10-15). It converts what it can convert for sure and leaves or refuses the rest. It doesn't chase every edge case of an old format, since nobody outside these projects has 2.x files. The `migrate` and `upgrade` rules above are 3.0's form of it, and in [the v4 design](design_docs/20261015-072055_v4.md) they're cut down to one `upgrade` with one step per format.

- One tokenizer per binding is the only reader of a line's parts. It takes text and a separator and returns spans. Each segment gets a name and an optional selector body, each with how it was quoted. There are also spans for the separator, the value and its elements, and the comment, or else the fault that makes the line malformed. Nothing is copied. The parser's line dispatch, the path scanner behind every lookup and setter, `SetLiteral`, `SetRaw`'s info check, and the CLI's `--set` split all read those spans, and the 7 scanners they replaced are deleted rather than wrapped. `migrate` reads with a 2.x flag on the same tokenizer, so the old rules are in one place too.
	- The tokenizer is pinned by a `tokens` subcommand on every CLI, compared 4 ways over the corpus and the fuzz soup, and by a generator in the reference that builds lines from the grammar with their spans known and asserts the tokenizer returns exactly those.

The itemized decisions are recorded in this file as they're made, and `spec.md` is their normative form.

## Architecture

### Software stack

There are many bindings, with a shared conformance corpus in `conformance/` as the contract between them. One portability constraint decides how the Accessor looks. The requested value type is expressed by a typed entry point or a compile-time generic, never a runtime `type` field, because static languages such as Go, Rust, C, C++, and C# can't let a runtime value pick a return type. There are prebuilt binaries for Linux and Windows on x86_64 and ARM64, for macOS as one universal binary for both, and for FreeBSD on x86_64. FreeBSD and macOS cross-build with zig, the same way as Linux ARM64. macOS doesn't need an Apple SDK for this, because zig has its own stubs for libSystem and the CLI doesn't link anything else. cargo-zigbuild builds both macOS halves and joins them into one file, and the build pins macOS 13 as the floor rather than taking zig's default, so a zig upgrade can't move it. Rust has no prebuilt std for FreeBSD on ARM64 or for OpenBSD, and cargo-zigbuild doesn't take NetBSD, so those build from source.

### Configuration model

`spec.md` defines fields and instances, accessor-driven types, arrays against instances, and raw blocks.

### Consumer API

The consumer-facing API is the **Accessor**, which reads, and the **Writer**, which emits.

- The Accessor's one conceptual operation is a **lookup**, or query. It gets a value at a path, coerced to a type, with a default and an on-bad policy, and each language does it in its own idiom.

- The type is chosen by a typed entry point or compile-time generic rather than a runtime field, so results go into a strongly-typed variable and the consumer doesn't have to cast everywhere.

- For consuming a file as a whole there's **traversal**, or scan. It materializes the document by merging duplicates and ordering it deterministically, and then walks it with wildcards and instance enumeration.

- The Writer does the reverse and writes out defaults, values, and comments. Structured diagnostics come back alongside.

The consuming programmer is assumed to be a junior in every binding, including the static ones, so ergonomics are a design constraint from the start. These are settled:

- There are 2 tiers, junior-first. A convenience tier is the documented default, with one value, one baked-in fallback, one return, and no status to inspect. The full tier is the form that returns a status, for when the caller needs to know why a read failed. Every binding names the convenience tier `_or`, so a routine ported between 2 of them can't keep the call name while it changes tier. Each language's native idiom for the same thing still works where it has one, such as Rust `unwrap_or`, Python's default argument, and the CLI's `--default=`.

- A supplied default implies default-behavior. The caller never writes both a fallback and an explicit on-bad, which is why the libraries don't have any on-bad parameter. The tier you call is the mode. `Error` mode has no library form, because a read that can't reach a value is a normal outcome rather than a fault, and a caller who wants a throw already has the status to raise on. The CLI keeps the explicit `--on-bad`, since it has no tiers to choose between.

- The convenience tier defuses the one real hazard of a forgiving accessor, which is a junior who discards the status and trusts a `0` or `""` that was empty or missing. Since the fallback is mandatory and visible at the call site, an unwanted zero can't slip in unseen.

- Portability is unaffected. The type is still fixed by the entry point or generic, and the fallback is an ordinary parameter.

- **Resource caps are set by the caller rather than built in.** The depth cap is a constant because no legitimate document is 512 deep. A legitimate large config can have millions of nodes, though, so one built-in number would either refuse real documents or sit too high to protect anything. `ParseLimited` takes a node cap, an array-element cap, and a diagnostics cap, with 0 for uncapped, and it was added the same way in every binding.
	- At the node cap the parse stops and reports once (`E020`), with the unparsed remainder counted as lost. Skipping line by line, the way the depth cap recovers, would emit one diagnostic per remaining line on the very input the cap exists for.
	- The node cap counts comment lines and kept lines too (2026-11-07). Each costs about what a node does, and a file of nothing else didn't build any node, so it took 100 times its size under the tightest caps. A separate cap for them was weighed and left out, because it would be a fourth number every caller has to pick, for the same memory.
	- `E020` goes on the first line not parsed. A cap crossed on the last line with content doesn't stop anything, so it doesn't report anything, and the overshoot is the one line it always was. It used to report there with nothing lost, which failed a Strict load of a whole document.
	- An over-long array refuses its whole line (`E021`). Truncating it would leave a value the author never wrote, and it would check clean forever after, which was the bracket-array lesson.
	- Past the diagnostics cap the list ends with one `E022` that counts the rest. Otherwise a document of nothing but bad lines costs a diagnostic per line, and the element cap alone can't bound that cost.
	- The depth cap keeps its skip-and-continue recovery. Stopping there too was weighed and turned down. A deep line already loses only its own subtree, every dropped line is diagnosed and counted lost, and the save gate refuses to rewrite the file. Stopping would also discard everything after the deep line, which is more loss.

- **Reading a whole config into one structure was declined on purpose.** Every binding reads one path at a time, so a config with 40 keys is 40 call sites, and users who come from libraries that decode a document into a typed struct in one call will notice.
	- It was considered and turned down, because the reference can't implement it. A derive-based decoder needs a proc-macro, which is a second crate, and the product is one file per binding with no dependencies.
	- Hand-writing the reflection instead would give each binding its own machinery with nothing in the reference to mirror. That turns the parity rule upside down, and parity is what keeps a fix portable by mechanical diff.
	- A local decoder in the 2 languages that could do it cheaply would be worse than none, since the same config would then load 2 different ways depending on the language.
	- The 40 call sites are one loader function a consumer writes once, and `Children`/`Paths` plus the typed reads are what it's built from.

### Integration modes

There's one question, "how do you pull SHCL into your project?", and 2 kinds of answer, which are to run it or to embed it. They're named plainly and ordered easiest first, so a beginner starts at the top:

- **Command**. Run the `shcl` CLI from a shell or script. There's nothing to compile and nothing to link.

- **Drop-in**. Copy one source file into your project. There's no dependency and no build step, and you own the copy.

- **Package**. Add it as an ordinary dependency and let the package manager fetch it (`go get`, `pip install`, `cargo add`, and so on).

- **Shared library**. Compile a drop-in source file into a `.so`, `.dll`, or `.dylib` and link it at runtime. The library stays a separate file.

- **Bundled**. Compile the same source into your binary, so you distribute one self-contained file.

The last 2 are the same code compiled 2 ways. A shared library stays a separate file loaded at runtime, and a bundled one is built into your binary. Neither is published as a prebuilt artifact, and that was a decision rather than a gap. A release includes the CLI binaries, the packages, and the drop-in sources. Publishing a shared object means an ABI to maintain, with a soname, symbol versioning, a separate headers package, and a promise that a caller built against an old one keeps working. All of that pulls against the premise of one file with no dependencies. The C header also exports plain externs with no export macro, so a Windows DLL would need one anyway. Every mode gets the same Accessor and Writer API, and the choice is about packaging rather than capability.

### Power layer (library-level, grammar untouched)

Compared to schema-bearing config languages (Pkl, CUE), SHCL is deliberately weaker in-language - that is the simplicity trade. To close most of the practical gap, the power lives in the library, never in the grammar: Pkl makes the config file powerful; SHCL keeps the file dumb and makes the library powerful. Everything below is optional - a consumer doing a bare `GetIntOr` never sees any of it - and none of it adds a rule a file author must learn.

- **Schema-as-SHCL validation.** A schema is itself a plain SHCL file that describes expected paths by type, required, allowed values, and ranges. One library call, `Validate(doc, schemaDoc)`, returns the same structured diagnostics loading already produces.
	- The schema vocabulary, such as `int` and `required`, is interpreted by the validator rather than the parser, so the core language stays free of reserved words. The fence info-string works the same way.
	- This also closes the typo hazard of a forgiving parser. The schema knows the legal field names, so unknown or misspelled fields get caught ("unknown field `enabeld`, did you mean `enabled`?"). The design is below.

- **Layered loading.** It's implemented, as spec.md "Layered loading" describes. `Load(defaults, site, user, ...)` is a left fold of `merge(base, over)` across files.
	- Container instances merge on matching `(field-name, value)`, which is the existing in-file rule. A leaf name in a higher layer replaces the lower layer's leaves of the same name, though, so defaults-plus-override works for scalars, arrays, and raw blocks as well as structure.
	- CLI `--set PATH=VALUE` sits on top as the final layer and is written through the Writer as data. `--set='x=80, 443'` stores the one string `80, 443`, where `--set-literal='x=[80, 443]'` stores the array of 2 elements.
	- Env-var mapping was dropped on purpose. The env namespace and its convention belong to the consuming program, which can map env onto `--set` itself. The same reasoning canceled the per-user config file. `check` doesn't take any layers, since its diagnostics are for a single file.

	- On `set`, a `--set` is an edit rather than a layer, so `set --write` saves it. Before that, the only route to a write from the shell was a tab-separated script on stdin, which no shell writes comfortably and no editor preserves. A family of typed options such as `--int` and `--string` was measured first and rejected. The type already follows the text, so the typed forms produced identical output. One gate moved instead of 20 options being added.

	- `--set-literal PATH=TEXT` is the same option, but it reads its argument as value syntax instead of data, which is what lets an array be written as an option at all. It parses the text rather than splicing it in, so the outcome is a value or a rejection. Output stays canonical, a written document is still a formatter fixpoint, and there's no way to inject syntax through it.

- **Schema-driven generation.** It's implemented, as spec.md "Schema-driven generation" describes. `generate(schema, no_banner)` and `shcl init --schema` emit a commented, typed starter config.
	- `desc` becomes a comment, and a generated annotation line sums up the type and constraints. Required fields are live, with their `default` or an empty value, optional fields are the same line commented out, and wildcard paths go in a trailing comment block.
	- Output is in flat dotted form, which mirrors the schema, and it always loads clean. It ends with a footer that names the format and links its spec.
	- A path whose last segment selects by value, with a `default`, is written as the bare path with the default (`env(prod)` with `default: prod` is `env: prod`), since a value after that selector is ignored. Validation decides whether the default names the selected instance. Refusing every such default was rejected, because it faults schemas that can be satisfied. Writing `env(prod):` and dropping the default was rejected, because the raw-default `V092` fault exists to stop a dropped schema input. Comparing the default with the selector inside the generator was rejected as a second copy of a match the validator already does. The self-check reads the load's error diagnostics before validation's, so a line that doesn't load is `V097` as well.
	- An optional field's commented line gets the same check. The line is read back alone, and its value is checked against its own field. Uncommenting every optional line and validating the whole text was rejected. A valued parent and a dotted child written as 2 lines name 2 instances, so a schema whose lines each work on their own would fault.
	- The annotation line and the footer are both byte-for-byte contracts across bindings, so their format is fixed and the annotation's numbers use the canonical formatters.
	- Of the options for the footer, writing it by default with a negative knob (`no_banner`, `--no-banner`) was picked. A generated file is usually the first SHCL a person ever sees, so the pointer to the spec earns its place, and with a negative flag a caller who says nothing gets the useful behavior. It goes at the bottom so the file opens with the settings rather than the boilerplate.
	- Its `Legal` line has SHCL as the subject rather than the copyright, so a reader can't take it as a claim over the config it's in.
	- Prose the generator writes starts with `##`, and a commented-out setting with a single `# `. A starter config is mostly comment, and with one `#` for both, the reader had to sort prose from settings by eye. Nothing depends on the difference, since both are comments to the language, and a config author may write a comment however they like. The banner is a public constant in every binding, so when the CLI writes it into a created file, that isn't a second copy of it.
	- When `set --write` creates a file it writes the same block, since that's the other way a new config file comes into being. The block is seeded as the created document's text rather than appended afterward, so the edits go above it and the write still goes through the library's save gate.

Explicitly out of scope, with finality unless something big changes: in-language expressions, functions, inheritance, interpolation, imports, anchors/references. The moment config files can compute, they need debugging - that is the complexity cliff to avoid.

### Schema validation

The schema is a plain SHCL file, read with the ordinary parser and the ordinary Accessor. It doesn't need a grammar change, reserved words, or any new parser feature.

**Layout: a flat list of path descriptions rather than a mirror of the document.** Each constraint is one instance of a field named `field`, whose value is the path it describes and whose children are the constraints:

~~~shcl
field: server.port
	type: int
	required: yes
	min: 1
	max: 65535

field: "server(*).host"
	type: string
~~~

The alternative was a schema that mirrors the document's tree, with constraints as children of each leaf, and it was rejected. It can't tell a constraint named `type` from a real document field named `type`, so the schema vocabulary would collide with the user's names. The flat form doesn't have that ambiguity, because the document's paths appear as values and never as field names. It also follows from the relational model the language is already built on, where `field` is the column and each path is a row, and it reads as an ordinary SHCL file to someone who has never seen a schema.

Consequences of the flat form:

- The validator doesn't need any new lookup code. `Instances("field")` enumerates the described paths, and `field(<path>).type` reads a constraint.

- A path with a bracket selector had to be quoted (`field: "server[*].host"`), because a bracket ended a bare value. With selectors in parens a path reads bare, `field: server(*).host`, since a paren is text in a value. The formatter writes the path as a value, so it quotes one with a paren, a quote, or a `#`, and `fmt` makes `field: server(*).host` into `field: "server(*).host"`. Both read the same.

- `shcl fmt` works on schemas for free, like any other SHCL document, and its output is a fixpoint.

**Wildcards handle repeated instances.** `server(*).port` constrains every instance of `server`, which is how a schema says "each server needs a port" in a language whose core idea is repeated instances. `repeat`, on the parent path, bounds the instance count itself. It's the one constraint that has no equivalent in tree-shaped schema languages.

**The vocabulary stays small and closed**, like the Loose coercion list. It's `type`, `required`, `allowed` (an enum, written as an ordinary array), `min`/`max` (inclusive numeric ranges), and `repeat`, plus `default` and `desc`, which only the generator reads.

- Fragments later added `inherits` as a constraint key, alongside the top-level `fragment:` declaration. Nothing joins that list without a spec change.

- Datetime ranges were considered and dropped for the same reason as regex below. Comparing datetimes across zone suffixes needs calendar arithmetic, since an offset can roll the date. No parser has any, and 4 hand-written implementations of it would be a parity minefield.

**Regular-expression constraints are rejected outright**, and this is the one real capability given up. None of the target languages share a regex engine, since character classes, Unicode properties, and anchoring all differ. A `pattern` key couldn't keep byte-for-byte agreement across bindings, which is the product's core guarantee. An enum handles the common case, and anything past that belongs in the consuming program.

**Validation reuses the reads, so strictness composes automatically.** `type: int` against `3.5` passes at Loose, which rounds, and fails at Standard. That follows from the validator calling the same typed reads a consumer would, and it's the correct behavior. The schema says what the program needs, and strictness says how forgiving that program is about getting it.

**Diagnostics reuse the existing structure** of line, severity, stable code, and prose message, so a consumer inspects validation results the same way it inspects load results. There are 2 additions:

- There's a `V###` code range, separate from the parser's `E###`/`H###`, so a validation failure is never confused with a parse failure. Unknown field, missing required, wrong type, value outside the allowed set, out of range, and wrong instance count each get one.

- Line 0 means "no line". A missing-required-field diagnostic needs a report for the whole document, since the point is that nothing was written.

The "did you mean `enabled`?" suggestion goes in the prose message rather than the code. Otherwise edit-distance implementations would have to agree byte-for-byte across 4 bindings for a string whose wording is up to each binding.

**A field name in a diagnostic appears the way the emitter would write it.** Pasting the stored name in raw let a name with a line break split one diagnostic across 2 lines. It also printed a flat `a.b` the same as `a` nesting `b`, which is the ambiguity that `paths` output and `QuoteSegment` already avoid by quoting. Every site that names a field now goes through one helper, so the `H001` and `H002` suppressors still match the head their builder emitted. A carriage return used to be escaped for display only, since the name parse had no `\r` escape to read back. Since format 3 the emitter writes it as `◉CR◉`, like any other control.

**A value in a diagnostic is its text, on one line, cut past 200 characters.** A backslash is itself, since it's text in format 3. The old `\\` and `\n` made `C:\temp` read as 2 backslashes. Each character `fmt` escapes shows the way `fmt` writes it in quotes, either by its first name, as `◉NEWLINE◉` or `◉BEL◉`, or as a code point, as `◉U+200B◉` for a zero-width space. A `"` is itself, and a real `◉` is `◉ (U+25C9)` so it can't pass for an escape. The helper takes the writer's own quoted text apart rather than keep a second list, so a message can't drift from `fmt`. A path in a schema message or a setter's note shows the same way, with a `◉` left as written, since there it's the path's own escape. Past 200 characters the middle is cut, as in `"tAj7...xYz" (4000 chars)`, which keeps the first and last 100, cut on characters. A 5 MB value used to be one 5 MB stderr line. One helper per binding does it, `one_line` in the library and `quoted` in each CLI, so the 4 stay byte-identical. The CLI's `get` shows the text the typed read parsed, without quotes.

**A list in a diagnostic shows its first 3 values and counts the rest**, as in `'x: [a, b, c, ...]'? (and 9 more)`. The `H001` hint for a field repeated on 400,000 lines used to be one 3.4 MB stderr line, printed on every run. One helper per binding does the cut, so the 4 stay byte-identical.

**A broken schema is reported against the schema.** Codes `V090+` are for schema faults, such as an unknown constraint key or an unusable type name, and their line numbers refer to the schema file.

- Originally any fault suppressed data validation entirely. After consumer feedback, a fault no longer masks real violations. The schema builder already drops a broken key or field on its own, so the remaining constraints check the document too now, with the faults listed first.

- The unknown-field sweep needs the complete declared vocabulary of names, but a key-level fault keeps its entry's path. So after a second round of the same feedback, the sweep was made to run through key-level faults. It skips only when a fault lost a path spelling outright, either an unreadable `field:` path or a mount that doesn't name any declared fragment, since those 2 kinds would make declared fields read as unknown.

- Generation keeps the all-or-nothing rule, because a partial starter file would be worse than an error.

- A schema that doesn't load isn't a schema fault. A load error loses its line, and the constraints on it go without any `V09x` to say so, so validating against what's left blames the document for the schema. Every entry point reports it with a lone `V099` and checks nothing, which means `validate`, the one-shot, `check --schema`, `generate`, and `init`. `validate` passed it in all 4 bindings until 2026100717500004, while the other 2 refused it. A `V` code on the schema document isn't a load error, since a document that came through the one-shot has some and C's `generate` records its faults there.

**CLI surface: `shcl check --schema SCHEMA FILE`**, rather than a new subcommand. Loading and validating ask the same question, "is this file good?", and `check` already defines the output and exit codes, so folding it in avoids a second, nearly identical command.

Both points that were left open are settled:

- `Validate` is in each binding's single drop-in file. The one-file promise the README leads with outranks keeping the core lean, and a schema user who had to copy 2 files would quietly break the pitch.

- There are no string or array length bounds. They would reopen the byte-versus-code-point metric already settled for merge keys, for a modest benefit, and an `allowed` enum or the consuming program can meet the need.

**Fragments close the recursion gap with one construct: `fragment:` declares, `inherits:` mounts.** The data language nests freely, but a flat path list can't describe a tree whose nodes contain their own kind. Consumers were generating schema entries to a fixed depth, past which correct keys reported as unknown, so validation returned false errors on valid files in the tool CI gates on.

- Every mature schema language grew a named-type reference for this reason. Declining it would mean telling tree-shaped configs to flatten into instances with parent pointers, which makes the file work for the schema tool instead of the reader.

- Naming: `use` was rejected as overloaded English, since it can be a verb directive or mean "purpose". `parent` collides with the parent and child vocabulary of a nesting language. `inherits` reads as a single plain word beside `type`/`required`/`allowed`, and it's accurate, because the mount inherits the fragment's fields and can add its own.

- Expansion stays demand-driven, so a mount is followed only where the document has nodes. That means recursion has no depth limit, doesn't need cycle detection, and costs time and memory in proportion to the document. The generator is the one place expansion could run away, and it cuts exactly where a fragment would re-enter itself. There were 2 places that had to be taught not to walk the same mount twice. One is the mount evaluation, where 2 constraint paths that match one node both mount the same fragment. The other is the unknown-field sweep's chain matcher, where a fragment mounted by 2 paths offers 2 ways to consume the same chain. Each remembers the (fragment, depth) states it has finished, so a chain that ends unknown costs the schema's size per level rather than doubling per level.

- Suggestions don't descend mounts, for the same reason as below stars.

**Open sections use a name-position wildcard, and it's part of the lookup grammar as well as the schema.** A section used as a map ("any child name under `indicators`, each shaped like this") had no schema spelling at all, since wildcards selected instances and never names.

- Of the candidates, which were a `*` name segment, an `open:` constraint key, and glob patterns, the bare `*` segment won. It reads like `[*]` one level up, doesn't need a new vocabulary word, and composes with deeper paths (`indicators.*.period`) without a second construct.

- It also belongs in reads, so the query language stays one language. `Get("*.port")` slots across children of any name the way `[*]` slots across instances. The Writer refuses it like any wildcard, since paths must name their target to be writable. A field literally named `*` can still be addressed quoted (`"*"`), which is never a wildcard.

- Suggestions ("did you mean") don't go below a `*`, since there isn't any fixed sibling list to suggest from, and a `repeat` on a `*` leaf doesn't disavow any `H001`.

- A wildcard after a wildcard flattens. `server(*).*` used to report every slot `Multiple`, because the per-instance sub-resolution collapsed anything that wasn't exactly one node, and a nested slot list is never one node. So `Remove` on such a path didn't remove anything, and a read of it couldn't return a value. The options were to call a nested list of one that slot and a nested list of none `NotFound`, or to splice the inner slots into the outer run, and splicing was picked. It's what "the two compose" already promised, it keeps `count`, `instances`, and the read in agreement, and it gives one slot per resolved leaf, which is what a caller who writes `server(*).*` is asking for. A repeated leaf under one instance stays `Multiple`, since that's the same ambiguity a path without a wildcard has.

- `Remove` and `Exists` take every node behind such a slot instead of skipping it. Both act on the whole match rather than reading one value per instance, so a read's ambiguity doesn't apply to them. Skipping left the data in place and still exited 0, which is wrong under either reading of the spec sentence. The switch is one flag on the resolve walk, off for the reads.

**Value identity resolves escapes.** There were 2 spellings of one string, `a: "q\"uote"` and `a: 'q"uote'`, that used to be 2 instances, while `a["q\"uote"]` matched both. So one selector addressed 2 nodes, and neither `count` nor a read could return a value. The options were to resolve escapes in the identity key, or to say in the spec that a selector may address several spellings, and resolving won. The selector already matches on the resolved text, names have resolved escapes since 2.0, and quoting was never part of identity anyway, since `a: x` and `a: "x"` have always been one instance. The common element has no escape and the key is the text itself, so the parse doesn't pay anything for it. Format 3 writes the escape as `◉DOUBLE_QUOTE◉`, and the rule is unchanged.

**A quoted by-value selector is scalar-only.** By-value matching is against the display form, and an inline array's display joins elements with `, `. So the scalar `"a, b"` and the list `a, b` met the same selector, and a read could only return Multiple.

- Superseded with format 3. Every selector, quoted or bare, matches one plain value and never an array, so the display-form match below is gone. The reasons are in [the value syntax design](design_docs/20261002-132445_value-syntax.md), under Selectors and discriminators.

- The candidates were a scalar-only quoted spelling, an IndexOf companion, and leaving it documented, and the quoted spelling won. Quoting already forces a value match over an index, and it already escapes sentinels and formats elsewhere this round, so "quoted selects the scalar spelling only" extends one rule instead of adding a second construct.

- Bare selectors keep the whole-display match, so existing paths behave the same. The parser's accelerator keeps the first child with the same display, with a rare fallback scan when a quoted selector needs the scalar sibling instead.

**Hand-edited configs are structurally safe across a round trip: retain what can be retained, and gate the save on the rest.** A malformed line used to be diagnosed and dropped, so a stray typo plus one settings change meant a hand-written line silently vanished.

- The full fix splits lines by what's provably safe. A line with malformed content, which can't be read at any position, is retained as inert trivia and re-emitted in place. It re-diagnoses the same way and can never read as a live binding. A line the parser could read but not apply, such as one with a bad indent, an unusable selector, or past the depth cap, can't be made inert. Re-emitted, it might parse as live content and invent data, which happens for lines that start with a BOM.
	- Later the emitter was changed to check the reload before it writes a kept line, and to write the line as a comment where it would bind, so most lines refused only for where they sit are retained now. The one test for dropping is under Load outcomes.

- A skipped line keeps its indent level, so the lines written under it are skipped with it rather than re-parented one level up. That applies to a list item whose item was dropped as much as to a malformed one. In 2.x's `*` spelling, `* small` under a parent with field children and `*small` are 2 spellings of one mistake. One rule handles both, rather than different results where one re-parented its block and the other lost it.

- Those lines count into `LostCount` instead, and the file tier's save refuses while it's nonzero, with an explicit lossy variant as the override. So deleting a user's line is always a stated choice. Retaining everything verbatim was considered and rejected because of the risk of invented content.

- The CLI's in-place write goes through the same gate. It was first left alone because a person sees the diagnostics on stderr, but that turned out to be false. At the default strictness the load recovers and prints nothing, so `--write` deleted the line at exit 0 in silence. It now prints the load's diagnostics and refuses while `LostCount` is nonzero, with `--lossy` as the stated override.

- The CLIs call `SaveFile` rather than having their own copy of the rule, so the command line and a consumer program can't disagree about which rewrites are safe.

- The refusal is a value rather than prose. Every binding reports it so it can be told apart from a failed write, because only one of the 2 is the caller's to reverse. Python raises rather than returning a message, since a message a caller may ignore turns the safest spelling of the call into a silent no-op that reports success.

**The library has an optional file tier, since file handling is where consumer bugs are.** Consumer feedback showed that every program that saves a config was reimplementing the same load and save steps and making the same mistakes on its own. They confused absent with unreadable, got buffer lengths wrong, and tore a config with a plain overwrite.

- A small companion tier was the result. The load never fails, and it returns one of 4 statuses (clean / had-errors / not-found / unreadable) beside a document that can always be used. The save writes canonical text through the same atomic temp-and-rename the CLI's `--write` already used, which was moved into the library so the CLIs call it and the 2 can't drift.
	- That's true below Strict. Since 3.0 a Strict file load fails the way a Strict parse does, with the document inside the error, so a program that moves between entry points keeps the failure. The one-shot load-and-validate does the same.

- It stays a companion rather than part of the core, and C guards it behind `SHCL_NO_FILE_IO` so embedded consumers can still build without file I/O.

**H002 reports every merged level, and a schema can disavow it per section with `reopen:`.** The first cut hinted only the outermost re-open. Inner merges looked adjacent at their own scope, because the newest-child test can't see that the whole region came from re-opening. That made filtering on the consumer side unsound, since allowing one section's hint silently waved through everything nested under it.

- Merges under a hinted container hint too now, and each names its own earlier line. The parser passes the re-open line down, so text that the re-opened region itself wrote stays silent.

- The disavowal is its own `reopen:` key rather than an overload of `repeat`, because "many instances" and "one section written in parts" are different declarations.

- Suppression works the same way as the H001 one, with a single wording site and a leaf-name match, and it's dropped where diagnostics and a schema meet.

**`* key: value` was a string with a hint (`H003`) rather than an error.** It was superseded with format 3. `- key: value` is `E027`, kept as written, and `H003` is retired. A colon before whitespace in a bare piece is an error everywhere now, so the hint had nothing left to point at. What follows is the 2.x record. `* key: value` is how YAML writes a list of objects, and it loaded silently as the string `key: value`, while the spec said an element didn't have a colon.

- An error would refuse a value the bare-value rule takes everywhere else. `a: b: c` binds `b: c`, and `* note: text` means the same text.

- A hint doesn't change any load, read, or exit code, so no existing file breaks. It fires only on a bare element whose text up to its first colon doesn't have a blank, with a blank or the end after the colon. `* 14:30`, `* http://x`, and `* note to self: x` stay quiet.

- The fix it points at is to quote the element, which `fmt` already does, since a colon is reserved in canonical output.

**A config file names its own schema on a `##    Schema   REF` comment line** (2026-09-26). It's modeled on JSON's `$schema` and the YAML language server's schema comment, so an editor can find the schema with nothing else to go on.

- It's written like the `Format` line so it reads as part of the same family, and a comment doesn't change anything about the document.

- `check` reads a path from the config file's directory, the way an editor does, and a `--schema` on the command line wins.

- The line counts at any indent (2026-09-28). The formatter indents a comment to the field below it, and a match at column 0 only meant `fmt` could turn a file's check off.

- `check` reads only a regular file there, and on Windows it refuses a path that starts with 2 separators or `\??\` (2026-09-28). The file may come from someone else, and a device, a FIFO, or a network share would make an unattended check run out of memory, hang, or connect to another host.
	- The read stops past 16 MiB (2026-10-01). A regular file can still read without end. Linux's `/proc/self/pagemap` has size 0 and reads as hundreds of GiB. A real schema is far smaller.

- A URL is left to editors. A check that goes to the network because of a line in a file isn't one to run unattended, so `check` says it skipped it and doesn't validate anything.

- `set_banner` keeps the line when it's inside the info block, since the author wrote it there and the block is rewritten whole.
	- The same goes for any line in the block that the block doesn't write, such as an `Owner` line (2026110613470302). The block's own lines are its 2 text lines, the lone `##` lines, and the lines named Format, Home, Syntax, and Legal. A block at the end that already reads as the current one stays as it is, so `banner on` on a current file doesn't change anything, and the line stays in the block.

**Durations and sizes are read-time types, like dates** (2026-09-26). `timeout: 30s` and `cache: 512MB` read as whole milliseconds and whole bytes, so a program never parses a unit itself.

- A bare number takes its unit from the field name (`timeout-ms`, `cache_mb`), or else from the program. The parser does the work, and a name that already says the unit is enough.

- Only a `-` or `_` marks where the unit starts. A camelCase boundary was tried and dropped. Names fold to lower case, so `fmt` turned `ttlHours: 1.5` into `ttlhours: 1.5`, and the same line read 1.5 hours before and 1.5 seconds after.

- `KB` to `TB` are powers of 1024 unless the program asks for 1000. Guessing the base from words such as `disk` or `network` in the name was turned down. `cache-size` or `chunk` fit either, and 2 programs would read one line 2 ways without any error.

- A value with its own unit wins over the name, with the hint `H005` when they differ. A read can't include a diagnostic, and validation reports only errors, so the hint comes from the load.

- A schema `min` or `max` is read the same way as the value it bounds (2026-09-29). Its own unit comes first, then the field name's, then the schema's `unit`, which stands in for the program's. Taking the schema's `unit` before the name was turned down, since `wait-seconds` with `unit: ms` would then read `min: 2` as 2 ms and the value `wait-seconds: 1` as 1 s. The name is the last segment of the field's path, so a path ending in `*` gives none.

- A fraction has to come out whole, and at most 18 digits after the point count, so the arithmetic is exact in 64 bits in every binding without a wider type.

### Formatter

The formatter is a structure-only canonicalizer. It writes block form, tabs, insertion order, and minimal quoting, and collapses redundancy, but it leaves value text untouched, since it can't know types.

**Author quoting survives canonical output, on data-format values too, and the writer quotes any colon, comma, or paren.** The decision is now in [the value syntax design](design_docs/20261002-132445_value-syntax.md), under Canonical output.

**A raw block's nesting is the closing fence's own indent, and the rule is symmetric.** The nesting used to be the common indent of the body's non-blank lines. That made a shared body indent impossible to write, and it needed an emit exception for a body without any non-blank line, which was the case that once grew by a level per pass.

- The fence defines the nesting rather than the body. Each body line loses only what it shares with the closing fence's indent, or the opening line's when the block never closes, and emit pads every non-empty body line by that same indent.

- Strip and pad mirror each other exactly, so there isn't any special case left. A body's shared extra indent survives as content, and a body of only whitespace keeps its spacing for the same reason as any other line. A raw block promises verbatim content, so it shouldn't be the place that quietly rewrites it.

**`SetRaw` refuses an info-string an emitted fence line can't contain.** That's a line break or a `#`. The fence line would read the `#` as opening a comment, so the block would come back with a different info-string than the one written. The info-string is also trimmed the way a fence line reads it back, and the op script's `raw` op shares the gate.

**A raw block in a higher layer fills an empty binding of the same name below.** Merge matched instances by `(name, value)` only, so a bare `blk:` in the base and a `blk:` with a block in the overlay both survived a merge, while parsing the 2 run together folds them.

- So merged output wasn't a formatter fixpoint, and that brought in a second defect, since the emitter's workaround for the resulting pair writes the fence on the name's line and loses an info string with a `#`.

- Merge uses the parser's own empty-fill rule now, so a merge and a parse of the 2 files joined together agree. The fill is limited to raw blocks because that's the limit of the parser's rule, and a valued instance still appends.

**A run of whole-line comments keeps its written order and its nesting.** A comment written deeper than the next binding is attached to the block it's in, and the rest of the run goes to the next binding. Each comment chose its block alone, so one could end up ahead of the comments written before it. A commented-out header followed by its commented-out child came back child first, and once both were uncommented the child was under the wrong field.

- A comment never goes ahead of the one before it. Once one stays for the next binding, every later one stays too, and one whose block is written out before the last one's goes there with it. Order is the one thing a reader of a commented-out block can't fix by eye.

- A comment kept away from its own block keeps its depth under the comment or kept field line before it, one tab per level. A comment no deeper than the place it ends up is written at that place's level, as before, which also keeps a run's first comment there, so a reload files the run the same way.

- A malformed line kept verbatim keeps the place's level. It stays at its level on a reload, so if it were written deeper it would move the lines after it. The exception is a line under a field line refused for its value alone, which a reload keeps open. It goes one level under that line, so it reads at the same path once its value is fixed.

- A reload puts a comment at most one level past the comment or kept field line before it. A merge that drops a layer's repeated footer line can drop the one the next line sat under, so that line comes no deeper than one level past what it now follows.

- A block's inside comments are written out after its last child's block, at that child's level, and a reload files them on that child. The load files them there too, once the tree is final, since a merge treats the 2 differently. It has to wait for the end, because a block reopened later gains children, and if the comment were filed on the child it had at the time, it would end up ahead of them.

- A block reopened later in the file gains children after the one that was last. That child's comments at its own level are then right above a sibling, and a reload files them on the sibling, so the load moves them there too, once the tree is final.

- Tail comments are filed before the end-of-load fold of late duplicates rather than after it. The fold moves a dropped instance's comments over to the one it joins, and when filing came after it, they were filed on the dropped one and lost.

- A merge, a new child, and the writer's fold change child lists after the load, so each one files comments by the same rules where it changed a list. Otherwise the next step put a comment in one place on the document and in another on its saved text, and where the comment went depended on whether a file was saved between 2 edits. The same goes for the blank the emitter drops on the first line, and for a raw block's trailing comment, which goes on its own line above when an empty binding of its name comes first.

**A float is written with the fewest digits that read back, and an exact tie between 2 such spellings rounds to even.** Shortest-round-trip formatters agree on every double except in 2 cases, and both had leaked into the output. At a power of 2 the rounding interval is lopsided, so the closest short spelling can fall outside it while its neighbor reads back. On an exact tie between 2 spellings of the shortest length, Rust's formatter rounds away from zero, but Go's, Python's, and glibc's round to even.

- Round to even was picked. It's IEEE 754's own tie rule, what 3 of the 4 bindings already did, and what `repr` in Python and `strconv` in Go print, so a value read from another tool's output is written the same here. The reference takes the correctly rounded spelling of the shortest length whenever it reads back, and keeps its own shortest spelling only when it doesn't.

- C tries the last-digit neighbors before adding a digit, which is what the shortest-digits algorithms find at a power of 2. Every power of 2 and a fixed set of random doubles go through a float write in every binding in the cross-binding check, so a formatter that drifts on either case is caught there.

### Saving a file

- **A save publishes a new file in the old one's place.** Write a temp file beside the target, then move it over. That's why an interrupted save can't truncate a config, and it's also the source of every limitation below. The bytes are new, so anything the old file had outside its contents has to be copied across on purpose, or it's gone.

- **The temp file borrows at most the first 64 bytes of the target's name, cut where a character starts.** It used to include the whole name plus the process id, which put it over the 255-byte limit for a target name in the low 240s. The exact cut-off also moved with the width of the pid, so the same file saved on one machine and failed on another. A stem of fixed width removes that band. The cap counted characters at first, and a name of 4-byte characters pushed the temp past the limit again. A pair of long names that share a 64-byte prefix can want the same temp, and the exclusive create and the 8 attempts already deal with that.

- **What's kept, and what isn't.** The permission bits are copied on purpose, and the group is kept with them on a best-effort basis, since a `me:www-data 0640` config that comes back with the saver's group loses the service its read. The owner isn't kept. A save that isn't root can't set it, so it doesn't try. On POSIX that's all that gets copied. ACLs, extended attributes, the SELinux label, and any other xattr are lost, as are other hard links to the old file.
	- None of that can be fixed at this layer, since a rename can't preserve what a rename replaces, so it's documented in the spec rather than papered over.
	- A relabeled config on an SELinux host is the case to know about. The new file takes the label its parent directory and the writing process imply, which is the same label in the ordinary case but not after a `chcon`.

- **Windows goes through `ReplaceFile` instead**, because it doesn't have the same constraint. `ReplaceFile` exists for this publish step, and it copies the destination's ACLs, security attributes, and named streams onto the replacement, which is the gap a plain move leaves. Its documented preserve list stops short of the basic attributes, so hidden and system are applied again by hand after the publish, the way read-only already was. Without that, a hidden config came back visible. It needs a destination to replace, and it fails outright rather than skip a merge it can't perform, so a create and any failure fall back to the replacing move. That was the behavior before, so it's never worse.
	- `ReplaceFile` is given a backup name. It works in 2 moves, the old file out and the new one in, and without a backup name a failure between them is documented to delete the old file (1176) or leave it under a name nobody is told (1177). With one, 1177 leaves the old file at the backup and nothing at the path. The save moves it back, and if that fails too it keeps both files and names them in the error.
	- The backup is the temp name with `.tmp` swapped for `.bak`, so it's beside the temp and has the same length limit. It's removed after a good publish.
	- A publish that's refused is tried again, 5 tries 50 ms apart. A scanner or an indexer that opens the fresh temp file blocks both the replace and the move for a moment, and with one try that was a failed save. A permanent refusal costs a fifth of a second before the error.
	- The fix doesn't depend on a given Windows build. It follows the documented behavior, which is what any build is allowed to do.
	- The temp file is created with the target's DACL rather than the directory's. A plain create inherited the directory's ACEs, so the new text of a private config was under a wider ACL until the replace, and a fallback move published that wider ACL. The create drops the auto-inherited mark, so the DACL is set again with the mark requested when the target's had it.

- **The C file tier goes through the wide API on Windows, and splits a path on either slash.** Both came out of the first consumer to embed the C header on Windows. The narrow file calls read a path in the process's active code page, so a path with a character outside it either failed to open or, worse, was written under a mojibake name that the same narrow read found again. Every call is the wide one now, and a path that isn't valid UTF-8 is refused rather than folded to a different name. The temp name was derived from the last `/`, and a path built with the platform separator doesn't have one, so every save through such a path failed. A drive-relative `C:x` splits after the colon, where the reference's `Path::parent` splits it. The runtimes of the other 3 bindings already did all of this.

- **The Go binding gets the Windows publish through a hook rather than a build-tagged pair.** Go has no way to name a symbol that exists only on Windows from a file that also compiles elsewhere, and `shcl.go` promises to work when it's copied into a tree on its own.
	- So the publish step is a package-level variable set to the plain rename, and a small file built only for Windows swaps in the `ReplaceFile` version. Copying the one file still works everywhere, and taking the whole module gets the better Windows publish.
	- The lint stage only ever sees the host's `GOOS`, so the Windows file is compiled and vetted in the cross stage instead. That's the only thing that looks at it at all.

- **The directory is synced after the move, as well as the file before it.** The file's own `fsync` only promises that the contents are on the disk. The move is a change to the directory, and without a sync there, a power cut can lose the publish and leave the old content. It's best effort in every binding, since a filesystem that refuses an `fsync` on a directory isn't a reason to fail a save that already succeeded. It's POSIX-only, since Windows doesn't have an equivalent. `ReplaceFile` is asked to write through, but Microsoft documents that flag as unsupported there, so on Windows the durability that's promised is the file's own flush before the publish.

- **A file the save had to create takes the mode an ordinary create would**, `0666` narrowed by the umask, rather than a private `0600`. A library shouldn't quietly make a decision the user can't see. A config that must be private needs that from the umask or a `chmod`, which are the tools a person already uses. An existing file still keeps its own mode, and that case is why the temp file is born private, so the copy is never briefly readable to anyone the original wasn't. A caller who wants a new file at an exact mode, such as `0600` for one with tokens in it, says so with the `mode` save option, which the umask doesn't narrow. The temp file is born private for that too. Windows has no such bits, so it's ignored there.

- **A save can keep the lines no edit touched.** There were 3 options. One was a second save that keeps the file's own text, as kdl-rs keeps a document's formatting and has an `autoformat` beside it. Another was working out the smallest text edit for each change and splicing it in, which is how VS Code's jsonc-parser edits `settings.json`. The third was canonical output only. The first 2 were taken together, as a separate save the program asks for, built by splicing (the user, 2026-09-25). The plain save and `fmt` stay canonical.
	- It lines up the 2 canonical texts rather than the writes. The emitter tags each line with the source line it came from, and the loaded text is parsed again and emitted the same way. The lines that one source line produced, and whatever the canonical form writes between them, are one group. A group of the edited text that matches the loaded one exactly takes the source's own lines. A dotted line with a comment above it is such a group, since the canonical form writes the comment inside the block the line makes. A run whose only change is its last value gets the new value written into its source line. Anything else is written as canonical text, indented the way the lines around it are, with the source's name spelling on a rewritten binding line. No setter, `remove`, or comment call had to learn about it, in any binding.
	- The result has to reload as the edited document, without losing any line the file didn't already lose and without any error it didn't already have. When it doesn't, the save writes the canonical form and says so (the user, 2026-09-25). That check is what lets the line-up be simple, because it only affects how much of the file stays as it was, never what the file says.
	- A load keeps the text only when asked. A merge drops it, since the layer's lines aren't that text's.
	- `set` saves this way from 3.0, when printing and with `--write` (JC, 2026-09-25). A file `set --write` creates doesn't have any text to keep, so it's canonical, with the info block.
	- These fall back today: a child added under a flat dotted line, and a value changed where a selector elsewhere names it. So does any edit to a file whose canonical order isn't its own, as with blocks folded together from separate places or a selector that puts a child under an earlier block. Keeping some of those lines would move the rest. A line that no binding stands for, such as a repeated header or field the load folded, or a line the load dropped, stays where it was after the line above it. A new line goes above it when it is indented past it, since a line written under a dropped line is dropped too, and below it otherwise. When the line above it goes or is rewritten, the save falls back.
	- A line the load dropped (`LostCount`) comes back as written this way, so the save gate refuses a save that keeps lines only when it falls back to the canonical form (SilkTerm and gitsby, 2026-09-25). Nothing is deleted, and the reload shows the same line dropped again.

- **A save that found nothing at the path publishes without replacing.** `set --write` works out that it's creating a file before it waits on stdin, and a file made during that wait used to be replaced by the info block and the edits, at exit 0. The CLI looks again right before the save, and the save publishes through a hard link, which fails on anything at the target, and then drops the temp name. A filesystem without hard links gets a check and a rename, so a short gap is left there. Windows moves without the replace flag, which refuses the same way. No new call was added. Which publish to use follows from what the save found, so a consumer doesn't have anything to choose. A consumer that wants only a new file sets the `create` save option, and this publish is what makes 2 saves at once come out as one file and one refusal.

- **`set --write` creates a FILE that isn't there yet.** `--write` names the file the command produces, so reporting it missing was an obstacle rather than a safeguard. The workaround was to `touch` it first, which is the same act with an extra step. `fmt --write` doesn't, since it has nothing to format. A file that exists but can't be read stays an error in both, since the alternative is writing over something unread.

- **Bracket text after the colon is retained and never read.** A `[` first after the colon has one meaning, which is the JSON habit. The line is kept verbatim like any other malformed line. It doesn't bind anything or count anything lost, the way a pasted YAML `- item` line already didn't. It's an error rather than a hint, because the value isn't there to read.
	- Superseded with format 3, where brackets are the array spelling. Only a malformed array is `E019`, still kept verbatim, and its name is fine, so the lines under it load. Load outcomes has the details.

- **A refused in-place write exits 7, its own code.** It used to share 1 with usage and I/O errors, so a script couldn't tell "pass `--lossy` or fix the file" apart from "the command line is wrong". The refusal is the one failure whose remedy is a decision rather than a correction.

- **`set` and `migrate` without `--write` exit 7 where the write would refuse.** `shcl set f ... > f.new && mv f.new f` is a common way to edit a file, and the print used to skip the gate, so it dropped the line `--write` refused to drop, at exit 0. `set` doesn't print anything when it refuses, since its output is the result that loses the line. `migrate` still prints, because its text keeps every line and only loading it drops one. `--lossy` works on both without `--write`. `fmt` to stdout stays canonical without a gate, since that's what it's for, and `fmt --check` asks the gate.

- **A file or stream that can't be read or written exits 8, and 1 is now the usage code alone.** It's the same reasoning as exit 7, applied to what was left in the catch-all. The 2 remedies have nothing in common. One is fixing the command line, and the other is fixing a path, a permission, or a disk. A path a write option refuses, such as a wildcard or an index that doesn't name any instance, stays at 1, because what has to change there is the option's value.

- **Every subcommand that loads a document prints the load's diagnostics to stderr, once per run.** Whether a typo the load recovered from is mentioned shouldn't depend on where the canonical text goes or on which subcommand asked for the load. This started as `fmt` and `set` in both modes, with the read subcommands left quiet. That half was reversed, because a read below strict returns the value and says nothing at all, which is the case where silence costs most. stdout has the same bytes either way.

- **The mode is applied to the temp file again after its data is written.** The kernel clears setuid and setgid on a write by a process without the right capability, so giving the temp file the target's mode before filling it silently dropped those bits. The copied mode has to be set last, after write and fsync, before the publish.

- **The write target is resolved on Windows too.** Rust and Go get it from their standard libraries. The C binding used the path as given, so a save through a linked-in config replaced the link with a regular file, which is the one thing resolving the target exists to prevent. It now asks Windows for the final path, which follows a symlink or junction and comes back with the long-path prefix. The prefix stays only when the name plus the temp file's suffix would otherwise be too long, so an ordinary save writes the plain name it always did, and a path past the old limit works at all.

- **A symlink cycle at the write target is an error.** Resolving the target is what makes a linked-in config written through rather than replaced, and a cycle used to come out of the resolver as "no target", which quietly replaced the link with a regular file. A loop is reported as too many levels of symbolic links, and nothing is written.

### Save outcomes

This is what a save does with each thing it can find at the path. The library's save in every binding and the CLI's `--write` do the same thing, and the CLI reports every refusal at exit 8. The table is the rule. The usual defect here is a case handled at one site but not at its sibling, so a new case gets a row before it gets code.

| At the path, after links are followed                                   | A save
| :---                                                                    | :---
| A regular file                                                          | Replaces it. The mode and the group come over. What doesn't is under Saving a file.
| Nothing, in a directory that exists                                     | Creates it, at `0666` narrowed by the umask, or at the mode option's bits exactly. Anything that turns up before the publish is left alone and the save fails.
| A link to a regular file                                                | Replaces the file the link points to. The link stays.
| A dangling link                                                         | Creates the file where the link points. The link stays. The walk joins each link's text to the link's directory as written, never cleaned, since the kernel follows `lnk` in `lnk/..` before it goes up.
| A link whose text ends in a separator, `.` or `..`                      | Refused: is a directory. That text can only reach a directory, and the kernel refuses to create a file through it.
| A link cycle                                                            | Refused: too many levels of symbolic links.
| A path ending in a separator, `.` or `..`                               | Refused: is a directory.
| A directory                                                             | Refused: is a directory.
| A FIFO, a socket, a device, or anything else that isn't a regular file  | Refused: not a regular file. A rename would swap it for a regular file. The CLI asks before it reads FILE, since reading a FIFO takes what was written to it.
| A regular file whose bytes changed since it was read or loaded          | Refused under `--write`: changed since it was read. The CLI reads FILE again right before the save. The library's save refuses too, with `Changed` and nothing written, when the bytes at the path as given are neither what the load read nor what that document's last save wrote. The force option overrides it. A file made where the load found nothing is a change, and so is a file the document never read, a save-as over it included, and one the check can't read. Nothing at the path is no change, so a save-as to a new name and a file gone since the load are written, as an editor writes them. No path is compared, so one file is one file however its path is spelled. A document from `parse` read no file, so it writes only where nothing is, or over what it wrote. Either way it's a check rather than a lock, so a gap the width of one save is left.
| A regular file whose canonical bytes equal what the save would write    | No write under `--write`, at exit 0. The file keeps its inode, its mtime, and its hard links. The library's save always writes, since its caller may want the publish.
| Nothing at the path, under the CLI's `--write`                          | Created as above, plus `FILE: created` on stderr, so a mistyped name isn't a silent new file at exit 0.
| Anything at the path, under the library's create option                 | Refused: `Exists`, nothing written. So is a save that loses to another one making the file at the same time, since the publish of a new file fails on anything at the path. A link to nowhere counts, though without the option the save creates the file where it points, so a planted link can't pick where a new file goes. It's checked before the changed check, and force doesn't override it.
| Anything, for a document read from a newer format                       | Refused: `TooNew`, nothing written. Its Format line names a newer format (`H006`), so the save would write its lines by these rules. It's checked first, before the lost-content gate, and no option overrides it. The CLI's `--write` refuses it at exit 7.

The library's refusals give the reason as a write status too. That's `IsDirectory` for the 3 is-a-directory rows, `NotRegular` for the FIFO row, and `Other` for a link cycle. A path ending in a separator, `.`, or `..` is handled before the create and changed checks, which would read it as a file there or as a change. The CLI's `--write` gives the same words for a folder swapped in during its wait as for one that was there from the start.

### Load outcomes

Every load-time code has one outcome, and the parser derives the lost count and the held indent level from that outcome alone. Each diagnosing arm names its code and its outcome and does nothing else, and one function records the diagnostic, counts, and holds the level. Before this, every arm counted and pushed by hand, and an arm that skipped one or the other was a repeat defect. A line has one of 5 outcomes:

- **Bound**. The line binds as written. The diagnostic describes something about it, and nothing is counted or held.

- **Retained**. The line's content is malformed at any position, so it's kept verbatim as trivia and written back in place, where it re-diagnoses the same way and can never read as a binding. It doesn't count anything. It holds its indent level, so what's written deeper is `E018`.
	- The exception is a field line refused for its value alone, which means `E017`, `E019`, `E023`, and `E025` in a value, `E026`, and `E028`. An `E014` for a bare name that still reads, such as `404: x`, works the same way, under the name it reads as. Its path is fine, so its level stays open, and the first line under it that binds opens the path the way `name:` with nothing after the colon would, then binds there. A line under it that's refused itself doesn't open anything, so a field without any line under it that binds still isn't there. A read on it is `NotFound` then, and `Empty` once a line under it binds. One typo in a value used to take its whole block with it, which gave a silent wrong answer for every key under it (SilkTerm, 2026-10-01). A path with an index or wildcard selector, or one past the nesting cap, could fail to place, so it still holds a dead level.
	- A retained line whose value opens a raw block keeps the body and its closing fence with it, as one kept line. When they were read as lines, the body bound as fields at exit 0, and its closing fence opened a block that took the rest of the file (review 20261003 item 2; 20260918b had declined it as a file that fails `check` anyway). Throwing the line and body out instead would refuse every later save over one typo in a name. The closing fence's indent comes off each body line, as in a field's block, and canonical output writes the body one level under the line, so the block moves with it. A block that never closed gets its closing fence, or whatever is written after it would read as its body.
	- Canonical output writes the kept line in place of the opened field's bare `name:` line when it's the field's last leading line and names only that field, since a reload opens the field from it the same way. A field the edits left with nothing under it keeps its own `name:` line too, since nothing would open it. The emitter's model of the reload's stack holds such a line's level open the same way, so a kept misplaced line under it is judged the way the parser will judge it.

- **Dropped**. The line was read but doesn't apply where it is, and by the test below, if it were written back it could bind with nothing to stand for it, so it's gone. It counts one lost. It holds its indent level the same way.

- **Kept as written**. The line is refused for where it is, with an indent that has a space in it. No level that canonical output opens is written with a space, so the line is written back exactly as it was, indent included, and a reload refuses it the same way. It doesn't count anything. It holds its indent level the way a dropped line does.

- **Value dropped**. The line binds, but a value on the line had nowhere to go. It counts one lost, and the level is the bound node's.

A line is dropped only when, written back, it could feed a raw block or bind where no comment stands for it, as a misplaced line indented with only tabs (`E012`) or one that starts with a BOM (`E014`) would. It's also dropped when a caller's cap or the depth cap refused it, since the next load may set those differently.

The table is the rule. If a code's behavior ever disagrees with its row, the code is wrong.

| Code   | Severity      | Outcome
| :---   | :---          | :---
| `E001` | error         | retained, unless the line opens a raw block, then dropped with it; a line refused for its content keeps its own code
| `E002` | error         | value dropped
| `E003` | error         | retained, unless the line opens a raw block, then dropped with it; judged before its path opens anything; the emitter writes it as a comment where the index would find an instance
| `E004` | error         | retained, with any raw block it opens; judged with the path, so it opens none of the path's fields
| `E005` | error         | bound
| `E006` | error         | dropped
| `E007` | error         | retained; the emitter writes it as a comment where it would bind
| `E008` | error         | retained
| `E009` | error         | retained; stays among the items
| `E010` | error         | retired: a bare comma in a `- ` item is `E026`
| `E011` | error         | retained; the emitter writes it as a comment where it would bind
| `E012` | error         | kept as written when the indent holds a space and the line opens no raw block; dropped otherwise
| `E013` | error         | retained
| `E014` | error         | retained, with any raw block it opens; a bare name that still reads holds its level open; dropped when the line begins with a BOM, which the file-start strip would rewrite into something that can bind
| `E015` | error         | bound
| `E016` | error         | dropped
| `E017` | error         | retained; a value fault holds its level open
| `E018` | error         | kept as written under a kept `E012` line when it opens no raw block; dropped otherwise
| `E019` | error         | retained; on a field line it holds its level open, and a `- ` item stays among the items
| `E020` | error         | the parse stopped: every later non-blank line is dropped, and no level is held
| `E021` | error         | dropped, whatever its value
| `E022` | error or hint | bound (about the list, not a line)
| `E023` | error         | retained; a value fault holds its level open, and a name fault keeps any raw block it opens
| `E024` | error         | retired: a backslash is text
| `E025` | error         | retained; a value fault holds its level open
| `E026` | error         | retained; on a field line it holds its level open, and a `- ` item stays among the items
| `E027` | error         | retained; stays among the items
| `E028` | error         | retained, written in place of the field's own line; the field opens with no value and the lines under it load
| `H001` | hint          | bound
| `H002` | hint          | bound
| `H003` | hint          | retired: the case is `E025` or `E027`
| `H004` | hint          | retired: became `E024`, which is retired too
| `H008` | hint          | changes nothing: the line has the outcome it has without it

- `spec.md` has what each code means, and [the value syntax design](design_docs/20261002-132445_value-syntax.md) explains why `E013`, `E014`, `E017`, `E019`, `E023`, and `E025` to `E028` work as they do. Format 3 moved `E017` from bound to retained, since reading an open quote as bare text would break the quote rule.

- A line that qualifies for more than one refusal takes the first that applies, in this order:
	- Where it is (`E012`, `E018`).
	- Its path and its name (`E014`, and `E017`, `E023`, or `E025` in a selector or a quoted name, then a wildcard selector, `E004`).
	- The element cap (`E021`).
	- Its value (`E009`, `E017`, `E019`, `E023`, `E025` to `E027`).
	- Only then, where its path leads (`E001`, then `E003`).
	- A line gets one diagnostic. A cap refuses a line past it whatever its value, so a broken array past the cap is `E021` and dropped, while within the cap it's kept (answered 2026-10-05). An item under a field that already has a value is still `E011`. The fuzz property `a_cap_refuses_only_a_line_that_would_bind` holds the order.

- A kept list item holds its column, with its field as the level's node, the way a dropped one holds its own. Without that, no level was open at the element's column, so the list's next sibling, whether a field or another element, was `E012`, "matches no open level", 2 lines under the level that opened it. One mistake cost every later line of the list. Dropped elements were settled first, and kept ones later.

- The table changed one thing when it was written. A raw fence without a parent field (`E006`) never held its level, so a line written deeper than it bound to the root. It holds it now, like every other dropped line.

- An indent that matched no open level (`E012`) already holds an unopened level from the resolve, which refuses a sibling at the same indent the same way. The funnel leaves that one in place rather than stacking a dead level on it.

- The unopened level goes on top of the levels open before it and doesn't close any of them. Popping every level its indent didn't extend was rejected. With that, one stray line indented with spaces in a block indented with tabs dropped every later sibling in that block, which 2.0.0 read fine. It lasts until a line comes that's neither under it nor at its column, so the stack has one at most.

- The options were to drop a misplaced line, which stopped every later save of the file, to write it back as a comment, or to write it back as it was. It goes back as it was, and as a comment only where it would bind as written. A comment would hide an error the line still has, and one stray space in a hand-edited config shouldn't stop a program from saving its window size (the SilkTerm report, 2026-09-24). An indent of only tabs is always one a level can be written with, so that line is still dropped.

- Canonical output indents with tabs whatever the input used, and a save keeps a misplaced line when its indent has the other character in it. The other options were to write the file back in its own style, tabs or spaces, whichever it uses more, and to write a misplaced line indented with only tabs as a comment. Output stays tabs and a line indented with only tabs stays lost, so the save refuses (the user, 2026-09-24).
	- In its own style the kept and lost cases only trade places. The likely typo in a file indented with spaces, a miscounted run of spaces, is kept now, but in 4-space output it could line up with a level and would have to be lost. A stray tab in a space file, the case that's lost now, is the rarer typo. A tab-count mistake in a tab file misses every level only when the file itself skips one.
	- With one output, canonical form stays one form. The goldens, the comparison across bindings, and a merge of a tab file with a space file all depend on it. A space unit would also have to be guessed, and a file whose levels don't step evenly doesn't have one.
	- A comment would let the save through, but nothing would flag the line again. A refusal doesn't change anything, and it says why.
	- Corpus case `147-indent-styles` pins all 4. A stray space in a tab block and a miscounted space run in a space block are kept, and a tab line in a block that skips a level and a stray tab in a space block are lost. It's a release gate, so the rule, the case, and this entry change together.

- A kept misplaced line is never attached to a block, and a line refused for where it is never takes the comments before it. Its indent isn't one canonical output writes levels with, so the block it matches in the source isn't the one it matches on a reload, and comments it measured differently moved on the next load. It waits for the next binding line, and whatever follows it waits with it.

- The emitter asks the reload before it writes one. It runs the parser's own resolve on a model of the level stack the reload will have at that line, which is the levels up to the last binding line plus what the lines refused since then pushed. The line goes out as written only where the parser would keep it again. A retained line that reads clean, `E001`, `E003`, `E007`, `E008`, or `E011`, is refused only for where it is, so the emitter asks about it the same way. For each open binding line, the model also knows whether an item or a field line has been written under it, and whether it has a value an item can't join. For a line with an index in its path, the model walks the path over the instances written before it, through the lines held open since the last binding line, as the reload will. Kept `E028` array lines have a settle of their own. A merge or an edit can move a kept line to where it would bind, and there it's written as a comment. The document settles to that comment after every load and edit, so the next step gives the same result whether or not the file was saved in between. Whether a kept line binds depends only on the lines between it and the binding line above it. An edit that doesn't change any of those skips the settle, so a kept line far away doesn't cost an edit anything. A line with an index is the one exception, since the instances it counts can be anywhere above it, so every edit settles while the document has one.

- `migrate` refuses a rewrite that leaves a misplaced line, even a kept one. 2.x placed some such lines by a looser rule and read them, so the migration would lose a binding at exit 0.

- A field line after a list's items (`E001`) and an item after a field line (`E008`) are both retained, so no list has a field under it. Before, the first bound and the second was dropped, so swapping the 2 lines decided whether data was lost, and the bound case built a list that no text loaded back (2026100511210900). Retaining both was chosen over also binding the bracket spelling (`E028`), which would have spread the exception into the writer and the schema (JC, 2026-10-23). A field line that opens a raw block is dropped with it instead, since if it were moved where it binds it couldn't be written as a comment. An index can select a list, so a dotted line through one, such as `srv(0).tls: on`, gets what the same field gets on the line under `srv(0):`, which is `E028` on an array line and `E001` after items. Before, it put the field under the list (2026102322270349).

- A wildcard selector on a binding line (`E004`) and an empty item (`E009`) are retained. Each is wrong wherever its line is, so a reload refuses it the same way and no edit can make it bind. Before, both were dropped, so one stray `-` stopped every later save of the file (2026102820320485). A `-` alone is an empty item too, with or without a blank after it, so a kept one written back with its blank trimmed reloads as the same line rather than as an `E014` name. Writing it back as `- `, blank included, was rejected, because canonical output has no trailing blanks and an editor strips them. `E004` is judged with the path, so a wildcard line doesn't open any of its path's fields, and a raw block it opens is kept with it, as `E014`'s is.

- An item without a field above it (`E007`) and an item under a field that has a value (`E011`) are retained, as `E008` is. Each is refused only for where it is, so the emitter asks the reload before it writes one, as above. If an edit emptied such a field, the field would take the item, so the item is written as a comment there. Before, both were dropped, so one stray item stopped every later save of the file (2026102821334870).

- A line whose index doesn't select any instance written before it (`E003`) is retained, as `E001` is. It's also refused only for where it is. A merge or an edit that puts the instance above it would make it bind, so the emitter walks its path over the instances written before it, and writes it as a comment where one is found. Before, it was dropped, so one stale index stopped every later save of the file (2026102821334970). It's judged before its path opens anything, as `E004` is, so a kept line doesn't leave an empty field behind. One that opens a raw block is dropped with it, as an `E001` line is. The same walk finds a dotted line that gets to stacked items through an index (`E001`), which used to go out as a comment wherever it was.

- A malformed or misplaced line kept among a stacked list's elements stays where it was, and keeps the list in the stacked spelling. It used to go with the field line like a comment, so a fix typed into it ended up outside the list (the SilkTerm report). Comments among the elements still go with the field line. A setter that replaces the list's value moves the kept lines above it, and so does a list after an empty binding of its name, whose bare header would merge into that binding on a reload.

- A comment at a list element's column after the last element belongs inside the list's block. The element's column entry has the list as its node, which read as the list's own level, so the comment went out a level up. Nothing showed while lists were always written inline, but a stacked one moved the comment on its first reload.

### Lexical edges

Whether a character is content or trivia depends on where it is, and this table is the rule. The tokenizer, the emitter, and every setter follow it, and if any of them disagrees with a row, that code is wrong. There are 4 positions:

- Bare text, which is a name, a selector body, a value, or an array element outside quotes.

- Inside matching quotes, which is a piece that opens with a quote and closes with the same quote as its last character.

- Inside backticks, for a whole value or element only.

- A raw body, which is the lines between fences.

A comment and a fence label are plain text to the end of the line, except that a `#` ends a fence label.

The full rules for each kind of bare piece are in `spec.md`, under Whitespace, quoting, and reserved characters, and the reasons are in [the value syntax design](design_docs/20261002-132445_value-syntax.md).

| Character            | Bare text                                                                                                                                                     | Inside matching quotes                                                                                    | Inside backticks                                               | Raw body
| :---                 | :---                                                                                                                                                          | :---                                                                                                      | :---                                                           | :---
| `#`                  | opens a comment, whatever sits before it                                                                                                                      | content                                                                                                   | content                                                        | content
| space                | trimmed at a piece's edge; in the middle, content in a field value or a `- ` item and an error anywhere else                                                  | content                                                                                                   | content                                                        | content
| tab, carriage return | trimmed at a piece's edge; an error in the middle                                                                                                             | content                                                                                                   | content                                                        | content; only the trailing carriage-return run comes off each line
| `"` or `'`           | opens a quoted piece when first in it; an error anywhere else, except a `'` with text right before and after it in a value or a `- ` item, which is content   | the matching one ends the piece and has to be the last thing in it, else `E017`; the other one is content | content                                                        | content
| backtick             | opens a backtick value when first in a value or an element; an error anywhere else                                                                            | content                                                                                                   | ends the value and has to be the last thing in it, else `E017` | content
| `◉`                  | opens or closes an escape in a value, an element or a selector body, `E023` when the name isn't on the list; an error in a name                               | opens or closes an escape                                                                                 | content                                                        | content
| `\`                  | content                                                                                                                                                       | content                                                                                                   | content                                                        | content
| `:`                  | ends a name; in a value or an element, content when something other than whitespace follows, else `E025` (`E027` in a `- ` item); an error in a selector body | content                                                                                                   | content                                                        | content
| `,`                  | inside `[]` ends an element; in a value or a `- ` item, content when something other than whitespace follows, else `E026`; an error in a selector body        | content                                                                                                   | content                                                        | content
| `[` or `]`           | `[` first after the colon opens a bracket array, `E019` when malformed; `[` right after a name is the old selector spelling, `E029`; an error anywhere else   | content                                                                                                   | content                                                        | content
| `(` or `)`           | `(` right after a name opens a selector, which ends at the first `)`; an error in a selector body; content in a value or an element                           | content                                                                                                   | content                                                        | content
| line break           | ends the line                                                                                                                                                 | none; written `◉NEWLINE◉`                                                                                 | none                                                           | ends the body line

What follows from the table:

- A `#` is a comment anywhere outside quotes, backticks, and a raw body, whether or not whitespace comes before it. `color: "#ff0000"` and `url: "http://x/y#frag"` are the spellings for a value with one in it. `a(#0)` in a file is a selector cut off by a comment. The `[#N]` index went with bracket selectors, so a lookup path with a bare body that starts with `#` is refused too, as `BadPath`. An index is a bare number, `a(0)`, and a file addresses an instance by value. A fence line's info string ends where a comment starts, so ```` ```c# ```` labels the block `c`.

- A `#` against text still opens a comment, and the load gives the hint `H008` so the cut isn't silent (2026102307035776). Against text means text right before the `#` in a bare piece, which is a value, an element, a selector body, or a fence label, as in `url: http://h/#frag`, `a(x#y)`, or ```` ```c# ````. It also means an empty piece with text right after the `#`, as in `color: #fff` or `a(#0)`. A blank before the `#`, a closing quote or `]` before it, or a blank or another `#` after it in an empty piece makes a plain comment, so `port: 80  # main`, `a: # note`, and `a: ## two` don't get the hint. The scan judges it from the characters on either side of the `#` it already stopped at, so a line without a comment doesn't cost anything more.
	- One option was hinting only a `#` with text right before it, which misses `color: #fff`, the commonest case. Another was hinting any `#` with text right after it, which also hints a plain `port: 80 #main`. This rule was picked over both. A header written `server: #main` gets the hint, since it reads the same as `color: #fff` does, and `server:  # main` doesn't.
	- Nothing suppresses it. A value that wants a comment with no blank before it is rare enough to quote.

- `##` for prose and `# ` for a disabled setting are conventions. To the language both are comments, and a config author may write one with any number of `#` and any spacing.

- A carriage return is a blank outside a raw body. It's trimmed at the end of a line, a name, a selector body, a value, an element, a comment, or a fence label. In the middle of a bare value or element it's `E025`, the same as a tab, since neither can be told from a space by eye. Inside quotes, backticks, or a comment it's content. Inside a raw body the trailing run comes off each line, and a carriage return in the middle of a line is content.

- A backslash is never special, so a Windows path reads the same bare, in single quotes, or in double quotes.

- A field line that can't be read still opens a raw block when a fence follows its first colon past where reading stopped, and no `#` comes before that colon. Quotes past that point aren't read as quotes, since none there parse. A value that starts with `[` doesn't open anything.

- A `[` first after the colon opens a bracket array, as in `ports: [80, 443]`, and `x:[y]` is never a selector. A malformed one is `E019` and kept as written, and it doesn't bind anything or count anything lost. Its name is fine, so the lines under it still load.

- The writer writes what the table lets it write and refuses the rest. When a value is quoted is under Canonical output in the value syntax design. A line break, a tab in quotes, and each hidden character are written as `◉` escapes, in a name, a value, or a selector. Anything without a spelling is refused whole, which means a fence label with a `#` or a line break, a comment with a line break, or a raw body line that ends in a carriage return. Nothing on the write side trims or quotes its way around a character the table calls content.

### Write outcomes

This is the mirror of the load outcomes, on the write side. A setter builds its line text through the emitter, hands it to the tokenizer, and refuses unless what comes back is the value it was given. Nothing else on the write side decides what a quote, a `#`, a comma, or a carriage return means, so a setter added later doesn't have any rule of its own and can't disagree with the parser. Both sides read the table under Lexical edges.

- The refusals follow from the lexical rules rather than from a list. A raw block's info string may not have a line break or a `#`, because the fence line would read the `#` as opening a comment. A raw body line may not end in a carriage return, because the load takes the trailing run off every line. A comment may not have a line break, because a comment is one line, and keeping the first line would drop the rest with nothing to say so.

- What the load normalizes, the setter normalizes too, and it stores the normalized form. A comment line and a fence label are trimmed at the end the way the load trims every line. A raw body line is payload, so it's refused rather than trimmed, since stripping a carriage return from each line of a block would quietly convert a CRLF payload to LF.

- The typed setters keep their render-and-parse-back on top of the round trip. It checks something else. The round trip asks whether the same text comes back, but a float or a datetime has to come back as that type. `inf` reads back as the text `inf` and not as any float at all.

- `SetLiteral` takes syntax rather than data, so whatever a file line gives with its text is what gets stored. A trailing blank comes off. It refuses what a file reports as an error, since a setter has no diagnostic to report one with. That's a line break, and any code a value can get on a file line, such as `E017`, `E019`, `E025`, or `E026`. It also refuses a `#` outside quotes, which a file reads as a comment, since the text after it would be dropped with no status to say so. A bracket array is a value there, so `--set-literal 'x=[80, 443]'` writes 2 elements.

- A path may have a line break in either half. A name and a selector value both go through the one quoter, which writes it as `◉NEWLINE◉` and reads it back. The selector was refused until the tokenizer cut, while elements were still stored in their source spelling and the value emitter had nothing to escape with.

- A refused write says why, in the status every setter returns. The table is the rule, with one row per status, in the order every binding numbers them. A path reason wins over a value reason, since the path is the first thing to fix, so a value reason always comes with a path that `CheckSetPath` passes. The CLIs print the reason from the status and don't work any of it out again. A new refusal gets a row on the end before it gets code.

| Status        | Half  | Given for
| :---          | :---  | :---
| `Ok`          |       | The write applied.
| `BadPath`     | path  | An empty path, one the scanner refuses, or a name or `(value)` the write would create that has no line reading back as itself.
| `ValueInPath` | path  | A `: value` part in the path.
| `Wildcard`    | path  | A wildcard name or selector.
| `NoSuchIndex` | path  | A `(k)` with no instance there.
| `TooDeep`     | path  | A path past the nesting cap.
| `Multiple`    | path  | A step with no selector, or a `(value)`, matching more than one field.
| `UnderArray`  | path  | A field the write would create under one holding an array (`E028`).
| `HasChildren` | value | An array on a field with lines under it (`E028`).
| `NotFinite`   | value | A NaN or infinite float.
| `BadDateTime` | value | A datetime that doesn't read back as the same fields.
| `BadRawInfo`  | value | A raw block's info string with a `#` or a line break in it.
| `BadRawBody`  | value | A raw block's body line ending in a carriage return, or one that would close the block.
| `BadComment`  | value | Comment text with a line break in it.
| `NotOneValue` | value | `SetLiteral` text a file line wouldn't read as one value, or that holds a `#` outside quotes.
| `NotUtf8`     | value | Text that isn't valid UTF-8. Go, Python, and C only, since a Rust string always is.
| `OutOfRange`  | value | An int past the 64-bit range. Python only.
| `NoReadBack`  | value | Any other value that doesn't read back. None is known, but it keeps the rule above true for a value nobody has thought of.
| `RawBlock`    | value | A default form of another type on a field holding a raw block (Default forms).

- `NotUtf8` comes before the other value reasons, so that way text that isn't UTF-8 gives it even with a line break or a `#` in it as well. A path's reason still wins over all of them, and a path that isn't UTF-8 is `BadPath`.

### Kept lines under edits

This is what each edit does with the kept lines near its target. A kept line is one the load kept as written, either retained for its content or kept for where it is. The table is the rule. Edits lost these lines one site at a time, each at exit 0, so a new edit gets a row before it gets code.

Where a kept line is comes from canonical output before the edit. Under the target means written inside its block. Heading the target means written in place of its `name:` line, which canonical output does for a field opened from a line kept for its value. Beside it is anything else.

| Edit                                                         | Beside the target                                                                                                     | Heading the target | Under the target
| :---                                                         | :---                                                                                                                  | :---               | :---
| `Remove`                                                     | stays                                                                                                                 | goes               | goes
| Every setter, the default forms included                     | stays, except a field line kept for its value that names only the target's field, which becomes a comment             | becomes a comment  | stays
| `SetComment`, `ClearComments`                                | stays                                                                                                                 | stays              | stays
| `SetBanner`                                                  | stays                                                                                                                 | stays              | stays
| `Merge`, the base's lines                                    | stays, except one the settle wrote as a comment among the comments of a leaf the layer replaces, which goes with them | stays              | stays
| `Merge`, the layer's lines                                   | comes in                                                                                                              | comes in           | comes in, except a footer line the base already has, unless kept lines sit under it

- A remove only takes lines away. It doesn't write any line the document didn't write before, so a field opened from a kept line doesn't leave a bare `name:` behind.
	- Neither does a dotted line whose last name a remove takes, when the next line names the same names again. After `a.b: 1` goes, `a.c: 2` opens `a` (2026110613470312). The blank line above the removed line goes with it, as it does above any removed line.

- A field opened from a kept line goes with the last line under it, and the kept line stays where it was. A raw block of the same name after it had its fence on the name's line only because of that empty field, so the fence moves to a line of its own. That's the one rewrite a remove makes.

- A remove takes the comments written against its target. Above it, that's the ones after the last kept line, and below it, the ones before the first kept line or blank line. A comment on the far side of a kept line stays with that line, and so does a run a blank line sets off from the target below it, which is the target's trailing lines only up to that blank (2026110712372276). A kept line the settle wrote as a comment counts as kept here, even though a reload of the canonical text reads it as a plain comment.

- A repeated header goes when the last line under it is removed, since an earlier block already has that instance, and the blank line above it goes too. While anything stays under it, the header and its blank line both stay.

- The kept lines beside a target that was the last field in its block stay at the end of that block. A misplaced line among them doesn't have a level there, so it goes down to right above the next field line, with the comments after it, which is where a reload files them. A kept field line after it stays in the block, so the 2 change places, as they do when the removed line is cut from the file by hand and the file is formatted (2026110714552634).

- A setter that replaces a stacked list's value moves the kept lines among its elements above it, as under Load outcomes, with the field's blank above them, as [Lines an edit takes from their node](#lines-an-edit-takes-from-their-node) describes. A move isn't a loss. A line among them that names the list is then a comment, as the next bullet says, on that set rather than a later one.

- A setter that writes a field writes as a comment every kept line at that level of its block that names only that field. That includes the one heading it when the field was opened from a kept line. So once those lines are fixed by hand, the field doesn't read as Multiple. Only a field line refused for its value alone counts, since its name reads. One with a raw body doesn't, since it can't be commented out as one line. Then the setter changes the field in place. Where there isn't any field of that name, the new one goes right under the first of those comments. The lines written under that kept line go under the new field, where a reload files them. A field made on the way to the target does the same. When there are 2 valid lines of one name, they stay as they are, since a setter on that name is refused (`Multiple`) where a read of it would give `Multiple`.

- A setter whose `(value)` selector doesn't find any instance, and that writes a value another instance of that name has, sets that instance, as a set without a selector does, since the instance it would make folds into it. So the lines beside it stay where they were. A fold of 2 instances, such as a setter giving one the value of an earlier one, leaves the kept lines beside the one that goes where they were, as a remove does. The comments written against it move to the one that stays.

- The load folds a second instance of one name and value into the first the same way. The kept lines read beside the second one stay above the next line of the block read after them, or at the end of the block, and the comments written against it move to the first. A kept line before a dotted line still goes to the line's first segment, where the dotted line is written.

- There are 2 kinds of kept line that stay as they are. One has a kept line written under it and isn't where a new field goes, since as a comment it would leave that line under the field above. The other has a misplaced line under it, since a misplaced line is filed by its own text and can't move with it. The first comment is then the first of the others. `SetComment` makes a missing field without touching any of these lines.

- A line the load dropped right after the kept line a new field goes under isn't placed by the save that keeps lines, since the lines before it are all new. That save falls back to canonical and refuses, as for any dropped line, and `--lossy` writes it.

- The note on each comment says why and when: `# a: O' Brien  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E025 a quote in a bare value`. It names the path the setter was given, the local time with the zone's short name, and the code and reason the load gave, without the advice after the reason. A zone without a short name, such as one named `+03`, is written as its offset, `UTC+03:00`. Windows names a zone only in full, so there it's always the offset. The line is a plain comment from then on, as a reload reads it. The save gate doesn't count it any more, and `ClearComments` and a remove of the field take it like any comment on the field. A default form that writes ends up here like any setter.

- `SHCL_TEST_CLOCK`, in the form `YYYY-mm-DD HH:MM:SS OFFSET_MINUTES [NAME]`, stands in for the clock and zone in that note, so tests can pin it. Every test runs on a pinned clock, which is set once before the first test, in `tests/common` for Rust, `TestMain` for Go, and at the top of each Python and C runner. `cli-regress.bash`, `crosscheck.bash`, and `check-doc-examples.bash` set it too. A pair of notes made on the real clock can be a second apart, so a test comparing them would fail now and then.

- A kept line's raw body is part of the line. Every edit keeps or takes the 2 together.

- The merge exception for a settled line on a replaced leaf dates from 2026-09-28. The line goes the way it would in a merge onto the reload of the saved base, where it's a comment.

- A leaf's comments, for a merge that replaces it, are the ones a remove would take. Above it, that's the ones after its last kept line, and below it, the ones before its first kept line or blank line. A settled line counts as the comment a reload reads it as. A comment or a settled line past a kept line beside the leaf stays with that line.

- The save gate counts kept lines. The load records how many it kept, and each edit takes off only what this table allows. A document with fewer than that counts the rest as lost, so `LostCount` includes them, the save refuses, and the save that keeps lines falls back and refuses with it. `--lossy` writes anyway, as for a dropped line. Of checking each edit site and checking the count at the save, the count was chosen, since the sites were the problem.

- A fuzz property checks all 4 bindings against the table. After any edits, every kept line that no edit's target took is still in the saved text, or the save refuses, and a remove doesn't add any line. The other 3 are held to it through the comparison across bindings, which replays its inputs and edits through each CLI's `set --write`.

### Lines an edit takes from their node

When an edit removes, replaces, folds, or merges a node, or replaces a list's items, the comments and blank lines around what went need a new node to belong to. Each edit handled that in its own code. There was `unstack` for a replaced item list, `beside_kept` with `leave_above` and `leave_last` for a merged duplicate, `refile_folded` and `settle_first_blank` for a fold at load, `drop_banners` for the info block, and the remove's own path. Each got the blank line wrong at least once, and fixing the site at hand closed one case per round (2026110616475902).

- Every comment line and blank line belongs to one node from the parse on, as its leading lines or its trailing lines. The emitter writes a node's lines in one fixed order, which is the blank, the comments, the line, the lines that open its block, the children, and the trailing lines.

- A node's leading lines are the comment run right above its line, with no blank line between, and its blank is the one above that run. A comment run a blank line sets off from the line below it is the trailing lines of the node written above it at that line's level. With none, it's the lines that open the parent's block, which sit above its first child. The root's are the top of the file. So in `# c`, a blank, `b: 2`, the comment is the file's and stays when `b` goes, and in `a: 1`, `# c`, a blank, `b: 2`, it's `a`'s (2026110712372276).
	- A run is set off only before the first kept line above the field line, so no comment crosses a kept line. A run between kept lines, or between a kept line and the field line, stays as built, with the field's leading lines, and a remove of the field still takes the comments after its last kept line. A kept line the settle wrote as a comment is set off as the comment a reload reads it as, and when the settle writes one, or moves one from among a list's items to right above the list with the list's blank above it, the lines around it are filed again.
	- A run between 2 blank lines is the line above's too. A remove of that line leaves it, since a remove takes the trailing lines only up to a blank line.
	- A dotted line is written as its last name, so that name's place decides. A run before a kept line that sits level with the line's first name goes above that name.
	- A run with no field line after it is the footer, as it always was. An edit that leaves one at the end of the top level, or leaves a block's opening lines with no child, files them as a reload does: in the footer, or as the lines inside the block.
	- A merge puts a layer's opening lines after the base node's, and the top of a layer's file after the top of the base's, with a blank above and below it. A line the base already has there isn't written twice, as for the footer.
	- `SetBanner` looks for an info block in the trailing lines and opening lines too, where the parse now files one set off by blank lines. The top of the file is the root's opening lines with the first field's leading lines, and a block there stays.

- The lines of something an edit takes away go to what takes its place, or else the next sibling, or else the parent's trailing lines. They go right above the heir's line, after the comments it already has, and the heir's blank goes above them. So a comment stays against a line, and the blank that set the heir off from the line above it still does. A blank between 2 of the lines that moved stays. One above the first of them goes, since it would set the heir off where the file didn't.

- `adopt` is the one function that does it, with the same name and the same call sites in all 4 bindings. No edit moves a comment or a blank any other way, so a new kind of edit can't get the blank wrong on its own.

- A replaced item list goes through it. A setter or a merge that writes the list anew puts the comments among its items, and the ones on them, right above the field (2026110613470311). Before that they went above the field's blank, so they read as part of the block above. The ones above a blank between 2 of them are then set off from the field, so they're filed as the line above's, as a reload files them.

- The code still differs in places. The remove, the folds, the merge of a duplicate, and the banner toggle still use their own helpers, which go once the comment placement suite (2026110616475903) passes with both in place (2026110712372281).

### Default forms

A default form makes sure a field has a usable value of its type, in one call. It writes where the path is missing, where the field is empty, and where its value doesn't read as that type. The typed read decides, at the document's strictness, so `$5` is an int to a loose document but not to a standard one. A form without a type of its own counts any value. Those are `SetStringDefault`, since any value reads as a string, and `SetLiteralDefault`, since literal text doesn't name any type. The CLI's `--set-default` and `--set-literal-default` are those 2, so they fill only a missing or empty field. The typed ops (`int-default` and the rest) do the replacing. The table is the rule.

| At the path                                  | Scalar default (int, float, bool, datetime)  | Array default                                | Raw default                                  | String or literal default
| :---                                         | :---                                         | :---                                         | :---                                         | :---
| Nothing                                      | written                                      | written                                      | written                                      | written
| An empty value                               | written in place                             | written in place                             | written in place                             | written in place
| `[]`                                         | written in place, since it reads `Empty`     | stays, since it reads as an empty array      | replaced                                     | stays
| A value that reads as the type               | stays                                        | stays                                        | stays                                        | stays
| A value that doesn't read as the type        | replaced                                     | replaced                                     | replaced                                     | never happens
| A raw block                                  | refused, `RawBlock`                          | refused, `RawBlock`                          | stays                                        | stays
| A field with lines under it and no value     | value written, the lines stay                | refused, `HasChildren`                       | written, the lines stay                      | value written, the lines stay

- A replaced value stays above the field as a comment with a note: `# port: abc  ## replaced by shcl when setting a default for port, 2026-10-04 00:15:00 PDT: not an int`. The old line is written the way the canonical text writes it, so the note is the same on a document and on a reload of its saved text. The time is the one `SHCL_TEST_CLOCK` stands in for, as in the note under Kept lines under edits.

- A stacked list that doesn't read is replaced too. Its whole value is one bracket array in the comment, so nothing typed by hand is lost. The comments on its items go above the field first, as for any setter that replaces a list.

- A raw block is refused because its body doesn't have a one-line comment form. Commenting every body line out would keep the text but not the block. Refusing doesn't lose anything.

- An empty value is filled without a note, since nothing is lost. A field with lines under it and no value reads `Empty`, so a scalar default gives it a value and the lines stay under it. An array default there is refused like any array on such a field.

- A path is judged first, then the value against the probe document, then what's there. So a wildcard or a NaN is refused whether or not the field reads, and a NaN over a value that doesn't read is `NotFinite` rather than a replace.

- The note is a plain comment from then on. `ClearComments` takes it, and a second call with the same default doesn't write anything, since the field reads now.

- The options were to change the default forms, to add a separate `ensure` call beside them, or to leave it to the docs. The default forms were changed, and a replaced line stays as a comment with a note (2026-10-09). The raw block refusal and the CLI options that fill only a missing or empty field date from 2026-10-10.

### Generation outcomes

This is what `init` writes for each kind of line, and what proves the line reads back. The table is the rule. `init` output that failed its own check was a long-running class of defect, and every one was the generator predicting what the scanner would read. It doesn't predict now. Each spelling it picks is scanned back as a file line first, the way the load will scan it, and every line it writes is read back.

| A generated line           | How it is written                                                                                                                                                                                                      | How it is checked
| :---                       | :---                                                                                                                                                                                                                   | :---
| A field's path             | The schema's own spelling when a file line reads it back as the same path, else rendered from the path's segments.                                                                                                     | The whole output loads without any error and validates clean against the schema.
| A child of a valued parent | Selects the parent by its value. The body is the first candidate a file line reads back as a value selector for that value: as written, bare, then quoted. A selector never matches an array, so an array has no body. | No candidate reads back: `V097`.
| Two lines on one path      | The first is written, and its value is the instance the children select. Two by-value fields with different values are 2 instances, and both are written.                                                              | The same as a field's path.
| An optional field's line   | Commented, with or without a default.                                                                                                                                                                                  | Read back alone, and its value checked against its own field.
| Text in the trailing block | Every schema string through `schema_text`, so a line break stays inside the comment.                                                                                                                                   | Nothing reads the block back; the escaper is the rule.

### Testing

The conformance corpus is the primary cross-language guarantee. Each case is an input, its canonical formatting, and the expected typed reads with status sentinels. Every parser runs it in CI.

Passing the corpus on its own is necessary but not enough once there's more than one binding. Even 2 implementations that each satisfy the expectations can still disagree on details the corpus never pinned, like float rendering or edge behavior that doesn't produce a diagnostic. So the pipeline also runs a differential check:

- Every binding's CLI is replayed over the same inputs, which are the whole corpus plus a freshly generated fuzz set.

- All bindings must agree with the reference byte-for-byte on stdout and exit code. The reference is Rust.

- stderr is outside the contract on purpose. Diagnostic wording and OS error text are up to each binding. stdout and exit codes are the contract.

Both of those run on small inputs, so nothing watches a whole class of defect that only appears at scale. A parser that's accidentally quadratic, a buffer that grows wrong past a few megabytes, or a memory profile that puts a real config out of reach all pass a corpus of cases a few hundred bytes long. So the pipeline also formats one large generated document, 100 MiB by default, through every binding:

- The bindings must agree on the result byte for byte, the same as on the corpus. The document is generated rather than stored, because a fixture that size has no business in a repo, and the layout matters more than the bytes.

- Each binding is held to a wall-clock ceiling and a peak-memory ceiling, given per input MiB so they follow the configured size. The ceilings are set to catch a change in growth rate rather than to time a machine. The time ones have wide headroom, because the pipeline runs the reference unoptimized and a hosted runner is slower again. Memory is held closer, since peak usage barely moves between machines.

- At that size the reference also has to prove formatting is a fixpoint and that a long array reads back whole. Both are cheap to state, and a small case can't check either one.

- Python formats a 16 MiB copy instead, and has to match the reference's output for that copy. At 100 MiB it took 2 minutes or more and was the critical path of the whole gate. At 16 MiB a quadratic parse or a bad buffer still shows, and the run takes about 20 seconds.

The size is a floor on purpose rather than a target. It was picked because it's roughly where memory stops being free. Every binding uses tens of times the input size in memory while parsing, so a document this big is the first one whose cost is worth a decision.

All of that runs on Linux, which was enough while every binding did the same thing everywhere. The file tier changed that. Publishing a written file goes through different code on Windows in all 4 bindings, so the Windows half was tested only where it never runs. A second CI job runs the runners and the veneer smoke on Windows.

Its scope is narrow on purpose, and it isn't a second definition of passing. The corpus goldens, the differential check, the large document, and every lint gate stay on the Linux job, where they're defined. The Windows job is there for the code that only exists there.

It came with 2 supporting decisions. The C runner walks the corpus with `dirent.h`, which MSVC doesn't have, so the compiler is gcc. End-of-line conversion is also turned off for the whole repo. Git for Windows turns it on by default, the goldens are compared byte for byte, and some of them are about line endings.

Every binding follows 2 portability rules:

- Floats render as shortest round-trip decimal, never in scientific notation. This matches the reference's native float formatting.

- Diagnostic order must be deterministic. A load's list is in line order, and in order of first appearance within a line. A port can match a fixed order, but it can't match a random one.

### Format comparison

The feature comparison on the front page says how SHCL differs from JSON, YAML, TOML, and XML. Nothing said what any of it costs, so `cicd/utility/comparison/` measures that, and the numbers [comparison.md](comparison.md) quotes come from there.

This is the method, and why each part of it is the way it is:

- **The language is held constant within a tier.** Every format in a tier is read by a library from that ecosystem, built the same way. Measuring SHCL's C binding against a JSON parser in Python would compare implementations and call the result a property of the formats.

- **Two tiers, never ranked against each other.** Rust is the headline, because there every format has a mature native parser, and the comparison is as close to formats only as it gets.
	- Python then repeats the exercise over the same documents, to answer what one tier can't, which is how much of a format's cost is the format and how much is one implementation of it.
	- Most of what Python uses is a C extension with a Python name, such as `json`, `ElementTree`, and PyYAML's `CSafeLoader`, while this project's Python binding is pure Python. So the row that matters there is `tomllib`, which is also pure Python.
	- That pair is the tier's only like-for-like comparison, and every entry records which side of the line it's on. Python libraries that aren't installed are skipped and named rather than failing the run.

- **One abstract model per document, 5 encoders.** Each shape is built once as a small tree and then encoded 5 ways, so the files have the same data by construction, rather than because 5 hand-written generators happen to agree. Each encoding is the spelling a person would use, such as SHCL raw blocks against YAML block scalars against XML CDATA, because a number taken from an unidiomatic encoding doesn't measure the format.

- **A pre-flight equivalence check.** At a small scale, every library in both tiers has to parse its own file and find the same number of scalar values in it. One model doesn't rule out an escaping mistake in one encoder, and a size or speed number taken from documents that don't have the same data is worth nothing. The Python tier reports through its worker's `--count` mode rather than while measuring, so the walk doesn't cost the timings or the memory figures anything. Both tiers also refuse a document their parse didn't read whole, which is the half that catches a binding defect.

- **One process per measurement.** Peak resident memory can only be attributed that way, since a process that parsed 6 documents doesn't say anything about what any one of them cost.

- **Six shapes**, because one document shape hides most of what separates these formats. Of those, 4 scale to whatever size the run asks for, which are long and flat, wide and deep, an array of records, and multi-line text blocks. The other 2 have their own realistic size instead, which is a hand-edited application config of a couple of kilobytes and a schema definition file of a few hundred bytes. A config file measured at 64 MiB isn't a config file anybody has, and the scaling shapes measured at 2 kilobytes would be measuring process startup.

- **The run count scales with the document.** Best of 3 doesn't say anything when the parse takes microseconds, so a small document gets more timed runs in proportion, up to 200 times the count the run asked for. The count used is recorded beside each shape.

Several choices cut against SHCL on purpose, so that a favorable result stays one:

- **No comments in any document.** JSON doesn't take them, while the other 4 formats do, so any comment at all would compare different documents, and comment retention is the difference SHCL would most like to show off.

- **JSON is pretty-printed and XML is indented**, since the premise is a file a person edits. JSON also gets `preserve_order`, because nobody would release a config loader that silently sorts the file's keys.

- **TOML and XML each get 2 libraries.** `toml_edit` is the only mainstream parser here besides SHCL that keeps the file as written, which makes it the one like-for-like comparison. XML is measured both by the fastest tree in Rust and by the tree you can write back.

- **The generated SHCL is canonical**, a `fmt` fixpoint, so the round-trip column reports what the format does rather than how the generator chose to space things.

Rows are ordered by the geometric mean of each library's parse time across every shape, fastest first. That one order is used for every printed table and for the results file, so a row keeps its place from shape to shape. It's the geometric mean rather than the arithmetic one, so a single large shape can't decide the whole order. The number it sorts on is recorded beside each library, so the order can be worked out again rather than trusted. SHCL sorts fifth of seven in Rust and last in Python. That's the measured result, and it's why the order is stated rather than chosen.

Reading a value by path isn't measured, on purpose. The 5 lookup APIs differ enough that the harness would have to write the walk itself for most of them, and the result would be a measurement of harness code.

It isn't a pipeline gate. Benchmarks are noisy and slow, and a red build caused by a busy machine doesn't teach anybody anything. It runs on demand, and its results build up in `results.shcl`. That file is the tool's storage format as well as its subject, and it's written, pruned, and read back through this repo's own library.

The tool found one thing about a library rather than a format, recorded so nobody has to work it out again. `lxml` goes quadratic on the long-and-flat shape, and drops from 59 MiB/s at 3 MiB to 5.7 at 26. It was measured with and without `huge_tree`, which makes no difference, so it isn't the flag that lifts libxml2's size ceilings. The likely cause is the shape's millions of distinct element names against libxml2's name dictionary. The shapes whose names repeat don't show anything like it, and no other library in either tier does this. It's a good argument for measuring more than one document shape.

What it found, at 64 MiB per shape (rerun on 2026-11-05; runs before 2026-09-19 read the memory figure with 2 documents alive for 5 of the 7 Rust libraries):

- SHCL writes the smallest file of the 5 in 3 shapes of 4, and the gap widens with nesting, to half the size of JSON and of XML on deep structure. Gzipped, SHCL is within 3% of the smallest file on every shape, so the win is in plain text only.

- SHCL loads fifth of seven in Rust and last in Python by aggregate, 3 to 9 times behind `serde_json`. On memory it's in the middle. It's below YAML on all 4 shapes, below TOML on 3, above JSON on all 4, and below `toml_edit` on all 4, at about 40% of it on the records. `toml_edit` is the one other parser that keeps the file.

- The Python tier puts SHCL 5.7x behind `tomllib`, the tier's one other pure-Python parser, against 1.6x behind `toml` in Rust, so part of the Python gap is the implementation rather than the format. The rest of the cost is the design working as intended rather than a defect.

- At the 2 realistic sizes the size result holds and the speed result stops mattering. SHCL writes the smallest file of the 5 for both the config and the schema definition, and reads them in 0.05 ms and 8 ms.

### CI/CD

The responsibility is split rather than duplicated:

- The GitHub workflow (`.github/workflows/ci.yml`) is a correctness gate only. It runs the merge gate, as far as the runner can, on pushes to `main`, on pull requests, and by hand. It has minimal permissions, cancels superseded runs, and times out.
	- The cross checks run there too. They don't build anything anyone downloads. They build the C library and CLI for Windows through mingw, the C library with file I/O compiled out, and the Go library for Windows, so they belong with the other checks rather than with the release artifacts. Inside the release branch, the gate never got to them. `--no-cross` turns them off with the cross targets.
	- On Linux the gate runs as 2 parallel jobs, `--merge-gate --no-tests --no-release --no-remote` and `--merge-gate --no-lint --no-cross --no-remote --skip=codeql-scan.bash`. As one job it outgrew the 60-minute limit, since cppcheck's exhaustive pass alone takes 16 to 26 minutes there after a change to the C header. `check-pins.bash` fails when the jobs stop running every stage between them, and both install every tool.
	- The tests job also builds the native release, runs its checks and packages, and runs the fast leak checks. The runner can't connect to the test boxes on the LAN. CodeQL is left out by `--skip`, since its bundle is about 700 MB and its run takes more time than the tests job has. `check-pins.bash` limits `--skip` to that step alone. The cross targets are left out too, because they'd need a third job, and the macOS, Linux arm64, and Windows jobs already build on their own runners (2026102813104371).
	- Rejected: a third job for the cross targets and their checks, which would install wine and QEMU and fetch FreeBSD's 640 MB image on every run, when the hosted workflow is meant to stay small. Also rejected: `--no-leakcheck` in place of `--skip`, which would drop the sanitizer runs the hosted gate already had.

- The hosted `macos` job builds the macOS universal release on GitHub's free arm64 runner, runs the Rust tests, and runs crosscheck and cli-regress on the arm64 half. It also checks that both halves still name macOS 13.0 as their floor. It runs on `macos-15`, the supported runner nearest that floor, since GitHub retires `macos-14` on 2026-11-02 (2026103014303616).
	- It takes about 3 minutes, so only a local run with `--long` starts it (JC, 2026-11-02). That run starts it alone, through ci.yml's `job` input, before anything else, and waits for it after the test boxes (2026102416250110). A failed job fails the run. GitHub runs what it has, so the job is a SKIP, with the reason, when the remote's branch isn't at HEAD, and it never sees uncommitted edits. `--quick` and `--backlog-run-quick` refuse `--long`, since they test edits in progress. `--no-remote` leaves the job out, since it stays on the LAN, and so does a run that doesn't build any macOS target.
	- Rejected: `macos-latest`, which moves to a new macOS without a commit here, and `macos-26`, which is the furthest from the floor. Also rejected: a separate workflow for the job, which `check-pins.bash` would have to learn to read, while an input on ci.yml leaves its pins where they're checked now.
	- The local Macs, b26 and vmKt6m, are Intel, so the test box step runs the x86_64 half there over the CLI cases, as `mactest`, and this job is what runs the arm64 half (2026102419263427).

- `dev` isn't gated by the hook or by the hosted workflow. The pre-push hook runs `cicd.bash --merge-gate`, which is every check of a run with no flags, on a commit bound for `main`, and it skips one whose tree a run already passed. A push to `main` that changes only docs and art that no build reads skips it too, judged against the remote's `main` by the one list in `cicd/docs-only-paths.txt`. Each run that gets through the tests and the cross checks records the tree it tested, unless it ran `--quick`, `--no-fmt`, `--no-lint`, `--no-tests`, `--no-cross`, or `--skip`, or skipped a missing tool. Before this, one change to `dev` went through a full local run, then the same gate again in the hook, and then about half an hour of hosted CI.
	- It's a tree hash rather than a commit hash. The publish stage commits after the tests run, and a `--no-ff` merge makes a new commit with the same files.
	- Gating `dev` was dropped. Work is merged there several times a day, and a 10-minute wait on each merge only ran again what the branch had already passed. Building and testing before the merge is the check that counts there. `main` still gates every commit.
	- Making the hook opt-in was rejected, since nothing would then gate a commit that never went through a run. So was keeping hosted runs on `dev` behind a `[skip ci]` marker, which would have to be typed on nearly every push.
	- The cost is that a failure only the runner shows, such as a tool its image lacks or a defect only on Windows, now waits for the next push to `main`. `gh workflow run ci --ref dev` gets a hosted run sooner.

- Everything else, such as cross-compiling, packaging, and publishing, stays in the local pipeline, `cicd/cicd.bash`, configured through `cicd/config.bash`.
	- The x86_64 release builds run on plain x86-64 (v1), the floor that the last Core 2 Duo and the Phenom II share. Stage 6 checks it with `check-cpu-floor.bash` before the artifacts are collected. It disassembles each x86_64 build and fails on any instruction past v1, then boots the Linux build under QEMU as a Penryn and as a Phenom and runs the CLI over the corpus. QEMU's software CPU traps on most extensions a model lacks, but runs `lzcnt` and `tzcnt` as `bsr` and `bsf`, so only the scan catches those. Rust's Windows targets also assume SSE3, CMPXCHG16B, and LAHF/SAHF, which both chips have. Hosted CI builds only the native release, so the Windows builds are scanned only in a local run.
	- The freebsd-x86_64 build links FreeBSD's own loader and libc, so no Linux box runs it directly. Stage 6 boots FreeBSD's official VM image under QEMU with `check-freebsd.bash` and runs that build over the same corpus cases, and it has to give the same bytes and exit codes as the Linux build. The image is pinned by URL and sha256 and kept in the pipeline's cache. With KVM the run takes about 20 seconds, and about 2 minutes without. It runs in stage 6 with the other release checks rather than in a hosted job, since a hosted job would fetch the 640 MB image on every run, a third-party FreeBSD action is ruled out (JC, 2026-10-21), and hosted CI doesn't build any cross targets.
	- The windows-x86_64 build runs the same cases under wine in stage 6, and again on b29w, a real Windows box, in the test box step. ssh to it opens in cmd, so the box half there is `cicd/utility/box-cases.ps1`, copied over with the cases. Windows words an OS error its own way, so only the code in `(os error N)` is compared, as under wine (2026103016433921).
	- Under `--long`, b29w also runs `win-runners.bash` from a copy of the tracked source, through git's bash, as the hosted Windows job does. That runs the 4 bindings' runners, cli-regress, the rows only for Windows, and `winpath-regress.ps1`'s registry checks. It runs as an administrator, and the registry test puts both PATH values back after. It took about 25 minutes, which is too long for every run (2026103016433943).

- A run with no flags fits in about an hour. What takes hours, such as every Rust test under Miri, runs only under `--long` (or `--slow`) and `--leakcheck`. So does `win-runners.bash` on b29w, and so do the bindings' suites other than Go on vmDebARM64, whose arm64 CPU is emulated. Its `REMOTE_BOXES` row sets that with `suites=go|suites-long`. Its CLI cases and the Go suite, about 3 minutes, run every time. `--quick` keeps the fast leak checks and leaves out the slow ones. It leaves out the test boxes, as it does the GitHub job, since they're other hosts (2026110215285702).

- `--backlog-run-quick [AREA...]` is the check before each commit, and `--backlog-run-full` is the last run before a merge. Neither dogfoods. The quick one is the format check, build, lint, tests, and cross checks, less what `--quick` leaves out, in about 4 minutes, and it doesn't record a tree, since it's partial. `--gate` is another name for it, now that the hosted run takes the merge gate. With no areas named it also leaves out `BACKLOG_SKIP`'s tests, such as the pre-push hook's own, which took 4 of a 10-minute run. Areas narrow only the tests, since the format check and lint are quick, and bring back their `BACKLOG_SKIP` steps. Its lint and test steps run up to 4 side by side, each with its share of the cores, and print in order, which took it from about 7 minutes to under 4 (2026102515494624). `BACKLOG_ALONE` names the ones that can't share the box with the rest. The full one runs the merge gate's checks. A run takes one run mode, so `--merge-gate` and the 2 backlog runs can't be given together.

- Both use one definition of "passing". The workflow runs `cicd.bash --merge-gate` on Linux, split by stage flags, plus a Windows job for the binding runners. Per-language toolchain setup is in the workflow YAML, and what passing means is in the engine, so the 2 can't drift.

- The formatter rewrites in place locally, but in CI it only checks and fails on a diff.

- Branch flow: `dev` is the integration target, where feature branches merge with `--no-ff`, and `main` is release-only. A dev -> main merge is normally a release cut.
	- The exception is a merge that doesn't change any product code, such as documentation, the demo asset, or the pipeline. Those go to `main` on their own so the front page and the install one-liners, which read from `main`, stay current, and the version stays where it is. Cutting a tag for them would publish a second set of binaries that behave the same as the last one, which doesn't tell a reader anything.
	- The 3 installer scripts count as front-page material for that rule rather than product code. No package or release asset includes them, and the one-liners fetch them from `main` at the moment somebody runs one, so a fix that's on `dev` doesn't help anybody. The alternative was to fetch them at a tag, and it was rejected. It would freeze an installer's bugs into every release that came with them, and the installer's job is to fetch the newest release rather than to be part of one. So an installer fix may go to `main` on its own, under the same rule as a docs merge, with no tag, version bump, or changelog entry.

- There's one canonical version source, `source/rust/Cargo.toml`. The pipeline reads it for artifact names and release tags. An automatic guard that bumped the version before a push was tried and dropped. dev is the integration branch, and versions there are cut on purpose at release time rather than policed per push.
	- The Go, Python, and C CLI version strings and `source/python/pyproject.toml` are mirrors of it kept by hand, moved together at a cut along with the changelog heading and the literal version strings in `install.md` and `examples.md`.
	- Every build the pipeline makes prints a build number after its version, as in `shcl v3.0.0 build dd2f6`, then the copyright line (2026102416250100). The number is the minutes from 2000 to the commit's time, in lower-case Crockford base32. It comes from the commit rather than the clock, so a rebuild of one commit still gives the same bytes. Only the Rust CLI is released, so only it is stamped. The other 3 print the version alone, and the crosscheck takes the build number and date off the version line before it compares, so the version itself is still held to Cargo.toml. A build outside the pipeline, such as a `cargo install` from crates.io, doesn't have any git history to read, so it prints the version alone.
	- A stamped build that isn't a release adds the date, as in `shcl v3.0.0 build dd2f6 (2026-10-23)`. The release builds of a version that already has its tag are dev builds too. A release is built from the bump commit, before the tag exists, so its release builds leave the date off, while the same run's debug build keeps it. The date is worked out from the build number when the CLI runs, in the local time zone of whoever asks. Of the options, the tag was picked as what tells the 2 apart (JC, 2026-10-23).
		- Rejected: a `--release` flag on the cut's run, which a missed flag turns into a dated release. Rejected: a date on every build, which breaks the byte-for-byte `--version` across the 4 CLIs. Rejected: the date stamped in at build time, which is the builder's day rather than the reader's.
		- The date on every build that isn't a release came back with the 2026-10-24 CICD reset (2026102416250100), since the crosscheck doesn't compare the build number and date any more.
	- There are 2 tags per cut, `vX.Y.Z` for the release and `source/go/vX.Y.Z` for the Go module. Go resolves a module in a subdirectory only through a tag with the path as a prefix, so skipping the second one silently leaves every Go consumer stuck on a pseudo-version.
	- Release assets are signed before the release is published. Both installers refuse a release whose sums file doesn't have a valid signature, so publishing first would offer an install that nothing can verify.
	- A registry publish can't be taken back. Neither crates.io nor PyPI allows a version to be uploaded again, and each keeps the README it was given at that moment. So the per-binding READMEs (`source/rust/README.md`, `source/python/README.md`) get their example code compiled and run against the packaged artifact before the upload rather than after. Those files are separate from the front-page README because relative links and images break on a package page, and Cargo can't read above the crate root anyway.
	- Binding versions move in lockstep with the product version, on purpose. The bindings are byte-for-byte equivalent by design, so with a single number across all of them, a consumer who reads `2.1` in any language knows exactly what behavior they have. It also lets each ecosystem's ordinary compatible-version operator (`shcl = "2"`, `shcl~=2.0`, Go's major-version import rule) do the tracking, with no scheme of our own to explain or maintain.

- Installer packages are built in the release stage rather than in a separate pipeline. `cicd/utility/package.bash` builds a .deb and an .rpm per Linux binary with nfpm, from one template rendered with sed, plus a FreeBSD .pkg and an NSIS setup per Windows binary. They go into the same versioned artifact family before the checksums are written. Package layout follows distro convention, which is /usr/bin and /usr/share/shcl, rather than the /opt layout the standalone install.bash uses, because packages answer to distro policy and the script answers to the spec. The payload matches install.bash, with the binary and the code/ drop-ins, plus the man page and completions in the Linux and FreeBSD packages.
	- No packager on Linux writes a FreeBSD `.pkg`, so `package.bash` writes the tar itself. It has `+COMPACT_MANIFEST`, `+MANIFEST` with each file's sha256, and then the files under `/usr/local`. Its ABI is `FreeBSD:*:amd64`, with a `FreeBSD_version` of 1400000 for the floor. pkg refuses a package whose ABI names another major version, so a `FreeBSD:14` package wouldn't install on 15. The version annotation gives the floor instead. Rejected: building it with `pkg create` on vmFreeBSD, which would leave the release short a package whenever the box is down, and building pkg from source into the image.

- Release trust root: the sha256sums file is signed offline with an RSA-4096 key, and both installers have the public half inlined and check it before reading a checksum out of the file. These are the decisions behind it:
	- Order matters more than the algorithm. A checksum taken from an unverified sums file proves nothing, so the signature is checked first or not at all.
	- The threat is release-asset replacement, such as a leaked token with release scope or a compromised CI job, rather than full repo compromise. An attacker who can rewrite `install.bash` on `main` can also delete the check. Those are different access paths, and separating them is the point.
	- The key is offline and signing is manual. A key in CI secrets would be open to the very compromise being defended against, which would make the signature decorative.
	- The key is inlined rather than fetched. A key downloaded over the same channel as the artifact doesn't authenticate anything.
	- RSA was picked over the more fashionable Ed25519 only because of verifier availability. `openssl` is there on Unix, and .NET's RSA is there on Windows PowerShell 5.1, where Ed25519 is absent. Any scheme that needs a tool the box doesn't already have (minisign, cosign, gpg) loses to the bootstrap problem of verifying the verifier.
	- `openssl` became a hard prerequisite of `install.bash` alongside curl/wget. Installing unverified isn't offered as a fallback, and the DIY path is there for a box that doesn't have it.
	- Rotation is expensive by construction, since old installers have the old key. Treat a key change as a breaking change, with a new installer and a release note.
	- The Go binding gets tamper-evidence free from `sum.golang.org`, so this protects the binaries and drop-in payload, which don't have an equivalent backstop.

- The toolchain is pinned in `rust-toolchain.toml`, with rustc, clippy, and the cross targets, and helpers installed with cargo get warn-only pins, so a box update can't silently change results.

- Release builds are reproducible. On the pinned toolchain in `rust-toolchain.toml`, building a given commit produces a byte-identical binary on any machine, from any directory, for all 4 release targets. The packages and the drop-ins tarball rebuild byte-identical too. So a release tag can be built and checked against the published checksum rather than taken on trust.

- Fuzzing is part of the regression suite rather than a separate rig. A deterministic mutator over the corpus asserts 2 invariants for any input. It never panics at any strictness, and the formatter is a fixpoint. The same mutator generates the inputs for the differential check above.

- Profiling is a standing stage. Every full run samples an optimized build over a heavy parse-and-format workload and emits a flamegraph plus a hot-spot summary, so a performance regression shows up in the artifacts of the run it happens in. Sampling is in-process and behind a feature flag, and it's never built into a release binary.

### Reference implementation

- The Rust crate is at `source/rust/`. It has no dependencies and a single-file library (`src/lib.rs`), so the drop-in integration mode stays real, and the `shcl` CLI builds from the same crate. Later bindings get sibling folders (`source/go/`, ...).

- The conformance runner and fuzz smoke are plain `cargo test` targets, so "the corpus passes" and "the build passes" are the same command everywhere.

### Go binding (Tier 2)

- The module is at `source/go/`, with a single-file library (`shcl.go`) that has no dependencies and uses generics for the typed reads. The CLI under `cmd/` is its own module, so it stays out of the published one. It has the same flags, output, and exit codes as the reference, but it exists to be driven by the differential check rather than installed.

- Conformance runs natively as `go test`, a port of the Rust runner over the same corpus, so the Go binding is corpus-green on its own, and the cicd crosscheck holds it byte-for-byte to the reference as well.

- The pipeline engine stays generic. The Go fmt/build/vet/test commands go in the config's per-stage extras, and the binding is registered in `BINDING_CLIS`, which each further binding (C, Python) repeats without changes to the engine.

### C binding (Tier 2)

- The sources are at `source/c/`. There's a single-header drop-in library (`shcl.h`, C11, no dependencies) plus the CLI under `cmd/shcl/`, with the same flags, output, and exit codes as the reference. The single header is the C version of the other bindings' single-file libraries. Copy `shcl.h` into a tree, and in one translation unit, `#define SHCL_IMPLEMENTATION` before including it.

- The C++ interface (`shcl.hpp`) isn't a second parser. It's the reference's API in std types, `get<T>()` included, with every call going to the same C functions, so it inherits the core's conformance and needs only a smoke test of compiling and behavior to stay correct. A C++ caller doesn't see any of the C interface, since the calls into C are compiled in one file, the way `shcl.h` compiles its implementation.

- The options were making every const member of the C++ `Document` take a lock, saying a Document isn't shared across threads, or taking `const` off the reads, and const members lock now. Every call into the core writes to the document behind it, including its read and scratch arenas and its index, so 2 threads reading one const Document raced. A C++ reader takes const to mean safe to call at the same time, and the Rust `Document` is `Sync`. The locks are a fixed set, picked by the document's address and recursive, and a call that reads 2 documents takes both together. Writes stay the caller's job to keep to one thread.

- Conformance runs natively, through a C port of the runner over the same corpus, so the C binding is corpus-green on its own, and the cicd crosscheck holds it byte-for-byte to the reference as well.

- Memory is a per-document bump arena, so teardown is a single free without any per-object bookkeeping. It's a trade for short-lived tools that keeps the port readable.

	- Nothing a document has finished with is reclaimed until the document is freed, such as a replaced value, a removed node, or a parent a merge rebuilt. `shcl_compact` rebuilds the document into fresh arenas and gives the old ones back, and the merge is what makes it worth calling, at hundreds of kilobytes a fold on a large base against dozens of bytes for one write. The other 3 bindings don't have such a call and don't need one, since reloading the canonical text is a cheap and ordinary thing to do there, and each one's `remove` says so.

	- `shcl_reads_release` levels off rather than going to zero. The read arena keeps its largest block on reset, so a polling process reuses it instead of asking the system on every pass. What's left at rest is the biggest single result the process has ever taken, which for a `shcl_to_canonical` of a large document is the size of that document.

- An allocation failure ends a parse rather than the process. A parse and a validate arm a recovery point before they start, so a failed allocation unwinds out of them and the call returns NULL with everything it had given back. This is worth breaking parity for. The other 3 bindings abort on allocation failure because their languages do, so there's nothing there to mirror, and a library must not end a process that isn't its own. Everywhere else, such as a read, a write, or a merge on a document already built, the `SHCL_OOM()` hook handles it, and its default is still the CLI's print-and-exit-70. An embedder defines it before the implementation and takes it from there, with a longjmp out, a log, or an abort. Nothing is unwound first, so a hook that returns leaks the document being built, and then aborts, because the allocation it was called for still failed. A hook that longjmps arms its recovery point with `SHCL_SETJMP`, which the header has because that unwind crosses the library's own frames and mingw needs it done a particular way, as `style-guide_code.md` explains.

	- Carrying on with a fallback block, rather than unwinding, was tried first, and it doesn't work. A bump arena keeps its vectors' bookkeeping inside it, so an allocation served out of nowhere returns node indices that aren't node indices any more, and the next tree walk reads off the end of the node array.

- The reference gets 2 portability details for free that C makes explicit. UTF-8 is iterated by codepoint, since plain byte scanning would mishandle multibyte text, and float output reproduces the reference's rule of shortest decimal and never scientific.

- C doesn't have a committed formatter without dependencies, so its quality gate is a compile without warnings rather than a separate format stage.

### Shell wrappers (retired)

- Retired 2026-10-08. Bash and PowerShell scripts call the `shcl` binary directly, and [examples.md](examples.md#bash) shows how. The 2 wrappers are frozen in `project/legacy/`, unmaintained and not installed, and an installer update removes the copies an older release put in `scripts/`. These are the reasons:
	- They added little over the binary. `shcl_int f p` is `shcl get --int f p`.
	- The PowerShell one did fix 2 real 5.1 problems, its output encoding and its old way of quoting native arguments. But about a third of it fixed problems that come from putting a PowerShell script or function in front of a native command. Those were `--` and unquoted commas eaten before the function sees them, colon arguments split under `-File`, and pipeline input to forward.
	- The 2 took 33 commits from August to October 2026, against a binary that doesn't need any of it.
	- What 5.1 needs from a caller is one encoding line, and [examples.md](examples.md#powershell) says so.

- This is the superseded design, kept for the record:
	- The shell binding wrapped the `shcl` CLI rather than a parser, so it inherited conformance for free.
	- Bash 3.2 (`project/legacy/shcl.bash`, was `source/bash/`) was targeted rather than POSIX sh. The wrapper was meant to earn its keep by being dual-purpose, so it could run as a script or be sourced for its functions. That dual mode and the typed helpers read far cleaner with Bash's arrays and `local` than with portable sh.
	- PowerShell (`project/legacy/shcl.ps1`, was `source/powershell/`) was the second wrapper, built to the same design. It was dual-mode, had the same binary-resolution order, and passed exit codes through into `$LASTEXITCODE`. It didn't have a script-level param block, since one would try to bind subcommand words, so every argument arrived in `$args` verbatim.
	- One `shcl` function was the whole CLI, and `shcl_get`, `shcl_int`, `shcl_bool`, and the rest were one-line typed sugar.
	- A sourced wrapper armed strict mode only on its run path, so no shell options leaked into the caller, and its own `shcl` function never shadowed the binary during lookup. The binary was found through `$SHCL_BIN`, then a `shcl` beside the script or a level up, then PATH, and then the repo build.

### Man page and completions

- `source/man/shcl.1` is roff written by hand rather than generated from the help text. The help is a byte-for-byte contract across the 4 CLIs and is laid out for an 80-column terminal. A man page has different needs, with sections a reader can jump to and room to say why a refusal exists. Generating one from the other would either bloat the help or flatten the page.

- The man page doesn't have a version string, so the release bump stays the same 8 files it has always been. It does have a revision date.

- The completions mirror the CLI's own per-subcommand option table rather than inventing one. Offering an option the subcommand rejects is worse than offering none, because the CLI treats an unusable option as a usage error rather than ignoring it. `cicd/utility/check-completions.bash` diffs the CLI's table against both completion files at lint time, so the 3 can't drift apart silently.

- The Bash and zsh completion files are kept parallel in structure, with the same table, the same helper names, and the same positional-counting loop, for the same reason the bindings are, which is that a fix ports across by mechanical diff.

- Neither completion offers anything for a `PATH` argument. Nothing can list the paths in a document without reading it, and filenames, the obvious fallback, would be wrong every single time.

- **Where each channel installs them.** The packages and the installer behave differently, because they're different kinds of thing:

	- The `.deb` and `.rpm` put the man page and both completions in the distribution's own directories, where each shell already looks. That's what a package is for, and it's the only channel that can do it without stepping on the package manager.

	- The installer symlinks the man page into the target's `man1` directory, the same way as the binary symlink, and that makes `man shcl` work as soon as the install directory is on `PATH`, since man derives its search path from the `bin` directories there.

	- The installer leaves the completions under the install directory and prints the line to paste for each shell. No single directory works. Bash's autoload directory varies with the bash-completion version, zsh needs a directory already on `$fpath`, and writing into the distribution's own would collide with the packaged copy. Printing the line is the same deal the `PATH` note already makes. It says plainly what wasn't done, and the fix is one paste away.

	- Uninstall removes only what a matching install put there, and the man symlink only when it points back into the install directory. One that doesn't came from a package, and removing it would break a working install.

## Copyright and license

> Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]<br />
> Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0) <https://creativecommons.org/licenses/by/4.0/>.
