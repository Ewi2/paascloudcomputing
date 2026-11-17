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
