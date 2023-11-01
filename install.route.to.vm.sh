#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

kubectl apply -n vmns -f - <<EOP
apiVersion: v1
kind: Service
metadata:
  labels:
    app: external-app
  name: external-app
spec:
  ports:
  - name: http
    port: 8000
    protocol: TCP
    targetPort: 8000
  selector:
    app: external-app
EOP
