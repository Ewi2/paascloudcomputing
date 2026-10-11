#!/usr/bin/env bash
# Despliegue PaaS de un tenant. Uso: deploy.sh <alpha|beta>
# Valida el values.yaml del cliente, trae la imagen (docker pull), la carga al nodo de
# Minikube y ejecuta helm con el plan que fijó el administrador.
set -euo pipefail

PAAS_ROOT="${PAAS_ROOT:-/opt/paas}"
TENANT="${1:-}"
case "$TENANT" in alpha|beta) ;; *) echo "Uso: $0 <alpha|beta>" >&2; exit 2 ;; esac

NS="tenant-$TENANT"
VALUES="$PAAS_ROOT/tenants/$TENANT/values.yaml"
CONF="$PAAS_ROOT/admin/tenants.env"
CHART="$PAAS_ROOT/paas-app-chart"

die() { echo "ERROR: $*" >&2; exit 1; }
conf() { sed -n "s/^${TENANT}_$1=//p" "$CONF" | head -n1; }

PLAN="$(conf plan)"; BASE="$(conf domain)"
[ -n "$PLAN" ] && [ -n "$BASE" ] || die "faltan ${TENANT}_plan / ${TENANT}_domain en $CONF"
python3 -c 'import yaml' 2>/dev/null || die "falta PyYAML (sudo apt install -y python3-yaml)"

# 1. El archivo del cliente debe ser regular (nunca un enlace) y de tamaño razonable
[ -f "$VALUES" ] && [ ! -L "$VALUES" ] || die "$VALUES no es un archivo regular"
[ "$(stat -c %s "$VALUES")" -le 65536 ] || die "values.yaml excede 64 KiB"

# 2. Copia única: lo que se valida es exactamente lo que se despliega
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat "$VALUES" > "$TMP/values.yaml"

field() { python3 -I -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2], ""))' "$TMP/values.yaml" "$1"; }
IMAGE="$(field image)"; DOMAIN="$(field domain)"; APP="$(field appName)"

# 3. Validaciones de política (el resto las hace values.schema.json dentro de helm)
re_image='^[a-z0-9][a-z0-9._/:-]{0,200}(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[a-f0-9]{64})$'
[[ "$IMAGE" =~ $re_image ]] || die "image inválida (se exige tag explícito o digest): '$IMAGE'"
[[ "$DOMAIN" == "$BASE" || "$DOMAIN" == *".$BASE" ]] || die "domain debe ser '$BASE' o un subdominio de '$BASE'"
[ -n "$APP" ] || die "appName es obligatorio"

# 4. Traer la imagen y dejarla disponible en el nodo (cubre también registros privados)
echo ">> docker pull $IMAGE"
docker pull "$IMAGE"
if command -v minikube >/dev/null 2>&1; then
  echo ">> minikube image load $IMAGE"
  minikube image load "$IMAGE"
fi

# 5. Despliegue: plan y tenant los impone el administrador, prevalecen sobre el archivo del cliente
echo ">> helm upgrade --install $APP -n $NS (plan: $PLAN)"
helm upgrade --install "$APP" "$CHART" -n "$NS" \
  -f "$TMP/values.yaml" \
  --set-string "plan=$PLAN" --set-string "tenant=$TENANT" \
  --atomic --wait --timeout 3m

kubectl -n "$NS" get deploy,svc,ingress,hpa -l "app.kubernetes.io/instance=$APP"
