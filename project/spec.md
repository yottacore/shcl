<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# SHCL specification

SHCL stands for Simple Hierarchical Config Language. This is the canonical language spec. It describes terminology, lexical rules, structure, the read-time type and coercion model, raw blocks, the accessor and writer API, the canonical formatter, and the conformance strategy. The formal line and value grammar is in `grammar.abnf`, the raw by-example origin is in `../../notes.txt`, and the settled decision log is in project memory.

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
	- [Dot and paren (inline form)](#dot-and-paren-inline-form)
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

SHCL aims to be forgiving to write, predictable to read, and expressive enough for any flat or hierarchical data, with a read API that takes only a few calls to learn. It doesn't claim to be the simplest possible language. The grammar has real features, and pretending otherwise invites the comparison. The simplicity claim is true of what the 2 audiences below experience, and SHCL is optimized for those 2 audiences and not for anyone else:

- **The person writing config by hand.** It must be forgiving and obvious enough that a non-programmer can hand-author a whole file from scratch without memorizing rules, even a file as rich as a declarative DDL. If a modern parser can figure out what was meant, it must, and the user is never asked to satisfy the machine.

- **The programmer consuming values.** SHCL can be pulled in as a **Command** (CLI), a **Drop-in** source file, a **Package**, or a linked library that is **Shared** or **Bundled**. However it's pulled in, it must get you to "read the value I need" in one obvious, amateur-friendly call, and let you write out defaults and comments just as easily.

Everything hard is the parser's job, including typing, coercion, disambiguation, error recovery, and formatting. Every ambiguous design call follows one rule: **push the burden onto this program, never onto the user or the consumer, and impose no constraint the parser could have resolved from context when the input isn't legitimately ambiguous.**

## Terminology

The spec avoids the word "key" on purpose, because it implies uniqueness and SHCL doesn't require that. The mental model is a database rather than a map.

- **Field** (a.k.a. column): the name on the left of a colon. A field isn't unique, and it may recur.

- **Value**: the text on the right of a colon, an array of such texts, or a raw block.

- **Instance**: one occurrence of a field with a particular value. Repeating a field with a *different* value creates another instance. *Row* and *record* are synonyms, and they're listed here only as a glossary pointer. The docs and API use "instance" throughout. "Record" is never used as a verb, since the write-side verb is "write".

- **Discriminator**: an instance's value, when it's used to tell instances of the same field apart (`base: Chicago` vs `base: Boston`).

- **Wrapper**: a field whose occurrences all have an empty value. They collapse into a single organizational node. A wrapper is the degenerate case of an instance, with an empty discriminator.

- **Leaf**: a field occurrence with a value and no children.

- **Field path** (a.k.a. key path): the dotted chain of field names identifying a position in the tree, e.g. `base.metrics.population`. A path may resolve to many instances.

One rule unifies all of the above: **a node is `(field-name, value, children)`; nodes merge when their `(field-name, value)` pair matches; an empty value merges with other empty values under the same parent (that is a wrapper).**

The software side has its own nouns:

- **Parser**: turns SHCL text into the in-memory model. It does all the hard work, such as deferred typing, disambiguation, and error recovery.

- **Accessor**: the typed read layer a consumer calls to pull values back out, with `GetInt`, wildcards, and status sentinels. Typing is *accessor-driven*. The target type is fixed by which entry point you call, and it's never stored in the file.

- **Writer**: the emit side. It writes values, defaults, and comment sections, and it canonicalizes a file.

- **Consumer**: the programmer using a binding, as opposed to the person hand-authoring the file.

- **Binding**: one language's implementation of the parser, accessor, and writer, as in "the Go binding" or "the Rust binding".

The Accessor reads in 2 modes:

- **Lookup** (a.k.a. query): fetch a single value at a field path, like a point read in TOML or YAML. In plain English, it means *get a value*.

- **Traversal** (a.k.a. scan): consume the document as a whole and iterate it. This is the mode for treating an SHCL file as a DDL or dumping every setting. In plain English, it means *walk the document*.

- **Materialize**: the step a traversal runs first. It merges duplicate instances and orders everything deterministically, so the walk is stable and repeatable.

A few more nouns the spec uses:

- **Trivia**: comments and blank-line grouping. The parser keeps them and the formatter writes them back out, but they're never part of identity, merging, reads, or diagnostics.

- **Raw block** and its **fence**: verbatim multi-line content between fence lines, which no SHCL rule applies to. The optional **info-string** after the opening fence is an advisory label.

- **Canonical form**: the one layout the formatter writes, with block layout, tabs, insertion order, and minimal quoting. Running `fmt` on canonical output gives back the same bytes, so it's a fixpoint.

- **Layer**: a whole document merged under another in layered loading (defaults, then site, then user).

- **Schema**: an ordinary SHCL file of `field:` path entries whose children constrain the document. Validation is a separate pass and never part of a parse.

- **Corpus / conformance case**: the shared fixture set every binding must pass byte-for-byte. The cross-binding differential check replays it through every CLI, along with fuzzed inputs.

## Lexical structure

### Encoding and lines

- Files are UTF-8. A leading UTF-8 BOM is stripped if present. What a *library* does with bytes that aren't valid UTF-8 is unspecified. The bindings differ here, since some refuse them, some parse the bytes as they are, and some substitute. So a consumer that hands the library raw bytes has to check the encoding itself. The CLIs agree, and every one refuses such a file at exit 8. A setter never writes such text. Go and C refuse bytes that aren't UTF-8, Python refuses a lone surrogate, and a Rust string can't contain either.

- Line endings may be LF or CRLF, and both are accepted. The canonical formatter emits LF. A save that keeps the lines keeps the file's own line endings and indent instead, as described under [File tier](#file-tier).

- Trailing whitespace on a line is trimmed before parsing.

- The recommended extension is `.shcl`.

### Comments

- `#` begins a comment that runs to the end of the line, wherever it sits, as long as it's outside quotes, backticks, and a raw block. No space is needed before it: `url: http://h/#frag` is the value `http://h/` and a comment, `a:#x` is an empty value and a comment, and ```` ```c# ```` labels a raw block `c`. A value with a `#` in it is quoted, as in `color: "#ff0000"`.
	- The load reports the hint `H008` when the `#` is against text. That means text right before it in a bare value, an array element, a selector body, or a fence label, as in `url: http://h/#frag` and ```` ```c# ````, or right after it where that piece is empty, as in `color: #fff` and `a:#x`. A blank before it, or a blank or another `#` after it in an empty piece, makes a plain comment with no hint: `pop: 700  # note`, `a: # note`, `a: ## two`. So does a `#` after a closing quote or `]`. The hint changes nothing the load reads.

- Comments may be a whole line or trail a value (`pop: 700  # note`).

- Blank lines contain no data, but a blank line between bindings is grouping the author created. The parser notes it as trivia on the node below, or on the comment line below, so a blank between comment-only regions survives too. The canonical formatter re-emits it. A run of blanks collapses to one, and output never starts with one. Like comments, blanks play no part in merging, reads, or diagnostics.

- A whole-line comment attaches to the next line that binds a node, unless it's written **deeper** than that next line. Then it belongs to the block it's in, and it stays there at its own depth. A comment at the level of the block's last binding trails that binding. The exception is one at column zero after the last top-level binding, which is the document's own tail comment instead, because a top-level field's trailing comment and the document's are written identically and a reload couldn't tell them apart. A comment written deeper still goes inside that binding's block. So a header whose children are all commented out keeps those comments indented under it, rather than handing them back a level shallow. The same rule keeps indented tail-of-file comments with their block, and only top-level tail comments remain end-of-file orphans.

- A run of comments keeps the order it was written in. Once one comment in the run goes with the next binding, every later one does too, and a comment whose block would be written out ahead of the one before it goes where that one went. A comment written under the comment before it keeps that nesting, one level per step, so a commented-out block comes back in its shape. A malformed line that's kept as trivia keeps its place in the order but not the extra depth, since it stays at its own level on a reload.

- A `#` inside quotes is literal (`url: "http://h/#frag"`), and so is a `#` inside backticks or a raw block. In a comment, the escape mark `◉` is plain text.

- Comments are never discarded. The parser keeps each one as trivia attached to the tree, and the canonical formatter re-emits them, as described under [Canonical formatter](#canonical-formatter). They play no part in merging, reads, or diagnostics.

- A selector on a file line is cut off by a `#` like anything else, so `a(#2).b: 1` in a file is a malformed line. In a lookup path a bare selector body that starts with `#` is refused, as `BadPath`. An index is a bare number, `a(2)`, and a value that starts with `#` is quoted, `a("#2")`.

### Whitespace, quoting, and reserved characters

- Whitespace around dots, colons, brackets, commas, and values is insignificant and trimmed. `a . b : "x"` == `a.b:"x"`.

- A carriage return counts as whitespace outside a raw block. It is trimmed at the edge of a name, a selector, a value, an element, a comment or a fence label, and kept in the middle of one. It is never indentation.

- A value is a bare value, a quoted string, a backtick value, or an array, and always fits on its line.

- A bare value runs to a comment or the end of the line, and has no quote in it, except an apostrophe inside a word. A bare field value or `- ` item may contain spaces, and each run is kept as typed, so `title: My App` reads as `My App`.
	- A space there means U+0020 only. A tab, a carriage return inside the value, or any other character Unicode lists as `White_Space`, such as a no-break space, is `E025`, and so is a `'`, a `"`, or a backtick anywhere in it, except as below. `a: x"y` and `name: O' Brien` are errors, and `a: 'x"y'` and `name: "O' Brien"` are the fix.
	- A `'` with a character other than whitespace right before it and right after it is text, so `name: O'Brien`, `title: Jim's Server`, and `song: rock'n'roll` read as written. It is still `E025` in an array element or a selector body. The writer quotes a value that has any quote in it, so `fmt` writes `name: "O'Brien"`.
	- Only a space, a tab, and a carriage return are trimmed at the ends, so `port: 80   # main` is fine. Any other whitespace at an edge stays in the value, so it is `E025` too.
	- In a bare value, only a few characters have a meaning. A `#` starts a comment, adn a value beginning with `[` is an array. A `[` or `]` anywhere else is `E025`. A backslash is text, so `path: C:\dir\file` loads clean.
	- A colon needs a character other than whitespace right after it, so `t: 12:30`, `display: :0` and `url: https://example.com:8080` are fine. A colon followed by whitespace, or one at the end, is `E025` in a value. For example, `host: example.com port: 80` is 2 fields run together, and `x: done:` is an error too. In a `- ` item it is `E027`.
	- A comma needs a character other than whitespace right after it too, so `opts: rw,noatime` is one string. A comma followed by whitespace, or one at the end, is `E026`, as in `ports: 80, 443` and `x: a,`, since an array is written in brackets.
	- Dates, times, durations and sizes may contain spaces when bare: `Jul 12 2026`, `2:30 PM`, `1h 30m`, `1.5 GiB`. `Jul 12, 2026` needs quotes for its comma. Typed reads don't care about the quotes.
	- A line with one of these errors in its value is kept as written and binds nothing. Its name is fine, so the lines under it still load under the field, as described under Diagnostics and writing.

- A **field name** is more restricted than a value. Bare, it starts with an ASCII letter, then has only ASCII letters, digits, `-`, and `_`. Any other name is quoted: `"404"`, `"user name"`, `"Straße"`. A quoted name can be any text, spaces and a leading digit included.
	- A bare name that breaks only that spelling rule, such as `404: x`, `-x: y`, `_id: 7`, or `Straße: x`, is `E014`. The name can still be read, so the line is kept as written and keeps its level open. The lines under it load under the name it reads as, and the field exists only when one of them binds. Quote the name to fix it.
	- A line that can't be read at all is `E014` too, with the reason in the message, and it is kept with what is written under it.
	- Every field line has its colon, a header with lines under it included. A line without one is described under [Error handling philosophy](#error-handling-philosophy).

- Either single or double quotes may wrap a string. They work the same way, and each one can contain the other kind as text: `'He said "hi"'`, `"it's"`. A string with both uses `◉DOUBLE_QUOTE◉` or `◉SINGLE_QUOTE◉`.

- A quoted piece opens with a quote as its first character and closes at the matching quote, which has to be the last thing in the piece. A piece that opens a quote or a backtick and doesn't close it that way is `E017`, as in `a: "open` or `a: "x" y`. The line is kept as written and binds nothing, and the lines under it still load under the field. One rule reads a name, a selector, a value element, a `SetLiteral` argument, a `--set` path, and a schema path.

- Outermost quotes are removed on read, and whitespace *inside* the quotes is preserved.

- A **backtick value**, such as `` color: `#FF8800` `` or `` esc: `\x7F` ``, is raw text for the program to decode.
	- Nothing inside it is special. It has no escapes, and `◉`, `#`, `,`, `[`, quotes, and whitespace are all text. It can't contain a backtick, since 3 of them open a fence.
	- A read returns the text between the backticks as written, with a `backtick` flag (see [Paths, selectors, and traversal](#paths-selectors-and-traversal)). It counts as quoted too, and a typed read still reads the text, so `` n: `42` `` reads as the integer 42.
	- It is allowed as a whole value or a whole array element, never in a field name or a selector.

- The **formatter** quotes more than the parser asks for, so canonical form has one reading. A value, a `- ` item or an array element is written bare only when it doesn't have whitespace or any of `#` `"` `'` `` ` `` `:` `,` `(` `)` `[` `]` `◉`, and doesn't need an escape. Otherwise it is quoted.
	- The reader takes `2:30PM`, `localhost:8080`, `:0`, `http://my.com/` and `rw,noatime` bare, but the writer quotes them, the same as a value with a space. Only hand-typed lines get that leeway, so nobody reading canonical output has to know where a colon or comma is text.
	- The one exception is a bare thousands number, such as `80,443`, `1,200.`, `1,200.50` or `$1,200`, in the form Loose reads in quotes (see [Strictness levels](#strictness-levels)). A value or `- ` item like that stays bare, since quoting it would make a Loose read of it a number. A setter's value like that is written bare too. Inside `[]` it is quoted like any comma, and an item a merge puts in brackets counts as quoted from then on.
	- A tab inside a quoted value is written `◉TAB◉`.
	- The author's quote kind is kept. A value written in single quotes, double quotes or backticks comes back that way, through `fmt` and also through a setter that overwrites it, when the new text can be written that way.
	- Quotes are never dropped, even on a value that reads as an int, a float, a bool, or a datetime, which are SHCL's own data formats. `ver: "8"` stays quoted, though a typed read gives 8 either way. `zip: "02134"` stays quoted and bare `zip: 02134` stays bare, and a typed read of `zip` gives 2134 for both. A bare thousands number stays bare, so `ports: 80,443` reads the same after a save.
	- A plain string such as `hook: "fFoo()"` stays quoted, so quoting a value that a downstream language treats as special survives reformatting.
	- When the writer picks the quotes, it uses double quotes, or single quotes when the text has a `"` and no `'`. Text with both goes in double quotes with `◉DOUBLE_QUOTE◉`. A backslash plays no part in the choice.
	- A `.` is reserved only in a field or path position rather than inside a value, so `host: example.com` stays bare even in canonical output.

### Escapes

- A backslash is plain text everywhere: bare, in either quote, in a field name, and in a selector. `path: "C:\temp\new"` reads as `C:\temp\new`, so a Windows path or a regex needs no doubling.

- An escape is the escape mark `◉` (U+25C9, FISHEYE), a name from the table below, then the mark again: `"line one◉NEWLINE◉two"`, `My◉SPACE◉App`.
	- Escapes work in bare and quoted values, array elements, quoted field names, and selector bodies. They don't work in comments, backtick values, raw block bodies, or fence labels, where a `◉` is an ordinary character.
	- Names ignore case, so `◉tab◉` is `◉TAB◉`. The writer uses the first name in each row and reads the rest as aliases.
	- Inside a piece the marks pair up left to right. The text between a pair has to be a name from the table, or the line is `E023`, and so is a mark with no partner. Escapes can't nest. No name could contain another, so a nested one is already `E023`.
	- `◉U+XXXX◉` names any character by its hex code point, 1 to 6 digits, up to `10FFFF`. A surrogate, `D800` to `DFFF`, or anything past `10FFFF` is `E023`. There are no hex byte or octal escapes.
	- A real `◉` is written `◉ESCAPE_CHAR◉`.
	- `E023` keeps the line as written. When only the value has the bad escape, the lines under it still load under the field. When the name has it, the name can't be read, so what is written under the line goes with it, a raw block included. A lookup path or a `SetLiteral` text that has one is refused.

The table is generated from `cicd/utility/gen-escapes.py`, which writes the same list into every binding and into the grammar's `escape-name` rule.

<!-- gen-escapes.py: begin -->
<!-- Generated from Unicode 18.0 by cicd/utility/gen-escapes.py. Edit the script, not this block. -->

| Escape           | Aliases                                                                         | Character
| :---             | :---                                                                            | :---
| `◉NUL◉`          | `◉NULL◉`                                                                        | U+0000
| `◉BEL◉`          | `◉BELL◉`                                                                        | U+0007
| `◉BACKSPACE◉`    | `◉BS◉`                                                                          | U+0008
| `◉TAB◉`          | `◉HT◉`, `◉HORIZONTAL_TAB◉`                                                      | U+0009
| `◉NEWLINE◉`      | `◉LF◉`, `◉LINEFEED◉`, `◉LINE_FEED◉`, `◉NEW_LINE◉`                               | U+000A
| `◉VT◉`           | `◉VERTICAL_TAB◉`, `◉VERTICALTAB◉`                                               | U+000B
| `◉FF◉`           | `◉FORM_FEED◉`, `◉FORMFEED◉`                                                     | U+000C
| `◉CR◉`           | `◉CARRIAGERETURN◉`, `◉CARRIAGE_RETURN◉`                                         | U+000D
| `◉CRLF◉`         | `◉CARRIAGERETURN_LINEFEED◉`, `◉CARRIAGE_RETURN_LINE_FEED◉`                      | U+000D U+000A
| `◉ESC◉`          | `◉ESCAPE◉`                                                                      | U+001B
| `◉DEL◉`          | `◉DELETE◉`                                                                      | U+007F
| `◉SPACE◉`        | none                                                                            | U+0020
| `◉SINGLE_QUOTE◉` | `◉SQUOTE◉`, `◉S_QUOTE◉`, `◉SINGLEQUOTE◉`                                        | U+0027
| `◉DOUBLE_QUOTE◉` | `◉DQUOTE◉`, `◉D_QUOTE◉`, `◉DOUBLEQUOTE◉`                                        | U+0022
| `◉BACK_TICK◉`    | `◉BACKTICK◉`, `◉TICK◉`                                                          | U+0060
| `◉ESCAPE_CHAR◉`  | `◉FISHEYE◉`                                                                     | U+25C9
| `◉U+XXXX◉`       | `UNICODE+`, `UNICODE-`, `UNICODE_`, `UNICODE`, `U-`, `U_`, `U` in place of `U+` | The character at that hex code point

<!-- gen-escapes.py: end -->

- The same rules apply to a quoted **field name**. A name is identified by its text with escapes resolved, rather than by how it was written, so `"a◉DOUBLE_QUOTE◉b"` and `'a"b'` are the same field. Canonical output picks one spelling, and `QuoteSegment` produces that spelling, so any name round-trips. The as-authored accessor is the one place the source spelling is handed back (see the Accessor).

- On output, a line break in a value is written `◉NEWLINE◉`, a carriage return `◉CR◉`, and the pair of them `◉CRLF◉`. A tab inside a quoted value is `◉TAB◉`, since a tab can't be told from spaces by eye. A literal tab in the input still reads as a tab. The other controls in the table are written by their first names, and a real `◉` as `◉ESCAPE_CHAR◉`. Each of these puts the value in quotes.

- Names and values also write each character a reader couldn't see as `◉U+XXXX◉`, with at least 4 hex digits in capitals, in quotes: any other control, the line and paragraph separators, the interlinear annotation marks U+FFF9 to U+FFFB, and each character Unicode 18.0 lists as `Default_Ignorable_Code_Point`, such as a zero-width space, a direction mark, embedding, override, or isolate, a soft hyphen, the byte order mark, a Hangul filler, or a tag character. The format fixes that list, so a later Unicode doesn't change the output. There are 3 kinds that stay as written where text needs them. The zero-width joiner and non-joiner always do, since emoji and several scripts need them. A variation selector does when the character before it is visible, meaning not a blank, a line break, a joiner, or anything else in this list, so `❤️` keeps its selector while a run of selectors, which can contain hidden text, doesn't. The tags of a subdivision flag do too: U+1F3F4, then 3 to 7 tag digits or lowercase tag letters, then the cancel tag U+E007F, which is how UTS #51 encodes the flags of England, Scotland, and Wales. Any other tag is escaped. Comments and raw block bodies are written as they are.

- A value is always a single physical line, and a line break *in* a value is written `◉NEWLINE◉`. Multi-line verbatim content goes in a raw block instead.

## Structure and hierarchy

Hierarchy is expressed in 2 interchangeable ways, and both produce identical trees.

### Indentation (block form)

- A line indented deeper than the previous line is its child. Indentation is **relative and stack-based**. Any increase opens a level, and a decrease must return to the exact column of an ancestor.

- A dedent to a column that matches no open level is an error the parser recovers from. The line is diagnosed and skipped, and the rest of the file goes on loading. Like any skipped line, it keeps its column. What is written deeper is skipped with it (`E018`), a fence line there takes its whole body with it, and another line at the same bad column is refused the same way rather than binding one level up. It opens no level and closes none, so a later line that matches a level open before it binds there, as if the bad line weren't there. A save writes the line back exactly as it was, and the lines under it too, when its indent has a space in it. Canonical output doesn't write any level it opens with a space, so a reload refuses it the same way. An indent of tabs alone would bind there, and a line opening a raw block would take its body along, so those count as lost. Where a merge or an edit moves a kept line to a spot where it would bind as written, it is written as a comment instead, which reads the same.

- Indentation is tabs *or* spaces, and nothing detects which. A line's indent is compared with the open levels as text. A line whose indent has the open one's as a proper prefix is a child, byte-equal is a sibling, and anything else is `E012`. So a file that mixes the two inside one subtree can still load, with the nesting that comparison gives. Keep it uniform per file.

### Dot and paren (inline form)

- `a.b.c: v` is exactly `a:` / (indent) `b:` / (indent) `c: v`. The `.` stands in for "newline + one deeper indent".

- `field(disc)` selects or creates the instance of `field` whose discriminator value is `disc`, then continues the path under it. `base(Boston).metrics.population: 700` is identical to writing `base: Boston` then nesting `metrics` then `population: 700`. A `(` right after the name is a selector, with whitespace allowed before it. A `[` after the colon starts the value as an array. The same syntax is the Accessor's lookup syntax, so a path reads identically whether authored in a file or passed to `Get`.
	- A `[` right after the name is the old selector spelling, `base[Boston]`, and is `E029`. Brackets are only for arrays. The line is kept as written and binds nothing. When it selects by value, the lines under it still load, under the instance it names. A lookup path with one is refused, and the message says to use parens.
	- A selector matches one plain value, quoted or not: `base(Boston)`, `base("New York")`. It never matches an array or a raw block, so there is no way to select an instance by an array value. A new instance is created only when nothing matches.
	- Escapes are resolved on both sides before comparing, so the match compares one logical string with another. `("q◉DOUBLE_QUOTE◉uote")` finds an instance written `'q"uote'`, whichever spelling either side used.
	- A bare selector body is stricter than a value: whitespace, a colon, a comma, a quote, a bracket, or a paren in it is `E025`. So `base(New York)`, `srv(O'Brien)`, and `host(a:b)` are errors, and `base("New York")`, `srv("O'Brien")`, and `host("a:b")` are the fix. A selector is often typed on a command line, where those need quoting anyway. The paren itself needs it too, because a bare `(` is a syntax error in bash, so quote the whole path there, as in `shcl get app.shcl 'base(Boston).population'`. A body that opens a quote and doesn't close it as its last character is `E017`, and a bad escape is `E023`. A lookup path with one of those is refused, as `BadPath`.
	- A selector is quoted only when a quote is its first character, after any whitespace inside the `(`, and the matching quote is the last thing before the `)`. A bare selector runs to the first `)`, so a `.` is text in it. To put a paren in one, quote the discriminator. A nested pair, `x(a(b))`, is `E014`, since the body ends at the first `)`.
	- A selector on the **last** path segment already supplies that instance's value (the discriminator), so a trailing value doesn't have anywhere to bind. `field(disc): value` is legal in the grammar, but it isn't a valid binding. The instance is still selected or created from the discriminator, and the trailing value is reported as an `error` diagnostic and dropped. Since it's an `error`, it fails a Strict load like any other. A value is fine after a selector that is *not* last, such as `base(Boston).population: 700`, where it binds the deeper leaf.

- Inline and block forms may be mixed freely, and the parser normalizes both to the same tree.

### Merging and instances

- Occurrences with the same `(field-name, value)` merge, and their children combine. This is how redundant paths collapse and how you add fields to an existing instance later in the file. Identity uses the *resolved* value, with escapes applied, so `a: "q◉DOUBLE_QUOTE◉uote"` and `a: 'q"uote'` are one instance. That's the same text a `(value)` selector matches on, and the rule names follow it too. Quoting isn't part of identity, so `a: x` and `a: "x"` are one instance.

- Occurrences of a field with **different** values are distinct instances, kept in file order.

- A **repeated leaf line** (`tags: red` then `tags: blue`, no children) is 2 *instances* of `tags`, rather than the array `tags: [red, blue]`. Instances and arrays are separate mechanisms (see below).

- Field names are case-**insensitive**, folding **ASCII `A-Z`/`a-z` only** (`Metrics` == `metrics`). Non-ASCII characters in names never fold (`"Straße"` != `"STRASSE"`, `"İ"` != `"i"`). Full Unicode case folding depends on the locale, as with the Turkish dotless I, and it isn't portable across bindings, so it's left out on purpose. Such names must be quoted, per the quoting rule above, and only their ASCII letters fold. Discriminator **values** are case-**sensitive** after trimming and quote-stripping (`base: Chicago` and `base: chicago` are two instances).

## Values and types

**Typing is accessor-driven.** The parser stores every value as raw text and never guesses a type. The consumer knows its own schema and requests a type on read. The library coerces intelligently but safely, and it reports problems without ever refusing to keep working. So the value forms below are *coercion targets recognized at read time* rather than parse-time tags.

### Strings

Any value can be read as a string. A read trims surrounding whitespace, strips the outermost quotes while keeping inner whitespace, and applies escapes. A backtick value is the exception, and its text comes back as written. Quoting in the file is *required* for a tab or other whitespace but a space, a quote, a bracket, a colon or comma with whitespace or the end after it, and for a value starting with `[`, as described under [Whitespace, quoting, and reserved characters](#whitespace-quoting-and-reserved-characters). The formatter also quotes a colon, a comma, or a paren on output. An array read as a single string yields its **canonical bracket form**, `[a, "b c"]`. The elements are minimally quoted, with escapes intact, and joined with `, `, so the string re-parses to the same array. Per-element unquoting and escapes belong to the array-of-strings read. That holds for a one-element array too, so `port: [80]` reads as the string `[80]`, while `port: 80` reads as `80`.

### Integers

These forms are recognized, ignoring case, when a value is read as an integer:

- Optional sign `+`/`-`, then digits. A leading zero is still decimal (`0644` -> 644), and a float read drops it too. Quote the value to keep the zeros for a string read through `fmt` (see Whitespace, quoting, and reserved characters).

- There are no thousands separators. `1,000` and `"1,000"` are text, and they're `BadType` as an integer or a float. Bare, `1,000` is text at every level, so `ports: 80,443` never reads as 80443. The Loose strictness level reads a quoted one, as described under Strictness levels.

- Hexadecimal `0x...`, octal `0o...`, and binary `0b...`, signed the same way (`0xFF` -> 255, `0o644` -> 420, `0b101` -> 5, `-0x10` -> -16).

- Digit-group underscores aren't allowed.

- There's no currency handling, so `$1200` is a string and `BadType` as an integer. The Loose strictness level re-admits a fixed list of leading symbols, as described under Strictness levels.

### Floats

These forms are recognized when a value is read as a float:

- An optional sign, then digits, with a leading or trailing dot allowed (`.5`, `5.`, `3.14`).

- Scientific exponent (`1e6`, `2.5E-3`).

- An integer is a valid float on read.

- The value must fit a double. A literal past its range (`1e400`) is `BadType`, since a double can't represent it and a setter couldn't write it back. A literal below its range (`1e-400`) reads as zero.

- There's no currency, percent, or thousands handling, so `$3.14`, `50%`, and `"1,000.5"` are strings and `BadType` as floats. The Loose strictness level re-admits all 3, the last one only in quotes, as described under Strictness levels.

### Booleans

These forms are recognized, ignoring case, when a value is read as a boolean:

- True: `true`, `yes`, `on`, `1`.

- False: `false`, `no`, `off`, `0`.

- `1`/`0` are boolean only when a boolean is requested, and otherwise they're integers.

- Anything else is `BadType`, including `t`, `y`, and `enabled`. Strict narrows the set to `true`/`false` only, and Loose widens it, as described under Strictness levels.

### Dates and times

These forms are recognized when a value is read as a date or time. The formats are a closed whitelist, and a conformance case pins each one. A format is admitted only when it can't be misread, so either the year comes first or the month is a word. Anything else fails the read as a date with `BadType`, and the value can still be read as a string. Matching a format isn't enough. The value must also be a real calendar date and clock time, so `2026-02-30` or `25:00` is `BadType` even though it matches a format.

**Dates** always have a 4-digit year. The internal delimiter is one of `-` `/` `.`, and it must be uniform within the date:

- `YYYY-MM-DD`: `2026-07-12`, `2026/07/12`, `2026.07.12`.

- `YYYYMMDD`: the compact 8-digit form.

- `DD Mon YYYY`, with a space or a delimiter between components: `12 Jul 2026`, `12-Jul-2026`, `12.July.2026`.

- `Mon DD YYYY`, the same way: `Jul 12 2026`, `Jul/12/2026`, and in the space form a comma may follow the day (`Jul 12, 2026`), but only inside quotes, since a bare comma with a space after it is `E026`. That one is written `b: "Jul 12, 2026"`.

Bare, `b: Jul 12 2026` and `b: Jul-12-2026` are both fine.

Month names come from the fixed English set only, as a 3-letter abbreviation or the full name, in any case (`jan`, `Jan`, `JANUARY`). A trailing dot isn't allowed, and neither are other languages, because a locale table is how bindings drift.

**Times:**

- 24-hour `HH:MM` and `HH:MM:SS`.

- Optional fractional seconds after seconds, with a `.` delimiter and 1-9 digits (`14:30:05.123`). They're unambiguous because they can only follow `HH:MM:SS`.

- 12-hour, with mandatory minutes and a mandatory meridiem: `H:MM AM` / `h:mm:ss pm`. Case is ignored, and the space before AM/PM is optional (`2:30PM`). A dotted `a.m.` is rejected.

**Timezone suffix**, optional, after any time: `Z` or `+`/`-``HH:MM`. Named zones (`EST`, `Europe/Paris`) are rejected, because they need a timezone database, and a database like that is the surest way to break parity between bindings.

**Combined:** `<date><sep><time>[zone]`. The separator is `T`, a single space, `_`, or one of `-` `/` `.` where it doesn't create ambiguity. The time's `:` ends the date reading, so `2026-07-12-14:30` and `20260712.14:30` are fine, and the separator doesn't have to match the date's internal delimiter. Date-only and time-only values are each valid alone. Without a zone suffix the value is a *local*, or floating, date/time. Each binding returns its idiomatic local type, and the value is never silently assumed to be UTC.

**Tolerances the whitelist allows,** because a hand-written config uses them and none of them can be misread: a one-digit hour, month, or day where the format has room for 2 (`9:30`, `2026-7-1`), a lower-case `z` or `t` where the format says `Z` or `T`, whitespace before the meridiem or the zone (`14:30 Z`, `2:30 pm`), and a run of spaces where the combined form takes one. A stricter reading would turn working configs into `BadType` for no gain. A separator that changes the format is still refused inside a value, so `2026-07-12 T 14:30` and `Jul 12,2026` are `BadType`. Each of these tolerances that puts a space in the value needs quotes in the file, as any value with a space does.

**Rejected by decision rather than left out:** `MM/DD/YYYY` and `DD/MM/YYYY`, which are the motivating ambiguity, and every other all-numeric date that isn't year-first; 2-digit years; Unix epoch numbers, since a consumer that wants epoch time reads the integer and converts it; fully-written-out prose dates ("July twelfth"). Because typing is accessor-driven, a bare 8-digit number is tried as `YYYYMMDD` only when a date is requested, and otherwise `20260712` is the ordinary integer 20260712.

### Durations and sizes

A duration read gives whole milliseconds and a size read gives whole bytes, from spellings a person writes: `500ms`, `30s`, `1h 30m`, `2d`, `512MB`, `1.5 GiB`.

- Duration units are `ms`, `s`, `m`, `h`, and `d`, lower case. Parts run largest unit first, each once, and blanks are allowed between a number and its unit and between parts, so `1h30m` and `"1h 30m"` read alike and `30m1h` is `BadType`. A spelling with a blank in it is quoted in the file.

- Size units are `B`, `KB`, `MB`, `GB`, `TB`, `KiB`, `MiB`, `GiB`, and `TiB`, plus `kB`, which is the same unit as `KB`. Letter case is read, since `Mb` is megabits to most readers. `KiB` to `TiB` are powers of 1024. `KB` to `TB` are too, unless the read asks for decimal, which makes them powers of 1000. The 1024 default follows systemd, Docker, and the JVM rather than IEC, where a kilobyte is 1000 bytes, so `decimal` is the way to get powers of 1000.

- A number may have a fraction, and the result has to be whole: `1.5s` is 1500 ms, `0.5KiB` is 512 bytes, and `0.0001s` or `1.1KiB` is `BadType`. At most 18 digits after the point count. Neither a sign nor an exponent is allowed.

- A bare number takes its unit from the field name when the name ends in one after a `-` or `_`: `ms`, `sec`, `seconds`, `minutes`, `hours`, or `days` for a duration, and `bytes`, `kb`, `mb`, `gb`, `tb`, `kib`, `mib`, `gib`, or `tib` for a size, in any letter case. `timeout-ms: 250` and `cache_mb: 512` don't need anything else. `min`, `m`, and `s` aren't name endings, since `retries-min` is a minimum and a trailing `s` is usually a plural, and a capitalized word (`timeoutMs`) isn't a boundary, since names fold to lower case.

- Otherwise a bare number takes the unit the read passes, and with neither it's `BadType`. A unit in the value wins over the name's, and the load reports the hint `H005`, as in `timeout-ms: 5s`.

- A duration is at most 9223372036854 ms, the range of Go's `time.Duration`, and a size fits a signed 64-bit integer, so every binding can store what another reads.

### Arrays

An array is multiple values in a **single cell**. It has 2 spellings that produce the identical array: brackets on the field's line, or one `- ` item per line under it.

**Bracket form**: `tags: [red, green, blue]`.

- Elements are split on every comma inside the brackets, with or without a space after it, so `[a,b]` is 2 elements. The spaces after the commas are only separators. Each element is trimmed and can't have whitespace when it's bare, so `[New York, Boston]` is `E025` and `["New York", Boston]` is fine. A colon at the end of a bare element is `E025` too, and an element with a comma needs quotes: `["rw,noatime"]`. An element may be quoted or a backtick value, and quoted elements keep their commas, brackets, and colons as text, so `["[a]", "b"]` is 2 strings.

- `[]` is the empty array, and so is `[ ]`. A field with nothing after the colon, `x:`, is an empty array too. An array read of it is `Empty`, and of `x: []` it is `Good` with no elements.

- `[80]` is a one-element array. A typed read gives the same result for `port: 80` and `port: [80]`, and only the string read differs, since it gives the bracket form:

| File says         | Read as int | Read as int array | Read as string
| :---              | :---        | :---              | :---
| `port: 80`        | `80`        | `[80]`            | `80`
| `port: [80]`      | `80`        | `[80]`            | `[80]`
| `port: [80, 443]` | `BadType`   | `[80, 443]`       | `[80, 443]`
| `port: []`        | `Empty`     | `[]`              | `[]`

- So brackets count as part of the value wherever text is compared. `x: 80` and `x: [80]` are 2 instances and 2 different values against a schema's `allowed` set, and a selector can find only the first.

- A malformed bracket array is `E019`, and the line is kept as written. An array is malformed when there's text after the closing `]` (`log: [INFO] started`), a bare `[` or `]` inside (`[[1, 2], 3]`), an empty element (`[a,, b]`, `[a, ]`), or no closing `]` on the line, since an array is one line like every value. Arrays don't nest. Quote the value if it's text, as in `log: "[INFO] started"`.

- A bare comma with whitespace or the end after it, outside brackets and quotes, is `E026`. `ports: 80, 443` clearly means an array, so the message says to add the brackets. The line is kept as written. `rw,noatime` is one string.

**Stacked form**: an empty-valued field whose child lines are all `- ` items is the same array, one item per line:

~~~text
sizes:
	- small
	- "extra large"
	- "Bond, James"
~~~

is exactly `sizes: [small, "extra large", "Bond, James"]`. The rules that keep it unambiguous:

- The marker is `-` then a blank, either a space or a tab, and the blank is required. That's what separates `- small` from `-x: y`, which is `E014`, since a bare name starts with a letter. `- -5` is the item `-5`. A `-` alone is an empty item (`E009`), with or without a blank after it.

- Each item is one value and follows the value rules, so `- extra large` is fine and `- a, b` is `E026`. Such a line is kept among the items, and the other items still load.

- `- name:` and `- name: value`, a bare item with a colon followed by whitespace or the end, are `E027`. That's how YAML starts an object in a list, and SHCL writes one as instances. `- "name: value"` is the text `name: value`, and `- localhost:8080` is fine, since the rule is about what follows the colon. The line is kept, and the other items still load.

- An item that is an array, `- [a]` or `- []`, is `E019` and kept, since arrays don't nest.

- A line led by `*`, the old marker, is `E013`, and the message says to use `- `. The line is kept as written, the other items still load, and what is written under it goes with it.

- **Uniform or nothing:** at the child indent, every line is a `- ` item or none is. A field line after the items is `E001`, and an item after a field line is `E008`. Each is kept as written and binds nothing, and what is written under it goes with it (`E018`), so no list has a field under it. A line refused for its content there keeps its own code, and one refused for its value alone still keeps its level open for what is kept under it. A line that would bind under it is `E001` and kept, since it would put a field under the list. A field line that opens a raw block is dropped with the block.

- The field opening the list has an **empty inline value**. A field may not have both an inline value and a `- ` list.

- **Scalars only**: an item is a value rather than a sub-node, so it doesn't have `field: value` children. Arrays *of objects* are expressed with instances and discriminators. An item that joins a list still keeps its column, with its field as that level. A field line written deeper is under the field, which is `E001`, and a line back at the item's column is the item's sibling.

Element typing is accessor-driven, so `GetStringArray`/`GetIntArray` read either spelling identically.

A field with lines under it takes one plain value or none. An array there, `route: [GET, POST]` with lines under it, is `E028`, and so is `[]`. The line is kept, and the lines under it load under the field with no value. A list as an instance's value was always rare, and there are other ways to write it: a string, `route: "GET POST"`; a position, `route(1)`; or one plain value with the list in a child field, `route: api` with `methods: [GET, POST]` under it.

Canonical output writes a bracket array `[a, b]`, with one space after each comma. A one-element array keeps its brackets, `[80]`, when it was written that way or set through an array setter, and the empty array is `[]`. A list written with `- ` stays stacked, one item per line, since that's the author's choice, like quotes. A merge writes every list in brackets, whatever form its layers used. A field line kept among or after its items (`E001`) would bind under the brackets, so it is written as a comment there.

An array, in either spelling, is **one cell holding many values**. That isn't the same as repeating a field on separate lines, which makes distinct **instances** of that field. The 2 look alike only for a bare repeated leaf, and once an instance has children the intent is plain. A parser **must** emit a hint diagnostic on a bare repeated leaf (`did you mean tags: [red, blue]?`) and never silently treats one form as the other. The hint is advisory, with severity `hint` rather than `error`. Repeated leaves are legal, and they're the instance mechanism working as designed. The diagnostic makes sure nobody mistakes one form for the other without knowing it.

### Coercion rules ("intelligent but safe")

- int -> float: always.

- float -> int: **`BadType`**. `3.5` read as an int isn't silently rounded, because silent lossy conversion is what adopters distrust. It can still be read as a float or a string. The Loose strictness level re-admits rounding, as described under Strictness levels.

- any scalar -> string: always.

- to boolean: only from the boolean token set, never from a nonzero number, so `5` isn't `true`.

- There's no other lossy, silent conversion. A value that can't be coerced to the requested type yields the requested failure behavior, described below, rather than a thrown error.

## Raw blocks

Line endings are normalized on load. A line's entire trailing carriage-return run is removed, so CRLF and LF files parse identically. This is visible only inside a raw block, which is the one place content is kept untrimmed. A body line ending in CR doesn't have any spelling that survives a write, since the writer's own newline would turn it into a line ending. Elsewhere in a line, a carriage return is whitespace, so it's trimmed at the edge of a piece and kept in the middle of one.

A raw block embeds verbatim multi-line content, such as a DDL, a code snippet, or a template. The content is exempt from all SHCL rules, including indentation, escapes, `#` comments, and reserved characters. A file may contain any number of them.

- **Fenced, Markdown-style.** A block opens with a run of at least 3 identical fence characters, `` ``` `` or `~~~`. The opening run's character and length define the block. It closes at the first later line whose trimmed text is a run of the *same* character with length **>=** the opener, so content may itself contain shorter fences. An optional info-string may follow the opening fence, as in `~~~sql`. It's a free-form advisory label. The parser captures it and a raw-block accessor returns it to the consumer, but the parser never interprets it. No values are reserved, and a consumer may treat it as a content-type hint if it wants.

- **Binding: a fence is a value line for its parent field.** A fence line at child indent binds the block as its parent field's value. If the parent's value is empty, the block fills that instance's value. If the parent already has a value, or already received a block, the fence creates a **new instance** of the parent field with the block as its value. That's the same rule as for a repeated leaf line. There's no separate "anonymous block" concept. Blocks are instances, selected with the normal selectors (`notes(0)`, `notes(2)`), and identical `(field-name, value)` blocks merge like any other instances. A block's identity is its content **plus its info-string**, so a `sql` block and a `python` block are distinct even with equal bodies. The fence character and length are spelling rather than identity.

- **Same-line spelling:** the fence may also open on the field's own line (`path.name: ~~~sql` ... close fence). The tree is identical, and the child-indent spelling is canonical. The info-string goes on the fence line in both spellings and is read as bare text, so a `#` ends it and opens the line's trailing comment in either spelling. For example, `~~~sql  # note` labels the block `sql`, and `db: ```c#` labels it `c`. A label can't contain a `#`. Canonical output puts that comment on the field's own line.

- **A refused line still takes its block.** A field line kept for its name (`E014`, `E023` in a name) whose value is a fence keeps the body and closing fence with it, so the body never reads as fields and the closing fence opens nothing. A line that can't be read at all opens a block when a fence follows its first colon past where reading stopped, with no `#` before that colon. Canonical output writes the body and fence one level under the kept line, as it does a field's block, and a block that never closes gets its closing fence. A misplaced line that opens a block takes it the same way, and is lost (`E012`).

- **Reading:** use `Get` or `GetRaw` at the field path. A path resolving to several block instances reports `Multiple` on a single-value read, like any other field. A string read (`ReadString`, `GetString`) of a block gives its body too, so it's the one call for a field that may have either a plain value or a block. `GetRaw` of a plain value is `BadType`.

- **Indentation:** the block is visually nested at a child indent for clarity. The parser strips that nesting from each content line. The nesting is the closing fence's own indentation, or the opening line's when the block never closes, and the parser strips only as much of it as the line has. Relative internal indentation is preserved, and so is any indentation the body shares beyond the fence's, so a writer can store an indented snippet and read it back as given. Content `a` then `  b` under nesting yields the value `"a\n  b"`. A body whose lines are all 2 spaces past the fence keeps those 2 spaces. A whitespace-only line loses only what it shares with the nesting, so its spacing survives verbatim. The formatter emits the body at the fence's indent, which is what the load strips back off.

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

Both blocks bind as values. `GetRaw("config.ddl")` returns the DDL, and `GetRaw("config.notes")` returns the paragraph. Neither one needs a wrapper or an index.

## Consumer API

The library is uniform across languages, and each binding implements the same concepts idiomatically. The aim is cross-language consistency with reasonable compromises, rather than getting the most out of each language. Bindings are tiered by delivery commitment:

- **Tier 1**: the Rust reference implementation, and the `shcl` CLI built from it. These define conformance.

- **Tier 2**: Go, C with its C++ veneer, and Python. These are independent parsers, released when they pass the corpus.

- **Tier 3**: everything else, such as C#, Java with Kotlin, and JavaScript. These are deferred for now, gated on the corpus, and designed for from the start.

- **Shell scripts**: Bash and PowerShell call the `shcl` CLI directly, so they inherit conformance from Tier 1 for free.

The consumer-facing API has 2 halves. The **Accessor** reads values by lookup or traversal, and the **Writer** emits them.

A couple of these bindings are a base core plus a thin **companion typed surface**, rather than separate implementations. Each one has one parser and 2 call surfaces:

- **C++ over the C core**: the C source and its public header wrapped in `extern "C"`, plus a C++ interface that hides the C one from a caller. That interface has `Get<T>()` and the rest of the API over the typed C functions. C isn't a strict subset of C++, so the shared header is kept C++-clean, and only the `.c` needs to compile as C.

- **Kotlin over the Java core**: Kotlin calls the Java classes directly through JVM interop with no runtime work. The companion is a small extensions file that gives a `reified`-generic `get<T>()` instead of Java's `Class<T>` token form.

Here's how each binding handles a document that threads share:

- Rust: `Document` is `Send` and `Sync`, so threads can read one at once, and a setter takes `&mut self`, so a write has it to itself.

- Go: reads can run from several goroutines at once, since the lookup index the first read builds is built whole, under a lock, before it's put in place. A write needs the caller to keep every other call off the document until it returns.

- Python: there are no locks. A read doesn't change anything on the document but the lookup index, which is built whole before it's put in place, so threads can share a document for reads. A write needs the caller to keep every other call off it.

- C: a `shcl_doc` isn't safe from 2 threads at once, reads included, since every call writes to it. Keep it to one thread at a time, or hold a lock around each call (`shcl.h`).

- C++: each const member takes that lock, so several threads can read one `Document`. The caller has to keep a member that changes it to one thread (`shcl.hpp`).

### The core call

The conceptual operation is **"get the value at `path`, coerced to a target type, with a default and an on-bad policy."** The critical portability rule: **the target type is expressed by the entry point (a typed variant or a compile-time generic), never by a runtime field in an options object.** This is the only form that assigns straight into a strongly-typed variable with no consumer-side cast in *every* target language. A runtime `type` value can't drive a static language's return type, so the API doesn't rely on one. Go, Rust, C, C++, and C# all forbid it, and Java can do it only through a `Class<T>` token.

- **type**: chosen by which method or generic you call. That's `GetInt` / `GetFloat` / `GetBool` / `GetDateTime` / `GetString` / `GetRaw` and their array forms, `GetDuration` and `GetSize` with the unit a bare number takes (scalar only, and outside `Get<T>`), or a generic `Get<T>` where it's idiomatic, which is always in Rust and optional in Go, C++, and C#. Each language does it this way: Go typed methods or generics; Rust trait + turbofish/inference; C typed functions with out-param + status; C++ templates (`Get<T>`) over those C functions; C# explicit generics; Java `get(path, Integer.class, ...)`; Kotlin `reified`-generic `get<T>()` extensions over the Java methods; Python `get_int(...)`, or `get(..., type=int)` since Python is dynamic; JS typed methods; PowerShell typed variable coercion on assign; POSIX sh a single command that returns text, where the type flag only *validates*.

- **on-bad**: how to react to a bad, empty, missing, or ambiguous value. The choices are `Error`, which reports it, `Default`, which substitutes the default, and `Flag`, which returns the zero or empty value plus a soft indicator and never errors.

In the libraries the mode isn't a parameter. The tier you call picks it, because 2 of the 3 modes already have a natural form in every language, and a third parameter would have been a runtime switch over them. The full tier (`Read*`) is `Flag`. It returns the value, the status, and the raw text of the offending value, and never errors. The convenience tier (`Get*Or`) is `Default`, since passing the fallback *is* choosing the mode. `Error` has no library form, because a read that can't get a value is a normal outcome here rather than a fault. A caller who wants a throw raises one on the status. When a binding's own `get_*` spelling has a must-exist mode, as Python's does when no default is passed, that's the binding's idiom rather than a fourth mode.

The CLI is where the mode *is* a parameter, because a command line doesn't have tiers to choose between. The option is `--on-bad=error|default|flag`, and the default is `flag`. A `--default` implies `default`, and `--on-bad=default` without one is a usage error, since it doesn't have anything to substitute. The CLI is also the only place where per-slot substitution into a partially-resolved array exists (`--default` with an array read), for the same reason. A shell caller has no per-slot status to inspect.

This applies to **all** value access, not just arrays.

### Ergonomic tiers

The consumer is assumed to be a junior programmer in **every** binding, so each typed entry point comes in 2 tiers:

- **Convenience tier, the one the docs lead with.** It has one value, one baked-in fallback, one return, and no status to inspect. Supplying the fallback *is* choosing `Default` on-bad mode, so an empty/missing/bad/ambiguous read yields the fallback and nothing throws. This is the call a beginner writes 90% of the time.

- **Full tier.** It's the same read, but it returns the status sentinel and the raw text, for callers who must tell `Empty` from `NotFound` from `BadType` or who want to raise on a status themselves. The difference between `Empty` and `NotFound` is deliberate, and it's rare among config formats. `feature:`, written with an empty value, and no line at all give different results, so a tri-state convention like "empty means explicitly disabled, absent means use the default" maps straight onto the status with no adapter. The raw text is the value span exactly as written on its source line, with the comment stripped and the ends trimmed, so `regex: '^\d{2,3}$'` reads back byte-for-byte, quotes, backslash, and comma included. A value that doesn't have a one-line source spelling, such as one a writer built, a stacked `- ` list, or a raw block, falls back to the display form.

The convenience tier works the same way everywhere, with a mandatory fallback that's visible at the call site. That's what defuses the silent-zero trap. A junior can't accidentally read a `0`/`""` that was really empty or missing, because there isn't any convenience call without a stated fallback. It also has the same *name* everywhere. `_or`, or `Or` in the languages that capitalize, means "with a fallback" in every binding, so a routine ported between 2 of them can't keep the call name while changing which tier it calls. Each binding's native value-or-default idiom still works where it has one, such as `get_int(path).unwrap_or(0)` in Rust and `get_int(path, default=0)` in Python. Each binding has 3 read forms, in its own spelling: `get_X_or` is the convenience tier, `read_X` is the full tier, and plain `get_X`, with no fallback, gives the value or the reason there isn't one. Plain `get_X` returns a `Result<T, Status>` in Rust and a value and `Status` pair in Go, and in Python it raises `StatusError` unless a `default` is passed. C doesn't have a plain `get_X`. It has only `shcl_get_X_or` for the value types and `shcl_read_X`. The Rust and Go rows below show plain `get_X` as the full tier, since it gives the status too.

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

The array, bool, float, datetime, string, raw, and raw-info forms follow the same 2-tier pattern (`GetIntArrayOr`, `GetBoolOr`, `GetRawInfoOr`, ...), and only the coercion target changes. C's convenience tier is a deliberate exception, since it has the value types only (`shcl_get_int_or`, `_float_or`, `_bool_or`, `_duration_or`, and `_size_or`). String, raw, raw-info, datetime, and array reads hand back borrowed memory or lengths, which a value-or-default signature can't express, so those use the full `shcl_read_*` tier. The C++ veneer copies every result, so its `get_or<T>` works for every `get<T>` type, arrays and datetimes included, with `get_raw_or` and `get_raw_info_or` beside it. The deviation is recorded in the style guide. The full tier is one representation of the `Flag`-mode status described above, and the convenience tier is `Default` mode with the fallback the caller passed. For array reads the convenience fallback is the whole default array, which is returned unless the read is `Good`. Per-slot substitution into a partially-resolved array comes from the full tier's per-slot status or the CLI's `--default`, rather than from the convenience form.

### Status sentinels

Reads report one of: **Good**, **Empty** (present but no value), **NotFound** (path doesn't resolve), **BadType** (present but not coercible to the requested type), **Multiple** (path resolves to more than one instance and the call wanted one), **BadPath** (the path can't be read as a path, or has a `: value` part, so it never reached the document). `BadPath` is last in the order, so an aggregate status puts it on top, and Python gives it the value 1, the CLI's usage exit. A path that parses and matches nothing is still `NotFound`. The `_or` reads give their fallback for a bad path the same as for a missing one, and the plain calls with no status (`Count`, `Instances`, `Children`, `Line`, `Lines`, `AuthoredName`, `Kind`, `Comments`, `Exists`, `Remove`, `ClearComments`) give their empty result. Each has a twin with a status, in each binding's spelling: `ReadCount`, `ReadInstances`, `ReadChildren`, `ReadLine`, `ReadLines`, `ReadAuthoredName`, `ReadKind`, `ReadComments`, and `ReadExists`, plus `TryRemove` and `TryClearComments` for the 2 that change the document, which give the count. Each says `BadPath`, `NotFound` when the path matches nothing, or `Good`. `ReadLine`, `ReadAuthoredName`, and `ReadKind` say `Multiple` for a repeated field, as the typed reads do. A wildcard slot that didn't resolve still counts as a match in `ReadCount`, `ReadInstances`, and `ReadLines`, as it does in `Count`. The 4 that act on every node a path reaches (`ReadComments`, `ReadExists`, `TryRemove`, `TryClearComments`) count only nodes that are there, so a wildcard whose slots all miss is `NotFound` for them. A node with no children or no comments is `Good` with an empty list, so an empty section and a missing one read differently. `Empty` is informational rather than a failure, and the empty value is still returned. An empty binding is `Empty` to every read on it, the info-string read included, because there isn't a block there, so there's nothing to mismatch a type against. `ReadKind` reads what is there rather than a value, so an empty binding is `Good` to it, with `Empty` as the result. The parser **never** refuses a legitimately reachable value because some *other* part of the file was malformed.

### Lookup and traversal

There are 2 ways to read a document:

- **Lookup** (query): get a single value at a path, the point read most config code wants (`doc.GetIntOr("base(Boston).metrics.population", 0)`). The core call and tiers above are all lookups.

- **Traversal** (scan): consume the file as a whole. **Materialize** it first, which merges duplicate instances and orders them deterministically, and then walk it. This is the mode for treating an SHCL file as a DDL or dumping every setting. The wildcards, `Instances`, and `Count` below are its building blocks.

Materialization is idempotent and order-stable, so 2 traversals of the same document walk it identically.

### Paths, selectors, and traversal

- A lookup path uses the same syntax and tolerances as the file: case-insensitive field names, dots to descend, `(sel)` to select an instance, whitespace ignored (`base ( Boston ) . population`). A selector in brackets is refused, as `E029` is on a file line. A `#` outside quotes and outside a selector body opens a comment, as it does on a file line, where `a#b: 1` binds nothing, so a path that has one is refused rather than cut there. A name with a `#` in it is quoted, `"a#b"`.

- The selector forms are `(Boston)` (bare non-numeric = value), `(0)` (bare numeric = index), `("2020")` (quoted = value even if numeric), `(*)` (wildcard, below). The old `[#2]` index is gone, and a bare body that starts with `#` is refused, as `BadPath`.

- **Choosing `(i)` vs `(value)` when mapping entities**: a consumer that walks instances into its own model walks with `Fields()` or `InstancePaths()`, which give every instance with its `(i)` path in one pass. Keep `Count` + `(i)` for a point read, since a loop over `Count` that reads each `(i)` costs the square of the count. Either way, prefer an index to a value. By-value selection misreads an entity whose name is numeric, since `(2020)` is an index and has to be quoted to force a value match. It also collapses 2 entities with the same name into one result (`Multiple`), and never finds an instance whose value is an array. Index selection is positional, total, and collision-free.

- `field(*)` is a wildcard returning every instance's value as an array: `GetIntArray("base(*).metrics.population")`. The result is positionally aligned to the instances, with one slot per instance in file order. If an instance lacks the sub-path, its slot is kept, with the status `NotFound` and the zero value. Slots are never silently dropped, so indices stay aligned with `Instances(field)`/`Count(field)`. A legitimately absent sub-path isn't malformed, so it doesn't produce a diagnostic.
	- Every array read has one status per slot alongside the values, as a slot list on the result. Each slot reads like a scalar of the target type: `Good`, `Empty` (empty value), `NotFound` (missing sub-path), `BadType` (uncoercible, raw block, or array where one scalar is expected), or `Multiple` (sub-path ambiguous within that instance). The read's aggregate status is the worst slot, ordered `Good` < `Empty` < `NotFound` < `BadType` < `Multiple`, so a partial miss can never report `Good`.
	- `Instances` on a wildcard path keeps unresolved slots in the enumeration as empty strings, so the indices still line up with the read and with `Count`, which counts slots.
	- The libraries don't substitute anything per slot. The convenience tier's fallback is the whole array, returned only when the read is `Good`. Per-slot substitution is the CLI's `--default`, because a shell caller doesn't have a slot list to inspect.

- A bare `*` in **name position** (`indicators.*.period`) is the name wildcard. It matches every child field regardless of name, one slot per child in file order, with the same per-slot status, `Instances`, `Count`, and per-slot substitution behavior as `field(*)` above. The 2 wildcards compose, as in `server(*).*` and `*.port`. A wildcard after a wildcard flattens, so the inner slots join the outer run and the result is one slot per resolved leaf rather than one per outer instance. `Remove` on a wildcard path removes every node the path reaches, the nodes behind a slot a read calls `Multiple` included, and `Exists` checks that same list. A name wildcard doesn't take a selector of its own, so `*(x)` isn't a path. It's only for queries. A binding line never accepts it, the Writer's setters refuse it (`CheckSetPath` = `Wildcard`), and a field literally named `*` is written and addressed quoted, as `"*"`, which stays a literal name everywhere.

- `Instances(field)` and `Count(field)` enumerate instances by value or index. The library hands back the values as they are, but the CLI's `instances` prints a value that has a line break in it quoted, with the writer's escapes (`"a◉NEWLINE◉b"`), since its output is one line per instance and a consumer splits on newlines. `get --array` and `get --slots` do the same for each element or slot. A line break here is any character Python's `splitlines()` breaks at: LF, VT, FF, CR, U+001C to U+001E, U+0085, U+2028, and U+2029. `fmt` escapes each of them, so the quoted value is one line. A plain `get` prints the value as it is, since the whole output is that one value.

- `Children(path)` lists the child field names under a path, in file order, **duplicates included**. It's how to ask what keys are in a section, which a deduplicated path enumeration can't tell you, and it's the natural way to read an open section that's used as a map. The empty path enumerates the top level. A path with several instances lists the children of each in turn, the way a dotted path reaches all of them. Names come back as stored. `QuoteSegment` makes one splice-safe in a path.

- `Line(path)` returns the 1-based source line of the binding at a path, so a consumer check the schema can't express can still cite the line. It returns 0 when the path doesn't resolve to exactly one node, or when a writer built the node. `Lines(path)` is the plural form. It returns every binding's line in file order, so a repeated field, which is the case that most needs a citable line, gives them all. Unresolved wildcard slots are kept as 0 so indices keep matching `Count`, and a miss gives the empty list. `ReadLine` and `ReadLines` say which kind of miss it was, as described under [Status sentinels](#status-sentinels). The read result has the same `line` directly, plus 2 flags. `quoted` is true when the read's single scalar element was quoted in the source, and `backtick` is true when that element was a backtick value, which is raw text the program decodes itself. A backtick value counts as quoted too. A value a setter wrote counts as quoted when a save would quote it, so the flag and any read that turns on it, such as a Loose quoted thousands number, give the same result before and after the save. So quoting is a real escape for downstream languages. `a: @null` and `a: "@null"` read the same text but can be told apart, and the escape survives `fmt`, since canonical output keeps the quotes on a quoted plain string (see Whitespace, quoting, and reserved characters). As a deviation, the C read structs stay value plus status. C and the C++ veneer get the same 2 facts with `shcl_line`/`shcl_lines` and `shcl_quoted`, which is false for anything that isn't one scalar element, and give the raw text with `shcl_raw_text`, or `raw()` in C++. C also deviates with `shcl_reads_release`, which gives back the memory every read handed out. The other 3 bindings reclaim it through their runtime, so they don't need such a call.

- `AuthoredName(path)` (each binding's spelling) returns the field name at a path exactly as the author wrote it, with case unfolded and outer quotes stripped, so a message can echo `SYMBOLS` when the file said `SYMBOLS` even though the stored and canonical name is the folded `symbols`. Escapes are resolved on a name the same way they are on a value, so `"a◉DOUBLE_QUOTE◉b"` and `'a"b'` are 2 spellings of one field rather than 2 fields. Names and values agree on what a quoted string means. This call is the exception. It hands back the **source** spelling, with escapes as written, which is the point of an as-authored accessor. Canonical output picks one spelling for the name and escapes what it has to (`◉DOUBLE_QUOTE◉`, `◉TAB◉`, `◉NEWLINE◉`), so it reads back as the same name. Resolution works as it does for `Line(path)`, so the result is the empty string when the path doesn't resolve to exactly one node. Merged instances keep the first binding's spelling, which matches `Line` and comment attachment. A node a writer built keeps the spelling the setter's path used.

- `Kind(path)` (each binding's spelling) says what the value at a path is, so a generic tool can pick its read without trying each one: `Scalar`, `Array`, `Raw` for a raw block, or `Empty`. It reads the stored form. `x:` is `Empty` and `x: []` is an `Array` with no elements, the same split an array read makes with `Empty` and `Good`. `x: [80]` is an `Array` even though a scalar read takes it, and `x: ""` is a `Scalar`. A section header is `Empty`, since its value is. The type is `ValueKind`, in that order. C's is `shcl_value_kind`, `SHCL_KIND_EMPTY` to `SHCL_KIND_RAW`, and Go's values are `KindEmpty` to `KindRaw`, since `Empty` is a read status there. Resolution works as it does for `Line(path)`, so the result is `Empty` when the path doesn't resolve to exactly one node, and `ReadKind` says which miss it was.

- `Paths()` enumerates every field path in the document, in file order, deduplicated. A segment that isn't a bare name is emitted quoted and escaped, in the same spelling the canonical formatter writes, so every returned path is a valid lookup path and nothing in the document is hidden from the enumeration.

- `InstancePaths()` is `Paths()` one instance at a time: every binding's path in file order, with `(i)` on each segment whose name its parent repeats, so each path reads exactly one node and a repeated block is walked instance by instance.

- `Fields()`, `ReadFields(path)`, and `ReadChildFields(path)` (each binding's spelling) are `InstancePaths()`, `ReadInstances` and `ReadChildren` with the whole field beside each entry: its path in the `InstancePaths()` form, its name as stored, its value as `Instances` gives it, and its line (0 for one a setter built). A wildcard slot that didn't match anything is an all-empty field, so indices still match `Count`. The path is what a caller hands back to a read, since a value isn't a selector. `(1)` is an index whatever the instance's value is. The CLI's `--json` output and `instances --paths` print these.

- `QuoteSegment(name)` (each binding's spelling of it) quotes one segment for splicing into a lookup path. A bare name passes through, and anything else comes back quoted and escaped. That's the same spelling the canonical formatter writes and the exact inverse of the name parse, so any name at all can be spliced. Building a path from user-typed text without it is path injection, since a dotted name reads as nesting. Its output is a valid selector body as well, so `name(` + `QuoteSegment(value)` + `)` picks the instance with a value the program has, numbers included. The value comes back quoted, and `site("0")` is the instance whose value is 0, where `site(0)` is the first one. It quotes what a value would leave bare, `2020`, `@null`, and `a.b` among them. `FormatValue` gives a value's spelling, as described under the Writer below.

- An ambiguous single-value read, where the path resolves to many instances, reports `Multiple`. Narrow it with a selector until exactly one remains.

### Diagnostics and writing

- Loading also yields a list of structured **diagnostics** for every skipped or repaired line, which the consumer may inspect or ignore. Each one has a line number, a severity, a stable **code**, and a prose message. Severity is `error` when a line was skipped or repaired, or `hint` for legal input that looks like a common mistake, such as the repeated-leaf array hint. The split matters for Strict mode, because only `error` diagnostics fail a strict load. A failed strict load still hands back the parsed document alongside the failure. Each binding's failure type includes both the diagnostics list and the document, since recover-and-continue means the tree is what a Standard load would have kept. The failure's message names the first few diagnostics rather than a bare count.
	- A **content-malformed line** is one the parser can't read or refuses, such as a bad field name, a line led by `*`, a malformed array, or a bare value with a tab or a quote in it. It's diagnosed and **retained** as inert trivia. Canonical output re-emits it in place, where it re-diagnoses identically and can never read as a live binding, so a typo in a hand-written config survives the consumer loading, editing, and writing the file back. The one exception is a line beginning with a BOM, which the file-start strip would rewrite, so it counts as lost instead. A line the parser can read but can't **apply** where it is gets retained too, such as an index that doesn't name any instance, a field line among list items, or a list item with no field to join. Canonical output writes it as a comment wherever a merge or an edit leaves it able to bind. A line that, written back, could feed a raw block or bind where no comment stands for it can't be retained safely, and neither can a line past the depth cap or a caller's cap. Those lines count into **`LostCount()`** (each binding's spelling), which is the number of lines or values dropped that canonical output can't re-emit. It also counts a retained line that an edit took even though the rule for that edit says it stays (`design.md`, Kept lines under edits). A nonzero count means writing the document back deletes hand-written content, which is why the file tier's save refuses then, as described below. A line at an indent that matches no open level is kept as written when that indent has a space in it, since the indent alone keeps it inert, and lost otherwise (see Structure). A retained line keeps its level, so what is written under it is skipped with it (`E018`). The exception is a field line refused for its value alone (`E017`, `E019`, `E023`, or `E025` in the value, `E026`, `E028`). Its path is fine, so the lines under it load as they would under the same path with nothing after the colon. A bare name that breaks only the spelling rule (`E014`, such as `404: x`) is held open the same way, under the name it reads as. Such a field exists only when one of them binds, and canonical output then writes the kept line in place of the bare `name:` line. A setter writing a field writes every such kept line of that name in its block as a comment, with a note naming the path, the local time, and the reason. It then changes the field in place, or puts a new one right under the first of those comments, so the file has one line for it. Whether each code is bound, retained, or dropped is in one table in `design.md` (Load outcomes), and the count and the held level follow from it.
	- The **code** (`E001..`, `H001..`) is the portable contract, so the same kind of problem gets the same code in every binding. The prose **message** is a free, per-binding voice, and it isn't part of the contract. The `shcl check` CLI follows this. It prints `line N: severity: CODE` to stdout, which is compared across bindings, and the prose message to stderr, which the differential check drops. The last stdout line is a summary: `ok (N diagnostic(s))`, `failed: N diagnostic(s), M error(s)`, or at `--strictness=strict` with an error present `strict load failed: N diagnostic(s)`. Every diagnostic line starts with `line `, and the summary never does, so a script keeps the diagnostics by that prefix. `check` exits nonzero when any `error` diagnostic is present, and not only on a strict load failure, so a CI gate on `check` catches dropped lines at any strictness.
	- `FormatDiagnostic(d)` (each binding's spelling) gives one diagnostic as the line the CLI prints on stderr: `line N: Error: CODE message`, or `Hint`. A `V090` to `V095` line counts lines in the schema file, so it reads `schema line N`. The message is the binding's own, so the line matches across bindings only up to the code. A diagnostic without a message ends at the code. Rust's `Display`, Go's `String()`, and Python's `str()` give the same line. C takes the parts its `shcl_diag_*` and `shcl_validation_*` accessors give and returns a buffer the caller frees, and `shcl_severity_name` gives the severity's text.
	- A load lists its diagnostics in line order, and 2 on one line in the order they were found. Under a diagnostic cap the ones listed are the first found, and the `E022` entry still ends the list. `check --schema` and the one-shot load put validation's after them, in the order under Schema validation. Under `--layer` each file's list is printed on its own, lowest layer first, and a merge doesn't combine them.
	- These are the load-time codes, listed so a CI gate can key on them. Validation adds the `V###` range, which is tabled under Schema validation:

| Code   | Meaning
| :---:  | :---
| `E001` | field line under a parent already holding stacked `- ` list items. The line is kept as written and binds nothing, the other items still load, and what is written under it goes with it. One that opens a raw block is dropped with the block. A dotted line that reaches the items through an index, such as a `srv(0).tls` line after items under `srv`, is a field line there too
| `E002` | value after a last-segment selector (`a.b(X): v`) - the value is ignored
| `E003` | selector names an instance that doesn't exist: `a(5).b` where there is one `a`. The message names the index as written. An index selects an existing instance by position and never creates one, which is why a binding line should select by value. The line is kept as written and binds nothing, and none of its path's fields are opened. One that opens a raw block is dropped with the block. On a write path the same situation comes back as the `NoSuchIndex` set-path check rather than as a diagnostic
| `E004` | wildcard selector on a binding line (wildcards are query-only). The line is kept as written and binds nothing, none of its path's fields are opened, and what is written under it goes with it. A raw block it opens is kept with it
| `E005` | unterminated raw block (closing fence never found)
| `E006` | raw-block fence with no parent field to bind to
| `E007` | stacked `- ` list item with no parent field. The line is kept as written and binds nothing
| `E008` | stacked `- ` list item under a parent with field children. The line is kept as written and binds nothing, and what is written under it goes with it
| `E009` | empty stacked `- ` list item: a `-` with nothing after it but blanks or a comment. The line is kept as written and binds nothing, and the other items still load
| `E011` | stacked `- ` item for a field that already has a value. The line is kept as written and binds nothing
| `E012` | indentation matches no open level; kept as written when the indent has a space and the line opens no raw block, lost otherwise
| `E013` | a line led by `*`, the old list item marker. A list item is written `- value`. The line is kept as written and binds nothing, the other items still load, and what is written under it goes with it
| `E014` | a bare field name that breaks the spelling rule (`404: x`, `-x: y`, `Straße: x`), or a malformed line, with the reason named in the message. A name that can still be read is kept and keeps its level open, so the lines under it load under that name. Any other malformed line is kept and the lines under it go with it. A line with no colon whose bare name has a blank in it (`square-miles 300`) is this code too. A raw block the line opens is kept with it
| `E015` | missing colon on a line that is one clean name or path, quoted or bare (`404`, `"user name"`, `a.b(x).c`), repaired as that path with an empty value
| `E016` | nesting deeper than the 512-level cap (line skipped)
| `E017` | a value, array element or selector body opens a quote or backtick it never closes with the matching one as its last character (`a: "open`, `a: "x" y`). The line is kept verbatim and binds nothing. In a value, the lines under it still load, under the field with no value. In a field name the same typo is `E014`
| `E018` | line written under a line that was skipped (indented beneath it); skipped with it, so a skipped line's block never re-parents one level up. A skipped field line whose value opens a raw block takes the body with it, here and under `E012` and `E021`, so the body is never read as lines. A `- ` item line whose item was refused (`E007` to `E009`, `E011`, `E021`) is a skipped line for this purpose. Under a kept `E012` line it is kept as written too
| `E019` | a bracket array that isn't well formed: text after the closing `]` (`log: [INFO] started`), a bare `[` or `]` inside, an empty element (`[a,, b]`), or no closing `]` on the line. A list item that is an array (`- [a]`) is `E019` too, since arrays don't nest. The line is kept verbatim: it binds nothing, and nothing is counted lost. The lines under it still load, under the field with no value. A read on the field is `Empty` when one of them loads, and `NotFound` when none does. Quote the value if it is text
| `E020` | node cap exceeded (fires only under a caller-supplied cap, see Limits): the parse stopped, and the unparsed remainder counts as lost content
| `E021` | array longer than the caller-supplied element cap (see Limits); the line, or the stacked item past the cap, is skipped whole rather than truncated to a value the author never wrote, whatever its value. A fault in the path or the name is reported first
| `E022` | the diagnostics list was cut at the caller-supplied cap (see Limits): this one entry ends it and counts what wasn't listed. An error when any unlisted one was, so a scan for errors still finds one and a Strict load still fails; a hint otherwise
| `E023` | a bad escape: text between 2 `◉` marks that isn't a name from the escape table, a code point that names no character, or a `◉` with no partner, in a value, an array element, a quoted name or a selector body. A backslash is never an escape. The line is kept verbatim like any other malformed line: it binds nothing, a read on it is `NotFound`, and nothing is counted lost. When only the value has it, the lines under it still load, under the field with no value, and a read on the field is `Empty` once one of them loads. When the name has it and the value is a fence, the raw block is kept with the line. A lookup path or a `SetLiteral` text holding one is refused. Comments, backtick values, raw bodies, and fence labels aren't escape text
| `E025` | a tab or other whitespace but a space, a quote other than an apostrophe inside a word, a bracket, or a colon with whitespace or the end after it, in a bare value (`a: x"y`, `name: O' Brien`, `host: a.com port: 80`); any whitespace or quote in a bare array element (`[New York, Boston]`, `[O'Brien]`); whitespace, a colon, a comma, a quote, a bracket or a paren in a bare selector body (`base(New York)`, `host(a:b)`). Kept verbatim like `E023`; in a value, the lines under it still load under the field. Quote the piece, or put each field on its own line
| `E026` | a bare comma with whitespace or the end after it, outside brackets and quotes (`ports: 80, 443`, `x: a,`), or in a stacked item (`- a, b`). A comma with text right after it is text (`rw,noatime`). The line is kept verbatim. On a field line the lines under it still load under the field; an item stays among the items, and the other items still load. Write the array in brackets, or quote text that has a comma
| `E027` | a stacked item wiht a bare colon followed by whitespace or the end (`- name:`, `- name: value`), which is how YAML starts an object in a list. The line is kept as written, and the other items still load. Quote the item if it is text, or write the objects as instances
| `E028` | an array value on a field with lines under it (`route: [GET, POST]` with fields under it, or `[]`). The line is kept verbatim, and the lines under it load under the field with no value. A field with lines under it takes one plain value or none. A dotted line that reaches the array through an index counts as a line under it, so a `srv(0).tls` line after an array on `srv` makes the array line `E028`
| `E029` | a selector in brackets, the old spelling (`base[Boston].pop: 1`). Selectors are written in parens, `base(Boston)`, and brackets are only for arrays. The line is kept as written and binds nothing. When it selects by value, the lines under it still load, under the instance it names. An index or a wildcard in brackets opens nothing, so the lines under it go with it. A lookup path with one is refused
| `H001` | repeated bare leaf (array written as repeated lines) - the mandatory hint
| `H002` | a binding merged with a non-adjacent earlier one (same name and value combine); legal, but only the parser can see it happened, so it reports it, and the prose names the earlier line. Every merged level under a hinted re-open reports, each naming its own earlier line, so a consumer filtering the hints sees the whole combination, not just its outermost frame; a schema can disavow it per section with `reopen:` (see Schema validation)
| `H005` | a value in another unit than the one its field name ends in, as `timeout-ms: 5s` or `cache-mb: 2GB`. Legal, and a unit in the value wins over the one the name gives a bare number, but the two disagreeing is usually a slip. Only a name ending in a duration or size unit after a `-` or `_` is looked at, and only a value that reads as that kind
| `H006` | the info block's `Format` line names a newer format major than this reader's, so the file may use rules it doesn't know. The load goes on as usual, and no save writes the document (File tier). On the stamp's line, read as `ReadFormatVersion` reads it. The message quotes the number as written
| `H007` | the `Format` line names an older format major than this reader's, so some lines may read differently than written: `p: a,b` was an array in 2.x. The prose points at `shcl upgrade --from-2x`. On the stamp's line, read as `ReadFormatVersion` reads it. The message quotes the number as written
| `H008` | a `#` against text opened a comment, so the piece stops before it: `url: http://h/#frag` reads `http://h/` and `color: #fff` reads nothing. Text sits right before the `#` in a bare value, an array element, a selector body or a fence label, or right after it where that piece is empty (see Comments). The prose names the fix, quoting the value. It changes no outcome, and comes first among its line's diagnostics, since the scan finds it before the line is judged

- A retired code is one no load reports any more. `shcl explain` on a retired code says it was retired and names the code that replaced it, or says that none did, at exit 0 like any code it knows.
	- `E010` is retired. It was a bare comma in a stacked item, and `E026` took its rule.
	- `E024` is retired. It was a Windows path in double quotes with a `\t` or `\n` escape, and a backslash is text now. No code replaced it.
	- `H003` is retired. It hinted at a stacked item written like a field binding, which is `E025` or `E027` now. No single code replaced it.
	- `H004` is retired. It was a hint, and `E024` took its rule before both went with backslash escapes. No code replaced it.

- **Limits**: nesting depth is capped at 512 levels below the document root. A line that would bind a node deeper than the cap is an `error` (`E016`) and is skipped. The Writer refuses to create a deeper path too. The cap bounds every depth-linear walk, so a loadable document can't overflow the stack in any binding. Python and C walk with their own stacks (C fits a 64 KB thread at the cap), and Go's goroutine stacks grow. Rust recurses and needs about 175 KB at the cap, well inside the 2 MB of a default thread. A depth of 512 is far beyond any hand-authored nesting.
	- The other 2 limits are the caller's, through `ParseLimited` (each binding's spelling), for input the consumer doesn't control. A document amplifies to many times its byte size in memory, so bounding the bytes read can't bound what a load allocates. Only counting what the parse builds can do that. A node cap stops the parse once a line takes the count past it. There's one `E020` on the first line not parsed, and the unparsed remainder counts as lost, so a later save refuses rather than writing a silently truncated file. The count is every node the parse builds plus every comment line and kept line it stores, since each costs about what a node does and a file of nothing else doesn't build any node. A cap crossed with only blank lines left doesn't stop anything, so nothing is reported. An element cap refuses any line whose array would have more elements (`E021`), and any stacked item past it. The line is skipped whole and never truncated. That holds whatever the line's value, so a broken value past the cap is dropped too, where within the cap it would be kept. A fault in the path or the name is still reported first. A fence line's info string is split on commas the same way, so a fence past the cap is refused too, and its block is skipped with it rather than read as live lines. A diagnostic cap bounds the list itself, since a document of nothing but bad lines costs a diagnostic per line. The first that many are listed, and one `E022` ends the list with a count of the rest. A cap of 0 disables it, which makes the call the plain strictness parse. All 3 are parse-time caps. What a program writes into a document is its own arithmetic.

- The **Writer** handles the reverse of the Accessor: emit values, defaults, and comment sections, and canonicalize a file (see below). It mirrors the Accessor's typed entry points, with a `Set<T>` per type (`SetInt`/`SetString`/.../`SetRaw`) and their array forms, so a programmatic value comes out as canonical text with no consumer-side formatting.
	- Setters don't take quoting options. A setter that overwrites a value keeps its quote kind, single, double, or backtick, when the new text can be written that way, and otherwise the writer picks. A thousands number such as `1,200` is written bare whatever it overwrites, since in quotes Loose would read it as a number. An array setter writes brackets even for one element, so `SetIntArray` gives `port: [80]` and `SetInt` gives `port: 80`, and over a list written with `- ` it keeps the list stacked. A setter refuses to write an array on a field with lines under it (`HasChildren`), or a field under an array (`UnderArray`).
	- Each setter is the exact inverse of the matching read: `SetString` re-quotes and escapes so the value reads back verbatim; `SetFloat`/`SetInt` emit the same canonical number text the reader accepts; `SetDateTime` stores the canonical spelling; `SetRaw` picks a fence long enough that the content can't close it early and trims the info-string the way a fence line reads it back.
	- `FormatValue(text)` (each binding's spelling) gives the text `SetString` writes after the colon of a field it makes, built by the same emitter and read-back check, so a program that writes config text itself gets the text the writer would write. `2020`, `@null`, `1,200`, and `-x` stay bare, `a b` comes back `"a b"`, and text with both quote kinds is double quoted with `◉DOUBLE_QUOTE◉`. Every scalar setter writes its value's text the same way, so `FormatValue(FormatFloat(v))` is what `SetFloat` writes, and the same goes for an int, `true` or `false`, and a datetime's canonical text, which is quoted when it has a time, for the colon. It gives nothing where `SetString` refuses (`NotUtf8`, `NoReadBack`). It gives one value rather than an array element, which `FormatArray` gives (below). Inside `[]` a thousands number such as `1,200` is quoted, since its comma would split it there. An overwrite can keep the old value's quote kind instead (above). Rust returns an `Option`, Go a second `bool`, Python `None`, C++ an empty `std::optional`, and C a malloc'd string the caller frees, or NULL.
	- `FormatArray(texts)` (each binding's spelling) gives the text `SetStringArray` writes after the colon of a field it makes, brackets and all, through the same emitter and read-back check. So `FormatArray(["80", "a b", "1,200"])` is `[80, "a b", "1,200"]`, one element is `[80]` and none is `[]`. Each element is what `FormatValue` gives for it, except a thousands number, which is quoted in brackets. Every typed array setter writes its values' texts the same way, as for `FormatValue`. It takes what `SetStringArray` takes, gives nothing where that refuses, and returns as `FormatValue` does. C takes the texts and their lengths, as `shcl_set_string_array` does.
	- **A setter writes only what reads back.** It builds its text through the emitter, hands that to the tokenizer, and refuses unless what comes back is the value it was given, so no setter decides for itself what a quote, a `#`, a comma, or a carriage return means. What that refuses follows from the lexical rules rather than from a list. It refuses an info-string with a line break or a `#` in it, since the fence line would read the `#` as opening a comment. It refuses a raw body line ending in a carriage return, since the load takes the trailing run off every line. It refuses a comment with a line break in it, since a comment is one line, and keeping the first would drop the rest silently. The typed setters keep their own render-and-parse-back on top of it, since a value has to read back as its type rather than only as the same text. `SetFloat` fails on an infinity or a NaN, and `SetDateTime` fails on a value the reader wouldn't parse back to the same fields, such as a month of 13, a fraction with no seconds, an offset past a day, or an empty value. A refused write binds nothing, leaves the document byte-identical, and its status says why.
	- A writer-created **top-level** node has the blank-line grouping a hand-written file would have, which is one blank line between top-level sections and never one as the first line. So writer output and hand-written examples agree on layout.
	- A **set** creates the path, with intermediate nodes as needed, and replaces the value at the leaf. A `(value)` or `(index)` selector on the path targets a specific instance, and a `(value)` selector creates the instance if it's absent. A step with no selector that matches more than one instance is refused (`CheckSetPath` = `Multiple`), since the write would have to pick an instance. That applies even where a read of the whole path finds one node, as `srv.port` does when only one of 2 `srv` blocks has a `port`. `port(0)` or `site(1).root` picks one. `Remove` and `ClearComments` act on every node the path reaches.
	- Companions round out the API. `Set<T>Default` makes sure a field has a usable value of its type. It's the "emit defaults" half, and every typed setter has one, `SetRaw` and `SetLiteral` included. It writes where the path is missing, where the field is empty, and where its value doesn't read as that type by the typed read at the document's strictness, and a value it replaces stays above the field as a comment with a note (design.md, Default forms). `SetStringDefault` and `SetLiteralDefault` count any value, since any value reads as a string. A raw block is never replaced by another type, since its body has no one-line comment (`RawBlock`). Where the value reads, it writes nothing but still refuses what `Set<T>` would refuse, the value included. `SetLiteral` takes the value as **syntax** rather than data. It reads its argument the way the parser reads the half of a line after the colon, so a caller with value text writes `[80, 443]` as a 2-element array without having to know its form first, and it's how a backtick value goes in. Whatever a file line gives with that text is what gets stored, so a trailing blank comes off. What it refuses is what a file reports as an error, since a setter doesn't have a diagnostic to report it with: a line break, which no file line can contain, a piece that opens a quote it never closes (`E017`), a malformed array (`E019`), a bad escape (`E023`), whitespace or a quote in a bare piece (`E025`), and a bare comma (`E026`). It also refuses a `#` outside quotes, which a file reads as a comment, since the text after it would be lost with no status to say so. Text a file line wouldn't read as a value at all, such as a fence opener, is stored as the string it gives, since the call reads a value half rather than a line. `Exists` reports presence. `SetComment` attaches a leading comment line, and creates an empty node so a section can be annotated. It puts a node's blank separator line above the comment so the comment is right against its node, and it refuses text that has a line break in it. A node's comment lines are the run right above its line with no blank line between. A run a blank line sets off from the line below it is the line above's, or the file's at the top, so it isn't the node's (design.md, Lines an edit takes from their node). A setter or a merge that replaces a stacked list puts the comments among its items and on them by the same rule, right above the field's line with the field's blank line above them (design.md, Lines an edit takes from their node). `ClearComments` takes every comment line above a node back off, so a comment can be replaced rather than added to. A comment on the node's own line stays, and so does a line kept for being malformed. `Comments` reads those same lines, each from its `#` on, so a program can tell a comment it wrote from one a user put there. `Remove` deletes the node(s) at a path, each with its comment lines above it, back to a line kept for being malformed or the line before them, the comment on its own line, and the comment lines right under its block, up to a blank line. A run a blank line sets off from the line below it isn't that line's, so in `# c`, a blank line, `b: 2`, a remove of `b` leaves `# c`. `ReadExists`, `ReadComments`, `TryRemove`, and `TryClearComments` give the same results with a status, as described under [Status sentinels](#status-sentinels).
	- Every setter returns a status, `SetStatus` (each binding's spelling): `Ok` when the write applied, or why it wrote nothing. A refused write doesn't apply anything or leave half-created intermediates. The CLI reports it as exit 1, with the reason the status gives, rather than silently printing the untouched document. A write is refused for its path or for what it would write, and when both are wrong the path's reason wins. The path reasons are `BadPath`, `ValueInPath`, `Wildcard`, `NoSuchIndex`, `TooDeep`, `Multiple`, and `UnderArray`. `CheckSetPath(path)` (each binding's spelling) checks the path alone, running the same validation the setters run and creating nothing, and gives `Ok` or one of those. The value reasons are `HasChildren`, `NotFinite`, `BadDateTime`, `BadRawInfo`, `BadRawBody`, `BadComment`, `NotOneValue`, `NotUtf8`, `OutOfRange`, `NoReadBack`, and `RawBlock`. The Write outcomes table in design.md says when each one is given. The values are in that order in every binding, `Ok` first, and a new one goes on the end.
	- Dropping a setter's status is the one write failure that leaves no trace, because the save that follows writes a document missing the edit and reports success. So the reference marks the status `#[must_use]`. The other bindings don't have an equivalent and say it in their documentation instead.
	- A write that makes a node collide with a same-named sibling under the in-file merge rule folds the pair the way a reparse would, so written output is a formatter fixpoint like any other canonical output.
	- On the CLI, `set --write` rewrites FILE in place, like `fmt --write`, through a temp-file-and-rename in the same directory, so an interrupted write can never truncate the config it rewrites. `set --write` also **creates** FILE when nothing is at the path yet, so a first write doesn't need a `touch` beforehand. `fmt --write` doesn't have anything to format, and it still reports the file missing. A FILE that exists but can't be read is an error either way, and never something to quietly write over. A created file starts out as the info block `init` writes (see "Schema-driven generation"), so a new config says what format it is. The edits go above it, separated from it by one blank line as in generated output, and `--no-banner` leaves it out. A file that already exists is never given one. A file that turns up at the path while the command runs, during the wait for ops on stdin for example, is left as it is, and the write fails at exit 8. So does a FILE whose bytes changed after the command read them: `--write` reads it again right before the save, so an edit made meanwhile is never reverted.
	- The rename publishes a new file, so FILE is resolved through symlinks first. A linked-in config is written through rather than replaced, a link to a file that doesn't exist yet gets that file created where it points, and a symlink cycle fails with too many levels of symbolic links and writes nothing. The file's mode is kept, setuid, setgid, and sticky bits included, as an editor's rewrite would keep it.
	- The temp file is created exclusively, so an existing file or symlink under the name it wants is never written through, and it's created private, so a private config is never briefly readable to anyone else. The target's mode goes on after the data is written and synced, right before the publish, so the kernel's clearing of setuid and setgid on write can't strip what was copied.
	- A path that names a directory rather than a file is refused, which means one that ends in a separator or whose last component is `.` or `..`. A document isn't a directory, and the platforms disagreed about whether such a path even reached the filesystem. A link whose own text ends that way is refused too.
	- Only a regular file is replaced. A directory, a FIFO, a socket, a device, or anything else that isn't a regular file is refused at exit 8, since a rename would swap it for a regular file. `--write` asks before it reads FILE, so a FIFO isn't drained.

	- Any other hard link to the old file keeps the old content. That's inherent to publishing a new file in the old one's place, and so is everything else a file has outside its permission bits: POSIX ACLs, extended attributes, and the SELinux label among them, and on Windows a file's own explicit ACEs and alternate data streams. The owner isn't kept either. The new file belongs to whoever ran the save, which only shows when that isn't the old file's owner. The group is kept, best effort, so a config a service reads through its group keeps that read. A saver who isn't in the old group leaves its own group on the file, as it did before. In a sticky directory such as `/tmp` the rename is refused for a file the saver doesn't own, and the save reports it.
	- A read-only file is rewritten, since the rename needs the directory rather than the file, and the new file comes back read-only. Windows clears the attribute for the publish and sets it again after, so the platforms agree. Windows closes most of that gap where it can: the publish goes through `ReplaceFile`, which copies the destination's ACLs, security attributes, and named streams onto the replacement, and falls back to a plain replacing move when the file is being created or the merge can't be done. Neither keeps the basic attributes, so hidden and system are re-applied after the publish along with read-only. `ReplaceFile` moves the old file to `.NAME.bakPID.N` beside it before it moves the new one in. If the second move fails, the old file is moved back. If that fails too, nothing is at the path, and the save keeps both files and fails with an error that names them: the old file at the backup name and the new text at the temp name, `.NAME.tmpPID.N`. The C binding reports `errno` only, so its header gives the names instead. A publish that is refused is tried 5 times, 50 ms apart, since a scanner or an indexer reading the fresh temp file blocks it for a moment. Over an existing file, the temp file is created with that file's DACL, so the new text is never open to anyone the file shuts out, and a fallback move keeps the DACL too. When the DACL can't be read, the temp file takes the directory's, as a new file would. On POSIX the containing directory is synced after the rename, as the file is before it, so a power cut can't lose the publish itself and leave the old content in place.
	- The CLI prints the load's diagnostics to stderr on every subcommand that loads a file, whether or not `--write` is given, and an in-place write **refuses**, exiting 7, while `LostCount()` is nonzero. That's the same `SaveFile` gate a consumer program gets (see the file tier below), and `--lossy` is the CLI's spelling of the override. Without the gate a recovered load would delete the line it couldn't re-emit at exit 0 with nothing on either stream. `set` and `migrate` without `--write` ask the same gate and exit 7 where the write would, so `shcl set f ... > f.new && mv f.new f` stops where an in-place write does. `set` prints nothing then, and `migrate` still prints its text, which keeps every line until it is loaded. A file that names a newer format (`H006`) is refused at 7 the same way, by `--write`, `set` without it, and `fmt --check`, and nothing overrides that.

### File tier

Every consumer that persists a config writes the same load and save steps again, and the file lifecycle is where those consumers' bugs are. So the library has a small optional file tier rather than leaving each caller to work it out alone.

- `LoadFile(path)` and `LoadFileWith(path, strictness)` read and parse in one call, and they never fail below Strict. The document always comes back usable, and empty when the file couldn't be read. It comes with a **file status** that separates the 4 cases a hand-rolled load path otherwise confuses: `Clean` (parsed, no error diagnostics; hints allowed), `HadErrors` (parsed with error diagnostics, and recover-and-continue means the document is still worth having), `NotFound` (no file at the path), and `Unreadable` (present but unreadable: permissions, a directory, bad encoding). At Strict, a file that parsed with an error fails the load the way `ParseWith` does, with the recovered document inside the error. A file that couldn't be read doesn't have any diagnostics, so it gets its status at every level.

- `ReadFile(path, maxBytes)` (each binding's spelling) is the load's read half on its own: the file's text, or the same status saying why not. A file past `maxBytes` is reported `Unreadable`, and a `maxBytes` of 0 means no cap. `LoadFile` is this plus a parse. It's there for the consumer that needs the exact bytes it last saw, to tell its own save coming back as a change notification from somebody else's edit. It's also for a consumer that wants a bound on how much it will read before a parse. Either one used to mean keeping a hand-rolled read beside the library.

- `SaveFile(doc, path)` writes the document's canonical text through the same temp-file-and-rename mechanics the CLI's `--write` uses (described above), so an interrupted save can never truncate the config it rewrites. The CLIs call this same code, so the two can't drift.

- A second save **keeps the lines** an edit didn't touch. `ParseKeepLines` and `LoadFileKeepLines` (each binding's spelling) load a document that keeps its text, and `ToTextKeepLines` and `SaveFileKeepLines` write it back: each line no edit touched byte for byte, a changed value into its own line with the name, spacing, and comment around it left alone, and a new line at the indent of the lines around it. A changed line keeps its own line ending, and a new one ends the way most of the file's lines do, so a CRLF file stays CRLF. A tie goes to LF. The text has to load back as the edited document, with no error the file didn't already have. When it wouldn't, as after a merge, or a child added under a flat dotted line, the save writes the canonical form instead and reports which one it wrote. A document the text wasn't kept for, a merged one included, always gets the canonical form. A line the load dropped comes back as written when the lines are kept, so the refusal below applies only when the save writes the canonical form. `set` saves like this, and `fmt` and `SaveFile` write the canonical form.

- A save that **creates** a file has no mode to preserve, so the file gets the `0666 & ~umask` an ordinary create would produce, which are the same bits the user's editor or shell redirect would have given it. An existing file keeps the permission bits it already had, which is the case the temp file is created private for. The `mode` save option gives a file the save creates those permission bits (`0777`) exactly, set on the file so the umask doesn't narrow them, and 0 is the ordinary create. It does nothing to a file already there, and nothing on Windows.

- The `create` save option makes a **create-only** save. It's refused when anything is at the path, a link to nowhere and a file another save makes at the same time included, and nothing is written. It's checked after the lost-content gate and before the changed check, and `force` doesn't override it.

- A document whose text names a **newer format** (`H006`) reads and edits as usual, but no save writes it, since it would write the lines by these rules under a Format line that says otherwise. `NewerFormat` (each binding's spelling) says so, for a load, a parse, or a merge with such a layer, and every save of it is refused, wherever it goes, with nothing written. It's checked first, before the lost-content gate, and no option overrides it. `WriteFileAtomic` writes the text it is given, and `UpgradeFile` leaves such a file alone.

- The save **refuses** when the write would delete content from the file, which is when `LostCount() > 0`, as described under [Diagnostics and writing](#diagnostics-and-writing). `SaveFileLossy` (each binding's spelling) is the explicit override, so deleting a user's line that can't be parsed or retained is always the caller's stated choice and never an accident. Retained content-malformed lines don't trip the gate, since they survive the save.

- The save also **refuses** when what is at the path isn't what this document has seen there. Right before the write it reads the path as given, and the bytes there have to be, byte for byte, what the load read or what this document's last save wrote. So another program's edit isn't lost to a save that never saw it. The same goes for a file nobody read. A save-as onto a file the document never read is refused too, as an editor asks before it writes over one. That includes a document from `Parse`, and one whose load couldn't read the file, since neither read any bytes. When nothing is at the path, there aren't any bytes to lose, so the save writes there, as an editor does: a save-as to a new name, and a file removed since the load, are both written. A touch alone isn't a change. No path is compared, so one file gives one result however its path is spelled: through `..`, a link or a hard link, or under a folder made since the load. The same relative name from another working folder is another file, one the document never read. A file the check can't read is a change, since the rename that replaces it doesn't need read access. Something that isn't a regular file is left to the write, which refuses it, and so is a path the write can't reach a file through: part of it a file, a folder not there, or a link cycle. The check never waits on a FIFO. A path that names a directory is refused as one before the check. It's a check rather than a lock, so an edit between the check and the rename is still lost. `SaveFileWith(path, options)` (each binding's spelling) is the save with its options, `lossy`, `keepLines`, `force`, `create`, and `mode`, and the other 3 saves are its short forms. `force` is the override, for a caller that means to replace whatever is there. A save records what it wrote, so it is a write: Rust's saves take `&mut self`, and the C++ veneer's aren't `const`. `UpgradeFile` keeps its own check, and the CLI's `--write` keeps its own, since the CLI parses the text it read.

- A refusal and a failed write are **separate values** rather than 2 spellings of one message, because they need different handling. A refusal is the caller's to reverse, and a write failure comes from the disk. The gate is checked before any I/O, so an unwritable path still reports the refusal. Each binding uses its own channel for that: Rust `SaveError::Refused`/`SaveError::Changed`/`SaveError::Exists`/`SaveError::TooNew`/`SaveError::Io`, Go a `*SaveRefused`, `*SaveChanged`, `*SaveExists`, or `*SaveTooNew` error (`errors.As`), C `SHCL_SAVE_REFUSED`/`SHCL_SAVE_CHANGED`/`SHCL_SAVE_EXISTS`/`SHCL_SAVE_TOO_NEW`/`SHCL_SAVE_FAILED` against `SHCL_SAVE_OK`, and Python **raises** `SaveRefused`/`SaveChanged`/`SaveExists`/`SaveTooNew`/`SaveFailed` rather than returning a message, since a returned message lets the obvious spelling, which is the call on a line of its own, report success while doing nothing.

- A failed write says **why** as a value, a write status (`WriteStatus`, each binding's spelling), beside the message, so a program can tell a missing folder from no permission or a full disk without reading the text. The values are listed here in order, numbered from 0 in every binding: `Ok`, `NotFound` (the folder isn't there, or part of the path is a file), `Unreadable` (`UpgradeFile` couldn't read the file as UTF-8 text), `PermissionDenied` (also `UpgradeFile` not allowed to read the file, and on Windows a file another process has open), `DiskFull` (the disk or the quota), `ReadOnly` (a read-only filesystem or write-protected media), `IsDirectory`, `NotRegular` (a FIFO, a device, or a socket at the path), and `Other`. `NotFound` and `Unreadable` are the file status's names. `WriteFileAtomic`, the saves, `WriteBackup`, and `UpgradeFile` give it: Rust in a `WriteError` that `SaveError::Io` and `UpgradeError::Io` contain, Go in a `*WriteError` reached with `errors.As`, Python as `.status` on `WriteError`, `SaveFailed` and `UpgradeFailed`, and C through a last `shcl_write_status *why` (may be NULL) beside `errno`. Only C hands back `Ok`. A Windows system code is sorted by one table every binding shares, since each language files a held file or a missing network path somewhere different.

- `UpgradeFile(path, fromV2)` (each binding's spelling) is for a program whose own shcl upgrade can leave it with a config file it can't load. It's opt-in, and meant to run on every start, before the load, without `fromV2`. A file that names this format isn't written, and a beta build of 3.0 stamped the same Format line, so nothing in the file tells one apart. The caller can tell them apart. With `fromV2`, a file naming this format that loads with an error is taken as 2.x and written like any other, backed up under `format-v3`. With `fromV2`, any file is written only when the fresh file loads clean, one with no Format line too. Otherwise nothing is written and the lines still in error are reported, since a second run would take the result as 2.x again. `fromV2` is for a file the caller knows is old, such as one a beta wrote, and never for every start, since a file this format wrote that picks up an error later would be read by 2.x rules too. A file that loads with no error under these rules is left alone too, unless `fromV2` says it's 2.x and `migrate` would change it. For example, `p: a,b` loads clean as one string, and was an array under 2.x. A 2.x file `migrate` leaves as it was doesn't have anything to do, unless its Format line names an older format. Then, with `fromV2`, that line alone is rewritten to name this one, indent and line end kept, after the backup, so the load's `H007` hint goes away. Anything else goes through `MigrateUnstamped`, is saved keeping its lines, the way `set` saves, and gets the info block `init` writes at the end, in place of an old one there, 2.x's `#` one included. So each line, blank ones included, stays where it was, and a line number in the old file names the same line in the fresh one. Where the lines can't be kept, or keeping them keeps an error the canonical form repairs, such as a missing colon, it is written the way `fmt` writes it. A whole block above the first field stays, so a file with its block at the top comes out with 2, both naming this format. That makes it the one library write that adds the block. The original is first copied under the backup name `migrate --write` uses, by an exclusive create, synced, at the original's mode, and the fresh text then replaces the file through the save's temp file and rename, so the path always has one or the other. A taken backup name is never written over. A file that changed since it was read, or whose text reads 2 ways and doesn't say it's 2.x (`fromV2` settles that, as `--from-2x` does), is left alone and reported. Lines and values the fresh file can't contain don't stop it, since the backup has them. The result counts them and names the backup. `Upgrade` is the text half alone, and `BackupFileName` and `WriteBackup` are the backup half, for a program that writes its own new text. `WriteBackup` refuses a file that isn't there or isn't a regular file, as `UpgradeFile` does, so a file and text passed the wrong way round write nothing. `shcl upgrade` is the CLI's spelling. It exits 7 for text that reads 2 ways or, with `--from-2x`, a fresh file that would still have an error, and 8 for a taken backup name or a read or write that failed.

- The tier is a companion rather than part of the core. C guards it behind `SHCL_NO_FILE_IO` so an embedded consumer can compile the library with no file I/O at all, and the C status enum is `shcl_file_status` with the load's status as an out-parameter (may be NULL).

## Canonical formatter

The formatter normalizes structure only. It can't know value types, so it never rewrites value text, and `.5` never becomes `0.5`. There are 2 normalizations to know about. Field names are case-insensitive, and the canonical spelling is the folded, ASCII-lowercase one, so `Max-Upload-MB:` comes back `max-upload-mb:` from `fmt`, which matches how every read and merge already treats the name. And a blank line an author put between bindings survives as one blank, with runs collapsed, so grouped configs stay grouped through `fmt --write`. It loads at the requested strictness like every other operation, and a document that fails a strict load doesn't format anything, since the load failure is the result. `fmt --check` prints nothing and exits 6 when a rewrite would change the file, or 0 when it wouldn't, so a tree can be checked for non-canonical files without diffing each one. It can't be combined with `--write`, `--layer`, or `--set`, since a merged or edited document is never the file. It asks the save gate first, so a file whose load dropped a line exits 7 the way `fmt --write` does, rather than promising a rewrite that would be refused.

- Use block (indented) form, with tabs for indentation.

- Preserve the file and insertion order of instances and fields, so index-based access stays stable.

- Collapse and merge redundant sections and paths.

- Preserve comments as attached trivia. A whole-line comment attaches to the node bound by the next non-comment line and re-emits right above that node's line, at its indent, plus one tab for each level it's under the comment before it, as described under [Comments](#comments). A trailing comment stays on its line, with 2 spaces before the `#`. Comment text is never rewritten.

- When instances merge, their comments concatenate in encounter order, and a second trailing comment moves to the lines above, since a canonical line has room for one. A list written with `- ` stays stacked. A comment trailing an item stays on its item, and a whole-line comment or a kept malformed or misplaced line among the items stays where it was, so a fix typed into it stays in the list. A stacked list after an empty instance of its name is written in brackets anyway, since its bare header would merge into that instance on re-read, and the lines and comments among its items go above it. A field line kept among or after its items (`E001`) would bind there, so it goes out as a comment. Top-level comments after the last binding line re-emit at the end of the output, unindented, and indented ones stay with their block.

- Quote a value, item, or array element that has whitespace, a colon, a comma, a paren, or any other reserved character (see Whitespace, quoting, and reserved characters). Keep the author's quotes adn quote kind on every value, backticks included. Quotes are never dropped. Arrays are written `[a, b]`, and a list written with `- ` stays stacked (see Arrays).

- Leave scalar text exactly as authored, and re-emit raw blocks verbatim. A block value canonicalizes to the child-indent spelling, which is a bare `name:` with the fence and its info-string on the next line at child indent. There's one field line per block instance.

- A couple of narrow exceptions keep round-trips exact. If an *earlier* instance of the same field under the same parent is empty, the child-indent header line would merge into it on re-read and the fence would fill that instance, so the formatter emits that block in the same-line spelling instead. And an info-string that *starts with* the fence character gets one space after the fence, so it can't lengthen the fence run on re-read. A block emitted in the same-line spelling also moves any trailing comment to the lines above, because after the fence it could read as part of the info-string on re-read.

## Schema validation

A schema is an ordinary SHCL file: a flat list of instances of one field named `field`. Each instance's *value* is a document path, and its children are the constraints on that path. Document paths appear in value position, never as field names, so the schema vocabulary can never collide with a document's own field names. `Validate(doc, schemaDoc)` returns the same structured diagnostics loading produces. A one-shot `LoadAndValidate(text, schemaText, strictness)` parses and validates in one call and hands back the document with one combined diagnostics list, parse first and then validation, which is the order `check --schema` prints. That way half the errors can't vanish because a caller merged only one of the 2 lists. Below Strict it never fails, and `ErrorCount()` tells whether the file had errors. At Strict any error in the combined list fails it the way `ParseWith` fails, a schema finding included, with the validated document inside the error. The `shcl check --schema SCHEMA FILE` CLI appends them to `check`'s normal output under the same stdout/exit contract, at strict as well. `check` doesn't write anything, so a strict-failing load still gets validated and still reports what the schema found. The summary line stays `strict load failed`. `LoadAndValidateWith(text, schemaDoc, strictness)` is the same call with the schema already parsed, so a program that validates on every start parses its schema once. The text form is that call on the parsed text, except that an empty schema text skips validation, where an empty schema document declares nothing and every field is unknown, as `Validate` finds. `ParseWith` then `Validate` isn't the same. The document's `Diagnostics()` and `ErrorCount()` keep the load's values, the hints the schema disavows stay, and Strict fails only on a load error. No grammar change is involved. The validator interprets the schema vocabulary, and the parser doesn't know anything about it.

~~~shcl
field: server.port
	type: int
	required: yes
	min: 1
	max: 65535

field: "server(*).host"
	type: string
~~~

A path with a selector reads bare too, `field: server(*).host`, since a paren is text in a value. One with a quote or a `#` in it needs the outer quotes, such as `field: 'srv("New York").port'`, and the writer adds them itself. When 2 `field` instances have the same path, they merge by the language's own merge rule, so constraints for one path can be written in one place or several.

The constraint vocabulary is closed, and nothing joins it without a spec change:

| Key                | Value                                                                                                                                    | Meaning
| :---               | :---                                                                                                                                     | :---
| `type`             | `int` `float` `bool` `string` `datetime` `raw` `duration` `size`, or `<scalar>-array` (no `raw-array`, `duration-array`, or `size-array`) | every value at the path must coerce to this type, at the *document's* strictness
| `unit`             | a unit spelling                                                                                                                          | `duration` and `size` only: the unit a bare number takes when the field name gives none
| `decimal`          | boolean                                                                                                                                  | `size` only: `KB` to `TB` are powers of 1000
| `required`         | boolean                                                                                                                                  | the path must resolve (see wildcard rule below)
| `allowed`          | array                                                                                                                                    | closed set of permitted **element** values, compared in the coerced space of `type`, written `allowed: [debug, info, warn]`. Every element of a multi-element value has to be in the set, so `allowed: "x, y, z"` is one element and admits none of the 3 in `c: [x, y, z]`. A string or untyped field's set sees an array's bracket text, while a typed scalar field reads `[80]` as 80 for `allowed`, `min`, and `max`. For `datetime` the coerced space is the moment: `12:00:00Z`, `12:00:00+00:00`, and `12:00:00-00:00` are one value, and so are `12:00:00` and `12:00:00.0`, while a value with no zone is local and matches no zoned one. Written seconds count, unlike a zero fraction: `12:00` and `12:00:00` are 2 values, so `allowed: "12:00:00"` refuses `12:00`. `raw`, `duration`, and `size` take no `allowed`; bound a duration or size with `min` and `max`
| `min` / `max`      | number, or a duration or size                                                                                                            | inclusive bounds, `int`/`float`/`duration`/`size` kinds only, a duration or size read the way the document's value is: its own unit, then the unit the field name ends in, then the schema's `unit`, so `min: 100` on `hold-ms` is 100 ms. A path ending in `*` has no one name, so there a bare bound needs `unit`. Checked per element on arrays. A `min` above its `max` admits nothing, so it is a schema fault and the range is dropped (the field keeps its other constraints) rather than every value being told off twice
| `repeat`           | one integer (exact) or an array of two (min, max), `repeat: [1, 3]`                                                                      | bounds the instance count at the path, per resolution context
| `inherits`         | fragment name                                                                                                                            | the subtree at this path has the named fragment's shape (see Fragments below)
| `reopen`           | boolean                                                                                                                                  | the section at this path is meant to be written in parts; `true` disavows `H002` for its leaf name (validation itself ignores it)
| `default` / `desc` | any                                                                                                                                      | reserved for the schema-driven generator; validation ignores them

Semantics:

- The schema file itself always loads at Standard, and its constraint values (booleans, numbers, the `allowed` set) are read at Standard, because a schema is a program artifact rather than user data. The *document's* values coerce at the document's strictness, so `type: int` against `3.5` passes at Loose, which rounds, and fails at Standard.

- An empty value passes `type`, `allowed`, `min`, and `max`, and counts as present for `required`. Present but without a value is what `Empty` means everywhere else.

- On a path with no wildcard, `required` means at least one instance resolves. Through a wildcard, it's a per-instance rule, so `server(*).port` requires a port under *each* server. It's vacuously satisfied when no instances exist, so require the parent separately if it must exist.

- A `repeat` upper bound above 1 also **disavows `H001`** for that field. The schema declares repetition as that field's instance mechanism, so the repeated-bare-leaf hint would be a false positive there. `check --schema` and the one-shot load-and-validate drop those hints, matched by leaf name, but plain `check` without a schema keeps them.

- `reopen: true` **disavows `H002`** the same way. A section declared as meant to be re-opened merges by design, so the merge hint would train its users to ignore hints. The mechanics are the same as for the `H001` disavowal. The hints are dropped at `check --schema` and the one-shot, matched by leaf name, and kept by plain `check`. A bad `reopen` value is a `V092` schema fault, so a typo can't silently disavow nothing.

- `repeat` and `required` evaluate per *resolution context*: the whole document for a plain path, each enclosing instance for the part of a path after a wildcard. So `field: server` + `repeat: [1, 10]` bounds the server count, while `field: "server(*).port"` + `repeat: 1` means exactly one port per server.

- An **open section** has children with any names, each laid out the same. It's declared with the name wildcard, so `field: indicators.*.period` + `required: yes` requires an int `period` under *each* child of `indicators`, whatever the child is called. A `*` segment resolves every child, whatever its name, and splits contexts per child exactly as `(*)` splits per instance. So `required`/`repeat` after it are per-child rules, vacuously satisfied when there are no children. For the unknown-field sweep, a `*` matches any one name at its position, with prefixes legal as usual, so an open section's children are never unknown while anything outside the declared layout still is. "Did you mean" suggestions don't go below a `*`, since there's no fixed sibling list to suggest from. A `repeat` above 1 on a `*` leaf doesn't disavow any `H001`, since there's no single leaf name to disavow.

- Quoting in a schema path works at 2 levels, and the difference matters. The outer quotes are ordinary SHCL string quotes around the value, and a path needs them whenever it has something a bare value can't, such as a quote or a `#`. A paren isn't one, so `field: server(*).host` and `field: "server(*).host"` are the same path. Those outer quotes are removed before the path is read, so wildcards inside a quoted path are still wildcards: `field: "server(*).*.port"` composes both kinds. To make a segment a *literal* name, quote the segment itself, inside the value: `field: '"*"'` is a field literally named `*`, and `field: '"*.example.com"'` is a field literally named `*.example.com`. Take care with the difference. `field: "*.example.com"` is an open section rather than that field. A `*` there matches every top-level name, each expected to have an `example.com` child, so it legalizes every top-level name for the unknown-field sweep. When a literal name is what is meant, quote the segment.

- **Fragments** name a reusable shape. A top-level `fragment: <name>` instance contains ordinary `field:` instances whose paths are *relative*. `inherits: <name>` on any field mounts that shape at the field's path. So "this subtree has the shape of that one" is one line, and a shape used at 2 paths is 2 mounts.
	- A **recursive** structure, such as a layout block that contains layout blocks, is a fragment whose field `inherits` itself. Self- and mutual references are legal, with **no depth limit**: validation expands a mount only where the document has nodes, and every mount descends at least one level of a finite document, so termination is structural and cost is proportional to the document, never the schema's unfolding.
	- Semantics: a mounted fragment's fields evaluate per resolved node at the mount path, running right after the node's own checks in fragment order, depth-first. That node is the context, so `required` and `repeat` inside the fragment anchor to it, like the segment after a wildcard. The mount's field keeps its own constraints, which apply to the mount node itself, and other `field:` paths through the mount point compose freely.
	- For the unknown-field sweep, a chain that walks a mount continues against the fragment's fields, with prefixes legal as usual, but suggestions don't descend mounts. A `repeat` above 1 on a fragment field disavows `H001` by leaf name exactly as a top-level one does.
	- When 2 `fragment` instances have the same name, they merge by the language's own merge rule and their fields combine. `field` is the only key legal inside a fragment.
	- Faults: a nameless or malformed declaration is `V094`, and an `inherits` that doesn't name a declared fragment is `V095`. Both are schema faults, reported like the rest of `V09x`, and a mount that names a missing or dropped fragment doesn't check anything at the mount. A second declaration of one name isn't a fault, since the parse merges the 2 before the validator sees them, and reports `H002`. Validation checks each fragment at each node once, so a fragment mounted by 2 paths that both reach the same node costs one pass rather than 2.
	- Generation has to lay every path out flat rather than follow the document, so that way it does bound the unfolding: a mount chain reaching the nesting cap is noted like a re-entering one instead of expanded, a path deeper than a document may nest goes to the trailing note, and a schema whose mounts multiply past the field ceiling is a `V096` fault rather than output that nothing can contain.

- A field in the document that no schema path covers is an unknown field. Legality is by name chain, with selectors ignored. Every schema path legalizes its own chain and every prefix of it. Only the topmost unknown node is diagnosed, and its subtree is skipped. The "did you mean" suggestion is in the prose message only and never in the code, because edit-distance output can't be pinned for parity.

- All validation diagnostics are `error` severity, and their order is deterministic: schema faults in schema order first; then per schema instance in schema order - `required`, `repeat`, then per resolved node in file order `type`, `allowed`, `min`, `max` (a node failing `type` skips its remaining checks) - then unknown fields in document order. The unknown-field sweep runs too, unless a fault cost the schema a path spelling, as a `field:` whose path is unreadable does, or a mount that doesn't name a declared fragment. Only those can turn declared fields into false unknowns, so only they make the sweep skip rather than misfire. A key-level fault, such as a broken `type:` or `min:`, keeps its entry, whose path still legalizes its name chain.

Validation diagnostics use the existing structure (line, severity, stable code, prose), with codes in a `V###` range disjoint from the parser's `E###`/`H###`. Line numbers are document lines. Line 0 means document scope, where nothing was written. Through a wildcard, a per-instance `required` miss gives the enclosing instance's line:

| Code            | Meaning                                                                                                                                                                | Line
| :---            | :---                                                                                                                                                                   | :---
| `V001`          | unknown field                                                                                                                                                          | the topmost unknown node
| `V002`          | required path missing                                                                                                                                                  | 0, or the enclosing instance under a wildcard
| `V003`          | wrong type                                                                                                                                                             | the node
| `V004`          | value not in the allowed set                                                                                                                                           | the node (first offending element)
| `V005` / `V006` | below `min` / above `max`                                                                                                                                              | the node (first offending element)
| `V007`          | instance count out of `repeat` bounds                                                                                                                                  | 0, or the enclosing instance under a wildcard
| `V090`          | unknown schema key                                                                                                                                                     | schema file
| `V091`          | unknown schema type name                                                                                                                                               | schema file
| `V092`          | bad schema constraint value (also: `min`/`max` without a numeric `type`, `allowed` with `type: raw`)                                                                   | schema file
| `V093`          | bad schema path                                                                                                                                                        | schema file
| `V094`          | bad fragment declaration (no name, or a non-`field` key inside)                                                                                                        | schema file
| `V095`          | `inherits` names no declared fragment                                                                                                                                  | schema file
| `V096`          | schema expands to more fields than generation allows                                                                                                                   | 0 (a document line space, not a schema one)
| `V097`          | generated output doesn't load, or fails the schema that produced it (a `default` outside its own field's constraints, say), or a must-exist path nothing can generate | 0 (a document line space, not a schema one)
| `V099`          | schema failed to load (schema had error diagnostics)                                                                                                                   | 0

A schema fault (`V090`+) doesn't silence the rest of the result. The constraints that parsed cleanly still check the document, since a broken key drops that key and a broken `field:` drops that field. So a typo in one constraint can't hide a real violation of another. The unknown-field sweep needs the complete declared vocabulary of *names*, and a key-level fault keeps its entry's path, so the sweep still runs. It turns off only when a fault cost a path spelling outright, as with an unreadable `field:` path or a mount that doesn't name a declared fragment. A schema that doesn't load is different. An error diagnostic of its own, such as a quote that never closes, loses its line and the constraints on it with no fault to say so. `Validate`, `LoadAndValidate`, `LoadAndValidateWith`, `check --schema`, `generate`, and `init` all report it with a lone `V099` and don't check anything. Generation (`shcl init`) still requires a fault-free schema, since a partial starter config would be worse than an error. `check --schema` folds validation diagnostics into `check`'s existing output: same `line N: severity: CODE` stdout lines, the same line plus its prose on stderr, same summary line and exit-6-on-any-error rule. Both streams include the code, but only stdout is the contract. A `V090`-`V095` line number is a schema-file line, as the table above shows. The stderr prose writes those as `schema line N` so the 2 number spaces can't be confused, while the compared stdout keeps the uniform `line N` form, since the code already names the space.

A config file can name its own schema on a comment line written like the info block's `Format` line, so `check` and an editor find it without being told.

- For example:

	~~~shcl
	##    Schema   ./app.schema.shcl
	port: 8080
	~~~

- The line is `##    Schema   ` then a path or a URL, at the start of a line or after its indent, anywhere in the file. The formatter indents a comment to the field below it, so an indented line counts the same. The same goes for the `Format` line. The first such line wins, and one inside a raw body is that block's content. `SchemaRef` returns what it names, and `SCHEMA_LINE_HEAD` is its spelling, for a program writing one. `ReadSchemaRef` gives it with a status: `NotFound` with no line, and `Empty` for a Schema line with nothing after the word.

- `check` without `--schema` validates against it, reading a relative path from the config file's directory, or from the working directory when the file is stdin. A `--schema` on the command line wins. A schema the line names that can't be read fails the check the way a missing `--schema` file does, with exit 8. So does one that isn't a regular file, such as a device or a FIFO, and on Windows a path starting with 2 slashes or backslashes, or with `\??\`, which names a network share or a device. So does a file over 16 MiB.

- A URL is for editors. `check` doesn't fetch one, and says so on stderr, since a check that reads the network because of a line in a file isn't one to run unattended.

- `ReadNamedSchema(text, file)` is that read as a library call, and `check` goes through it. `file` is the config's path, and only says where a relative path starts. It gives back the schema's text, or a `SchemaStatus` saying why not: `NotFound` and `Empty` as `ReadSchemaRef` has them, `Url`, `NetworkPath` on Windows, `FileNotFound`, `IsDirectory`, `NotRegular`, `TooLarge`, or `Unreadable` for anything else, such as a file that isn't UTF-8. It also gives the path it read, or the URL as written, the line number, and a message naming the path. A URL is never fetched.

- `SetBanner` rewrites the info block and keeps a Schema line that sits in it, where the block was. A block at the end that already reads as the one this release writes stays as it is, the Schema line in it.

## Layered loading

Composing a config from defaults, then a site file, then a user file, is `merge` applied as a left fold: `Load(defaults, site, user)` overlays each later document on the accumulation of the earlier ones, so the last file wins. `merge(base, over)` takes 2 already-parsed documents and overlays `over`, the higher priority, onto `base`. It's a library operation, and it doesn't change the grammar.

The overlay rule, per parent scope:

- A **leaf** name present in `over` **replaces** every `base` child of that name, spliced in at the first replaced position, provided the `base` children of that name are themselves all childless or absent. A leaf name is one whose `over`-side nodes don't have any children, so each is a scalar, an array, or a raw block. This is real override. A later `port: 9090` wins over an earlier `port: 8080`, a later `tags: green` replaces the earlier repeated-leaf list `tags: red` / `tags: blue` wholesale rather than appending to it, and a bare `port:` clears the leaf.

- A childless `over` node whose `base`-side name group has any **container** instance is a **wrapper mention** rather than a leaf override. It merges by `(field-name, value)` like any container instance, so a matching instance is left untouched and an unmatched one is appended as a new empty instance. So a bare section header in a higher layer, such as `server:` or `server: web1` with no body, never deletes the base subtree beneath it. JSON Merge Patch and kustomize make the same choice. The cost is deliberate. There isn't any way to blank a whole section from a higher layer, and an explicit deletion spelling may be added after 1.0 if one proves necessary.

- A name with any **container** instance in `over`, meaning a node with children, merges instance by instance. Each `over` instance matches a `base` instance by `(field-name, value)`, which is the same key the in-file merge rule uses, and recurses. An unmatched `over` instance is appended in file order. So 2 layers' children under `server: web1` combine, while a new `server: web3` is added.

- There's one exception to matching by `(field-name, value)`. An unmatched `over` instance with a **raw block** fills a same-named **empty** `base` binding rather than appending beside it, which is what a fence line does to an empty binding inside a single file. Without it a merge and a parse of the 2 layers run together would disagree about the same 2 lines, and the merged document wouldn't be a formatter fixpoint. Only a raw block fills. An unmatched valued instance still appends, matching what the parser does with the same 2 lines.

There are 5 more behaviors, all deliberate and all the same in every binding. `Line(path)` after a merge cites the line of whichever file the node came from, in that file's own numbering and with nothing to say which file it was. A **leaf override drops the base leaf's comments and its blank-line grouping**, where the in-file fold concatenates them. The override replaces the binding, and the comment above it described the value being replaced. A line the base kept as written for being malformed moves onto the replacement, and one kept in the leaf's block stays in the replacement's. The exception is one the load already writes as a comment because it would bind as written. That one goes with the comments, as a reload of the saved base would see it. Merging a document over an equal one therefore **doubles a container's leading comments**, since container instances match and combine theirs. `lost` **sums across layers**, so a consumer that merges and then saves to a fresh path is refused for a line some layer dropped, since the merged document is missing that content whatever it's written to. And a **strict failure in a lower layer** ends the fold there, so only that layer's diagnostics are reported.

A consumer that folds layers itself should know 3 more things. **The fold is not associative**. With a base `p:` that has `q: 1`, then `p: 2`, then a bare `p:`, `(A+B)+C` keeps `p: 2` beside the section, since the bare header is a wrapper mention against a container. `A+(B+C)` first folds the bare header over the leaf, and the section then absorbs it, so `p: 2` is gone. A pre-merged upper pair isn't interchangeable with the CLI's left fold. **A merged document keeps the base's strictness**, so a value from a stricter layer reads with the base's coercion rules. **A merge is not free**. It costs a pass over the base's touched scopes plus an index rebuild on the next read, and a replaced node is kept until the document is dropped. A 40000-key base with a 3-line overlay takes single-digit to 60 milliseconds depending on the binding, and 500 merges of an 8-node overlay grow the process about a megabyte.

Comment trivia stays with the nodes that have it, and the merged document is a formatter fixpoint like any other. Where an `over` instance matches a `base` one, the `base` node survives and takes on the `over` node's comments under the in-file rule: leading comments concatenate in layer order, and the first trailing comment wins. End-of-file comments are kept once each, so a footer several layers share isn't repeated per layer. `over`'s content is copied into `base`, so `base` stays valid after `over` is released.

On the CLI, every loading subcommand (`get`, `fmt`, `count`, `instances`, `children`, `paths`, `set`) takes repeated `--layer=FILE` and repeated `--set=PATH=VALUE`. `check` doesn't, because its diagnostics are inherently single-file.

- Precedence runs low to high: the `--layer` files in listed order, then the positional `FILE`, then the `--set` values. `fmt` with layers prints the merged canonical document, so it doubles as the merge command.

- A `--set` is a Writer edit rather than a merged layer. It targets the instance its path names, or creates the path. A path that matches more than one field at any step is a usage error at exit 1, as it is for a setter, and `port(0)` picks one. A real top-layer file would replace the whole same-named group wholesale instead, so put the value in a `--layer` file when whole-group override is the intent.

- Whether a `--set` is an edit or a layer decides whether it persists. On `set`, a `--set` edits the document rather than layering over it, so `set --write` writes those edits back. Giving any `--set` also means no write-ops script is read from stdin.

- Everywhere else a `--set` stays ephemeral and `--write` refuses it. `--write` refuses `--layer` everywhere, for the same reason. Folding a lower layer permanently into the top file is the opposite of what layering is for.

- `--lossy` only means anything where the command can refuse: a write, and `set` or `migrate` without `--write`, which refuse the way the write would. On `fmt` without `--write` it would read as protection against something the command never did, so there it's a usage error, like every other option a subcommand doesn't take.

- A pair of options that ask for different results is a usage error whichever order they came in, and the message names both. One case is 2 different type options on `get`, and the other is one value option given 2 different values. Nothing resolves last-wins, since the answer would then depend on typing order with nothing said about it. Repeating an option with the same value doesn't compete with anything and is allowed, and `--layer` and `--set` are ordered lists, so they repeat by design.

- A FILE of `-` is stdin on every subcommand, `set` included. When the edits arrive as options, no ops script is read, so stdin has the document there as it does everywhere else. Only when stdin is the ops script does `-` mean an empty base instead. It can't be both. The 2 used to combine into reading neither, which threw a piped document away at exit 0.

- A `--set` value goes in as **data**. Its type still follows the text (`workers=8` is an integer), but a comma, a quote, or a space inside it is content, so `ports=80, 443` stores one quoted string and `title=My App` stores `title: "My App"`.

- `--set-literal=PATH=TEXT` is the same option with the other reading. `TEXT` goes in as **value syntax**, the way a file writes it, so `ports=[80, 443]` stores a 2-element array, `title="My App"` stores a quoted string, and `` color=`#FF8800` `` stores a backtick value. Text a file line would report, such as `ports=80, 443`, is refused. `--remove=PATH`, `--set-default=PATH=VALUE`, and `--set-literal-default=PATH=TEXT` complete the edit options, and all five share one ordered list, so the last one to touch a path wins. On the read side, `--slots` prints an array read's per-slot statuses beside its values.

- `instances --paths` prints the path that reads each instance, the `InstancePaths()` form such as `shard(0)`, in place of its value. A wildcard slot that didn't match anything is an empty line.

- `--json` on `get`, `instances`, `children`, and `paths` prints one JSON object per line, for `jq` or PowerShell's `ConvertFrom-Json`. The keys always come in the same order: `path`, the `InstancePaths()` form; `name`, on `children` only; `value`, always a string; `line`, a number, 0 for a field an edit made; and `status`, on `get --slots` only. On `get` the value is the value read, or the `--default` in its place, every element of one array has the field's path and line, and a read that didn't find any field has an empty path. Elsewhere the value is the field's own: an array in brackets as `fmt` writes it, a raw block's content, or empty when the field doesn't have one. `paths --json` lists every field, repeats included, where `paths` lists each path once. Only what JSON requires is escaped, the way `jq -c` writes it, so the 4 CLIs agree byte for byte. `--paths` with `--json` is a usage error, since both decide what a line contains.

Environment-variable mapping is left out on purpose. The env namespace and its naming convention belong to the consuming program, which can map env vars onto `--set` itself.

## Schema-driven generation

`generate(schema, no_banner)` turns a schema into a commented, typed starter config. It puts the schema's `desc`/`default` vocabulary to work, which the validator reserves and ignores. `shcl init --schema=FILE` prints it to stdout.

This is the output for each schema field, in schema order:

- A `desc` line becomes a leading `## ` comment.

- A generated annotation line summarizes the type and constraints: `## <type>[, one of: v1, v2, ...][, <lo>-<hi> | >= <lo> | <= <hi>][, repeat <lo>[-<hi>]][, required]`. An untyped field shows `any`. Allowed values and numeric bounds are rendered in the type's canonical text, with the same float formatter reads use; a line break inside a rendered value is written as its escape, `◉NEWLINE◉`, so it can't break out of the comment, and other text, non-ASCII included, is written as it is. This annotation is part of the generated file, so it's a byte-for-byte cross-binding contract rather than free prose.

- `desc` is prose. Bare, it may contain spaces, and it needs quotes where any value does, such as for a comma or colon with a space after it. It goes in the comment as written. A `default` that doesn't have a spelling on a value line is a `V092` schema fault at that line rather than a silently dropped value. That means a raw block, or any default under `type: raw`.

- The field line itself depends on whether the field must exist. Fields that **must exist**, through `required` or a `repeat` lower bound of 1 or more, are live. They're written `path: <default>`, or `path:` with an empty value when there isn't a `default`. A quoted plain-string `default` keeps its quotes, and one containing a newline is written in its quoted escaped spelling. **Optional** fields are the same line commented out (`# path: ...`), so the starter is valid and minimal as-is. Prose the generator writes has `##` and a commented-out setting has a single `# `, so the 2 read apart at a glance. That's a convention for what SHCL writes rather than a rule. To the language both are ordinary comments, and a config author may write a comment with any number of `#` and any spacing around it.

- A must-exist field whose path contains a wildcard is generated in dotted form, with the wildcard dropped so it targets the instance it materializes, when some other live line materializes the wildcard's parent. Otherwise the instance that line creates would fail the schema. When that parent's line has a value, a dotted child would name the empty-valued instance instead of the one the line made, so any line under a valued live parent selects it by the value: `srv: web` is followed by `srv(web).port:` rather than `srv.port:`. The selector body is the first spelling a file line reads back as that value: a single element as it was written, then bare, then quoted. A body or a name with a real line break is written in its escaped spelling, since a file line is one line and the as-written spelling would be 2. A selector matches one plain value, so an array-valued parent doesn't have a selector spelling, and it makes the child a `V097` fault. When 2 fields would write one line, the first is written, and its value is the instance the children select. A commented line under a commented valued parent selects it the same way, so uncommenting both still names one instance. A live line under a commented parent stays dotted, since selecting by value would make the optional parent exist. Remaining wildcard paths, and paths that can't be written at all, are collected into a trailing `## Paths needing an instance name (not generated):` comment block, one `##   <path>   <type>` per line. A name-wildcard `*` segment doesn't have a name to drop to, and an index `(N)` needs a pre-existing instance, so neither can be written. A path that must exist and can't be written at all is a `V097` fault instead, since the trailing block can never satisfy it. The exception is a `repeat` lower bound of 2 or more, which is the documented shortfall below. Every such path gets its own fault line, naming the path and why it can't be written, so one run says how much of the schema is unreachable rather than one path at a time.

- A path whose last segment selects by value is written without that selector when its field has a `default`, because a value after a last-segment selector is ignored (`E002`). `field: "env(prod)"` with `default: prod` generates `env: prod`, which is the line that makes the instance the path selects. When 2 such fields select different values, they're 2 instances, so `env(prod)` and `env(dev)` write both lines. Whether the default names that instance is left to validation, so a default naming another one is a `V097` fault. With no `default` the selector line is written as it is (`flag(on):`). A commented-out line follows the same rule.

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

	These bytes are part of the generated file, so they're a cross-binding contract like the annotation line. The `Legal` line names SHCL as its subject, and it says nothing about the config it's in. The footer is written unless the caller asks for it to be left out, with `no_banner` on the library call or `--no-banner` on `init`. The flag is negative so a caller that says nothing gets the footer. Every binding exposes the same bytes as a constant (`GEN_BANNER`, `GenBanner` in Go, `SHCL_GEN_BANNER` in C), so a program that writes its own config file writes the block without keeping a second copy of it. `SetBanner` puts the block at the end of a document and takes an old one off first. The old one can be in the footer, or above any field but the first, which is where a field added below it by hand puts it. It's found by its first text line rather than its links, so a program that refreshes the block on each save never ends up with 2. The block runs from the lone `##` above that line to the next one, so the file's own `##` comments next to it stay, even written right against it. A line inside it that the block doesn't write, such as a Schema line or an `Owner` line someone added, stays where the block was. With the block going on, a block at the end that already reads as this one, apart from such lines, stays as it is, so the file doesn't change. The `Format` line `migrate` stamps comes off too, with the note under it. When the block goes on, a lone Format line above the first field comes off as well, since the new block names the format, so the file names only one. A whole block there still stays, with its Format line set to this format, since it reads first. The footer is the only difference the flag makes, and everything above it is byte-for-byte identical either way. The `Syntax` link points at the spec as tagged by the first release of the format major (`v3.0.0-beta1` for format 3), so a file keeps pointing at the rules it was written for. It changes only when the `Format` line does.

A fragment mount is expanded inline. The fragment's fields generate under the mount's path, depth-first, `desc`/`default` and all, until a fragment would re-enter itself. That cycle-cut mount joins the trailing comment block with the fragment's name in the type column, so a recursive schema generates one full level and says what belongs deeper. Paths are emitted in the schema's flat dotted and selector form, as the schema writes them, rather than expanded to block form, and in the schema's own spelling when a file line reads that spelling back as the same path. A lookup path takes spellings a file line doesn't, such as a `#` in a selector body, and those are rendered from the path instead, with the body quoted. The result is valid SHCL that loads with no error diagnostics and **validates clean against the schema that produced it**, with one documented exception. A `repeat` lower bound of 2 or more can't be auto-satisfied, since identical generated lines would merge into one instance, so such a field is emitted live once and validation reports the shortfall. That promise is checked against the finished text rather than assumed, both its load and its validation. A generated line that doesn't load, or a schema whose own `default` breaks its field's constraints, including a default that doesn't name the instance its path selects, fails generation with `V097` instead of producing a starter config that fails the first `check --schema`. That holds for an optional field too, with or without a `default`: its line is written commented, so it is read back on its own and its value checked against its field, since uncommenting it shouldn't break the file. A schema fault (V09x) makes generation fail the same way validation does. `init` then exits 6 like `check --schema` reporting the same fault. Exit 1 stays a usage error, and a schema that can't be read is exit 8. `generate` is a library call in every binding, plus the C++ veneer. `init` doesn't read a document, so it doesn't take `--layer` or `--set`. Generated output doesn't have a size ceiling of its own beyond the depth cap. Paths are emitted flat, so a chain of mounts writes each level's whole path on every line below it and the output grows with the square of the depth. A schema of 21 KB that mounts itself 511 levels deep generates 270 KB. Time is linear in the output and the depth cap bounds both, so nothing runs away, but a starter config isn't always small.

## Error handling philosophy

At Loose and Standard strictness, SHCL never bails on a whole file for one bad line. Strict turns any `error` diagnostic into a load failure by request, as described under [Strictness levels](#strictness-levels). The parser skips or best-effort-repairs the offending line, emits a diagnostic, and continues. The Accessor never errors when it can unambiguously get to a value, and malformed content before or after a clean section doesn't poison that section. Errors are reserved for genuine ambiguity, or raised by the caller from the status the full tier hands back.

One repair is defined concretely, because it's the common "figure it out" case. A line that is **one well-formed field name or path with no colon and nothing after it**, such as `base(Boston).metrics.population` with no value, is repaired to that path with an **empty value**, which is the obvious intent, and a diagnostic is emitted (`E015`). A name that breaks only the bare spelling rule still counts as one clean name here, so `404` and `-x` alone repair to `"404":` and `"-x":`, and so does a quoted name with a space in it, `"user name"`. The repair is deliberately narrow. A line whose colon is missing but which is *not* one clean name or path, such as a bare name with a blank in it (`square-miles 300`, `user name`), is genuinely ambiguous. The `300` could be a value, or part of a name that can't legally contain a space. So it's `E014` and kept as written rather than guessed. The lines under it still load, under the name it reads as.

## Strictness levels

One knob, set once per document at load time, governs how forgiving the whole library is: **`Loose` / `Standard` / `Strict`**. The CLI spells it `--strictness=loose|standard|strict` or `1|2|3`. The default is `Standard`, and everything specified elsewhere in this document describes `Standard` behavior. The level is per-document and never per-call, because it's a property of how an application treats its config rather than of one read. It's orthogonal to the on-bad policy, and the 2 compose. Strictness decides *whether* a value coerces, and the tier you call, or the CLI's `--on-bad`, decides what happens when it doesn't.

The bundles are normative, so a binding implements exactly this table:

| Behavior                                | Loose (1)                                                    | Standard (2, default)                           | Strict (3)
| :---                                    | :---                                                         | :---                                            | :---
| Malformed line at load                  | skip + `error` diagnostic                                    | skip + `error` diagnostic                       | **load fails**
| Colon-less-path repair                  | applied + `error` diagnostic                                 | applied + `error` diagnostic                    | **load fails**
| `hint` diagnostics (e.g. repeated-leaf) | emitted                                                      | emitted                                         | emitted (never fail a load)
| float -> int                            | rounds half away from zero (`3.5` -> 4, `-2.5` -> -3)        | `BadType`                                       | `BadType`
| Leading currency symbol -> number       | stripped                                                     | `BadType`                                       | `BadType`
| `50%` -> float                          | 0.5                                                          | `BadType`                                       | `BadType`
| Quoted thousands number -> number       | `"1,200"` -> 1200                                            | `BadType`                                       | `BadType`
| Boolean token set                       | Standard set plus `t`/`f`, `y`/`n`, `enable(d)`/`disable(d)` | `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0` | `true`/`false` only

Notes:

- **Loose** re-admits the forgiving conversions cut from Standard, as a closed list, and nothing joins it without a spec change. Under the currency rule, a single leading symbol from exactly these codepoints is stripped (`$ ¢ £ ¤ ¥ ₩ ₪ ₫ € ₭ ₮ ₱ ₲ ₴ ₹ ₺ ₼ ₽ ₾ ₿`), along with any whitespace after it, so `$ 1200` reads the same as `$1200`. Multi-letter codes (`USD`, `kr`) aren't stripped, and there isn't a trailing form. A `%` float is the fraction, so a Loose `GetInt` on `50%` rounds 0.5 -> 1. It's never special-cased to the number before the `%`, so `GetInt` and `GetFloat` can't disagree.

- A quoted thousands number reads as a number at **Loose**: 1 to 3 digits, then groups of exactly 3 after commas, then an optional `.` and any digits, so a trailing `.` is fine as on a plain number. A currency symbol, a sign, and a `%` go where they go on any Loose number, and a blank isn't allowed anywhere. `"1,200"`, `"$1,200"`, and `"1,200."` read as 1200, `"1,200.50"` reads as 1200.5, and an int read of that one rounds to 1201. `"1, 200"`, `"1,2,3"`, `"1,2000"`, `".1,200"`, and `"$ 1,200"` stay text. Bare, `1,200` is text at every level, since it could be a list, and the writer keeps it bare, so a save never makes it a number. A value a setter wrote counts as quoted when its saved text is quoted, so `set` of `1,200` gives text and an array element `"1,200"` gives 1200. Standard and Strict don't read any of them. A string read gives the text as written at every level.

- **Strict** is the "fail loudly" mode: any `error` diagnostic aborts the load. The never-bail philosophy above describes Loose and Standard. Every call that takes a strictness fails the same way, with the document inside the error: `ParseWith`, `ParseLimited`, `ParseKeepLines`, `LoadFileWith`, `LoadFileKeepLines`, `LoadAndValidate`, and `LoadAndValidateWith`. Rust returns `Err(LoadError)`, Go a `*LoadError` beside the document, Python raises `LoadError`, and C and C++ hand back the document with `strict_failed` true. Reads are unchanged except the boolean set. `hint` diagnostics never fail a load at any level, because repeated leaves are legal instances, and failing legal input would break the data model.

- The corpus pins every level. Conformance reads have an optional level column, so a binding can't drift on any bundle row.

## Migrating from 2.x

The 3.0 lexical rules are smaller than 2.x's, so a file written for 2.x can read differently under them. `migrate FILE` rewrites such a file so the current parser reads the tree 2.x read. It touches only the spellings the 2 rule sets disagree on, and comments, blank lines, raw bodies, and layout come through as written. `--write` saves the result through the same save gate `fmt --write` uses, and says how many lines it rewrote. When a line was rewritten it first copies the original beside the file, with a backup tag before the extension, so `config.shcl` keeps its old bytes in `config_backup_YYYYmmDD-HHMMSS_format-v2.shcl`. The time is local, and the number is the format the file was written for, which is what its Format line names, or 2 when it has none. It refuses at exit 8 when that name is taken, and writes nothing. `upgrade --write` and `UpgradeFile` use the same name, as described under [File tier](#file-tier). `--check` prints nothing, names each line a rewrite would change as `FILE:LINE`, and exits 6 when there is one, so a directory of files can be checked without diffing each one. It asks the save gate first, so a file `--write` would refuse is exit 7 rather than 6.

Most of the change is loud. A quote that never closes is `E017`, bracket text after a colon is `E019`, a bad `◉` escape is `E023`, a quote, a tab or a bracket in a bare value is `E025`, a bare comma before a blank is `E026`, a `*` item is `E013`, a selector in brackets is `E029`, and a line the current rules can't read at all is a malformed line. A file with one of those says so the first time it's loaded. `migrate` quotes such a value, writes a `*` item as `- `, and quotes a bare name not led by a letter, so `-x: y` isn't read as a list item. It writes a selector in parens, so `base[Boston].pop` becomes `base(Boston).pop`, and quotes a bare body these rules refuse, such as `srv[New York]` or `x[a(b)]`. A real `◉` in a 2.x file becomes `◉ESCAPE_CHAR◉`.

One change is quiet. A backslash pair was an escape in 2.x and is text now, so `"C:\\work"` read as `C:\work` then and reads as `C:\\work` now. `migrate` writes the text 2.x read. `"C:\\work"` becomes `"C:\work"`, a bare `C:\temp`, which 2.x read with a tab, becomes `"C:◉TAB◉emp"`, and `"say \"hi\""` becomes `'say "hi"'`. That goes for a value, an element, a `*` item, and a selector body, bare or quoted. A backslash before any other character was text in 2.x too, so `C:\work` stays as written. A quoted name with a backslash pair is the exception. Version 1.2 read such a name as typed, and 2.0 resolved it, so the file can't say which name it meant. It's left as written and counted lost.

A comma list is quiet too. Under 2.x, `a,b` and `a, b` both read as arrays, and the current rules read `a,b` as one string. `migrate` writes either one in brackets, `[a, b]`, and drops an empty element, as 2.x did. A list with one element left, such as `s,`, is the plain value `s`, which is how 2.x read it. In a file that doesn't say which rules wrote it, `a,b` is left as written and asks for `--from-2x`, while `a, b`, an error under these rules, is converted either way. A lone bare value these rules refuse, such as `done:` or `O' Brien`, is quoted. A quote inside a 2.x piece was text, but a comma or a `#` before its close was in the piece too, so `title="a, b"` is one element, written `'title="a, b"'`. A quote that never closes there is text, so `don't, stop` is 2 elements. `O'Brien` reads the same under both and stays bare. Under 2.x every whitespace character at a piece's edges was trimmed, such as a no-break space or a vertical tab, where the current rules trim only a space, a tab, and a carriage return, so `migrate` drops the others there too.

The comment rule didn't change. A `#` outside quotes opened a comment in 2.x and still does, so values and comments read the same on both sides.

Which file it's looking at is the one thing `migrate` can't read off the text. `p: a,b` is written the same way under both rule sets and means 2 different things, an array then and one string now, so rewriting a 3.0 file would change what it says. The info block has a `Format` line naming the format's major, and that's what decides. A file with it doesn't have anything to migrate. That includes a file a pre-release build of 3.0 stamped, since it wrote the same line and nothing else tells the 2 apart. Such a file is on its own. `migrate` and `upgrade` leave it as it is, and a line the current rules refuse says so when it loads. The one exception is `upgrade --from-2x`, where the caller says a 2.x build wrote it. Such a file that loads with an error is taken as 2.x when the fresh file loads clean. A Format line inside a raw body is that block's content and doesn't count. The 2 rule sets can put the blocks in different places, so a line naming this format counts outside the blocks the current parser finds, and an older one outside the blocks 2.x found. Where a file names more than one format, the highest decides. A file without it keeps those spellings as written and exits 7, unless `--from-2x` says it's 2.x. That goes for any piece both rule sets read cleanly and differently, such as a backslash pair, a `◉` escape, a backtick value, `[a]`, or a `- ` item. A line these rules already refuse is rewritten either way, and every line with a selector in brackets is one, since that's `E029` now. Lines inside a raw body under one rule set and not the other read 2 ways as well, and go the same way. After `'C:\': ~~~` a block opens now, but in 2.x the backslash escaped the quote and none opened. A file `migrate` rewrites is stamped with that line, plus a note saying where it came from, so a second run has the answer the first one didn't. An older Format line becomes that line where it is, and counts as a rewritten line. A file without one gets it at the end. Those 2 lines end the way most of the file's lines do, with a tie going to LF, as a line-keeping save's new lines do. A raw block that never closes leaves the line nowhere to go, since anything after it is the block's content, so `migrate` exits 7 and writes nothing until the block is closed. Only `migrate` and `upgrade` act on the line. Every other command treats it as the comment it is, except that a load says so when it names another major than this one: `H006` for a newer one, `H007` for an older one. A document from a newer one is never saved, and `NewerFormat` says so, as described under [File tier](#file-tier). A program asks the same question with `FormatVersion` (each binding's spelling). `ReadFormatVersion` gives the result with a status, so a file with no line and one whose line is damaged read apart: `NotFound` with no line, `Empty` for a line with nothing after `Format`, and `BadType` for one whose number doesn't read, such as `##    Format   3x`. A number too big for 32 bits reads as the largest one that fits, which is a newer format than this one. A line counts only when it's `##    Format` with nothing after it, or that and the 3 blanks the block writes before the number. The hints come from the same reading, but quote the number as written, leading zeros included, so `99999999999` shows as itself rather than as the 32-bit cap. A very long one is cut like any value in a message. `MigrateUnstamped` is the rewrite without the stamp, for a program that writes the info block itself.

Some lines 2.x bound have no 3.0 spelling to move to, so nothing binds them now: bracket text after the colon, a selector with a comma in it, which 2.x matched against an array value, and a comma list on a field with lines under it, which is `E028` in brackets. A quoted name with a backslash pair counts the same way, since 2.x versions read it 2 ways. `migrate` exits 7 on any of them rather than reporting success, so a scripted migration can tell "migrated" from "gave up". `--lossy` accepts the loss on a rewrite.

Here's what `migrate` promises, and what it doesn't:

- The output reads as the input read under 2.x, except for the lines it counts as lost. That's the whole point, and it's what the migration gate checks, document by document, against a build of the last 2.x commit.

- The output is its own fixpoint. Running `migrate` on what `migrate` wrote changes nothing, so a rewrite can't drift further on a second pass.

- A file it can't convert is left alone. It never rewrites part of a file and reports success, and it never damages a file that was already correct. `--lossy` is the one way to accept a loss, and it has to be asked for.

- It adds the `Format` line and a note saying the file came from 2.x to a file it rewrote, and nothing else. Where the file had an older `Format` line, the new one takes its place. It never writes the whole info block into a file that had none. A file with no `Format` line and nothing to rewrite gets the `Format` line alone, at the end, so `Migrate(text, false)` is how a program stamps the format without the info block. `FORMAT_LINE` (each binding's spelling) is that line.

- It is not a formatter. Layout, comments, blank lines, and raw bodies come through as written, so `migrate` output isn't a `fmt` fixpoint and isn't meant to be.

Exit codes: 0 when the file needed nothing or was rewritten, 6 from `--check` when a line would change, 7 when a spelling needs `--from-2x` to settle, a line 2.x bound has nowhere to go, or a raw block never closes, and 8 when the file can't be read or written.

There are 3 edge cases that read differently, and `migrate` leaves all 3 as written:

- A fence label with a `#` in it ran to the end of the line in 2.x. It ends at the `#` now, and the rest is the line's comment. A label has no quoting, so rename it.

- A carriage return in the middle of a line, at the edge of a piece, was content in 2.x. It's trimmed now.

- An indent that matches no open level's column reads differently too. Under 2.x a line was placed by a looser comparison, so a tab followed by a space and a tab, or by 2 spaces, bound then and is `E012` now. `migrate` rewrites spellings and not layout, so a file like that has to be re-indented by hand. None of this happens quietly. `migrate --write` refuses at exit 7 while the migrated text has such a line, though a save elsewhere keeps it as written.

## Cross-language parity and conformance

The guarantee is the corpus rather than the binding count: **every released binding is corpus-green**. A binding that hasn't passed the full conformance corpus isn't released. A companion surface (C++/Kotlin) inherits its core's conformance for free, and a Bash or PowerShell script that calls the Tier 1 CLI inherits that CLI's. These are the safeguards:

- This spec plus `grammar.abnf` are the single source of truth. Behavior is specified rather than left to each implementation.

- A **conformance corpus** of golden cases (`conformance/`) pins every implementation to identical results. Each case is an input `.shcl`, its expected canonical formatting, and a set of expected typed reads with their status sentinels. The date, coercion, and quoting edge cases are in the corpus, so no parser can silently drift.

- Every parser runs the corpus in CI before it's considered conformant.

- The byte-for-byte promise applies to valid UTF-8. What a library does with other bytes is unspecified (see [Encoding and lines](#encoding-and-lines)).

## Resolved minor items

These were deferred before, and they're now settled in the sections above:

- **Currency set**: cut from Standard; Loose-only, a fixed 20-codepoint list, single leading symbol only (see Strictness levels).

- **`field(*)` with a missing sub-path**: keep the positional slot, per-element `NotFound`, no diagnostic (see Paths, selectors, and traversal).

- **on-bad surface**: canonical `Error`/`Default`/`Flag`. In the libraries the tier you call picks it, rather than a parameter. On the CLI it's `--on-bad`, defaulting to `flag` (see The core call).

- **`GetInt` on a `%` value**: cut from Standard (`BadType`); at Loose, rounds the fraction, not special-cased (see Strictness levels).

- **Fence info-string**: free-form advisory label, exposed but never interpreted (see Raw blocks).

- **Fehu anti-escape**: removed entirely, since raw blocks are the verbatim escape hatch (see Escapes).

- **Field-name case folding**: ASCII `A-Z` only, never Unicode (see Merging and instances).
