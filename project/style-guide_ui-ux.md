<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
# CLI style guide

How the `shcl` command line looks and behaves. It writes down what the CLIs already do, so a new subcommand or option can follow it. Where a CLI does something else, that is a bug in the CLI, not a second convention.

There are four CLIs, one per binding. Only the Rust one is distributed. The Go, Python and C ones exist so the cross-binding check can compare them, and they have to match the Rust one on stdout and exit code, byte for byte.

## Commands

- The first argument is the subcommand. Each is one lower-case word: `get`, `set`, `fmt`, `check`, `init`, `count`, `instances`, `children`, `paths`, `migrate`, `upgrade`, `tokens`, `explain`.

- `help`, `version`, `about` and `donate` also work as options: `--help` and `-h`, `--version`, `-v` and `-V`, `--about`, `--donate`. `shcl help CMD` and `shcl CMD --help` print that subcommand's part of the help.

- Bare `shcl` prints the help and exits 0.

- A mistyped command, option or diagnostic code gets a did-you-mean, when one is close. It only suggests for ASCII words.

## Options

- Long options are GNU style: `--name`, lower case, words joined by hyphens.

- The only short forms are `-w` for `--write` and the help and version letters. New options get no short form.

- A value option takes either `--opt=VALUE` or `--opt VALUE`. In the space form the next argument is the value, whatever it looks like.

- `--` ends the options, for a FILE or PATH that starts with a dash.

- `-` means stdin. It may be named once per run, across FILE, `--layer` and `--schema`.

- An option a subcommand does not use is a usage error. It is never ignored.

- A combination that makes no sense is refused, and the help lists every refused combination.

- Two options that compete are a usage error, whichever order they were typed in, and the message names both. Nothing is ever resolved by last-wins, since that makes the answer depend on typing order and says nothing about it. Two different type options on `get` are the example.

- Repeating one option is not competing when the value is the same, which is a no-op, and a repeatable option applies in the order given. The same option given two different values is competing and is refused like any other pair.

## Help text

- Every line is 80 columns or less. All four CLIs print the same bytes, and a help edit moves all four.

- The usage block is two columns: the command on the left, and its description starting at column 42, wrapped under itself.

- Each option names, in parentheses, the subcommands it belongs to.

- `shcl help CMD` is cut out of the full text at run time, so there is only one copy to keep right.

- The exit codes are listed at the end of the help.

## Streams

- Stdout is for data: the value read, the document, the list of names or paths, the version. Every line ends in a newline.

- Stderr is for a person: errors, the load's diagnostics with their prose, and notes such as `n.shcl: migrated, 0 line(s) rewritten`.

- `check` is the one command whose output is its diagnostics. It prints `line N: severity: CODE` on stdout for each, then a summary line, and the same line plus its prose on stderr. A diagnostic line always starts with `line ` and the summary never does.

- Every subcommand that loads a document prints the load's diagnostics to stderr, once per run.

- Stdout and the exit code are the contract, and the cross-binding check compares them. Stderr prose is pinned by `cli-regress.bash` rows instead.

## Messages

- A message starts lower case and has no trailing period.

- It names what went wrong and where: `cannot read zz as int: no value at that path (in n.shcl)`.

- A usage error ends with `(see --help)`, unless it says the fix itself: `missing value for --schema (try --schema=VALUE)`. `explain` points at `shcl explain` instead, since that is where its answer is.

- A file that cannot be opened is `FILE: ` and the system's own message.

- A count that can be one or more is written `N line(s)`, `N diagnostic(s)`.

- Quotes around a suggested word are single quotes: `did you mean 'fmt'?`.

## Exit codes

| Code | Meaning
| :--- | :---
| 0    | Good.
| 1    | Usage error, and nothing else. A value an option refuses is still 1, since the option is what has to change. So is a PATH that cannot parse, `--default` or not.
| 2    | The value is empty.
| 3    | Nothing at the path.
| 4    | The value is the wrong type.
| 5    | The path matches more than one instance.
| 6    | `check` found an error, a strict load failed, `init`'s schema has faults, or a `--check` found a rewrite to make.
| 7    | An in-place write was refused, or `migrate` or `upgrade` left something behind. A `--check` reports the refusal with the same code.
| 8    | A file or stream could not be read or written.

A new failure reuses one of these where one fits.

## Writing files

- Nothing on disk changes without `--write` or `-w`. Without it the result goes to stdout.

- An in-place write goes through the library's save: a temp file, then a rename over the original.

- A write that would delete lines or values from the file is refused with exit 7, and the file is left alone. `--lossy` says the loss was meant.

- `--write` on `set` creates FILE when it is not there yet, with the info block unless `--no-banner` is given.
