#!/bin/bash

delete="false"
recreate="false"

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

for var in "$@"
do
  [ "${var}" == "--delete" ] && delete="true"
  [ "${var}" == "--recreate" ] && recreate="true"
done

if [ "${delete}" == "true" ]; then
  echo >&2 "Deleting the workload machine..."
  multipass delete "${WORKLOAD_VM_NAME}"
  multipass purge
  exit 0
fi

if [ "${recreate}" == "true" ]; then
  echo >&2 "Recreating the workload machine..."
  rm -rfv "${DATA_DIR}/workload-files"
  multipass delete "${WORKLOAD_VM_NAME}"
  multipass purge
fi

set -u

multipass launch -c 2 -m 1G -d 4G -n "${WORKLOAD_VM_NAME}" "${RUN_OS}"
