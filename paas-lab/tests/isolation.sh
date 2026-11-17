#!/usr/bin/env bash
# Aislamiento de red entre dos tenants (Fase 1): ICMP y TCP en ambos sentidos.
# Si la Fase 5 está instalada, comprueba también que un tenant no alcanza el broker del otro.
#
# Uso: tests/isolation.sh [tenantA=alpha] [tenantB=beta]
# Requiere un CNI que aplique NetworkPolicy (Calico). ARP es de capa 2 y queda fuera del
# alcance de NetworkPolicy.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly PROBE_PORT=8080
readonly TENANT_A="${1:-alpha}"
readonly TENANT_B="${2:-beta}"
require_tenant "$TENANT_A"
require_tenant "$TENANT_B"
readonly NS_A="tenant-$TENANT_A"
readonly NS_B="tenant-$TENANT_B"

cleanup() {
  kubectl -n "$NS_A" delete pod --selector paas/test=isolation --now --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NS_B" delete pod --selector paas/test=isolation --now --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

# Crea un pod que responde HTTP en PROBE_PORT. Argumentos: namespace, nombre.
probe_pod() {
  kubectl -n "$1" apply -f - >/dev/null <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $2
  labels: {paas/test: isolation}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  - name: probe
    image: $PROBE_IMAGE
    command: ["sh", "-c", "echo ok > /tmp/index.html; exec httpd -f -p $PROBE_PORT -h /tmp"]
    resources: $PROBE_RESOURCES
MANIFEST
}

pod_ip() { kubectl -n "$1" get pod "$2" --output 'jsonpath={.status.podIP}'; }

# Ejecuta un comando dentro de un pod y compara el resultado con lo esperado.
# Argumentos: descripción, permitido|bloqueado, namespace, pod, comando...
check() {
  local description="$1" expected="$2" namespace="$3" pod="$4" actual=bloqueado
  shift 4
  kubectl -n "$namespace" exec "$pod" -- "$@" >/dev/null 2>&1 && actual=permitido
  if [ "$actual" = "$expected" ]; then
    pass "$description ($expected)"
  else
    fail "$description (esperado: $expected; obtenido: $actual)"
  fi
}

info "Creando pods de prueba en $NS_A y $NS_B"
probe_pod "$NS_A" probe-1
probe_pod "$NS_A" probe-2
probe_pod "$NS_B" probe-1
kubectl -n "$NS_A" wait --for=condition=Ready pod/probe-1 pod/probe-2 --timeout=120s >/dev/null \
  || die "los pods de prueba de $NS_A no arrancaron"
kubectl -n "$NS_B" wait --for=condition=Ready pod/probe-1 --timeout=120s >/dev/null \
  || die "el pod de prueba de $NS_B no arrancó"
IP_A="$(pod_ip "$NS_A" probe-2)"
IP_B="$(pod_ip "$NS_B" probe-1)"
readonly IP_A IP_B

check "$TENANT_A -> $TENANT_A  ICMP" permitido "$NS_A" probe-1 ping -c 2 -W 2 "$IP_A"
check "$TENANT_A -> $TENANT_A  TCP $PROBE_PORT" permitido "$NS_A" probe-1 wget -q -T 3 -O /dev/null "http://$IP_A:$PROBE_PORT/"
check "$TENANT_A -> DNS del clúster" permitido "$NS_A" probe-1 nslookup kubernetes.default.svc.cluster.local
check "$TENANT_A -> $TENANT_B  ICMP" bloqueado "$NS_A" probe-1 ping -c 2 -W 2 "$IP_B"
check "$TENANT_A -> $TENANT_B  TCP $PROBE_PORT" bloqueado "$NS_A" probe-1 wget -q -T 3 -O /dev/null "http://$IP_B:$PROBE_PORT/"
check "$TENANT_B -> $TENANT_A  ICMP" bloqueado "$NS_B" probe-1 ping -c 2 -W 2 "$IP_A"
check "$TENANT_B -> $TENANT_A  TCP $PROBE_PORT" bloqueado "$NS_B" probe-1 wget -q -T 3 -O /dev/null "http://$IP_A:$PROBE_PORT/"

if kubectl -n "$NS_A" get service rabbitmq >/dev/null 2>&1; then
  check "$TENANT_A -> su broker (API HTTP 15672)" permitido "$NS_A" probe-1 \
    wget -q -T 3 -O /dev/null http://rabbitmq:15672/
  check "$TENANT_B -> broker de $TENANT_A (API HTTP 15672)" bloqueado "$NS_B" probe-1 \
    wget -q -T 3 -O /dev/null "http://rabbitmq.$NS_A.svc.cluster.local:15672/"
fi

finish
