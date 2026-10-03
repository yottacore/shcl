<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# SHCL specification

Simple Hierarchical Config Language. This is the canonical language spec: terminology, lexical rules, structure, the read-time type/coercion model, raw blocks, the accessor and writer API, the canonical formatter, and the conformance strategy. The formal line/value grammar is in `grammar.abnf`; the raw by-example origin is in `../../notes.txt`; the settled decision log is in project memory.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Design goals (the north star)](#design-goals-the-north-star)
- [Terminology](#terminology)
- [Lexical structure](#lexical-structure)
	- [Encoding and lines](#encoding-and-lines)
	- [Comments](#comments)
	- [Whitespace, quoting, and reserved characters](#whitespace-quoting-and-reserved-characters)
	- [Escapes](#escapes)
- [Structure and hierarchy](#structure-and-hierarchy)
	- [Indentation (block form)](#indentation-block-form)
	- [Dot and bracket (inline form)](#dot-and-bracket-inline-form)
	- [Merging and instances](#merging-and-instances)
- [Values and types](#values-and-types)
	- [Strings](#strings)
	- [Integers](#integers)
	- [Floats](#floats)
	- [Booleans](#booleans)
	- [Dates and times](#dates-and-times)
	- [Durations and sizes](#durations-and-sizes)
	- [Arrays](#arrays)
	- [Coercion rules ("intelligent but safe")](#coercion-rules-intelligent-but-safe)
- [Raw blocks](#raw-blocks)
- [Consumer API](#consumer-api)
	- [The core call](#the-core-call)
	- [Ergonomic tiers](#ergonomic-tiers)
	- [Status sentinels](#status-sentinels)
	- [Lookup and traversal](#lookup-and-traversal)
	- [Paths, selectors, and traversal](#paths-selectors-and-traversal)
	- [Diagnostics and writing](#diagnostics-and-writing)
	- [File tier](#file-tier)
- [Canonical formatter](#canonical-formatter)
- [Schema validation](#schema-validation)
- [Layered loading](#layered-loading)
- [Schema-driven generation](#schema-driven-generation)
- [Error handling philosophy](#error-handling-philosophy)
- [Strictness levels](#strictness-levels)
- [Migrating from 2.x](#migrating-from-2x)
- [Cross-language parity and conformance](#cross-language-parity-and-conformance)
- [Resolved minor items](#resolved-minor-items)

<!-- /TOC -->

## Design goals (the north star)

SHCL aims to be forgiving to write, predictable to read, and expressive enough for any flat or hierarchical data, with a read API that stays small and predictable. (Not "the simplest possible language": the grammar has real features, and pretending otherwise just invites the comparison. The simplicity claim lives where it is true - in what the two audiences below actually experience.) It is optimized for those two audiences and nobody else:

- **The person writing config by hand.** It must be forgiving and obvious enough that a non-programmer can hand-author a whole file from scratch - even something as rich as a declarative DDL - without memorizing rules. If a modern parser can figure out what was meant, it must; the user is never asked to satisfy the machine.

- **The programmer consuming values.** However SHCL is pulled in (as a **Command** (CLI), a **Drop-in** source file, a **Package**, or a linked library, **Shared** or **Bundled**), it must get you to "read the value I need" in one obvious, amateur-friendly call, and let you write out defaults and comments just as easily.

Everything hard - typing, coercion, disambiguation, error recovery, formatting - is the parser's job. The corollary rule for every ambiguous design call: **push the burden onto this program, never onto the user or the consumer, and impose no constraint the parser could have resolved from context when the input is not legitimately ambiguous.**

## Terminology

The word "key" is deliberately avoided - it implies uniqueness, which SHCL does not require. The mental model is a database, not a map.

- **Field** (a.k.a. column): the name on the left of a colon. A field is not unique; it may recur.

- **Value**: the text on the right of a colon (or an array of such, or a raw block).

- **Instance**: one occurrence of a field with a particular value. Repeating a field with a *different* value creates another instance. (*Row* and *record* are synonyms, listed here only as a glossary pointer; the docs and API use "instance" throughout, and "record" is never used as a verb - the write-side verb is "write".)

- **Discriminator**: an instance's value, when used to tell instances of the same field apart (`base: Chicago` vs `base: Boston`).

- **Wrapper**: a field whose occurrences all have an empty value; they collapse into a single organizational node. A wrapper is just the degenerate (empty-discriminator) case of an instance.

- **Leaf**: a field occurrence with a value and no children.

- **Field path** (a.k.a. key path): the dotted chain of field names identifying a position in the tree, e.g. `base.metrics.population`. A path may resolve to many instances.

One rule unifies all of the above: **a node is `(field-name, value, children)`; nodes merge when their `(field-name, value)` pair matches; an empty value merges with other empty values under the same parent (that is a wrapper).**

The software side has its own nouns:

- **Parser**: turns SHCL text into the in-memory model. It does all the hard work - deferred typing, disambiguation, error recovery.

- **Accessor**: the typed read layer a consumer calls to pull values back out (`GetInt`, wildcards, status sentinels). Typing is *accessor-driven* - the target type is fixed by which entry point you call, never stored in the file.

- **Writer**: the emit side - write values, defaults, and comment sections, and canonicalize a file.

- **Consumer**: the programmer using a binding, as opposed to the person hand-authoring the file.

- **Binding**: one language's implementation of the whole surface (parser + accessor + writer) - "the Go binding", "the Rust binding".

The Accessor reads in two modes:

- **Lookup** (a.k.a. query): fetch a single value at a field path - the TOML/YAML-style point read. Plain English: *get a value*.

- **Traversal** (a.k.a. scan): consume the document as a whole and iterate it - the mode for treating an SHCL file as a DDL or dumping every setting. Plain English: *walk the document*.

- **Materialize**: the step a traversal runs first - merge duplicate instances and order everything deterministically, so the walk is stable and repeatable.

A few nouns from the wider surface:

- **Trivia**: comments and blank-line grouping - kept through parse and re-emitted by the formatter, never part of identity, merging, reads, or diagnostics.

- **Raw block** (and its **fence**): verbatim multi-line content between fence lines, exempt from all SHCL rules; the optional **info-string** after the opening fence is an advisory label.

- **Canonical form**: the one output shape the formatter produces (block layout, tabs, insertion order, minimal quoting); `fmt` of canonical output is byte-identical (a fixpoint).

- **Layer**: a whole document merged under another in layered loading (defaults, then site, then user).

- **Schema**: an ordinary SHCL file of `field:` path entries whose children constrain the document; validation is a separate pass, never a parse-time concept.

- **Corpus / conformance case**: the shared fixture set every binding must pass byte-for-byte; the cross-binding differential check replays it (and fuzzed inputs) through every CLI.

## Lexical structure

### Encoding and lines

- Files are UTF-8. A leading UTF-8 BOM is stripped if present. What a *library* does with bytes that are not valid UTF-8 is unspecified, and the bindings do differ - refusing, parsing the bytes as they are, and substituting are all in use - so a consumer handing the library raw bytes has to check the encoding itself. The CLIs do agree: every one refuses such a file at exit 8.

- Line endings may be LF or CRLF (both accepted); the canonical formatter emits LF. A save that keeps the lines keeps the file's own line endings and indent instead, as described under [File tier](#file-tier).

- Trailing whitespace on a line is trimmed before parsing.

- The recommended extension is `.shcl`.

### Comments

- `#` begins a comment that runs to the end of the line, wherever it sits, as long as it is outside quotes and outside a raw block. No space is needed before it: `url: http://h/#frag` is the value `http://h/` and a comment, `a:#x` is an empty value and a comment, and ```` ```c# ```` labels a raw block `c`. A value holding a `#` is quoted: `color: "#ff0000"`.

- Comments may be a whole line or trail a value (`pop: 700  # note`).

- Blank lines contain no data, but a blank line between bindings is grouping the author created: the parser notes it as trivia (on the node below, or on the comment line below, so a blank between comment-only regions survives too) and the canonical formatter re-emits it (a run of blanks collapses to one; output never starts with one). Like comments, blanks play no part in merging, reads, or diagnostics.

- A whole-line comment attaches to the next line that binds a node - except when it is written **deeper** than that next line: then it belongs to the block it sits in, and it stays there at its own depth. Written at the level of the block's last binding it trails that binding - except at column zero after the last top-level binding, where it is the document's own tail comment instead: a top-level field's trailing comment and the document's are written identically, so a reload could not tell them apart. Written deeper still, it sits inside that binding's block - so a header whose children are all commented out keeps those comments indented under it rather than handing them back a level shallow. The same rule keeps indented tail-of-file comments with their block, and only top-level tail comments remain end-of-file orphans.

- A run of comments keeps the order it was written in. Once one comment in the run goes with the next binding, every later one does too, and a comment whose block would be written out ahead of the one before it goes where that one went. A comment written under the comment before it keeps that nesting, one level per step, so a commented-out block comes back in its shape. A malformed line kept as trivia keeps its place in the order but not the extra depth, since it holds its level on a reload.

- A `#` inside quotes is literal (`url: "http://h/#frag"`), and so is a `#` inside a raw block.

- Comments are never discarded: the parser keeps each one as trivia attached to the tree, and the canonical formatter re-emits them (see Canonical formatter). They play no part in merging, reads, or diagnostics.

- A selector on a file line is cut off by a `#` like anything else, so `a[#2].b: 1` in a file is a malformed line. The `[#N]` index is a path spelling for the API and the CLI; a file names an instance by its value.

### Whitespace, quoting, and reserved characters

- Whitespace around dots, colons, brackets, commas, and values is insignificant and trimmed. `a . b : "x"` == `a.b:"x"`.

- A carriage return counts as whitespace outside a raw block. It is trimmed at the edge of a name, a selector, a value, an element, a comment or a fence label, and kept in the middle of one. It is never indentation.

- Quotes are optional, and value quoting is a rule about **canonical output**, not about what input is legal. The parser takes everything after the colon (up to a comment) as the value, so `q: needs no quotes` loads with zero diagnostics and reads back verbatim - mid-text whitespace, `:`, `'`, `]`, `\`, even a `"`, all pass through. Bare, only a few characters keep their meaning: a `#` starts a comment, an unquoted `,` splits array elements, a value *beginning* with a quote opens a quoted element, and a value beginning with `[` is bracket-array spelling, which is refused (`E019`) rather than misread. Quote a value to cover those cases, or to keep leading/trailing whitespace (values are trimmed). The **formatter** is stricter than the parser: on output it quotes any value containing a **reserved character** - whitespace, `,` `:` `#` `"` `'` `[` `]` - so canonical form stays unambiguous. It also keeps the author's quotes on a plain string: a quoted element stays quoted through canonical output unless its text reads as one of SHCL's own data formats (int, float, bool, datetime). Quoting those is just spelling, since readers type the value either way, and they normalize to bare (`ver: "8"` comes back `ver: 8`). A number with a leading zero keeps its quotes, since the quotes say the zeros matter: `zip: "02134"` stays quoted, while bare `zip: 02134` stays bare. A plain string such as `hook: "fFoo()"` stays quoted, so quoting a value that a downstream language treats as special survives reformatting. (A `.` is reserved only in *field/path* position, not inside a value: `host: example.com` stays bare even in canonical output.)

- A **field name** is more restricted than a value: bare, it may contain only ASCII letters, digits, `-`, and `_`. A name that contains anything else - a space, a reserved character, or a **non-ASCII** character - must be quoted (`"Straße"`, `"user name"`). A bare name with such a character is a malformed line and is skipped; quote it to keep it.

- Either single or double quotes may wrap a string. Programming-quote rules apply: an unescaped `'` is literal inside `"..."` and vice-versa.

- A quoted piece opens with a quote as its first character and closes at the next matching quote, which has to be the last thing in the piece. Anywhere else a quote is an ordinary character: `c: say "hi" there` is one bare element. A piece that begins with a quote it never closes that way is read bare, quotes and all, and reported (`E017`); a comma or comment after it still ends it. One rule reads a name, a selector, a value element, a `SetLiteral` argument, a `--set` path and a schema path.

- Outermost quotes are removed on read; whitespace *inside* the quotes is preserved.

### Escapes

- Inside **double quotes** only, `\` triggers escape processing: `\t` (tab), `\n` (newline), `\\` (backslash), `\"`, `\'`, and `\uXXXX` or `\UXXXXXXXX` for a character by its hex code point, as in TOML (`\u00E9` is `é`). A `\u` or `\U` short of digits, or naming a surrogate or a value past U+10FFFF, is `E023`, and so is any other pair: the line is kept as written and binds nothing, since `"C:\work\new"` has already turned its `\n` into a newline by the time the `\w` shows it was a path. Single quotes are literal, and bare text never processes a backslash, so `path: C:\dir\file` and `a[C:\].b` are plain text. This is TOML's and YAML's rule. A double-quoted value that starts like a Windows path, a drive letter and `:\` or a leading `\\`, and holds a `\t` or `\n` escape, such as `"C:\temp"`, is `E024` and refused the same way, since a path almost never means a tab or a newline. Names, selector bodies and paths with no drive or share are left out. On output, a tab or line break in a value that starts like that is written `\u0009` or `\u000A`. On output, names and values write each character a reader could not see as a `\u` escape in double quotes, or `\U` past U+FFFF: a control with no short escape, the line and paragraph separators, the interlinear annotation marks U+FFF9 to U+FFFB, and each character Unicode 18.0 lists as `Default_Ignorable_Code_Point`, such as a zero-width space, a direction mark, embedding, override or isolate, a soft hyphen, the byte order mark, a Hangul filler or a tag character. The format fixes that list, so a later Unicode does not change the output. Three kinds stay as written where text needs them. The zero-width joiner and non-joiner always do, since emoji and several scripts need them. A variation selector does when the character before it is visible, meaning not a blank, a line break, a joiner or anything else in this list, so `❤️` keeps its selector while a run of selectors, which can contain hidden text, does not. The tags of a subdivision flag do too: U+1F3F4, then three to seven tag digits or lowercase tag letters, then the cancel tag U+E007F, which is how UTS #51 encodes the flags of England, Scotland and Wales. Any other tag is escaped. Comments and raw block bodies are written as they are.

- The same rule applies to a **field name**, so a name is identified by its text with escapes resolved, not by how it was written: `"a\"b"` and `'a"b'` are the same field. Canonical output picks one spelling and escapes it, and `QuoteSegment` produces that spelling, so any name round-trips. The as-authored accessor is the one place the source spelling is handed back (see the Accessor).

- A backslash is content in a bare or single-quoted value, so a Windows path or a regex needs no doubling. Multi-line verbatim content goes in a raw block.

- A value is always a single physical line; a newline *in* a value is written `\n`. (Multi-line verbatim content is a raw block instead.)

## Structure and hierarchy

Hierarchy is expressed two interchangeable ways; both produce identical trees.

### Indentation (block form)

- A line indented deeper than the previous line is its child. Indentation is **relative and stack-based**: any increase opens a level; a decrease must return to the exact column of an ancestor.

- A dedent to a column that matches no open level is a (recoverable) error - the line is diagnosed and skipped, the rest of the file continues. Like any skipped line it holds its column: what is written deeper is skipped with it (`E018`), a fence line there takes its whole body with it, and another line at the same bad column is refused the same way rather than binding one level up. It opens no level and closes none, so a later line that matches a level open before it binds there, as if the bad line were not there. A save writes the line back exactly as it was, and the lines under it too, when its indent holds a space: no level canonical output opens is written with one, so a reload refuses it the same way. An indent of tabs alone would bind there, and a line opening a raw block would take its body along, so those count as lost. Where a merge or an edit moves a kept line to a spot where it would bind as written, it is written as a comment instead, which reads the same.

- Indentation is tabs *or* spaces, and nothing detects which. A line's indent is compared with the open levels as text: a proper prefix of the open one is a child, byte-equal is a sibling, and anything else is `E012`. So a file that mixes the two inside one subtree can still load, with the nesting that comparison gives. Keep it uniform per file.

### Dot and bracket (inline form)

- `a.b.c: v` is exactly `a:` / (indent) `b:` / (indent) `c: v`. The `.` stands in for "newline + one deeper indent".

- `field[disc]` selects (or creates) the instance of `field` whose discriminator value is `disc`, then continues the path under it. `base[Boston].metrics.population: 700` is identical to writing `base: Boston` then nesting `metrics` then `population: 700`. A `[` right after the name, whitespace allowed, is a selector; a `[` after the colon starts the value (see `E019`). The same syntax is the Accessor's lookup syntax, so a path reads identically whether authored in a file or passed to `Get`. Matching is against the instance's **display form** (elements joined with `, `) in both places, so a selector also selects an array-valued instance (`base[Boston, MA]` finds `base: Boston, MA`); a new instance is created only when nothing matches. Escapes are resolved on **both** sides before comparing (inside double quotes, as everywhere), so the match is logical string against logical string: `["q\"uote"]` finds an instance written `'q"uote'`, whichever spelling either side used. A **quoted** selector is additionally **scalar-only**: it matches only a single-element value whose logical string equals the text, so `x["a, b"]` selects the scalar `x: "a, b"` and never the two-element list `x: a, b` - quoting is the escape here as everywhere else, and the bare spelling keeps the whole-display match. A selector is quoted only when a quote is its first character (after any whitespace inside the `[`) and the matching quote is the last thing before the `]`; anywhere else in a bare selector a quote is ordinary text, so `srv[O'Brien].port: 8080  # main` reads the port as `8080` and keeps the comment, and a quote the body opens and never closes is kept as text and reported (`E017`), as in a value. A bare selector runs to the first `]`, backslash or not; to embed a `]`, quote the discriminator.
	- A selector on the **last** path segment already supplies that instance's value (the discriminator), so a trailing value has nowhere to bind: `field[disc]: value` is grammar-legal but not a valid binding. The instance is still selected/created from the discriminator, and the trailing value is reported as an `error` diagnostic and dropped. Being an `error`, it fails a Strict load like any other. (A value is fine after a selector that is *not* last, e.g. `base[Boston].population: 700`, where it binds the deeper leaf.)

- Inline and block forms may be freely mixed; the parser normalizes both to the same tree.

### Merging and instances

- Occurrences with the same `(field-name, value)` merge; their children combine. This is how redundant paths collapse and how you add fields to an existing instance later in the file. Identity is on the *resolved* value, escapes applied, so `a: "q\"uote"` and `a: 'q"uote'` are one instance - the same text a `[value]` selector matches on, and the rule names follow too. Quoting is not part of it: `a: x` and `a: "x"` are one instance.

- Occurrences of a field with **different** values are distinct instances, kept in file order.

- A **repeated leaf line** (`tags: red` then `tags: blue`, no children) is two *instances* of `tags` - not the array `tags: red, blue`. Instances and arrays are separate mechanisms (see below).

- Field names are case-**insensitive**, folding **ASCII `A-Z`/`a-z` only** (`Metrics` == `metrics`). Non-ASCII characters in names never fold (`"Straße"` != `"STRASSE"`, `"İ"` != `"i"`) - full Unicode case folding is locale-trapped (Turkish dotless-I) and unportable across bindings, so it is deliberately excluded. (Such names must be quoted, per the quoting rule above; only their ASCII letters fold.) Discriminator **values** are case-**sensitive** after trimming and quote-stripping (`base: Chicago` and `base: chicago` are two instances).

## Values and types

**Typing is accessor-driven.** The parser stores every value as raw text and never guesses a type. The consumer knows its own schema and requests a type on read; the library coerces intelligently but safely, and reports problems without ever refusing to keep working. The value forms below are therefore *coercion targets recognized at read time*, not parse-time tags.

### Strings

Any value can be read as a string. On read: trim surrounding whitespace, strip the outermost quotes (keeping inner whitespace), and apply escapes. Quoting in the file is only *required* where a character would otherwise change meaning (see Whitespace, quoting, and reserved characters); the formatter quotes any reserved-character value on output. A multi-element array read as a single string yields its **canonical inline form** - elements minimally quoted, escapes intact, joined with `, ` - so the string re-parses to the same array; per-element unquoting and escapes belong to the array-of-strings read.

### Integers

Recognized (case-insensitive) when a value is read as an integer:

- Optional sign `+`/`-`, then digits. A leading zero is still decimal (`0644` -> 644), and a float read drops it too. Quote the value to keep the zeros for a string read through `fmt` (see Whitespace, quoting, and reserved characters).

- Thousands separators are accepted only inside quotes, since `,` is reserved bare (`"1,000"` -> 1000).

- Hexadecimal `0x...`, octal `0o...` and binary `0b...`, signed the same way (`0xFF` -> 255, `0o644` -> 420, `0b101` -> 5, `-0x10` -> -16).

- No digit-group underscores.

- No currency handling: `$1200` is a string, `BadType` as an integer. (The Loose strictness level re-admits a fixed leading-symbol list; see Strictness levels.)

### Floats

Recognized when a value is read as a float:

- Optional sign; digits with a leading or trailing dot allowed (`.5`, `5.`, `3.14`).

- Scientific exponent (`1e6`, `2.5E-3`).

- An integer is a valid float on read.

- The value must fit a double. A literal past its range (`1e400`) is `BadType`, since no double holds it and no setter could write it back; one below it (`1e-400`) reads as zero.

- No currency and no percent handling: `$3.14` and `50%` are strings, `BadType` as floats. (The Loose strictness level re-admits both; see Strictness levels.)

### Booleans

Recognized (case-insensitive) when a value is read as a boolean:

- True: `true`, `yes`, `on`, `1`.

- False: `false`, `no`, `off`, `0`.

- `1`/`0` are boolean only when a boolean is requested; otherwise they are integers.

- Anything else - including `t`, `y`, `enabled` - is `BadType`. (Strict narrows the set to `true`/`false` only; Loose widens it; see Strictness levels.)

### Dates and times

Recognized when a value is read as a date/time. The formats are a closed whitelist, each pinned by a conformance case; the admission rule is that a format cannot be misread - either the year comes first, or the month is a word. Anything else fails the read as a date with `BadType` (the value is still readable as a string). Matching a format is not enough: the value must then also be a real calendar date and clock time (`2026-02-30` or `25:00` is `BadType` despite matching a shape).

**Dates** - 4-digit year always. The internal delimiter is one of `-` `/` `.` and must be uniform within the date:

- `YYYY-MM-DD`: `2026-07-12`, `2026/07/12`, `2026.07.12`.

- `YYYYMMDD` - compact 8-digit.

- `DD Mon YYYY` - space or a delimiter between components: `12 Jul 2026`, `12-Jul-2026`, `12.July.2026`.

- `Mon DD YYYY` - likewise: `Jul 12 2026`, `Jul/12/2026`; in the space form a comma may follow the day (`Jul 12, 2026`), but only inside quotes, since a bare `,` splits array elements - `b: Jul 12, 2026` is the two-element array `Jul 12` and `2026`.

Month names are the fixed English set only - 3-letter abbreviation or full name, case-insensitive (`jan`, `Jan`, `JANUARY`), no trailing dot, no other languages (a locale table is how bindings drift).

**Times:**

- 24-hour `HH:MM` and `HH:MM:SS`.

- Optional fractional seconds after seconds, `.` delimiter, 1-9 digits (`14:30:05.123`) - unambiguous because it can only follow `HH:MM:SS`.

- 12-hour with mandatory minutes and mandatory meridiem: `H:MM AM` / `h:mm:ss pm`, case-insensitive, space before AM/PM optional (`2:30PM`); dotted `a.m.` is rejected.

**Timezone suffix** (optional, after any time): `Z` or `+`/`-``HH:MM`. Named zones (`EST`, `Europe/Paris`) are rejected - they require a timezone database, the ultimate parity killer.

**Combined:** `<date><sep><time>[zone]`. The separator is `T`, a single space, `_`, or one of `-` `/` `.` where it does not create ambiguity - the time's `:` ends the date reading, so `2026-07-12-14:30` and `20260712.14:30` are fine, and the separator need not match the date's internal delimiter. Date-only and time-only values are each valid alone. Without a zone suffix the value is a *local* (floating) date/time - each binding returns its idiomatic local type; it is never silently assumed UTC.

**Tolerances the whitelist allows,** because a hand-written config uses them and none of them can be misread: a one-digit hour, month or day where the shape has room for two (`9:30`, `2026-7-1`), a lower-case `z` or `t` where the shape says `Z` or `T`, whitespace before the meridiem or the zone (`14:30 Z`, `2:30 pm`), and a run of spaces where the combined form takes one. A stricter reading would turn working configs into `BadType` for no gain. What is still refused inside a value is a separator that changes the shape: `2026-07-12 T 14:30` and `Jul 12,2026` are `BadType`, and a comma-bearing `Mon DD, YYYY` has to be quoted, since a bare comma splits array elements.

**Rejected by decision, not omission:** `MM/DD/YYYY` and `DD/MM/YYYY` (the motivating ambiguity) and every other all-numeric date that is not year-first; 2-digit years; Unix epoch numbers (a consumer wanting epoch reads the integer and converts); fully-written-out prose dates ("July twelfth"). Because typing is accessor-driven, a bare 8-digit number is tried as `YYYYMMDD` only when a date is requested; otherwise `20260712` is the ordinary integer 20260712.

### Durations and sizes

A duration read gives whole milliseconds and a size read gives whole bytes, from spellings a person writes: `500ms`, `30s`, `1h 30m`, `2d`, `512MB`, `1.5 GiB`.

- Duration units are `ms`, `s`, `m`, `h` and `d`, lower case. Parts run largest unit first, each once, and blanks are allowed between a number and its unit and between parts, so `1h30m` and `1h 30m` read alike and `30m1h` is `BadType`.

- Size units are `B`, `KB`, `MB`, `GB`, `TB`, `KiB`, `MiB`, `GiB` and `TiB`, plus `kB`. Letter case is read, since `Mb` is megabits to most readers. `KiB` to `TiB` are powers of 1024. `KB` to `TB` are too, unless the read asks for decimal, which makes them powers of 1000.

- A number may have a fraction, and the result has to be whole: `1.5s` is 1500 ms, `0.5KiB` is 512 bytes, and `0.0001s` or `1.1KiB` is `BadType`. At most 18 digits after the point count. No sign, no exponent.

- A bare number takes its unit from the field name when the name ends in one after a `-` or `_`: `ms`, `sec`, `seconds`, `minutes`, `hours` or `days` for a duration, and `bytes`, `kb`, `mb`, `gb`, `tb`, `kib`, `mib`, `gib` or `tib` for a size, in any letter case. `timeout-ms: 250` and `cache_mb: 512` need nothing else. `min`, `m` and `s` are not name endings, since `retries-min` is a minimum and a trailing `s` is usually a plural, and a capitalized word (`timeoutMs`) is not a boundary, since names fold to lower case.

- Otherwise a bare number takes the unit the read passes, and with neither it is `BadType`. A unit in the value wins over the name's, and the load says so with the hint `H005`, as in `timeout-ms: 5s`.

- A duration is at most 9223372036854 ms, the range of Go's `time.Duration`, and a size fits a signed 64-bit integer, so every binding holds what another reads.

### Arrays

An array is multiple values in a **single cell**. It has two interchangeable spellings that produce the identical array; the canonical formatter emits the inline form.

**Inline (comma) form** - `tags: red, green, blue`. Splitting is on **unquoted** commas; each element is trimmed; quoted elements keep their internal commas and colons; a single value is a one-element array; an empty value is an empty array. **Empty elements are dropped** - a leading, doubled, or trailing comma contributes nothing (`red,,blue` is `[red, blue]`, `red,` is `[red]`), and a value that is only commas and whitespace (`,`, `, ,`, `,,,`) is the empty array. None of these is an error. To include a deliberately empty element, quote it (`red, "", blue`).

**Stacked (`*`) form** - an empty-valued field whose child lines are all `*`-marked is the same array, one element per line:

~~~text
sizes:
	* small
	* medium
	* "extra, large"
~~~

is exactly `sizes: small, medium, "extra, large"`. The rules that keep it unambiguous:

- The marker is `*` then at least one space, and the space is what separates `* small` (an element) from `*x: y`, which is `E013` - a `*` can never begin a field name. An element is a value like any other, so a colon in it is text: `* key: value` is the one string `key: value`, not a field. That is the YAML spelling of a list of objects, so a bare element written `name: value` or `name:` (no blank before the colon, a blank or the end after it) gets the hint `H003`. Quoting it says the string was meant; a list of objects is written as instances.

- **Uniform or nothing:** at the child indent, every line is a `*` element or none is; a mix is not a block array (each line is parsed as whatever it is, with a diagnostic if malformed).

- **One element per line**, each a single scalar typed on read exactly like an inline element; quote to embed a comma, or to keep an element written like a field binding from hinting (`* "Bond, James"`). A bare comma on an element line is an error, not a second element.

- The field opening the list has an **empty inline value**; a field may not have both an inline value and a `*` list.

- **Scalars only** (first cut): a `*` element is a value, not a sub-node, so it has no `field: value` children. Arrays *of objects* are expressed with instances and discriminators, not `*` lists. An element that joins a list still holds its column, with its field as that level: a line written deeper binds under the field, which is `E001`, and a line back at the element's column is the element's sibling.

Element typing is accessor-driven, so `GetStringArray`/`GetIntArray` read either spelling identically.

An array (either spelling) is **one cell holding many values** - not the same as repeating a field on separate lines, which makes distinct **instances** of that field. The two look alike only for a bare repeated leaf; once an instance has children the intent is plain. A parser **must** emit a hint diagnostic on a bare repeated leaf (`did you mean tags: red, blue?`) and never silently treats one form as the other. The hint is advisory (severity `hint`, not `error`) - repeated leaves are legal and are the instance mechanism working as designed; the diagnostic just makes the lookalike impossible to hit unknowingly.

### Coercion rules ("intelligent but safe")

- int -> float: always.

- float -> int: **`BadType`**. `3.5` read as an int is not silently rounded - silent lossy conversion is exactly what adopters distrust. It is still readable as a float or a string. (The Loose strictness level re-admits rounding; see Strictness levels.)

- any scalar -> string: always.

- to boolean: only from the boolean token set (never numeric-nonzero; `5` is not `true`).

- No other lossy, silent conversion. A value that cannot be coerced to the requested type yields the requested failure behavior (below), not a thrown error.

## Raw blocks

Line endings normalize on load: a line's entire trailing carriage-return run is removed, so CRLF and LF files parse identically. This is visible only inside a raw block, the one place content is kept untrimmed - a body line ending in CR has no spelling that survives a write, since the writer's own newline would turn it into a line ending. Elsewhere in a line a carriage return is whitespace: trimmed at the edge of a piece, kept in the middle of one.

A raw block embeds verbatim multi-line content - a DDL, a code snippet, a template - exempt from all SHCL rules (indentation, escapes, `#` comments, reserved characters). A file may contain any number of them.

- **Fenced, Markdown-style.** A block opens with a run of at least three identical fence characters, `` ``` `` or `~~~`. The opening run's character and length define the block; it closes at the first later line whose trimmed text is a run of the *same* character with length **>=** the opener. (So content may itself contain shorter fences.) An optional info-string may follow the opening fence (e.g. `~~~sql`); it is a free-form advisory label - captured and exposed to the consumer (a raw-block accessor returns it), but never interpreted by the parser. No values are reserved; a consumer may treat it as a content-type hint if it wants.

- **Binding: a fence is a value line for its parent field.** A fence line at child indent binds the block as its parent field's value. If the parent's value is empty, the block fills that instance's value; if the parent already has a value (or already received a block), the fence creates a **new instance** of the parent field with the block as its value - the same rule as a repeated leaf line. There is no separate "anonymous block" concept: blocks are instances, selected with the normal selectors (`notes[0]`, `notes[#2]`), and identical `(field-name, value)` blocks merge like any other instances. A block's identity is its content **plus its info-string** (a `sql` and a `python` block are distinct even with equal bodies); the fence character and length are spelling, not identity.

- **Same-line spelling:** the fence may also open on the field's own line (`path.name: ~~~sql` ... close fence). Identical tree; the child-indent spelling is canonical. The info-string rides the fence line in both spellings and is read as bare text, so a `#` ends it and opens the line's trailing comment, in either spelling: `~~~sql  # note` labels the block `sql`, and `db: ```c#` labels it `c`. A label cannot hold a `#`. Canonical output puts that comment on the field's own line.

- **Reading:** `Get`/`GetRaw` at the field path. A path resolving to several block instances reports `Multiple` on a single-value read, like any other field.

- **Indentation:** the block is visually nested at a child indent for clarity. The parser strips that nesting from each content line: the closing fence's own indentation (the opening line's, when the block never closes), and only as much of it as the line actually has. Relative internal indentation is preserved, and so is any indentation the body shares beyond the fence's, so a writer can store an indented snippet and read it back as given. Content `a` then `  b` under nesting yields the value `"a\n  b"`; a body whose every line sits two spaces past the fence keeps those two spaces. A whitespace-only line loses only what it shares with the nesting, so its spacing survives verbatim. The formatter emits the body at the fence's indent, which is exactly what the load strips back off.

~~~~text
config:
	ddl:
		~~~sql
		CREATE TABLE users (
			id   INTEGER PRIMARY KEY,
			name TEXT NOT NULL
		);
		~~~
	notes: ~~~
		free-form paragraph, kept verbatim,
		    including this deeper indent.
		~~~
~~~~

Both blocks bind as values: `GetRaw("config.ddl")` returns the DDL, `GetRaw("config.notes")` the paragraph. No wrapper, no index needed.

## Consumer API

The library is uniform across languages; each binding realizes the same concepts idiomatically. Aim for cross-language consistency with reasonable compromises, not for maxing out each language. Bindings are tiered by delivery commitment:

- **Tier 1**: the Rust reference implementation, and the `shcl` CLI built from it. These define conformance.

- **Tier 2**: Go, C (+ C++ veneer), Python - independent parsers, released when corpus-green.

- **Tier 3**: everything else (C#, Java (+ Kotlin), JavaScript, ...) - after v1.0, corpus-gated, designed-for from the start.

- **CLI wrappers**: Bash and PowerShell are thin wrappers around the `shcl` CLI, not independent parsers - they inherit conformance from Tier 1 for free.

The consumer-facing surface has two halves: the **Accessor** reads values (by lookup or traversal), and the **Writer** emits them.

Two of these are not separate implementations but a base core plus a thin **companion typed surface** - one parser, two call surfaces:

- **C++ over the C core**: the C source, its public header wrapped in `extern "C"`, plus a C++ interface (`Get<T>()` and the rest of the API over the typed C functions) that keeps the C one out of a caller's sight. C is not a strict subset of C++, so the shared header is kept C++-clean; only the `.c` need compile as C.

- **Kotlin over the Java core**: Kotlin calls the Java classes directly via JVM interop with no runtime work; the companion is a small extensions file giving `reified`-generic `get<T>()` instead of Java's `Class<T>` token form.

### The core call

The conceptual operation is **"get the value at `path`, coerced to a target type, with a default and an on-bad policy."** The critical portability rule: **the target type is expressed by the entry point (a typed variant or a compile-time generic), never by a runtime field in an options object.** This is the only shape that assigns straight into a strongly-typed variable with no consumer-side cast in *every* target language. A runtime `type` value cannot drive a static language's return type (Go, Rust, C, C++, C# all forbid it; Java can only via a `Class<T>` token), so we do not rely on it.

- **type**: chosen by which method/generic you call - `GetInt` / `GetFloat` / `GetBool` / `GetDateTime` / `GetString` / `GetRaw` and their array forms, `GetDuration` and `GetSize` with the unit a bare number takes (scalar only, and outside `Get<T>`), or a generic `Get<T>` where idiomatic (Rust always; Go/C++/C# optional). Realizations: Go typed methods or generics; Rust trait + turbofish/inference; C typed functions with out-param + status; C++ templates (`Get<T>`) over those C functions; C# explicit generics; Java `get(path, Integer.class, ...)`; Kotlin `reified`-generic `get<T>()` extensions over the Java methods; Python `get_int(...)` (or `get(..., type=int)` since it is dynamic); JS typed methods; PowerShell typed variable coercion on assign; POSIX sh a single command returning text (type flag only *validates*).

- **on-bad**: how to react to a bad/empty/missing/ambiguous value - `Error` (surface it), `Default` (substitute the default), or `Flag` (return the zero/empty value plus a soft indicator, never erroring).

In the libraries the mode is not a parameter: it is which tier you call, because two of the three modes already have a natural shape in every language and a third parameter would have been a runtime switch over them. The full tier (`Read*`) is `Flag` - the value, the status, and the raw text of the offending value, never erroring. The convenience tier (`Get*Or`) is `Default` - passing the fallback *is* choosing the mode. `Error` has no library form: a read that cannot reach a value is a normal outcome here rather than a fault, so the caller who wants a throw raises on the status themselves. When a binding's own `get_*` spelling has a must-exist mode (Python's, with no default passed), that is the binding's idiom, not a fourth mode.

The CLI is where the mode *is* a parameter, because a command line has no tiers to choose between: `--on-bad=error|default|flag`, default `flag`. It is also the only place per-slot substitution into a partially-resolved array exists (`--default` with an array read), for the same reason - a shell caller has no per-slot status to inspect.

This applies to **all** value access, not just arrays.

### Ergonomic tiers

The consumer is assumed to be a junior programmer in **every** binding, so each typed entry point comes in two tiers:

- **Convenience tier (the one the docs lead with).** One value, one baked-in fallback, one return, no status to inspect. Supplying the fallback *is* choosing `Default` on-bad mode, so an empty/missing/bad/ambiguous read yields the fallback and nothing throws. This is the call a beginner writes 90% of the time.

- **Full tier.** The same read exposing the status sentinel (and the raw text) for callers who must tell `Empty` from `NotFound` from `BadType`, or who want to raise on a status themselves. The `Empty`-vs-`NotFound` distinction is a deliberate feature, rare among config formats: `feature:` (written, empty) and no line at all are different answers, so a tri-state convention like "empty means explicitly disabled, absent means use the default" maps straight onto the status with no adapter. The raw text is the value span exactly as authored on its source line (comment stripped, trimmed) - `regex: ^\d{2,3}$` reads back byte-for-byte, commas and spacing included. A value with no one-line source spelling (writer-built, a stacked `*` list, a raw block) falls back to the display form.

The convenience tier has the same shape everywhere (a mandatory, call-site-visible fallback), which is precisely what defuses the silent-zero trap: a junior cannot accidentally read a `0`/`""` that was really empty or missing, because there is no convenience call without a stated fallback. It also has the same *name* everywhere: `_or` (`Or` in the languages that capitalize) means "with a fallback" in every binding, so a routine ported between two of them cannot keep the call name while changing which tier it lands on. Each binding's native value-or-default idiom still works where it has one - `get_int(path).unwrap_or(0)` in Rust, `get_int(path, default=0)` in Python - and the plain `get_*` spelling keeps whatever it already meant there.

| Language   | Convenience tier                             | Full tier
| :---       | :---                                         | :---
| Go         | `pop := doc.GetIntOr(path, 0)`               | `pop, st := doc.GetInt(path)`
| Rust       | `let pop = doc.get_int_or(path, 0);`         | `let r = doc.get_int(path); // Result<i64, Status>`
| C          | `int64_t pop = shcl_get_int_or(d, p, n, 0);` | `shcl_read_i64 r = shcl_read_int(d, p, n);`
| C++        | `auto pop = doc.get_or<int64_t>(path, 0);`   | `auto r = doc.get<int64_t>(path); // .value`
| C#         | `int pop = doc.GetIntOr(path, 0);`           | `var r = doc.GetInt(path); // .Value / .Status`
| Java       | `int pop = doc.getIntOr(path, 0);`           | `var r = doc.getInt(path); // .value() .status()`
| Kotlin     | `val pop = doc.getIntOr(path, 0)`            | `val r = doc.getInt(path)`
| Python     | `pop = doc.get_int_or(path, 0)`              | `r = doc.read_int(path)  # r.value, r.status`
| JS         | `const pop = doc.getIntOr(path, 0)`          | `const r = doc.getInt(path)  // {value, status}`
| PowerShell | `[int]$pop = $doc.GetIntOr($path, 0)`        | `$r = $doc.GetInt($path)  # .Value .Status`
| POSIX sh   | `pop=$(shcl get --int --default=0 f 'path')` | `shcl get --int f 'path'; status=$?`

The array, bool, float, datetime, string, raw, and raw-info forms follow the same two-tier pattern (`GetIntArrayOr`, `GetBoolOr`, `GetRawInfoOr`, ...); only the coercion target changes. Deliberate exception: C's convenience tier covers the value types only (`shcl_get_int`/`_float`/`_bool`, and the `_or` spelling of each) - string, raw, raw-info, datetime, and array reads hand back borrowed memory or lengths, which a value-or-default signature cannot express, so those use the full `shcl_read_*` tier; the C++ veneer copies every result, so its `get_or<T>` covers every `get<T>` type, arrays and datetimes included, with `get_raw_or` and `get_raw_info_or` beside it. The deviation is recorded in the style guide. The full tier is one representation of the `Flag`-mode status described above; the convenience tier is `Default` mode with the fallback the caller passed. For array reads the convenience fallback is the whole default array (returned unless the read is `Good`); per-slot substitution into a partially-resolved array is the full tier's per-slot status or the CLI's `--default`, not the convenience form.

### Status sentinels

Reads report one of: **Good**, **Empty** (present but no value), **NotFound** (path does not resolve), **BadType** (present but not coercible to the requested type), **Multiple** (path resolves to more than one instance and the call wanted one). `Empty` is informational, not a failure - the empty value is still returned. An empty binding is `Empty` to every read on it, the info-string read included: there is no block there, so there is nothing to mismatch a type against. The parser **never** refuses a legitimately reachable value because some *other* part of the file was malformed.

### Lookup and traversal

Two ways to read a document:

- **Lookup** (query) - get a single value at a path, the point read most config code wants (`doc.GetIntOr("base[Boston].metrics.population", 0)`). The core call and tiers above are all lookups.

- **Traversal** (scan) - consume the file as a whole: **materialize** it first (merge duplicate instances, order deterministically), then walk it. This is the mode for treating an SHCL file as a DDL or dumping every setting. The wildcards, `Instances`, and `Count` below are its building blocks.

Materialization is idempotent and order-stable, so two traversals of the same document walk it identically.

### Paths, selectors, and traversal

- A lookup path uses the same syntax and tolerances as the file: case-insensitive field names, dots to descend, `[sel]` to select an instance, whitespace ignored (`base [ Boston ] . population`).

- Selector forms: `[Boston]` (bare non-numeric = value), `[0]` (bare numeric = index), `["2020"]` (quoted = value even if numeric), `[#2]` (explicit index).

- **Choosing `[#i]` vs `[value]` when mapping entities** (a consumer walking instances into its own model): prefer `Count` + `[#i]`. By-value selection matches the display form, so it misreads an entity whose name happens to be numeric (`[2020]` is an index; quote it to force a value match) and collapses two same-named entities into one answer (`Multiple`). A scalar written `"a, b"` and the two-element list `a, b` are distinguishable by spelling - the quoted selector `["a, b"]` is scalar-only, the bare one matches the display form of either - but iteration still wants position, not values. Index selection is positional, total, and collision-free.

- `field[*]` is a wildcard returning every instance's value as an array: `GetIntArray("base[*].metrics.population")`. The result is positionally aligned to the instances - one slot per instance, in file order. If an instance lacks the sub-path, its slot is kept (status `NotFound`, with the zero value); slots are never silently dropped, so indices stay aligned with `Instances(field)`/`Count(field)`. A legitimately absent sub-path is not malformed, so it produces no diagnostic.
	- Every array read has one status per slot alongside the values (a slot list on the result). Each slot reads like a scalar of the target type: `Good`, `Empty` (empty value), `NotFound` (missing sub-path), `BadType` (uncoercible, raw block, or array where one scalar is expected), or `Multiple` (sub-path ambiguous within that instance). The read's aggregate status is the worst slot, ordered `Good` < `Empty` < `NotFound` < `BadType` < `Multiple`, so a partial miss can never report `Good`.
	- `Instances` on a wildcard path keeps unresolved slots in the enumeration as empty strings, preserving index alignment with the read and with `Count` (which counts slots).
	- The libraries substitute nothing per slot: the convenience tier's fallback is the whole array, returned only when the read is `Good`. Per-slot substitution is the CLI's `--default`, because a shell caller has no slot list to inspect.

- A bare `*` in **name position** (`indicators.*.period`) is the name wildcard: it matches every child field regardless of name, one slot per child in file order, with the same per-slot status, `Instances`, `Count`, and per-slot substitution behavior as `field[*]` above. The two compose (`server[*].*`, `*.port`): a wildcard after a wildcard flattens, so the inner slots join the outer run and the result is one slot per resolved leaf rather than one per outer instance. `Remove` on a wildcard path removes every node the path reaches, the nodes behind a slot a read calls `Multiple` included, and `Exists` answers over that same list. A name wildcard takes no selector of its own (`*[x]` is not a path), and it is a query construct only: a binding line never accepts it, the Writer's setters refuse it (`WriteReason` = `Wildcard`), and a field literally named `*` is written and addressed quoted (`"*"`), which stays a literal name everywhere.

- `Instances(field)` and `Count(field)` enumerate instances by value or index. The library hands back the values as they are; the CLI's `instances` prints a value holding a line break in its quoted escaped spelling, since its output is one line per instance and a consumer splits on newlines. `get --array` and `get --slots` do the same for each element or slot; a plain `get` prints the value as it is, since the whole output is that one value.

- `Children(path)` lists the child field names under a path, in file order, **duplicates included** - the "what keys are in this section?" question a deduplicated path enumeration cannot answer, and the natural way to read an open (map-shaped) section. The empty path enumerates the top level. A path with several instances lists the children of each in turn, the way a dotted path reaches all of them. Names come back as stored; `QuoteSegment` makes one splice-safe in a path.

- `Line(path)` returns the 1-based source line of the binding at a path (0 when the path does not resolve to exactly one node, or the node was writer-built), so a consumer check the schema cannot express can still cite the line. `Lines(path)` is its plural: every binding's line in file order (a repeated field, the case that most wants a citable line, yields them all), with unresolved wildcard slots kept as 0 so indices keep matching `Count`, and a miss the empty list. The read result includes the same `line` directly, alongside a `quoted` flag: true when the read's single scalar element was quoted in the source. A value a setter wrote counts as quoted when a save would quote it, so the flag and any read that turns on it, such as quoted thousands, answer the same before and after the save. Quoting is thereby a real escape for downstream languages - `a: @null` and `a: "@null"` read the same text but are distinguishable - and the escape survives `fmt`, since canonical output keeps the quotes on a quoted plain string (see Whitespace, quoting, and reserved characters). (Deviation: the C read structs stay value+status; C and the C++ veneer answer the same two questions with `shcl_line`/`shcl_lines` and `shcl_quoted`, which is false for anything that is not one scalar element.) (Deviation: C also has `shcl_reads_release`, which gives back the memory every read handed out - the other three reclaim it through their runtime, so they need no such call.)

- `AuthoredName(path)` (each binding's spelling) returns the field name at a path exactly as the author wrote it - case unfolded, outer quotes stripped - so a message can echo `SYMBOLS` when the file said `SYMBOLS` even though the stored (and canonical) name is the folded `symbols`. Escape sequences are resolved on a name the same way they are on a value, so `"a\"b"` and `'a"b'` are two spellings of one field rather than two fields - the two halves of the language agree on what a quoted string means. This call is the exception that proves it: it hands back the **source** spelling, escapes as written, which is the point of an as-authored accessor. Canonical output picks one spelling for the name and escapes it (`\\`, `\"`, `\t`, `\n`), so it reads back as the same name. Resolution mirrors `Line(path)`: the empty string when the path does not resolve to exactly one node. Merged instances keep the first binding's spelling, matching `Line` and comment attachment; a writer-built node keeps the spelling the setter's path used.

- `Paths()` enumerates every field path in the document, in file order, deduplicated. A segment that is not a bare name is emitted quoted and escaped - the same spelling the canonical formatter writes - so every returned path is a valid lookup path and nothing in the document is hidden from the enumeration.

- `InstancePaths()` is `Paths()` one instance at a time: every binding's path in file order, with `[#i]` on each segment whose name its parent repeats, so each path reads exactly one node and a repeated block is walked instance by instance.

- `QuoteSegment(name)` (each binding's spelling of it) quotes one segment for splicing into a lookup path: a bare name passes through, anything else comes back quoted and escaped - the same spelling the canonical formatter writes, and the exact inverse of the name parse, so any name at all can be spliced. Building a path from user-typed text without it is path injection - a dotted name reads as nesting.

- An ambiguous single-value read (path resolves to many instances) reports `Multiple`; narrow it with a selector until exactly one remains.

### Diagnostics and writing

- Loading also yields a list of structured **diagnostics** (line number + severity + a stable **code** + a prose message) for every skipped or repaired line, which the consumer may inspect or ignore. Severity is `error` (a line was skipped or repaired) or `hint` (legal input that looks like a common mistake, e.g. the repeated-leaf array hint). The split matters for Strict mode: only `error` diagnostics fail a strict load. A failed strict load still hands back the parsed document alongside the failure (each binding's failure shape includes both the diagnostics list and the document - recover-and-continue means the tree is what a Standard load would have kept), and the failure's message names the first few diagnostics rather than a bare count.
	- A **content-malformed line** (one the parser cannot read at all: a bad field name, a `*` not followed by a space, bracket text after the colon) is diagnosed AND **retained** as inert trivia: canonical output re-emits it in place, where it re-diagnoses identically and can never read as a live binding - so a hand-typo in a config survives the consumer loading, editing, and writing the file back. (The one exception is a line beginning with a BOM, which the file-start strip would rewrite; it counts as lost instead.) A line the parser can read but cannot **apply** - an unusable selector, a line past the depth cap, a dropped list element - cannot be retained safely (re-emitted, it could parse as live content somewhere else) and instead counts into **`LostCount()`** (each binding's spelling): how many lines or values were dropped that canonical output cannot re-emit. It also counts a retained line that an edit took where the rule for that edit keeps it (`design.md`, Kept lines under edits). Nonzero means writing the document back deletes hand-written content, which is why the file tier's save refuses then (below). A line at an indent that matches no open level is kept as written when that indent holds a space, since the indent alone keeps it inert, and lost otherwise (see Structure). A retained line holds its level, so what is written under it is skipped with it (`E018`), except a field line refused for its value alone (`E019`, `E023` in a value, `E024`): its path is fine, so the lines under it load as they would under the same path with nothing after the colon. Such a field exists only when one of them binds, and canonical output then writes the kept line in place of the bare `name:` line. Which of those each code is - bound, retained, dropped - is one table in `design.md` (Load outcomes), and the count and the held level follow from it.
	- The **code** (`E001..`, `H001..`) is the portable contract - the same kind of problem gets the same code in every binding. The prose **message** is a free, per-binding voice and is not part of the contract. The `shcl check` CLI reflects this: it prints `line N: severity: CODE` to stdout (compared across bindings) and the prose message to stderr (dropped by the differential check). The last stdout line is a summary: `ok (N diagnostic(s))`, `failed: N diagnostic(s), M error(s)`, or at `--strictness=strict` with an error present `strict load failed: N diagnostic(s)`. Every diagnostic line starts with `line `, and the summary never does, so a script keeps the diagnostics by that prefix. `check` exits nonzero when any `error` diagnostic is present - not only on a strict load failure - so a CI gate on `check` catches dropped lines at any strictness.
	- A load lists its diagnostics in line order, and two on one line in the order they were found. Under a diagnostic cap the ones listed are the first found, and the `E022` entry still ends the list. `check --schema` and the one-shot load put validation's after them, in the order under Schema validation. Under `--layer` each file's list is printed on its own, lowest layer first; a merge does not combine them.
	- The load-time codes, so a CI gate can key on them (validation adds the `V###` range, tabled under Schema validation):

| Code | Meaning
| :--: | :--
| `E001` | field line under a parent already holding stacked `*` list elements (field kept)
| `E002` | value after a last-segment selector (`a.b[X]: v`) - the value is ignored
| `E003` | selector names an instance that does not exist: `a[5].b` where there is one `a`. From a file only the bare `[5]` reaches it, since a `#` there opens a comment and `a[#5].b` is `E014`; an index selects an existing instance by position and never creates one, which is why a binding line should select by value. On a write path the same situation comes back as the `NoSuchIndex` write reason rather than as a diagnostic
| `E004` | wildcard selector on a binding line (wildcards are query-only)
| `E005` | unterminated raw block (closing fence never found)
| `E006` | raw-block fence with no parent field to bind to
| `E007` | stacked `*` list element with no parent field
| `E008` | stacked `*` list element under a parent with field children (element dropped)
| `E009` | empty stacked `*` list element
| `E010` | bare comma in a stacked `*` list element (one element per line)
| `E011` | stacked `*` element for a field that already has a value (element ignored)
| `E012` | indentation matches no open level; kept as written when the indent holds a space and the line opens no raw block, lost otherwise
| `E013` | malformed `*` line (`*` not followed by a space); line skipped, and what is written under it with it
| `E014` | malformed line skipped (with the reason named in the message)
| `E015` | missing colon (repaired as an empty value)
| `E016` | nesting deeper than the 512-level cap (line skipped)
| `E017` | a value element or a selector body opens a quote it never closes with the matching quote as its last character - the piece is read bare, quotes and all; a comma or comment after it still ends it. In a field name the same typo is `E014`, since a bare name cannot have a quote
| `E018` | line written under a line that was skipped (indented beneath it); skipped with it, so a skipped line's block never re-parents one level up. A skipped field line whose value opens a raw block takes the body with it, here and under `E012` and `E021`, so the body is never read as lines. A `*` element line whose element was dropped (`E007` to `E011`, `E021`) is a skipped line for this purpose. Under a kept `E012` line it is kept as written too
| `E019` | a value beginning with `[`, the way JSON, TOML and YAML write an array (`ports: [80, 443]`). A `[` after the colon is never a selector, and reading the text without its brackets would bake a changed value in, so the line is kept verbatim like any other malformed line: it binds nothing, a read on it is `NotFound`, and nothing is counted lost. The lines under it still load, under the field with no value. An array is written without brackets (`ports: 80, 443`)
| `E020` | node cap exceeded (fires only under a caller-supplied cap, see Limits): the parse stopped, and the unparsed remainder counts as lost content
| `E021` | array longer than the caller-supplied element cap (see Limits); the line is skipped whole rather than truncated to a value the author never wrote
| `E022` | the diagnostics list was cut at the caller-supplied cap (see Limits): this one entry ends it and counts what was not listed. An error when any unlisted one was, so a scan for errors still finds one and a Strict load still fails; a hint otherwise
| `E023` | an escape in double quotes that is none of the seven (`\t`, `\n`, `\\`, `\"`, `\'`, `\uXXXX`, `\UXXXXXXXX`), or a `\u` or `\U` that names no character, in a value, a quoted name or a selector body. The line is kept verbatim like any other malformed line: it binds nothing, a read on it is `NotFound`, and nothing is counted lost. When only the value holds the pair, the lines under it still load, under the field with no value. A lookup path or a `SetLiteral` text holding one is refused. A raw block's info string is not escape text
| `E024` | a double-quoted value that starts like a Windows path, a drive letter and `:\` or a leading `\\`, and holds a `\t` or `\n` escape, as in `"C:\temp"`. Kept verbatim like `E023`: it binds nothing, a read on it is `NotFound`, nothing is counted lost, and the lines under it still load. A `SetLiteral` text holding one is refused. Single quotes or bare text keep each backslash, and so does doubling it. Names and selector bodies are not checked
| `H001` | repeated bare leaf (array written as repeated lines) - the mandatory hint
| `H002` | a binding merged with a non-adjacent earlier one (same name and value combine); legal, but only the parser can see it happened, so it says so - the prose names the earlier line. Every merged level under a hinted re-open reports, each naming its own earlier line, so a consumer filtering the hints sees the whole combination, not just its outermost frame; a schema can disavow it per section with `reopen:` (see Schema validation)
| `H003` | a bare stacked `*` element written like a field binding (`* name: value` or `* name:`); legal, and read as one string, but it is how YAML writes a list of objects, so the parser says so. Quoting the element says the string was meant
| `H005` | a value in another unit than the one its field name ends in, as `timeout-ms: 5s` or `cache-mb: 2GB`. Legal, and a unit in the value wins over the one the name gives a bare number, but the two disagreeing is usually a slip. Only a name ending in a duration or size unit after a `-` or `_` is looked at, and only a value that reads as that kind

- **Limits**: nesting depth is capped at 512 levels below the document root. A line that would bind a node deeper than the cap is an `error` (`E016`) and is skipped; the Writer likewise refuses to create a deeper path. The cap is what makes any loadable document safe to format, merge, and copy in every binding - depth-linear recursion can never outrun a thread stack - and 512 is far beyond any hand-authored nesting.
	- The other two limits are the caller's, through `ParseLimited` (each binding's spelling), for input the consumer does not control. A document amplifies to many times its byte size in memory, so bounding the bytes read cannot bound what a load allocates; only counting what the parse builds can. A node cap stops the parse once a line takes the count past it - one `E020`, and the unparsed remainder counts as lost, so a later save refuses rather than writing a silently truncated file. An element cap refuses any line whose array would hold more elements (`E021`); the line is skipped whole, never truncated. A fence line's info string is split on commas the same way, so a fence past the cap is refused too, and its block is skipped with it rather than read as live lines. A diagnostic cap bounds the list itself, since a document of nothing but bad lines costs a diagnostic per line: the first that many are listed, and one `E022` ends the list with a count of the rest. 0 disables a cap, which makes the call the plain strictness parse. All three are parse-time caps: what a program writes into a document is its own arithmetic.

- The **Writer** handles the reverse of the Accessor: emit values, defaults, and comment sections, and canonicalize a file (see below). It mirrors the Accessor's typed-entry-point shape - a `Set<T>` per type (`SetInt`/`SetString`/.../`SetRaw`) and their array forms - so a programmatic value comes out as canonical text with no consumer-side formatting.
	- Each setter is the exact inverse of the matching read: `SetString` re-quotes and escapes so the value reads back verbatim; `SetFloat`/`SetInt` emit the same canonical number text the reader accepts; `SetDateTime` stores the canonical spelling; `SetRaw` picks a fence long enough that the content cannot close it early and trims the info-string the way a fence line reads it back.
	- **A setter writes only what reads back.** It builds its text through the emitter, hands that to the tokenizer, and refuses unless what comes back is the value it was given, so no setter decides for itself what a quote, a `#`, a comma or a carriage return means. What that refuses follows from the lexical rules rather than from a list: an info-string holding a line break or a `#` (the fence line would read the `#` as opening a comment), a raw body line ending in a carriage return (the load takes the trailing run off every line), a comment holding a line break (a comment is one line, and keeping the first would drop the rest silently). The typed setters keep their own render-and-parse-back on top of it, since a value has to read back as its type and not merely as the same text: `SetFloat` fails on an infinity or a NaN, `SetDateTime` on a value the reader would not parse back to the same fields (a month of 13, a fraction with no seconds, an offset past a day, an empty value). A refused write binds nothing, leaves the document byte-identical, and returns false.
	- A writer-created **top-level** node has the blank-line grouping a hand-written file would have (one blank line between top-level sections; never as the first line), so writer output and hand-authored examples agree on shape.
	- A **set** creates the path (intermediate nodes as needed) and replaces the value at the leaf; a `[value]`/`[#index]` selector on the path targets a specific instance (a `[value]` selector creates the instance if absent).
	- Companions round out the surface: `Set<T>Default` writes only when the path does not already resolve (the "emit defaults" half; every typed setter has one, `SetRaw` and `SetLiteral` included), and where it does resolve writes nothing but still refuses what `Set<T>` would refuse, the value included; `SetLiteral` takes the value as **syntax** rather than data - it reads its argument the way the parser reads the half of a line after the colon, so a caller holding value text writes `80, 443` as a two-element array without having to know its shape first (whatever a file line gives with that text is what gets stored, so a trailing blank comes off and a `#` outside quotes ends the value; what it refuses is what a file reports as an error, since a setter has no diagnostic to report it with - a line break, which no file line can hold, a piece that opens a quote it never closes (`E017`), text beginning with `[`, which a file refuses as `E019`, and a bad escape in double quotes (`E023`); text a file line would not read as a value at all - a fence opener - is stored as the string it gives, since the call reads a value half, not a line); `Exists` reports presence; `SetComment` attaches a leading comment line (creating an empty node so a section can be annotated), placing a node's blank separator line above the comment so the comment sits against its node, and refusing text that holds a line break; `ClearComments` takes every comment line above a node back off, so a comment can be replaced rather than added to (a comment on the node's own line stays, and so does a line kept for being malformed); `Comments` reads those same lines, each from its `#` on, so a program can tell a comment it wrote from one a user put there; and `Remove` deletes the node(s) at a path.
	- Every setter reports whether the write applied: an unusable path (a wildcard, a `[#index]` instance that does not exist, a value part, or a path past the depth cap) applies nothing, no half-created intermediates, and reports failure, which the CLI reports as exit 1 rather than silently printing the untouched document. `WriteReason(path)` (each binding's spelling) names which of those a failed write hit - `Writable`, `BadPath`, `ValueInPath`, `Wildcard`, `NoSuchIndex`, or `TooDeep` - by running the same validation the setters run, creating nothing, so a consumer's error message need not guess.
	- Dropping a setter's answer is the one write failure that leaves no trace (the save that follows writes a document missing the edit and reports success), so the reference marks the setters `#[must_use]`; the other bindings have no equivalent and say it in their documentation instead.
	- A write that makes a node collide with a same-named sibling under the in-file merge rule folds the pair the way a reparse would, so written output is a formatter fixpoint like any other canonical output.
	- On the CLI, `set --write` (like `fmt --write`) rewrites FILE in place through a temp-file-and-rename in the same directory, so an interrupted write can never truncate the config it rewrites. `set --write` also **creates** FILE when nothing is at the path yet, so a first write needs no `touch` beforehand; `fmt --write` has nothing to format and still reports it missing, and a FILE that exists but cannot be read is an error either way, never something to quietly write over. A created file starts out as the info block `init` writes (see "Schema-driven generation"), so a new config says what format it is; the edits go above it, separated from it by one blank line as in generated output, and `--no-banner` leaves it out. A file that already exists is never given one. A file that turns up at the path while the command runs, during the wait for ops on stdin for example, is left as it is, and the write fails at exit 8. So does a FILE whose bytes changed after the command read them: `--write` reads it again just before the save, so an edit made meanwhile is never reverted.
	- The rename publishes a new file, so FILE is resolved through symlinks first: a linked-in config is written through, not replaced; a link to a file that does not exist yet gets that file created where it points; and a symlink cycle is an error - too many levels of symbolic links - with nothing written. The file's mode is kept, setuid, setgid and sticky bits included, as an editor's rewrite would keep it.
	- The temp file is created exclusively, so an existing file or symlink under the name it wants is never written through, and it is born private, so a private config is never briefly readable to anyone else; the target's mode goes on after the data is written and synced, immediately before the publish, so the kernel's clearing of setuid and setgid on write cannot strip what was copied.
	- A path that names a directory rather than a file - it ends in a separator, or its last component is `.` or `..` - is refused: a document is not a directory, and the platforms disagreed about whether such a path even reached the filesystem. So is a link whose own text ends that way.
	- Only a regular file is replaced. A directory, a FIFO, a socket, a device or anything else that is not a regular file is refused at exit 8, since a rename would swap it for a regular file. `--write` asks before it reads FILE, so a FIFO is not drained.

	- Any other hard link to the old file keeps the old content. That is inherent to publishing a new file in the old one's place, and so is everything else a file has outside its permission bits: POSIX ACLs, extended attributes and the SELinux label among them, and on Windows a file's own explicit ACEs and alternate data streams. The owner is not kept either: the new file belongs to whoever ran the save, which only shows when that is not the old file's owner. The group is kept, best effort, so a config a service reads through its group keeps that read; a saver who is not in the old group leaves its own group on the file, as it did before. In a sticky directory such as `/tmp` the rename is refused for a file the saver does not own, and the save reports it.
	- A read-only file is rewritten, since the rename needs the directory rather than the file, and the new file comes back read-only; Windows clears the attribute for the publish and sets it again after, so the platforms agree. Windows closes most of that gap where it can: the publish goes through `ReplaceFile`, which copies the destination's ACLs, security attributes and named streams onto the replacement, and falls back to a plain replacing move when the file is being created or the merge cannot be done. Neither keeps the basic attributes, so hidden and system are re-applied after the publish along with read-only. `ReplaceFile` moves the old file to `.NAME.bakPID.N` beside it before it moves the new one in. If the second move fails, the old file is moved back. If that fails too, nothing is at the path, and the save keeps both files and fails with an error that names them: the old file at the backup name and the new text at the temp name, `.NAME.tmpPID.N`. The C binding reports `errno` only, so its header gives the names instead. A publish that is refused is tried five times, 50 ms apart, since a scanner or an indexer reading the fresh temp file blocks it for a moment. Over an existing file, the temp file is created with that file's DACL, so the new text is never open to anyone the file shuts out, and a fallback move keeps the DACL too. When the DACL cannot be read, the temp file takes the directory's, as a new file would. On POSIX the containing directory is synced after the rename, as the file is before it, so a power cut cannot lose the publish itself and leave the old content in place.
	- The CLI prints the load's diagnostics to stderr on every subcommand that loads a file, whether or not `--write` is given, and an in-place write **refuses**, exiting 7, while `LostCount()` is nonzero - the same `SaveFile` gate a consumer program gets (see the file tier below); `--lossy` is the CLI's spelling of the override. Without the gate a recovered load would delete the line it could not re-emit at exit 0 with nothing on either stream.

### File tier

Every consumer that persists a config re-implements the same load/save dance, and file lifecycle is where those consumers' bugs live - so the library has a small optional file tier rather than leaving each caller to fumble it independently.

- `LoadFile(path)` (and `LoadFileWith(path, strictness)`) reads and parses in one call and never fails: the document always comes back usable (empty when the file could not be read), paired with a **file status** that separates the four cases a hand-rolled load path otherwise confuses - `Clean` (parsed, no error diagnostics; hints allowed), `HadErrors` (parsed, error diagnostics present - recover-and-continue means the document is still worth having), `NotFound` (no file at the path), and `Unreadable` (present but unreadable: permissions, a directory, bad encoding). A strict-failing file reports `HadErrors` with the recovered document, never a throw.

- `ReadFile(path, maxBytes)` (each binding's spelling) is the load's read half on its own: the file's text, or the same status saying why not, with a file past `maxBytes` reported `Unreadable` (0 is no cap); `LoadFile` is this plus a parse. It is there for the consumer that needs the exact bytes it last saw - to tell its own save coming back as a change notification from somebody else's edit - or a bound on how much it will read before a parse; either one used to mean keeping a hand-rolled read beside the library.

- `SaveFile(doc, path)` writes the document's canonical text through the same temp-file-and-rename mechanics the CLI's `--write` uses (described above), so an interrupted save can never truncate the config it rewrites; the CLIs call this same code, so the two cannot drift.

- A second save **keeps the lines** an edit did not touch. `ParseKeepLines` and `LoadFileKeepLines` (each binding's spelling) load a document that holds on to its text, and `ToTextKeepLines` and `SaveFileKeepLines` write it back: each line no edit touched byte for byte, a changed value into its own line with the name, spacing and comment around it left alone, and a new line at the indent of the lines around it. A changed line keeps its own line ending, and a new one ends the way most of the file's lines do, so a CRLF file stays CRLF. A tie goes to LF. The text has to load back as the edited document, with no error the file did not already have. When it would not, as after a merge, or a child added under a flat dotted line, the save writes the canonical form instead and reports which one it wrote. A document the text was not kept for, a merged one included, always gets the canonical form. A line the load dropped comes back as written when the lines are kept, so the refusal below applies only when the save writes the canonical form. `set` saves like this; `fmt` and `SaveFile` write the canonical form.

- A save that **creates** a file has no mode to preserve, so the file gets the `0666 & ~umask` an ordinary create would produce - the same bits the user's editor or shell redirect would have given it. An existing file keeps the permission bits it already had, which is the case the temp file is born private for.

- The save **refuses** when the load dropped content it would silently delete (`LostCount() > 0` - see Diagnostics); `SaveFileLossy` (each binding's spelling) is the explicit override, so deleting a user's unparsable-but-unretainable line is always the caller's stated choice, never an accident. Retained content-malformed lines do not trip the gate - they survive the save.

- A refusal and a failed write are **separate values**, never two spellings of one message, because they need different handling (a refusal is the caller's to reverse, a write failure is the disk's answer), and the gate answers before any I/O, so an unwritable path still reports the refusal. Each binding uses its own channel for that: Rust `SaveError::Refused`/`SaveError::Io`, Go a `*SaveRefused` error (`errors.As`), C `SHCL_SAVE_REFUSED`/`SHCL_SAVE_FAILED` against `SHCL_SAVE_OK`, and Python **raises** `SaveRefused`/`SaveFailed` rather than returning a message, since a returned message lets the obvious spelling - the call on a line of its own - report success while doing nothing.

- The tier is a companion, not core: C guards it behind `SHCL_NO_FILE_IO` so an embedded consumer can compile the library with no file I/O at all, and the C status enum is `shcl_file_status` with the load's status as an out-parameter (may be NULL).

## Canonical formatter

The formatter normalizes structure only - it cannot know value types, so it never rewrites value text (no `.5` -> `0.5`). Two normalizations to know about: field names are case-insensitive, and the canonical spelling is the folded (ASCII-lowercase) one - `Max-Upload-MB:` comes back `max-upload-mb:` from `fmt`, matching how every read and merge already treats the name; and a blank line an author put between bindings survives (one blank; runs collapse), so grouped configs stay grouped through `fmt --write`. It loads at the requested strictness like every other operation; a strict-failing document formats nothing (the load failure is the result). `fmt --check` prints nothing and exits 6 when a rewrite would change the file, 0 when it would not, so a tree can be checked for non-canonical files without diffing each one; it cannot be combined with `--write`. It asks the save gate first, so a file whose load dropped a line exits 7 the way `fmt --write` does, rather than promising a rewrite that would be refused.

- Block (indented) form, tabs for indentation.

- Preserve file/insertion order of instances and fields (so index-based access stays stable).

- Collapse and merge redundant sections and paths.

- Preserve comments as attached trivia. A whole-line comment attaches to the node bound by the next non-comment line and re-emits just above that node's line, at its indent, plus one tab for each level it sits under the comment before it (see Comments); a trailing comment stays on its line, two spaces before the `#`. Comment text is never rewritten.

- When instances merge, their comments concatenate in encounter order; a second trailing comment moves to the lines above (a canonical line has room for one). Comments among stacked-list elements ride the list's field line. A malformed or misplaced line kept among them keeps the list stacked, with the line where it sat, so a fix typed into it stays in the list; without one the list is written inline. A stacked list after an empty instance of its name is written inline anyway, since its bare header would merge into that instance on re-read, and its kept lines go above it. Top-level comments after the last binding line re-emit at the end of the output, unindented; indented ones stay with their block (see Comments).

- Quote a value when a reserved character requires it (minimal quoting), and keep the author's quotes on a plain string; quoted data-format values (int, float, bool, datetime) normalize to bare.

- Leave scalar text exactly as authored; raw blocks are re-emitted verbatim. A block value canonicalizes to the child-indent spelling - bare `name:`, fence (with its info-string) on the next line at child indent - one field line per block instance.

- Two narrow exceptions keep round-trips exact. If an *earlier* instance of the same field under the same parent is empty, the child-indent header line would merge into it on re-read and the fence would fill that instance - so the formatter emits that block in the same-line spelling instead. And an info-string that *starts with* the fence character gets one space after the fence, so it cannot lengthen the fence run on re-read. A block emitted in the same-line spelling also moves any trailing comment to the lines above - after the fence it could read as part of the info-string on re-read.

## Schema validation

A schema is an ordinary SHCL file: a flat list of instances of one field named `field`, each whose *value* is a document path and whose children are the constraints on it. Document paths appear in value position, never as field names, so the schema vocabulary can never collide with a document's own field names. `Validate(doc, schemaDoc)` returns the same structured diagnostics loading produces; a one-shot `LoadAndValidate(text, schemaText, strictness)` parses and validates in one call, handing back the document with one combined diagnostics list (parse first, then validation - the order `check --schema` prints) so half the errors cannot vanish because a caller merged only one of the two lists, and it never fails: a strict-failing document comes back as the document plus its diagnostics, with `ErrorCount()` as the "did this file have errors?" predicate; the `shcl check --schema SCHEMA FILE` CLI appends them to `check`'s normal output under the same stdout/exit contract, at strict as well: `check` writes nothing, so a strict-failing load still gets validated and still reports what the schema found. The summary line stays `strict load failed`. No grammar change is involved: the schema vocabulary is interpreted by the validator, the parser knows nothing of it.

~~~shcl
field: server.port
	type: int
	required: yes
	min: 1
	max: 65535

field: "server[*].host"
	type: string
~~~

A path containing a bracket selector must be quoted (a bare selector's scan ends at the first `]`); the canonical formatter applies that quoting itself. Two `field` instances with the same path merge by the language's own merge rule, so constraints for one path can be written in one place or several.

The constraint vocabulary is closed - nothing joins it without a spec change:

| Key | Value | Meaning
| :-- | :-- | :--
| `type` | `int` `float` `bool` `string` `datetime` `raw` `duration` `size`, or `<scalar>-array` (no `raw-array`, `duration-array` or `size-array`) | every value at the path must coerce to this type, at the *document's* strictness
| `unit` | a unit spelling | `duration` and `size` only: the unit a bare number takes when the field name gives none
| `decimal` | boolean | `size` only: `KB` to `TB` are powers of 1000
| `required` | boolean | the path must resolve (see wildcard rule below)
| `allowed` | inline array | closed set of permitted **element** values, compared in the coerced space of `type`. Every element of a multi-element value has to be in the set, so `allowed: "x, y, z"` is one element and admits none of the three in `c: x, y, z` even though `GetString` returns the joined form. For `datetime` the coerced space is the moment: `12:00:00Z`, `12:00:00+00:00` and `12:00:00-00:00` are one value, and so are `12:00:00` and `12:00:00.0`, while a value with no zone is local and matches no zoned one. `raw`, `duration` and `size` take no `allowed`; bound a duration or size with `min` and `max`
| `min` / `max` | number, or a duration or size | inclusive bounds, `int`/`float`/`duration`/`size` kinds only, a duration or size read the way the document's value is: its own unit, then the unit the field name ends in, then the schema's `unit`, so `min: 100` on `hold-ms` is 100 ms. A path ending in `*` has no one name, so there a bare bound needs `unit`. Checked per element on arrays. A `min` above its `max` admits nothing, so it is a schema fault and the range is dropped (the field keeps its other constraints) rather than every value being told off twice
| `repeat` | one integer (exact) or two (min, max) | bounds the instance count at the path, per resolution context
| `inherits` | fragment name | the subtree at this path has the named fragment's shape (see Fragments below)
| `reopen` | boolean | the section at this path is meant to be written in parts; `true` disavows `H002` for its leaf name (validation itself ignores it)
| `default` / `desc` | any | reserved for the schema-driven generator; validation ignores them

Semantics:

- The schema file itself always loads at Standard, and its constraint values (booleans, numbers, the `allowed` set) are read at Standard - a schema is a program artifact, not user data. The *document's* values coerce at the document's strictness, so `type: int` against `3.5` passes at Loose (which rounds) and fails at Standard.

- An empty value passes `type`, `allowed`, `min`, and `max` (present-but-no-value is what `Empty` means everywhere else) and counts as present for `required`.

- On a path with no wildcard, `required` means at least one instance resolves. Through a wildcard, it is a per-instance rule - `server[*].port` requires a port under *each* server - and is vacuously satisfied when no instances exist (require the parent separately if it must exist).

- A `repeat` upper bound above 1 also **disavows `H001`** for that field: repetition is that field's instance mechanism by declaration, so the repeated-bare-leaf hint would be a structural false positive there. `check --schema` (and the one-shot load-and-validate) drops those hints, matched by leaf name; plain `check` without a schema keeps them.

- `reopen: true` **disavows `H002`** the same way: a section declared as meant-to-be-re-opened merges by design, so the merge hint would train its users to ignore hints. Same mechanics as the `H001` disavowal - dropped at `check --schema` and the one-shot, matched by leaf name, kept by plain `check`. A bad `reopen` value is a `V092` schema fault, so a typo cannot silently disavow nothing.

- `repeat` and `required` evaluate per *resolution context*: the whole document for a plain path, each enclosing instance for the part of a path after a wildcard. So `field: server` + `repeat: 1, 10` bounds the server count, while `field: "server[*].port"` + `repeat: 1` means exactly one port per server.

- An **open section** - any child name, each shaped the same - is declared with the name wildcard: `field: indicators.*.period` + `required: yes` requires an int `period` under *each* child of `indicators`, whatever the child is called. A `*` segment resolves every child (any name) and splits contexts per child exactly as `[*]` splits per instance, so `required`/`repeat` after it are per-child rules, vacuously satisfied when there are no children. For the unknown-field sweep, a `*` matches any one name at its position (prefixes legal as usual), so an open section's children are never unknown while anything outside the declared shape still is; "did you mean" suggestions do not reach below a `*` (there is no fixed sibling list to suggest from). A `repeat` above 1 on a `*` leaf disavows no `H001` (there is no single leaf name to disavow).

- Quoting in a schema path works at two levels, and the difference matters. The outer quotes are ordinary SHCL string quotes around the value, and a path needs them whenever it contains a reserved character - which `[` is, so every selector path is written `field: "server[*].host"`. Those outer quotes are removed before the path is read, so wildcards inside a quoted path are still wildcards: `field: "server[*].*.port"` composes both kinds. To make a segment a *literal* name, quote the segment itself, inside the value: `field: "\"*\""` is a field actually named `*`, and `field: "\"*.example.com\""` is a field actually named `*.example.com`. Take care with the difference: `field: "*.example.com"` is not that field, it is an open section - a `*` matching every top-level name, each expected to have an `example.com` child - which legalizes every top-level name for the unknown-field sweep. When a literal name is what is meant, quote the segment.

- **Fragments** name a reusable shape. A top-level `fragment: <name>` instance holds ordinary `field:` instances whose paths are *relative*; `inherits: <name>` on any field mounts that shape at the field's path. So "this subtree has the shape of that one" is one line, and a shape used at two paths is two mounts.
	- A **recursive** structure (a layout block holding layout blocks) is a fragment whose field `inherits` itself. Self- and mutual references are legal, with **no depth limit**: validation expands a mount only where the document actually has nodes, and every mount descends at least one level of a finite document, so termination is structural and cost is proportional to the document, never the schema's unfolding.
	- Semantics: a mounted fragment's fields evaluate per resolved node at the mount path (that node is the context - `required`/`repeat` inside the fragment anchor to it, like the segment after a wildcard), running right after the node's own checks in fragment order, depth-first. The mount's field keeps its own constraints (they apply to the mount node itself), and other `field:` paths through the mount point compose freely.
	- For the unknown-field sweep, a chain that walks a mount continues against the fragment's fields (prefixes legal as usual); suggestions do not descend mounts. A `repeat` above 1 on a fragment field disavows `H001` by leaf name exactly as a top-level one does.
	- Two `fragment` instances with the same name merge by the language's own merge rule (their fields combine); `field` is the only key legal inside a fragment.
	- Faults: a nameless or malformed declaration is `V094`, and `inherits` naming no declared fragment is `V095` - both schema faults, reported like the rest of `V09x` (a mount naming a missing or dropped fragment checks nothing at the mount). Two declarations of one name are not one of them: the parse merges them before the validator sees them, and reports `H002`. Validation checks each fragment at each node once, so a shape mounted by two paths that both reach the same node costs one pass, not two.
	- Generation has to lay every path out flat rather than follow the document, so it does bound the unfolding: a mount chain reaching the nesting cap is noted like a re-entering one instead of expanded, a path deeper than a document may nest goes to the trailing note, and a schema whose mounts multiply past the field ceiling is a `V096` fault rather than an output nothing can hold.

- A field in the document that no schema path covers is an unknown field. Legality is by name chain (selectors ignored): every schema path legalizes its own chain and every prefix of it. Only the topmost unknown node is diagnosed; its subtree is skipped. The "did you mean" suggestion lives in the prose message only, never the code - edit-distance output is not parity-pinnable.

- All validation diagnostics are `error` severity, and their order is deterministic: schema faults in schema order first; then per schema instance in schema order - `required`, `repeat`, then per resolved node in file order `type`, `allowed`, `min`, `max` (a node failing `type` skips its remaining checks) - then unknown fields in document order. The unknown-field sweep runs too, unless a fault cost the schema a path spelling - a `field:` whose path is unreadable, or a mount naming no declared fragment; only those can turn declared fields into false unknowns, so only they make the sweep skip rather than misfire. A key-level fault (a broken `type:`, `min:`, ...) keeps its entry, whose path still legalizes its name chain.

Diagnostic codes ride the existing structure (line, severity, stable code, prose) in a `V###` range disjoint from the parser's `E###`/`H###`. Line numbers are document lines; line 0 means document scope (nothing was written); through a wildcard, a per-instance `required` miss gives the enclosing instance's line:

| Code | Meaning | Line
| :-- | :-- | :--
| `V001` | unknown field | the topmost unknown node
| `V002` | required path missing | 0, or the enclosing instance under a wildcard
| `V003` | wrong type | the node
| `V004` | value not in the allowed set | the node (first offending element)
| `V005` / `V006` | below `min` / above `max` | the node (first offending element)
| `V007` | instance count out of `repeat` bounds | 0, or the enclosing instance under a wildcard
| `V090` | unknown schema key | schema file
| `V091` | unknown schema type name | schema file
| `V092` | bad schema constraint value (also: `min`/`max` without a numeric `type`, `allowed` with `type: raw`) | schema file
| `V093` | bad schema path | schema file
| `V094` | bad fragment declaration (no name, or a non-`field` key inside) | schema file
| `V095` | `inherits` names no declared fragment | schema file
| `V096` | schema expands to more fields than generation allows | 0 (a document line space, not a schema one)
| `V097` | generated output does not load, or fails the schema that produced it (a `default` outside its own field's constraints, say), or a must-exist path nothing can generate | 0 (a document line space, not a schema one)
| `V099` | schema failed to load (schema had error diagnostics) | 0

A schema fault (`V090`+) does not silence the rest of the result: the constraints that parsed cleanly still check the document (a broken key drops that key, a broken `field:` drops that field), so a typo in one constraint cannot hide a real violation of another. The unknown-field sweep needs the complete declared vocabulary of *names*, and a key-level fault keeps its entry's path - so the sweep still runs; it turns off only when a fault cost a path spelling outright (an unreadable `field:` path, or a mount naming no declared fragment). Generation (`shcl init`) still requires a fault-free schema - a partial starter config would be worse than an error. `check --schema` folds validation diagnostics into `check`'s existing output: same `line N: severity: CODE` stdout lines, the same line plus its prose on stderr, same summary line and exit-6-on-any-error rule. Both streams include the code; only stdout is the contract. A `V090`-`V093` line number is a schema-file line (the table above says which); the stderr prose writes those as `schema line N` so the two number spaces cannot be confused, while the compared stdout keeps the uniform `line N` shape - the code already names the space.

A config file can name its own schema on a comment line written like the info block's `Format` line, so `check` and an editor find it without being told.

- For example:

	~~~shcl
	##    Schema   ./app.schema.shcl
	port: 8080
	~~~

- The line is `##    Schema   ` then a path or a URL, at the start of a line or after its indent, anywhere in the file. The formatter indents a comment to the field below it, so an indented line counts the same. The same goes for the `Format` line. The first such line wins, and one inside a raw body is that block's content. `SchemaRef` returns what it names, and `SCHEMA_LINE_HEAD` is its spelling, for a program writing one.

- `check` without `--schema` validates against it, reading a relative path from the config file's directory, or from the working directory when the file is stdin. A `--schema` on the command line wins. A schema the line names that cannot be read fails the check the way a missing `--schema` file does, with exit 8. So does one that is not a regular file, such as a device or a FIFO, and on Windows a path starting with two slashes or backslashes, or with `\??\`, which names a network share or a device. So does a file over 16 MiB.

- A URL is for editors. `check` does not fetch one, and says so on stderr, since a check that reads the network because of a line in a file is not one to run unattended.

- `SetBanner` rewrites the info block and keeps a Schema line that sits in it.

## Layered loading

Composing a config from defaults, then a site file, then a user file, is `merge` applied as a left fold: `Load(defaults, site, user)` overlays each later document on the accumulation of the earlier ones, so the last file wins. `merge(base, over)` takes two already-parsed documents and overlays `over` (higher priority) onto `base`; it is a library operation, no grammar change.

The overlay rule, per parent scope:

- A **leaf** name present in `over` (its `over`-side nodes all have no children - a scalar, an inline array, or a raw block) **replaces** every `base` child of that name, spliced in at the first replaced position - provided the `base` children of that name are themselves all childless (or absent). This is real override: a later `port: 9090` wins over an earlier `port: 8080`, a later `tags: green` replaces the earlier repeated-leaf list `tags: red` / `tags: blue` wholesale (override, not append), and a bare `port:` clears the leaf.

- A childless `over` node whose `base`-side name group has any **container** instance is a **wrapper mention**, not a leaf override: it merges by `(field-name, value)` like any container instance, so a matching instance is left untouched and an unmatched one is appended as a new empty instance. A bare section header (`server:`, or `server: web1` with no body) in a higher layer therefore never deletes the base subtree beneath it - the same choice JSON Merge Patch and kustomize make. The deliberate cost: there is no way to blank a whole section from a higher layer; an explicit deletion spelling may be added post-1.0 if one proves necessary.

- A name with any **container** instance (a node with children) in `over` merges instance-by-instance: each `over` instance matches a `base` instance by `(field-name, value)` - the same key the in-file merge rule uses - and recurses; an unmatched `over` instance is appended in file order. So two layers' children under `server: web1` combine, while a new `server: web3` is added.

- One exception to matching by `(field-name, value)`: an unmatched `over` instance with a **raw block** fills a same-named **empty** `base` binding rather than appending beside it, which is what a fence line does to an empty binding inside a single file. Without it a merge and a parse of the two layers run together would disagree about the same two lines, and the merged document would not be a formatter fixpoint. Only a raw block fills; an unmatched valued instance still appends, matching what the parser does with the same two lines.

Five more, all deliberate and all the same in every binding. `Line(path)` after a merge cites the line of whichever file the node came from, in that file's own numbering and with nothing to say which file it was. A **leaf override drops the base leaf's comments and its blank-line grouping**, where the in-file fold concatenates them - the override replaces the binding, and the comment above it described the value being replaced. A line the base kept as written for being malformed moves onto the replacement, except one the load already writes as a comment because it would bind as written: that one goes with the comments, as a reload of the saved base would see it. Merging a document over an equal one therefore **doubles a container's leading comments**, since container instances match and combine theirs. `lost` **sums across layers**, so a consumer that merges and then saves to a fresh path is refused for a line some layer dropped - the merged document is missing that content whatever it is written to. And a **strict failure in a lower layer** ends the fold there, so only that layer's diagnostics are reported.

Three things a consumer folding layers itself should know. **The fold is not associative**: with a base `p:` holding `q: 1`, then `p: 2`, then a bare `p:`, `(A+B)+C` keeps `p: 2` beside the section (the bare header is a wrapper mention against a container), while `A+(B+C)` first folds the bare header over the leaf and the section then absorbs it, so `p: 2` is gone. A pre-merged upper pair is not interchangeable with the CLI's left fold. **A merged document keeps the base's strictness**, so a value from a stricter layer reads with the base's coercion rules. **A merge is not free**: it costs a pass over the base's touched scopes plus an index rebuild on the next read, and a replaced node is kept until the document is dropped - a 40000-key base with a three-line overlay is single-digit to sixty milliseconds depending on the binding, and five hundred merges of an eight-node overlay grow the process about a megabyte.

Comment trivia rides with the nodes that have it, and the merged document is a formatter fixpoint like any other. Where an `over` instance matches a `base` one, the `base` node survives and takes on the `over` node's comments under the in-file rule: leading comments concatenate in layer order, and the first trailing comment wins. End-of-file comments are kept once each, so a footer several layers share is not repeated per layer. `over`'s content is copied into `base`, so `base` stays valid after `over` is released.

On the CLI, every loading subcommand (`get`, `fmt`, `count`, `instances`, `children`, `paths`, `set`) takes repeated `--layer=FILE` and repeated `--set=PATH=VALUE`. `check` does not: its diagnostics are inherently single-file.

- Precedence runs low to high: the `--layer` files in listed order, then the positional `FILE`, then the `--set` values. `fmt` with layers prints the merged canonical document, so it doubles as the merge command.

- A `--set` is a Writer edit, not a merged layer. It targets the first matching instance, or creates the path. On a repeated leaf that means it edits one instance, where a real top-layer file would replace the whole same-named group wholesale. Put it in a `--layer` file when whole-group override is the intent.

- That distinction decides persistence. On `set`, a `--set` edits the document rather than layering over it, so `set --write` writes those edits back. Giving any `--set` also means no write-ops script is read from stdin.

- Everywhere else a `--set` stays ephemeral and `--write` refuses it. `--write` refuses `--layer` everywhere, for the same reason: folding a lower layer permanently into the top file is the opposite of what layering is for.

- `--lossy` only means anything alongside `--write`. On its own it would read as protection against something the command never did, so it is a usage error anywhere else, like every other option a subcommand does not take.

- Two options that ask for different answers are a usage error whichever order they came in, and the message names both. Two different type options on `get` are one case, one value option given two different values the other. Nothing resolves last-wins, since the answer would then depend on typing order with nothing said about it. Repeating an option with the same value competes with nothing and is allowed, and `--layer` and `--set` are ordered lists, so they repeat by design.

- A FILE of `-` is stdin on every subcommand, `set` included. When the edits arrive as options, no ops script is read, so stdin has the document there as it does everywhere else. Only when stdin is the ops script does `-` mean an empty base instead. It cannot be both, and reading neither is what the two used to combine to: a piped document thrown away at exit 0.

- A `--set` value goes in as **data**. Its type still follows the text (`workers=8` is an integer), but a comma or quote inside it is content, so `ports=80, 443` stores one quoted string.

- `--set-literal=PATH=TEXT` is the same option with the other reading. `TEXT` goes in as **value syntax**, the way a file writes it, so that same text stores a two-element array. `--remove=PATH`, `--set-default=PATH=VALUE` and `--set-literal-default=PATH=TEXT` complete the edit options, and all five share one ordered list, so the last one to touch a path wins. On the read side, `--slots` prints an array read's per-slot statuses beside its values.

Environment-variable mapping is deliberately not provided. The env namespace and its naming convention belong to the consuming program, which can map env vars onto `--set` itself.

## Schema-driven generation

`generate(schema, no_banner)` turns a schema into a commented, typed starter config - the schema's `desc`/`default` vocabulary (reserved by the validator, ignored there) put to work. `shcl init --schema=FILE` prints it to stdout.

The output, per schema field in schema order:

- A `desc` line becomes a leading `## ` comment.

- A generated annotation line summarizes the type and constraints, ASCII only: `## <type>[, one of: v1, v2, ...][, <lo>-<hi> | >= <lo> | <= <hi>][, repeat <lo>[-<hi>]][, required]`. An untyped field shows `any`. Allowed values and numeric bounds are rendered in the type's canonical text (the same float formatter reads use); a newline inside a rendered value is escaped to `\n` so it cannot break out of the comment. This annotation is part of the generated file, so it is a byte-for-byte cross-binding contract, not free prose.

- `desc` is prose and takes the whole value: a comma in a sentence makes it several elements, and all of them go in the comment, as written. A `default` that has no spelling on a value line - a raw block, or any default under `type: raw` - is a `V092` schema fault at that line rather than a silently dropped value.

- The field line itself: fields that **must exist** (`required`, or a `repeat` lower bound of 1 or more) are live (`path: <default>`, or `path:` with an empty value when there is no `default`; a quoted plain-string `default` keeps its quotes, and one containing a newline is written in its quoted escaped spelling); **optional** fields are the same line commented out (`# path: ...`), so the starter is valid and minimal as-is. Prose the generator writes has `##` and a commented-out setting has a single `# `, so the two read apart at a glance. That is a convention for what SHCL writes, not a rule: to the language both are ordinary comments, and a config author may write a comment with any number of `#` and any spacing around it.

- A must-exist field whose path contains a wildcard is generated in dotted form (the wildcard dropped, targeting the instance it materializes) when some other live line materializes the wildcard's parent - otherwise the very instance that line creates would fail the schema. When that parent's line has a value, a dotted child would name the empty-valued instance instead of the one the line made, so any line under a valued live parent selects it by the value: `srv: web` is followed by `srv[web].port:`, not `srv.port:`. The selector body is the first spelling a file line reads back as that value: a single element as it was written, then bare, then quoted; an array only bare, as its elements joined. A body or a name with a real line break is written in its escaped spelling, since a file line holds one line and the as-written spelling would be two. An array that has no bare spelling, one holding a `]` say, makes the child a `V097` fault. When two fields would write one line, the first is written, and its value is the instance the children select. A commented line under a commented valued parent selects it the same way, so uncommenting both still names one instance. A live line under a commented parent stays dotted, since selecting by value would make the optional parent exist. Remaining wildcard paths, and paths that cannot be written at all (a name-wildcard `*` segment has no name to drop to; `[#N]` needs a pre-existing instance and its `#` would start a comment), are collected into a trailing `## Paths needing an instance name (not generated):` comment block, one `##   <path>   <type>` per line. A path that must exist and cannot be written at all is a `V097` fault instead, since the trailing block can never satisfy it - except a `repeat` lower bound of 2 or more, which is the documented shortfall below. Every such path gets its own fault line, naming the path and why it cannot be written, so one run says how much of the schema is unreachable rather than one path at a time.

- A path whose last segment selects by value is written without that selector when its field has a `default`, because a value after a last-segment selector is ignored (`E002`). `field: "env[prod]"` with `default: prod` generates `env: prod`, which is the line that makes the instance the path selects. Two such fields selecting different values are two instances, so `env[prod]` and `env[dev]` write both lines. Whether the default names that instance is left to validation, so a default naming another one is a `V097` fault. With no `default` the selector line is written as it is (`flag[on]:`). A commented-out line follows the same rule.

- After the last field, and after the trailing block if there is one, a footer names the format and points at its spec, separated from what precedes it by one blank line:

	~~~text
	##
	## This config file format is SHCL.
	## "Simple Hierarchical Config Language"
	##    Format   3
	##    Home     https://github.com/yottacore/shcl
	##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md
	##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.
	##
	~~~

	These bytes are part of the generated file, so they are a cross-binding contract like the annotation line. The `Legal` line names SHCL as its subject: it says nothing about the config it sits in. The footer is written unless the caller asks for it to be left out - `no_banner` on the library call, `--no-banner` on `init` - and the flag is negative so a caller that says nothing gets the footer. Every binding exposes the same bytes as a constant (`GEN_BANNER`, `GenBanner` in Go, `SHCL_GEN_BANNER` in C), so a program writing its own config file writes the block without keeping a second copy of it. `SetBanner` puts the block at the end of a document and takes an old one off first, from the footer or from above any field but the first, where a field added below it by hand puts it, found by its first text line rather than its links, so a program that refreshes the block on each save never ends up with two. The block runs from the lone `##` above that line to the next one, so the file's own `##` comments next to it stay, even written right against it. The `Format` line `migrate` stamps comes off too, with the note under it. The footer is the only difference the flag makes: everything above it is byte-for-byte identical either way. The `Syntax` link points at the spec as tagged by the first release of the format major (`v3.0.0-beta1` for format 3), so a file keeps pointing at the rules it was written for. It changes only when the `Format` line does.

A fragment mount is expanded inline - the fragment's fields generate under the mount's path, depth-first, `desc`/`default` and all - until a fragment would re-enter itself; that cycle-cut mount joins the trailing comment block with the fragment's name in the type column, so a recursive schema generates one full level and says what belongs deeper. Paths are emitted in the schema's flat dotted/bracket form (mirroring the schema's own shape), not expanded to block form, and in the schema's own spelling when a file line reads that spelling back as the same path. A lookup path takes spellings a file line does not, such as a `#` in a selector body, and those are rendered from the path instead, the body quoted; the result is valid SHCL that loads with no error diagnostics and **validates clean against the schema that produced it** - with one documented exception: a `repeat` lower bound of 2+ cannot be auto-satisfied (identical generated lines would merge into one instance), so such a field is emitted live once and validation reports the shortfall. That promise is checked against the finished text rather than assumed, both its load and its validation. A generated line that does not load, or a schema whose own `default` breaks its field's constraints (including a default that does not name the instance its path selects), fails generation with `V097` instead of producing a starter config that fails the first `check --schema`. That holds for an optional field too, with or without a `default`: its line is written commented, so it is read back on its own and its value checked against its field, since uncommenting it should not break the file. A schema fault (V09x) makes generation fail the same way validation does; `init` then exits 6 like `check --schema` reporting the same fault (exit 1 stays a usage error, and a schema that cannot be read is exit 8). `generate` is a library call in every binding (plus the C++ veneer); `init` reads no document, so it takes no `--layer`/`--set`. Generated output has no size ceiling of its own beyond the depth cap: paths are emitted flat, so a chain of mounts writes each level's whole path on every line below it and the output grows with the square of the depth. 21 KB of schema mounting itself 511 levels deep generates 270 KB. Time is linear in the output and the depth cap bounds both, so nothing runs away - but a starter config is not always small.

## Error handling philosophy

SHCL never bails on a whole file for one bad line (at Loose and Standard strictness; Strict turns any `error` diagnostic into a load failure by request - see Strictness levels). The parser skips or best-effort-repairs the offending line, emits a diagnostic, and continues. The Accessor never errors when it can unambiguously reach a value; malformed content before or after a clean section does not poison that section. Errors are reserved for genuine ambiguity (or raised by the caller off the status the full tier hands back).

One repair is defined concretely, because it is the common "figure it out" case: a line that is a **well-formed field path with no colon and nothing after it** (`base[Boston].metrics.population`, no value) is repaired to that path with an **empty value** - the obvious intent - with a diagnostic emitted. This is deliberately narrow. A line whose colon is missing but which is *not* a clean path - a bareword then whitespace then another token (`square-miles 300`) - is genuinely ambiguous (is `300` a value, or part of a name that cannot legally contain a space?), so it is skipped with a diagnostic rather than guessed.

## Strictness levels

One knob, set once per document at load time, governs how forgiving the whole surface is: **`Loose` / `Standard` / `Strict`** (CLI shorthand `--strictness=loose|standard|strict` or `1|2|3`). The default is `Standard` - everything specified elsewhere in this document describes `Standard` behavior. The level is per-document, never per-call: it is a property of how an application treats its config, not of one read. It composes with, and is orthogonal to, the on-bad policy: strictness decides *whether* a value coerces; the tier you call - or the CLI's `--on-bad` - decides what happens when it does not.

The bundles are normative - a binding implements exactly this table:

| Behavior | Loose (1) | Standard (2, default) | Strict (3)
| :-- | :-- | :-- | :--
| Malformed line at load | skip + `error` diagnostic | skip + `error` diagnostic | **load fails**
| Colon-less-path repair | applied + `error` diagnostic | applied + `error` diagnostic | **load fails**
| `hint` diagnostics (e.g. repeated-leaf) | emitted | emitted | emitted (never fail a load)
| float -> int | rounds half away from zero (`3.5` -> 4, `-2.5` -> -3) | `BadType` | `BadType`
| Leading currency symbol -> number | stripped | `BadType` | `BadType`
| `50%` -> float | 0.5 | `BadType` | `BadType`
| Boolean token set | Standard set plus `t`/`f`, `y`/`n`, `enable(d)`/`disable(d)` | `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0` | `true`/`false` only

Notes:

- **Loose** re-admits the forgiving conversions cut from Standard, as a closed list - nothing joins it without a spec change. The currency rule is: a single leading symbol from exactly these codepoints is stripped (`$ ¢ £ ¤ ¥ ₩ ₪ ₫ € ₭ ₮ ₱ ₲ ₴ ₹ ₺ ₼ ₽ ₾ ₿`), along with any whitespace after it, so `$ 1200` reads the same as `$1200`; multi-letter codes (`USD`, `kr`) are not stripped, and there is no trailing form. A `%` float is the fraction, so a Loose `GetInt` on `50%` rounds 0.5 -> 1 - never special-cased to the pre-`%` number, so `GetInt` and `GetFloat` cannot disagree.

- **Strict** is the "fail loudly" mode: any `error` diagnostic aborts the load (the never-bail philosophy above describes Loose and Standard). Reads are unchanged except the boolean set. `hint` diagnostics never fail a load at any level - repeated leaves are legal instances, and failing legal input would break the data model.

- Every level is corpus-pinned: conformance reads have an optional level column, so a binding cannot drift on any bundle row.

## Migrating from 2.x

The 3.0 lexical rules are smaller than 2.x's, so a file written for 2.x can read differently under them. `migrate FILE` rewrites such a file so the current parser reads the tree 2.x read. It touches only the spellings the two rule sets disagree on, and comments, blank lines, raw bodies and layout come through as written. `--write` saves the result through the same save gate `fmt --write` uses, and says how many lines it rewrote. When a line was rewritten it first copies the original beside the file, with `_old_v2` before the extension, so `config.shcl` keeps its old bytes in `config_old_v2.shcl`. It refuses at exit 8 when that name is taken, and writes nothing. `--check` prints nothing, names each line a rewrite would change as `FILE:LINE`, and exits 6 when there is one, so a directory of files can be checked without diffing each one. It asks the save gate first, so a file `--write` would refuse is exit 7 rather than 6.

Most of the change is loud. A quote that never closes is `E017`, bracket text after a colon is `E019`, a bad escape in double quotes is `E023`, a Windows path in double quotes with a `\t` or `\n` escape is `E024`, and a line the current rules cannot read at all is a malformed line. A file with one of those says so the first time it is loaded.

One change is quiet. A `\u` or `\U` with its hex digits in double quotes was kept as written in 2.x and names a character now, so `"\u0041"` read as six characters then and reads as `A`. `migrate` doubles the backslash in a 2.x file, and asks for `--from-2x` when the file does not say which rules wrote it.

The comment rule did not change. A `#` outside quotes opened a comment in 2.x and still does, so values and comments read the same on both sides.

Which file it is looking at is the one thing `migrate` cannot read off the text. `p: 'C:\temp'` is written the same way under both rule sets and means two different things, so rewriting a 3.0 file would change what it says. The info block has a `Format` line naming the format's major, and that is what decides. A file with it has nothing to migrate. One inside a raw body is that block's content and does not count. The two rule sets can put the blocks in different places, so a line naming this format counts outside the blocks the current parser finds, and an older one outside the blocks 2.x found. Where a file names more than one format, the highest decides. A file without it keeps those spellings as written and exits 7, unless `--from-2x` says it really is 2.x. Lines inside a raw body under one rule set and not the other read two ways as well, and go the same way. After `'C:\': ~~~` a block opens now, but in 2.x the backslash escaped the quote and none opened. A file `migrate` rewrites is stamped with that line, plus a note saying where it came from, so a second run has the answer the first one did not. The two lines end the way most of the file's lines do, a tie going to LF, as a line-keeping save's new lines do. Only `migrate` reads the line; every other command treats it as the comment it is. A program asks the same question with `FormatVersion` (each binding's spelling), and `MigrateUnstamped` is the rewrite without the stamp, for a program that writes the info block itself.

Two lines 2.x bound have no 3.0 spelling to move to, so nothing binds them now: bracket text after the colon, and a value that starts like a Windows path and held a line break. A tab in such a value goes in as it is, which both rule sets read alike, but a line break has no such spelling, so the value is written the way 2.x read it and is `E024`. `migrate` exits 7 on either rather than reporting success, so a scripted migration can tell "migrated" from "gave up"; `--lossy` accepts the loss on a rewrite.

What `migrate` promises, and what it does not:

- The output reads as the input read under 2.x. That is the whole point, and it is what the migration gate checks, document by document, against a build of the last 2.x commit.

- The output is its own fixpoint. Running `migrate` on what `migrate` wrote changes nothing, so a rewrite cannot drift further on a second pass.

- A file it cannot convert is left alone. It never rewrites part of a file and reports success, and it never damages a file that was already correct. `--lossy` is the one way to accept a loss, and it has to be asked for.

- It adds two comment lines to a file it rewrote - the `Format` line and a note saying the file came from 2.x - and nothing else. It never writes the whole info block into a file that had none.

- It is not a formatter. Layout, comments, blank lines and raw bodies come through as written, so `migrate` output is not a `fmt` fixpoint and is not meant to be.

Exit codes: 0 when the file needed nothing or was rewritten, 6 from `--check` when a line would change, 7 when a spelling needs `--from-2x` to settle or a line 2.x bound has nowhere to go, and 8 when the file cannot be read or written.

Three edges read differently, and `migrate` leaves all three as written:

- A fence label holding a `#` ran to the end of the line in 2.x. It ends at the `#` now, and the rest is the line's comment. A label has no quoting, so rename it.

- A carriage return in the middle of a line, at the edge of a piece, was content in 2.x. It is trimmed now.

- An indent that matches no open level's column. 2.x placed a line by a looser comparison, so a tab followed by a space and a tab, or by two spaces, bound then and is `E012` now. `migrate` rewrites spellings and not layout, so a file like that has to be re-indented by hand. Nothing goes quietly: `migrate --write` refuses at exit 7 while the migrated text holds such a line, though a save elsewhere keeps it as written.

## Cross-language parity and conformance

The guarantee is the corpus, not the binding count: **every released binding is corpus-green**. A binding that has not passed the full conformance corpus is not released, full stop. A companion surface (C++/Kotlin) inherits its core's conformance for free, and the CLI-wrapper bindings (Bash, PowerShell) inherit the Tier 1 CLI's. The safeguards:

- This spec plus `grammar.abnf` are the single source of truth; behavior is specified, not left to each implementation.

- A **conformance corpus** of golden cases (`conformance/`) pins every implementation to identical results: each case is an input `.shcl`, its expected canonical formatting, and a set of expected typed reads with their status sentinels. The date/coercion/quoting edge cases live here so no parser can silently drift.

- Every parser runs the corpus in CI before it is considered conformant.

## Resolved minor items

These were previously deferred and are now settled inline (above):

- **Currency set**: cut from Standard; Loose-only, a fixed 20-codepoint list, single leading symbol only (see Strictness levels).

- **`field[*]` with a missing sub-path**: keep the positional slot, per-element `NotFound`, no diagnostic (see Paths, selectors, and enumeration).

- **on-bad surface**: canonical `Error`/`Default`/`Flag`. In the libraries it is which tier you call, not a parameter; on the CLI it is `--on-bad`, defaulting to `flag` (see The core call).

- **`GetInt` on a `%` value**: cut from Standard (`BadType`); at Loose, rounds the fraction, not special-cased (see Strictness levels).

- **Fence info-string**: free-form advisory label, exposed but never interpreted (see Raw blocks).

- **Fehu anti-escape**: removed entirely - raw blocks are the verbatim escape hatch (see Escapes).

- **Field-name case folding**: ASCII `A-Z` only, never Unicode (see Merging and instances).
