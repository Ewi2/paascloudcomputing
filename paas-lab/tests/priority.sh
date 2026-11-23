#!/usr/bin/env bash
# Prioridad alta frente a prioridad baja (Fase 5, modo prioridad): publica una carga estándar y
# una carga VIP en el broker de un tenant y compara cómo responde el escalado de cada consumidor.
#
# Uso: tests/priority.sh [tenant=beta]
# Requiere el modo prioridad aplicado: kubectl apply -k admin/events/tenants/<tenant>-priority
#
# Variables opcionales:
#   LOW_MESSAGES   mensajes de prioridad 1 a la cola estándar   (por defecto 30)
#   HIGH_MESSAGES  mensajes de prioridad 10 a la cola VIP       (por defecto 10)
#   TIMEOUT        segundos máximos de observación              (por defecto 300)
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly POLL_SECONDS=2
readonly LOW_PRIORITY=1
readonly HIGH_PRIORITY=10
readonly TENANT="${1:-beta}"
readonly LOW_MESSAGES="${LOW_MESSAGES:-30}"
readonly HIGH_MESSAGES="${HIGH_MESSAGES:-10}"
readonly TIMEOUT="${TIMEOUT:-300}"
require_tenant "$TENANT"
readonly NS="tenant-$TENANT"

# Los dos consumidores. Cada uno es un Deployment con un ScaledObject del mismo nombre.
readonly CONSUMERS=(worker worker-vip)
readonly LABELS=("Prioridad baja" "Prioridad alta")

[ -n "$(scaler_field "$NS" worker-vip .metadata.name)" ] \
  || die "el modo prioridad no está aplicado en $NS (kubectl apply -k admin/events/tenants/$TENANT-priority)"

declare -a QUEUE MAX VALUE POLLING
for i in 0 1; do
  QUEUE[i]="$(scaler_field "$NS" "${CONSUMERS[i]}" '.spec.triggers[0].metadata.queueName')"
  MAX[i]="$(scaler_field "$NS" "${CONSUMERS[i]}" .spec.maxReplicaCount)"
  VALUE[i]="$(scaler_field "$NS" "${CONSUMERS[i]}" '.spec.triggers[0].metadata.value')"
  POLLING[i]="$(scaler_field "$NS" "${CONSUMERS[i]}" .spec.pollingInterval)"
  info "${LABELS[i]}: cola ${QUEUE[i]}, consumidor ${CONSUMERS[i]}, 1 réplica cada ${VALUE[i]} mensajes, sondeo cada ${POLLING[i]}s, máximo ${MAX[i]}"
  [ "$(deployment_replicas "$NS" "${CONSUMERS[i]}")" -eq 0 ] \
    || info "Aviso: ${CONSUMERS[i]} no parte de 0 réplicas; la medición de activación no será válida"
done

# Publica una carga y verifica que se encoló completa. Argumentos: índice, cantidad, prioridad, prefijo.
publish_load() {
  local index="$1" count="$2" priority="$3" prefix="$4" routed
  routed="$(broker "$NS" publish "${QUEUE[index]}" "$count" "$priority" "$prefix")"
  if [ "$routed" = "$count" ]; then
    pass "$count mensajes de prioridad $priority encolados en ${QUEUE[index]}"
  else
    fail "solo se encolaron '${routed:-0}' de $count mensajes en ${QUEUE[index]}"
  fi
}

# Mismo orden que la guía: primero la carga estándar, después la VIP. El reloj de cada cola
# empieza cuando termina de publicarse su carga.
declare -a START ACTIVATED PEAK DRAINED
info "Publicando la carga de prioridad baja y después la de prioridad alta"
publish_load 0 "$LOW_MESSAGES" "$LOW_PRIORITY" Baja_Prioridad
START[0]="$SECONDS"
publish_load 1 "$HIGH_MESSAGES" "$HIGH_PRIORITY" Alta_Prioridad_VIP
START[1]="$SECONDS"
PEAK=(0 0)
ACTIVATED=("" "")
DRAINED=("" "")

deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  read -r -a pending <<<"$(broker "$NS" length "${QUEUE[0]}" "${QUEUE[1]}")"
  done_count=0
  line="t=${SECONDS}s"
  for i in 0 1; do
    replicas="$(deployment_replicas "$NS" "${CONSUMERS[i]}")"
    [ "$replicas" -gt "${PEAK[i]}" ] && PEAK[i]="$replicas"
    [ -z "${ACTIVATED[i]}" ] && [ "$replicas" -gt 0 ] && ACTIVATED[i]=$((SECONDS - START[i]))
    [ -z "${DRAINED[i]}" ] && [ "${pending[i]:-?}" = 0 ] && DRAINED[i]=$((SECONDS - START[i]))
    # Ciclo completo de un consumidor: se activó, vació su cola y volvió a 0.
    [ -n "${ACTIVATED[i]}" ] && [ -n "${DRAINED[i]}" ] && [ "$replicas" -eq 0 ] && done_count=$((done_count + 1))
    line="$line  ${QUEUE[i]}: cola=${pending[i]:-?} workers=$replicas"
  done
  echo "$line"
  [ "$done_count" -eq 2 ] && break
  sleep "$POLL_SECONDS"
done

# Fila de la tabla de resultados. Rellena por caracteres y no por bytes, como haría printf:
# así las etiquetas con tildes quedan alineadas.
row() {
  local text widths=(28 20 20) i=0 line=""
  for text in "$@"; do
    line+="$text$(printf '%*s' $((widths[i] - ${#text})) '')"
    i=$((i + 1))
  done
  echo "$line"
}

echo
row "" "${LABELS[0]}" "${LABELS[1]}"
row "Cola" "${QUEUE[0]}" "${QUEUE[1]}"
row "Mensajes publicados" "$LOW_MESSAGES" "$HIGH_MESSAGES"
row "Mensajes por réplica" "${VALUE[0]}" "${VALUE[1]}"
row "Sondeo de KEDA" "${POLLING[0]}s" "${POLLING[1]}s"
row "Primer worker a los" "${ACTIVATED[0]:--}s" "${ACTIVATED[1]:--}s"
row "Pico de workers" "${PEAK[0]}" "${PEAK[1]}"
row "Cola vacía a los" "${DRAINED[0]:--}s" "${DRAINED[1]:--}s"
echo

for i in 0 1; do
  if [ -n "${ACTIVATED[i]}" ]; then
    pass "${CONSUMERS[i]}: KEDA lo activó a los ${ACTIVATED[i]}s"
  else
    fail "${CONSUMERS[i]}: KEDA no lo activó (kubectl -n $NS describe scaledobject ${CONSUMERS[i]})"
  fi
  if [ -n "${DRAINED[i]}" ] && [ "$(deployment_replicas "$NS" "${CONSUMERS[i]}")" -eq 0 ]; then
    pass "${CONSUMERS[i]}: vació ${QUEUE[i]} y volvió a 0 réplicas"
  else
    fail "${CONSUMERS[i]}: no completó el ciclo en ${TIMEOUT}s"
  fi
done
if [ "${PEAK[1]}" -gt "${PEAK[0]}" ]; then
  pass "la carga VIP desplegó más réplicas (${PEAK[1]}) que la estándar (${PEAK[0]}) con menos mensajes"
else
  fail "la carga VIP no desplegó más réplicas que la estándar (${PEAK[1]} frente a ${PEAK[0]})"
fi
# La activación depende de en qué punto del intervalo de sondeo llega cada carga: se informa,
# pero no se exige (con sondeos de 5 s y 15 s lo esperable es que la VIP se active antes).
if [ -n "${ACTIVATED[0]}" ] && [ -n "${ACTIVATED[1]}" ]; then
  if [ "${ACTIVATED[1]}" -le "${ACTIVATED[0]}" ]; then
    info "La cola VIP se activó primero (${ACTIVATED[1]}s frente a ${ACTIVATED[0]}s)"
  else
    info "Esta vez la cola estándar se activó primero (${ACTIVATED[0]}s frente a ${ACTIVATED[1]}s): repetir la prueba"
  fi
fi
finish
