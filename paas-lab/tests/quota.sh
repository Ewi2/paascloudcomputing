#!/usr/bin/env bash
# ResourceQuota de un tenant (Fase 1): comprueba que el exceso de CPU y de PVC se rechaza.
#
# Uso: tests/quota.sh <tenant>
# KEEP=1 conserva los recursos de prueba para observar las alertas de cuota. Borrarlos después:
#   kubectl -n tenant-<t> delete deployment,pvc --selector paas/test=quota
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly REQUEST_MILLICPU=250          # CPU que pide cada réplica de prueba
readonly EXTRA_REPLICAS=4              # réplicas por encima de las que caben en la cuota
readonly SETTLE_SECONDS=20             # tiempo para que el ReplicaSet intente crear todos los pods
readonly TENANT="${1:?uso: $0 <tenant>}"
require_tenant "$TENANT"
readonly NS="tenant-$TENANT"

quota_hard() { kubectl -n "$NS" get resourcequota paas-quota --output "jsonpath={.spec.hard.$1}"; }

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  kubectl -n "$NS" delete deployment,pvc --selector paas/test=quota --ignore-not-found --now >/dev/null 2>&1
}
trap cleanup EXIT

cpu_quota="$(quota_hard 'requests\.cpu')"
pvc_quota="$(quota_hard persistentvolumeclaims)"
case "$cpu_quota" in
  *m) cpu_quota_milli="${cpu_quota%m}" ;;
  *)  cpu_quota_milli=$((cpu_quota * 1000)) ;;
esac
replicas=$((cpu_quota_milli / REQUEST_MILLICPU + EXTRA_REPLICAS))

# Los pods que la cuota admite pueden quedar en Pending (el nodo tiene menos CPU libre que la
# cuota): no afecta a la prueba, porque la cuota se evalúa al crear el pod, antes de planificarlo.
info "CPU: $replicas réplicas x ${REQUEST_MILLICPU}m contra la cuota requests.cpu=$cpu_quota"
kubectl -n "$NS" apply -f - >/dev/null <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quota-probe
  labels: {paas/test: quota}
spec:
  replicas: $replicas
  selector: {matchLabels: {app: quota-probe}}
  template:
    metadata: {labels: {app: quota-probe}}
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests: {cpu: ${REQUEST_MILLICPU}m, memory: 32Mi}
          limits: {cpu: ${REQUEST_MILLICPU}m, memory: 32Mi}
MANIFEST
sleep "$SETTLE_SECONDS"
if kubectl -n "$NS" get events --field-selector reason=FailedCreate --output 'jsonpath={.items[*].message}' \
    | grep -q 'quota-probe.*exceeded quota'; then
  pass "el ReplicaSet recibió 'exceeded quota' al superar la cuota"
else
  fail "no se registró 'exceeded quota' (kubectl -n $NS describe replicaset)"
fi

info "Storage: $((pvc_quota + 1)) PVC de 100Mi contra la cuota persistentvolumeclaims=$pvc_quota"
last_output=""
for i in $(seq $((pvc_quota + 1))); do
  last_output="$(kubectl -n "$NS" apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: quota-probe-$i
  labels: {paas/test: quota}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
MANIFEST
)"
done
if grep -q 'exceeded quota' <<<"$last_output"; then
  pass "el último PVC fue rechazado por la cuota"
else
  fail "el último PVC no fue rechazado: $last_output"
fi

echo
kubectl -n "$NS" describe resourcequota paas-quota
finish
