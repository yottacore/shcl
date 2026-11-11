<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Usage and examples

This page shows the `shcl` command from a shell first, then the library from code. Every example here reads `server.shcl`, which is the small web server config that the README shows under [What a .shcl file looks like](../README.md#what-a-shcl-file-looks-like). The line numbers in the output are that file's.

This page describes 3.0.0-beta1. It's a beta. The newest full release is still 2.0.0, which reads files by the 2.x rules. Package managers skip a beta unless it's named, so the install and dependency lines below name it.

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

The `shcl` binary does everything the library does, from a shell. That includes typed reads, edits, validation, formatting, and generating a starter config. It's one executable with no dependencies, so it's also a config probe for shell scripts, Makefiles, and CI.

Reads are typed at the call site the same as in code, and a fallback is one option away:

~~~console
$ shcl get --int server.shcl workers
4

$ shcl get --int --default=8 server.shcl thread-pool     # absent from the file
8

$ shcl get server.shcl 'site(example.com).tls.cert'
/etc/ssl/example.pem
~~~

Repeated fields can be queried as a set, and `(*)` runs one read over every instance:

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

When you don't know the keys, `children` lists them and `paths` walks the whole file. Each name comes back in the form a path accepts, so it can go into the next read as is:

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

The values `instances` prints aren't paths. A number in parens is an index, so with `shard: 1` above `shard: 0`, `shard(1)` reads the second one. `--paths` prints the path that reads each instance instead. `--json` prints one JSON object per line with the path, value, and line together, for `jq` or PowerShell's `ConvertFrom-Json`:

~~~console
$ shcl instances --paths server.shcl site
site(0)
site(1)

$ shcl instances --json server.shcl site
{"path":"site(0)","value":"example.com","line":7}
{"path":"site(1)","value":"blog.example.com","line":17}
~~~

`get`, `children`, and `paths` take `--json` too. `paths --json` lists every field including the repeats, and `children --json` adds each child's `name`. The value is always a string, and a line break in it comes out as JSON's `\n`.

`check` shows how forgiving the parser is. Knock the colon off line 3 of that file, and line 3 is all you lose:

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

Every subcommand that loads the file prints what the load dropped to stderr, once. A read that came back fine still came from a file with a line missing. Both streams include the code, but only stdout is the contract. The stdout line is `line N: Severity: CODE` and nothing else, so a script can match on `E014` without parsing English. The stderr line adds a message for a person to read. `check` exits 6 when it finds errors, so a build can gate on it.

Hand it a schema and it validates against that too. A schema is an ordinary `.shcl` file with one `field:` instance per path, and the constraints are written as its children. [The spec](spec.md#schema-validation) has the full vocabulary.

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

A schema catches wrong types, out-of-range numbers, and unknown fields. For an unknown field it names the one you probably meant:

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

- A program finds it the same way with `read_named_schema(text, path)`, which is the call `check` uses. It returns the schema's text, or a status that says why not, such as no line, a URL it won't fetch, or a file that isn't there.

A broken schema can't hide a broken config. A fault in the schema itself is reported as its own error in the `V090`+ range, and the constraints that did parse still check the file. The unknown-field sweep keeps running through a broken constraint, since the field is still declared by name. The sweep turns off only when a fault loses a path entirely, which happens with an unreadable `field:` path or a mount that doesn't name any declared fragment. Only those 2 faults can make a declared field look unknown. A schema file that doesn't load at all, such as one with a quote that never closes, is `V099`. Nothing is checked against it then, in the library or the CLI.

`shcl init` turns the same schema into a starting file for your own users. Fields are commented and correctly typed, and required fields are live while optional ones are left commented out:

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

Comments that shcl writes itself start with 2 hashes, and a setting left commented out starts with one. That's a convention rather than a rule, so your users can comment however they like. The block at the bottom says what the file is and where the syntax is written down, for whoever opens it later, and `--no-banner` leaves it out. `set --write` writes the same block when it creates a file that wasn't there. `fmt` normalizes a file, and `set` edits one and leaves the lines it didn't change as they were. Both write in place with `--write`:

~~~sh
shcl fmt --write server.shcl
shcl set --write server.shcl --set 'workers=8'
~~~

An in-place write goes through the library's own save. It refuses when the rewrite would delete lines or values from the file, and exits 7. See [What saving does](#what-saving-does). Pass `--lossy` to say you meant it. Without `--write`, `set` refuses the same way and prints nothing, so `shcl set f ... > f.new && mv f.new f` stops at the same refusal that `--write` does.

The CLI has a few more verbs. `migrate` rewrites a file written for shcl 2.x under the 3.0 rules. It changes only the things the 2 versions read differently, and leaves comments, blank lines, and layout as they were. Those things are a comma list, a `*` item, a selector in brackets, a quote that never closed, and the old `name:[disc]` syntax. `--write` saves the result through the same gate and keeps the original beside it, as `config_backup_20261007-091500_format-v2.shcl` for `config.shcl`. `--check` names the lines it would change and doesn't touch anything.

`upgrade` does the same rewrite for a file that no longer loads clean. It writes the file out fresh, with each line where it was plus the info block that `init` writes, and makes the same kind of backup. A file that loads clean is left alone, and so is one whose Format line names this format, so a program can run `upgrade` or the library's `upgrade_file` on every start. `--from-2x` says the file was written for 2.x. With it, a clean file is rewritten when it reads differently now, and a file that names this format but loads with an error is taken as 2.x. So give it only for a file you know is old. On a file that wasn't written for 2.x it can change good lines, though the backup keeps the original.

`tokens` prints each line span by span as the parser reads it, for when a line is refused and the reason isn't obvious. Each line is read on its own, so a raw body line comes out as if it were a field line.

If you have files written for 2.x, run `migrate --from-2x` over them once and read what comes back. The flag is there because a comma list such as `p: a,b` is written the same way under both rule sets but means 2 different things. It was an array then, and it's one string now. So when `migrate` isn't told which rules wrote the file, it leaves those values alone and exits 7 rather than guessing and damaging a file that was already correct. It stamps what it rewrites, so running it twice is safe. Most of what changed at 3.0 is loud, and it shows up as a diagnostic the first time such a file loads. Backslashes are one quiet exception, because a backslash pair was an escape in 2.x and is text now. `migrate --from-2x` writes what 2.x read, so `path: "C:\temp\new"` becomes `path: "C:◉TAB◉emp◉NEWLINE◉ew"`, and without the flag that value is left alone at exit 7 too. A raw block's label is another. In 2.x a label with a `#` in it ran to the end of the line, but now it ends at the `#`. `migrate` can't rewrite that, since a label has no quoting.

`shcl help` lists the rest, and `man shcl` says the same at more length. `shcl help get` narrows it to one subcommand. `shcl explain E019` gives the rule behind a diagnostic code, and `shcl explain` alone lists every code. When a command or an option has a typo, shcl says what was probably meant. `shcl --about` prints the version, license, and project home, and `shcl --donate` points at the sponsors page. Tab completion for bash and zsh is included. For calling it from a script, see [Bash](#bash) and [PowerShell](#powershell).

## Example use-cases in your code

The bindings are versioned together, so `3.x` means the same behavior and the same conformance corpus in every language. Each ecosystem's usual compatible-version operator is all you need. It picks up minor and patch releases on its own, and it won't cross a major version unless you edit the line yourself.

Every binding is one file with no dependencies. You can optionally just copy it out of `source/` and commit it - see [DIY install](install.md#diy-install).

### Rust

- Install: `cargo add shcl@3.0.0-beta1`

- Dependency line: `shcl = "3.0.0-beta1"`

- Toolchain: Rust 1.88 or newer.

- Note: The Rust crate includes the library and the CLI together. See [Language packages](install.md#language-packages) if the binary is what you're after.

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
let workers = doc.get_int_or("workers", 4);
let root = doc.get_string_or("site(example.com).root", String::new());
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

- Install the module: `go get github.com/yottacore/shcl/source/go/v3@v3.0.0-beta1`

- Dependency line: `require github.com/yottacore/shcl/source/go/v3 v3.0.0-beta1`

- Notes: the Go module is in a subdirectory of this repo, so the import path ends in `/source/go` and the module's own tags have a matching `source/go/` prefix. Since 2.0 the major version goes in the path too, because Go requires it. So the import ends `/source/go/v3`, and `go get -u` tracks `3.x` and never crosses to a 4.x. A 2.x consumer keeps working on the old path until it edits the import.

~~~go
import shcl "github.com/yottacore/shcl/source/go/v3"

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

- Install: `pip install --pre shcl`

- Dependency line: `shcl==3.0.0b1`

- Toolchain: Python 3.9 or newer.

- Note: The PyPI distribution is only the library module. The `shcl` command comes from a package or an installer.

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

Zig doesn't need a binding of its own, since it uses the C header directly. `@cImport` takes the declarations, one C file has the implementation, and thin wrappers let Zig slices supply the pairs of pointer and length that the C API wants:

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

Next to it goes an `impl.c` with 2 lines, `#define SHCL_IMPLEMENTATION` and then `#include "shcl.h"`. Build with `zig build-exe main.zig impl.c -lc -lm -I.`. The C file tier does the loading and saving, so Zig's own standard library stays out of it. That library still changes between releases, but this interop doesn't. This example was checked on 0.16.

### C, C++

C and C++ don't have a registry worth targeting. `shcl.h` is a single header with no dependencies. Copy it into your tree from a release tag and pin that tag, or take it from an installed package under `/usr/share/shcl/code/`. Define `SHCL_IMPLEMENTATION` in exactly one translation unit, put the header above your own system includes, and link `-lm`. C++ has its own interface in `shcl.hpp`, which is shown after the C example.

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

The C binding uses `round()`, so link the math library, as in `cc -std=c11 -O2 ex.c -o ex -lm`. There aren't any per-object frees. Reads return pointers into the document's arena, and the single `shcl_free` releases all of it, so anything you need afterward has to be copied out first. A long-running process has 2 optional calls for a document it keeps open. `shcl_reads_release` frees what the reads have handed out, and `shcl_compact` frees what repeated writes left behind. The `_to` read forms, such as `shcl_read_string_array_to`, copy into a buffer you pass and don't leave anything behind. The file calls are optional. `-DSHCL_NO_FILE_IO` compiles them out for an embedded target, and then `shcl_parse` and `shcl_to_canonical` work on text you already have.

C++ adds `shcl.hpp` beside `shcl.h`. It has the same calls as the other bindings with std types, and the C core runs inside it without being exposed. The implementation goes in its own file with nothing else in it:

~~~cpp
// impl.cpp: the one file that builds the library.
#define SHCL_IMPLEMENTATION
#include "shcl.hpp"
~~~

Every other file includes `shcl.hpp` as usual:

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

Build with `c++ -std=c++17 -O2 main.cpp impl.cpp -o ex -lm`. The `Document` frees itself, and every read comes back as a copy, so nothing it hands out depends on the document staying alive.

### Bash

Scripts call the `shcl` binary directly. The binary is the parser, so a script gets the same results as every binding. A typed read is `get` with a type option, and the value comes back on stdout.

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

A read of a missing value with no `--default`, or of one that isn't the type asked for, exits nonzero and says why on stderr. Stdout still gets the type's zero, such as `0`, `false`, or an empty line, so check the exit code rather than the value.

The two spellings differ in how the value is read. `--set` takes **data**, and its type follows the text, so `workers=8` writes an integer. A bracket or a comma in it is content, though, so `hosts=[a, b]` would store one quoted string. `--set-literal` takes **value syntax**, as it's written in a file, so that same text writes an array of 2 elements. Use it whenever the value isn't a plain scalar.

Removal and defaults have option forms too, which are `--remove=PATH`, `--set-default=PATH=VALUE`, and `--set-literal-default=PATH=TEXT`. A default fills a field that's missing or empty. All 5 options share one ordered list, so 2 options that touch the same path are applied in the order given. A remove takes every field its path matches, including each instance of a repeated name and each wildcard match. Raw blocks are the one edit without an option form. They go in as a write-ops script on stdin, with one op per line and the fields separated by a literal tab:

~~~bash
shcl set --write server.shcl <<OPS
remove	site(old.example.com)
raw	motd		Welcome.
OPS
~~~

A tab or line break inside an op value goes in as `◉TAB◉` or `◉NEWLINE◉`, which are the same escapes a file uses. A backslash is text.

Lists come back one item per line. When a script needs more than a name, `--json` gives each item as one JSON object, and `--paths` gives each instance a path that reads only it:

~~~bash
shcl paths --json server.shcl | jq -r '"\(.line)\t\(.path) = \(.value)"'

for site in $(shcl instances --paths server.shcl site); do
    echo "${site}: $(shcl get server.shcl "${site}.root")"
done
~~~

### PowerShell

PowerShell does the same reads by calling `shcl` directly. Quote a path that has a selector in it. If it isn't quoted, PowerShell runs what's inside the parentheses as a command.

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

A few behaviors of the write half are easy to miss, and they're the same in every binding.

Setters build whatever is missing along the path, so the `tls.hsts` and `blog.example.com` lines in the examples above are written as a nested block and a new site instance, and you don't have to build either one.

Saving rewrites the file in canonical form. Spacing is normalized, field names are lowercased, and the dotted `site(blog.example.com).tls.hsts` line is folded into the block form it always meant. **Your comments stay attached** to whatever they documented, including the one that moves with that folded line:

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

That's the whole file after the edits rather than an excerpt, since the point is a formatter that survives a round trip through an editing tool.

A file somebody keeps by hand can be saved the way they keep it instead. Load it with `parse_keep_lines` or `load_file_keep_lines`, and save with `save_file_keep_lines`. Each line the edits didn't touch comes back byte for byte, a changed value is written into its own line, and a new line takes the indent of the lines around it. The text has to load back as the same document without any new error. Where it wouldn't, such as after a merge or after a child is added under a flat dotted line, the save writes the canonical form and returns false, so the program knows which one it got. A line the load dropped comes back as written too, so this save refuses only when it would write the canonical form. `shcl set` saves this way, and `shcl fmt` saves the canonical way.

The save also protects the file it's overwriting. It writes a temp file in the same directory and then renames it, so an interrupted save can't leave a truncated config behind, and a linked-in config is written through rather than replaced. It also refuses when the write would delete lines or values from the file. A line the parser can't read at all is kept verbatim and survives the save untouched. A line it could read but couldn't place, such as a stray indent or an impossible selector, doesn't have any safe text to write back. That line counts toward `lost_count()`, and the save stops rather than dropping a line somebody typed. `save_file_lossy` is for when you do want to delete it, so deleting is always a stated choice.

The save also refuses to write over another program's edit. A document from `load_file` stores the text it read, and a save first reads what's at the path and checks that it's that text, or what the last save wrote. When it isn't, the save doesn't write anything and returns `SaveError::Changed` in Rust, `*SaveChanged` in Go, `SaveChanged` in Python, or `SHCL_SAVE_CHANGED` in C. Load again and redo the edit, or save with `force` set in the options to `save_file_with` when you mean to replace it. The same goes for a file the document never read, so a save-as over an existing file needs `force`, the way an editor asks first. Where nothing is at the path, the save writes, so a save-as to a new name works, and so does a save after the file was deleted. A document from `parse` can be saved where nothing is yet, or over a file it saved itself.

The same options can make a save that only creates. With `create` set, a save refuses when anything is already at the path, doesn't write anything, and returns `SaveError::Exists` in Rust, `*SaveExists` in Go, `SaveExists` in Python, or `SHCL_SAVE_EXISTS` in C. When 2 programs save the same new file at once, they get one file and one refusal, and neither one overwrites the other. `mode` sets the exact permission bits on a file that the save creates, so a file with tokens in it can start out at `0600` whatever the umask is. A file that's already there keeps its own mode either way.

When a file was written for a newer format than this version of shcl reads, it loads with an `H006` hint, and reads and edits work as usual. A save won't write it, though, since that would write each line by this version's rules. `newer_format()` returns true for it, and every save refuses without writing anything, wherever it goes. The refusal is `SaveError::TooNew` in Rust, `*SaveTooNew` in Go, `SaveTooNew` in Python, and `SHCL_SAVE_TOO_NEW` in C. It can't be overridden by any option. `shcl fmt --write` and `shcl set` refuse it at exit 7.

A save that fails returns why as a value, along with its message. The values include `NotFound` when the folder isn't there, `PermissionDenied`, `DiskFull`, `ReadOnly`, `IsDirectory`, and a couple more, so a program can tell them apart without reading the text. `write_file_atomic` and `upgrade_file` do the same. In C the value comes back through the last argument, which may be NULL.

A setter returns a status, which is `Ok` when the write applied. Any other status means it didn't write anything, and it names why. Either the path is the problem or what the write would put there is, and when both are, you get the path's reason. The usual path reason is `Wildcard`, since wildcards are only for queries. Another is `Multiple`, for a path that matches more than one field, such as `port` in a file with 2 `port` lines. The read after the write wouldn't know which one you meant either. `port(0)` or `site(1).root` picks one. A value reason names what was wrong with the value, such as `NotFinite` for a NaN, `BadComment` for comment text with a line break, and `NotOneValue` for `set_literal` text like `a, b`. `check_set_path(path)` checks the path alone without writing. The whole list is in the [spec](spec.md), under the Writer.

Check that status rather than assuming it. If a refusal is ignored, the save that follows writes a config missing the edit, adn reports success doing it. In Rust the status is `#[must_use]`, so dropping it is a compile warning. In C `SHCL_SET_OK` is 0, so compare with it, since a bare `!` reads a refusal as success.

There's one read call that belongs with these. Canonical output lowercases field names, and `authored_name(path)` returns the name as the author wrote it. Use it in a message about their file, since reporting `Max-Upload-MB` as `max-upload-mb` reads like a different setting to the person who wrote it.
