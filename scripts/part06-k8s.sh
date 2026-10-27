#!/usr/bin/env bash
# Part 6: Kubernetes networking on a three-node kind cluster.
set -uo pipefail
cd "$(dirname "$0")/../part06"
source ../scripts/lib.sh

must kind create cluster --name net --config kind.yaml --wait 180s
must kubectl wait --for=condition=Ready nodes --all --timeout=180s
must kubectl -n kube-system wait --for=condition=Ready pods --all --timeout=180s

capture p6-k8s-nodes <<'CMD'
kubectl get nodes -o wide
CMD
capture p6-k8s-ns <<'CMD'
kubectl create namespace shop
CMD
capture p6-k8s-apply <<'CMD'
kubectl apply -f web.yaml
CMD
must kubectl -n shop rollout status deployment/web --timeout=180s
capture p6-k8s-pods <<'CMD'
kubectl -n shop get pods -o wide
CMD
capture p6-k8s-svc <<'CMD'
kubectl -n shop get service web
CMD
capture p6-k8s-eps <<'CMD'
kubectl -n shop get endpointslices -l kubernetes.io/service-name=web
CMD
capture p6-k8s-client <<'CMD'
kubectl -n shop run client --image=busybox:1.38 --labels app=client -- sleep 3600
CMD
must kubectl -n shop wait --for=condition=Ready pod/client --timeout=120s
capture p6-k8s-resolv <<'CMD'
kubectl -n shop exec client -- cat /etc/resolv.conf
CMD
capture p6-k8s-dns <<'CMD'
kubectl -n shop exec client -- nslookup web.shop.svc.cluster.local
CMD
capture p6-k8s-curl <<'CMD'
for i in 1 2 3 4 5 6; do kubectl -n shop exec client -- wget -qO- http://web | grep Hostname; done
CMD
capture p6-k8s-proxy-mode <<'CMD'
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep '^mode'
CMD
capture p6-k8s-netpol <<'CMD'
kubectl apply -f netpol.yaml
CMD
capture p6-k8s-intruder <<'CMD'
kubectl -n shop run intruder --image=busybox:1.38 --labels app=intruder -- sleep 3600
CMD
must kubectl -n shop wait --for=condition=Ready pod/intruder --timeout=120s
sleep 5
capture p6-k8s-allowed <<'CMD'
kubectl -n shop exec client -- wget -qO- -T 3 http://web | grep Hostname
CMD
capture p6-k8s-blocked <<'CMD'
kubectl -n shop exec intruder -- wget -qO- -T 3 http://web
CMD
must kind delete cluster --name net
