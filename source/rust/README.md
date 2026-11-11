<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
# shcl

**S**imple **H**ierarchical **C**onfig **L**anguage. Forgiving to write, predictable to read.

Values are stored as plain text and coerced only when *your* code asks for a type, so `NO` in a config file never silently turns into `false`. A bad line is skipped or repaired with a diagnostic instead of taking down the whole file.

This crate is the reference implementation. A shared conformance corpus checks the independent Go, Python, and C bindings byte-for-byte against it.

## Install

~~~sh
cargo add shcl
~~~

The crate has zero dependencies, and it also includes the CLI:

~~~sh
cargo install shcl
~~~

## Use

~~~rust
use shcl::{Document, FileStatus, SetStatus};

// Reads and parses in one call, and never fails: the document is usable
// either way, and the status separates missing from unreadable from
// parsed-with-errors.
let (mut doc, file_status) = Document::load_file("server.shcl");
if file_status == FileStatus::NotFound {
	eprintln!("no config yet - using defaults");
}

// One call, a typed value, a visible fallback at the call site.
let limit = doc.get_int_or("site(example.com).max-upload-mb", 10);

// Or ask why a read failed: Good, Empty, NotFound, BadType, Multiple, BadPath.
let r = doc.read_int("site(example.com).max-upload-mb");
if !r.ok() {
	eprintln!("{:?} (raw text was {:?})", r.status, r.raw);
}

// Wildcards read across instances, with a status per slot.
let roots = doc.read_string_array("site(*).root");

// Writes through a temp file and a rename, so an interrupted save cannot
// truncate the config - and refuses if this write would delete lines or values
// from the file (save_file_lossy is the override), if another program
// changed the file since the load (force in save_file_with's SaveOptions), or
// if the file names a newer format than this reader's (newer_format).
// A setter returns Ok, or why it wrote nothing at all, and the status is
// #[must_use].
let st = doc.set_int("site(example.com).max-upload-mb", limit * 2);
if st != SetStatus::Ok {
	eprintln!("not written: {st:?}");
}
doc.save_file("server.shcl").unwrap();
~~~

`Document::parse` never fails, and neither does `load_file`. When you want a hard error instead, use `Document::parse_with(&text, Strictness::Strict)` or `load_file_with(path, Strictness::Strict)`.

The library also has `merge` for layered config, such as defaults, then site, then user. `validate` checks a document against a schema, which is itself a SHCL file. There's also a full writer, and a canonical formatter that preserves comments.

## Compatibility

Bindings are versioned in lockstep, so `3.x` is the same behavior in every language. `shcl = "3"` picks up minor and patch releases on its own and never crosses a major version. It skips a beta, though, so name this one exactly: `shcl = "3.0.0-beta1"`.

## Docs

The language spec, the formal grammar, and the other bindings are at <https://github.com/yottacore/shcl>.

## License

The license is MIT. SHCL™ is a trademark of Jim Collier. See the [trademark policy](https://github.com/yottacore/shcl/blob/main/trademark.md).
