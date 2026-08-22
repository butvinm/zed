#!/usr/bin/env bash
set -euxo pipefail
CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 cargo build --release -p zed
