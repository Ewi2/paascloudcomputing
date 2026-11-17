#!/usr/bin/env bash
# Ciclo completo de escalado por eventos (Fase 5): publica mensajes en la cola de un tenant y
# comprueba que el worker pasa de 0 a N réplicas, vacía la cola y vuelve a 0 sin intervención.
# También comprueba que los workers de los demás tenants no se ven afectados.
#
# Uso: tests/keda.sh <tenant> [mensajes=50]
# TIMEOUT cambia el tiempo máximo de observación en segundos (por defecto 300).
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly POLL_SECONDS=5
readonly TENANT="${1:?uso: $0 <tenant> [mensajes]}"
readonly MESSAGES="${2:-50}"
readonly TIMEOUT="${TIMEOUT:-300}"
require_tenant "$TENANT"
readonly NS="tenant-$TENANT"

# Operaciones sobre la cola. Se ejecutan dentro del pod del broker, contra su API HTTP local y
# con las credenciales de su entorno: la clave no sale del pod.
#   publish <cola> <cantidad>   publica mensajes e imprime cuántos quedaron encolados
#   length <cola>               imprime los mensajes pendientes
read -r -d '' BROKER_TOOL <<'TOOL' || true
api=http://127.0.0.1:15672/api
auth="Authorization: Basic $(printf '%s:%s' "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS" | base64)"
case "$1" in
  publish)
    routed=0
    i=1
    while [ "$i" -le "$3" ]; do
      body="{\"properties\":{},\"routing_key\":\"$2\",\"payload\":\"Pedido_$i\",\"payload_encoding\":\"string\"}"
      wget -q -O - --header "$auth" --header 'content-type: application/json' --post-data "$body" \
        "$api/exchanges/%2F/amq.default/publish" | grep -q '"routed": *true' && routed=$((routed + 1))
      i=$((i + 1))
    done
    echo "$routed"
    ;;
  length)
    wget -q -O - --header "$auth" "$api/queues/%2F/$2" | sed -n 's/.*"messages": *\([0-9]*\).*/\1/p'
    ;;
esac
TOOL
readonly BROKER_TOOL

broker() { kubectl -n "$NS" exec deployment/rabbitmq -- sh -c "$BROKER_TOOL" broker "$@"; }

scaler_field() { kubectl -n "$NS" get scaledobject worker --output "jsonpath={$1}" 2>/dev/null; }

# Suma de las réplicas de worker en los demás tenants.
other_tenants_replicas() {
  local tenant total=0
  for tenant in $(registered_tenants); do
    [ "$tenant" = "$TENANT" ] && continue
    total=$((total + $(deployment_replicas "tenant-$tenant" worker)))
  done
  echo "$total"
}

QUEUE="$(scaler_field '.spec.triggers[0].metadata.queueName')"
[ -n "$QUEUE" ] || die "la Fase 5 no está instalada en $NS (scripts/bootstrap.sh events)"
MAX_REPLICAS="$(scaler_field .spec.maxReplicaCount)"
MESSAGES_PER_REPLICA="$(scaler_field '.spec.triggers[0].metadata.value')"
COOLDOWN="$(scaler_field .spec.cooldownPeriod)"
readonly QUEUE MAX_REPLICAS MESSAGES_PER_REPLICA COOLDOWN

info "SLA de $TENANT: hasta $MAX_REPLICAS workers, 1 réplica cada $MESSAGES_PER_REPLICA mensajes, cooldown de ${COOLDOWN}s"
[ "$(deployment_replicas "$NS" worker)" -eq 0 ] || info "Aviso: el worker no parte de 0 réplicas"
others_before="$(other_tenants_replicas)"

info "Publicando $MESSAGES mensajes en la cola '$QUEUE'"
routed="$(broker publish "$QUEUE" "$MESSAGES")"
if [ "$routed" = "$MESSAGES" ]; then
  pass "$routed mensajes encolados"
else
  fail "solo se encolaron '${routed:-0}' de $MESSAGES mensajes"
fi

peak=0
others_peak="$others_before"
drained=no
deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  replicas="$(deployment_replicas "$NS" worker)"
  pending="$(broker length "$QUEUE")"
  others="$(other_tenants_replicas)"
  [ "$replicas" -gt "$peak" ] && peak="$replicas"
  [ "$others" -gt "$others_peak" ] && others_peak="$others"
  if [ "$pending" = 0 ]; then drained=yes; else drained=no; fi
  echo "t=${SECONDS}s  cola=${pending:-?}  workers=$replicas"
  # Fin del ciclo: hubo actividad, la cola quedó vacía y KEDA devolvió el worker a 0.
  [ "$peak" -gt 0 ] && [ "$drained" = yes ] && [ "$replicas" -eq 0 ] && break
  sleep "$POLL_SECONDS"
done

if [ "$peak" -ge 1 ]; then
  pass "activación: KEDA llevó el worker de 0 a 1 réplica"
else
  fail "KEDA no activó el worker (kubectl -n $NS describe scaledobject worker)"
fi
if [ "$peak" -gt 1 ]; then
  pass "escalado: pico de $peak réplicas (máximo del SLA: $MAX_REPLICAS)"
else
  fail "el worker no pasó de 1 réplica (kubectl -n $NS describe hpa keda-hpa-worker)"
fi
if [ "$drained" = yes ]; then
  pass "los workers vaciaron la cola"
else
  fail "la cola no se vació en ${TIMEOUT}s (kubectl -n $NS logs --selector app.kubernetes.io/name=worker)"
fi
if [ "$(deployment_replicas "$NS" worker)" -eq 0 ]; then
  pass "scale-to-zero: el worker volvió a 0 réplicas"
else
  fail "el worker no volvió a 0 réplicas en ${TIMEOUT}s"
fi
if [ "$others_peak" -eq "$others_before" ]; then
  pass "los workers de los demás tenants no cambiaron ($others_before réplicas)"
else
  fail "los workers de otros tenants pasaron de $others_before a $others_peak réplicas"
fi
finish
