# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- `children` and `instances` exit 3 on a path that matches nothing, as `get` does, with `cannot list PATH: no field at that path (in FILE)` on stderr. They used to exit 0 with no output, the same as for an empty section. A node with no children still lists nothing at exit 0, and `count` still prints 0 at exit 0.

- An installer run that would put an older release over a newer install says so in its plan and its receipt, and on the stable channel says how to keep the newer one. It also removes the drop-ins, man page, and completions that the older release doesn't include, so they don't sit beside a binary they don't match.

- A save checks the bytes at the path it writes, every time, whatever file the path names now. It writes when they're what the load read or what this document's last save wrote, or when nothing is there, as an editor does. So a file deleted since the load is written back, where beta1 refused it as changed, and a save-as to a new name is still written. Unless `force` is set, a save onto a file the document never read is refused as changed, where it used to write. A save-as is one case, and a document from `parse` over an existing file is another. A save to the same relative name from another working folder is refused the same way.

- `set --write` and `fmt --write` write back a FILE deleted while they ran, and say `FILE: created`, as the library's save does. They used to refuse it as changed since it was read.

- A comment run that a blank line sets off from the field below it belongs to the line above it, or to the file at the top, in every binding. So a remove, `clear_comments`, or `comments` on that field leaves it alone, where before they took it as the field's own comment, and a remove of the first field no longer takes the file's header comment or its info block. A comment added to the field goes right above it, under the blank. A remove still takes the comments right above the field and right under it, up to a blank line.

- `instances`, `get --array`, and `get --slots` print a value quoted when it has any line break that Python's `splitlines()` splits at. Besides LF and CR, those are VT, FF, U+001C to U+001E, U+0085, U+2028, and U+2029. Those used to print bare, so a consumer splitting the output counted more values than there were.

### Fixed

- `set_literal`, `set_literal_default`, `--set-literal`, and the `literal` op refuse text with a `#` outside quotes as not one value, in every binding. They stored only the text before it and reported success, so `x#y` became `x` and `https://a.b/c#frag` lost its fragment. Quote the text, or use `set_string`, to keep a `#` in a value.

- In Go, a zero-value `Document`, such as `var d shcl.Document`, is an empty document at Standard, the same as `New()`. Its first set, read, or merge used to panic. `Merge(nil)` adds nothing, where it used to panic too.

- The Windows setup's uninstall rewrote a machine PATH that had an empty segment, such as a trailing `;`, even when it didn't have a shcl folder in it, and its install dropped the empty segments. It writes only its own segment now, as install.ps1 does.

- install.ps1 extracts the drop-in payload with Windows' own `tar`. A GNU tar from Git for Windows, MSYS2, or Cygwin ahead of it on PATH failed the unpack.

- Under a `TMPDIR` with `..` inside a folder name, such as `tmp sp..x`, install.bash installed, then refused to remove its temp folder and exited 1. Both installers take only a whole `vX.Y.Z` or `vX.Y.Z-suffix` tag, where a tag such as `v2.0.0x` passed before.

- A setter or a merge that replaced a stacked list put the comments among its items above the field's blank line, so they read as part of the block above. They go right above the field now, with the blank above them.

- When a document was loaded through `nodir/../f.shcl` while `nodir` wasn't there, its save wrote over a file another program made there since. The check compared 2 paths that were resolved at 2 different times. Now it compares bytes.

- A save to `f.shcl/`, `f.shcl/.`, or `f.shcl/..`, or a create-only one, says it's a directory in Rust and C, as in Go and Python. Rust and C said the file changed, or that it was there. `set --write` says the same for a folder swapped in during its wait as for one there from the start, and the C CLI no longer says `Not a directory` for `f.shcl/`.

- The Go library builds for the `js` and `wasip1` wasm targets again. In beta1 it used a system constant those targets don't have.

- A file that re-opens many blocks loads in linear time again. In beta1, 100,000 blocks each named twice took 4 to 5.5 s to load in Go and C, and a kept line before each second instance made it 10 s and more.

- In C, checking a document against a fragment that mounts itself takes time that grows with the square of the depth rather than the cube. In beta1, 40 lines each 510 levels deep took 4 s to check in C, but now they take a quarter of a second.

- A `#` outside quotes in a lookup path is refused, as `BadPath`. The path used to end there, so `set --remove='colors#primary'` removed all of `colors` at exit 0. Quote a name that has one, as in `"colors#primary"`.

- When `set_literal` stores a bare value, such as `10:00` or `(5)`, it counts as quoted if a save quotes it, as it does from the other setters. Its `quoted` flag read false before the save and true after it.

- `E003` names the index as written. An index one past the 64-bit range was shown as 18446744073709551615.

- The node cap of `parse_limited` counts comment lines and kept lines too. A file that had only those didn't build any node, so a capped parse of it stored 100 times the file. A cap that's crossed on the last line no longer reports `E020`, since nothing was left to stop.

## v3.0.0-beta1 - 2026-11-05

This release is format 3. It fixes the 2.x design flaws that heavy use turned up. v4 will keep this format and settle the programming interface.

### Upgrading from 2.x

- Run `shcl upgrade --from-2x FILE` or `shcl migrate --from-2x FILE` once on a 2.x file. A program can call `upgrade_file()` on start.

- A backslash is plain text. Escapes are names between 2 `◉` marks, such as `◉NEWLINE◉`, `◉TAB◉`, and `◉U+200B◉`.

- An array is `[80, 443]` or one `- ` item per line. `*` items and comma lists are gone.

- A selector goes in parens, `site(example.com).root`, and an index is `site(0)`. `[#N]` and `field:[disc]` are gone.

- A bare value may have spaces in it. A bare name starts with a letter. A value in backticks is raw.

- `fmt` and every canonical save keep a value's quotes, and quote one that has whitespace or punctuation.

- A thousands comma makes a value text at Standard and Strict.

- Exit 1 is a usage error only, 7 a save-gate refusal, and 8 a file that can't be read or written.

- Every setter returns a `SetStatus`, and one whose path matches more than one field writes nothing. `write_reason` is now `check_set_path`.

- A Strict load fails the same way from every call that takes a strictness.

- A save refuses a file another program changed since the load. `force` overrides it.

- A failed write gives a `WriteError` with a `WriteStatus` in every binding.

- `shcl set` writes back the lines its edits leave alone. `fmt` still writes the canonical form.

- `shcl --version` prints the build number and the copyright line. The words `version`, `about`, and `donate` are gone.

- The project moved to `github.com/yottacore/shcl`. Old links redirect. The Go import path is `github.com/yottacore/shcl/source/go/v3`.

- Renamed: `format_f64` to `format_float`, Rust's `ZoneSpec` to `Zone`, C's unit names, and Python's `Quote` and `Rules` members. Removed: Go's `Read.OK()` and C's `shcl_get_int`, `shcl_get_float`, and `shcl_get_bool`.

- C++ no longer includes the C interface.

- The Bash and PowerShell wrappers are retired. Call `shcl` directly.

- The installers default to the newest full release, for the current user.

### New

- Saves that keep every line an edit didn't touch, and `save_file_with()` with the `lossy`, `keep_lines`, `force`, `create`, and `mode` options.

- A file that names a newer format is read-only (`newer_format()`).

- `upgrade_file()`, `upgrade()`, `migrate()`, `set_banner()`, the info block, and a Schema line that `check` follows (`read_named_schema()`).

- Status reads for counts, instances, children, lines, kinds, and the Format line, with a `BadPath` status.

- `fields()`, `instance_paths()`, `kind()`, `format_value()`, `format_array()`, `format_diagnostic()`, and `load_and_validate_with()`.

- Duration and size reads and schema types. Octal and binary ints.

- Hints `H005` to `H008`.

- `shcl explain`, `shcl tokens`, `shcl help CMD`, `children`, `paths`, `instances --paths`, `fmt --check`, `--remove`, and the `-default` set flags. A mistyped command or option gets a did-you-mean.

- `ReadFile`, `ParseLimited`, `get_raw_info`, and a `DateTime` alias.

- C: `_to` reads, `shcl_compact`, and an out-of-memory hook. C++ can write.

- A universal macOS binary for macOS 13 and later, a FreeBSD x86_64 binary, and a FreeBSD package. The installers take `--version`.

### Fixed

- Parsing: lines under a skipped line, raw block fences and nesting, carriage returns, the Unicode trim, quotes inside a bare value or selector, `E003`, `E004`, `E007`, `E009`, and `E011` lines kept as written, and diagnostic order and length.

- Reads: wildcards, float and int range, named-month dates, `allowed` on a datetime, and unreadable paths.

- Writes and saves: kept lines moved by a set, a remove or a fold, setter input checks, float rounding, comment order, symlinks, directories, file mode, and long names.

- Merging: layer order, footer comments, and kept lines in a replaced leaf.

- Schema and init: bound messages, `min` above `max`, units on bounds, `init` order and selectors, and schema load errors.

- CLI: `migrate` edge cases, diagnostics under `--layer`, exit codes, flag conflicts, write-op parsing, help and completions, and long values in messages.

- C and C++: leaks, stack use, and `_GNU_SOURCE`.

- Go and Python: copies of diagnostics, UTF-8 checks, close errors, and save messages.

- Windows: file attributes and ACLs, device names, symlinks and long paths in C, and line endings.

- Installers and packages: release picking, uninstall, umask, PowerShell 5.1, glibc and libgcc needs, reproducible packages, and `install-dev.bash` tool checks.

- Performance: formatting, flat-key reads, bulk removes and merges, colon-less lines, and the did-you-mean suggester.

## v2.0.0 - 2026-08-26

This is the first major release since 1.0.0. There are 2 incompatible changes, and both are listed under Changed. Escapes now resolve in field names, so `"a\"b"` and `'a"b'` are one field where they used to be 2. The C++ veneer's `read_datetime` returns the structured value that every other binding's does, and the text form moved to `read_datetime_str`. Canonical output also changes in several cases where the old output lost something or wouldn't settle. So a file reformatted by 2.0 can differ from the same file reformatted by 1.2. Go consumers update the import path to `github.com/jim-collier/shcl/source/go/v2`. Anyone who installed the Go CLI switches to the Rust binary, which is now the only one distributed, as Removed says. Rust and Python consumers change a version constraint and nothing else.

### Added

- A file tier in every binding and the C++ veneer. `LoadFile` and `SaveFile` were added beside the existing text entry points, with a load status of `Clean`, `HadErrors`, `NotFound`, or `Unreadable`, which tells a caller why a load came back thin. The atomic write through a temp file and a rename moved out of the CLIs and into the libraries, so a consumer no longer has to write it again to avoid truncating a config on a full disk. The C binding compiles the whole tier out under `SHCL_NO_FILE_IO` for freestanding builds. A save that creates a file gives it the mode that an ordinary create would, which is `0666` narrowed by the umask. Those are the same bits an editor or a shell redirect would have produced. A save that rewrites an existing file keeps the permission bits it already had.

- `LostCount()`, and a save gate built on it. `SaveFile` refuses to write a document that lost content on load, rather than quietly saving the loss. `SaveFileLossy` is the explicit override. The refusal is a value the caller can act on, which is `SaveError::Refused` in Rust, a `*SaveRefused` error type in Go, `SaveRefused` or `SaveFailed` raised from a `SaveError` base in Python, and `SHCL_SAVE_REFUSED` or `SHCL_SAVE_FAILED` in C. The gate decides before any I/O, so a lost document saved to an unwritable path still reports the refusal rather than the write failure.

- `AuthoredName(path)`, which returns a name as it was written in the source, escapes and all. It's the one accessor that returns source text. Everywhere else, a name is stored, compared, emitted, and listed with its escapes resolved. That's why a round trip of a document that cares about the original spelling needs it.

- A convenience tier named `_or` in every binding, such as `GetIntOr`, `get_int_or`, `shcl_get_int_or`, and `get_or<T>`. Each call returns the value on `Good`, and the caller's fallback otherwise. Rust and Python gained 11 each, and C gained 3, so a routine ported between 2 bindings can no longer keep the call name while silently changing tier.

- `reopen: true` as a schema key, plus `SuppressDeclaredReopens`. A schema declares once that a config is expected to re-open a section in several places, instead of every consumer learning to ignore `H002`.

- Rust gained `Clone`, `FromStr`, and `Display` on `Document` and `Status`, so `println!("{doc}")` prints the canonical form. `FromStr` has `Infallible` as its error, since a Standard parse can't fail. `format_f64` is public, and the float setters use it.

- The C++ veneer gained the calls it was missing. Those are the file tier, per-slot array statuses, a datetime array read, `exists`, `quoted`, and status to text. Go gained a `String` on its load status and the 5 array status reductions. Go and C gained an `ok()` predicate, which the other 2 already had.

- `shcl --lossy` on `set --write`, which is the CLI half of the save gate, and `-v` beside `-V`. A read failure now prints why on stderr in every mode rather than only under `--on-bad=error`, and stdout is byte-identical. `--on-bad=default` and an empty value outside error mode stay quiet on purpose.

- `shcl set --write` creates FILE when nothing is at the path yet, so a first write no longer needs a `touch` before it. `fmt --write` has nothing to format and still reports the file missing. A file that exists but can't be read stays an error in both, since the alternative is writing over something unread.

- A man page and shell completions. `man shcl` documents every subcommand, option, write op, and exit code, and says which options each subcommand takes. The help only hints at that. The bash and zsh completions offer each subcommand only the options it accepts. An option that a subcommand doesn't take is a usage error, so offering it would be wrong. The `.deb` and `.rpm` put the man page and both completions where each tool already looks. The installer symlinks the man page into the target's own `man1` directory, and leaves the completions with the line to enable them.

- The installer gained `--uninstall` (`-Uninstall` on Windows), a sudo pre-check, a working no-terminal guard, and an `export PATH=` line to paste when the install directory isn't on the path.

- Windows executables have the program icon, and the product name, description, version, company, and copyright that the properties panel expects. That goes for both the x86_64 and ARM64 builds and for the setup. The version is read from the build, so it can't drift from what `shcl version` reports.

- Release builds are reproducible. On the pinned toolchain, a build of a given commit gives a byte-identical binary on any machine and from any directory, for all 4 released targets. So the published checksum can be reproduced rather than trusted. The README says so beside the checksum instructions.

- `-Help` on the Windows installer, which lists the same options that the Linux installer's `--help` does. The documented one-line command pipes the script straight into the shell, so there wasn't any file left for `Get-Help` to describe.

### Changed

- **Field names resolve their escapes.** `"a\"b"` and `'a"b'` name one field. Each one used to be a separate field keyed by its own text, so 2 spellings of one name were 2 names, even though the same 2 spellings as values were one string. Names are compared, emitted, and listed with their escapes resolved, and `AuthoredName` still returns the source text. As a result, a line break in a name can be written, since names are emitted through an escaper that writes it as `\n`. A line break in a `[value]` selector is still refused, because that text is stored raw.

- **The C++ veneer's datetime reads swap names.** `read_datetime` returns `Read<Datetime>`, which is the structured value that every other binding's `read_datetime` returns. The text form it used to return is now `read_datetime_str`. The old pair had the names backward compared to the rest of the project. A veneer consumer that calls `read_datetime` gets a compile error rather than a silent change of meaning.

- The author's quotes on a plain string survive the formatter. `ver: "8"` still normalizes to `ver: 8`, since a reader types that value the same either way and the quotes don't mean anything. But a quoted plain string keeps its quotes through `fmt` and `init`. Stripping the quotes left a value unescaped when a downstream language treats it as special, such as `"@null"` or a quoted function reference. The `quoted` read flag exists for that case.

- A quoted by-value selector matches a scalar only. `x["a, b"]` selects a value with a single element whose logical string is `a, b`, rather than matching against the whole display form. A bare selector is unchanged.

- Parsing uses far less memory in every binding, and less time. A 100 MiB document used to take 39x to 72x its size in memory, from 3.8 GB in Rust up to 7.0 GB in C. It now takes 21x to 47x, which is 2.1 GB in Rust, 3.0 in C, 3.3 in Go, and 4.7 in Python. C went from the heaviest binding to among the lightest, and load time is down as much as 40%. Output is byte-identical, since it's the same parse with less kept in memory.

- A line that's malformed in content but sound in position is kept as inert trivia and written back, instead of vanishing. Lines whose position can't be recovered are still dropped and still count toward `LostCount`, which the save gate reads. A line that starts with a BOM is left out on purpose, because emitting it again produces content that the parser reads back as live.

- `shcl set --write` consults the save gate. It used to delete unreadable lines at exit 0 with nothing on stderr. The recorded reason was that a person sees the diagnostics anyway, but that was false at the default strictness, where they don't see anything at all.

- `shcl set -` follows stdin. It reads the piped document when the edits come from options, and starts from an empty base when the ops script is on stdin. The 2 meanings never compete, so nothing that worked before changed.

- The unknown-field sweep runs through a schema fault in a key instead of skipping the whole sweep. It skips only where the fault costs the entry its path, which is `V093` and `V095`.

- `H002` reports at every merged level rather than only the first. A map that's entered again passes the re-open line down to its children.

- A bare `shcl` prints the help and exits 0, the same as `shcl help`, where it used to print the same text and exit 1. The convention is that asking for help succeeds.

- Every setter in the reference is `#[must_use]`, so a discarded write is a compile warning rather than a silent no-op. The other bindings don't have an equivalent annotation. The behavior is unchanged in all 4.

- Performance changes, all measured:
	- The check for whether to quote on emit takes 0.09s on 400k bindings, where it took 0.24s.
	- The setters share one path scan and one tree walk, so 80k writes went from 1.31s to 1.14s.
	- The C binding parses the same corpus in 751 MB and 0.80s, where it took 1332 MB and 1.19s. It also keeps one copy of its output during emit rather than 4.
	- Go went from 660 MB to 593 MB, and from 1.42s to 1.11s.

### Fixed

- Go, Python, and C disagreed with the reference on a quoted selector whose lookup needed the rare fallback scan. They created a node where the reference selects one. The accelerator is meant only to speed things up, so a miss must never change the result. The 3 ports now scan again on a plain miss, as well as on a hit of the wrong kind.

- The C binding's number parsing and formatting followed the host program's locale. Under a locale with a decimal comma, the canonical output differed from the other 3 bindings, every float read came back `BadType`, and the float formatter truncated `1.5` to `1`. Both sites now translate the decimal point themselves. Pinning the locale would have been a side effect on the whole process, which a library shouldn't cause, and it isn't thread-safe.

- A setter accepted a path segment or a by-value selector containing a line break, and wrote a document that parsed back to nothing. Both are refused now. A name escapes the break instead, as Changed says.

- A value with leading or trailing whitespace outside space and tab was truncated on write. The rule that quotes whitespace at the edges now applies to the whole set that all 4 bindings already agreed on.

- `fmt` emptied a line of only whitespace inside a raw block. Once that stopped, it grew a raw block whose body doesn't have any non-blank line by one indent level on every pass, without limit. The common indent is taken from non-blank lines, so such a body doesn't have any indent to strip. The formatter now doesn't add any back, and leaves the body byte-for-byte. Normalizing the line away would also have ended the growth, but a raw block promises verbatim content, so it's the wrong place to throw out a line of non-breaking or ideographic space.

- Merged output wasn't always a formatter fixpoint. An empty binding in the base and a block with the same name in the overlay both survived a merge, but parsing the 2 run together folds them. Merge now uses the parser's own rule for filling an empty binding, so the 2 agree. That also removes the emitter's workaround for the resulting pair, which wrote the fence on the name's line and lost any info string with a `#` in it.

- A line in a raw block body that ended in more than one carriage return wasn't a fixpoint. The load stripped one, the write turned the one left into a line ending, and the reload dropped it. The whole trailing run comes off at load now. A carriage return inside a line is content and still round-trips.

- Python's integer setters range-check against `i64`, so a value no other binding could store is refused rather than written and read back wrong.

- Python's merge and clone walks use explicit stacks. When a document at the documented depth cap was merged from a caller 900 frames deep, it used to run out of interpreter stack past about 485 levels and leave the base document half changed.

- The C++ veneer's `Datetime` move operations left the moved-from value with a view of digits it had given away, so it formatted a fraction it no longer had. The rebind now enforces the invariant, and it can't be bypassed.

- On Windows an in-place write left the file's ACLs, attributes, and alternate data streams behind. A rename puts a new file in place, and everything the old one had outside its contents was lost with it. The write goes through `ReplaceFile` now, which copies them onto the replacement. It falls back to the old replacing move when the file is being created or the merge can't be done. On POSIX the parent directory is synced after the rename, as well as the file before it, so a power cut can no longer lose the rename itself and leave the old content. The spec now lists what a write still can't keep, such as other hard links, POSIX ACLs, extended attributes, and the SELinux label.

- The PowerShell wrapper needed PowerShell 7. It used one operator that older versions don't have, on the line that passes on the binary's exit code, so it failed on the Windows PowerShell 5.1 that comes with the OS. That line is written the long way now, and the wrapper runs on both.

### Removed

- The C++ veneer's `read_datetime_raw`. `read_datetime` does its job now, as Changed says.

- `go install github.com/jim-collier/shcl/source/go/cmd/shcl@latest`. The Go module is only the library now. Its CLI is in a module of its own, and the published module no longer includes it. That CLI was only ever a test fixture for the cross-binding check. It was byte-identical to the reference by design, and it didn't offer anything of its own. The Rust binary is the CLI this project distributes, and it's what the packages, the installers, and `cargo install shcl` all install.

## v1.2.0 - 2026-08-04

### Added

- `shcl about` and `shcl donate` on the CLI, each also written `--about` and `--donate` the way `help` and `version` already are. `about` gives the version, copyright, project home, license, and a short description of what SHCL is. `donate` points at the GitHub Sponsors page.

- `Lines(path)` in each binding's spelling, plus the C++ veneer, which is the plural of `Line(path)`. A repeated field is the case that most needs a line to cite, and the singular returns 0 for it. `Lines` returns every binding's line in file order. Unresolved wildcard slots stay as 0, so the indices still match `Count`.

### Changed

- `help`, `about`, and `donate` print with a blank line above and below, so the block stands clear of the shell prompts on either side of it. Bare `shcl` still prints the same help text without the blank lines, because it's a usage error rather than something asked for. `version` stays a single bare line, so it's still easy to capture.

- A schema fault no longer turns off all data validation. Faults in the `V090`+ range are still reported first and still fail `check --schema`, but the constraints that parsed cleanly now check the document too. So a typo in one constraint can't hide a real violation of another. The unknown-field sweep still needs a schema without any faults, since a dropped constraint would make the fields it declared look unknown. `shcl init` is unchanged, and generation still fails on any fault.

### Fixed

- The C CLI treated an informational flag in a `--set-literal` value as a request for that output, where the other 3 read it as the value. Its option-skip list was missing `--set-literal`, so `shcl get --set-literal -h FILE PATH` printed the help text instead of reading.

- When all of a block header's children were commented out, the formatter gave those comments back one indent level too shallow. When a header without children had comments at the end of the file, they lost their indent completely. A comment written deeper than a block's last binding now stays inside that binding's block at its own depth, in every binding. Comment runs at the binding's own level follow it as before.

## v1.1.0 - 2026-08-04

### Added

- A wildcard `*` in the name position of lookup paths. `Get("indicators.*.period")` reads across children of any name, the way `[*]` reads across instances, with per-slot statuses that line up with `Count` and `Instances`. A schema path can declare an open section, which allows any child name and gives each one the same fields, without listing the names. The setters refuse a wildcard path, but `Remove` on one removes every matching slot. A field whose name is `*` itself can still be reached quoted, as `"*"`.

- Schema fragments. `fragment: <name>` declares a reusable set of ordinary `field:` entries with relative paths, and `inherits: <name>` mounts it at a field's path. Fragments may be recursive or refer to each other, with no depth limit, because validation follows a mount only where the document has nodes. So structures that nest without limit, such as layout trees, validate at any depth, and one fragment can be mounted at several paths instead of copying its fields. `shcl init` expands mounts into the starter config, and stops where a fragment would enter itself again. There are new schema fault codes, `V094` for a bad fragment declaration and `V095` for an `inherits` that doesn't name any declared fragment.

- `QuoteSegment` in every binding and the C++ veneer. It quotes one path segment, so a name that a user typed can safely be put into a lookup path. Without it, a dotted name silently reads as nesting.

- `Children(path)`, which returns child field names in file order, duplicates included. So an open section, used like a map, can be read without scanning `Paths()` for a prefix. The empty path lists the top level.

- `Line(path)`, plus `line` and `quoted` on the read result in Rust, Go, and Python. C keeps its structs of value and status, and gains the `shcl_line` and `shcl_children` accessors. A consumer's own checks can cite the source line, and can tell a quoted value from a bare one, such as `a: "@null"` from `a: @null`.

- `LoadAndValidate(text, schema, strictness)`, which parses and validates in one call. It returns the document with one combined list of diagnostics, so a caller doesn't merge 2 lists by hand and lose half the errors. `ErrorCount()` was also added, to say whether the file had errors.

- A new `H002` hint when a binding merges with an earlier one that isn't next to it. When 2 `table: t` sections written apart silently became one table, that's now visible, and the message names the earlier line. A mention right after the first one, and merges through a selector or an intermediate path, stay silent, since a repeated path written that way is on purpose.

- `check --schema` now drops `H001`, the repeated bare leaf hint, for fields whose schema allows more than one repeat. The schema declares that repeats are how those fields get instances, and the hint was teaching users to ignore hints.

- `SuppressDeclaredRepeats(schema, diags)` in every binding. It drops the repeated field hint for any field whose schema allows more than one instance. It's the same filter that `check --schema` applies, and a program can call it anywhere it has both document diagnostics and a schema.

- `WriteReason(path)`, which returns the reason a write at a path would fail, behind the setters' bare pass or fail. The reason is `BadPath`, `ValueInPath`, `Wildcard`, `NoSuchIndex`, or `TooDeep`. It only checks, and never creates anything.

- `V096`. When a starter config is generated from a schema whose fragments mount each other along several paths, it now reports a schema fault instead of expanding until it runs out of memory.

- `shcl set --write FILE --set PATH=VALUE` writes edits given as options straight back to the file. Before, the only way to save an edit was an op script with tab-separated fields piped in on stdin. That's awkward to write by hand in any shell, and impossible to read once the tabs are invisible. Edits now don't need a pipe or a tab. The options are repeatable and apply in the order given.

- `--set-literal=PATH=TEXT` beside it, for the values that `--set` can't write. A `--set` value is data, so `ports=80, 443` stores one quoted string. The same text through `--set-literal` stores an array of 2 elements, because it goes in as value syntax, the way a file writes it. Both share one ordered list, so the last option to touch a path wins. Raw blocks, a set only when the field is absent, and removal still go in as an op script.

- `SetLiteral` and `SetLiteralDefault` in every binding, as `set_literal` or `shcl_set_literal`, which are the library half of the above. They read their argument the way the parser reads the value half of a line, so a consumer with value text can write it without first working out what kind of value it is. Text with a line break, or a quote that never closes, is rejected rather than written. An unquoted `#` ends the value, as it would in a file. The op script gained a matching `literal` op.

- Starter configs from `shcl init --schema` end with a short footer that names the format and links its home page and spec, so whoever opens the file next can find out what it is and how to edit it. `--no-banner` leaves it out, and `generate` takes the same flag in every binding.

### Changed

- `generate` gained a `no_banner` argument in every binding. Python and the C++ veneer give it a default, but Rust, Go, and C callers must pass it. The flag is negative on purpose. Passing false, zero, or nothing writes the footer, so a caller has to ask to leave it out.

- The Go module's `go` directive dropped from 1.24 to 1.20, which is the tested floor. `strings.CutSuffix` is the newest standard library call it uses. So projects with a pinned toolchain can use the module instead of vendoring the file.

- `shcl set` no longer reads a write-ops script from stdin when any `--set` is given. This only affects a command line that passed both, which used to apply the `--set` values and then the piped ops. Pass the whole edit one way or the other. The 2 `--write` refusals also got their own wording, and each names only the option that clashed, rather than "--layer or --set".

- Top-level nodes that the writer creates now have one blank line between them, as a hand-written file would. Written and generated output changes to match.

- Parsing is faster. The reference no longer copies every line and its indent, and 3 bindings scan paths without building a list of characters for each line. Formatting a large file is roughly 10 percent quicker in the reference, Go, and C, and about 12 percent quicker in Python.

### Fixed

- The canonical formatter no longer loses the author's comment layout in 2 ways. A blank line between regions of only comments survives the round trip. A comment written deeper than the next binding stays with the block it's in, instead of moving to the next field with less indent. It's emitted after that block's last child, at the block's indent.

- A failed strict load is no longer a dead end. The failure includes the parsed document, and Go's `ParseWith` also returns it, not nil, along with the error. The message names the first few diagnostics instead of a bare count.

- `Paths()` no longer hides a node whose name needs quoting, or its subtree. Segments that can't be bare come back quoted and escaped, so every path it returns is a valid lookup path, and the list matches the document.

- A read's raw text is now the value as it was written on its source line, as documented. It used to be the canonical display form, which silently rewrote `^\d{2,3}$` to `^\d{2, 3}$`. Values that don't have a one-line source text keep the display form as a fallback. Those are values the writer built, stacked lists, and raw blocks.

- By-value selectors now apply escape sequences to both sides before comparing, so `["q\"uote"]` finds an instance written `'q"uote'`. Before, the comparison was text against text, and the mismatch was a silent `NotFound`. The writer's placement walk had the same gap, and could create a false second instance.

- Formatting a file could change what it meant. Some values only became final after their siblings were keyed, such as a stacked list that closed onto an earlier instance's value, or a fenced block that filled an empty field that matched an earlier one. Such a value was left beside its match instead of merging. So the file formatted to 2 entries and then reformatted to one, and a read that correctly reported several instances started returning a value.

- An in-place rewrite created its temp file under a predictable name without asking for exclusive creation. So anything already at that name, including a symlink someone else had put there, was written through, and the rename then turned the config itself into a link. The temp file is now created exclusively, and it gets the target's permissions before any data is written to it. So a private config is never readable to anyone else, even briefly.

- Validation against a recursive schema could fail to finish, because a fragment reached from 2 paths was checked again for each path at each level. Each fragment is now checked once per node. The C binding also kept every level's working data until the end, and now it frees that data as it goes.

- Python raised on numerals beyond a few thousand digits where the other bindings report a bad type. Length is checked before conversion now.

- The C date formatter could write past the buffer size it documents when it was given a value that the caller built, rather than one that came from parsing.

- The C++ wrapper's structured date read returned a pointer into the document's storage, so the value dangled once the document was gone. It owns its fractional digits now, which changes what `read_datetime_raw` returns.

- Comments were dropped when documents merged. A section in both layers lost the higher layer's comments, and a write that merged duplicate fields lost any comment under the one that lost. A footer several layers share is now kept once rather than repeated per layer.

- The call that loads and validates in one step ignored a schema that failed to load, so constraints on its broken lines silently vanished. It reports the schema failure now, as `check --schema` does.

- A value or a path that read like `-h` or `--version` printed help or the version and exited successfully. Only a flag in option position counts now, and `--` ends the options so a path may begin with a dash.

- Rewriting a file in place while merging layers folded those layers permanently into it. The combination is refused.

- Generated starter configs didn't always load. A wildcard written with spaces, or with the alternate colon spelling, produced a line that the parser rejects, and a deep chain of fragments produced paths past the nesting limit.

- C had 3 entry points that left working data in documents they don't own, so a long-running program that kept one parsed schema kept growing.

- The Go repeat-hint filter rewrote the caller's list while returning a new one.

- Quoting a name that ends in a backslash produced a path that couldn't be read back.

- Repeat-hint suppression could silence an unrelated field when a schema path ended in a quoted name containing a dot.

- A field name with a null byte in it could match a schema path of 2 segments, and get past the unknown-field check.

- A system install linked the program into a directory that isn't on a normal user's path.

## v1.0.0 - 2026-07-28

This is the first stable release. Semantic versioning now applies to the language, the read and write APIs, and the diagnostic codes, so a breaking change to any of them means 2.0.0.

### Added

- Published packages. Rust is on crates.io as `cargo add shcl`, Python is on PyPI as `pip install shcl`, and the Go module is by tag at `github.com/jim-collier/shcl/source/go`. Binding versions move in lockstep with the product version, so each ecosystem's usual compatible-version operator tracks minor and patch releases without crossing a major version.

- Signed releases. The `sha256sums` file now comes with a detached signature made offline with the project signing key, and both install scripts verify it before trusting any checksum out of that file. The public key is in `shcl-signing.pub`, for checking by hand.

### Changed

- The Windows `user` install moved from `%USERPROFILE%\bin\Shcl` to `%LOCALAPPDATA%\Programs\Shcl`, and adds that directory to `PATH` directly instead of keeping a second copy of the executable one level up.

- `install.bash` now requires `openssl` along with `curl` or `wget`. There isn't a fallback that installs without checking.

- The trademark policy is now built around conformance. An implementation that passes the published corpus may use the name, without asking and without affiliation.

## v1.0.0-rc1 - 2026-07-26

### Added

- Schema validation, with a schema that's itself a plain SHCL file. Every binding has `validate(doc, schema)`, and `shcl check --schema=FILE` reports stable `V###` codes.

- Layered loading, with `merge(base, over)` in every binding, plus repeatable `--layer=FILE` and `--set=PATH=VALUE` overrides on the loading subcommands.

- Generation from a schema. `generate(schema)` and `shcl init --schema=FILE` emit a commented, typed starter config that validates clean against its own schema.

- Installer packages. There's a `.deb` and an `.rpm` for each Linux binary, and a Windows setup, and the release checksums include all of them.

- `paths()` in every binding and the C++ veneer, to list a document's field paths in file order.

- `set --write` rewrites the base file in place, matching `fmt --write`.

- New diagnostics `E016`, for a document nested past the cap of 512 levels, and `E017`, for a value that opens a quote it never closes.

### Changed

- Blank lines between bindings now survive the canonical formatter instead of being discarded. Runs of them collapse to one.

- Every subcommand rejects options it doesn't use instead of silently ignoring them.

- `init` exits 6 on a broken schema, matching `check --schema`, and lists the schema faults.

- Large documents are faster. Merging, inline `[value]` selectors, stacked lists, raw block formatting, and schema suggestions all went from quadratic to linear time. A merge of 32k keys went from 16 seconds to 0.07 in the reference, with byte-identical output.

- C memory use stays flat under many reads or many merges, where it used to grow without limit.

- The Windows installers edit `PATH` in the registry one segment at a time, and keep its type. Installer downloads require https with TLS 1.2 or newer.

- When an internal invariant breaks, the library goes on as well as it can rather than aborting.

- The spec states that lowercase is a field name's canonical spelling.

### Fixed

- A bare section header in a higher layer merged over a base document deleted the whole subtree below it. It now merges. Clearing a leaf from a layer still works.

- A write to an unusable path, such as a wildcard or a missing `[#N]`, reported success and could leave a half-created path behind. Setters now report whether the write applied, and nothing is created unless the whole path is usable.

- `fmt --write` could leave a truncated file if interrupted, and C reported success on a failed write. Both writers are now atomic.

- An in-place write no longer discards what it replaces. The target's permission bits are preserved, and a symlinked config is written through instead of being replaced by a regular file. Any other hard link to the file still keeps the old content, which a rename can't avoid.

- The Writer could create 2 siblings that a second parse would merge, so its output wasn't a formatter fixpoint.

- The bindings checked `shcl set` op values in 4 different ways. All 4 now use the reference's grammar.

- `shcl init --schema` could generate a file that its own schema rejected, and could emit lines that don't parse.

- Go `Validate` aborted the process on a schema path with a `[#N]` selector at or above 2^63.

- Deeply nested documents crashed 3 of the 4 bindings, each at a different depth. The nesting cap catches them at load.

- The C CLI silently capped `--layer` and `--set` at 64 each.

- `shcl.h` didn't compile as a drop-in C++ translation unit under `-Wall -Wextra -Werror`.

- Some README and spec examples named APIs that don't exist.

## v1.0.0-beta2 - 2026-07-21

### Added

- Writer API in every binding, with typed `set_*`, array and `_default` forms, `set_raw`, `remove`, comments, and an empty document constructor. A `shcl set` CLI subcommand reads its edits from an ops script with tab-delimited fields.

- The canonical formatter keeps comments as node trivia rather than throwing them out.

- Stable diagnostic codes, `E###` and `H###`, on `check`. They print as `line N: severity: CODE` on stdout, with the message on stderr.

- Convenience read tier with whole-value fallbacks, `get_*_or` or `default=`, across the bindings.

- `--rawinfo` accessor for a raw block's info string.

- Per-slot statuses on wildcard array reads, plus `--slots` and per-slot `--default` on the CLI.

### Changed

- `check` exits nonzero whenever any error diagnostic is present, not only on strict-load failure.

- Value options accept both `--opt=VALUE` and `--opt VALUE` with a space. `help` and `version` are also accepted as subcommands.

- The bindings behave the same way on a broken pipe, an invalid argument encoding, and running out of memory.

- The dogfood install is now atomic. It writes a temp file in the destination, then renames it over the target.

### Fixed

- Hex integer bounds now read `i64::MIN` correctly and reject out-of-range magnitudes.

- Merge keys are now injective, so distinct arrays and raw blocks can no longer collide.

- Formatting a large document no longer risks a stack overflow, since emit is now iterative.

## v1.0.0-beta1 - 2026-07-15

This is the first tagged pre-release.

### Added

- Language spec and formal grammar (`project/spec.md`, `project/grammar.abnf`).

- Conformance corpus of golden cases that every binding must pass.

- Rust reference parser and the `shcl` CLI (`get`, `fmt`, `check`, `count`, `instances`).

- Independent parsers for Go, C (with a C++ veneer), and Python, each corpus-green.

- Bash wrapper around the CLI, usable as a script or sourced for typed helpers.

- Strictness levels loose, standard, and strict, set per document.

- Raw fenced blocks for verbatim multi-line content.
