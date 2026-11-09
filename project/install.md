<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Installation

This page covers how to get the `shcl` CLI and the libraries, from a package manager to building it yourself, and also how to set up a clone for development.

The latest release, `v3.0.0-beta1`, has packages, prebuilt CLI binaries, and a checksums file on the [releases page](https://github.com/yottacore/shcl/releases). It's a beta. The newest full release is still `v2.0.0`, which reads files by the 2.x rules.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Language packages](#language-packages)
	- [Cargo](#cargo)
	- [Go module](#go-module)
	- [PyPI](#pypi)
	- [C and C++](#c-and-c)
- [Packages and installers](#packages-and-installers)
	- [Debian](#debian)
	- [Fedora, RHEL, openSUSE](#fedora-rhel-opensuse)
	- [FreeBSD](#freebsd)
	- [Windows setup](#windows-setup)
- [Install scripts, stable or dev](#install-scripts-stable-or-dev)
	- [Linux, macOS, WSL and FreeBSD](#linux-macos-wsl-and-freebsd)
	- [Windows (PowerShell)](#windows-powershell)
- [DIY install](#diy-install)
- [Set up a development environment](#set-up-a-development-environment)

<!-- /TOC -->

## Language packages

Each binding is published where its own ecosystem looks for it, all under the name `shcl`: [crates.io](https://crates.io/crates/shcl) for Rust, [PyPI](https://pypi.org/project/shcl/) for Python, and the [Go module](https://pkg.go.dev/github.com/yottacore/shcl/source/go/v3) for Go.

Only the crate includes the CLI as well as the library. That makes it the easiest way to get the binary on a platform taht doesn't have a prebuilt one, such as NetBSD or OpenBSD.

### Cargo

Cargo skips a beta unless it's named, so a plain `cargo install shcl` gets 2.0.0:

~~~sh
cargo install shcl --version 3.0.0-beta1
~~~

### Go module

The module is the library by itself, so this adds a dependency and doesn't install a command:

~~~sh
go get github.com/yottacore/shcl/source/go/v3@v3.0.0-beta1
~~~

### PyPI

The PyPI distribution is also the library by itself, so `pip install shcl` adds a dependency and doesn't install a command. pip skips a beta without `--pre`:

~~~sh
pip install --pre shcl
~~~

### C and C++

There's no registry to target, and none is needed. `shcl.h` is a single dependency-free header you vendor, and C++ adds `shcl.hpp` beside it. See [C, C++](examples.md#c-c) for where to get it and how to build against it.

For version pinning and the dependency line per ecosystem, see [Example use-cases in your code](examples.md#example-use-cases-in-your-code).

## Packages and installers

This is the simplest route, if your system has a package manager. Download the `.deb`, `.rpm`, or Windows setup for your architecture (`x86_64` or `arm64`), or the FreeBSD `.pkg` (`x86_64` only), from the releases page.

Packages put the binary at `/usr/bin/shcl`, and the drop-in sources under `/usr/share/shcl/`. They also install the man page and the bash and zsh completions where each shell already looks, so `man shcl` and tab completion work with nothing to configure.

### Debian

~~~sh
sudo dpkg -i shcl-3.0.0-beta1-linux-x86_64.deb
~~~

### Fedora, RHEL, openSUSE

~~~sh
sudo rpm -i shcl-3.0.0-beta1-linux-x86_64.rpm
~~~

### FreeBSD

Run it as root on FreeBSD 14 or newer. The package puts everything under `/usr/local` rather than `/usr`, as FreeBSD packages do. The first release to have it is 3.0.0-beta1.

~~~sh
pkg add shcl-3.0.0-beta1-freebsd-x86_64.pkg
~~~

### Windows setup

Run `shcl-3.0.0-beta1-windows-x86_64-setup.exe`. It installs to `C:\Program Files\Shcl`, adds that to `PATH`, and can uninstall itself later.

## Install scripts, stable or dev

Each script downloads a release, checks its signature, and installs the binary plus the drop-in files. It's idempotent. An update also removes the Bash and PowerShell wrappers that older releases put in `scripts/`. It uses sane defaults, states its plan, and asks before touching anything. Pass `--help` (`-Help` on Windows) for the options.

The default is the newest full release. Until 3.0.0 is out that's still 2.0.0, which reads files by the 2.x rules. For the 3.0 beta this page describes, add `--release dev` (`-Release dev` on Windows).

Each release includes a `shcl-<version>-sha256sums.txt` and a detached `.sig` over it. The sums file lists every asset, including the binary, the packages, and the drop-in payload. Both installers include the release public key and verify that signature before they read any checksum out of the file, so replacing a release asset isn't enough to get past them. Nothing unverified is installed. A release without a signed drop-in payload gets the binary and a note that says what was skipped. On Linux, macOS, and FreeBSD this needs `openssl`, alongside `curl` or `wget`. There isn't an install-anyway fallback, so use the [DIY install](#diy-install) route on a machine that lacks it.

`install.bash` also lays down the man page and the shell completions. It symlinks the man page into the target's own `man1` directory, so `man shcl` works once the install directory is on your `PATH`, because man derives its search path from the `bin` directories there. Completions are left under `<install dir>/completions/` for you to enable, and the installer prints the line to paste for each shell. There isn't a single directory that works everywhere, and writing into the distribution's own is the packages' job rather than a tarball installer's.

### Linux, macOS, WSL and FreeBSD

~~~sh
bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
~~~

Options go at the end, after the closing parenthesis.

The prebuilt linux-x86_64 binary needs glibc 2.34 or newer (Ubuntu 22.04, Debian 12, RHEL 9, and later). On an older system, `cargo install shcl` builds against what's there.

On macOS nothing extra is needed, since bash, curl, and openssl come with it. The prebuilt binary is one universal file that runs on both Intel and Apple silicon Macs, and it needs macOS 13 or newer. The first release to have it is 3.0.0-beta1, so add `--release dev` until 3.0.0 is out.

On FreeBSD the script needs bash and curl (`pkg install bash curl`). The prebuilt binary is x86_64 only and needs FreeBSD 14 or newer. The first release to have it is 3.0.0-beta1, so add `--release dev` until 3.0.0 is out.

### Windows (PowerShell)

~~~powershell
irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1 | iex
~~~

`irm | iex` can't take any arguments, so for options use the scriptblock form:

~~~powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1))) -Help
~~~

The installer extracts the drop-in payload with `tar`, which Windows 10 1803, Server 2019, and later include. On an older Windows, use the setup `.exe` from the releases page instead.

shcl's messages and `fmt` output write an escape with `◉`, as in `◉NEWLINE◉`. Windows Terminal shows it. Consolas, the old console window's default font, has no `◉`, so switch that window to Cascadia Mono. PowerShell reads a program's output in the console code page, so `$out = shcl fmt app.shcl` turns each `◉` into `Γùë`. Run `[Console]::OutputEncoding = [Text.Encoding]::UTF8` first. Output that cmd sends to a file is fine.

| Target           | Linux, macOS and FreeBSD                                 | Windows
| :---             | :---                                                     | :---
| `user` (default) | `~/.local/share/shcl` plus a `~/.local/bin/shcl` symlink | `%LOCALAPPDATA%\Programs\Shcl`, added to your `PATH`
| `system`         | `/opt/shcl` plus a `/usr/local/bin/shcl` symlink         | `C:\Program Files\Shcl`, added to `PATH`

A `user` install needs no sudo or elevation. A `system` one does.

NetBSD and OpenBSD have no prebuilt binaries yet. Use `cargo install shcl`, a drop-in source file, or build the CLI.

## DIY install

- **Prebuilt binary**. Grab the `shcl` binary for your platform from the releases page and put it anywhere on your `PATH`. To check it by hand, download the sums file, its `.sig`, and [`shcl-signing.pub`](../shcl-signing.pub) from the repo, then verify the signature before the checksum. A checksum out of an unverified sums file doesn't prove anything:

	~~~sh
	openssl dgst -sha256 -verify shcl-signing.pub \
		-signature shcl-3.0.0-beta1-sha256sums.txt.sig shcl-3.0.0-beta1-sha256sums.txt
	sha256sum -c --ignore-missing shcl-3.0.0-beta1-sha256sums.txt
	~~~

	The macOS binary isn't notarized by Apple, so one saved from a web browser is quarantined and Gatekeeper refuses to run it. After checking it, clear that with `xattr -d com.apple.quarantine shcl`. The install script fetches with curl, which doesn't set the quarantine flag.

- **Drop-in source**. Copy one file into your project. There's no dependency and no build step. The file is `source/rust/src/lib.rs` for Rust, `source/go/shcl.go` for Go, `source/python/shcl.py` for Python, and `source/c/shcl.h` for C, and C++ adds `source/c/shcl.hpp` beside it.

- **Build the CLI**. The reference is in `source/rust/` and has zero dependencies:

	~~~sh
	cargo build --release --manifest-path source/rust/Cargo.toml
	# binary at source/rust/target/release/shcl
	~~~

	Release builds are reproducible. Build a tag yourself and compare against the published checksum.

	Each other binding builds with its own toolchain, such as `go build`, a C compiler, or a Python interpreter. All of them run the same conformance corpus.

## Set up a development environment

`install-dev.bash` clones the repo, installs the toolchains and linters the pipeline gates on as far as it can without sudo, and prints the package-manager hint for anything left over. It states its plan first:

~~~sh
bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install-dev.bash)
~~~

The pipeline runs on Linux. macOS is untested for it, and some checks need Linux. On Windows, use WSL, since the pipeline is bash. Then, from the clone:

~~~sh
cicd/cicd.bash --merge-gate --no-remote
~~~

`--merge-gate` is the whole gate: format check, build, lint, tests, the cross-binding differential, the release builds, and the leak checks. `--no-remote` leaves out the test boxes on the maintainer's network. GitHub runs the same on Linux without CodeQL and the cross targets, and it also runs jobs on Windows, Windows on ARM, Linux on ARM, and macOS. `--gate` is a check of about 4 minutes that leaves out the slow steps.

[`contributing.md`](../contributing.md) has the full list. It gives every toolchain and linter with its install command, the per-binding test commands, the extra tools a full cross-and-package run wants, and how to add a conformance case.
