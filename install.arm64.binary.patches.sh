#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

arm64_patch_dir="${TEMP_DIR}/istio-proxy-${ISTIO_VERSION}-arm64"
rm -rf "${arm64_patch_dir}" && mkdir -p "${arm64_patch_dir}" && cd "${arm64_patch_dir}"
docker create --name="istio-export-${ISTIO_REVISION}" "istio/proxyv2:${ISTIO_VERSION}" --platform linux/arm64
docker export istio-export-1-19-3 | tar x
docker rm "istio-export-${ISTIO_REVISION}"
