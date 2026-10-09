# shcl

**S**imple **H**ierarchical **C**onfig **L**anguage. Forgiving to write, predictable to read.

Values are stored as plain text and coerced only when *your* code asks for a type, so a config file can never silently decide that `NO` means `false`. A bad line is skipped or repaired with a diagnostic instead of taking down the whole file.

This crate is the reference implementation. Independent Go, Python, and C bindings are held byte-for-byte against it by a shared conformance corpus.

## Install

~~~sh
cargo add shcl
~~~

Zero dependencies. The crate also includes the CLI:

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
let limit = doc.get_int("site(example.com).max-upload-mb").unwrap_or(10);

// Or ask why a read failed: Good, Empty, NotFound, BadType, Multiple, BadPath.
let r = doc.read_int("site(example.com).max-upload-mb");
if !r.ok() {
	eprintln!("{:?} (raw text was {:?})", r.status, r.raw);
}

// Wildcards read across instances, with a status per slot.
let roots = doc.read_string_array("site(*).root");

// Writes through a temp file and a rename, so an interrupted save cannot
// truncate the config - and refuses if this write would delete lines or values
// from the file (save_file_lossy is the override).
// A setter returns Ok, or why it wrote nothing at all, and the status is
// #[must_use].
let st = doc.set_int("site(example.com).max-upload-mb", limit * 2);
if st != SetStatus::Ok {
	eprintln!("not written: {st:?}");
}
doc.save_file("server.shcl").unwrap();
~~~

`Document::parse` never fails, and neither does `load_file`. When you want a hard error instead, use `Document::parse_with(&text, Strictness::Strict)` or `load_file_with(path, Strictness::Strict)`.

Also here: `merge` for layered config (defaults, site, user), `validate` against a schema that is itself a SHCL file, a full writer, and a canonical formatter that preserves comments.

## Compatibility

Bindings are versioned in lockstep, so `2.x` is the same behavior in every language. `shcl = "2"` picks up minor and patch releases on its own and never crosses a major version.

## Docs

Language spec, formal grammar, and the other bindings: <https://github.com/yottacore/shcl>

## License

MIT. SHCL™ is a trademark of Jim Collier - see the [trademark policy](https://github.com/yottacore/shcl/blob/main/trademark.md).
