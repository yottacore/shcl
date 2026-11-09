<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD033 -- inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- markdownlint-disable MD026 -- Trailing punctuation in heading; the "compares to..." ellipsis is deliberate -->
<div align="center">

[![CI](https://github.com/yottacore/shcl/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yottacore/shcl/actions/workflows/ci.yml?query=branch%3Amain)
[![Latest release](https://img.shields.io/github/v/release/yottacore/shcl?sort=semver&include_prereleases)](https://github.com/yottacore/shcl/releases)
[![Needs](https://img.shields.io/badge/needs-Rust%201.88%2B%20%7C%20Go%201.20%2B%20%7C%20Python%203.9%2B%20%7C%20C11%20%7C%20C%2B%2B17-blue)](project/examples.md#example-use-cases-in-your-code)

<!-- TOC ignore:true -->
# SHCL

**S**imple **H**ierarchical **C**onfig **L**anguage

*A config format for files people edit by hand. Forgiving to write, predictable to read.*

<!-- width = the gif's own pixel width, so it never renders larger than 1:1; no height attr, so a narrow column can still shrink it without squashing -->
<img src="assets/demo.gif" alt="SHCL demo: a messy config file, a typed read from it, check reporting the bad lines while the rest loads, and fmt rewriting it with nothing lost" width="960"/>

<!-- [Watch the walkthrough](https://www.youtube.com/watch?v=VIDEO_ID) -->

<br />

</div>

- A typo costs you one line, not the whole file.

- A program can change one value and leave every other line the way a person typed it, comments and all.

- A save won't delete anything you wrote unless you tell it to.

- Your code picks a value's type when it reads it, so `NO` never turns into `false`.

- Rust, Go, Python, C, and C++ read a file the same way. Each library is one source file with no dependencies.

- The CLI comes prebuilt and signed for Linux, macOS, Windows, and FreeBSD. It's all MIT licensed.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [The problem](#the-problem)
- [What SHCL does about it](#what-shcl-does-about-it)
- [Try it](#try-it)
- [What a .shcl file looks like](#what-a-shcl-file-looks-like)
- [How it compares to...](#how-it-compares-to)
	- [Config languages - JSON, YAML, TOML, XML](#config-languages---json-yaml-toml-xml)
	- [When SHCL is the wrong choice](#when-shcl-is-the-wrong-choice)
- [More features](#more-features)
- [Who uses SHCL](#who-uses-shcl)
- [Escapes](#escapes)
- [Installation](#installation)
- [Usage and examples](#usage-and-examples)
- [Set up a development environment](#set-up-a-development-environment)
- [Docs](#docs)
- [Contributing and support](#contributing-and-support)
- [Legal stuff](#legal-stuff)

<!-- /TOC -->

## The problem

You have probably lived some version of this:

- A whole service refused to start because one line of config had a typo.

- YAML turned `country: NO` into `false`. (Norway. It really does that.)

- JSON needed a comment, and JSON doesn't do comments.
	- Or a trailing comma killed the parse.

- TOML was pleasant right up until the data nested three levels deep.

- You wanted an integer. You got a string, or an exception, or a silent zero you didn't notice until production.

- That one project that stored a complex nested config in XML. You still have PTSD from it.

Every mainstream format makes you do the careful work, and punishes the whole file for one mistake.

## What SHCL does about it

SHCL (canonically pronounced "SHiCkLe") flips the burden around. Modern CPU cycles are cheap, even on embedded systems. Brainpower isn't.

So the parser does the hard work, and the person writing the file and the programmer reading it don't have to.

SHCL makes a contract:

- Types live in your code, not in the file. The file stores text. You ask for a type when you read a value. Nothing is guessed at parse time, so there is no "Norway problem".

- One broken line never takes down the file. It is skipped with a note. Everything else that can still be loaded safely is.

- Every convenience read states a fallback at the call site. A missing value cannot sneak in as a silent zero.

- If a person can tell what a line means, the parser can too.

When you do want zero-tolerance rigor: schema validation, plus a strict mode that fails loudly.

## Try it

Install the CLI. Until 3.0.0 is out, `--release dev` gets the 3.0 beta that this page describes:

~~~sh
bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash) --release dev
~~~

Windows, the packages, and the language libraries are in [Installation](project/install.md).

Save this as `box.shcl`. It has a mistake on line 3:

~~~text
name:      Build box
port:      8081    # 8080 is taken
workers =  4
log-level: warn
~~~

The bad line gets reported, and the rest of the file still reads:

~~~console
$ shcl get --int box.shcl port
line 3: Error: E014 malformed line skipped: unexpected character after the path, at column 9
8081
~~~

Now change the port from a script. The comment, the spacing, and even the broken line are left where they were, so whoever wrote it can still fix it:

~~~console
$ shcl set --write box.shcl --set 'port=9000'
line 3: Error: E014 malformed line skipped: unexpected character after the path, at column 9

$ cat box.shcl
name:      Build box
port:      9000    # 8080 is taken
workers =  4
log-level: warn
~~~

`shcl check box.shcl` lists every problem and exits 6, for CI. `shcl explain E014` prints the rule behind the code.

## What a .shcl file looks like

Below is an example config for a small web server - the kind of thing nginx makes you learn a bespoke brace language for. All of this is one valid file: indentation and dotted paths are interchangeable, quoting is only needed when a value contains a reserved character, and messy spacing is fine.

~~~~text
# Flat, TOML-style settings
listen: "0.0.0.0:443"
workers: 4
log-level: warn

# Hierarchy when you need it: one instance per site
site: example.com
	root: /srv/www/example
	Max-Upload-MB : 50
	methods: [GET, POST, HEAD]
	tls:
		cert: /etc/ssl/example.pem
		hsts: on

# Repeating the field adds another site - arrays of objects
# no syntax to invent
site: blog.example.com
	root: /srv/www/blog

# Dotted paths give the same tree; add to any instance from anywhere
site("blog.example.com").tls.hsts: off

# Multi-line content goes in a fenced block, kept verbatim
maintenance-page:
	~~~html
	<h1>Down for maintenance - back in five.</h1>
	~~~
~~~~

Field names are case-insensitive, and repeated paths merge. Here `site` is a set of instances. Each of example.com and blog.example.com has its own children.

## How it compares to...

### Config languages - JSON, YAML, TOML, XML

|                                       | SHCL                       | JSON            | YAML                                      | TOML                           | XML
| :---                                  | :---                       | :---            | :---                                      | :---                           | :---
| Comments                              | ✅                          | 🚫               | ✅                                         | ✅                              | ✅
| Unquoted strings                      | ✅                          | 🚫               | ✅ But the parser may silently change type | 🚫                              | 🚫
| Bad lines don't break the whole thing | ✅                          | 🚫               | 🚫                                         | 🚫                              | 🚫
| Who decides a value's type            | Your code, at read time    | The file        | The parser guesses                        | The file                       | Your code
| Deep nesting                          | Indent or dot paths, mixed | Brace pyramids  | Indent, whitespace-fragile                | `[a.b.c]` headers get old fast | Tag soup
| Nested arrays                         | 🚫 Use repeated instances   | ✅               | ✅                                         | ✅                              | Repeated child tags
| Nested object definitions             | ✅                          | ✅               | ✅                                         | ✅                              | ✅
| Multi-line verbatim blocks            | Fenced, like Markdown      | Escaped strings | Block scalars, with rules to memorize     | Multi-line strings             | CDATA
| Hand-editable by a non-programmer     | ✅                          | Risky           | Risky                                     | ✅ Mostly                       | 🚫
| Tells you what it fixed               | ✅ Structured diagnostics   | 🚫               | 🚫                                         | 🚫                              | 🚫

> *A note on types, because it is the big design difference: JSON and TOML store types in the file, so the author has to get them right. YAML infers types from the text, which is where `NO` becomes `false`. SHCL stores plain text and coerces when **you** ask for a type; the only code that decides a value is an int (for example) is the code that needed an int.*

[Compared to other config languages](project/comparison.md) has the benchmark numbers, and how SHCL differs from Pkl, CUE, and Dhall.

### When SHCL is the wrong choice

- You need expressions, functions, or imports inside the file itself. Use Pkl (arguably best), CUE, or Dhall.

- You are serializing machine-to-machine data at high volume. Use JSON or something binary. SHCL is for files that people edit.

- You want the whole file decoded into a struct in one call, the way TOML and YAML libraries do it. SHCL reads one path at a time, and that is [by design](project/design.md#consumer-api).

## More features

Beyond the list at the top:

- The Rust reference and the Go, Python, and C/C++ bindings produce byte-for-byte identical output for valid UTF-8, and one conformance corpus tests all of them. Zig uses the C header as is.

- Each binding is a drop-in source file. C++ adds `shcl.hpp` beside `shcl.h`, and Go has an optional Windows file. The CLI is a single binary, and shell scripts call it directly.

- Binaries are prebuilt for Linux and Windows on x86_64 and ARM64, for macOS as one universal binary, and for FreeBSD on x86_64. macOS and FreeBSD start with 3.0.0-beta1. Everything else builds from source with `cargo install shcl`.

- Releases are signed, and the binaries are reproducible from the tag.

- There's a complete specification and a formal grammar.

- Hierarchy comes from indentation or dot paths, such as `site(blog.example.com).tls.hsts: off`, and they mix freely. Both give the same tree.

- Reads come as int, float, bool, datetime, duration, size, string, or raw block. Int, float, bool, datetime, and string reads have array forms too.

- Repeated fields are queryable as a set. Count them, list them, or fan one read across all of them with `site(*).root` and get a status per slot.

- Raw fenced blocks work as in Markdown, and embed anything verbatim, such as SQL, code, or templates.

- Three strictness levels, from most forgiving to fail-on-anything. At Loose, `"$1,200"` reads as 1200 and `15%` as 0.15. Standard and Strict refuse both.

- Every diagnostic has a stable code (`E014`, `V001`), so tooling can match on the code while the prose stays free to improve.

- Schema validation, layered loading (defaults, site, user), and commented starter-config generation, all as library features.

- SHCL is safe on untrusted input. A parse can take caps on nodes, array size, and diagnostics, so a hostile file can't run a program out of memory. Nesting is capped at 512 levels for every parse.

- `shcl fmt --check app.shcl` exits 6 when the file isn't in canonical form. One line gates formatting in CI.

- A save keeps the file's mode and group, and writes through symlinks. On Windows it also keeps the ACLs and the hidden flag. It writes a temp file and renames it, so a crash can't leave half a config behind.

- A save won't write over a change another program made after the load. It can also refuse to replace a file that's already there, and give a new file exact permission bits, such as 0600 for one with tokens in it.

- A file that was written for a newer format version still reads, but no save overwrites it.

- Reads and lists print JSON lines with `--json`, for jq or `ConvertFrom-Json`. `shcl explain E014` prints the rule behind a code, and a typo in a command, an option, or a schema field name gets a suggestion. A man page and bash and zsh completions are included.

- The C binding builds without file IO for embedded targets, and frees a whole document with one call.

- The release gate runs the corpus, a fuzzer, and a 4-way check that feeds the same inputs to all 4 parsers and compares the bytes.

## Who uses SHCL

These projects use SHCL today, and harden it in the process:

| Project                                                                                  | OSS?  | Release status | Used for
| :---                                                                                     | :---: | :---           | :---
| [SilkTerm](https://github.com/jim-collier/silkterm)                                      | Yes   | beta           | Config & UI language
| [GitNiblet OSS Edition](https://github.com/yottacore/gitniblet)                          | Yes   | beta           | Config & DDL
| [GitNiblet Enterprise Edition](https://www.yottacore.com/product/nano-git-db-enterprise) | No    | beta           | Config
| [convert-base-v2](https://github.com/jim-collier/convert-base-v2)                        | Yes   | **stable**     | Config
| [TradeClanker](https://www.yottacore.com/product/tradeclanker)                           | No    | beta           | Config & User's rules

<!--
| [Rapid Photo Downloader Pro](https://github.com/jim-collier/rapid-photo-downloader-pro)    | Yes  | alpha          | Config
| [Nemo Anywhere](https://www.yottacore.com/product/nemo-anywhere)                           | Yes  | beta           | Config
| SlodWorld                                                                                  |  No  | beta           | Config
| [SlodWorld2](https://www.yottacore.com/product/slodworld2)                                 |  No  | beta           | Config
-->

Most of these are by the same author.

## Escapes

Escapes work differently than in most formats, and more predictably. A backslash is plain text everywhere, so a Windows path goes in as typed, quoted or not. (JSON, YAML and TOML all read the `\t` and `\n` in `"C:\temp\new"` as a tab and a line break, and the path quietly breaks.)

This "escape problem" is as old as computer text. It's a fix to a problem that eventually caused more problems than it solved - for something most people rarely need. It has three main causes:

1. A common keyboard character starts escape sequences, even though overwhelmingly most text doesn't need to be escaped.

2. There's no escape terminator. So either an escape is limited to one character after the backslash - and it has to be meaningful somehow - or it's hard to tell where the escape ends. (For example in C, `"\x41BC"` is one escape, not an encoded `A` followed by `BC`.)

3. There's no clear, uniform way to escape the escape character itself. (For example, matching 2 backslashes with a regex in a string literal requires `\\\\\\\\`.)

SHCL avoids the whole problem. It has 3 easy ways to write a problem character, and context suggests the easiest one to use:

1. A fenced block, as in Markdown. Everything in it is passed as-is, tabs and line breaks included.

2. A value in backticks, also as in Markdown. It's never decoded, and unlike quotes, `◉` is a plain character inside it. It's also a handy signal to readers that the program reading the value does the interpreting, not SHCL.

3. The SHCL escape mark `◉`, which begins and ends a finite list of escaped characters (including itself).

Examples:

~~~~text
# No surprise escapes here, it's just a literal string.
backup-dir: C:\temp\new

# The standard fenced block approach to give the calling program a formatted string without interpretation.
help-text:
	~~~
	The system may need one or more of:
		- A reboot
		- Some refreshing water
	~~~

# This is returned as a literal string for the calling program to deal with, as it requested.
color: `\x1b[31m`

# Deliberate and obvious escapes, if you don't want to use a fenced block
motd: "Back soon.◉NEWLINE◉◉TAB◉Sorry for the wait."

# As with the previous example, these values here are returned by SHCL with the escapes properly interpreted.
demo-escapes:
	emoji:  "This is a smiley emoji: ◉U+1F600◉."
	escape: "This is the SHCL escape character: ◉ESCAPE_CHAR◉"
~~~~

The full list of escapes is in [the spec](project/spec.md#escapes).

## Installation

[Installation](project/install.md) has packages for Debian, Fedora, FreeBSD, and Windows, the install scripts for the stable and dev channels, the language packages, and a DIY route.

## Usage and examples

[Usage and examples](project/examples.md) shows the `shcl` command from a shell, and the library from Rust, Go, Python, Zig, C, and C++. It also has Bash and PowerShell scripts, and what a save does to the file.

## Set up a development environment

`install-dev.bash` clones the repo and installs the toolchains and linters the pipeline gates on. The one-liner and the gate to run are in [Installation](project/install.md#set-up-a-development-environment), and [`contributing.md`](contributing.md) has the full list.

## Docs

- [`project/install.md`](project/install.md): packages, install scripts, the DIY route, and a development setup.

- [`project/examples.md`](project/examples.md): the CLI from a shell, and the library from each language.

- [`project/comparison.md`](project/comparison.md): size and speed against JSON, YAML, TOML, and XML, and how SHCL differs from Pkl, CUE, and Dhall.

- [`project/spec.md`](project/spec.md): the full language spec. Terminology, types, coercion, the read API, raw blocks, strictness levels.

- [`project/grammar.abnf`](project/grammar.abnf): the formal grammar.

- [`project/design.md`](project/design.md): the why behind the decisions.

- [`changelog.md`](changelog.md): what changed in each release.

- [`contributing.md`](contributing.md): how to help.

- [`project/style-guide_code.md`](project/style-guide_code.md): coding and prose style. The bindings deliberately mirror the reference's structure over per-language idiom, so they stay byte-for-byte in sync.

- [`project/style-guide_ui-ux.md`](project/style-guide_ui-ux.md): how the command line behaves, including option spelling, the help layout, what goes to stdout and what to stderr, and the exit codes.

The generated API reference is on [docs.rs](https://docs.rs/shcl) for Rust and [pkg.go.dev](https://pkg.go.dev/github.com/yottacore/shcl/source/go/v3) for Go.

## Contributing and support

A config parser gets trusted with other people's files, so help and scrutiny are both welcome. Bug reports, spec edge cases, and new-language bindings all count. See [`contributing.md`](contributing.md) to get started.

If SHCL is useful to you and code or issue reports aren't your thing, a star or a mention helps other people find it. If it saves you time, you can sponsor it through [GitHub](https://github.com/sponsors/jim-collier) or [Ko-fi](https://ko-fi.com/jimcollier).

## Legal stuff

> Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]<br />
> Licensed under the [MIT License](https://mit-license.org/)<br />
> SPDX-License-Identifier: `MIT`<br />
> No warranty.<br />
> SHCL™ is a [trademark](trademark.md) of Jim Collier. The name means it passes the conformance corpus.
