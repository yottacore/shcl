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
>
> - Tweet/skeet/post about it
>
> - Refer this project in your project's readme
>
> - Mention the project to your friends/colleagues
>
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

Everything routes through the local pipeline, `cicd/cicd.bash`. A green `cicd/cicd.bash --merge-gate` run locally covers what GitHub CI runs on Linux. GitHub also runs jobs on Windows, Windows on ARM, Linux on ARM, and macOS, which a local run doesn't.

The pipeline fast-forwards from the remote before it builds anything, so what it tests is what you would push. It stops and says so if your branch and its upstream have both moved. `--no-sync` skips that.

There is also a `pre-push` hook that runs the merge gate, `cicd/cicd.bash --merge-gate`, for you, but only when the push would move `main`. It runs every check of a run with no flags, and it doesn't dogfood, publish, or rewrite anything. `--ci` is another name for it. A push that changes only docs and art, which are the files `cicd/docs-only-paths.txt` lists, goes to `main` without it. Everything else pushes straight through, `dev` and feature branches alike. `install-dev.bash` turns the hook on. To turn it on by hand, run this:

~~~sh
git config core.hooksPath cicd/hooks
~~~

It skips the gate for a commit whose files a run already passed. Every `cicd.bash` run that gets through the tests and the cross checks without `--quick`, `--no-fmt`, `--no-lint`, `--no-tests`, `--no-cross`, `--skip`, or a skipped tool records the tree it tested. So the push at the end of a full run goes straight out, and so does a `--no-ff` merge of a branch that passed onto a `main` that hasn't moved since. `SHCL_GATE_RERUN=1` runs the gate anyway, and `git push --no-verify` or `SHCL_SKIP_HOOK=1` gets past it when you need to.

GitHub CI runs on pushes to `main`, on pull requests, and by hand from the Actions tab. Pushes to `dev` don't start it, and nothing gates `dev`, so run `cicd/cicd.bash --gate` on your own box before you merge there.

### Toolchains

- Install Rust through rustup. `rust-toolchain.toml` pins the version and cross targets, and `rustfmt` and `clippy` come with it.
	- Only rustup honors that pin. If your distro also packages Rust and its `cargo` wins on `PATH`, the pin is ignored without any warning, and you can end up building at one version while formatting and linting at another. `cicd.bash` prepends `~/.cargo/bin` so the pipeline is safe either way, but a bare `cargo` at the prompt isn't. Check it with `type -a cargo` and `rustup show active-toolchain`, and fix it by putting `~/.cargo/bin` ahead of the system directories rather than after them.

- For Go, install a current release. Hosted CI pins the 1.26 series rather than `stable`, because `staticcheck` has its own type checker and can't read a newer Go's export data. The 2 pins move together, and `.github/workflows/ci.yml` gives the reason. The `go` directive in `source/go/go.mod` is the minimum for a consumer of the library, and it isn't enough for the pipeline. `gofmt` and `go vet` are built in.

- Python needs 3.9 or later, and the binding and its tests use only the stdlib.

- C needs gcc and g++. The build gate is a `-std=c11 -Wall -Wextra -Wshadow -Wvla -Wconversion -Wsign-conversion -Werror` compile.

- PowerShell 7 or later is required, since the lint stage runs PSScriptAnalyzer through `pwsh` on every run, including `--gate`.

- Zig and Pillow are needed too. `check-readme` and `check-c-compilers` build with zig, and `shell-regress` reads the demo gif with Pillow. Those checks run on your box even when docker works.

`install-dev.bash` at the repo root sets up as much of this as it can without sudo, and prints package-manager hints for the rest. It checks each tool against its pin in `cicd/config.bash`, the cross, packaging, and analyzer tools below included, and names each one that's missing or at another version.

A run without `--gate` also wants the cross and packaging tools listed below. `--quick` builds the cross targets too, but it doesn't build any packages.

- `cargo-zigbuild` and a mingw toolchain are for the Windows and ARM64 builds. Missing tools fail that stage, so pass `--no-cross` if you don't have them.

- `nfpm` is for `.deb`/`.rpm`, and `makensis` is for the Windows setup. If either one is missing, the run warns and skips its packages.

None of this is needed for `--gate`.

With docker you may not need any of it.

- When docker works on an x86_64 box, `cicd/cicd.bash` runs stages 1 to 6 in a Debian image with every tool at its pinned version, and builds the image from `cicd/container/` the first time. Without it, or when the image fails to build, they run on your box, with a one-line note saying why. `--no-container` keeps them on your box anyway, and `--container` fails rather than run without the image. The sync, dogfood, demo gif and publish stages always run on your box. The stage flags pass through, so `cicd/cicd.bash --merge-gate` is the merge gate in the image, and so is the pre-push hook's.

- Caches go in `~/.cache/shcl-cicd`, or wherever `SHCL_CTR_CACHE` points. Zig's cache is the exception. It's a docker volume of its own, `shcl-zig-cache`, and a run empties it at the end once it's over 2 GB or another Zig version filled it. Your own `~/.cache/zig` is never touched. Cargo's target dirs, `source/rust/target` and `source/rust/target-migrate`, contain a stamp that names the toolchain in `rust-toolchain.toml` and the lockfile that filled them. When either has changed, a run empties the dir before it builds, so an old toolchain's units don't pile up, and an extra image's copy is emptied the same way. The run waits to do that while another run is going.

- What a run starts in docker is labeled `dev.project=shcl`, plus `dev.run` with the name of the run's temp folder, and the run's containers are removed when it ends, even when it failed or was stopped. A run in the image also removes our image tags except the current one and the one before it, even when it failed or was stopped. The images build on docker's default builder, and a run leaves docker's build cache alone. Docker can trim that cache itself, through `builder.gc` in `/etc/docker/daemon.json`. Runs from early November 2026 made a `shcl-cicd` buildx builder, and a run removes it and its cache the first time it finds it.

- A run caps its memory, with no swap, so a runaway step is killed and the rest of the box isn't. The cap is `CICD_MEM_CAP`, a docker size such as `24g`, or `none` for no cap, and it's a third of the RAM from 4g to 32g by default. Any other value fails the run before anything starts. Each container gets `--memory` and `--memory-swap` at the cap and `--oom-score-adj 1000`, and where `systemd-run --user` works the run itself goes under a user scope at the cap, where it's first in line for the OOM killer. A step killed at the cap exits 137.

- `--keep-temp` keeps the run's temp folder and its containers, and says where they are. `--list` prints the steps the other flags would run, by stage, with the test IDs each step runs under it, and runs nothing.

Stages 2 to 6 run from a copy of the tree taken after the format stage, with your uncommitted edits and any new file git doesn't ignore in it, so you can keep editing, merging, and switching branches while a run goes. The run lists what it copied. `--no-freeze` runs them in the checkout instead.

There are 2 more images for now and then:

- `--container=ubuntu` is Ubuntu 24.04 and its gcc 13, like the hosted runner, for a red that only shows up there. It runs the format check, build, tests, and cross checks, strict like `--merge-gate`, without release builds, test boxes, or leak checks.

- `--container=alpine` builds on musl and runs the binding suites and the CLI checks.

### Build and test

- For a fast loop, `cargo test --manifest-path source/rust/Cargo.toml` runs the conformance corpus plus the fuzz smoke against the reference.

- Each binding also tests natively:
	- Go: `go -C source/go test -count=1 ./...`. The corpus is outside the module, so without `-count=1` a cached pass hides a changed case.
	- Python: `python3 -X dev -W error::ResourceWarning source/python/tests/conformance.py`, so a file left open fails. `tests/soak.py` runs the same way.
	- C: compile and run `source/c/tests/conformance.c` with `-Isource/c`, passing `project/conformance` as the corpus dir.

- To run everything at once, use `cicd/cicd.bash --merge-gate`. It runs the format check, build, lint, tests, the cross-binding crosscheck, the release builds, and the leak checks. Every binding must match the reference byte for byte on stdout and exit codes, and stderr text isn't part of the contract.

- In between, `cicd/cicd.bash --quick` runs the lint and test steps that take under a minute, and the cross builds. It leaves out the slow checks, the crosscheck among them, and the ones that fetch from the network. `QUICK_SKIP` in `cicd/config.bash` lists them. It leaves out the test boxes too, since they're other hosts. A quick run never counts as a pass for the hook.

- Before a commit, `cicd/cicd.bash --backlog-run-quick` runs the format check, build, lint, tests, and cross checks, less what `--quick` leaves out, with no leak checks or profiler calibration, in about 4 minutes. `--gate` is another name for it. It also leaves out the slow tests `BACKLOG_SKIP` in `cicd/config.bash` lists, and records no tree. Area names after it, such as `--backlog-run-quick go cli`, keep only those areas' tests, `BACKLOG_SKIP`'s included. `--help` lists them, and `BACKLOG_AREAS` says which steps each area has. Its lint and test steps run up to 4 at once, and print in order. `--backlog-run-full`, for a last run before a merge, runs the merge gate's checks. Neither one dogfoods, publishes, commits, pushes, installs, syncs, rewrites a tracked file, or prompts.

- Each run keeps its scratch in a folder of its own, `${HOST_TEMP}/shcl/<YYYYmmDD-HHMMSS>_<NNN>/`, with `TMPDIR`, `TEMP`, and `TMP` pointed there. Without `HOST_TEMP` it goes under `TMPDIR`, or `/tmp`. The folder is removed when the run ends, even when it failed or was stopped, unless `--keep-temp` was given. A run also removes the run folders under `${HOST_TEMP}/shcl/` more than 2 days old whose run has stopped. A folder without a `run.pid` in it isn't a run's, and it stays. A script under `cicd/utility/` run by hand makes a folder of its own the same way, with a `run.pid`, and in a run it works in a folder inside the run's.

- The filesystem property tests save into a real folder, `SHCL_FS_DIR`, or the temp folder with a `note:` line when it's unset. A run gives them a 256 MB tmpfs made for it. In the image that's docker's `--mount type=tmpfs`, and on a Linux host a user namespace around each binding's tests, so nothing needs root and the mount is gone when they end. On macOS it's a RAM disk from `hdiutil`, which is HFS+ so it ignores case, and it's detached at the end. On FreeBSD it's a tmpfs, where the user may mount one (root, or `vfs.usermount=1`). On Windows it's a folder in the temp folder, as `TEMP` spells it. Where none works they go in a plain folder in the run's, and a `note:` line says why. A box's `suites` run them too, as the `fs` suite. `cicd/utility/fs-property.bash` runs them with `SHCL_FUZZ_DUMP` set, and compares each binding's answers with Rust's. `SHCL_FS_SECS` sets their budget, 2 s by default, and `SHCL_FS_SEED` replays one seed.

- `--skip TEXT` leaves out each lint, test, leak check, cross or release check step whose command contains `TEXT`, and the run records nothing. The hosted workflow runs the merge gate with `--skip=codeql-scan.bash`, since it doesn't install CodeQL.

- A run with `--long` also starts the hosted `macos` job on GitHub's arm64 Mac runner, for your branch as pushed, and waits for it at the end. It needs `gh`, and a remote branch at your HEAD, or it's a SKIP that says why. It runs your last commit rather than uncommitted edits. `--quick` and `--backlog-run-quick` refuse `--long`, and `--no-remote` leaves the job out.

- The leak and memory checks are grouped by how long they take. `--quick` ends its tests with the fast ones, a run with no flags with the slow ones too, and `--long` (or `--slow`) adds the ones that take hours, so a run with no flags stays near an hour. `--backlog-run-quick` leaves them out. `--leakcheck` adds every one, so `cicd/cicd.bash --merge-gate --leakcheck` is the merge gate plus the ones that take hours. `--no-leakcheck` drops every one, including the sanitizer runs in the tests, and it can't be given with `--leakcheck`. `LEAKCHECK_FAST`, `LEAKCHECK_STEPS`, and `LEAKCHECK_LONG` in `cicd/config.bash` list them. Every Rust test under Miri is a long one, and takes hours. Miri needs the dated nightly in `rust-toolchain.toml`, and those tests skip without it. The C analyzer, the C soak, and CodeQL run in the build image when their tools aren't on your box and docker works.

- CodeQL runs each language's security-and-quality suite over all 5, and any finding fails it. Fix it, or put a `codeql[QUERY-ID]` comment with the reason alone on the line above it, `// ...` or `# ...`, and `/* ... */` above commented-out C. A real bug gets a backlog item, and its ID goes in the reason. The databases and SARIF go in `cicd/artifacts/codeql/`.

### Adding a conformance case

Behavior changes come with a corpus case, or they aren't pinned.

- A case is a directory under `project/conformance/NNN-short-name/`, using the next free number.

- Every case needs 4 files:
	- `input.shcl` is the document under test.
	- `expected.shcl` has the exact `fmt` stdout.
	- `expected-diags.txt` has the exact `check` stdout at standard strictness.
	- `reads.tsv` has one row per read to replay.

- Optional paired files add a dimension:
	- `write.ops` and `expected-write.shcl` test the Writer.
	- `write-bad.ops` lists ops that must be rejected.
	- `schema.shcl` and `expected-validate.txt` test schema validation.
	- `layer*.shcl`, `merge.sets`, and `expected-merged.shcl` test layered loading.
	- `init-schema.shcl` and `expected-init.shcl` test starter-config generation.

- Column meanings and file grammars are in `project/conformance/README.md`. It also has a short note per case, so add one for yours.

- Generate the golden files from the Rust reference and eyeball them. Never hand-edit a golden to make a test pass.

- All 4 runners pick up a new case automatically. Run `cicd/cicd.bash --merge-gate`, since every binding must agree on a case before it's released.

Behavior the corpus can't see, because it isn't stdout, belongs in `cicd/utility/crosscheck.bash` instead. In-place writes are the current example. The check there compares the file tree a write leaves behind, so all 4 bindings are held to the same mode, symlink, and content outcome.

### Linters

- These tools gate, so the lint stage fails the run on any finding:
	- `rustfmt` and `clippy` are rustup components.
	- `gofmt` and `go vet` come with Go.
	- `staticcheck` is for Go. Install it with `go install honnef.co/go/tools/cmd/staticcheck@<pin>`.
	- `govulncheck` is for Go too. Install it with `go install golang.org/x/vuln/cmd/govulncheck@<pin>`. It checks the module graph and the standard library against the vulnerability database.
	- `cargo-deny` is for Rust. Install it with `cargo install cargo-deny --version <pin>`. It checks advisories, licenses, and duplicate versions over the lockfile, and its config is in `source/rust/deny.toml`.
	- `shellcheck` checks the pipeline's own scripts and the installers.
	- `ruff` and `mypy` are for Python. Install them with `pipx install ruff` and `pipx install mypy`. Both read their settings from `source/python/pyproject.toml`.
	- `build` is for Python. Install it with `pipx install build`. The lint stage builds the wheel and sdist and checks that they contain the library alone, since the CLI and the tests must never go in a package.
	- `cppcheck` is for C. Install it with `pipx install cppcheck`, since the PyPI wheel bundles the real binary.
	- `markdownlint-cli2` checks the docs. Install it with `npm install -g markdownlint-cli2`. The repo config is in `.markdownlint-cli2.jsonc`.
	- `PSScriptAnalyzer` checks the ps1 installer and scripts. Install it with `pwsh -Command 'Install-Module PSScriptAnalyzer -Scope CurrentUser'`.

- The pipeline pins each of these tools, and hosted CI installs the same versions. The pins are in one place, `TOOL_PINS` in `cicd/config.bash`. Install those versions and the run stays quiet. A drifted tool gets a warning at the top of every run, and a lint-stage check fails the run if the workflow file's copy of a pin ever disagrees.

- `shfmt` and `clang-format` are optional. They're useful interactively but don't gate, and since shfmt's output differs from the house shell style, it never rewrites files here. clang-tidy does gate, through `cicd/utility/analyze-c.bash` in the build image.

### Style

The full rules are in [`project/style-guide_code.md`](project/style-guide_code.md). Read it before touching a binding. The most important rule there is that every binding deliberately mirrors the Rust reference's structure, function for function, even where the host language would do it differently. That's what keeps the bindings byte-for-byte identical and a fix portable by mechanical diff. Here are the basics:

- Use tabs for indentation and spaces for alignment.

- Markdown never hard-wraps. One paragraph or bullet is one physical line.

- Comments are terse and explain why rather than what.

### Branches

- Work on a short-named feature branch and open a PR against `dev`. `main` is for releases only.
