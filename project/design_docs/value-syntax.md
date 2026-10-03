<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD038 -- Spaces inside code span elements -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Value syntax

Status: draft, not built yet. Target: format 3, before the `v3.0.0-beta1` cut. Until it is built, `spec.md` describes what the code does today, and this document wins wherever the two disagree about where the format is going.

Scope: escapes, quoting, bare values and field names, arrays, list items and selectors. Between them they decide how nearly every line in a file is read.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Summary](#summary)
- [Specification](#specification)
	- [Escape list](#escape-list)
	- [Error codes](#error-codes)
	- [Examples](#examples)
- [Goals](#goals)
	- [Non-goals](#non-goals)
- [Design](#design)
	- [The problem with backslash escapes](#the-problem-with-backslash-escapes)
	- [The escape character](#the-escape-character)
	- [Escapes](#escapes)
	- [Strings and quoting](#strings-and-quoting)
	- [Backtick values](#backtick-values)
	- [Arrays](#arrays)
	- [Stacked lists](#stacked-lists)
	- [Selectors and discriminators](#selectors-and-discriminators)
	- [Errors and kept lines](#errors-and-kept-lines)
	- [Canonical output](#canonical-output)
	- [Hidden characters](#hidden-characters)
	- [Migration](#migration)
- [Alternative ideas](#alternative-ideas)
	- [Unconsidered](#unconsidered)
	- [Rejected](#rejected)
	- [Superseded](#superseded)
- [Research findings](#research-findings)
- [Roadmap](#roadmap)
- [Related backlog issues](#related-backlog-issues)

<!-- /TOC -->

## Summary

- A backslash is plain text everywhere. `"C:\temp"` is a path, not `C:`, a tab and `emp`.

- An escape is a name between two `◉` characters, from a short fixed list under [escape list](#escape-list), such as `◉NEWLINE◉`, `◉TAB◉`, `◉U+200B◉`. Anything between `◉` but not in [escape list](#escape-list) is an error.

- A bare value can't contain whitespace or a quote. `title: My App` and `name: O'Brien` are errors, and `title: "My App"` and `name: "O'Brien"` are the fix.

- A bare field name starts with a letter. Any other name is quoted.

- Arrays are written in brackets, `ports: [80, 443]`, or one item per line with `- `.

- Backticks wrap a raw value the program decodes itself, such as `` `#FF8800` `` or `` `\x7F` ``. SHCL hands back the text between the backticks as is.

- Every mistake is a loud error on its own line. The rest of the file still loads, and a save keeps the bad line as written. Lines under a bad line still load wherever its name can be read.

- The point is to end the review and fix churn that backslash escapes have caused since 3.0 work began. The backlog item is 2026100207032800.

## Specification

The rules in short. The reasons are under [Design](#design).

- A backslash is never special.

- An escape is `◉`, a name from the [escape list](#escape-list), then `◉`.
	- Names are case-insensitive, and usually written in capitals.
	- The text between the two `◉` may contain only `A-Z`, `a-z`, `0-9`, `_`, `-` and `+`.
	- Anything not on the list is `E023`, and so is an odd number of `◉` in one piece.
	- Escapes can't nest. The list has no name that could contain another, so a nested one is already `E023`.
	- A piece is one bare value or array element, one quoted string, one quoted field name or one selector body.
	- A real `◉` is written `◉ESCAPE_CHAR◉`.

- Whitespace or a quote in a bare value, a bare array element or a bare selector body is `E025`.
	- Whitespace means a space, a tab, a carriage return, and every other character Unicode lists as `White_Space`.
	- Whitespace at the start and end is trimmed first, so `port: 80   # main` is fine.
	- A quote means `'`, `"` or a backtick, anywhere in the piece.

- A bare field name starts with an ASCII letter, then has only ASCII letters, digits, `-` and `_`. Anything else is `E014`. A quoted name can be any text.
	- A name that breaks only these spelling rules, such as `404`, `-x`, `user name` or `Straße`, can still be read. Its line is kept, and the lines under it load under the name it spells.
	- A name that can't be read at all, such as one with a bad escape, still takes its block with it, as today.

- Single and double quotes work the same way. Each one can contain the other kind of quote as plain text.

- A backtick value is raw. It has no escapes, can't contain a backtick, and is allowed only as a value or an array element.

- An array is `[a, b, c]`. A field can also take one item per line, each line `- ` then the item.

- A field with lines under it takes one plain value or none. An array there is `E028`.

- A selector matches one plain value. `base[Boston]` and `base["New York"]` work, and there is no way to select by an array value.

| Text                           | `◉` escapes | Whitespace inside | Notes
| :---                           | :---        | :---              | :---
| Bare value or array element    | yes         | no                | `E025` on whitespace or a quote
| Single or double quoted string | yes         | yes               | Either quote can contain the other
| Backtick value                 | no          | yes               | Values and array elements only
| Bare field name                | no          | no                | A letter, then letters, digits, `-` and `_`
| Quoted field name              | yes         | yes               | `"user name"`, `"Straße"`, `"404"`. The same field as any other spelling of it
| Selector body                  | yes         | quoted only       | Same rules as a value
| Comment                        | no          | yes               | A `◉` is plain text
| Raw block body and fence label | no          | yes               | A `◉` is plain text

### Escape list

The writer always uses the first name. The others are read as aliases.

| Canonical        | Aliases                                                                           | Character
| :---             | :---                                                                              | :---
| `◉NUL◉`          | `◉NULL◉`                                                                          | U+0000
| `◉BEL◉`          | `◉BELL◉`                                                                          | U+0007
| `◉BACKSPACE◉`    | `◉BS◉`                                                                            | U+0008
| `◉TAB◉`          | `◉HT◉`, `◉HORIZONTAL_TAB◉`                                                        | U+0009
| `◉NEWLINE◉`      | `◉LF◉`, `◉LINEFEED◉`, `◉LINE_FEED◉`, `◉NEW_LINE◉`                                 | U+000A
| `◉VT◉`           | `◉VERTICAL_TAB◉`, `◉VERTICALTAB◉`                                                 | U+000B
| `◉FF◉`           | `◉FORM_FEED◉`, `◉FORMFEED◉`                                                       | U+000C
| `◉CR◉`           | `◉CARRIAGERETURN◉`, `◉CARRIAGE_RETURN◉`                                           | U+000D
| `◉CRLF◉`         | `◉CARRIAGERETURN_LINEFEED◉`, `◉CARRIAGE_RETURN_LINE_FEED◉`                        | U+000D U+000A
| `◉ESC◉`          | `◉ESCAPE◉`                                                                        | U+001B
| `◉DEL◉`          | `◉DELETE◉`                                                                        | U+007F
| `◉SPACE◉`        | none                                                                              | U+0020
| `◉SINGLE_QUOTE◉` | `◉SQUOTE◉`, `◉S_QUOTE◉`, `◉SINGLEQUOTE◉`                                          | `'`
| `◉DOUBLE_QUOTE◉` | `◉DQUOTE◉`, `◉D_QUOTE◉`, `◉DOUBLEQUOTE◉`                                          | `"`
| `◉BACK_TICK◉`    | `◉BACKTICK◉`, `◉TICK◉`                                                            | `` ` ``
| `◉ESCAPE_CHAR◉`  | `◉FISHEYE◉`                                                                       | `◉`, U+25C9
| `◉U+XXXX◉`       | `U`, `U_`, `U-`, `UNICODE`, `UNICODE_`, `UNICODE+` or `UNICODE-` in place of `U+` | The character at that hex code point

- `◉U+XXXX◉` takes one to six hex digits, up to `10FFFF`. A surrogate, `D800` to `DFFF`, is `E023`.

- There are no hex byte or octal escapes. See [Rejected](#rejected).

### Error codes

The code numbers are provisional until the change is built. "Value only" means the line's name is fine, so the lines under it still load, as described under [Errors and kept lines](#errors-and-kept-lines).

| Code   | Meaning                                                                            | Outcome
| :---   | :---                                                                               | :---
| `E013` | A line starting with `*`. A list item is `- ` now                                  | Retained. The other items still load.
| `E014` | A bare field name that breaks the spelling rules, such as `-x: y` or `404: x`      | Retained. Holds its level open, which is new.
| `E017` | A quote or backtick that opens a piece and does not close it as its last character | Retained, value only. It used to bind, read bare.
| `E019` | A bracket array that is not well formed                                            | Retained, value only
| `E023` | A bad `◉` escape                                                                   | Retained. Value only when it sits in the value.
| `E024` | Retired. A Windows path with `\t` or `\n` in it is just text now                   | None
| `E025` | Whitespace or a quote in a bare value, bare array element or bare selector body    | Retained. Value only when it sits in the value.
| `E026` | A bare comma outside brackets and quotes, such as `ports: 80, 443`                 | Retained, value only
| `E027` | A list item that is a bare name ending in `:`, such as `- name:`                   | Retained. The other items still load.
| `E028` | An array value on a field that has lines under it                                  | Retained, value only
| `H003` | Retired. The case it hinted at is `E025` or `E027` now                             | None

A malformed bracket array is any of these:

- Text after the closing `]`: `[INFO] started`.

- A bare `[` or `]` inside: `[[1, 2], 3]`.

- An empty element: `[a,, b]` or `[a, ]`.

- No closing `]` on the line. An array is one line, like every value.

Quoted text inside an array is just a string, so `["[a]", "b"]` is two strings.

### Examples

| Line                          | Reads as                         | Why
| :---                          | :---                             | :---
| `path: C:\temp\new`           | `C:\temp\new`                    | A backslash is text
| `path: "C:\temp\new"`         | `C:\temp\new`                    | Quotes don't change that
| `title: My App`               | `E025`                           | Bare whitespace
| `title: "My App"`             | `My App`                         | Quoted
| `title: My◉SPACE◉App`         | `My App`                         | An escape works bare too
| `msg: "line one◉NEWLINE◉two"` | two lines                        | An escape in quotes
| `msg: "say ◉HELLO◉"`          | `E023`                           | Not on the list
| `name: O'Brien`               | `E025`                           | A quote in a bare value
| `name: "O'Brien"`             | `O'Brien`                        | Quoted
| `q: 'He said "hi"'`           | `He said "hi"`                   | The other quote is text
| `ports: [80, 443]`            | two elements                     | The array spelling
| `ports: 80, 443`              | `E026`                           | Arrays need brackets
| `log: [INFO] started`         | `E019`                           | Text after `]`
| `log: "[INFO] started"`       | `[INFO] started`                 | Quoted text
| `` color: `#FF8800` ``        | `#FF8800`, flagged as backticked | The program decodes it
| `when: "Jul 12 2026"`         | a date                           | Typed reads still work on quoted text
| `when: Jul-12-2026`           | a date                           | No space, so no quotes needed
| `404: not-found.html`         | `E014`                           | A bare name starts with a letter
| `"404": not-found.html`       | field `404`                      | Quoted

## Goals

- End the churn. Backslash escapes caused most of the review and fix rounds before the 3.0 cut.

- Make a Windows path safe to type any way: bare, single quoted or double quoted.

- Give every line one reading, so the file can't mean something other than what it shows.

- Make mistakes loud. A bad line is an error on that line, never a silent change of value.

- Let a program write any character, including the ones nobody can see.

- Keep config files readable by a person who has never read the spec.

### Non-goals

- Escapes in comments and raw blocks. A `◉` there is plain text.

- Decoding backtick values. That is the program's job.

- Values that span lines outside a raw block.

- Nested arrays and arrays of objects. Instances cover objects.

- Changes to the comment rule. A `#` outside quotes and backticks still opens a comment.

- Changes to fence labels.

## Design

### The problem with backslash escapes

- Most bug/fix/bug/fix churn is being caused by escapes. For example: "C:\shouldn't\be\tab\or\newline"
	- Will be read as "C:\<bad escape>\shouldn't\be\<tab>ab\or\<newline>ewline"

- It could be put in single quotes for a raw read, but anything after 'C:\shouldn' is an error (or at least a new class of problem to deal with).

- The canonical way to handle it is to escape the backslash itself, e.g. "C:\\shouldn't\\be\\tab\\or\\newline".
	- This works, but is hard for regular users to remember, and easy to screw up.

- Let's really get to the heart of the matter:
	1. *Using a common necessary keyboard character to begin an escape sequence, has always been a stupid convention*.
		- Or to put it more charitably, has always caused never-ending headaches.
	2. *Users generally don't need or want to put newlines or tabs in regular strings.*.

- So I'm twisting myself in knots over a known problematic use case that nothing like shcl has ever really solved well.

- We already have a way to easily get newlines and tabs into strings: A fenced block.

- If you really want them also in regular strings, let's consider these observations:
	1. It's already possible to put tabs in strings. The only real everyday outlier then is newlines. And other kinds of escapes, but those are either:
		- Vanishingly rare (e.g. other ASCII escapes) and don't deserve an "easy" solution that causes never-ending grief for the rest of the codebase, or
		- Are standalone values like hex values, or unicode values - that can be indicated other ways that don't cause never-ending grief for the rest of the codebase.
	2. Escapes that are signaled with only a single character - and then you have to guess where it ends - is already fraught with problems by definition.

- Considering this, if we (as a civilization) were to fundamentally rethink escapes and start from scratch, we would:
	- Use one or more characters to unambiguously signal the start *and* end of an escape sequence.
	- Have high "signal" value that is much harder to confuse with content.
	- Use one or more characters that don't have high-frequency use.
	- Be rare enough that the need to escape itself is low.
		- But also, be able to easily escape *itself* to mean that literal character within the string.
	- Have a finite list of possible things being escaped, for easier validation.

- The solution proposed here (in the [Specification](#specification) section) has some drawbacks:
	- Since the characters aren't on the keyboard (except the `%` idea) - the whole point - they aren't easy for users to get into the string.
		- This can be partially mitigated by programmatically including the escape signal character[s] in the file's comments, so users can at least copy/paste.
		- Also mitigated by the fact that programs can easily write the escape.
	- It might feel weird for older die-hard users of traditional escaping. 🤷

### The escape character

- `◉` is U+25C9, FISHEYE, from Unicode's Geometric Shapes block.
	- Most fonts have it, and it reads clearly in a monospace font.
	- Almost nobody types it by accident, so an escape is never started by mistake.

- One character marks both ends, as in `◉TAB◉`.
	- The closing mark is what tells the reader where the name ends, the job `${VAR}` does in Bash. So `"Once upon a◉NEWLINE◉time"` works.
	- An open and close pair would only help with nesting, and nesting is an error anyway.

- It isn't on a keyboard, and that is the point.
	- Programs write it.
	- People copy it from a comment or the docs. The info block `init` writes should carry one.

- Lookalikes such as `⦿`, `◎` and `⊙` are plain text. Typing one by hand is unlikely, since the realistic ways in are a program or a paste, so the risk is accepted. A lone real `◉` is an error, since the count in a piece is then odd.

- The fehu rune `ᚠ` was tried once and removed (`design.md`, Guiding principles). It wrote literal backslashes, so it sat on top of backslash escapes instead of replacing them. `◉` is the only escape there is, its names are a closed list, and anything off the list is an error.

### Escapes

- The list is short on purpose: the controls a program might need, the quotes, the backtick, the escape character itself, `SPACE`, and any character by code point.

- Names are case-insensitive. `◉tab◉` is `◉TAB◉`.

- Aliases are read but never written. The full list lives in one generated table, the way the output escape list does today in `cicd/utility/gen-escapes.py`, so each alias is one line in one place, not four hand-kept copies.

- Escapes work in bare text too. `My◉SPACE◉App` reads as `My App` without quotes.

- They don't work in comments, raw block bodies, fence labels or backtick values. A `◉` there is just a character, as many as you like.

- Inside a piece, `◉` marks pair up left to right. The text between each pair must be a name from the list. An odd count is an error, since the last `◉` has no partner.

### Strings and quoting

- A bare value is one run of text with no whitespace in it.
	- It ends at a comment, at the end of the line, or at a bracket or comma where those mean something.
	- Whitespace inside it is `E025`.
	- The fix the error suggests is to quote the value.

- Why no bare whitespace: a value then has one reading.
	- `say "hi" there`, a value starting with a quote it never closes, and `Jul 12, 2026` splitting at its comma were all edge rules that four bindings had to agree on.
	- The writer already quoted any value with whitespace, so a file `fmt` wrote is already legal.
	- This reverses "Quotes are optional" in `spec.md`. A hand-typed `title: My App` is now an error, accepted as the price of one reading per line.

- A quote anywhere in a bare value is `E025` too: `O'Brien` and `a"b` are errors, and `"O'Brien"` and `'a"b'` are the fix.
	- A quote mid-value used to be text, which left a person guessing whether it opened a string.
	- The same goes for a backtick.

- A piece that starts with a quote must end with the matching quote. Otherwise it is `E017`, and the line is now refused instead of read bare, since a bare reading would break the whitespace rule.

- Single and double quotes differ only in which quote each can contain.
	- `'He said "hi"'` and `"it's"` need no escapes.
	- A string with both should use `◉DOUBLE_QUOTE◉` and/or `◉SINGLE_QUOTE◉`.

- Dates, times, durations and sizes with spaces need quotes now: `"Jul 12 2026"`, `"2:30 PM"`, `"1h 30m"`, `"1.5 GiB"`. Without the spaces they stay bare: `Jul-12-2026`, `2:30PM`, `1h30m`, `1.5GiB`. Typed reads don't care about the quotes, as before.

- A bare field name starts with an ASCII letter.
	- That is the usual rule for names in programming languages, and it keeps a name from being read as a number or a list item.
	- `-x: y`, `404: x` and `_id: 7` are `E014`. Quote them: `"404": x`. The lines under them still load meanwhile.
	- A name that starts with a letter is unchanged.

- Quoted field names follow the same rules as quoted values, and resolve `◉` escapes, so `"a◉DOUBLE_QUOTE◉b"` and `'a"b'` name the same field.

### Backtick values

- A backtick value is a third kind of quote, for values that are their own little language: a color, a C escape, an HTML entity.

- Examples, each one value:
	- `` `#FF8800` ``
	- `` `\0` ``, `` `\t` ``, `` `\x7F` ``, `` `\u25C9` ``, `` `\x00FF` ``, `` `\077` ``
	- `` `&#x27` ``, `` `&quot` ``, `` `&#9673` ``
	- `` `'` ``, `` `"` ``, `` `$` ``

- SHCL never decodes the text inside backticks. A read returns exactly what is between the backticks, plus a flag saying it was backticked, the way the `quoted` flag works today. The program decides what `\x7F` means.

- Single and double quotes are not aliases for backticks. `"\x7F"` is the four characters `\`, `x`, `7`, `F`, and so is `` `\x7F` ``. Only the flag differs.

- The text is raw: no escapes, and `◉`, `#`, `,`, `[` and whitespace are all plain text.

- A backtick value can't contain a backtick. Three backticks open a fence, so there is no way to spell one.

- Allowed as a whole value or a whole array element. Not in a field name or a selector.

- A backtick that opens a piece and doesn't close it as the last character is `E017`, as for quotes.

### Arrays

- `[a, b, c]` is the array spelling, and the canonical one.
	- Spaces after the commas are only separators. Each element follows the value rules, so `[New York, Boston]` is `E025` and `["New York", Boston]` is fine.
	- `[]` is the empty array. `x: []` and `x:` both read as an empty array. A plain read of `x:` still gives its Empty status, and a string read of `x: []` gives `[]`.
	- `[80]` is a one-element array.

- A bare comma outside brackets and quotes is `E026`. `ports: 80, 443` clearly means an array, so the error says to add the brackets, and `migrate` adds them.

- A malformed array is `E019`. See [Error codes](#error-codes) for the cases.

- Reading:

| File says         | Read as int | Read as int array | Read as string
| :---              | :---        | :---              | :---
| `port: 80`        | `80`        | `[80]`            | `80`
| `port: [80]`      | `80`        | `[80]`            | `[80]`
| `port: [80, 443]` | error       | `[80, 443]`       | `[80, 443]`
| `port: []`        | empty       | `[]`              | `[]`

- A string read of an array gives its canonical bracket form, as a multi-element read does today with the comma form. So brackets count as part of the value wherever text is compared: `x: 80` and `x: [80]` are two different instances, two different selector matches, and two different values against a schema's `allowed` list.

- Why brackets: every other format people know spells an array this way, and before this change a value starting with `[` was always an error (`E019`), so no file that loaded is read differently.

### Stacked lists

- A field can take its array one item per line:

	~~~text
	sizes:
		- small
		- "extra large"
		- "Bond, James"
	~~~

- That reads the same as `sizes: [small, "extra large", "Bond, James"]`.

- The marker is `-` then whitespace. The whitespace is required.
	- `-x: y` is `E014`, since a bare name starts with a letter.
	- `-5` alone on a line has no colon, so it was never a legal line. `- -5` is the item `-5`.

- Each item is one value and follows the value rules. `- extra large` is `E025`.

- `- name:` is `E027`. That is how YAML starts an object in a list, and SHCL does that with instances. The line is kept, and the other items still load.
	- `- "name:"` is the item `name:`.
	- `- name: value` is already `E025`, for the space.
	- `- localhost:8080` is fine. The rule is a bare name ending in a colon, not any colon.

- The old marker, `*`, is `E013`, and the message says to use `- `. `migrate` converts it.

- Every line at the item column is an item, or none is, as today. The field opening the list has no value of its own.

### Selectors and discriminators

- A field with lines under it takes one plain value or none.
	- `route: [GET, POST]` with lines under it is `E028`.
	- A list as an instance's value was always rare, and other spellings cover it: a string, `route: "GET POST"`; a position, `route[#1]`; or a one-word value with the list in a child field, `route: api` with `methods: [GET, POST]` under it.

- A selector matches one plain value: `base[Boston]`, `base["New York"]`.
	- The old match by display form, where `base[Boston, MA]` found the array value `Boston, MA`, is gone.
	- A bare selector body follows the bare value rules, so `base[New York]` and `srv[O'Brien]` are `E025`.

### Errors and kept lines

- No error here stops the load or throws out good lines. Each one complains on its line and keeps the rest: the lines around it, the lines under it where they can be placed, and the other items of a list.

- Every new error keeps the line exactly as written. It binds nothing, a read on it is NotFound, nothing is counted lost, and a save writes it back where it was.

- A line refused for its value alone keeps its level open. That covers `E017`, `E019`, `E023` and `E025` when they are in the value, plus `E026` and `E028`.
	- The name is fine, so lines indented under it still load under that name.
	- `E014` for a name that can still be read works the same way. The lines under it load under the name it spells.
	- The field only exists if one of those lines binds.
	- This is the rule from 2026100115403384. Without it, one typo in a value takes its whole block with it.
	- The full outcome rules for every code are in `design.md` under Load outcomes.

- Bug 2026100213205957, fixed: two value-only refusals, one nested under the other.

	~~~text
	a: My App
		b: x y
	~~~

	- Both lines are errors, which is right.
	- Since nothing binds, `a` never exists, and the save used to write `b: x y` at column 0. Once the quotes were added, `b` read as a top-level field, not `a.b`.
	- The save now writes `b` back under `a`, where it was.
	- A fuzz property holds it: a kept line reloads at the same path, under the same parent lines, after both a canonical and a line-keeping save.
	- A comment between the two is still written at column 0. It should nest too, under 2026100218185700.

- These errors become far more common than `E023` and `E024` were, since a bare value with a space is a very common hand-typed line. That makes the kept-line rules and the bug above more important, not less.

### Canonical output

What the writer and `fmt` produce. The line-keeping save still writes unchanged lines as they were.

- A value is written bare when it has no whitespace, none of `,` `#` `"` `'` `` ` `` `[` `]` `◉`, doesn't end in `:`, and needs no escape. Otherwise it is quoted.
	- A `:` inside a value is text, so `2:30PM` and `localhost:8080` stay bare.
	- A value ending in `:` is quoted, since as a list item it would read as `- name:`.

- The user's quotes on a plain string are kept, as today.
	- Quoting used to be pure spelling, normalized away, which silently took the quotes off values a downstream language treats as special, such as `"@null"` or a quoted function name. The `quoted` read flag exists for that case.
	- `ver: "8"` still becomes `ver: 8`, since readers type the value either way.
	- A number with a leading zero keeps its quotes, as today: `zip: "02134"`. The quotes don't stop a typed read, so a program that reads `zip` as an int gets 2134. Knowing a zip code isn't a number is up to the program.
	- A data value whose bare spelling would break the whitespace rule keeps its quotes: `"Jul 12 2026"`, `"1h 30m"`.

- Quote choice when the writer picks: double quotes, or single quotes when the text has a `"` and no `'`. Text with both goes in double quotes with `◉DOUBLE_QUOTE◉`. A backslash plays no part in the choice any more.

- Arrays are written `[a, b]`. A one-element array keeps its brackets, `[80]`, when it was written that way or set through an array setter. The empty array is `[]`.

- Backtick values stay in backticks.

- Escapes written:
	- A line break is `◉NEWLINE◉`, a carriage return is `◉CR◉`, and the pair of them is `◉CRLF◉`.
	- A tab inside a quoted value is `◉TAB◉`, since a tab can't be told from spaces by eye. A literal tab in the input still reads as a tab.
	- The other controls on the list are written by their canonical names.
	- A real `◉` is `◉ESCAPE_CHAR◉`.
	- Each hidden character, below, is `◉U+XXXX◉` with at least four hex digits in capitals.

- A kept line is written back exactly as it was.

- The quoting rule runs at standard strictness, fixed, so canonical form can't vary with how strictly the file was loaded.

### Hidden characters

Moved from `design.md`, with the escape spelling changed to `◉U+XXXX◉`.

- The writer escapes every character a reader could not see in an editor, so nothing hidden survives a save unnoticed.
	- The list is the controls, the line and paragraph separators, the interlinear annotation marks U+FFF9 to U+FFFB, and every character Unicode 18.0 lists as `Default_Ignorable_Code_Point`, such as a zero-width space, a direction mark, an embedding, override or isolate, a soft hyphen, the byte order mark, a Hangul filler or a tag character.
	- Tag characters settled it: a run of them spells ASCII no editor shows, and a soft hyphen or a Hangul filler hides text as well as a zero-width space does.
	- The list is fixed at Unicode 18.0, so a later Unicode does not change a format 3 file. It lives in `cicd/utility/gen-escapes.py`, which writes it into the four bindings and the grammar, and `check-docs.bash` fails when a copy differs.

- Three kinds stay as written where ordinary text needs them.
	- The zero-width joiner and non-joiner always stay, since emoji and several scripts need them. A run of them can still hide bits. Escaping them would break emoji sequences and those scripts.
	- A variation selector stays after a visible character, since emoji (`❤️`), ideograph variants and Mongolian need one there. Anywhere else it is escaped, so a run of selectors cannot carry hidden bytes.
	- A tag stays only inside a subdivision flag as UTS #51 spells one: U+1F3F4, three to seven tag digits or lowercase tag letters, and the cancel tag U+E007F. That covers the flags of England, Scotland and Wales, and nothing long enough to hide a sentence.

- Judging selectors and tags by what sits next to them was chosen over escaping all of them, which turns emoji and flags into escapes, and over keeping all of them, which leaves open the hiding this list is for.

- Comments and raw block bodies are written as they are.

### Migration

- `migrate` rewrites a 2.x file into the new rules. It writes each value the way 2.x read it.

| Before                          | After
| :---                            | :---
| `"C:\\work"`                    | `"C:\work"`
| `\t` and `\n` escapes           | `◉TAB◉` and `◉NEWLINE◉`
| `\"` and `\'`                   | The other quote kind, or `◉DOUBLE_QUOTE◉` and `◉SINGLE_QUOTE◉`
| `\uXXXX`                        | The character, or `◉U+XXXX◉` when it is hidden
| A bare value with whitespace    | The same text, quoted
| A bare value with a quote       | The same text, quoted
| A bare name not led by a letter | The same name, quoted
| `a, b`                          | `[a, b]`
| `* item`                        | `- item`
| `* key: value`                  | `- "key: value"`
| A real `◉`                      | `◉ESCAPE_CHAR◉`

- Bracket text after a colon in a 2.x file is still counted lost, as now. That is exit 7, and `--lossy` overrides it.

- The standing rule for 2.x still applies: on a hard edge case, refuse with an error rather than build machinery, and never damage a correct file at exit 0.

- A program may also give up on an old file: read what it can, then write a fresh one from the values it kept. That is fine for every program using SHCL so far.

- Files stamped `Format 3` by a pre-release build are an open question. See [Roadmap](#roadmap).

## Alternative ideas

### Unconsidered

Not looked at in any depth:

- A per-file setting that picks the escape character.

- Triple-quoted strings for text over several lines. Raw blocks cover that.

- Nested arrays, and arrays of objects inside brackets.

### Rejected

- Escape rule idea 1, ruled out as possibly making things worse. `%` collides with Windows environment variables such as `%USERPROFILE%`, which puts the same burden on the same users that backslash does.
	- The beginning is signaled with `%`.
	- The end is signaled with `%`.
	- The format is generally, `%VALUE_BEING_ESCAPED%`
		- The value inside is case-insensitive, and can contain *only* one of: `A-Z`, `a-z`, `0-9`, `_`, `-`
	- In-between `%%`, is a finite list of possibilities. Values not in that list, are an error.
	- The real character `%` is encoded as `%PERCENT%`
	- An odd number of `%` is an automatic error.
	- Escapes can't be nested.
	- Pros:
		- Is easy to encode, since `%` is on the keyboard.
	- Cons:
		- User would have to remember to escape real `%`s with `%PERCENT%`

- Escape rule idea 2, ruled out as too complicated, and error-prone, and unnecessary. The character survived into the final design. What went, and why:
	- `◉U_NNNN◉` read as decimal. Everyone writes code points in hex, so a pasted `U+2014` would have silently meant U+07DE.
	- `◉HEX_...◉` and `◉OCTAL_...◉`. See the hex and octal entry below.
	- Names for keyboard symbols such as `◉HASH◉`, `◉LEFT_BRACKET◉` and `◉PERCENT◉`. Inside quotes those characters are already plain text, so the names only mattered in bare text, where they would have reopened the comment rule.
	- Backtick values that SHCL decoded. See the backtick entry below.
	- The idea as written:
		- The beginning is signaled with `◉`.
		- The end is signaled with `◉`. (Same symbol)
		- The format is generally, `◉VALUE_BEING_ESCAPED◉`
			- The value inside is case-insensitive, and can contain *only* one of: `A-Z`, `a-z`, `0-9`, `_`, `-`
		- In-between `◉VALUE_BEING_ESCAPED◉`, is a finite list of possibilities.
		- The real character `◉` is encoded as `◉ESCAPE_CHAR◉`, `◉FISHEYE◉`, `◉U_9673◉`
		- An odd number of escape characters is an automatic error.
		- Escapes can't be nested.
		- Other symbol ideas:
			- `⹗VAL⹘`: Not vertically aligned very well. Requires two symbols.
			- `🢔VAL🢖`: Nice because they have extra space on left and right, but is less clear which direction is "open" and "close". Which can also be a problem, e.g. "Is this one 🢒SPACE🢐 or two?" Requires two symbols.
			- `🢒VAL🢐`: Hard to tell those are triangles. Requires two symbols.
			- `🞂VAL🞀`: Better but technically, we don't need two values. Requires two symbols.
		- Finite list of escapes:
			- ASCII:
				- `◉NUL◉`, `◉NULL◉`
				- `◉BEL◉`, `◉BELL◉`
				- `◉BS◉`, `◉BACKSPACE◉`
				- `◉HT◉`, `◉TAB◉`
				- `◉LF◉`, `◉NEWLINE◉`, `◉NEW_LINE◉`, `◉LINEFEED◉`, `◉LINE_FEED◉`
				- `◉VT◉`, `◉VERTICALTAB◉`, `◉VERTICAL_TAB◉`
				- `◉FF◉`, `◉FORMFEED◉`, `◉FORM_FEED◉`
				- `◉CR◉`, `◉CARRIAGERETURN◉`, `◉CARRIAGE_RETURN◉`
				- `◉ESC◉`, `◉ESCAPE◉`
				- `◉DEL◉`, `◉DELETE◉`
			- Common:
				- `◉HEX_[0-9A-F]+◉`
				- `◉OCTAL_[0-7]+◉`, `◉0_[0-7]+◉`
				- `◉U_[0-9]+◉`, `◉UNICODE_[0-9]+◉`
			- Potentially problematic regular keyboard symbols in some contexts:
				- `◉HASH◉`, `◉HASHTAG◉`, `◉HASH_TAG◉`, `◉POUND◉`, `◉OCTOTHORPE◉`
				- `◉LEFT_BRACKET◉`, `◉LEFTBRACKET◉`, `◉RIGHT_BRACKET◉`, `◉RIGHTBRACKET◉`
				- `◉UNDERSCORE◉`
				- `◉MINUS◉`, `◉PERCENT◉`, `◉BACK_SLASH◉`, `◉BACKSLASH◉`, `◉FORWARD_SLASH◉`, `◉FORWARDSLASH◉`, `◉BACK_TICK◉`, `◉BACKTICK◉`, `◉TICK◉`, etc.
		- For values that are standalone escape values, not embedded in a string (e.g. a hex color), they can be indicated with backticks. But for single standalone values only, not field names. E.g.:
			- [tic]`#FF8800`[tic]
			- [tic]`\0`[tic]
			- [tic]`\t`[tic]
			- [tic]`\x7F`[tic]
			- [tic]`\u9673`[tic]
			- [tic]`\x00FF`[tic]
			- etc.

- Other escape characters.
	- `⍟`, U+235F, from the APL block. Very rare in text, but some fonts lack it.
	- `¤`, U+00A4. In every font and every old 8-bit character set, but ICU currency patterns use it, as in `"¤#,##0.00"`.

- Hex and octal escapes in strings, `◉x41◉` and `◉OCT_101◉`. Half of readers would expect a number and half a character. In a string the parser has to build text, so a hex byte would have to be a code point anyway. `◉U+...◉` covers characters, and a backtick value covers anything a program wants to decode itself.

- SHCL decoding backtick values. The examples mix C escapes, HTML entities, a CSS color and plain characters, and no one decoder fits all of them. Decoding `\x7F` would also bring backslash escapes back, in four bindings.

- Single and double quotes as aliases for backticks. The flag would then depend on which quote a person happened to use.

- Escapes in comments and raw blocks. A comment is where a `◉` sits for copying, and a raw block is verbatim by definition.

- Reading `[80]` and `80` as different types. Typed reads give the same answer for both. Only the string read differs.

- `[80,443]` with no space as the canonical form. `[80, 443]` is easier to read.

- Selecting an instance by an array value. Rare, and covered by a string, a position or a child field.

- Reading `- name: value` as a YAML object in a list. Instances already do that job.

### Superseded

What the build has today, and what replaces it.

- Backslash escapes inside double quotes: `\t`, `\n`, `\\`, `\"`, `\'`, `\uXXXX` and `\UXXXXXXXX`. Replaced by `◉` escapes.
	- `E023` meant a bad backslash escape. It means a bad `◉` escape now.
	- `E024`, a Windows path in double quotes with `\t` or `\n` in it, goes. It replaced the hint `H004`, and both are retired. Item 2026100115323227.
	- The writer's `\u0009` and `\u000A` spelling for such a path goes with it.
	- Writing a value with a backslash in single quotes, or in double quotes with each backslash doubled, is no longer needed. Items 2026100115323216 and 2026100115323222.

- "Quotes are optional" (`spec.md`, Whitespace, quoting, and reserved characters), and for this case the principle that the user is never made to satisfy the machine. A bare value with whitespace is an error now.

- The inline comma array, `tags: red, green, blue`, and its leniency: empty elements dropped, and a value of only commas read as the empty array. Replaced by brackets, where an empty element is an error.

- `*` as the stacked list marker, decision 36. `-` had been turned down because of negative numbers and field names that start with a dash. Requiring whitespace after the dash, and a letter at the start of a bare name, settles both, and `- ` is what people already know from YAML and Markdown.

- The hint `H003`, for a `*` item spelled like a field. That case is an error now.

- Bracket text after a colon as always `E019`, "the JSON habit". Brackets are the array spelling now, and `E019` means a malformed one.

- Selector matching by display form, for array-valued instances.

## Research findings

- How the churn grew:
	- 3.0 limited escapes to double quotes, and made a bad one, `E023`, refuse its line. `"C:\work\new"` was the case behind that: the `\w` stayed, the `\n` silently became a newline, and a hint would have reached only callers that read diagnostics.
	- `\u` escapes were added on 2026-09-26, and the hidden-character list on 2026-09-28.
	- `"C:\temp"` got the hint `H004`, which became the error `E024` on 2026-10-01.
	- A refused value then took its whole block with it, which led to the lazy level (2026100115403384).
	- That led to a fence bug (2026100117214801), a `set` placement bug (2026100117214802), and the column 0 bug above.
	- Most of those started with a Windows path in double quotes.

- Other formats:
	- TOML, YAML and JSON all use backslash escapes inside double quotes.
	- TOML's own spec points Windows paths at its single-quoted literal strings, `'C:\Users\nodejs\templates'`, because of this.
	- TOML requires quotes on every string. YAML allows bare strings with spaces.
	- YAML, TOML and JSON all spell an inline array `[a, b]`, and YAML writes a list one item per line with `- `.

- The fehu rune `ᚠ` was an earlier attempt at an escape-free spelling. It wrote literal backslash runs, and `\ᚠ` was a literal fehu. It was removed, with raw blocks named as the verbatim escape hatch.

## Roadmap

1. Settle the open points below.

2. Build it, reference first, then the other bindings.
	- Rust, then Go, Python and C, then the C++ veneer.
	- The tokenizer, the writer, `SetLiteral` and `--set-literal`, and `migrate`. `--set` and the typed setters take data, not syntax, so `--set 'title=My App'` still works.
	- One generated table for the escape names and aliases and the whitespace list, beside the hidden-character list.
	- `spec.md`, `grammar.abnf`, and `design.md` under Lexical edges and Load outcomes.
	- Corpus cases and goldens. Most goldens change, since arrays and quoting change.
	- CLI help showing the quoted form for `--set-literal`: `--set-literal 'title="My App"'`.
	- Comments nesting under kept lines, 2026100218185700.

3. Then cut `v3.0.0-beta1`.

Open points, each with a proposed answer:

- Files stamped `Format 3` by a pre-release build (2026100115403385). Proposed: state that pre-release files are on their own, per the 2.x low-stakes rule, and let programs give up on them as above.

- Whether canonical output keeps a list written with `- ` in that form. Proposed: no, `fmt` writes brackets. The line-keeping save keeps the lines as they were.

- How a setter asks for a backtick value, or for brackets on a one-element array. Proposed: options on the existing setters, named when built.

- The error code numbers.

## Related backlog issues

| ID               | Title                                                                                         | Relation
| :---             | :---                                                                                          | :---
| 2026100207032800 | No '\' escapes                                                                                | This design
| 2026100213205957 | A kept line under a kept value-only line is saved at column 0                                 | Fixed
| 2026100218185700 | A comment between nested kept lines is written at column 0                                    | Open bug, fixed with this
| 2026100115403384 | A bad escape on a line that opens a block drops the whole block                               | The lazy level. Stays.
| 2026100115323227 | `"C:\temp"` loads with a tab and only a hint says so                                          | Superseded. `E024` goes.
| 2026100115323216 | The writer spells Windows paths three different ways                                          | Superseded
| 2026100115323222 | No way to ask a setter for single quotes                                                      | Superseded
| 2026100115403385 | A file stamped Format 3 during the beta is never migrated                                     | Open point above
| 2026100117214801 | A bad escape in the name of a line that opens a raw block leaves the body to be read as lines | Stays. Its repro changes.
| 2026100117214802 | `set` on a file ending in a kept line writes the new key above it                             | Stays. Its repro changes.
