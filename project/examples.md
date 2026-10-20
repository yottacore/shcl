<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Usage and examples

This page shows the `shcl` command from a shell first, then the library from code. Every example here reads `server.shcl`, the small web server config the README shows under [What a .shcl file looks like](../README.md#what-a-shcl-file-looks-like), and the line numbers in the output are that file's.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Using the CLI](#using-the-cli)
- [Example use-cases in your code](#example-use-cases-in-your-code)
	- [Rust](#rust)
	- [Go](#go)
	- [Python](#python)
	- [Zig](#zig)
	- [C, C++](#c-c)
	- [Bash](#bash)
	- [PowerShell](#powershell)
	- [What saving does](#what-saving-does)

<!-- /TOC -->

## Using the CLI

Everything the library does, the `shcl` binary does from a shell: typed reads, edits, validation, formatting, and starter-config generation. One dependency-free executable, so it is also a config probe for shell scripts, Makefiles, and CI.

Reads are typed at the call site exactly as they are in code, and a fallback is one option away:

~~~console
$ shcl get --int server.shcl workers
4

$ shcl get --int --default=8 server.shcl thread-pool     # absent from the file
8

$ shcl get server.shcl 'site(example.com).tls.cert'
/etc/ssl/example.pem
~~~

Repeated fields are queryable as a set, and `(*)` fans one read across every instance:

~~~console
$ shcl count server.shcl site
2

$ shcl instances server.shcl site
example.com
blog.example.com

$ shcl get --array --slots server.shcl 'site(*).tls.hsts'
Good	on
Good	off
~~~

When the keys are the thing you do not know, `children` lists them and `paths` walks the whole file. Each name comes back in the form a path accepts, so it can go straight back into the next read:

~~~console
$ shcl children server.shcl
listen
workers
log-level
site
site
maintenance-page

$ shcl children server.shcl 'site(example.com)'
root
max-upload-mb
methods
tls
~~~

The values `instances` prints are not paths. A number in parens is an index, so with `shard: 1` above `shard: 0`, `shard(1)` reads the second one. `--paths` prints the path that reads each instance instead, and `--json` prints one JSON object per line with the path, value and line together, for `jq` or PowerShell's `ConvertFrom-Json`:

~~~console
$ shcl instances --paths server.shcl site
site(0)
site(1)

$ shcl instances --json server.shcl site
{"path":"site(0)","value":"example.com","line":7}
{"path":"site(1)","value":"blog.example.com","line":17}
~~~

`get`, `children` and `paths` take `--json` too. `paths --json` lists every field, repeats included, and `children --json` adds each child's `name`. The value is always a string, with a line break in it as JSON's `\n`.

`check` is where the forgiving parser shows its hand. Knock the colon off line 3 of that file, and line 3 is all you lose:

~~~console
$ shcl check server.shcl
line 3: Error: E014
line 3: Error: E014 malformed line skipped: unexpected character after the path, at column 9
(run 'shcl explain CODE' for the rule behind a code)
failed: 1 diagnostic(s), 1 error(s)

$ shcl get server.shcl log-level     # the rest of the file loaded fine
line 3: Error: E014 malformed line skipped: unexpected character after the path, at column 9
warn
~~~

Every subcommand that loads the file says what the load dropped, once, on stderr - a read that came back fine is still a file with a line missing. Both streams include the code; only stdout is the contract. The stdout line is `line N: Severity: CODE` and nothing else, so a script can match on `E014` without parsing English, while the stderr line adds the prose for a person reading along. `check` exits 6 when it found errors - enough to gate a build.

Hand it a schema and it validates against that too. A schema is an ordinary `.shcl` file: one `field:` instance per path, constraints written as its children ([the spec](spec.md#schema-validation) has the full vocabulary).

~~~text
field: workers
	type: int
	desc: Worker threads.
	min: 1
	max: 256
	default: 4
	required: yes

field: log-level
	type: string
	desc: How chatty the log is.
	allowed: [debug, info, warn, error]
	default: warn
~~~

That catches wrong types, out-of-range numbers, and unknown fields - and for the last one it names the field you probably meant:

~~~console
$ shcl check --schema=app-schema.shcl app.shcl
line 2: Error: V001
line 2: Error: V001 unknown field 'log-levle'; did you mean 'log-level'?
(run 'shcl explain CODE' for the rule behind a code)
failed: 1 diagnostic(s), 1 error(s)
~~~

A config file can also name its own schema, so `shcl check app.shcl` needs no option and an editor can find it too:

- A line such as this one names it, at the start of a line or indented under a field. The path is read from the file's own directory.

	~~~shcl
	##    Schema   app-schema.shcl
	~~~

- A program finds it the same way with `read_named_schema(text, path)`, the call `check` uses. It hands back the schema's text, or a status saying why not, such as no line, a URL it won't fetch, or a file that is not there.

A broken schema cannot mask a broken config: a fault in the schema itself is reported as its own error (`V090`+), and the constraints that did parse still check the file. The unknown-field sweep keeps running through a broken constraint, since the field is still declared by name. It turns off only when a fault costs a path spelling outright: an unreadable `field:` path, or a mount naming no declared fragment. Only those can turn a declared field into a false unknown. A schema file that does not load at all, say a quote that never closes, is `V099` and nothing is checked against it, from the library and the CLI alike.

The same schema, pointed the other way, writes a starting file for your own users - commented, correctly typed, required fields live and optional ones left commented out:

~~~console
$ shcl init --schema=app-schema.shcl
## Worker threads.
## int, 1-256, required
workers: 4

## How chatty the log is.
## string, one of: debug, info, warn, error
# log-level: warn

##
## This config file format is SHCL.
## "Simple Hierarchical Config Language"
##    Format   3
##    Home     https://github.com/yottacore/shcl
##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md
##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.
##
~~~

Two hashes is what shcl writes its own prose with, one is a setting left commented out - a convention, not a rule, so your users can comment however they like. The block at the bottom tells whoever opens that file later what it is and where the syntax is written down; `--no-banner` leaves it out. `set --write` writes the same block when it creates a file that was not there. Rounding out the verbs, `fmt` normalizes a file and `set` edits one, leaving the lines it did not change as they were. Both write in place with `--write`:

~~~sh
shcl fmt --write server.shcl
shcl set --write server.shcl --set 'workers=8'
~~~

An in-place write is the library's own save, with the same refusal (at its own exit code, 7) when the rewrite would delete lines or values from the file; see [What saving does](#what-saving-does). `--lossy` is the way to say you meant it. Without `--write`, `set` refuses the same way and prints nothing, so `shcl set f ... > f.new && mv f.new f` stops at the same refusal `--write` makes.

A few more verbs round out the CLI. `migrate` rewrites a file written for shcl 2.x under the 3.0 rules, touching only what the two read differently (a comma list, a `*` item, a selector in brackets, a quote that never closed, the old `name:[disc]` spelling) and leaving comments, blank lines and layout as they were; `--write` saves it through the same gate and keeps the original beside it, as `config_backup_20261007-091500_format-v2.shcl` for `config.shcl`, and `--check` names the lines it would change without touching anything. `upgrade` is the same rewrite for a file that no longer loads clean, written out fresh the way `fmt` and `init` would write it, with the same kind of backup. A file that loads clean is left alone, and so is one whose Format line names this format, so a program can run it (or the library's `upgrade_file`) on every start. `--from-2x` says the file was written for 2.x. Then a clean file is made over when it reads differently now, and one naming this format that loads with an error is taken as 2.x, so give it only for a file known to be old. On a file not written for 2.x it can change good lines, and the backup keeps the original. `tokens` prints each line as the parser reads it, span by span, for the times a line is refused and it is not obvious why. Each line is read on its own, so a raw body line comes out as if it were a field line.

If you have files written for 2.x, run `migrate --from-2x` over them once and read what comes back. The flag is not optional politeness: a comma list such as `p: a,b` is written the same way under both rule sets and means two different things, an array then and one string now, so without being told which rules wrote the file, `migrate` leaves those values alone and exits 7 rather than guessing and damaging a file that was already correct. What it rewrites it stamps, so running it twice is safe. Most of what changed at 3.0 is loud, and a file that has it says so the first time it loads. Backslashes are one quiet exception: a backslash pair was an escape in 2.x and is text now. `migrate --from-2x` writes what 2.x read, so `path: "C:\temp\new"` becomes `path: "C:◉TAB◉emp◉NEWLINE◉ew"`, and without the flag that value is left alone at exit 7 too. A raw block's label is another: one holding a `#` ran to the end of the line in 2.x and ends at the `#` now, and `migrate` cannot rewrite that, since a label has no quoting.

`shcl help` covers the rest and `man shcl` says the same at more length; `shcl help get` narrows it to one subcommand, and `shcl explain E019` gives the rule behind a diagnostic code, with `shcl explain` alone listing every code. A typo in a command or an option says what was probably meant. `shcl --about` names the version, license and project home, and `shcl --donate` points at the sponsors page. Tab completion for bash and zsh is included. For calling it from a script, see [Bash](#bash) and [PowerShell](#powershell).

## Example use-cases in your code

Bindings are versioned in lockstep, so `2.x` means the same behavior and the same conformance corpus in every language. Each ecosystem's usual compatible-version operator is all you need: it picks up minor and patch releases on its own, and never crosses a major version without you editing the line yourself.

Every binding is one file with no dependencies. You can optionally just copy it out of `source/` and commit it - see [DIY install](install.md#diy-install).

### Rust

- Install: `cargo add shcl`

- Dependency line: `shcl = "2"`

- Toolchain: Rust 1.88 or newer.

- Note: The Rust crate includes the library and the CLI together. See [Language packages](install.md#language-packages) if the binary is what you are after.

~~~rust
use shcl::{Document, FileStatus, SetStatus, Status};

// One call reads and parses, and never fails: the document comes back usable
// either way, and the status tells missing apart from unreadable and from
// parsed-with-errors - three cases a hand-written load path tends to blur.
let (mut doc, file_status) = Document::load_file("server.shcl");
if file_status == FileStatus::NotFound {
	println!("no config yet - starting from defaults");
}

// Typed read, with a fallback if the path is missing
let workers = doc.get_int("workers").unwrap_or(4);
let root = doc.get_string("site(example.com).root").unwrap_or_default();
println!("serving from {root}");

// Or ask why a read failed, when the difference matters
match doc.get_int("site(example.com).max-upload-mb") {
	Ok(mb) => println!("{mb} MB"),
	Err(Status::NotFound) => println!("not configured"),
	Err(other) => println!("unusable: {other:?}"),
}

// Writes create what they need to: this adds a site and a nested block.
// Each one returns Ok, or why it wrote nothing - a refused write writes
// nothing at all rather than half of it - and the status is `#[must_use]`, so
// that answer cannot go missing by accident.
let st = doc.set_int("workers", workers * 2);
if st != SetStatus::Ok {
	eprintln!("workers: {st:?}");
}
let st = doc.set_bool("site(example.com).tls.hsts", true);
if st != SetStatus::Ok {
	eprintln!("hsts: {st:?}");
}
let st = doc.set_string("site(blog.example.com).root", "/srv/www/blog");
if st != SetStatus::Ok {
	eprintln!("blog root: {st:?}");
}

// Refuses if this write would delete lines or values from the file; see
// "What saving does" below (save_file_lossy is the override).
doc.save_file("server.shcl")?;
~~~

### Go

- Install the module: `go get github.com/yottacore/shcl/source/go/v2`

- Dependency line: `require github.com/yottacore/shcl/source/go/v2 v2.0.0`

- Notes: this repo keeps the Go module in a subdirectory, so the import path ends in `/source/go` and the module's own tags have a matching `source/go/` prefix. From 2.0 the major goes in the path too, as Go requires, so the import ends `/source/go/v2` and `go get -u` tracks `2.x` without ever crossing to a 3.x. A 1.x consumer keeps working on the old path until it edits the import.

~~~go
import shcl "github.com/yottacore/shcl/source/go/v2"

// One call reads and parses, and never fails (see the Rust example).
doc, fileStatus := shcl.LoadFile("server.shcl")
if fileStatus == shcl.FileNotFound {
	fmt.Println("no config yet - starting from defaults")
}

workers := doc.GetIntOr("workers", 4)
root := doc.GetStringOr("site(example.com).root", "")
fmt.Println("serving from", root)

if mb, st := doc.GetInt("site(example.com).max-upload-mb"); st == shcl.Good {
	fmt.Println(mb, "MB")
} else {
	fmt.Println("unusable:", st)
}

// Each setter returns SetOk, or why it wrote nothing: a refused write writes
// nothing at all rather than half of it.
if st := doc.SetInt("workers", workers*2); st != shcl.SetOk {
	fmt.Println("workers:", st)
}
if st := doc.SetBool("site(example.com).tls.hsts", true); st != shcl.SetOk {
	fmt.Println("hsts:", st)
}
if st := doc.SetString("site(blog.example.com).root", "/srv/www/blog"); st != shcl.SetOk {
	fmt.Println("blog root:", st)
}

// Refuses if this write would delete lines or values from the file; see
// "What saving does" below (SaveFileLossy is the override).
if err := doc.SaveFile("server.shcl"); err != nil {
	log.Fatal(err)
}
~~~

### Python

- Install: `pip install shcl`

- Dependency line: `shcl~=2.0`

- Toolchain: Python 3.9 or newer.

- Note: The PyPI distribution is the library module by itself; the `shcl` command comes from a package or an installer.

~~~python
import shcl

# One call reads and parses, and never fails (see the Rust example).
doc, file_status = shcl.Document.load_file("server.shcl")
if file_status is shcl.FileStatus.NotFound:
	print("no config yet - starting from defaults")

workers = doc.get_int("workers", default=4)
root = doc.get_string("site(example.com).root", default="")

read = doc.read_int("site(example.com).max-upload-mb")
if read.status is not shcl.Status.Good:
	print("unusable:", read.status)

# A setter returns Ok, or why it wrote nothing - a refused write writes
# nothing at all rather than half of it. Only Ok is true, so `if not` works
# too.
st = doc.set_int("workers", workers * 2)
if st is not shcl.SetStatus.Ok:
	print("workers:", st)
st = doc.set_bool("site(example.com).tls.hsts", True)
if st is not shcl.SetStatus.Ok:
	print("hsts:", st)
st = doc.set_string("site(blog.example.com).root", "/srv/www/blog")
if st is not shcl.SetStatus.Ok:
	print("blog root:", st)

# Raises SaveRefused if this write would delete lines or values from the
# file; see "What saving does" below (save_file_lossy is the override).
doc.save_file("server.shcl")
~~~

### Zig

Zig needs no binding of its own - it consumes the C header directly. `@cImport` takes the declarations, one C file has the implementation, and thin wrappers let Zig slices supply the pointer-and-length pairs the C API wants:

~~~zig
const std = @import("std");
const c = @cImport(@cInclude("shcl.h"));

// The C API takes (pointer, length) paths; a Zig slice already has both.
fn getIntOr(doc: ?*c.shcl_doc, path: []const u8, def: i64) i64 {
	return c.shcl_get_int_or(doc, path.ptr, path.len, def);
}
fn setInt(doc: ?*c.shcl_doc, path: []const u8, v: i64) bool {
	return c.shcl_set_int(doc, path.ptr, path.len, v) == c.SHCL_SET_OK;
}
fn setBool(doc: ?*c.shcl_doc, path: []const u8, v: bool) bool {
	return c.shcl_set_bool(doc, path.ptr, path.len, @intFromBool(v)) == c.SHCL_SET_OK;
}
fn setString(doc: ?*c.shcl_doc, path: []const u8, v: []const u8) bool {
	return c.shcl_set_string(doc, path.ptr, path.len, v.ptr, v.len) == c.SHCL_SET_OK;
}
fn readString(doc: ?*c.shcl_doc, path: []const u8) c.shcl_read_str {
	return c.shcl_read_string(doc, path.ptr, path.len);
}

// The C file tier loads and saves, so no Zig file IO is involved
var st: c.shcl_file_status = undefined;
const doc = c.shcl_load_file("server.shcl", &st);
defer c.shcl_free(doc);

const workers = getIntOr(doc, "workers", 4);

const root = readString(doc, "site(example.com).root");
if (root.status == c.SHCL_GOOD)
	std.debug.print("{s}\n", .{root.value.p[0..root.value.n]});

_ = setInt(doc, "workers", workers * 2);
_ = setBool(doc, "site(example.com).tls.hsts", true);
_ = setString(doc, "site(blog.example.com).root", "/srv/www/blog");

_ = c.shcl_save_file(doc, "server.shcl", null);
~~~

Alongside it goes an `impl.c` of two lines (`#define SHCL_IMPLEMENTATION`, then `#include "shcl.h"`); build with `zig build-exe main.zig impl.c -lc -lm -I.`. Letting the C file tier do the loading and saving keeps Zig's own standard library out of it, which matters here because that library still moves between releases while this interop does not; checked on 0.16.

### C, C++

C and C++ have no registry worth targeting. `shcl.h` is a single dependency-free header: copy it into your tree from a release tag and pin that tag, or take it from an installed package under `/usr/share/shcl/code/`. Define `SHCL_IMPLEMENTATION` in exactly one translation unit, put the header above your own system includes, and link `-lm`. C++ has its own interface in `shcl.hpp`, shown after the C example.

- Install: vendor `shcl.h`

- Dependency line: pin the release tag

~~~c
// shcl.h asks for a POSIX level for its file tier, and a feature request only
// counts before the first system header, so it goes above your own includes.
#define SHCL_IMPLEMENTATION   // in exactly one translation unit
#include "shcl.h"
#include <stdio.h>
#include <string.h>

#define P(s) s, strlen(s)     // paths take a pointer and a length, not a NUL terminator

// One call reads and parses, and never fails (see the Rust example).
// shcl_parse takes text you already hold.
shcl_file_status st;
shcl_doc *doc = shcl_load_file("server.shcl", &st);
if (st == SHCL_FILE_NOT_FOUND)
	puts("no config yet - starting from defaults");

int64_t workers = shcl_get_int_or(doc, P("workers"), 4);

// Strings keep the status tier, so missing and empty stay distinguishable
shcl_read_str root = shcl_read_string(doc, P("site(example.com).root"));
if (root.status == SHCL_GOOD)
	printf("%.*s\n", (int)root.value.n, root.value.p);

// A setter returns SHCL_SET_OK, or why it wrote nothing - a refused write
// writes nothing at all rather than half of it. SHCL_SET_OK is 0, so compare
// with it: a bare `!` would read a refusal as success.
shcl_set_status ss = shcl_set_int(doc, P("workers"), workers * 2);
if (ss != SHCL_SET_OK)
	fprintf(stderr, "workers: %s\n", shcl_set_status_name(ss));
ss = shcl_set_bool(doc, P("site(example.com).tls.hsts"), 1);
if (ss != SHCL_SET_OK)
	fprintf(stderr, "hsts: %s\n", shcl_set_status_name(ss));
ss = shcl_set_string(doc, P("site(blog.example.com).root"), P("/srv/www/blog"));
if (ss != SHCL_SET_OK)
	fprintf(stderr, "blog root: %s\n", shcl_set_status_name(ss));

// SHCL_SAVE_REFUSED means this write would delete lines or values from the
// file; see "What saving does" below (shcl_save_file_lossy is the override).
shcl_write_status why;
shcl_save_result saved = shcl_save_file(doc, "server.shcl", &why);
if (saved == SHCL_SAVE_REFUSED)
	fprintf(stderr, "not saved: it would drop lines\n");
else if (saved == SHCL_SAVE_FAILED)
	fprintf(stderr, "could not save: %s\n", shcl_write_status_name(why));

shcl_free(doc);   // frees the document and everything handed out from it
~~~

The C binding uses `round()`, so link the math library - `cc -std=c11 -O2 ex.c -o ex -lm`. There are no per-object frees: reads hand back pointers into the document's arena, and the single `shcl_free` releases all of it, so anything you need afterwards must be copied out first. A long-running process has two optional calls for a document it keeps: `shcl_reads_release` gives back what the reads have handed out, and `shcl_compact` gives back what repeated writes left behind. The `_to` read forms, such as `shcl_read_string_array_to`, copy into a buffer you pass and leave nothing behind. The file calls are an optional companion: `-DSHCL_NO_FILE_IO` compiles them out for an embedded target, leaving `shcl_parse` and `shcl_to_canonical` to work on text you hold yourself.

C++ adds `shcl.hpp` beside `shcl.h`. It has the same calls as the other bindings, in std types, and runs the C core inside without showing any of it. The implementation goes in a file of its own, with nothing else in it:

~~~cpp
// impl.cpp: the one file that builds the library.
#define SHCL_IMPLEMENTATION
#include "shcl.hpp"
~~~

Everywhere else, include `shcl.hpp` wherever you like:

~~~cpp
#include "shcl.hpp"
#include <cstdio>

// One call reads and parses, and never fails (see the Rust example).
auto [doc, st] = shcl::Document::load_file("server.shcl");
if (st == shcl::FileStatus::NotFound)
	std::puts("no config yet - starting from defaults");

auto workers = doc.get_or<std::int64_t>("workers", 4);

// Strings keep the status tier, so missing and empty stay distinguishable
auto root = doc.read_string("site(example.com).root");
if (root.status == shcl::Status::Good)
	std::printf("%s\n", root.value.c_str());

// A setter returns Ok, or why it wrote nothing, and is nodiscard
auto ss = doc.set_int("workers", workers * 2);
if (ss != shcl::SetStatus::Ok)
	std::fprintf(stderr, "workers: %s\n", shcl::to_string(ss));
ss = doc.set_bool("site(example.com).tls.hsts", true);
if (ss != shcl::SetStatus::Ok)
	std::fprintf(stderr, "hsts: %s\n", shcl::to_string(ss));
ss = doc.set_string("site(blog.example.com).root", "/srv/www/blog");
if (ss != shcl::SetStatus::Ok)
	std::fprintf(stderr, "blog root: %s\n", shcl::to_string(ss));

// Refused means this write would delete lines or values from the file; see
// "What saving does" below (save_file_lossy is the override).
if (doc.save_file("server.shcl") != shcl::SaveResult::Ok)
	std::fprintf(stderr, "could not save\n");
~~~

Build with `c++ -std=c++17 -O2 main.cpp impl.cpp -o ex -lm`. The `Document` frees itself, and every read comes back as a copy, so nothing handed out depends on the document living on.

### Bash

Scripts call the `shcl` binary directly. It is the parser, so a script gets the same answers as every binding. A typed read is `get` with a type option, and the value comes back on stdout.

- Install: install the CLI, see [Installation](install.md)

- Dependency line: n/a - scripts call the CLI

~~~bash
workers=$(shcl get --int --default=4 server.shcl workers)
root=$(shcl get --default='' server.shcl 'site(example.com).root')
maxUpload=$(shcl get --size server.shcl 'site(example.com).Max-Upload-MB')   # 52428800, in bytes

# Repeatable, applied in order; --write rewrites the file in place.
shcl set --write server.shcl \
    --set "workers=$((workers * 2))" \
    --set 'site(example.com).tls.hsts=true' \
    --set-literal 'cluster.hosts=[a.example.com, b.example.com]'
~~~

A missing value with no `--default`, or one that isn't the type asked for, exits nonzero and says why on stderr. Stdout still gets the type's zero, such as `0`, `false` or an empty line, so check the exit code rather than the value.

The two spellings differ in how the value is read. `--set` takes **data**: its type follows the text, so `workers=8` writes an integer, but a bracket or a comma in it is content - `hosts=[a, b]` would store one quoted string. `--set-literal` takes **value syntax**, the way a file writes it, so that same text writes a two-element array. Reach for it whenever the value is not a plain scalar.

Removal and defaults have option forms too - `--remove=PATH`, `--set-default=PATH=VALUE`, `--set-literal-default=PATH=TEXT`, where a default fills a field that is missing or empty - and all five share one ordered list, so two options touching the same path resolve in the order given. A remove takes every field its path reaches, each instance of a repeated name and each wildcard match. Raw blocks are the one edit with no option form; those go in as a write-ops script on stdin, one op per line, fields separated by a literal tab:

~~~bash
shcl set --write server.shcl <<OPS
remove	site(old.example.com)
raw	motd		Welcome.
OPS
~~~

A tab or line break inside an op value goes in as `◉TAB◉` or `◉NEWLINE◉`, the same escapes a file uses, and a backslash is text.

Lists come back one item per line. When a script needs more than a name, `--json` gives each item as one JSON object, and `--paths` gives each instance a path that reads only it:

~~~bash
shcl paths --json server.shcl | jq -r '"\(.line)\t\(.path) = \(.value)"'

for site in $(shcl instances --paths server.shcl site); do
    echo "${site}: $(shcl get server.shcl "${site}.root")"
done
~~~

### PowerShell

The same reads, calling `shcl` directly. Quote a path that has a selector in it. Unquoted, PowerShell runs what is inside the parentheses as a command.

~~~powershell
$workers   = [int](shcl get --int --default=4 server.shcl workers)
$root      = shcl get --default='' server.shcl 'site(example.com).root'
$maxUpload = [long](shcl get --size server.shcl 'site(example.com).Max-Upload-MB')

shcl set --write server.shcl `
         --set "workers=$($workers * 2)" `
         --set 'site(example.com).tls.hsts=true' `
         --set-literal 'cluster.hosts=[a.example.com, b.example.com]'
~~~

The op-script form works here too, piped in:

~~~powershell
$ops = "remove`tsite(old.example.com)",
       "raw`tmotd`t`tWelcome."
$ops | shcl set --write server.shcl
~~~

`--json` output is one object per line, which `ConvertFrom-Json` takes as it comes:

~~~powershell
$sites = shcl instances --json server.shcl site | ConvertFrom-Json
foreach ($site in $sites) {
	"$($site.path) on line $($site.line): $(shcl get server.shcl "$($site.path).root")"
}
~~~

PowerShell 7 turns a value that looks like a date into a `DateTime`. On 7.5 and later, `ConvertFrom-Json -DateKind String` keeps it as the text in the file.

`$LASTEXITCODE` has the exit code after each call. Windows PowerShell 5.1 reads a native command's output in the console's code page, so set `[Console]::OutputEncoding = [Text.Encoding]::UTF8` before reading a value that isn't plain ASCII. To pipe non-ASCII text in on 5.1, also set `$OutputEncoding = [Text.UTF8Encoding]::new($false)`, which leaves out the byte-order mark.

### What saving does

Three behaviors of the write half are easy to miss, and they are the same in every binding.

Setters build whatever is missing along the path, so the `tls.hsts` and `blog.example.com` lines in the examples above arrive as a nested block and a new site instance without you assembling either.

And saving rewrites the file in canonical form: spacing normalized, field names lowercased, the dotted `site(blog.example.com).tls.hsts` line folded into the block form it was always spelling. **Your comments stay attached** to whatever they documented, including the one that travels with that folded line:

~~~~text
# Flat, TOML-style settings
listen: "0.0.0.0:443"
workers: 8
log-level: warn

# Hierarchy when you need it: one instance per site
site: example.com
	root: /srv/www/example
	max-upload-mb: 50
	methods: [GET, POST, HEAD]
	tls:
		cert: /etc/ssl/example.pem
		hsts: true

# Repeating the field adds another site - arrays of objects
# no syntax to invent
site: blog.example.com
	root: /srv/www/blog
	tls:

		# Dotted paths give the same tree; add to any instance from anywhere
		hsts: off

# Multi-line content goes in a fenced block, kept verbatim
maintenance-page:
	~~~html
	<h1>Down for maintenance - back in five.</h1>
	~~~
~~~~

That is the whole file after the edits, not an excerpt - a formatter that can survive a round trip through an editing tool is the point.

A file somebody keeps by hand can be saved the way they keep it instead. Load it with `parse_keep_lines` or `load_file_keep_lines`, and save with `save_file_keep_lines`. Each line the edits did not touch comes back byte for byte, a changed value is written into its own line, and a new line takes the indent of the lines around it. The text has to load back as the same document, with no new error. Where it would not, as after a merge, or a child added under a flat dotted line, the save writes the canonical form and returns false, so the program knows which one it got. A line the load dropped comes back as written too, so this save refuses only when it would write the canonical form. `shcl set` saves this way; `shcl fmt` is the canonical one.

And the save protects the file it is overwriting. It goes through a temp file in the same directory plus a rename, so an interrupted save cannot leave a truncated config behind, and a linked-in config is written through rather than replaced. It also refuses when the write would delete lines or values from the file. A line the parser cannot read at all is kept verbatim and survives the save untouched. A line it could read and not place (a stray indent, an impossible selector) has no safe spelling to re-emit. That one counts into `lost_count()`, and the save stops rather than quietly dropping a line somebody typed. `save_file_lossy` is there for when deleting it is what you actually want, so it is always a stated choice.

A save that fails says why as a value, beside its message: `NotFound` when the folder isn't there, `PermissionDenied`, `DiskFull`, `ReadOnly`, `IsDirectory` and a couple more, so a program can tell them apart without reading the text. The same goes for `write_file_atomic` and `upgrade_file`. In C it comes back through the last argument, which may be NULL.

A setter returns a status, `Ok` when the write applied. Anything else means it wrote nothing at all, and names why. Either the path is the problem, or what the write would put there is, and when both are the path's reason is the one you get. Wildcards are the usual path reason (`Wildcard`), since those are query-only. Another is a path that matches more than one field (`Multiple`), such as `port` in a file with two `port` lines, since the read after the write would not know which one you meant either. `port(0)` or `site(1).root` picks one. A value reason names what was wrong with it: `NotFinite` for a NaN, `BadComment` for comment text with a line break, `NotOneValue` for `set_literal` text like `a, b`, and so on. `check_set_path(path)` checks the path alone, without writing. The whole list is in the [spec](spec.md), under the Writer.

Check that answer rather than assuming it: an ignored refusal means the save that follows writes a config missing the edit, adn reports success doing it. In Rust the status is `#[must_use]`, so dropping it is a compile warning. In C `SHCL_SET_OK` is 0, so compare with it, since a bare `!` reads a refusal as success.

One read-side companion belongs with this: canonical output lowercases field names, and `authored_name(path)` hands back the spelling the author actually used. It is what you want in a message about their file - reporting `Max-Upload-MB` as `max-upload-mb` reads like a different setting to the person who wrote it.
