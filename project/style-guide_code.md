<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD033 -- inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
# Style guide

The canonical coding and prose style for this repo. `contributing.md` covers process; this file covers how the code and docs are written, and why. Where this guide and a general-purpose "best practice" disagree, this guide wins on purpose - the deviations are listed per language, each with its reason.

## Parity over idiom

This is the one rule that overrides everything else in this file, and the reason parts of this codebase are deliberately *not* written the way a style checker for each language would suggest.

The bindings are one program written several times. Rust is the reference; Go, Python, and C are independent ports of it. All of them must produce byte-for-byte identical output - same stdout, same exit codes, same diagnostic codes - and the conformance corpus plus the cross-binding differential check enforce that on every build.

To keep that promise cheap to maintain, every port mirrors the reference's *structure*, not just its behavior:

- Same function inventory and call flow. The reference's `read_string` is Go's `ReadString`, Python's `read_string`, C's `shcl_read_string`. One concept, one name, spelled in each language's case convention.

- Same parse pipeline, same order of operations, same helper boundaries. A line of the reference has a recognizable sibling line in every port.

- Same user-visible strings where output is the contract (diagnostic codes, `check` summaries, CLI usage errors).

Why: when a bug is fixed or a feature is added to the reference, the port is a mechanical diff of the same function in each sibling - not a re-derivation. Structural divergence is where behavioral divergence hides; two "equivalent" idiomatic implementations of the same rule will eventually disagree on an edge case, and in this project that is a defect by definition.

The cost is accepted openly: some code reads as slightly foreign to a native of its language. A Go reader will notice reads return a status struct instead of an `error`; a Python reader will notice explicit character-class loops where `str.strip()` would be shorter. Those are not oversights - each one exists because the shorter idiom behaves differently from the reference in some corner (the specific cases are listed below).

Scope of the rule: parity governs structure and behavior. Idiom still governs the surface - each language keeps its own formatter, naming case, error-propagation syntax, and doc-comment conventions. The goal is "obviously the same program, written by someone fluent in each language", not transliterated Rust.

New bindings (Tier 3) follow the same recipe: port the reference function-for-function, run the corpus, and don't release until the crosscheck is green.

## Rules for every language

- Formatters win. Where a canonical formatter exists (rustfmt, gofmt), its output is the law - run it, don't hand-format against it. Intentional data tables get the formatter's skip pragma rather than a fight.

- Tabs for indentation, spaces for alignment. The test is whether the language prevents it or strongly pushes the other way; none of the six here do, so all six use tabs. This repo pins rustfmt to `hard_tabs`; gofmt is tabs natively; Python, C and both shells follow suit. PEP 8 does prefer spaces, but it also says to stay consistent with code already indented with tabs, and one indentation style across a multi-language repo is worth more than per-language purity. The Python linter's tab rule (`W191`) is switched off for exactly this reason, not overlooked.

- Names are meaningful and searchable: `upperBound`, not `ub`. Short conventional names are fine where they are idiomatic - loop indices (`i`), a local `err`, a receiver letter in Go, and few-line locals in the compact parser cores (`t` for a just-trimmed line, `q` for the current quote char) where the same short name means the same thing at the same site in every binding. The test is "can a reader find and search-replace what you mean", not maximal length.

- Comments are terse and explain *why*, not *what*. No narration of the next line, ASCII only (`->` not arrows; `©` is fine). If a line needs a what-comment, rewrite the line.

- **Section rules are the one sanctioned banner.** In a single-file drop-in binding of a few thousand lines they are the only navigation aid, so each binding uses exactly one spelling for its major-section dividers and nothing else: Rust and Go a full-width `// ----...` line with the section title on the following comment line; Python the same three-line form written `# ----...` / `# <title>` / `# ----...`; C `// --- <title> ---...` padded to the margin, with `// ====...` reserved for the header/implementation split; shell keeps the house `#•••` rule; PowerShell writes it `#===`, because every `.ps1` stays ASCII with no byte-order mark. `irm | iex` keeps a mark on `install.ps1` and the parse then fails, and Windows PowerShell 5.1 reads a file with no mark in the ANSI code page. No other decorative comment forms.

- Every source file starts with the SPDX line and copyright, then a short purpose block. Library files also state the drop-in story and the parity contract.

- The tokenizer is the one place the lexical rules live. Every reading of a line's parts - the parser's dispatch, the path scanner, the comment and comma splits, the element cap, the quote check, `SetLiteral`, the CLI's `--set` split - goes through it and reads spans. No second quote state machine, in any binding: a rule that has to be read somewhere new is read through the tokenizer, or the tokenizer grows.

- A setter writes only what reads back. It builds its text through the emitter, hands that to the tokenizer, and refuses unless what comes back is the value it was given, so a write that would come back different never touches the document. No setter carries its own trim, carriage-return, `#` or quote rule, in any binding; a new setter adds no rule of its own. The typed setters keep their render-and-parse-back on top of it, since a float or a datetime has to read back as that type and not merely as the same text.

- **A public call has one name across the four bindings, cased the way its language cases names.** `format_float` is `format_float`, `FormatFloat`, `format_float` and `shcl_format_float`; it was `format_f64` in Rust and C until 2026-09-20, which made the reference name a Rust type in an API contract that has none. The datetime zone type is `Zone` everywhere for the same reason. This is the rule a later pass judges a name against, so the spread does not get re-argued: the exceptions below are the whole list, and a new one needs a line here.
	- Go spells the datetime type `DateTime` and the call `ParseDateTime`, where the other three spell it `datetime` as one word. Go names a constructor after its type, and the type is a deliberate deviation of its own, below.
	- Go carries a `ZoneKind` enum and a `Zone` struct where Rust has one enum with a payload, and C carries a `shcl_zone_kind` enum beside an `off_min` field. Neither language has a payload-carrying enum, so the shape differs; the word does not.
	- Python's zone is a `("utc", None) | ("offset", minutes)` tuple with no named type. A two-case tagged value is a tuple in Python, and a class for it would be the port reading as something the other three are not.
	- C writes `read_bool` and `write_reason` as `shcl_read_bool_` and `shcl_write_reason_`. C gives a function and a typedef one namespace, and the result types already hold the plain names. Renaming either side would break callers for no gain in behavior.

- Single file per binding, zero dependencies. That is the product ("copy this file into your tree"), so no module splits, no helper crates/packages, and no dependency however good.

- Small standalone utility scripts are MIT regardless of anything else, and carry their license in the header.

- What analysis runs, and what deliberately does not. Gating: rustfmt and clippy, gofmt, go vet, staticcheck, govulncheck, cargo-deny, ruff, mypy, cppcheck, PSScriptAnalyzer, shellcheck, markdownlint. Declined, each for a reason that is not going to change:
	- `clang-format` and `clang-tidy`. Reformatting the C drop-in rewrites roughly nine lines in ten, which throws away the hand-aligned tables and the structural match with the other bindings.
	- `golangci-lint`. It wraps checks that already gate individually, so it would add a dependency and no signal.
	- `shfmt`. Its output fights the shell style the pipeline scripts are written in.
	- Pedantic clippy. Satisfying it means restructuring away from the reference's shape, which is the one thing parity forbids.

## Per-language

### Rust (reference)

- rustfmt is canonical, with the repo's `rustfmt.toml` (`hard_tabs = true`). Clippy gates at its default level; pedantic is advisory.

- Errors as values via `Result` and `?` where a real error exists. But most "failure" here is not an error: a missing or mistyped value is a normal, expected outcome, so reads return a `Read<T>` carrying a `Status` - by spec, not exception-shaped. No `panic!`/`unwrap`/`expect` outside tests, and none in released code: the only ones left sit behind the `profiling` feature, which never compiles into a normal build.

- No `thiserror`/`anyhow`, no error-crate ergonomics: the zero-dependency rule outranks them, and `Status` + structured diagnostics already cover the domain.

- Derive (`Debug`, `Clone`, `PartialEq`) rather than hand-roll. Public items get `///` docs. Early returns and `let .. else` over nesting.

- `Cow<str>` where a per-line helper usually has nothing to do: `fold_name` when a name has no upper case to fold, and the path scanner's plain-name fast path when a name has nothing to resolve. The other three allocate freely there, or hand the work to a garbage collector, so there is nothing to mirror - and the parser calls these once per segment per line, where two strings built and freed for the sake of copying bytes onto themselves showed up in a profile.

- The setters are `#[must_use]`. Surface-only, so parity is untouched - the other three have no equivalent and say the same thing in prose. A dropped `false` means the save that follows writes a config missing the edit and reports success, which is the one failure here that leaves no trace anywhere; the compiler catches it for free in the one language that can.

### Go

- gofmt and `go vet` gate. Standard library only.

- Reads return `Read[T]` (generics) with a `Status` field, not `(T, error)`. Deliberate deviation: the reference models read failure as data, and an `error` return would push every port toward different control flow. Real errors (I/O, bad UTF-8) still use `error` normally.

- No interfaces: there is one implementation of everything and no test seam that needs one. No goroutines: parsing is single-pass and single-threaded by design.

- Exported identifiers get doc comments starting with the name. Short names in small scopes, descriptive in the public API.

- Deliberate deviation: the datetime type is `DateTime`, not `ShclDateTime`; the package name already carries the prefix. The reference and Python export `DateTime` as an alias so the two spellings meet.

- The tokenizer's absent offsets (`Sep`, `Comment`, `Fault`) are `-1` where the reference has `None`; the spans themselves are the same byte offsets in every binding.

### Python

- Python 3.9+, stdlib only. ruff and mypy (default mode) gate; black does not run - the repo's tab indentation stands (see the repo-wide rule above).

- Status-carrying reads instead of exceptions, matching the reference; exceptions are for real faults, not for "value not found".

- Several stdlib shortcuts are banned because they diverge from the reference's semantics: `str.strip()` (Python's whitespace set differs from Rust's), `str.lower()` (locale/Unicode folding; ASCII-only folding is the spec), bare `round()` (banker's rounding; the spec is half-away-from-zero), unbounded `int` (range-check against i64). Each ban is commented at the site it matters.

- Control flow mirrors the reference, so it leans more LBYL than idiomatic EAFP. That is the parity rule at work.

- Deliberate deviation: the parser's child/display accelerator maps key on exact tuples of the strings already in hand, where the other three bindings stream an FNV hash and verify hits against the arena. CPython's dict and tuple machinery runs at C speed while a hand-rolled per-byte hash loop does not, and the tuple keys are exactly as injective - same first-wins semantics, same behavior.

- Deliberate deviation: Python carries three hot-path shortcuts the other bindings do not need - a length-one branch in the value display and the merge key, an identity test before the source-attach guard's key compare, and the path scanner's two helpers at module level rather than nested. Rust and Go stream these fields through a hash and build nothing, and a closure per call costs nothing there. The shortcuts change no output and are asserted structurally in the Python runner, not by a clock.

- Deliberate deviation: the emit, overlay and clone walks are iterative where the reference recurses. CPython's own recursion limit sits far below the 512-level depth cap the spec allows, so a document the reference formats without complaint raised RecursionError here; raising the interpreter's limit would have moved the failure to a stack overflow with no traceback. The walks carry their own explicit stacks and visit nodes in the same order, so the output is unchanged.

- The public surface is type-hinted (every public method, function and attribute); private helpers are hinted where it pays, and mypy strict is not a gate.

- Deliberate deviation: the write side's read-back check lets text with no UTF-8 spelling through. Python's string is the only one of the four that can hold a lone surrogate, and the tokenizer scans bytes, so there is nothing to hand it; the save is where a document that cannot be encoded fails, and always was.

- Deliberate deviation: the tokenizer scans the UTF-8 bytes of the line rather than the str, and `Tokens.src` keeps those bytes so the read-back helpers can slice them. Every offset the four bindings hand out is a byte offset, and the `tokens` output is compared byte for byte, so the str's code-point offsets could not serve. Two hot-path shortcuts ride on that, both exact: a value with no quote and no `#` is cut with `bytes.find` one piece at a time (so the element cap still stops the scan where the byte loop would), and a bare name is matched with a compiled ASCII class.

### C and C++

- C11, single header, STB-style (`#define SHCL_IMPLEMENTATION` in one TU). The gate is `-Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror` plus cppcheck.

- Memory model: one bump arena per document, `shcl_free` frees everything, no per-object ownership. Raw pointers are fine here - this is C working as designed, not a RAII gap. The one exception is the node vector, which lives in malloc/realloc storage: a bump arena cannot reclaim the abandoned half of each doubling, and the node array is the biggest thing that doubles.

- Strings are length-delimited byte spans with explicit UTF-8 iteration helpers, because the reference iterates `char`s and byte-wise shortcuts mis-handle multibyte input.

- The C++ interface (`shcl.hpp`) is a binding of its own over the C core, not a second parser. Its calls and types mirror the Rust reference in std types, and a caller sees nothing of C. The header's public half names no C, and the calls into it sit in the `SHCL_IMPLEMENTATION` section, which one file compiles. C++17 (the gate's pin, for broad compiler reach), with no exceptions. It makes every public C call or has a reason not to, and `check-veneer.bash` holds it to that, with the reasons listed in the script. The same check fails when the public half names C, and builds a consumer apart from the implementation.

- Deliberate deviation: where C++ cannot mirror a Rust `Result` it follows Go, the other binding with no exceptions. `load_file`, `read_file` and `generate` return a pair, and a strict parse's failure is `strict_failed()` on the document it returns. `suppress_declared_repeats` and `_reopens` take the document rather than a diagnostics list, since the core drops the hints in place. The C enums' values are checked against the C++ ones at compile time, and the format strings are the C macros, so neither can drift.

- Deliberate deviation: C's convenience read tier covers only the value types (`shcl_get_int`/`_float`/`_bool` and the `_or` spelling of each). String, raw, raw-info, datetime, and array reads hand back borrowed memory or lengths that a value-or-default signature cannot express, so those stay on the full `shcl_read_*` tier. The spec's ergonomic-tier section says the same. The other three bindings do carry all of them, raw-info included, and so does C++, which copies every result: `get_or<T>` covers each `get<T>` type, the arrays and `Datetime` among them, and `get_raw_or` and `get_raw_info_or` are named calls because a raw block is a `std::string` to a template.

- Deliberate deviation: an allocation failure inside a parse or a validate unwinds and the call returns NULL, where the other three abort. Their languages abort on allocation failure and there is nothing there to mirror, while a C consumer embedding the header has a process that is not the library's to end. Everywhere else - a read, a write, a merge on a document already built - the `SHCL_OOM()` hook is still the answer.

- Deliberate deviation: on mingw x86_64 the two recovery points are armed with `_setjmp(buf, NULL)` rather than plain `setjmp`. mingw's `setjmp` stores `__builtin_frame_address(0)` as an SEH target frame, and `longjmp` then runs a full `RtlUnwindEx` to reach it. Taking that address forces a frame pointer, and gcc encodes a vectorized function's xmm save slots as offsets from the post-prologue rsp while `UWOP_SET_FPREG` in the same unwind info tells the unwinder to take them from rbp, which sits above the whole frame. Windows resolves the difference past the top of the stack and the read faults; wine derives rsp differently and never sees it, so the identical binary passes there. A NULL frame makes `longjmp` restore the context without unwinding, which is all a C recovery point needs, since nothing between the failed allocation and the arrival has a destructor or a `__finally`. The shape needs both a frame pointer and saved xmm registers, which is a decision gcc makes per optimization level: `-O1`, `-O2` and `-Os` crashed where `-O0` and `-O3` did not, so the gate sweeps all five. It is written `SHCL_SETJMP(buf)` and sits in the public half of the header rather than the implementation, because an embedder whose `SHCL_OOM()` hook longjmps needs it in whatever translation unit arms the recovery point. The guard is mingw x86_64 only. mingw takes the same unwinding branch on aarch64 and nothing builds the C binding for aarch64 windows, so that target is a limit to measure if it ever arrives rather than one to widen the guard to on the assumption the shape matches. What the deviation costs is stated on the macro: skipping the unwind means a C++ frame between an embedder's recovery point and the failed allocation does not run its destructors.

- Deliberate deviation: the float formatter decides whether a spelling reads back with its own integer arithmetic, not `strtod`. The other three have a shortest-digits formatter in their runtime; C has `printf` and `strtod`, and more than one C runtime (msvcrt, wine's) parses some 15-digit spellings one ulp off, which made the C spelling of a value depend on the libc it was built against. The parser's float reads still go through `strtod`, so a value read on such a runtime can be one ulp off; the header cannot fix a libc.

- Deliberate deviation: `shcl_compact` has no counterpart in the other three. A write goes into the document's bump arena and the value it replaced stays there until `shcl_free`, so a process rewriting one field in a loop grows by a few dozen bytes per write; the other three reclaim the old value through their runtimes. Compaction rebuilds the document into fresh arenas, carrying the diagnostics, the lost count and the strictness with it, so a save or a strict gate afterwards reads the same. C++ has it as `compact()`.

- Deliberate deviation: `shcl_tokenize` and `shcl_tokenize_value` take a document, because the span vectors they fill have to live somewhere and the read arena is where everything handed to a caller lives; the `shcl_tokens` struct is zeroed before its first use and again after `shcl_reads_release`. Inside the parser the same tokenizer fills the parse scratch, so a load retains none of it. `shcl_migrate` is the one text result with no document behind it, and hands back a `shcl_migration` whose `text` is a malloc'd buffer the caller frees, the way `shcl_read_file` does. It returns a struct rather than taking out-parameters because the other three return one, and the counters it carries are the same three fields there.

- Deliberate deviation: `shcl_reads_release` has no counterpart in the other three. Read results are copied into the document's read arena, which only `shcl_free` reclaims - the right default for a read-once consumer and the documented contract. A process polling one document in a loop needs a way out, and the other three bindings have one for free because they hand back owned collections their runtime reclaims. C++ calls it on every read, since it copies each result into owned std types the moment it gets it. The `_to` read forms are C-only for the same reason: they copy into the caller's buffer, so a caller never has to remember the release, and C++ does not wrap them.

- Rust's generic `name_unit` is `name_duration_unit` and `name_size_unit` in C, over a shared `name_ends`. C has no generics, so one lookup per unit table is the closest it gets.

- The read structs stay value+status, where the other three carry `raw`, `line` and `quoted` on the read result. Those two of the three that a C consumer can still ask for are separate accessors - `shcl_line`, `shcl_quoted` - because widening a by-value struct to carry a borrowed span costs every read that never looks at it. C++'s `Read<T>` follows C here rather than the other three. Filling `line` and `quoted` would resolve the path twice more on every read, so they stay `line()` and `quoted()` on the `Document`.

### Bash and PowerShell (wrappers)

- These are front ends to the compiled `shcl` binary, not parsers - they inherit conformance for free.

- shellcheck gates the bash wrapper; shfmt does not rewrite (its output fights the house shell style). PSScriptAnalyzer gates the ps1.

- The ps1 deviates from PowerShell convention on purpose: no `param()` block (it would eat `get`/`--int` before they reach the binary in dual-mode use) and `shcl_*` snake_case helper names instead of Verb-Noun (the sourced call surface is identical across bash and pwsh, which outranks the local convention for a two-line forwarder).

- Shell scripts keep the house compact style: `#•••` section rules, minified helper functions, the header layout the existing files use.

## Performance

Correctness comes first, and in this repo parity comes with it: an optimization that makes one binding faster and the four of them disagree is a bug, not a win. Beyond that, speed and memory are treated as four separate stages, not as one thing to worry about at the end.

The wins that matter were locked in by the architecture, before any code was hot. Know these before reshaping a parser:

- Parsing is one forward pass, single-threaded, no backtracking. The line is the unit of error recovery, which is also what makes the forgiveness story cheap.

- C owns memory with a bump arena per document, plus a scratch arena that resets on every read call. No per-object ownership, no free list - `shcl_free` drops the whole thing.

- The parser builds its `(name, value)` child index as it goes, so in-file duplicate folding and merges never rescan siblings. It is discarded once the parse is done.

- Path lookups use a second index, keyed on `(parent, name)` and built the first time a lookup needs one, so reading every key in a large document does not scan siblings per key. The Writer keeps it current as it places, folds and removes nodes; only a merge drops it, and the next lookup rebuilds.

- Both indexes hold hashes and node indices only. Key strings are never built, and a hit is verified against the arena, so a hash collision costs a comparison rather than a wrong answer.

Then there are the habits, which cost nothing to write and are not premature:

- Reserve a collection when the size is knowable, and grow it geometrically rather than by one.

- Hoist anything invariant out of a loop. Look it up once.

- Build strings with the language's builder, never by repeated concatenation.

- In shell, no forks inside a loop. One pass of one tool beats a thousand subshells, and the pipeline's own scripts are held to that.

Optimizing early is fine when there is named evidence for it. The profiler stage runs on every full local pipeline run, not under `--quick` or `--ci`, checks its own attribution against two loops of known cost, and writes a flamegraph plus a hot-spot summary, so "this path is already slow" can be a fact rather than a hunch. Without something like that, leave it alone.

Everything else waits for the end, and is driven by measurement only. Micro-optimization belongs here and nowhere else: profile an optimized build on a realistic workload, attack the top of the list, measure again, revert anything that did not move the number. The 20260725 performance tranche is the worked example - a 32k-node merge went from 16 seconds to 0.07, all of it accelerators rather than rewrites.

Release builds are tuned for size and speed together. The Rust release profile uses fat LTO, one codegen unit, `panic = "abort"` and symbol stripping. The binary is deliberately not packed - packers trip antivirus heuristics.

## Prose and docs

- Markdown never hard-wraps: one paragraph or bullet is one physical line.

- Short sentences. Nested bullets over comma-chained clauses. Minimal bold/italics/caps, no drama, no unicode beyond what the content needs.

- Filenames are lowercase, except where a tool or convention fixes the casing: `README.md`, `Cargo.toml`/`Cargo.lock`, `CODEOWNERS`, `FUNDING.yml`, `PSScriptAnalyzerSettings.psd1`.

- Docs update in the same change as the code they describe, not after.
