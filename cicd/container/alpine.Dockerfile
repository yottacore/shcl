# musl, for 'cicd.bash --container=alpine'. It runs what CTR_ARGS_alpine in
# config.bash names: the build and the binding suites and CLI checks of the test
# stage. So only the tools those use, and no linters. Run now and then, not every
# time.
#
# Alpine has no snapshot archive and drops old package versions, so apk is pinned
# only as far as the base image. The toolchains below are pinned.
#
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]
# SPDX-License-Identifier: MIT

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# GNU coreutils, findutils and grep, since the gate scripts use stat -c, find
# -printf and the like. strace and mandoc are for cli-regress and perf-gate rows.
RUN apk add --no-cache \
		bash coreutils findutils grep sed gawk diffutils util-linux procps \
		ca-certificates curl wget openssl git xz tar file jq \
		gcc g++ musl-dev linux-headers \
		python3 strace mandoc

ARG RUSTUP_VER=1.29.1
ARG RUSTUP_SHA256=331228566cc931f32cd684f9bebc5956a5e5d7394c8d5de595f196a658ab98e6
ARG GO_VER=1.26.9
ARG GO_SHA256=42d158b4d8f7b61ac0a830567c940a86098fb7aac52e467a5ebec03ef5cc2f8d

WORKDIR /tmp/dl
RUN curl -fsSLo go.tgz "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" \
	&& echo "${GO_SHA256}  go.tgz" | sha256sum -c - \
	&& tar -C /opt -xzf go.tgz \
	&& curl -fsSLo rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/x86_64-unknown-linux-musl/rustup-init" \
	&& echo "${RUSTUP_SHA256}  rustup-init" | sha256sum -c - \
	&& chmod +x rustup-init \
	&& RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo ./rustup-init -y --no-modify-path --profile minimal --default-toolchain none \
	&& cd / && rm -rf /tmp/dl

# rust-toolchain.toml's toolchain on a musl host, with its components and targets.
ENV RUSTUP_HOME=/opt/rustup
COPY rust-toolchain.toml /opt/rustup-pin/
RUN cd /opt/rustup-pin && export CARGO_HOME=/opt/cargo \
	&& /opt/cargo/bin/rustup toolchain install \
	&& /opt/cargo/bin/rustup default "$(/opt/cargo/bin/rustup show active-toolchain | cut -d' ' -f1)"

RUN mkdir -m 1777 /cache
ENV PATH=/opt/cargo/bin:/opt/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/cache/home \
	CARGO_HOME=/cache/cargo \
	GOPATH=/cache/go \
	GOCACHE=/cache/go/build \
	GOMODCACHE=/cache/go/mod \
	GOTOOLCHAIN=local \
	LANG=C.UTF-8
WORKDIR /
