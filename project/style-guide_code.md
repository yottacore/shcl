<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD033 -- inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
# Style guide

This is the canonical coding and prose style for this repo. `contributing.md` covers process, and this file covers how the code and docs are written, and why. Where this guide and a general-purpose "best practice" disagree, this guide wins on purpose. The deviations are listed per language, and each one has its reason.

## Parity over idiom

This rule overrides everything else in this file. It's why parts of this codebase ignore what a style checker for each language would suggest.

The bindings are one program written several times. Rust is the reference, and Go, Python, and C are independent ports of it. They all have to produce identical output byte for byte, with the same stdout, exit codes, and diagnostic codes. The conformance corpus and the differential check across bindings enforce that on every build.

To keep that cheap to maintain, every port mirrors the reference's structure as well as its behavior:

- The function inventory and call flow are the same. The reference's `read_string` is Go's `ReadString`, Python's `read_string`, and C's `shcl_read_string`. Each concept has one name, written in each language's case convention.

- The parse pipeline, the order of operations, and the helper boundaries are the same. A line of the reference has a recognizable sibling line in every port.

- User-visible strings are the same where output is the contract. Those are the diagnostic codes, the `check` summaries, and the CLI usage errors.

When a bug is fixed or a feature is added to the reference, porting it is a mechanical diff of the same function in each sibling rather than working it out again. Behavior differences hide where the structure differs. Any 2 "equivalent" idiomatic implementations of the same rule will disagree on an edge case sooner or later, and in this project that's a defect by definition.

The cost is that some code reads as a little foreign to a native of its language, and that's accepted. A Go reader will notice that reads return a status struct instead of an `error`. A Python reader will notice explicit character-class loops where `str.strip()` would be shorter. Each one is there because the shorter idiom behaves differently from the reference in some corner case, and the specific cases are listed below.

Parity governs structure and behavior. Idiom still governs the surface, so each language keeps its own formatter, naming case, error-propagation syntax, and doc-comment conventions. The goal is "obviously the same program, written by someone fluent in each language", rather than transliterated Rust.

v4 will narrow the rule to the core, which means the tokenizer, parser, stored lines, edits, and emitter. Each binding's public API in v4 will be native to its language, as [the v4 design](design_docs/20261015-072055_v4.md#native-api-over-a-mirrored-core) says.

New bindings, which are Tier 3, follow the same recipe. Port the reference function for function, run the corpus, and don't release until the crosscheck is green.

## Rules for every language

- Formatters win. Where there's a canonical formatter, such as rustfmt or gofmt, its output is final. Run it, and don't hand-format against it. Intentional data tables get the formatter's skip pragma rather than a fight.

- Use tabs for indentation and spaces for alignment. The test is whether the language prevents it or strongly pushes the other way. None of the 6 languages here do, so all 6 use tabs. This repo pins rustfmt to `hard_tabs`, gofmt uses tabs natively, and Python, C, and both shells follow suit. PEP 8 does prefer spaces, but it also says to stay consistent with code that's already indented with tabs. One indentation style across a repo with several languages is worth more than purity in each one. The Python linter's `W191` tab rule is switched off for this reason rather than by oversight.

- Names are meaningful and searchable, such as `upperBound` rather than `ub`. Short conventional names are fine where they're idiomatic. Examples are loop indices such as `i`, a local `err`, a receiver letter in Go, and locals of a few lines in the compact parser cores where the same short name means the same thing at the same site in every binding, such as `t` for a line that was just trimmed and `q` for the current quote char. The test is "can a reader find and search-replace what you mean", rather than maximal length.

- Comments are terse and explain why rather than what. They don't narrate the next line, and they're ASCII only, with `->` instead of arrows, though `©` is fine. If a line needs a what-comment, rewrite the line.

- **Section rules are the one sanctioned banner.** In a single-file drop-in binding of a few thousand lines, they're the only aid for finding your way around. So each binding uses exactly one form for its major-section dividers and nothing else. Rust and Go use a full-width `// ----...` line with the section title on the next comment line. Python uses the same form of 3 lines, written `# ----...` / `# <title>` / `# ----...`. C uses `// --- <title> ---...` padded to the margin, and `// ====...` is reserved for the split between header and implementation. Shell keeps the house `#•••` rule. PowerShell writes it `#===`, because every `.ps1` stays ASCII without a byte-order mark. `irm | iex` keeps a mark on `install.ps1` and the parse then fails, and Windows PowerShell 5.1 reads a file without a mark in the ANSI code page. There aren't any other decorative comment forms.

- Every source file starts with the SPDX line and copyright, then a short purpose block. Library files also say how they're used as a drop-in and state the parity contract.

- The tokenizer is the one place the lexical rules live. Everything that reads a line's parts goes through it and reads spans. That includes the parser's dispatch, the path scanner, the comment and comma splits, the element cap, the quote check, `SetLiteral`, and the CLI's `--set` split. There isn't a second quote state machine in any binding. A rule that has to be read somewhere new is read through the tokenizer, or the tokenizer grows.

- A setter writes only what reads back. It builds its text through the emitter, hands that to the tokenizer, and refuses unless what comes back is the value it was given, so a write that would come back different never changes the document. Setters don't have their own trim, carriage-return, `#`, or quote rule in any binding, and a new setter doesn't add one either. The typed setters still render the value and parse it back on top of that, since a float or a datetime has to read back as that type rather than only as the same text.

- **A public call has one name across the 4 bindings, cased the way its language cases names.** `format_float` is `format_float`, `FormatFloat`, `format_float`, and `shcl_format_float`. It was `format_f64` in Rust and C until 2026-09-20, which named a Rust type in an API contract that doesn't have one. The datetime zone type is `Zone` everywhere for the same reason. A later pass judges a name against this rule, so the differences aren't argued again. The exceptions below are the whole list, and a new one needs a line here.
	- Go spells the datetime type `DateTime` and the call `ParseDateTime`, where the other 3 spell it `datetime` as one word. Go names a constructor after its type, and the type is a deliberate deviation of its own, listed below.
	- Go has a `ZoneKind` enum and a `Zone` struct where Rust has one enum with a payload, and C has a `shcl_zone_kind` enum beside an `off_min` field. Neither language has an enum with a payload, so the type differs but the name doesn't.
	- Go calls the result of `Upgrade` and `UpgradeFile` an `Upgraded`, where Rust has an `Upgrade` struct beside its `upgrade` call. Go gives a type and a function one namespace, and the call keeps the name. Its `UpgradeError` is a struct with an `UpgradeErrorKind`, for the same reason as `Zone`.
	- C calls that result an `shcl_upgraded` too, beside its `shcl_upgrade` call, for the same reason as `read_bool` below, and frees it with `shcl_upgraded_free`. Its `shcl_upgrade_error` is an enum with an OK value, and the message comes back through an out parameter, since a C enum has no payload.
	- Python's zone is a `("utc", None) | ("offset", minutes)` tuple without a named type. A tagged value with 2 cases is a tuple in Python, and a class for it would make the port read as something the other 3 aren't.
	- C writes `read_bool` as `shcl_read_bool_`. C gives a function and a typedef one namespace, and the result type already has the plain name. Renaming either side would break callers without any gain in behavior.
	- Go writes the `SetStatus` values with a `Set` prefix, from `SetOk` to `SetRawBlock`, where the others have `Ok` to `RawBlock`. Every Go enum value is in the package's one namespace, where `BadPath` and `Multiple` are already read statuses, and a bare `Ok` would be next to `Read.Ok()`. `String()` gives the names without the prefix, as the others print them. C's are `SHCL_SET_OK` to `SHCL_SET_RAW_BLOCK`, of type `shcl_set_status`, and `shcl_set_status_name` gives the names, as `shcl_status_name` does for a read.
	- `WriteStatus` goes the same way: Go's `WriteOk` to `WriteOther`, since `NotFound` is a read status, and C's `SHCL_WRITE_OK` to `SHCL_WRITE_OTHER`, of type `shcl_write_status`, with `shcl_write_status_name`.
	- `SchemaStatus` too: Go's `SchemaGood` to `SchemaUnreadable`, since `Good`, `NotFound` and `Empty` are read statuses, and C's `SHCL_SCHEMA_GOOD` to `SHCL_SCHEMA_UNREADABLE`, of type `shcl_schema_status`, with `shcl_schema_status_name`. Go spells the URL value `SchemaURL`, the way it spells `UpgradeIO`, and `String()` gives `Url`.
	- `ValueKind` too: Go's `KindEmpty` to `KindRaw`, since `Empty` is a read status, and C's `SHCL_KIND_EMPTY` to `SHCL_KIND_RAW`, of type `shcl_value_kind`, with `shcl_value_kind_name`. C's read result is `shcl_read_value_kind`, named for the type inside it the way `shcl_read_i64` is. The reason is because `shcl_read_kind` is the call.
	- Python's `Quote.None_` has the trailing underscore PEP 8 gives a name that is a keyword. The other members are the reference's, and check-docs checks every Python enum against the reference's members and order.
	- C's `shcl_quote_segment` takes a document, where the others take only the name. The quoted text is stored in the document's read arena like every string C hands out, for the reason `shcl_tokenize` takes one, given below. A path builder that doesn't have a document yet passes one from `shcl_new`, which is what C++'s `quote_segment` does for its caller.
	- C's `shcl_format_diagnostic` takes the line, severity, code, and message, where the others take a diagnostic. C doesn't have a diagnostic struct, only the `shcl_diag_*` and `shcl_validation_*` accessors, and taking the parts means one call can format both. The text is malloc'd and comes back with its length, as `shcl_read_file`'s does, since a validation result doesn't have a read arena to put it in.
	- The table from a read status to the CLI's exit code is private to the Rust and Go CLIs. C has it in the header as `shcl_status_code`, C++ wraps that as `status_code`, and Python's `Status` values are the codes, which its runner pins. All 3 came with the first ports, and dropping them would break callers without any gain in behavior, as with `read_bool` above. The codes are the same in all 5.
	- C++ has `read_datetime_str` and `read_datetime_array_str`, and no other binding does. They return the text form, which `read_datetime` returned before it changed to the structured value in 2.0, so a caller of the old call had something to move to. `DateTime::str()` gives the same text.
	- C++ doesn't have `get_duration`, `get_size`, `get_raw`, or `get_raw_info`. Since it doesn't have exceptions or a `Result`, its status tier `get<T>` returns the same `Read<T>` the `read_*` calls do, so `read_duration`, `read_size`, `read_raw`, and `read_raw_info` are those 4. The first 2 take more than a path, and a raw block is a `std::string` to a template, as with `get_raw_or` under C and C++.
	- A duration read gives the language's own duration type, which is `std::time::Duration`, Go's `time.Duration`, Python's `timedelta`, or C++'s `std::chrono::milliseconds`. C doesn't have one and gives `int64_t` milliseconds. Each one has the spec's whole milliseconds. The "no unit" argument is each language's empty option, `None` in Rust and Python and `std::nullopt` in C++. Go and C don't have an optional type, so their unit enums open with a none value, which is `DurationNone` and `SizeNone` in Go and `SHCL_DURATION_NONE` and `SHCL_SIZE_NONE` in C.
	- The datetime has a different layout in each language, and only `date`, `time`, `frac`, and `zone` are names that all 5 share. Rust and Python store the date and time as tuples, `(year, month, day)` and `(hour, minute, second)`, with the second absent when it wasn't written. C++ has `Date` and `Time` structs with those field names. Go and C don't have tuples or optionals, so theirs are flat, with a flag beside each part that can be missing. Those are Go's `HasDate`, `HasTime`, and `HasSeconds`, and C's `has_date`, `has_time`, `has_second`, and `has_frac`. Their fields have the names C++ gives them.

- Each binding is a single file with zero dependencies. That's the product, as in "copy this file into your tree", so there aren't any module splits, helper crates or packages, or dependencies, however good.

- Small standalone utility scripts are MIT regardless of anything else, and have their license in the header.

- Some analysis runs, and some is declined on purpose. The gating tools are rustfmt and clippy, gofmt, go vet, staticcheck, govulncheck, cargo-deny, ruff, mypy, cppcheck, PSScriptAnalyzer, shellcheck, and markdownlint. These are declined, each for a reason that isn't going to change:
	- `clang-format` and `clang-tidy` would reformat the C drop-in, which rewrites about 9 lines in 10 and loses the hand-aligned tables and the structural match with the other bindings.
	- `golangci-lint` wraps checks that already gate one by one, so it would add a dependency without any new signal.
	- `shfmt` output conflicts with the shell style the pipeline scripts are written in.
	- Satisfying pedantic clippy would mean moving away from the reference's structure, which parity forbids.

## Per-language

### Rust (reference)

- rustfmt is canonical, with the repo's `rustfmt.toml` (`hard_tabs = true`). Clippy gates at its default level, and pedantic is advisory.

- A real error is a value, returned through `Result` and `?`. Most "failure" here isn't an error, though. A missing or mistyped value is a normal, expected outcome, so reads return a `Read<T>` with a `Status`, as the spec requires, rather than anything like an exception. There isn't any `panic!`, `unwrap`, or `expect` outside tests, and released code doesn't have any. The only ones left are behind the `profiling` feature, which never compiles into a normal build.

- The code doesn't use `thiserror`, `anyhow`, or the ergonomics of other error crates. The zero-dependency rule outranks them, and `Status` plus structured diagnostics are already enough here.

- Derive traits such as `Debug`, `Clone`, and `PartialEq` rather than writing them by hand. Public items get `///` docs. Use early returns and `let .. else` rather than nesting.

- `Cow<str>` is used where a per-line helper usually doesn't have anything to do. That's `fold_name` when a name doesn't have any upper case to fold, and the path scanner's fast path for a plain name when there's nothing to resolve. The other 3 allocate freely there or leave the work to a garbage collector, so there's nothing to mirror. The parser calls these once per segment per line, and a profile showed the cost there of building and freeing 2 strings only to copy bytes onto themselves.

- `SetStatus` is `#[must_use]`, so every setter's result is too. That only affects the surface, so parity isn't touched. The other 3 don't have an equivalent and say the same thing in prose. If a refusal is dropped, the save that follows writes a config missing the edit and reports success. That's the one failure here that doesn't leave any trace, and the compiler catches it for free in the one language where it can.

### Go

- gofmt and `go vet` gate. The code uses the standard library only.

- Reads return a generic `Read[T]` with a `Status` field rather than `(T, error)`. Deliberate deviation: the reference models read failure as data, and an `error` return would push every port toward different control flow. Real errors, such as I/O or bad UTF-8, still use `error` normally.

- There aren't any interfaces, since everything has one implementation and there isn't a test seam that needs one. There aren't any goroutines either, because parsing is single-pass and single-threaded by design.

- Exported identifiers get doc comments that start with the name. Names are short in small scopes and descriptive in the public API.

- Deliberate deviation: the datetime type is `DateTime` rather than `ShclDateTime`, since the package name already has the prefix. The reference and Python export `DateTime` as an alias so both names work.

- Enum values share the package's one namespace, so when 2 enums would use the same name, one side gets a prefix. `FileNotFound` has one beside the read status `NotFound`. Every `SetStatus` value from `SetOk` to `SetRawBlock` has one, since `BadPath` and `Multiple` are read statuses. So does every `WriteStatus` value from `WriteOk` to `WriteOther`, since `NotFound` is a read status too, and every `SchemaStatus` value from `SchemaGood` to `SchemaUnreadable`. `ValueKind`'s values have `Kind`, from `KindEmpty` to `KindRaw`, since `Empty` is a read status. Each one prints the reference's name.

- When the tokenizer's `Sep`, `Comment`, or `Fault` offset is absent, it's `-1` where the reference has `None`. The spans themselves are the same byte offsets in every binding.

### Python

- The code targets Python 3.9+ and uses only the stdlib. ruff and mypy in default mode gate. black doesn't run, because the repo's tab indentation stands, as the repo-wide rule above says.

- Reads return a status rather than raising, as the reference does. Exceptions are for real faults rather than for "value not found".

- Several stdlib shortcuts are banned because they don't match the reference's semantics. `str.strip()` is out because Python's whitespace set differs from Rust's. `str.lower()` folds by locale and Unicode, but the spec folds ASCII only. Bare `round()` uses banker's rounding, but the spec rounds half away from zero. An unbounded `int` has to be range-checked against i64. Each ban has a comment at the site where it matters.

- Control flow mirrors the reference because of the parity rule, so it leans more toward LBYL than idiomatic EAFP.

- Deliberate deviation: the parser's child and display accelerator maps key on exact tuples of the strings it already has, where the other 3 bindings stream an FNV hash and check hits against the arena. CPython's dict and tuple code runs at C speed but a hand-written hash loop over each byte doesn't, and the tuple keys are exactly as injective. The first-wins semantics and the behavior are the same.

- Deliberate deviation: Python has 3 shortcuts on hot paths that the other bindings don't need. There's a branch for length one in the value display and the merge key, an identity test before the source-attach guard's key compare, and the path scanner's 2 helpers at module level rather than nested. Rust and Go stream these fields through a hash and don't build anything, and a closure per call doesn't cost anything there. The shortcuts don't change any output, and the Python runner asserts them by structure rather than by a clock.

- Deliberate deviation: the emit, overlay and clone walks are iterative where the reference recurses. CPython's own recursion limit is far below the spec's depth cap of 512 levels, so a document the reference formats without complaint raised RecursionError here. Raising the interpreter's limit would have moved the failure to a stack overflow without a traceback. The walks have their own explicit stacks and visit nodes in the same order, so the output doesn't change.

- The public API is type-hinted, including every public method, function, and attribute. Private helpers are hinted where it helps, and mypy strict isn't a gate.

- Deliberate deviation: the write side's read-back check lets through text that can't be encoded as UTF-8. Python's string is the only one of the 4 that can contain a lone surrogate, and the tokenizer scans bytes, so there's nothing to give it. The save is where a document that can't be encoded fails, and it always was.
	- Superseded 2026-10-08 by 2026100815543610: the setters refuse such text, as Go's and C's do, and since 2026100907362300 the status says `NotUtf8`. A parse still keeps a lone surrogate, and the save is still where that fails.

- Deliberate deviation: `SetStatus` is an `Enum` whose only true value is `Ok`, through a `__bool__`. The other 3 don't give it a truth value and compare with `Ok`. Setters returned a bool before, so a caller's `if not doc.set_int(...)` still means refused. An `IntEnum` was the other choice, and there `Ok` is 0 and false, which would reverse every such check without any error. The values are still numbered from 0 in the reference's order, as `.value`. `WriteStatus` works the same way, so the two read alike.

- Deliberate deviation: Python raises an exception where the reference returns an error enum. There's one class per variant under a base named for the enum, so a caller can tell them apart with `except`. `SaveRefused`, `SaveChanged`, `SaveExists`, `SaveTooNew`, and `SaveFailed` are under `SaveError`, and `UpgradeNotFound`, `UpgradeAmbiguous`, `UpgradeBackupTaken`, `UpgradeFailed`, and `UpgradeErrorsLeft` are under `UpgradeError`. The reference's `Io` variant is the `Failed` one. A `get_*` call without a default raises `StatusError` where the reference returns `Err(Status)`.

- Every name at module level that isn't in `__all__` starts with `_`, so the sentinels and the type variable don't read as API.

- Deliberate deviation: the tokenizer scans the UTF-8 bytes of the line rather than the str, and `Tokens.src` stores those bytes so the read-back helpers can slice them. Every offset the 4 bindings hand out is a byte offset, and the `tokens` output is compared byte for byte, so the str's code-point offsets wouldn't work. There are 2 exact shortcuts on hot paths that depend on the bytes. A value without a quote or a `#` is cut with `bytes.find` one piece at a time, so the element cap still stops the scan where the byte loop would. A bare name is matched with a compiled ASCII class.

### C and C++

- The C binding is C11 in a single header, STB-style, with `#define SHCL_IMPLEMENTATION` in one translation unit. The gate is `-Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror` plus cppcheck.

- Each document has one bump arena, `shcl_free` frees everything, and there isn't any ownership per object. Raw pointers are fine here, since this is C working as designed rather than a gap where RAII should be. The one exception is the node vector, which is in malloc and realloc storage. A bump arena can't reclaim the abandoned half of each doubling, and the node array is the biggest thing that doubles.

- Strings are length-delimited byte spans with explicit helpers for UTF-8 iteration, because the reference iterates `char`s, and byte-wise shortcuts get multibyte input wrong.

- The C++ interface in `shcl.hpp` is a binding of its own over the C core, rather than a second parser. Its calls and types mirror the Rust reference in std types, and a caller doesn't see any of C. The header's public half doesn't name anything from C, and the calls into C are in the `SHCL_IMPLEMENTATION` section, which one file compiles. It's C++17 without exceptions, and the gate pins C++17 so it builds on many compilers. It makes every public C call or has a reason not to, and `check-veneer.bash` enforces that, with the reasons listed in the script. The same check fails when the public half names C, and it builds a consumer separately from the implementation.

- Deliberate deviation: where C++ can't mirror a Rust `Result`, it follows Go, which is the other binding without exceptions. `load_file`, `read_file` and `generate` return a pair, and a strict parse's failure is `strict_failed()` on the document it returns. `suppress_declared_repeats` and `_reopens` take the document rather than a diagnostics list, since the core drops the hints in place. The C enums' values are checked against the C++ ones at compile time, and the format strings are the C macros, so neither one can get out of sync.

- Deliberate deviation: in C, the reason a write failed comes back through a last `shcl_write_status *why` argument on each call that writes, which may be NULL, the way a load's file status does. The C++ saves take the same pointer with a default of `nullptr`, so a save written before it still compiles, and the `SaveResult` it returns is still the one to test. `write_file_atomic` returns the `WriteStatus` itself, and `UpgradeError` has it as `status`. Otherwise this interface doesn't return things through a pointer the call writes.

- Deliberate deviation: C's convenience read tier includes only the value types, which are `shcl_get_int_or`, `_float_or`, `_bool_or`, `_duration_or`, and `_size_or`. String, raw, raw-info, datetime, and array reads return borrowed memory or lengths that a value-or-default signature can't express, so those stay on the full `shcl_read_*` tier. The spec's ergonomic-tier section says the same. The other 3 bindings do have all of them, including raw-info, and so does C++, which copies every result. Its `get_or<T>` handles each `get<T>` type, including the arrays and `Datetime`, and `get_raw_or` and `get_raw_info_or` are named calls because a raw block is a `std::string` to a template.

- Deliberate deviation: an allocation failure inside a parse or a validate unwinds and the call returns NULL, where the other 3 abort. Their languages abort on allocation failure, so there's nothing to mirror, but a C consumer that embeds the header has a process that isn't the library's to end. Everywhere else the `SHCL_OOM()` hook still handles it, which includes a read, a write, and a merge on a document that's already built.

- Deliberate deviation: on mingw x86_64 the 2 recovery points are armed with `_setjmp(buf, NULL)` rather than plain `setjmp`. mingw's `setjmp` stores `__builtin_frame_address(0)` as an SEH target frame, and `longjmp` then runs a full `RtlUnwindEx` to reach it. Taking that address forces a frame pointer. gcc encodes a vectorized function's xmm save slots as offsets from the rsp after the prologue, while `UWOP_SET_FPREG` in the same unwind info tells the unwinder to take them from rbp, which is above the whole frame. Windows resolves the difference past the top of the stack and the read faults. wine derives rsp differently and never sees it, so the identical binary passes there. A NULL frame makes `longjmp` restore the context without unwinding, which is all a C recovery point needs, since nothing between the failed allocation and the recovery point has a destructor or a `__finally`. The crash needs both a frame pointer and saved xmm registers, and gcc decides that per optimization level. `-O1`, `-O2`, and `-Os` crashed where `-O0` and `-O3` didn't, so the gate sweeps all 5. It's written `SHCL_SETJMP(buf)` and is in the public half of the header rather than the implementation, because an embedder whose `SHCL_OOM()` hook longjmps needs it in whatever translation unit arms the recovery point. The guard applies only to mingw x86_64. mingw takes the same unwinding branch on aarch64, but nothing builds the C binding for aarch64 windows. So that target is a limit to measure if it ever comes up, rather than one to widen the guard to on the assumption that it crashes the same way. The cost of the deviation is stated on the macro. Skipping the unwind means a C++ frame between an embedder's recovery point and the failed allocation doesn't run its destructors.

- Deliberate deviation: the float formatter uses its own integer arithmetic rather than `strtod` to check whether the text it writes for a value reads back. The other 3 have a shortest-digits formatter in their runtime. C has `printf` and `strtod`, and more than one C runtime, such as msvcrt and wine's, parses some 15-digit numbers one ulp off. That made the C text for a value depend on the libc it was built against. The parser's float reads still go through `strtod`, so a value read on such a runtime can be one ulp off, and the header can't fix a libc.

- Deliberate deviation: `shcl_compact` doesn't have a counterpart in the other 3. A write goes into the document's bump arena, and the value it replaced stays there until `shcl_free`, so a process that rewrites one field in a loop grows by a few dozen bytes per write. The other 3 reclaim the old value through their runtimes. Compaction rebuilds the document into fresh arenas and copies the diagnostics, the lost count, and the strictness along with it, so a save or a strict gate afterwards reads the same. C++ has it as `compact()`.

- Deliberate deviation: `shcl_tokenize` and `shcl_tokenize_value` take a document, because the span vectors they fill have to be stored somewhere, and the read arena is where everything handed to a caller is stored. The `shcl_tokens` struct is zeroed before its first use and again after `shcl_reads_release`. Inside the parser the same tokenizer fills the parse scratch, so a load doesn't retain any of it. `shcl_migrate` is the one text result without a document behind it. It returns a `shcl_migration` whose `text` is a malloc'd buffer the caller frees, the way `shcl_read_file` does. It returns a struct rather than taking out-parameters because the other 3 return one, and its counters are the same 3 fields there.

- Deliberate deviation: `shcl_reads_release` doesn't have a counterpart in the other 3. Read results are copied into the document's read arena, which only `shcl_free` reclaims. That's the right default for a consumer that reads once, and it's the documented contract. A process that polls one document in a loop needs a way out, and the other 3 bindings get one for free because they return owned collections that their runtime reclaims. C++ calls it on every read, since it copies each result into owned std types as soon as it gets it. The `_to` read forms are C-only for the same reason. They copy into the caller's buffer, so a caller never has to remember the release, and C++ doesn't wrap them.

- Deliberate deviation: the emit, overlay and clone walks are iterative where the reference recurses, as in Python. At the depth cap of 512 levels, the emit recursion took about 190 KB of stack at `-O2` and the overlay about 560 KB. That's past a musl thread's 128 KB and far past an embedded stack, which the README says the C binding builds for. A 64 KB thread leaves 128 bytes a level, which is too little for any recursive frame that does real work. Each walk has its own stack in the scratch arena and visits nodes in the same order, so the output doesn't change.

- Rust's generic `name_unit` is `name_duration_unit` and `name_size_unit` in C, over a shared `name_ends`. C doesn't have generics, so one lookup per unit table is as close as it gets.

- The read structs stay value plus status, where the other 3 have `raw`, `line`, and `quoted` on the read result. A C consumer asks for each of them through its own accessor, which is `shcl_raw_text`, `shcl_line`, or `shcl_quoted`, because widening a by-value struct to include a borrowed span adds a cost to every read that never looks at it. `shcl_raw_text` has the longer name since `shcl_read_raw` already reads a raw block. C++'s `Read<T>` follows C here rather than the other 3. Filling `raw`, `line`, and `quoted` would resolve the path 3 more times on every read, so they stay `raw()`, `line()`, and `quoted()` on the `Document`.

### Bash and PowerShell

- The Bash and PowerShell wrappers were retired on 2026-10-08 and frozen in `project/legacy/`, and they're left out of every lint list. What's left is the installers, the dogfood runner, and the pipeline's own scripts.

- shellcheck gates the bash scripts. shfmt doesn't rewrite them, since its output conflicts with the house shell style. PSScriptAnalyzer gates the ps1 files.

- Shell scripts keep the compact house style, with `#•••` section rules, minified helper functions, and the header layout the existing files use.

## Performance

Correctness comes first, and in this repo parity comes with it. An optimization that makes one binding faster but makes the 4 of them disagree is a bug. Beyond that, speed and memory are treated as 4 separate stages rather than one thing to worry about at the end.

The wins that matter were locked in by the architecture, before any code was hot. Know these before you restructure a parser:

- Parsing is one forward pass on one thread, without backtracking. The line is the unit of error recovery, which is also what keeps forgiving parsing cheap.

- C manages memory with a bump arena per document, plus a scratch arena that resets on every read call. There isn't any ownership per object or a free list, and `shcl_free` drops the whole thing.

- The parser builds its `(name, value)` child index as it goes, so in-file duplicate folding and merges never rescan siblings. It's discarded once the parse is done.

- Path lookups use a second index, keyed on `(parent, name)` and built the first time a lookup needs one, so reading every key in a large document doesn't scan siblings per key. The Writer keeps it current as it places, folds, and removes nodes. Only a merge drops it, and the next lookup rebuilds it.

- Both indexes store only hashes and node indices. Key strings are never built, and a hit is verified against the arena, so a hash collision costs a comparison rather than a wrong answer.

Then there are habits that cost nothing to write and aren't premature:

- Reserve a collection when the size is knowable, and grow it geometrically rather than by one.

- Hoist anything invariant out of a loop. Look it up once.

- Build strings with the language's builder, never by repeated concatenation.

- In shell, don't fork inside a loop. One pass of one tool beats a thousand subshells, and the pipeline's own scripts are held to that.

Optimizing early is fine when there's named evidence for it. The profiler stage runs on every full local pipeline run, though not under `--quick` or `--gate`. It checks its own attribution against 2 loops of known cost and writes a flamegraph plus a hot-spot summary, so "this path is already slow" can be a fact rather than a hunch. Without evidence like that, leave the code alone.

Everything else waits for the end, and only measurement drives it. Micro-optimization belongs here and nowhere else. Profile an optimized build on a realistic workload, work on the top of the list, measure again, and revert anything that didn't move the number. The 20260725 performance tranche is the worked example. A merge of 32k nodes went from 16 seconds to 0.07, and all of the gain came from accelerators rather than rewrites.

Release builds are tuned for size and speed together. The Rust release profile uses fat LTO, one codegen unit, `panic = "abort"`, and symbol stripping. The binary isn't packed, on purpose, because packers trip antivirus heuristics.

## Prose and docs

- Markdown never hard-wraps. One paragraph or bullet is one physical line.

- Use short sentences, and nested bullets rather than clauses chained with commas. Keep bold, italics, and caps to a minimum, avoid drama, and don't use unicode beyond what the content needs.

- Filenames are lowercase, except where a tool or convention fixes the casing: `README.md`, `Cargo.toml` and `Cargo.lock`, `CODEOWNERS`, `FUNDING.yml`, and `PSScriptAnalyzerSettings.psd1`.

- Docs are updated in the same change as the code they describe, rather than after it.
