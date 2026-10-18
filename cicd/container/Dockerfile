# Build and test tools for 'cicd.bash --container', pinned, so stages 1 to 6 don't
# depend on what the build box has installed or on another project's toolchain.
# Sync, dogfood, the demo gif and publish stay on the host.
#
# cicd.bash builds this from a copy of cicd/container/ plus rust-toolchain.toml,
# and tags it with a hash of those files, so an edit to any of them means a new
# image. Tool versions match TOOL_PINS in config.bash, and check-pins.bash says
# when they don't.
#
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
# SPDX-License-Identifier: MIT

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# Apt reads the snapshot the base image was cut from (its sources name it), so a
# trixie point release can't move gcc or anything else under the gate.
ARG APT_SNAP=20261005T000000Z
RUN sed -i -e "s|^URIs: http://deb.debian.org/debian-security|URIs: http://snapshot.debian.org/archive/debian-security/${APT_SNAP}|" \
		-e "s|^URIs: http://deb.debian.org/debian\$|URIs: http://snapshot.debian.org/archive/debian/${APT_SNAP}|" \
		-e 's|^Signed-By:|Check-Valid-Until: no\nSigned-By:|' /etc/apt/sources.list.d/debian.sources \
	&& ! grep -q deb.debian.org /etc/apt/sources.list.d/debian.sources

# gcc-12 and gcc-13 next to the default 14, and clang, for check-c-compilers;
# 13 is the hosted runner's. zsh, bash-completion, nsis, rpm, man-db, strace,
# locales and jq are for rows in the test stage that fail a skip under --ci.
# qemu, busybox and cpio boot the CPU floor check. libicu and libgssapi are for pwsh.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bash ca-certificates curl wget openssl git xz-utils unzip file jq \
		gcc g++ gcc-12 gcc-13 clang libc6-dev binutils \
		gcc-mingw-w64-x86-64 nsis rpm \
		python3 python3-venv \
		zsh bash-completion strace locales man-db \
		qemu-system-x86 busybox cpio \
		libicu76 libgssapi-krb5-2 \
	&& rm -rf /var/lib/apt/lists/*

# The snapshot decides nsis's version, so this says when it isn't the pin.
ARG MAKENSIS_VER=3.11
RUN v="$(makensis -VERSION)" && case "${v}" in "v${MAKENSIS_VER}"|"v${MAKENSIS_VER}-"*) ;; *) echo "makensis ${v}"; exit 1 ;; esac

# The CPU floor check boots a kernel that runs on x86-64-v1, as Debian's does.
# Only the image file is kept, not the modules.
RUN cd /tmp && apt-get update \
	&& kpkg="$(apt-cache depends linux-image-amd64 | sed -n 's/^ *Depends: //p' | head -n 1)" \
	&& apt-get download "${kpkg}" \
	&& mkdir -p /opt/floor && dpkg-deb --fsys-tarfile ./*.deb | tar -xf - -C /tmp --wildcards './boot/vmlinuz-*' \
	&& mv /tmp/boot/vmlinuz-* /opt/floor/vmlinuz && chmod 644 /opt/floor/vmlinuz \
	&& rm -rf /tmp/boot ./*.deb /var/lib/apt/lists/*

ARG RUSTUP_VER=1.29.1
ARG RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARG GO_VER=1.26.9
ARG GO_SHA256=42d158b4d8f7b61ac0a830567c940a86098fb7aac52e467a5ebec03ef5cc2f8d
ARG ZIG_VER=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG SHELLCHECK_VER=0.11.0
ARG SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARG CARGO_DENY_VER=0.19.9
ARG CARGO_DENY_SHA256=f1f8eedc2a3ac297c540873f93785d4104b102c0079506b2a6b3221b7ec956af
ARG PWSH_VER=7.6.6
ARG PWSH_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
# PSGallery posts no checksum, so this one is from the download.
ARG PSSCRIPTANALYZER_VER=1.25.0
ARG PSSCRIPTANALYZER_SHA256=14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60
# Only here for markdownlint-cli2.
ARG NODE_VER=22.23.2
ARG NODE_SHA256=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307

WORKDIR /tmp/dl
RUN curl -fsSLo go.tgz "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" \
	&& echo "${GO_SHA256}  go.tgz" | sha256sum -c - \
	&& tar -C /opt -xzf go.tgz \
	&& curl -fsSLo zig.txz "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz" \
	&& echo "${ZIG_SHA256}  zig.txz" | sha256sum -c - \
	&& mkdir /opt/zig && tar -C /opt/zig --strip-components=1 -xJf zig.txz \
	&& curl -fsSLo sc.txz "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VER}/shellcheck-v${SHELLCHECK_VER}.linux.x86_64.tar.xz" \
	&& echo "${SHELLCHECK_SHA256}  sc.txz" | sha256sum -c - \
	&& tar -C /usr/local/bin --strip-components=1 -xJf sc.txz "shellcheck-v${SHELLCHECK_VER}/shellcheck" \
	&& curl -fsSLo deny.tgz "https://github.com/EmbarkStudios/cargo-deny/releases/download/${CARGO_DENY_VER}/cargo-deny-${CARGO_DENY_VER}-x86_64-unknown-linux-musl.tar.gz" \
	&& echo "${CARGO_DENY_SHA256}  deny.tgz" | sha256sum -c - \
	&& tar -C /usr/local/bin --strip-components=1 -xzf deny.tgz "cargo-deny-${CARGO_DENY_VER}-x86_64-unknown-linux-musl/cargo-deny" \
	&& curl -fsSLo pwsh.tgz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-x64.tar.gz" \
	&& echo "${PWSH_SHA256}  pwsh.tgz" | sha256sum -c - \
	&& mkdir /opt/pwsh && tar -C /opt/pwsh -xzf pwsh.tgz && chmod +x /opt/pwsh/pwsh \
	&& ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh \
	&& curl -fsSLo psa.nupkg "https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/${PSSCRIPTANALYZER_VER}" \
	&& echo "${PSSCRIPTANALYZER_SHA256}  psa.nupkg" | sha256sum -c - \
	&& psa="/usr/local/share/powershell/Modules/PSScriptAnalyzer/${PSSCRIPTANALYZER_VER}" \
	&& mkdir -p "${psa}" && unzip -q psa.nupkg -d "${psa}" \
	&& rm -rf "${psa}/_rels" "${psa}/package" "${psa}/[Content_Types].xml" "${psa}/PSScriptAnalyzer.nuspec" \
	&& curl -fsSLo node.txz "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz" \
	&& echo "${NODE_SHA256}  node.txz" | sha256sum -c - \
	&& mkdir /opt/node && tar -C /opt/node --strip-components=1 -xJf node.txz \
	&& cd / && rm -rf /tmp/dl

# The toolchain, components and targets rust-toolchain.toml names, checked by
# rustup against the release manifest. Also the default, for cargo run outside
# the repo, such as a test's scratch crate.
ENV RUSTUP_HOME=/opt/rustup
COPY rust-toolchain.toml /opt/rustup-pin/
RUN curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/x86_64-unknown-linux-gnu/rustup-init" \
	&& echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
	&& chmod +x /tmp/rustup-init \
	&& CARGO_HOME=/opt/cargo /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none \
	&& cd /opt/rustup-pin && export CARGO_HOME=/opt/cargo \
	&& /opt/cargo/bin/rustup toolchain install \
	&& /opt/cargo/bin/rustup default "$(/opt/cargo/bin/rustup show active-toolchain | cut -d' ' -f1)" \
	&& rm -f /tmp/rustup-init

# The dated nightly from the same file's [nightly] table, for sanitize-rust.bash.
# Miri's own std is built here once, rather than by the first run of each cache.
ENV MIRI_SYSROOT=/opt/miri-sysroot
RUN cd /opt/rustup-pin && export CARGO_HOME=/opt/cargo \
	&& nightly="$(sed -n '/^\[nightly\]/,/^\[/s/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)" \
	&& comps="$(sed -n '/^\[nightly\]/,/^\[/s/^components = \[\(.*\)\]/\1/p' rust-toolchain.toml | tr -d '" ')" \
	&& /opt/cargo/bin/rustup toolchain install "${nightly}" --profile minimal --component "${comps}" \
	&& /opt/cargo/bin/cargo "+${nightly}" miri setup \
	&& rm -rf /opt/cargo/registry
# Rust's ASan runtime is LLVM's, which names no frame in a report without this.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends llvm-19 \
	&& rm -rf /var/lib/apt/lists/*

# Built by the toolchain above, from the module proxy and its checksum db.
ARG STATICCHECK_VER=2026.1
ARG GOVULNCHECK_VER=v1.5.0
ARG NFPM_VER=v2.47.0
RUN export GOTOOLCHAIN=local GOBIN=/usr/local/bin GOPATH=/tmp/gopath GOCACHE=/tmp/gocache \
	&& /opt/go/bin/go install "honnef.co/go/tools/cmd/staticcheck@${STATICCHECK_VER}" \
	&& /opt/go/bin/go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VER}" \
	&& /opt/go/bin/go install "github.com/goreleaser/nfpm/v2/cmd/nfpm@${NFPM_VER}" \
	&& rm -rf /tmp/gopath /tmp/gocache

# Every wheel by hash, dependencies included.
COPY requirements.txt /opt/venv-pin/
RUN python3 -m venv /opt/venv \
	&& /opt/venv/bin/pip install --no-cache-dir --no-deps --require-hashes -r /opt/venv-pin/requirements.txt

# markdownlint-cli2 and its dependencies from the lock file, each by its integrity hash.
COPY package.json package-lock.json /opt/mdl/
RUN cd /opt/mdl && PATH="/opt/node/bin:${PATH}" npm ci --no-fund --no-audit --ignore-scripts \
	&& ln -s /opt/mdl/node_modules/.bin/markdownlint-cli2 /usr/local/bin/markdownlint-cli2

# Runs as the caller's uid, which has no passwd entry here. /cache is the cache
# dir cicd.bash mounts from the host.
RUN mkdir -m 1777 /cache
ENV PATH=/opt/venv/bin:/opt/cargo/bin:/opt/go/bin:/opt/zig:/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/cache/home \
	CARGO_HOME=/cache/cargo \
	GOPATH=/cache/go \
	GOCACHE=/cache/go/build \
	GOMODCACHE=/cache/go/mod \
	GOTOOLCHAIN=local \
	LANG=C.UTF-8 \
	SHCL_FLOOR_KERNEL=/opt/floor/vmlinuz \
	POWERSHELL_TELEMETRY_OPTOUT=1 \
	POWERSHELL_UPDATECHECK=Off \
	DOTNET_CLI_TELEMETRY_OPTOUT=1
WORKDIR /
