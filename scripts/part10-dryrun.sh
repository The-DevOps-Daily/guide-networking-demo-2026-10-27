#!/usr/bin/env bash
# Part 10: validate the mesh, Gateway API and Cilium manifests against the projects' CRDs.
set -uo pipefail
cd "$(dirname "$0")/../part10"
source ../scripts/lib.sh
must kind create cluster --name crds --wait 180s
must kubectl apply --server-side -f https://raw.githubusercontent.com/istio/istio/1.31.3/manifests/charts/base/files/crd-all.gen.yaml
must kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
must kubectl apply --server-side -f https://raw.githubusercontent.com/cilium/cilium/v1.20.4/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml
must kubectl wait --for=condition=Established crd --all --timeout=120s
must kubectl create namespace shop
capture p10-dry-run <<'CMD'
kubectl apply --dry-run=server -f mesh.yaml -f gateway.yaml -f cilium-l7.yaml
CMD
must kind delete cluster --name crds
