#!/usr/bin/env bash
# Funciones comunes de las pruebas. Se carga con:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Las pruebas no usan "set -e": una comprobación fallida se cuenta y la prueba continúa.

# Los pods de prueba piden lo mínimo que admite el LimitRange para no restar capacidad a las aplicaciones.
# shellcheck disable=SC2034  # las usan los scripts que cargan este archivo
readonly PROBE_IMAGE=busybox:1.36
readonly PROBE_RESOURCES='{requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}'

PASSED=0
FAILED=0

info() { echo "== $*"; }
pass() { echo "PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $*"; FAILED=$((FAILED + 1)); }
die()  { echo "ERROR: $*" >&2; exit 2; }

# Cierra la prueba: imprime el resumen y devuelve 0 solo si no hubo fallas.
finish() {
  echo "Resultado: $PASSED OK, $FAILED con falla"
  [ "$FAILED" -eq 0 ]
}

# Comprueba que el tenant está dado de alta. Argumento: tenant.
require_tenant() {
  [ "$(kubectl get namespace "tenant-$1" --output 'jsonpath={.metadata.labels.paas/tenant}' 2>/dev/null)" = "$1" ] \
    || die "el tenant '$1' no está dado de alta (scripts/bootstrap.sh tenancy)"
}

# Tenants dados de alta en el clúster, uno por línea.
registered_tenants() {
  kubectl get namespace --selector paas/tenant \
    --output 'jsonpath={range .items[*]}{.metadata.labels.paas/tenant}{"\n"}{end}'
}

# Réplicas actuales de un Deployment (0 si no existe). Argumentos: namespace, nombre.
deployment_replicas() {
  local replicas
  replicas="$(kubectl -n "$1" get deployment "$2" --output 'jsonpath={.status.replicas}' 2>/dev/null)"
  echo "${replicas:-0}"
}

# Operaciones sobre las colas del broker de un tenant (Fase 5). Se ejecutan dentro del pod del
# broker, contra su API HTTP local y con las credenciales de su entorno: la clave no sale del pod.
#   publish <cola> <cantidad> [prioridad] [prefijo=Pedido]
#                         publica mensajes "<prefijo>_<n>" e imprime cuántos quedaron encolados
#   length <cola>...      imprime los mensajes pendientes de cada cola, separados por espacios
read -r -d '' BROKER_TOOL <<'TOOL' || true
api=http://127.0.0.1:15672/api
auth="Authorization: Basic $(printf '%s:%s' "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS" | base64)"
operation="$1"
shift
case "$operation" in
  publish)
    queue="$1" count="$2" prefix="${4:-Pedido}" properties='{}'
    [ -n "${3:-}" ] && properties="{\"priority\":$3}"
    routed=0
    i=1
    while [ "$i" -le "$count" ]; do
      body="{\"properties\":$properties,\"routing_key\":\"$queue\",\"payload\":\"${prefix}_$i\",\"payload_encoding\":\"string\"}"
      wget -q -O - --header "$auth" --header 'content-type: application/json' --post-data "$body" \
        "$api/exchanges/%2F/amq.default/publish" | grep -q '"routed": *true' && routed=$((routed + 1))
      i=$((i + 1))
    done
    echo "$routed"
    ;;
  length)
    lengths=""
    for queue in "$@"; do
      length="$(wget -q -O - --header "$auth" "$api/queues/%2F/$queue" | sed -n 's/.*"messages": *\([0-9]*\).*/\1/p')"
      lengths="$lengths ${length:-?}"
    done
    echo $lengths
    ;;
esac
TOOL
readonly BROKER_TOOL

# Argumentos: namespace, operación y sus argumentos (ver BROKER_TOOL).
broker() {
  local namespace="$1"
  shift
  kubectl -n "$namespace" exec deployment/rabbitmq -- sh -c "$BROKER_TOOL" broker "$@"
}

# Campo de un ScaledObject (vacío si no existe). Argumentos: namespace, nombre, ruta jsonpath.
scaler_field() {
  kubectl -n "$1" get scaledobject "$2" --output "jsonpath={$3}" 2>/dev/null
}
