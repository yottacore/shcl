<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Contributing

First off, thanks for taking the time to contribute!

All types of contributions are encouraged and valued. See the [Table of contents](#table-of-contents) for different ways to help and details about how this project handles them. Please read the relevant section before making your contribution - it makes things easier on both ends.

> And if you like the project but don't have time to contribute, that's fine. There are easier ways to support it:
>
> - Star the project
> - Tweet/skeet/post about it
> - Refer this project in your project's readme
> - Mention the project to your friends/colleagues
> - Sponsor it on [GitHub](https://github.com/sponsors/jim-collier) or [Ko-fi](https://ko-fi.com/jimcollier)

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Code of Conduct](#code-of-conduct)
- [I Have a Question](#i-have-a-question)
- [I Want To Contribute](#i-want-to-contribute)
	- [Reporting Bugs](#reporting-bugs)
		- [Before Submitting a Bug Report](#before-submitting-a-bug-report)
		- [How Do I Submit a Good Bug Report?](#how-do-i-submit-a-good-bug-report)
	- [Suggesting Enhancements](#suggesting-enhancements)
		- [Before Submitting an Enhancement](#before-submitting-an-enhancement)
		- [How Do I Submit a Good Enhancement Suggestion?](#how-do-i-submit-a-good-enhancement-suggestion)
- [How to develop](#how-to-develop)
	- [Toolchains](#toolchains)
	- [Build and test](#build-and-test)
	- [Adding a conformance case](#adding-a-conformance-case)
	- [Linters](#linters)
	- [Style](#style)
	- [Branches](#branches)

<!-- /TOC -->

## Code of Conduct

This project and everyone participating in it is governed by the [SHCL Code of Conduct](https://github.com/yottacore/shcl/blob/main/code_of_conduct.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to shclⒶyottacore.com.

## I Have a Question

Before you ask a question, it is best to search for existing [Issues](https://github.com/yottacore/shcl/issues) that might help you. In case you have found a suitable issue and still need clarification, you can write your question in this issue. It is also advisable to search the internet for answers first.

If you then still feel the need to ask a question and need clarification, we recommend the following:

- Open an [Issue](https://github.com/yottacore/shcl/issues/new).

- Provide as much context as you can about what you're running into.

- Provide project and platform versions, depending on what seems relevant.

We will then take care of the issue as soon as possible.

## I Want To Contribute

> ### Legal Notice
>
> When contributing to this project, you must agree that you have authored 100% of the content, that you have the necessary rights to the content and that the content you contribute may be provided under the project license.

### Reporting Bugs

#### Before Submitting a Bug Report

A good bug report shouldn't leave others needing to chase you up for more information. Therefore, we ask you to investigate carefully, collect information and describe the issue in detail in your report. Please complete the following steps in advance to help us fix any potential bug as fast as possible.

- Make sure that you are using the latest version.

- Determine if your bug is really a bug and not an error on your side e.g. using incompatible environment components/versions (Make sure that you have read the [documentation](https://github.com/yottacore/shcl/blob/main/README.md). If you are looking for support, you might want to check [this section](#i-have-a-question)).

- To see if other users have experienced (and potentially already solved) the same issue you are having, check if there is not already a bug report existing for your bug or error in the [bug tracker](https://github.com/yottacore/shcl/issues?q=label%3Abug).

- Also search the wider internet (Stack Overflow and the like) in case someone outside GitHub has already discussed it.

- Collect information about the bug:
	- OS, Platform and Version (Windows, Linux, macOS, x86, ARM)
	- Environment versions
	- Possibly your input and the output
	- Can you reliably reproduce the issue? And can you also reproduce it with older versions?
	- Steps to cleanly reproduce from scratch.

#### How Do I Submit a Good Bug Report?

> You must never report security related issues, vulnerabilities or bugs including sensitive information to the issue tracker, or elsewhere in public. Instead sensitive bugs must be sent by email to shclⒶyottacore.com.

We use GitHub issues to track bugs and errors. If you run into an issue with the project:

- Open an [Issue](https://github.com/yottacore/shcl/issues/new). (Since we can't be sure at this point whether it is a bug or not, we ask you not to talk about a bug yet and not to label the issue.)

- Explain the behavior you would expect and the actual behavior.

- Please provide as much context as possible and describe the *reproduction steps* that someone else can follow to recreate the issue on their own. This usually includes your code. For good bug reports you should isolate the problem and create a reduced test case.

- Provide the information you collected in the previous section.

Once it's filed:

- The project team will label the issue accordingly.

- Someone will try to reproduce the issue from the steps given. Where there are no steps, or no obvious way to reproduce it, they will ask for them, and the issue waits until it reproduces.

- Once it reproduces, the issue is left to be [implemented by someone](#how-to-develop).

### Suggesting Enhancements

This section guides you through submitting an enhancement suggestion for SHCL, **including completely new features and minor improvements to existing functionality**. Following these guidelines will help maintainers and the community to understand your suggestion and find related suggestions.

#### Before Submitting an Enhancement

- Make sure that you are using the latest version.

- Read the [documentation](https://github.com/yottacore/shcl/blob/main/README.md) carefully and find out if the functionality is already covered, maybe by an individual configuration.

- Perform a [search](https://github.com/yottacore/shcl/issues) to see if the enhancement has already been suggested. If it has, add a comment to the existing issue instead of opening a new one.

- Find out whether your idea fits with the scope and aims of the project. It's up to you to make a strong case to convince the project's developers of the merits of this feature. Keep in mind that we want features that will be useful to the majority of our users and not just a small subset. If you're just targeting a minority of users, consider writing an add-on/plugin library.

#### How Do I Submit a Good Enhancement Suggestion?

Enhancement suggestions are tracked as [GitHub issues](https://github.com/yottacore/shcl/issues).

- Use a **clear and descriptive title** for the issue to identify the suggestion.

- Provide a **step-by-step description of the suggested enhancement** in as many details as possible.

- **Describe the current behavior** and **explain which behavior you expected to see instead** and why. At this point you can also tell which alternatives do not work for you.

- **Explain why this enhancement would be useful** to most SHCL users. You may also want to point out the other projects that solved it better and which could serve as inspiration.

## How to develop

Everything routes through the local pipeline, `cicd/cicd.bash`. A green `cicd/cicd.bash --ci` run locally is the same gate GitHub CI runs on Linux. GitHub also runs a Windows job that `--ci` does not.

The pipeline fast-forwards from the remote before it builds anything, so what it tests is what you would push. It stops and says so if your branch and its upstream have both moved. `--no-sync` skips that.

There is also a `pre-push` hook that runs the gate for you, but only when the push would move `main`. Everything else pushes straight through, `dev` and feature branches alike. `install-dev.bash` turns it on; to do it by hand:

~~~sh
git config core.hooksPath cicd/hooks
~~~

It skips the gate for a commit whose files a run already passed. Every `cicd.bash` run that gets through the tests and the cross checks without `--quick`, `--no-fmt`, `--no-lint`, `--no-cross` or a skipped tool records the tree it tested. So the push at the end of a full run goes straight out, and so does a `--no-ff` merge of a branch that passed onto a `main` that has not moved since. `SHCL_GATE_RERUN=1` runs the gate anyway, and `git push --no-verify` or `SHCL_SKIP_HOOK=1` gets past it when you need to.

GitHub CI runs on pushes to `main`, on pull requests, and by hand from the Actions tab. Pushes to `dev` do not start it, and nothing gates `dev`, so run `cicd/cicd.bash --ci` on your own box before you merge there.

### Toolchains

- Rust via rustup - `rust-toolchain.toml` pins the version and cross targets; `rustfmt` and `clippy` come with it.
	- Only rustup honors that pin. If your distro also packages Rust and its `cargo` wins on `PATH`, the pin is ignored with no warning, and you can end up building at one version while formatting and linting at another. `cicd.bash` prepends `~/.cargo/bin` so the pipeline is safe either way, but a bare `cargo` at the prompt is not. Check with `type -a cargo` and `rustup show active-toolchain`; fix by putting `~/.cargo/bin` ahead of the system directories, not after.

- Go - install a current release. Hosted CI pins the 1.26 series rather than `stable`, because `staticcheck` has its own type checker and cannot read a newer Go's export data; the two pins move together (the reason is spelled out in `.github/workflows/ci.yml`). The `go` directive in `source/go/go.mod` is the minimum for a consumer of the library, not enough for the pipeline. `gofmt` and `go vet` are built in.

- Python 3.9+ - the binding and its tests are stdlib-only.

- C - gcc and g++; the build gate is a `-std=c11 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror` compile.

- PowerShell 7+ - required: the lint stage runs PSScriptAnalyzer through `pwsh` on every run, including `--ci`.

`install-dev.bash` at the repo root sets up as much of this as it can without sudo, and prints package-manager hints for the rest.

A full (non-`--quick`) pipeline run also wants the cross and packaging tools:

- `cargo-zigbuild` and a mingw toolchain, for the Windows and ARM64 builds. Missing tools fail that stage, so pass `--no-cross` if you do not have them.

- `nfpm` for `.deb`/`.rpm`, and `makensis` for the Windows setup. Either one missing just warns and skips its own packages.

None of this is needed for `--ci`, which is the gate that matters for a pull request.

### Build and test

- Fast loop: `cargo test --manifest-path source/rust/Cargo.toml` - runs the conformance corpus plus the fuzz smoke against the reference.

- Each binding also tests natively:
	- Go: `go -C source/go test -count=1 ./...`. The corpus sits outside the module, so without `-count=1` a cached pass hides a changed case.
	- Python: `python3 source/python/tests/conformance.py`
	- C: compile and run `source/c/tests/conformance.c` with `-Isource/c`, passing `project/conformance` as the corpus dir.

- Everything at once: `cicd/cicd.bash --ci` - format check, build, lint, tests, and the cross-binding crosscheck. Every binding must match the reference byte for byte on stdout and exit codes; stderr text is not part of the contract.

### Adding a conformance case

Behavior changes come with a corpus case, or they are not pinned.

- A case is a directory under `project/conformance/NNN-short-name/`, using the next free number.

- Every case needs four files:
	- `input.shcl` - the document under test.
	- `expected.shcl` - the exact `fmt` stdout.
	- `expected-diags.txt` - the exact `check` stdout at standard strictness.
	- `reads.tsv` - one row per read to replay.

- Optional paired files add a dimension:
	- `write.ops` + `expected-write.shcl` - the Writer.
	- `write-bad.ops` - ops that must be rejected.
	- `schema.shcl` + `expected-validate.txt` - schema validation.
	- `layer*.shcl` + `merge.sets` + `expected-merged.shcl` - layered loading.
	- `init-schema.shcl` + `expected-init.shcl` - starter-config generation.

- Column meanings and file grammars are in `project/conformance/README.md`. It also has a short note per case, so add one for yours.

- Generate the golden files from the Rust reference and eyeball them. Never hand-edit a golden to make a test pass.

- All four runners pick up a new case automatically. Run `cicd/cicd.bash --ci`; every binding must agree on it before it is released.

Behavior the corpus cannot see, because it is not stdout, belongs in `cicd/utility/crosscheck.bash` instead. In-place writes are the current example: the check there compares the file tree a write leaves behind, so all four bindings are held to the same mode, symlink and content outcome.

### Linters

- Gating (the lint stage fails the run on any finding):
	- `rustfmt` + `clippy` - rustup components.
	- `gofmt` + `go vet` - come with Go.
	- `staticcheck` - Go: `go install honnef.co/go/tools/cmd/staticcheck@<pin>`.
	- `govulncheck` - Go: `go install golang.org/x/vuln/cmd/govulncheck@<pin>`; checks the module graph and the standard library against the vulnerability database.
	- `cargo-deny` - Rust: `cargo install cargo-deny --version <pin>`; advisories, licenses and duplicate versions over the lockfile, config in `source/rust/deny.toml`.
	- `shellcheck` - the pipeline's own scripts and the installers.
	- `ruff` + `mypy` - Python: `pipx install ruff` and `pipx install mypy`; both read their settings from `source/python/pyproject.toml`.
	- `build` - Python: `pipx install build`. The lint stage builds the wheel and sdist and checks they contain the library alone, since the CLI and the tests must never ship.
	- `cppcheck` - C: `pipx install cppcheck` (PyPI wheel bundles the real binary).
	- `markdownlint-cli2` - docs: `npm install -g markdownlint-cli2`; repo config in `.markdownlint-cli2.jsonc`.
	- `PSScriptAnalyzer` - the ps1 installer and scripts: `pwsh -Command 'Install-Module PSScriptAnalyzer -Scope CurrentUser'`.

- Versions: the pipeline pins each of these tools, and hosted CI installs the same versions. The pins live in one place, `TOOL_PINS` in `cicd/config.bash`; install those versions and the run stays quiet (a drifted tool gets a warning at the top of every run, and a lint-stage check fails the run if the workflow file's copy of a pin ever disagrees).

- Installed-but-optional: `shfmt` and `clang-tidy`/`clang-format` are useful interactively but do not gate (shfmt's output differs from the house shell style, so it never rewrites files here).

### Style

The full rules live in [`project/style-guide_code.md`](project/style-guide_code.md) - read it before touching a binding. The single most important rule there: every binding deliberately mirrors the Rust reference's structure, function-for-function, even where the host language would idiomatically do it differently. That is what keeps the bindings byte-for-byte identical and a fix portable by mechanical diff. Quick basics:

- Tabs for indentation, spaces for alignment.

- Markdown never hard-wraps - one paragraph or bullet is one physical line.

- Comments are terse and explain why, not what.

### Branches

- Work on a short-named feature branch and PR against `dev`; `main` is release-only.
