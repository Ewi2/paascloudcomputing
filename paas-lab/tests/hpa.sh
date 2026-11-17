#!/usr/bin/env bash
# Autoescalado por peticiones del Ingress (Fase 3): genera carga HTTP contra la aplicación de
# un tenant y comprueba que el HPA aumenta las réplicas.
#
# Uso: tests/hpa.sh <tenant> [segundos=240]
# WAIT_DOWN=1 espera además a que el HPA vuelva al mínimo (varios minutos más).
# INGRESS_ADDR cambia la dirección del Ingress (por defecto, la IP de Minikube).
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly POLL_SECONDS=10
readonly SCALE_DOWN_TIMEOUT=420
readonly RATE_LIMIT_ANNOTATION='nginx\.ingress\.kubernetes\.io/limit-rps'
# Valores actuales de las dos métricas del HPA. La de Ingress puede venir en milésimas (12500m = 12.5).
readonly CPU_METRIC='.status.currentMetrics[?(@.type=="Resource")].resource.current.averageUtilization'
readonly INGRESS_METRIC='.status.currentMetrics[?(@.type=="Object")].object.current.averageValue'
readonly TENANT="${1:?uso: $0 <tenant> [segundos]}"
readonly DURATION="${2:-240}"
require_tenant "$TENANT"
readonly NS="tenant-$TENANT"

hpa_field() { kubectl -n "$NS" get hpa "$APP" --output "jsonpath={$1}"; }

current_replicas() {
  local replicas
  replicas="$(hpa_field .status.currentReplicas)"
  echo "${replicas:-0}"
}

# Envía una ráfaga por segundo sobre una sola conexión. Cada ráfaga duplica el límite del plan:
# NGINX atiende lo que el límite permite y rechaza el resto con 503, que el HPA no cuenta.
generate_load() {
  local deadline=$((SECONDS + DURATION))
  while [ "$SECONDS" -lt "$deadline" ]; do
    curl --silent --output /dev/null --max-time 5 --header "Host: $DOMAIN" "http://$ADDRESS/?n=[1-$BURST]"
    sleep 1
  done
}

stop_load() { [ -n "${LOAD_PID:-}" ] && kill "$LOAD_PID" 2>/dev/null; }
trap stop_load EXIT

[ "$(kubectl get apiservice v1beta1.custom.metrics.k8s.io \
      --output 'jsonpath={.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = True ] \
  || die "la API de métricas personalizadas no está disponible (scripts/bootstrap.sh monitoring)"

# El HPA de la aplicación lo crea el chart; el de la Fase 5 (keda-hpa-worker) no lleva esta etiqueta.
APP="$(kubectl -n "$NS" get hpa --selector app.kubernetes.io/managed-by=Helm \
  --output 'jsonpath={.items[0].metadata.name}' 2>/dev/null)"
[ -n "$APP" ] || die "no hay una aplicación con autoescalado en $NS (scripts/deploy.sh $TENANT)"
DOMAIN="$(kubectl -n "$NS" get ingress "$APP" --output 'jsonpath={.spec.rules[0].host}')"
RATE_LIMIT="$(kubectl -n "$NS" get ingress "$APP" --output "jsonpath={.metadata.annotations.$RATE_LIMIT_ANNOTATION}")"
[[ "$RATE_LIMIT" =~ ^[0-9]+$ ]] || die "el Ingress $APP no tiene la anotación limit-rps"
ADDRESS="${INGRESS_ADDR:-$(minikube ip)}" || die "no se pudo obtener la IP de Minikube"
MIN_REPLICAS="$(hpa_field .spec.minReplicas)"
MAX_REPLICAS="$(hpa_field .spec.maxReplicas)"
readonly APP DOMAIN RATE_LIMIT ADDRESS MIN_REPLICAS MAX_REPLICAS
readonly BURST=$((RATE_LIMIT * 2))

info "Carga sobre http://$DOMAIN/: ráfagas de $BURST solicitudes por segundo (límite del plan: $RATE_LIMIT rps) durante ${DURATION}s"
info "HPA $APP: de $MIN_REPLICAS a $MAX_REPLICAS réplicas"
generate_load &
LOAD_PID=$!

peak="$MIN_REPLICAS"
deadline=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$deadline" ] && [ "$peak" -lt "$MAX_REPLICAS" ]; do
  sleep "$POLL_SECONDS"
  current="$(current_replicas)"
  [ "$current" -gt "$peak" ] && peak="$current"
  echo "t=${SECONDS}s  réplicas=$current  cpu=$(hpa_field "$CPU_METRIC")%  ingress=$(hpa_field "$INGRESS_METRIC") rps/pod"
done
stop_load

if [ "$peak" -gt "$MIN_REPLICAS" ]; then
  pass "el HPA escaló de $MIN_REPLICAS a $peak réplicas (máximo del plan: $MAX_REPLICAS)"
else
  fail "el HPA no escaló en ${DURATION}s (kubectl -n $NS describe hpa $APP)"
fi

if [ "${WAIT_DOWN:-0}" = 1 ]; then
  info "Sin carga: esperando el regreso a $MIN_REPLICAS réplicas (hasta ${SCALE_DOWN_TIMEOUT}s)"
  deadline=$((SECONDS + SCALE_DOWN_TIMEOUT))
  current="$peak"
  while [ "$SECONDS" -lt "$deadline" ] && [ "$current" -gt "$MIN_REPLICAS" ]; do
    sleep "$POLL_SECONDS"
    current="$(current_replicas)"
  done
  if [ "$current" -le "$MIN_REPLICAS" ]; then
    pass "el HPA volvió a $MIN_REPLICAS réplicas"
  else
    fail "el HPA sigue en $current réplicas"
  fi
fi
finish
