#!/bin/bash
base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"
export PATH="${BIN_DIR}:${PATH}"
export ISTIO_VERSION=${ISTIO_VERSION:-1.19.3}
export ISTIO_ARCH=${ISTIO_ARCH:-osx-arm64}
wget "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz" -O "${TEMP_DIR}/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz"
tar xvzf "${TEMP_DIR}/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz" -C "${TEMP_DIR}"
mv -v "${TEMP_DIR}/istioctl" "${BIN_DIR}/istioctl-${ISTIO_VERSION}"
ln -sfv "${BIN_DIR}/istioctl-${ISTIO_VERSION}" "${BIN_DIR}/istioctl"
