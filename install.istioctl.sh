#!/bin/bash
local_bin="${HOME}/.local/test-istio-vm-multipass/bin"
mkdir -p "${local_bin}/tmp/"
export PATH="${local_bin}:/usr/local/bin:${PATH}"
export ISTIO_VERSION=${ISTIO_VERSION:-1.19.3}
export ISTIO_ARCH=${ISTIO_ARCH:-osx-arm64}
wget "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz" -O "${local_bin}/tmp/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz"
tar xvzf "${local_bin}/tmp/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz" -C "${local_bin}/tmp"
mv -v "${local_bin}/tmp/istioctl" "${local_bin}/istioctl-${ISTIO_VERSION}"
ln -sfv "${local_bin}/istioctl-${ISTIO_VERSION}" "${local_bin}/istioctl"
rm -rf "${local_bin}/tmp/*"
