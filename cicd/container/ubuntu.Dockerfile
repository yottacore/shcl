# The hosted runner's OS for 'cicd.bash --container=ubuntu': Ubuntu 24.04 and
# its gcc 13, so a red that shows only on hosted CI can be reproduced here. It
# runs what CTR_ARGS_ubuntu in config.bash names, so it has the tools for the
# build and test stages and the cross checks, and no linters. Run now and then,
# not every time.
#
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
# SPDX-License-Identifier: MIT

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

# Apt reads the live archive, not a snapshot, since the runner's image takes
# Ubuntu's updates as they come and this is here to match it.
#
# gcc 13 is the default here, as on the runner; 12, 14 and clang are for
# check-c-compilers, which the runner has too. The rest are rows in the test
# stage that fail a skip under --gate, and tzdata is for rows that pin a zone.
# libicu and libgssapi are for pwsh. The image's man is a stub that says it was
# minimized, so the real one is put back, as the runner has it. Ubuntu's mawk
# reads #{2,5} wrong, and the runner's awk is gawk.
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		bash ca-certificates curl wget openssl git xz-utils unzip file jq tzdata gawk \
		gcc g++ gcc-12 gcc-14 clang libc6-dev binutils \
		gcc-mingw-w64-x86-64 nsis rpm \
		zsh bash-completion strace locales man-db \
		libicu74 libgssapi-krb5-2 \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm /usr/bin/man && dpkg-divert --quiet --remove --rename /usr/bin/man

ARG RUSTUP_VER=1.29.1
ARG RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARG GO_VER=1.26.9
ARG GO_SHA256=42d158b4d8f7b61ac0a830567c940a86098fb7aac52e467a5ebec03ef5cc2f8d
ARG PWSH_VER=7.6.6
ARG PWSH_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
# The runner's Python comes from setup-python at 3.13, not Ubuntu's 3.12.
ARG PYTHON_VER=3.13.16
ARG PYTHON_BUILD=20261009
ARG PYTHON_SHA256=1cca1041f693f110a2e0d16417090b8996258c7a121e90eeab66c2f40ea407f2

WORKDIR /tmp/dl
RUN curl -fsSLo go.tgz "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" \
	&& echo "${GO_SHA256}  go.tgz" | sha256sum -c - \
	&& tar -C /opt -xzf go.tgz \
	&& curl -fsSLo pwsh.tgz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-x64.tar.gz" \
	&& echo "${PWSH_SHA256}  pwsh.tgz" | sha256sum -c - \
	&& mkdir /opt/pwsh && tar -C /opt/pwsh -xzf pwsh.tgz && chmod +x /opt/pwsh/pwsh \
	&& ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh \
	&& curl -fsSLo py.tgz "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD}/cpython-${PYTHON_VER}+${PYTHON_BUILD}-x86_64-unknown-linux-gnu-install_only.tar.gz" \
	&& echo "${PYTHON_SHA256}  py.tgz" | sha256sum -c - \
	&& tar -C /opt -xzf py.tgz \
	&& curl -fsSLo rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/x86_64-unknown-linux-gnu/rustup-init" \
	&& echo "${RUSTUP_SHA256}  rustup-init" | sha256sum -c - \
	&& chmod +x rustup-init \
	&& RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo ./rustup-init -y --no-modify-path --profile minimal --default-toolchain none \
	&& cd / && rm -rf /tmp/dl

# rust-toolchain.toml's toolchain, components and targets, each download checked
# against the release manifest.
ENV RUSTUP_HOME=/opt/rustup
COPY rust-toolchain.toml /opt/rustup-pin/
RUN cd /opt/rustup-pin && export CARGO_HOME=/opt/cargo \
	&& /opt/cargo/bin/rustup toolchain install \
	&& /opt/cargo/bin/rustup default "$(/opt/cargo/bin/rustup show active-toolchain | cut -d' ' -f1)"

# The dated nightly under [nightly] in the same file, for sanitize-rust.bash, as
# the main image has it.
ENV MIRI_SYSROOT=/opt/miri-sysroot
RUN cd /opt/rustup-pin && export CARGO_HOME=/opt/cargo \
	&& nightly="$(sed -n '/^\[nightly\]/,/^\[/s/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)" \
	&& comps="$(sed -n '/^\[nightly\]/,/^\[/s/^components = \[\(.*\)\]/\1/p' rust-toolchain.toml | tr -d '" ')" \
	&& /opt/cargo/bin/rustup toolchain install "${nightly}" --profile minimal --component "${comps}" \
	&& /opt/cargo/bin/cargo "+${nightly}" miri setup \
	&& rm -rf /opt/cargo/registry

# staticcheck for the Go cross check, nfpm for the stub package rows.
ARG STATICCHECK_VER=2026.1
ARG NFPM_VER=v2.47.0
RUN export GOTOOLCHAIN=local GOBIN=/usr/local/bin GOPATH=/tmp/gopath GOCACHE=/tmp/gocache \
	&& /opt/go/bin/go install "honnef.co/go/tools/cmd/staticcheck@${STATICCHECK_VER}" \
	&& /opt/go/bin/go install "github.com/goreleaser/nfpm/v2/cmd/nfpm@${NFPM_VER}" \
	&& rm -rf /tmp/gopath /tmp/gocache

# Only Pillow, for the demo gif's output order row, by the main image's hash.
COPY requirements.txt /opt/py-pin/
RUN grep -A1 '^pillow==' /opt/py-pin/requirements.txt > /opt/py-pin/pillow.txt \
	&& /opt/python/bin/python3 -m pip install --no-cache-dir --no-deps --require-hashes -r /opt/py-pin/pillow.txt

RUN mkdir -m 1777 /cache
ENV PATH=/opt/python/bin:/opt/cargo/bin:/opt/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/cache/home \
	CARGO_HOME=/cache/cargo \
	GOPATH=/cache/go \
	GOCACHE=/cache/go/build \
	GOMODCACHE=/cache/go/mod \
	GOTOOLCHAIN=local \
	LANG=C.UTF-8 \
	POWERSHELL_TELEMETRY_OPTOUT=1 \
	POWERSHELL_UPDATECHECK=Off \
	DOTNET_CLI_TELEMETRY_OPTOUT=1
WORKDIR /
