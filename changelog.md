# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Upgrading from 2.x

- `children` on a path with several instances lists each one's children, where it listed nothing.

- A backslash is plain text everywhere, bare or in either quote, so `path: "C:\temp\new"` reads as written. `\n`, `\t`, `\\`, `\"`, `\uXXXX` and the rest are not escapes any more, and `\,` and `\#` no longer protect a comma or a `#`.

- An escape is a name between two `◉` marks, from a fixed list: `◉NEWLINE◉`, `◉TAB◉`, `◉U+200B◉`, and `◉ESCAPE_CHAR◉` for the mark itself. Anything else between two marks is `E023`.

- `set`'s write-ops script reads the same escapes in a string, raw or comment value, so `◉TAB◉` and `◉NEWLINE◉` put a tab or a line break on one op line, and a backslash is text. It read `\n`, `\t` and `\\` there. An unknown name refuses the op.

- `get --array`, `get --slots` and `instances` print a value holding a line break quoted with `◉` escapes, `"a◉NEWLINE◉b"`, where they wrote `"a\nb"`.

- `fmt` and every save write a line break, a tab in quotes and each invisible character as a `◉` escape. A zero-width space or a direction mark comes out as `◉U+XXXX◉`. The joiners stay as written, and so do a variation selector after a visible character and the tags of a subdivision flag.

- A value in backticks, such as `` `#FF8800` `` or `` `\x7F` ``, is raw. A read returns the text as written, with a `backtick` flag, for the program to decode.

- An array is written in brackets, `ports: [80, 443]`, or one `- ` item per line. `[]` is empty. A malformed one is `E019`.

- A bare value may hold spaces, as in `title: My App`, but not a quote, a tab or a bracket (`E025`). A colon or comma needs a character other than whitespace right after it, so `rw,noatime` and `localhost:8080` read bare, `host: a.com port: 80` is `E025` and `ports: 80, 443` is `E026`.

- A bare field name starts with a letter. Quote any other name, as in `"404": x`, or it is `E014`.

- `*` is no longer a list marker (`E013`). `- name: value` is `E027`, and an array on a field with lines under it is `E028`.

- A quote or backtick that never closes is `E017`.

- Each of these errors keeps its line as written. When the name reads, the lines under it still load.

- `E010`, `E024`, `H003` and `H004` are retired.

- A selector matches one plain value, never an array.

- `fmt` keeps a plain string in the quotes it was written in.

- A selector is written in parens, `site(example.com).root`, and brackets are only for arrays. A selector in brackets is `E029`, and a path in brackets is refused. The `field:[disc]` form and the `[#N]` index are gone; an index is `site(0)`. Quote a path with a paren on a command line.

- `fmt` and every canonical save never take quotes off a value, so `ver: "8"` and `zip: "02134"` stay quoted, where they came out bare.

- `fmt` and every canonical save quote a value, list item or array element holding any whitespace, `:`, `,`, `(`, `)`, `[` or `]`, so `display: :0` comes out `display: ":0"` and `opts: rw,noatime` as `opts: "rw,noatime"`. Both still read bare.

- `shcl migrate FILE --from-2x` rewrites a 2.x file for these rules and leaves comments and layout alone. It writes comma lists in brackets, `*` items as `- ` and selectors in parens, quotes what would now read differently, and leaves a backslash as written. With `--write` the original is kept beside it, as `config_backup_20261007-091500_format-v2.shcl` for `config.shcl`, in local time.

- A file a pre-release build of 3.0 stamped `Format 3` is read as current, and `migrate` and `upgrade` leave it alone. Nothing tells it apart from a file this release wrote. A line the current rules refuse says so when it loads.

- Exit 1 is a usage error only. A save-gate refusal is 7, and a file or stream that cannot be read or written is 8.

- Two options asking for different answers are a usage error, in either order.

- The project moved to `github.com/yottacore/shcl`. Go imports change to match. Old links redirect.

- `format_f64` and `shcl_format_f64` are `format_float`, `SHCL_F64_BUF` is `SHCL_FLOAT_BUF`, and Rust's `ZoneSpec` is `Zone`.

- Go's `Read.OK()` is removed. Use `Ok()`.

- A Strict load fails the same way from every call that takes a strictness. `load_file_with`, `load_file_keep_lines` and `load_and_validate` fail like `parse_with`, with the document inside the error, where they gave a plain document: Rust returns a `Result`, Go adds an `error` (`LoadFileWith` and `LoadFileKeepLines` return three values), Python raises `LoadError`. A schema finding fails the one-shot at Strict too. C and C++ keep their signatures, and `strict_failed` says so.

- C's `shcl_get_int`, `shcl_get_float` and `shcl_get_bool` are removed. They took a fallback, where `get_int` in the other bindings is the status read. Use `shcl_get_int_or` and its twins, or `shcl_read_int` for the status.

- A read status has a new last value, `BadPath`, so a match that names every status needs one more arm.

- `write_reason` is renamed `check_set_path` (Go `CheckSetPath`, C `shcl_check_set_path`). It returns a `SetStatus`, below, and its `Writable` value is `Ok`.

- Every setter returns a `SetStatus` in place of true or false: `Ok` when the write applied, or why it wrote nothing, such as `Wildcard`, `NotFinite` or `NotOneValue`. When the path and the value are both wrong, the path's reason comes back. In Rust the status is `#[must_use]`; compare it with `SetStatus::Ok`.

- `check_set_path` says `UnderArray` for a field under one holding an array, where it said `Ok`.

- A setter on a path that matches more than one field at any step writes nothing and returns `Multiple`, where it wrote the first match. `check_set_path` says `Multiple` too. `port(0)` or `site(1).root` picks one. `--set`, `--set-literal`, their `-default` forms and a `set` op line on such a path exit 1.

- The C++ veneer's `read_datetime_array` returns structured values. The text form is `read_datetime_array_str`.

- C++ no longer shows the C interface: a file including `shcl.hpp` gets no `shcl.h`, only the implementation file does. The calls the other bindings have as free functions are free here too (`migrate`, `format_version`, `generate`, `tokenize`, `quote_segment`, `read_file`, `write_file_atomic`, `suppress_declared_*`). `load_file` returns the document with its status, `generate` returns the faults, `Datetime` is `DateTime` with the reference's fields, and `Diagnostic.is_error` is `severity`.

- Python's typed setters raise `TypeError` on a value of the wrong type, and the array setters take a list.

- `shcl --version` prints `shcl v3.0.0`, plus a build number on a release binary. The words `version`, `about` and `donate` are gone: use `--version`, `--about` and `--donate`. Several of them in one run each print once, in order.

- `shcl set` writes back the lines its edits leave alone, printing or with `--write`, where it wrote the canonical form. `shcl fmt` still writes the canonical form.

- The installers default to the newest full release, installed for the current user. With no full release yet, that is the newest pre-release.

- The Bash and PowerShell wrappers are retired. Call `shcl` directly: `shcl_int f p` is `shcl get --int f p`. No package or installer includes them now, and an installer update removes the old copies from `scripts/`.

### New

- A prebuilt macOS binary, one universal file for Intel and Apple silicon, for macOS 13 and later. `install.bash` installs it.

- A prebuilt FreeBSD x86_64 binary. `install.bash` installs it, and names a release that has no binary for the platform it runs on.

- `parse_keep_lines()`, `load_file_keep_lines()`, `to_text_keep_lines()` and `save_file_keep_lines()` in every binding save a file with the lines no edit touched left as they were, dropped lines included, and fall back to the canonical form when that would not load back the same.

- `instance_paths()` in every binding walks a file one instance at a time, with `(i)` on each repeated name.

- `format_version()` and `migrate_unstamped()` in every binding, for a program that writes its own info block.

- `upgrade_file()` in every binding, for a program to call on start: a config file it cannot load clean is kept under a timestamped backup name and written fresh, with whatever settings carry over and the info block. A file that loads clean is left alone, unless the caller says it is 2.x and it reads differently now. `upgrade()` is the text half, and `backup_file_name()` and `write_backup()` the backup half. `shcl upgrade FILE` does the same, printing or with `--write`.

- `set_banner()` in every binding, and the `banner` op, put the info block at the end of a file and take an old one off first. The file's own comments next to the old one stay.

- `clear_comments()` in every binding, and the `clear-comments` op, take off the comment lines above a node, so a comment can be replaced. `comments()` reads them.

- C: `shcl_read_string_to` and a `_to` form of each array read copy into the caller's buffer, so the read arena stays flat without `shcl_reads_release`.

- Duration and size reads in every binding (`read_duration`, `read_size`), `shcl get --duration` and `--size` with `--unit` and `--decimal`, and schema types `duration` and `size` with `unit`, `decimal`, `min` and `max`. `500ms`, `1h 30m` and `1.5 GiB` read as whole milliseconds or bytes, and a bare number takes its unit from a name such as `timeout-ms`.

- The shell wrappers gain `shcl_duration` and `shcl_size`.

- Hint `H005` for a value in another unit than its field name ends in, as `timeout-ms: 5s`.

- Integers can be written in octal and binary, `0o644` and `0b101`, beside hex.

- A config file can name its schema on a `##    Schema   PATH` line. `shcl check` uses it when `--schema` is not given, reading the path from the file's directory, and leaves a URL to editors. `schema_ref()` in every binding reads it.

- `shcl explain [CODE]` gives the rule behind a diagnostic code, or lists every code.

- `shcl explain` on a retired code, such as `H004`, says it was retired and names the code that replaced it.

- `shcl help CMD` and `CMD --help` show one subcommand's help.

- A mistyped command, option or code gets a did-you-mean.

- `migrate()` in every binding, and `shcl migrate` with `--write` and `--check`.

- `fmt --check` exits 6 when a file is not in canonical form.

- `shcl tokens FILE` shows how the parser splits each line.

- `shcl children` and `shcl paths` list keys and walk a file. The shell wrappers gain `shcl_children` and `shcl_paths`.

- `--remove`, `--set-default` and `--set-literal-default` on the CLI.

- `ReadFile(path, maxBytes)` in every binding reads a file without parsing it.

- `ParseLimited` in every binding caps nodes, array size and diagnostics, for input from someone else (`E020` to `E022`).

- `get_raw_info` and `get_raw_info_or` in Rust, Go and Python.

- A `DateTime` alias beside `Datetime` in Rust and Python.

- `V097`: `init` checks its own output against the schema before returning it.

- `init` and a creating `set --write` put an info block at the end of a new file. `--no-banner` leaves it out. The text is a public constant in every binding.

- `init` writes prose comments as `##` and commented-out settings as `#`.

- C: `shcl_parse_datetime`, `shcl_compact`, `shcl_reads_release` and the `SHCL_OOM()` hook. A parse or validate that runs out of memory returns NULL instead of ending the process.

- C++ can write. It has the setters, `remove`, the tokenizer and the rest of the API, plus the format constants and `MAX_DEPTH`.

- The installers take `--version`.

### Parsing

- A line indented under a skipped line is skipped with it (`E018`) instead of moving up a level. That now holds under `E006`, `E012`, `E013` and a dropped `- ` item as well.

- A skipped line that opens a raw block takes the block with it.

- A malformed line that opens a raw block keeps the block with it, so the body no longer loads as fields and `fmt` writes it back under the line. A line that cannot be read at all still opens one when a fence follows its colon.

- A carriage return is whitespace outside a raw block, at the edge of any piece.

- Only a space, a tab or a carriage return is trimmed. A no-break space or other Unicode space at the end of a value is content.

- A `#` on a raw block's fence line starts a comment in both fence spellings.

- A stacked list that closes onto an earlier instance's value gets the same `H002` hint a merge written inline does.

- A raw block's nesting is its closing fence's indent, so a body can keep an indent of its own.

- An unterminated raw block at the end of a file no longer gains an empty last line.

- A comment after a top-level field belongs to the document.

- Two spellings of one quoted value are one instance.

- An unterminated quote in a selector is reported as `E017`.

- A quote in the middle of a bare value or a selector no longer swallows the rest of the line.

- A value after an index selector (`a(0): 2`) is `E002` and counts as lost.

- A colon inside a name or selector no longer hides a bracket array from `E019`.

- A `- ` with nothing after it is an empty item (`E009`).

- A trailing comment on a top-level `- ` line is kept.

- A comment or malformed line under a stacked list that folds into an earlier instance is no longer dropped.

- A blank line at the very start of a document is dropped at load, so the document matches its own canonical form.

- `E014` gives the column where the path went wrong.

- An all-digit selector too big for a 64-bit index names no instance, in every binding.

- A load lists its diagnostics in line order. The `H001` hints and a late `H002` came after everything else.

- A diagnostic lists the first 3 values of a list and counts the rest. The `H001` hint for a field repeated on 400,000 lines printed all of them, on one line, every run. `V004` on an array read as a string did the same.

### Reads

- A wildcard whose parent is missing reads `NotFound`, not `Empty`.

- A wildcard after a wildcard flattens to one slot per leaf.

- A float past the double range, such as `1e400`, reads `BadType`.

- An integer past the 64-bit range reads as a float in any spelling.

- At Loose, a float at or past 2^63 read as an int is refused rather than clamped, and `$ 3.14` reads like `$ 1200`.

- A named-month date takes a one- or two-digit day only.

- `allowed` on a datetime compares the moment, not the spelling.

- An array read of a one-element cell reports its quoting.

- The info-string of an empty binding reads `Empty`.

- A path that cannot be read as a path, such as `site[0].port`, `a..b` or one with a `: value` part, reads `BadPath`, where it read `NotFound`. The `_or` reads still give their fallback, and Python's value for it is 1, the CLI's usage exit.

### Writes and saving

- A line at an indent no level matches is written back as it was when the indent holds a space, and so are the lines under it. A save no longer refuses over one. A tab-only one is still lost.

- A malformed line among stacked list elements keeps the list stacked, with the line where it was.

- A save refuses when an edit would lose a line kept as written, the same way it refuses over a line the load dropped. The refusal says how many lines the write would delete from the file.

- A remove leaves the malformed lines beside the removed field where they were. A field opened only by the lines under it goes with the last of them and no longer leaves a bare `name:` line.

- A setter writing a field writes each malformed line of that name in its block as a comment, with a note giving the path, the local time and the reason. A new field goes right under the first of them. It wrote a second line for the field, which read as two once the malformed line was fixed.

- A setter writes only what reads back, and refuses anything else.

- C and Python setters refuse text that is not valid UTF-8, as Go's do. They took it, and the save wrote a file every reader refuses (C) or failed (Python).

- `SetFloat` refuses infinity and NaN, and `SetDateTime` refuses a date that cannot exist.

- `SetLiteral` refuses text a file line would refuse, such as a malformed array or a bad escape.

- `SetComment` refuses text with a line break, trims the way the load does, and puts the blank separator line above the comment.

- `SetRaw` trims its label the way a fence line is read. It refuses a label with a `#` or a line break, and a body whose lines end in a carriage return.

- A value with both quote kinds is stored the way a reload stores it.

- `Set<T>Default` refuses any wildcard path.

- `Remove` on a wildcard path removes every node it reaches.

- Every binding writes a float the same way, with ties rounding to even.

- Comments end up in the same place whether or not the file was saved between steps.

- A run of whole-line comments keeps its order and nesting through a save.

- A save through a dangling symlink creates the file where the link points. A symlink cycle is an error.

- A save to a path that names a directory is refused.

- A save keeps the file's whole mode, setuid, setgid and sticky included, and its group where it can. A read-only file is rewritten and stays read-only.

- A file whose name runs past about 240 characters can be saved.

### Merging

- Merging a layer and merging its formatted copy give the same result.

- A merge keeps a layer's own order and a footer comment it repeats. Merging onto an empty document changes nothing.

- A merge no longer deletes a malformed line kept above or under a leaf.

### Schema and init

- `V005` and `V006` name the bound and the value that broke it.

- A `min` above its `max` is a schema fault. The range is dropped, and the unknown-field check still runs.

- A bare `min` or `max` on a duration or size takes its unit from the field name before the schema's `unit`, the same as the value, so `min: 100` on `hold-ms` needs no `unit`.

- `init` writes lines in tree order.

- `init` selects a valued parent's instance by its value (`srv(web).port:`), on live and commented lines alike.

- `init` names a required path it cannot generate.

- `init` handles a path, selector or `desc` holding a comma or a line break.

- A `default` with no one-line spelling is `V092`.

- A generated config documents both `allowed` and a numeric bound.

- A fragment mounted by two paths reports each fault once.

- Validating against a fragment that mounts itself is no longer exponential in the document's depth.

- The `H001` and `H002` hints a schema disavows are matched on the built schema. A hint or diagnostic no longer splits across lines.

- `check --schema` prints the schema's own diagnostics, and still validates at strict.

- `validate` and `generate` report a schema that does not load as `V099`, as `check --schema` and `init` already did.

### CLI

- `migrate` refuses while a line sits at an indent no level matches, since 2.x read some of them.

- `migrate` refuses a file whose raw block never closes, since its Format line would have nowhere to go. Close the block and run it again.

- `get`, `count`, `instances`, `fmt` and `set` print the load's diagnostics to stderr, once, before any edit runs.

- Diagnostics under `--layer` name their file, and every layer's are printed.

- A `--write` with nothing to change leaves the file alone.

- A `--write` that creates a file says so on stderr.

- A stdout that cannot be written exits 8. A stderr that cannot be written costs nothing else.

- A closed stdin reads as an empty document on every platform.

- A directory given as FILE says `Is a directory` in every CLI.

- `-` may be named only once across FILE, `--layer` and `--schema`.

- `--set` splits at the first `=` outside quotes and parens.

- `--default` with `--on-bad=error` is a usage error.

- A PATH that cannot parse is a usage error, exit 1, on `get`, `count`, `instances` and `children`, `--default` or not. It read as not found, so `get --default` printed the default at exit 0.

- Write ops: `bool` takes only `true` and `false`, extra fields are an error, `comment` decodes escapes, and a CRLF script works.

- `get --array`, `get --slots` and `instances` print one line per value.

- The help flags work anywhere in option position.

- Usage errors end with `(see --help)`, and a misplaced or valued flag says what is wrong with it.

- Messages on stderr dropped the `shcl:` prefix.

- The help and the man page name the subcommands each option applies to.

- The zsh completion parses again, and bash completes `--option=value`.

- `version`, `about` and `donate` refuse words after them, exit 1. The flags still work anywhere.

- `set` skips a byte order mark at the start of its ops, which Windows PowerShell 5.1 adds to piped text.

- `set` says it is reading ops from stdin only when stdin is a terminal.

- `set --write` says when it had to save the canonical form instead of keeping the lines.

- `set` and `migrate` without `--write` exit 7 where `--write` would refuse, and take `--lossy`. `set` then prints nothing, and says when it printed the canonical form. It printed a result missing the dropped line at exit 0.

- The Go and Python CLIs report a file that will not open as the file name and the system's message.

### C and C++

- `shcl.h` compiles with `_GNU_SOURCE` defined.

- The validator no longer puts 16 KB of scratch on the stack.

- A remove, a merge, a refused setter and a default form no longer leave memory in the document.

- `shcl_generate` leaves nothing behind when it refuses.

- C drops an `H001` its schema disavows, like the other bindings.

- The veneer's `to_canonical`, `validate` and `read_file` no longer leak, and a default `Document` is usable.

- The README's C example builds as written.

### Go and Python

- Go's `LoadError` and `Diagnostics()`, and Python's `diagnostics()` and `LoadError`, hand back copies.

- Go's string setters refuse text that is not valid UTF-8.

- Go's save fails when closing the temp file fails.

- Python's `Read` is generic, so a type checker knows what a read returns.

- Python's `Diagnostic`, `Read` and `ShclDateTime` print their fields, and `ShclDateTime` compares by value.

- Python's `set_comment`, `set_raw` and `set_literal` check their argument types.

- The Python CLI writes UTF-8 and handles closed streams. `save_file` no longer leaks a temp file, a deep document no longer exhausts the stack, and `read_file(0)` no longer reads stdin.

### Windows

- A save keeps the hidden and system attributes, and can no longer leave nothing at the path. A publish blocked for a moment is retried. Its temp file takes the file's ACL.

- A save to a device name such as `CON` or `NUL` is refused.

- C saves follow symlinks and junctions, take backslash paths and paths past 260 characters, and use the wide file API. The C CLI reads a wide command line.

- A C read through a dangling symlink no longer creates a file.

- The CLI exits quietly when its reader closes early.

- The C and Python CLIs write LF line endings.

- The PowerShell wrapper works on Windows PowerShell 5.1 again, keeps non-ASCII text through a pipe, and passes pipeline input on when run as a script.

### Installers and packages

- The Linux one-liner is `bash <(curl ...)`.

- Both installers run the new binary before writing anything. The Linux one says when glibc is too old.

- Both name a rate limit, use `GITHUB_TOKEN`, check the target before downloading, and warn when another `shcl` comes first on PATH.

- Stable picks the highest version and skips drafts. A tag like `vnext` no longer wins.

- Uninstall removes only what was installed.

- A system install is usable by every user under any umask.

- The Windows installer no longer closes the shell that ran it, and works on Windows PowerShell 5.1. It checks the target and a running `shcl.exe` before downloading.

- The Windows setup handles a running `shcl.exe` and an older install, builds for a pre-release version, and reports a failed PATH update.

- Help prints as prose. A missing asset or a missing terminal is reported.

- The `.deb` and `.rpm` declare their glibc and libgcc needs.

- The packages and the drop-ins tarball are reproducible.

- `install-dev.bash` puts a fresh clone on `dev`.

- With wget, a download redirected to plain http is refused. `install-dev.bash` runs the rustup installer from a file.

- `install.ps1` piped into `iex` inside another script no longer ends that script on a failure.

- `install.bash --uninstall` says when there is nothing to remove.

- The drop-ins tarball's file modes no longer depend on the checkout's umask.

### Performance

- Formatting a large file takes about a tenth less time in every binding, and more in Rust and Go. C and Go use less memory doing it.

- Reads, writes and defaults in a flat document go through a name index. 40,000 flat keys read in under half a second.

- Removing many nodes and merging many overridden leaves are no longer quadratic.

- A file of colon-less lines parses in linear time.

- The first read after a merge scales with the document, not with its edit history.

- The did-you-mean suggester is linear in name length.

- C builds a schema in linear time.

## v2.0.0 - 2026-08-26

The first major since 1.0.0. Two things change incompatibly, both listed under Changed: escapes now resolve in field names, so `"a\"b"` and `'a"b'` are one field where they used to be two; and the C++ veneer's `read_datetime` returns the structured value every other binding's does, with the textual form moving to `read_datetime_str`. Canonical output also moves for several shapes - in each case one where the old output lost something or would not settle - so a file reformatted by 2.0 can differ from the same file reformatted by 1.2. Go consumers update the import path to `github.com/jim-collier/shcl/source/go/v2`, and anyone who installed the Go CLI switches to the Rust binary, which is the only one distributed now - see Removed. Rust and Python consumers change a version constraint and nothing else.

### Added

- A file tier in every binding and the C++ veneer: `LoadFile`/`SaveFile` beside the existing text entry points, with a load status (`Clean`, `HadErrors`, `NotFound`, `Unreadable`) telling a caller why a load came back thin. The atomic temp-file-and-rename write moved out of the CLIs and into the libraries, so a consumer no longer has to reimplement it to avoid truncating a config on a full disk. The C binding compiles the whole tier out under `SHCL_NO_FILE_IO` for freestanding builds. A save that **creates** a file gives it the mode an ordinary create would - `0666` narrowed by the umask, the same bits an editor or a shell redirect would have produced - while a save that rewrites an existing file keeps the permission bits it already had.

- `LostCount()`, and a save gate built on it: `SaveFile` refuses to write a document that lost content on load, rather than quietly persisting the loss. `SaveFileLossy` is the explicit override, and the refusal is a value the caller can act on - `SaveError::Refused` in Rust, a `*SaveRefused` error type in Go, `SaveRefused`/`SaveFailed` raised from a `SaveError` base in Python, `SHCL_SAVE_REFUSED`/`SHCL_SAVE_FAILED` in C. The gate answers before any I/O, so a lost document saved to an unwritable path still reports the refusal rather than the write failure.

- `AuthoredName(path)`: a name as it was written in the source, escapes and all. It is the one accessor that hands back source text - everywhere else a name is stored, compared, emitted and enumerated with its escapes resolved - which is exactly why round-tripping a document that cares about the original spelling needs it.

- A convenience tier named `_or` in every binding (`GetIntOr`, `get_int_or`, `shcl_get_int_or`, `get_or<T>`): the value on `Good`, the caller's fallback otherwise. Rust and Python gained eleven each, C three, so a routine ported between two bindings can no longer keep the call name while silently changing tier.

- `reopen: true` as a schema key, plus `SuppressDeclaredReopens`: a section a config is expected to re-open in several places declares it once, instead of every consumer learning to ignore `H002`.

- Rust gained `Clone`, `FromStr` (with `Infallible` as the error, since a Standard parse cannot fail), and `Display` on `Document` and `Status`, so `println!("{doc}")` prints the canonical form. `format_f64` is public, and is what the float setters use.

- The C++ veneer gained the rest of the surface it was missing: the file tier, per-slot array statuses, a datetime array read, `exists`, `quoted`, and status-to-text. Go gained a `String` on its load status and the five array status reductions; Go and C gained an `ok()` predicate, which the other two already had.

- `shcl --lossy` on `set --write`, the CLI half of the save gate, and `-v` beside `-V`. Read failures now explain themselves on stderr in every mode rather than only under `--on-bad=error`, with stdout byte-identical; `--on-bad=default` and an empty value outside error mode stay quiet on purpose.

- `shcl set --write` creates FILE when nothing is at the path yet, so a first write no longer has to be preceded by a `touch`. `fmt --write` has nothing to format and still reports the file missing, and a file that exists but cannot be read stays an error in both - the alternative is writing over something unread.

- A man page and shell completions. `man shcl` covers every subcommand, option, write op and exit code, with the per-subcommand option ownership the help only hints at, and the bash and zsh completions offer each subcommand exactly the options it accepts - an option a subcommand does not take is a usage error, so offering it would be a lie. The `.deb` and `.rpm` put all three where each shell already looks; the installer symlinks the man page into the target's own `man1` directory and leaves the completions with the line to enable them.

- The installer gained `--uninstall`/`-Uninstall`, a sudo pre-check, a working no-terminal guard, and a pastable `export PATH=` line when the install directory is not on the path.

- Windows executables have the program icon and the metadata the properties panel expects - product name, description, version, company and copyright - on both the x86_64 and ARM64 builds and on the setup. The version is read from the build, so it cannot drift from what `shcl version` reports.

- Release builds are reproducible. On the pinned toolchain, building a given commit produces a byte-identical binary on any machine and from any directory, for all four shipped targets, so the published checksum can be reproduced rather than trusted. README says so beside the checksum instructions.

- `-Help` on the Windows installer, listing the same options the Linux installer's `--help` does. The documented one-liner pipes the script straight into the shell, so there was no file left for `Get-Help` to describe.

### Changed

- **Field names resolve their escapes.** `"a\"b"` and `'a"b'` name one field, where each used to be a separate field keyed by its own spelling - which meant two spellings of one name were two names, while the same two spellings as *values* were one string. Names are compared, emitted and enumerated resolved; `AuthoredName` is how the source spelling is still reachable. A line break in a name is writable as a result, since names emit through an escaper that writes it as `\n`; in a `[value]` selector it is still refused, because that text is stored raw.

- **The C++ veneer's datetime reads swap names.** `read_datetime` returns `Read<Datetime>`, the structured value every other binding's `read_datetime` returns; the textual form it used to return is now `read_datetime_str`. The old pair had the names backwards relative to the rest of the project, and a veneer consumer calling `read_datetime` will get a compile error rather than a silent change of meaning.

- Author quoting on a plain string survives the formatter. `ver: "8"` still normalizes to `ver: 8` - a reader types that value the same either way, so the quotes say nothing - but a quoted plain string keeps its quotes through `fmt` and `init`, because stripping them un-escaped values a downstream language treats as special (`"@null"`, a quoted function reference), which is the case the `quoted` read flag exists for.

- A quoted by-value selector matches a scalar only. `x["a, b"]` selects a single-element value whose logical string is `a, b`, rather than matching against the whole display form; a bare selector is unchanged.

- Parsing costs far less memory in every binding, and less time. A 100 MiB document used to hold 39x to 72x its size in memory (3.8 GB in Rust up to 7.0 GB in C); it now holds 21x to 47x (2.1 GB in Rust, 3.0 in C, 3.3 in Go, 4.7 in Python), with C moving from the heaviest binding to among the lightest, and load time down as much as 40%. Output is byte-identical - this is the same parse, keeping less.

- A line that is malformed in content but positionally sound is retained as inert trivia and written back, instead of vanishing. Lines whose position cannot be recovered still drop and still count toward `LostCount`, which is what the save gate reads. A BOM-led line is deliberately excluded - re-emitting it produces content the parser reads back as live.

- `shcl set --write` consults the save gate. It previously deleted unreadable lines at exit 0 with nothing on stderr; the justification on record - that a person sees the diagnostics anyway - was false at the default strictness, where they see nothing at all.

- `shcl set -` follows stdin: the piped document when the edits come from options, an empty base when the ops script has stdin. The two meanings never compete, so nothing that worked before changed.

- The unknown-field sweep runs through a key-level schema fault instead of skipping wholesale, and skips only where the fault costs the entry its path (`V093`, `V095`).

- `H002` reports at every merged level, not just the first: a re-entered map passes the re-open line down to its children.

- A bare `shcl` prints the help and exits 0, the same as `shcl help` - one convention, "asking for help succeeds" - where it used to print the same text and exit 1.

- Every setter in the reference is `#[must_use]`, so a discarded write is a compile warning rather than a silent no-op. The other bindings have no equivalent annotation; the behavior is unchanged in all four.

- Performance, all measured: the quoted-emit gate costs 0.09s where it cost 0.24s on 400k bindings; the setters share one path scan and one tree walk (80k writes, 1.31s to 1.14s); the C binding parses the same corpus in 751 MB and 0.80s where it took 1332 MB and 1.19s, and retains one copy of its output during emit rather than four; Go went from 660 MB to 593 MB and 1.42s to 1.11s.

### Fixed

- Go, Python and C disagreed with the reference on a quoted selector whose lookup needed the rare fallback scan: they created a node where the reference selects one. The accelerator is meant to be a pure speed-up, so a miss must never change the answer - the three ports now rescan on an outright miss as well as on a wrong-shape hit.

- The C binding's number parsing and formatting followed the host program's locale. Under a comma-decimal locale the canonical output diverged from the other three bindings, every float read came back `BadType`, and the float formatter truncated `1.5` to `1`. Both sites now translate the decimal point themselves - pinning the locale would have been a process-wide side effect a library has no business causing, and is not thread-safe.

- A setter accepted a path segment or a by-value selector containing a line break, and wrote a document that reparsed to nothing. Both are refused now (a name escapes the break instead; see Changed).

- A value with leading or trailing whitespace outside space and tab was truncated on write. The edge-whitespace quoting rule now covers the whole set all four bindings already agreed on.

- `fmt` emptied a whitespace-only line inside a raw block, and then, once it stopped, grew a raw block whose body has *no* non-blank line by one indent level on every pass, without bound. The common indent is taken from non-blank lines, so such a body has none to strip - and the formatter now adds none back, leaving it byte-for-byte. Normalizing it away would also have ended the growth, but a raw block promising verbatim content is the wrong place to discard a line of non-breaking or ideographic space.

- Merged output was not always a formatter fixpoint: an empty binding in the base and a same-named block in the overlay both survived a merge, where parsing the two run together folds them. Merge adopts the parser's own empty-fill rule now, so the two agree. That also removes the emitter's workaround for the resulting pair, which wrote the fence on the name's line and lost an info string containing `#` outright.

- A raw block body line ending in more than one carriage return was not a fixpoint: the load stripped one, the write turned the survivor into a line ending, and the reload dropped it. The whole trailing run comes off at load now. A carriage return inside a line is content and still round-trips.

- Python's integer setters range-check against `i64`, so a value no other binding could store is refused rather than written and read back wrong.

- Python's merge and clone walks are explicit stacks. A document at the documented depth cap, merged from a caller 900 frames deep, used to exhaust the interpreter's stack past about 485 levels and leave the base document half-mutated.

- The C++ veneer's `Datetime` move operations left the moved-from value holding a view of digits it had handed away, so it formatted a fraction it no longer held. The invariant now lives in the rebind, which cannot be bypassed.

- On Windows an in-place write left the file's ACLs, attributes and alternate data streams behind. A rename publishes a new file, and everything the old one had outside its contents went with it; the write goes through `ReplaceFile` now, which copies them onto the replacement, and falls back to the old replacing move when the file is being created or the merge cannot be done. On POSIX the containing directory is synced after the rename as well as the file before it, so a power cut can no longer lose the publish itself and leave the old content. What a write still cannot keep - other hard links, POSIX ACLs, extended attributes and the SELinux label among them - is now stated in the spec rather than left to be discovered.

- The PowerShell wrapper needed PowerShell 7. It used one operator that older versions do not have, on the line that forwards the binary's exit code, so it failed outright on the Windows PowerShell 5.1 that ships with the OS. Written the long way now, and it runs on both.

### Removed

- The C++ veneer's `read_datetime_raw`. Its job is `read_datetime`'s now; see Changed.

- `go install github.com/jim-collier/shcl/source/go/cmd/shcl@latest`. The Go module is the library alone now - its CLI sits in a module of its own and no longer ships inside the published one. That CLI was only ever a test fixture for the cross-binding check, byte-identical to the reference by construction and with nothing of its own to offer; the Rust binary is the CLI this project distributes, and it is what the packages, the installers and `cargo install shcl` all deliver.

## v1.2.0 - 2026-08-04

### Added

- `shcl about` and `shcl donate` on the CLI, each also written `--about` and `--donate` the way `help` and `version` already are. `about` gives the version, copyright, project home, license and a short description of what SHCL is; `donate` points at the GitHub Sponsors page.

- `Lines(path)` (each binding's spelling, plus the C++ veneer): the plural of `Line(path)`. A repeated field - the case that most wants a citable line, and the one the singular returns 0 for - yields every binding's line in file order; unresolved wildcard slots stay as 0 so indices keep matching `Count`.

### Changed

- `help`, `about` and `donate` print with a blank line above and below, so the block stands clear of the shell prompts either side of it. Bare `shcl` still prints the same help text unpadded - it is a usage error rather than something asked for - and `version` stays a single bare line so it is still easy to capture.

- A schema fault no longer suppresses data validation wholesale. Faults (`V090`+) are still reported first and still fail `check --schema`, but the constraints that parsed cleanly now check the document too - a typo in one constraint cannot hide a real violation of another. The unknown-field sweep still requires a fault-free schema, since a dropped constraint would turn the fields it declared into false unknowns. `shcl init` is unchanged: generation still fails on any fault.

### Fixed

- The C CLI treated an informational flag in a `--set-literal` value as a request for that output, where the other three read it as the value. Its option-skip list was missing `--set-literal`, so `shcl get --set-literal -h FILE PATH` printed the help text instead of reading.

- A block header whose children were all commented out got those comments back one indent level shallow from the formatter (and a childless header's tail-of-file comments lost their indent entirely). A comment written deeper than a block's last binding now stays inside that binding's block at its own depth, in every binding; comment runs at the binding's own level trail it as before.

## v1.1.0 - 2026-08-04

### Added

- Name-position wildcard `*` in lookup paths: `Get("indicators.*.period")` slots across children of any name the way `[*]` slots across instances (per-slot statuses, `Count`/`Instances` aligned), and a schema path can declare an open section - "any child name here, each shaped like this" - without enumerating names. The setters refuse a wildcard path, while `Remove` on one removes every matching slot; a field literally named `*` stays addressable quoted (`"*"`).

- Schema fragments: `fragment: <name>` declares a reusable shape (ordinary `field:` entries with relative paths), `inherits: <name>` mounts it at a field's path. Recursive and mutually-referencing shapes are legal with no depth limit - validation follows a mount only where the document has nodes - so arbitrarily-nesting structures (layout trees and the like) validate at any depth, and one shape can be mounted at several paths instead of duplicating its fields. `shcl init` expands mounts into the starter config, cutting where a fragment would re-enter itself. New schema-fault codes `V094` (bad fragment declaration) and `V095` (`inherits` names no declared fragment).

- `QuoteSegment` in every binding and the C++ veneer: quotes one path segment so a user-typed name can be spliced into a lookup path safely - without it, a dotted name silently reads as nesting.

- `Children(path)`: child field names in file order, duplicates included, so an open (map-shaped) section can finally be read without prefix-scanning `Paths()`. The empty path enumerates the top level.

- `Line(path)`, plus `line` and `quoted` on the read result (Rust/Go/Python; C keeps its value+status structs and gains the `shcl_line`/`shcl_children` accessors): consumer-side checks can cite the source line, and a quoted value is distinguishable from a bare one - `a: @null` vs `a: "@null"`.

- `LoadAndValidate(text, schema, strictness)`: parse and validate in one call, returning the document with one combined diagnostics list - no more hand-merging two lists and losing half the errors - plus `ErrorCount()` as the "did this file have errors?" predicate.

- A new `H002` hint when a binding merges with a non-adjacent earlier one (two separately-written `table: t` sections silently becoming one combined table is now visible; the prose names the earlier line). Adjacent re-mentions and selector/path-intermediate merges - the deliberate redundant-path idiom - stay silent.

- `check --schema` now drops `H001` (repeated bare leaf) for fields whose schema declares a repeat upper bound above 1: there, repetition is the instance mechanism by declaration, and the hint was training users to ignore hints.

- `SuppressDeclaredRepeats(schema, diags)` in every binding: drops the repeated-field hint for any field whose schema allows more than one instance - the same filter `check --schema` applies, callable wherever document diagnostics and a schema meet.

- `WriteReason(path)`: the reason a write at a path would fail - `BadPath`, `ValueInPath`, `Wildcard`, `NoSuchIndex`, or `TooDeep` - behind the setters' bare pass/fail. A probe only; it never creates.

- `V096`: generating a starter config from a schema whose fragments mount each other along several paths now reports a schema fault instead of expanding until it runs out of memory.

- `shcl set --write FILE --set PATH=VALUE` writes edits given as options straight back to the file. Previously the only way to persist an edit was a tab-separated op script piped in on stdin, which is awkward to write by hand in any shell and impossible to read once tabs are invisible; edits now need neither a pipe nor a tab. The options are repeatable and apply in the order given.

- `--set-literal=PATH=TEXT` beside it, for the values `--set` cannot write. A `--set` value is data, so `ports=80, 443` stores one quoted string; the same text through `--set-literal` stores a two-element array, because it goes in as value syntax the way a file writes it. Both share one ordered list, so the last option to touch a path wins. Raw blocks, set-only-if-absent and removal still go in as an op script.

- `SetLiteral` and `SetLiteralDefault` in every binding (`set_literal` / `shcl_set_literal`), the library half of the above: they read their argument the way the parser reads the value half of a line, so a consumer holding value text can write it without first working out its shape. Text with a line break, or a quote that never closes, is rejected rather than written; an unquoted `#` ends the value as it would in a file. The op script gained a matching `literal` op.

- Generated starter configs (`shcl init --schema`) end with a short footer naming the format and linking its home page and spec, so whoever opens the file next can find out what it is and how to edit it. `--no-banner` leaves it out, and `generate` takes the same flag in every binding.

### Changed

- `generate` gained a `no_banner` argument in every binding (Python and the C++ veneer default it; Rust, Go and C callers must pass it). The flag is negative on purpose: passing false, zero, or nothing writes the footer, so the opt-out is the thing a caller has to ask for.

- The Go module's `go` directive dropped from 1.24 to 1.20, the tested floor (`strings.CutSuffix` is the newest stdlib dependency) - so pinned-toolchain projects can use the module instead of vendoring the file.

- `shcl set` no longer reads a write-ops script from stdin when any `--set` is given. This only affects a command line that passed both, which previously applied the `--set` values and then the piped ops; pass the whole edit one way or the other. The wording of the two `--write` refusals also split, naming just the option that clashed rather than "--layer or --set".

- Writer-created top-level nodes now have the blank-line grouping a hand-written file would have: one blank line between top-level sections. Written and generated output changes shape accordingly.

- Parsing is faster: the reference no longer copies every line and its indent, and three bindings scan paths without building a character list per line. Formatting a large file is roughly 10 percent quicker in the reference, Go and C, and about 12 percent in Python.

### Fixed

- The canonical formatter no longer loses hand-authored comment layout two ways: a blank line between comment-only regions survives the round-trip, and a comment written deeper than the next binding stays with the block it sits in (re-emitted after that block's last child, at the block's indent) instead of re-attaching dedented to the next field.

- A failed strict load is no longer a dead end: the failure includes the parsed document (Go's `ParseWith` also returns it non-nil alongside the error), and the message names the first few diagnostics instead of a bare count.

- `Paths()` no longer hides a node whose name needs quoting, nor its subtree. Non-bare segments come back quoted and escaped, so every returned path is a valid lookup path and the enumeration matches the document.

- A read's raw text is now the value span exactly as authored on its source line, as documented - not the canonical display form, which silently rewrote `^\d{2,3}$` to `^\d{2, 3}$`. Values with no one-line source spelling (writer-built, stacked lists, raw blocks) keep the display-form fallback.

- By-value selectors now apply escape sequences to both sides before comparing, so `["q\"uote"]` finds an instance written `'q"uote'`. Previously the comparison was spelling against spelling and the mismatch was a silent `NotFound`; the writer's placement walk had the same blind spot and could create a spurious second instance.

- Formatting a file could change what it meant. A value that only became final after its siblings were keyed - a stacked list closing onto an earlier instance's value, or a fenced block filling an empty field that matched an earlier one - was left beside its match instead of merging, so the file formatted to two entries, reformatted to one, and a read that correctly reported several instances started returning a value.

- Rewriting a file in place created its temporary under a predictable name without demanding exclusive creation, so anything already sitting there - including a symlink someone else had planted - was written through, and the rename then turned the config itself into a link. The temporary is now created exclusively and given the target's permissions before any data goes into it, so a private config is never briefly readable to anyone else either.

- Validating against a recursive schema could stop finishing, because a shape reached from two paths was re-checked per path per level. Each shape is now checked once per node. The C binding also held every level's working data until the end; that is released as it goes now.

- Python raised on numerals beyond a few thousand digits where the other bindings report a bad type. Length is checked before conversion now.

- The C date formatter could write past the buffer size it documents when handed a value the caller built rather than one that came from parsing.

- The C++ wrapper's structured date read handed back a pointer into the document's storage, so the value dangled once the document was gone. It owns its fractional digits now, which changes what `read_datetime_raw` returns.

- Comments were dropped when documents merged: a section present in both layers lost the higher layer's comments, and a write that merged duplicate fields lost any comment hanging below the losing one. A footer several layers share is now kept once rather than repeated per layer.

- The one-shot load-and-validate ignored a schema that failed to load, so constraints on its broken lines silently vanished. It reports the schema failure now, like `check --schema` does.

- A value or a path that read like `-h` or `--version` printed help or the version and exited successfully. Only a flag in option position counts now, and `--` ends the options so a path may begin with a dash.

- Rewriting a file in place while merging layers folded those layers permanently into it. The combination is refused.

- Generated starter configs did not always load: a wildcard written with spaces or with the alternate colon spelling produced a line the parser rejects, and a deep chain of fragments produced paths past the nesting limit.

- Three C entry points left working data in documents they do not own, growing a long-running program that holds one parsed schema.

- The Go repeat-hint filter rewrote the caller's list while returning a new one.

- Quoting a name that ends in a backslash produced a path that could not be read back.

- Repeat-hint suppression could silence an unrelated field when a schema path ended in a quoted name containing a dot.

- A field name containing a null byte could satisfy a two-segment schema path, slipping past the unknown-field check.

- A system install linked the program into a directory that is not on a normal user's path.

## v1.0.0 - 2026-07-28

First stable release. The language, the read and write APIs, and the diagnostic codes are now covered by semantic versioning: a breaking change to any of them means 2.0.0.

### Added

- Published packages. Rust on crates.io (`cargo add shcl`), Python on PyPI (`pip install shcl`), and the Go module by tag (`github.com/jim-collier/shcl/source/go`). Binding versions move in lockstep with the product version, so each ecosystem's ordinary compatible-version operator tracks minor and patch releases without crossing a major.

- Signed releases. The `sha256sums` file now comes with a detached signature made offline with the project signing key, and both install scripts verify it before trusting any checksum out of that file. The public key is at `shcl-signing.pub` for manual verification.

### Changed

- The Windows `user` install moved from `%USERPROFILE%\bin\Shcl` to `%LOCALAPPDATA%\Programs\Shcl`, and adds that directory to `PATH` directly instead of keeping a second copy of the executable one level up.

- `install.bash` now requires `openssl` alongside `curl` or `wget`. There is no unverified-install fallback.

- The trademark policy is now built around conformance: an implementation that passes the published corpus may use the name, without asking and without affiliation.

## v1.0.0-rc1 - 2026-07-26

### Added

- Schema validation: a schema is itself a plain SHCL file. `validate(doc, schema)` in every binding, and `shcl check --schema=FILE` with stable `V###` codes.

- Layered loading: `merge(base, over)` in every binding, plus repeatable `--layer=FILE` and `--set=PATH=VALUE` overrides on the loading subcommands.

- Schema-driven generation: `generate(schema)` and `shcl init --schema=FILE` emit a commented, typed starter config that validates clean against its own schema.

- Installer packages: a `.deb` and `.rpm` per Linux binary and a Windows setup, all covered by the release checksums.

- `paths()` in every binding and the C++ veneer, to enumerate a document's field paths in file order.

- `set --write` rewrites the base file in place, matching `fmt --write`.

- Two new diagnostics: `E016` for a document nested past the 512-level cap, and `E017` for a value that opens a quote it never closes.

### Changed

- Blank lines between bindings now survive the canonical formatter instead of being discarded. Runs of them collapse to one.

- Every subcommand rejects options it does not use instead of silently ignoring them.

- `init` exits 6 on a broken schema, matching `check --schema`, and lists the schema faults.

- Large-document performance: merging, inline `[value]` selectors, stacked lists, raw-block formatting, and schema suggestions all dropped from quadratic to linear. A 32k-key merge went from 16 seconds to 0.07 in the reference, with byte-identical output.

- C memory use is flat for read-heavy and merge-heavy workloads, where it previously grew without bound.

- The Windows installers edit `PATH` in the registry segment-wise and preserve its type. Installer downloads require https with a TLS 1.2 floor.

- The library degrades gracefully on a slipped internal invariant rather than aborting.

- The spec states that lowercase is a field name's canonical spelling.

### Fixed

- A bare section header in a higher layer merged over a base document deleted the whole subtree below it. It now merges. Clearing a leaf from a layer still works.

- A write to an unusable path (a wildcard, or a missing `[#N]`) reported success and could leave a half-created path behind. Setters now report whether the write applied, and nothing is created unless the whole path is usable.

- `fmt --write` could leave a truncated file if interrupted, and C reported success on a failed write. Both writers are now atomic.

- An in-place write no longer discards what it replaces. The target's permission bits are preserved, and a symlinked config is written through instead of being replaced by a regular file. Any other hard link to the file still keeps the old content, which a rename cannot avoid.

- The Writer could create two siblings that a reparse would merge, so its output was not a formatter fixpoint.

- `shcl set` op values were validated four different ways across the bindings. All four now use the reference's grammar.

- `shcl init --schema` could generate a file that its own schema rejected, and could emit lines that do not parse.

- Go `Validate` aborted the process on a schema path with a `[#N]` selector at or above 2^63.

- Deeply nested documents crashed three of the four bindings, each at a different depth. The nesting cap catches them at load.

- The C CLI silently capped `--layer` and `--set` at 64 each.

- `shcl.h` did not compile as a drop-in C++ translation unit under `-Wall -Wextra -Werror`.

- README and spec examples that named APIs which do not exist.

## v1.0.0-beta2 - 2026-07-21

### Added

- Writer API in every binding (typed `set_*`, array and `_default` forms, `set_raw`, `remove`, comments, empty-doc constructor) plus a `shcl set` CLI subcommand driven by a tab-delimited ops script.

- Comments are preserved through the canonical formatter as node trivia rather than being discarded.

- Stable diagnostic codes (`E###`/`H###`) on `check`, printed as `line N: severity: CODE` on stdout with the prose on stderr.

- Convenience read tier with whole-value fallbacks (`get_*_or` / `default=`) across the bindings.

- `--rawinfo` accessor for a raw block's info string.

- Per-slot statuses on wildcard array reads, plus `--slots` and per-slot `--default` on the CLI.

### Changed

- `check` exits nonzero whenever any error diagnostic is present, not only on strict-load failure.

- Value options accept both `--opt=VALUE` and the space-separated `--opt VALUE` spelling; `help` and `version` are also accepted as subcommands.

- Uniform behavior across bindings for broken-pipe exit, invalid argument encoding, and out-of-memory.

- Dogfood install is now atomic (stage to a temp file in the destination, then rename over the target).

### Fixed

- Hex integer bounds now read `i64::MIN` correctly and reject out-of-range magnitudes.

- Merge keys made injective so distinct arrays and raw blocks can no longer collide.

- Large-document formatting no longer risks a stack overflow (iterative emit).

## v1.0.0-beta1 - 2026-07-15

First tagged pre-release.

### Added

- Language spec and formal grammar (`project/spec.md`, `project/grammar.abnf`).

- Conformance corpus of golden cases that every binding must pass.

- Rust reference parser and the `shcl` CLI (`get`, `fmt`, `check`, `count`, `instances`).

- Independent parsers for Go, C (with a C++ veneer), and Python, each corpus-green.

- Bash wrapper around the CLI, usable as a script or sourced for typed helpers.

- Three strictness levels (loose, standard, strict) as a per-document knob.

- Raw fenced blocks for verbatim multi-line content.
