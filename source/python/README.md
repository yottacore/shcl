<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
# shcl

**S**imple **H**ierarchical **C**onfig **L**anguage. Forgiving to write, predictable to read.

Values are stored as plain text and coerced only when *your* code asks for a type, so a config file can never silently decide that `NO` means `false`. A bad line is skipped or repaired with a diagnostic instead of taking down the whole file.

It uses only the standard library, and it's one module without any dependencies. A shared conformance corpus checks it byte-for-byte against the Rust reference.

## Install

~~~sh
pip install shcl
~~~

## Use

~~~python
from shcl import Document, FileStatus, SetStatus, Status

# Reads and parses in one call, and never raises: the document is usable
# either way, and the status separates missing from unreadable from
# parsed-with-errors.
doc, file_status = Document.load_file("server.shcl")
if file_status is FileStatus.NotFound:
	print("no config yet - using defaults")

# One call, a typed value, a visible fallback at the call site.
limit = doc.get_int("site(example.com).max-upload-mb", default=10)

# Or ask why a read failed: Good, Empty, NotFound, BadType, Multiple, BadPath.
r = doc.read_int("site(example.com).max-upload-mb")
if r.status is not Status.Good:
	print(r.status, r.raw)

# Wildcards read across instances, with a status per slot.
roots = doc.read_string_array("site(*).root")

# Writes through a temp file and a rename, so an interrupted save cannot
# truncate the config - and raises SaveRefused if this write would delete lines
# or values from the file (save_file_lossy is the override).
# A setter returns SetStatus.Ok, or why it wrote nothing at all. Only Ok is
# true, so `if not doc.set_int(...)` reads as refused.
st = doc.set_int("site(example.com).max-upload-mb", limit * 2)
if st is not SetStatus.Ok:
	print("not written:", st)
doc.save_file("server.shcl")
~~~

`Document.parse` never raises, and neither does `load_file`. When you want a hard error instead, use `Document.parse_with(text, Strictness.Strict)` or `load_file_with(path, Strictness.Strict)`, which raise `LoadError`. A `get_*` call without a `default=` raises `StatusError` rather than inventing a value.

The library also has `merge` for layered config such as defaults, site, and user, `validate` against a schema that is itself a SHCL file, a full writer, and a canonical formatter that preserves comments.

Python 3.9 or newer.

## Compatibility

Bindings are versioned in lockstep, so `3.x` is the same behavior in every language. `shcl~=3.0` picks up minor and patch releases on its own and never crosses a major version. It skips a beta, though, so name this one exactly: `shcl==3.0.0b1`, or `pip install --pre shcl`.

## The CLI

This package is the library only. The `shcl` command comes as a prebuilt binary and as `.deb`, `.rpm`, and Windows packages. See <https://github.com/yottacore/shcl>.

## Docs

The language spec, the formal grammar, and the other bindings are at <https://github.com/yottacore/shcl>.

## License

The license is MIT. SHCL™ is a trademark of Jim Collier. See the [trademark policy](https://github.com/yottacore/shcl/blob/main/trademark.md).
