<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Compared to other config languages

This page compares SHCL with JSON, YAML, TOML, and XML on file size and read speed, and says how it differs from Pkl, CUE, and Dhall. The short feature table is in the README, under [How it compares to...](../README.md#how-it-compares-to).

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Performance comparison benchmarks](#performance-comparison-benchmarks)
	- [Application config](#application-config)
	- [Schema definition](#schema-definition)
	- [Unrealistic stress test](#unrealistic-stress-test)
- [Programmable config languages - Pkl, CUE, Dhall](#programmable-config-languages---pkl-cue-dhall)

<!-- /TOC -->

## Performance comparison benchmarks

SHCL writes the smallest file of the five. But it is several times slower to read than JSON, the fastest of the five, at every size (see the tables). That is due to two conscious tradeoffs:

1. SHCL offloads much of the burden of parsing and datatype-correct formatting from the user and programmer, to the library itself.

2. SHCL is the only one of the five that gives your file back the same way you wrote it.

These test results cover three scenarios, each with the same data in all five config formats, each read by a native Rust library for each format. Columns keep one order across the three tables: fastest to slowest on the application config.

### Application config

This test covers the kind of config a person hand-edits. The test data contains entries for server, logging, database, cache, auth, paths, limits, feature flags, and a banner block.

| Config file    | JSON      | XML   | TOML  | SHCL    | YAML
| :---           | :---      | :---  | :---  | :---    | :---
| File size (KB) | 2.2       | 3.0   | 1.7   | **1.6** | 1.7
| Read time (ms) | **0.008** | 0.016 | 0.024 | 0.050   | 0.070

Practically nobody chooses a format based on read times that low, except maybe a realtime embedded system whose whole executable is measured in kilobytes. (And one of those would not be linking in any library anyway.)

### Schema definition

This test covers 195 table definitions, each with typed columns, nullability, defaults, keys, indexes, and comments.

| Schema file    | JSON    | XML  | TOML | SHCL    | YAML
| :---           | :---    | :--- | :--- | :---    | :---
| File size (KB) | 426     | 492  | 294  | **263** | 318
| Read time (ms) | **1.6** | 3.0  | 4.9  | 7.7     | 12.1

Here SHCL is 38% smaller than JSON and 47% smaller than XML, and still reads in under a hundredth of a second. SHCL is built for files of this size, which are big but still edited by hand.

### Unrealistic stress test

Far past anything anyone edits by hand: one array of 296,892 records.

| Stress test                | JSON     | XML  | TOML | SHCL    | YAML
| :---                       | :---     | :--- | :--- | :---    | :---
| File size (MB)             | 105      | 157  | 75   | **67**  | 78
| Gzipped (MB)               | 8.7      | 10.8 | 9.1  | 8.9     | 9.3
| Read time (s)              | **0.63** | 1.40 | 2.07 | 3.92    | 4.76
| Peak memory (GB)           | **1.1**  | 1.5  | 2.4  | 1.7     | 2.7
| Keeps your file as written | no       | no   | no   | **yes** | no

`toml_edit` is the only other parser here that keeps the file as written, comments included. It isn't in the table. It peaks at 4.2 GB against SHCL's 1.7, and reads in 2.5 s against SHCL's 3.9.

Every number above comes from one Rust library per format. A slow library and a slow format aren't the same thing, so the same files are read again in Python. `json`, `ElementTree`, and PyYAML are all C underneath, like most Python parsers. SHCL's Python binding is pure Python. `tomllib` is also pure Python, so it's the only fair match. In Python, SHCL reads 5.7 times slower than `tomllib`; in Rust, 1.6 times slower than `toml`. SHCL is behind in both, and the 2 languages use separate implementations.

TLDR: If you are moving a lot of machine-generated data over a high-bandwidth connection, use JSON. If you want to save developer time, and respect end-user sanity, use SHCL.

> *How it was measured: [`cicd/utility/comparison/`](../cicd/utility/comparison/) writes the same data in all 5 formats, then reads each file back with its own ecosystem's parser. Every parser gets the same compiler and flags, and one process per measurement. The method and caveats are in [design.md](design.md#format-comparison). Every number, including the other shapes and the Python tier, is in [results.shcl](../cicd/utility/comparison/results.shcl).*

## Programmable config languages - Pkl, CUE, Dhall

These are a different species. They overlap a little with SHCL's power layer, but from the opposite direction: they make the *config file itself* powerful, which is exactly what SHCL avoids.

- **Pkl** (from Apple) is a real language: classes, inheritance, built-in validation. Great when your config genuinely is a program. (And very arguably the winner among these three, depending on your use-case.)

- **CUE** unifies types and values into one thing. Extremely strong validation, and a mental model that takes real time to absorb.

- **Dhall** is functional programming for config: imports, functions, guaranteed termination. Closer to writing Haskell than editing a file.

They are all good at what they do. The shared cost is that once a config file can compute, it can be wrong in ways you have to debug.

SHCL deliberately stays off that cliff. The file stays dumb, and the power moves into the library instead:

- **Schema validation.** A schema is just another SHCL file. `doc.validate(schema)` catches unknown fields, wrong types, and out-of-range values, including the "did you mean `enabled`?" typo case.

- **Layered loading.** `merge(base, over)` folds files in order - defaults, then site, then user, last wins - and the CLI stacks the same way, with repeatable `--layer=FILE` and `--set=PATH=VALUE` overrides on top. That covers most of what imports actually get used for. Environment variables are deliberately left to your program. The env namespace and its naming convention belong to the app, and the app can map them onto `--set` itself.

- **Generated starter configs.** The schema plus the writer can emit a fully commented, correctly typed starting file.

Your config never needs a debugger, and a non-programmer can still edit it.
