#!/usr/bin/env bash
# Límite de solicitudes HTTP en el Ingress. Uso: tests/ratelimit.sh <dominio> [total=500]
# Requiere resolver el dominio o usar INGRESS_ADDR (por defecto, la IP de Minikube).
set -uo pipefail
DOMAIN="${1:?uso: $0 <dominio> [total]}"; TOTAL="${2:-500}"
ADDR="${INGRESS_ADDR:-$(minikube ip)}"

codes="$(seq "$TOTAL" | xargs -P 50 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  --max-time 5 -H "Host: $DOMAIN" "http://$ADDR/")"
echo "$codes" | sort | uniq -c | sort -rn

ok="$(grep -c '^200$' <<<"$codes")"; limited="$(grep -c '^503$' <<<"$codes")"
if [ "$ok" -gt 0 ] && [ "$limited" -gt 0 ]; then
  echo "PASS: $ok respuestas 200 y $limited rechazadas (503) por el límite del plan"
else
  echo "FAIL: sin mezcla de 200/503. Revisa 'kubectl get ingress -o yaml' (annotations limit-*) y el Ingress Controller NGINX"
  exit 1
fi
