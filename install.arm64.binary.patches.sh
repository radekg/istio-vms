#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

arm64_patch_dir="${TEMP_DIR}/istio-proxy-${ISTIO_VERSION}-arm64"
rm -rf "${arm64_patch_dir}" && mkdir -p "${arm64_patch_dir}" && cd "${arm64_patch_dir}"
${CONTAINER_TOOL} create --name="istio-export-${ISTIO_REVISION}" "docker.io/istio/proxyv2:${ISTIO_VERSION}" --platform linux/arm64
${CONTAINER_TOOL} export istio-export-${ISTIO_REVISION} | tar x
${CONTAINER_TOOL} rm "istio-export-${ISTIO_REVISION}"
