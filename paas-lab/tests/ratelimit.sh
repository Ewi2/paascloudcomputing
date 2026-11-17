#!/usr/bin/env bash
# Límite de solicitudes HTTP del plan en el Ingress (Fase 2): una ráfaga desde un solo origen
# debe recibir una mezcla de respuestas 200 y 503.
#
# Uso: tests/ratelimit.sh <dominio> [solicitudes=500]
# INGRESS_ADDR cambia la dirección del Ingress (por defecto, la IP de Minikube).
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly CONCURRENCY=50
readonly DOMAIN="${1:?uso: $0 <dominio> [solicitudes]}"
readonly TOTAL="${2:-500}"
ADDRESS="${INGRESS_ADDR:-$(minikube ip)}" || die "no se pudo obtener la IP de Minikube"
readonly ADDRESS

info "$TOTAL solicitudes a http://$DOMAIN/ ($CONCURRENCY en paralelo)"
codes="$(seq "$TOTAL" | xargs -P "$CONCURRENCY" -I{} curl --silent --output /dev/null \
  --write-out '%{http_code}\n' --max-time 5 --header "Host: $DOMAIN" "http://$ADDRESS/")"
sort <<<"$codes" | uniq -c | sort -rn

served="$(grep -c '^200$' <<<"$codes")"
limited="$(grep -c '^503$' <<<"$codes")"
if [ "$served" -gt 0 ] && [ "$limited" -gt 0 ]; then
  pass "$served respuestas 200 y $limited rechazadas (503) por el límite del plan"
else
  fail "sin mezcla de 200 y 503: revisar las anotaciones limit-* del Ingress y el Ingress Controller"
fi
finish
