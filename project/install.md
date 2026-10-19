<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- hard tabs -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<!-- TOC ignore:true -->
# Installation

How to get the `shcl` CLI and the libraries, from a package manager to building it yourself, and how to set up a clone for development.

The latest release, `v2.0.0`, has packages, prebuilt CLI binaries, and a checksums file on the [releases page](https://github.com/yottacore/shcl/releases).

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
	- [Windows setup](#windows-setup)
- [Install scripts, stable or dev](#install-scripts-stable-or-dev)
	- [Linux, macOS, WSL and FreeBSD](#linux-macos-wsl-and-freebsd)
	- [Windows (PowerShell)](#windows-powershell)
- [DIY install](#diy-install)
- [Set up a development environment](#set-up-a-development-environment)

<!-- /TOC -->

## Language packages

Each binding is published where its own ecosystem looks for it, all under the name `shcl`: [crates.io](https://crates.io/crates/shcl) for Rust, [PyPI](https://pypi.org/project/shcl/) for Python, and the [Go module](https://pkg.go.dev/github.com/yottacore/shcl/source/go/v2) for Go.

Only the crate includes the CLI as well as the library, which is the easiest way to get the binary on a platform with no prebuilt one - NetBSD and OpenBSD included.

### Cargo

~~~sh
cargo install shcl
~~~

### Go module

The module is the library by itself and installs no command, so this is a dependency, not an installation:

~~~sh
go get github.com/yottacore/shcl/source/go/v2
~~~

### PyPI

The PyPI distribution is likewise the library by itself, so `pip install shcl` is a dependency, not an installation:

~~~sh
pip install shcl
~~~

### C and C++

No registry to target, and none needed: `shcl.h` is a single dependency-free header you vendor, and C++ adds `shcl.hpp` beside it. See [C, C++](examples.md#c-c) for where to get it and how to build against it.

For version pinning and the dependency line per ecosystem, see [Example use-cases in your code](examples.md#example-use-cases-in-your-code).

## Packages and installers

The simplest route, if your system has a package manager. Download the `.deb`, `.rpm`, or Windows setup for your architecture (`x86_64` or `arm64`) from the releases page.

Packages put the binary at `/usr/bin/shcl`, and the drop-in sources under `/usr/share/shcl/`. They also install the man page and the bash and zsh completions where each shell already looks, so `man shcl` and tab completion work with nothing to configure.

### Debian

~~~sh
sudo dpkg -i shcl-2.0.0-linux-x86_64.deb
~~~

### Fedora, RHEL, openSUSE

~~~sh
sudo rpm -i shcl-2.0.0-linux-x86_64.rpm
~~~

### Windows setup

Run `shcl-2.0.0-windows-x86_64-setup.exe`. It installs to `C:\Program Files\Shcl`, adds that to `PATH`, and can uninstall itself later.

## Install scripts, stable or dev

Downloads a release, checks its signature, and installs the binary plus the drop-in files. Idempotent. An update also removes the Bash and PowerShell wrappers that older releases put in `scripts/`. It uses sane defaults, states its plan, and asks before touching anything. Pass `--help` (`-Help` on Windows) for the options.

The default is the newest full release. Until 3.0.0 is out that is still 2.0.0, which reads files by the 2.x rules. For the 3.0 beta this page describes, add `--release dev` (`-Release dev` on Windows).

Each release includes a `shcl-<version>-sha256sums.txt` and a detached `.sig` over it, covering every asset - the binary, the packages, and the drop-in payload alike. Both installers include the release public key and verify that signature *before* reading any checksum out of the file, so replacing a release asset is not enough to get past them. Nothing unverified is installed: a release with no signed drop-in payload gets the binary and a note saying what was skipped. On Linux, macOS and FreeBSD this needs `openssl`, alongside `curl` or `wget`; there is no install-anyway fallback, so use the [DIY install](#diy-install) route on a machine that lacks it.

`install.bash` also lays down the man page and the shell completions. It symlinks the man page into the target's own `man1` directory, so `man shcl` works once the install directory is on your `PATH` - man derives its search path from the `bin` directories there. Completions are left under `<install dir>/completions/` for you to enable, and the installer prints the line to paste for each shell: there is no single directory that works everywhere, and writing into the distribution's own is the packages' job, not a tarball installer's.

### Linux, macOS, WSL and FreeBSD

~~~sh
bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install.bash)
~~~

Options go at the end, after the closing parenthesis.

The prebuilt linux-x86_64 binary needs glibc 2.34 or newer (Ubuntu 22.04, Debian 12, RHEL 9, and later). On an older system, `cargo install shcl` builds against what is there.

On macOS nothing extra is needed, since bash, curl and openssl come with it. The prebuilt binary is one universal file that runs on both Intel and Apple silicon Macs, and it needs macOS 13 or newer. The first release to have it is 3.0.0-beta1, so add `--release dev` until 3.0.0 is out.

On FreeBSD the script needs bash and curl (`pkg install bash curl`). The prebuilt binary is x86_64 only and needs FreeBSD 14 or newer. The first release to have it is 3.0.0-beta1, so add `--release dev` until 3.0.0 is out.

### Windows (PowerShell)

~~~powershell
irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1 | iex
~~~

`irm | iex` cannot take arguments at all, so for options use the scriptblock form:

~~~powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/yottacore/shcl/main/install.ps1))) -Help
~~~

The installer unpacks the drop-in payload with `tar`, which Windows 10 1803, Server 2019 and later include. On an older Windows, use the setup `.exe` from the releases page instead.

| Target           | Linux, macOS and FreeBSD                                 | Windows
| :---             | :---                                                     | :---
| `user` (default) | `~/.local/share/shcl` plus a `~/.local/bin/shcl` symlink | `%LOCALAPPDATA%\Programs\Shcl`, added to your `PATH`
| `system`         | `/opt/shcl` plus a `/usr/local/bin/shcl` symlink         | `C:\Program Files\Shcl`, added to `PATH`

A `user` install needs no sudo or elevation. A `system` one does.

NetBSD and OpenBSD have no prebuilt binaries yet. Use `cargo install shcl`, a drop-in source file, or build the CLI.

## DIY install

- **Prebuilt binary**. Grab the `shcl` binary for your platform from the releases page and put it anywhere on your `PATH`. To check it by hand, download the sums file, its `.sig`, and [`shcl-signing.pub`](../shcl-signing.pub) from the repo, then verify the signature before the checksum. A checksum out of an unverified sums file proves nothing:

	~~~sh
	openssl dgst -sha256 -verify shcl-signing.pub \
		-signature shcl-2.0.0-sha256sums.txt.sig shcl-2.0.0-sha256sums.txt
	sha256sum -c --ignore-missing shcl-2.0.0-sha256sums.txt
	~~~

	The macOS binary is not notarized by Apple, so one saved from a web browser is quarantined and Gatekeeper refuses to run it. After checking it, clear that with `xattr -d com.apple.quarantine shcl`. The install script fetches with curl, which sets no quarantine.

- **Drop-in source**. Copy one file into your project. No dependency, no build step. Rust `source/rust/src/lib.rs`, Go `source/go/shcl.go`, Python `source/python/shcl.py`, C `source/c/shcl.h`.

- **Build the CLI**. The reference lives in `source/rust/` and has zero dependencies:

	~~~sh
	cargo build --release --manifest-path source/rust/Cargo.toml
	# binary at source/rust/target/release/shcl
	~~~

	Release builds are reproducible. Build a tag yourself and compare against the published checksum.

	Each other binding builds with its own toolchain (`go build`, a C compiler, a Python interpreter). All of them run the same conformance corpus.

## Set up a development environment

`install-dev.bash` clones the repo, installs the toolchains and linters the pipeline gates on as far as it can without sudo, and prints the package-manager hint for anything left over. It states its plan first:

~~~sh
bash <(curl -fsSL https://raw.githubusercontent.com/yottacore/shcl/main/install-dev.bash)
~~~

The pipeline runs on Linux. macOS is untested for it, and some checks need Linux. On Windows, use WSL, since the pipeline is bash. Then, from the clone:

~~~sh
cicd/cicd.bash --gate
~~~

`--gate` is the whole gate: format check, build, lint, tests, and the cross-binding differential. It is the same thing GitHub runs on Linux. GitHub also runs a Windows job that `--gate` does not.

[`contributing.md`](../contributing.md) has the full list - every toolchain and linter with its install command, the per-binding test commands, the extra tools a full cross-and-package run wants, and how to add a conformance case.
