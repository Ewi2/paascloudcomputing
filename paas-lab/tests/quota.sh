#!/usr/bin/env bash
# ResourceQuota de un tenant (CPU y storage). Uso: tests/quota.sh <alpha|beta>
# KEEP=1 conserva el Deployment de prueba para observar las alertas de cuota (borrar después).
set -uo pipefail
T="${1:?uso: $0 <alpha|beta>}"; NS="tenant-$T"; REQ=250; fail=0

hard() { kubectl -n "$NS" get resourcequota paas-quota -o "jsonpath={.spec.hard.$1}"; }
cpu="$(hard 'requests\.cpu')"; pvcs="$(hard persistentvolumeclaims)"
case "$cpu" in *m) mcpu="${cpu%m}" ;; *) mcpu=$((cpu * 1000)) ;; esac
REPLICAS=$((mcpu / REQ + 4))

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  kubectl -n "$NS" delete deploy quota-probe --ignore-not-found --now >/dev/null 2>&1
  kubectl -n "$NS" delete pvc -l paas/test=quota --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

echo "== CPU: $REPLICAS réplicas x ${REQ}m contra cuota requests.cpu=$cpu"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: quota-probe}
spec:
  replicas: $REPLICAS
  selector: {matchLabels: {app: quota-probe}}
  template:
    metadata: {labels: {app: quota-probe}}
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests: {cpu: ${REQ}m, memory: 32Mi}
          limits: {cpu: ${REQ}m, memory: 32Mi}
EOF
sleep 20
if kubectl -n "$NS" get events --field-selector reason=FailedCreate -o jsonpath='{.items[*].message}' | grep -q 'quota-probe.*exceeded quota'; then
  echo "PASS  el ReplicaSet recibió 'exceeded quota' al superar la cuota de CPU"
else
  echo "FAIL  no se registró 'exceeded quota' (kubectl -n $NS describe rs)"; fail=1
fi

echo "== Storage: creando $((pvcs + 1)) PVC de 100Mi contra persistentvolumeclaims=$pvcs"
out=""
for i in $(seq $((pvcs + 1))); do
  out="$(kubectl -n "$NS" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: quota-pvc-$i, labels: {paas/test: quota}}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 100Mi}}}
EOF
)"
done
if grep -q 'exceeded quota' <<<"$out"; then
  echo "PASS  el último PVC fue rechazado por la cuota"
else
  echo "FAIL  el último PVC no fue rechazado: $out"; fail=1
fi

echo; kubectl -n "$NS" describe resourcequota paas-quota | sed -n '1,25p'
exit "$fail"
