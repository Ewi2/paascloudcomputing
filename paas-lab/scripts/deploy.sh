#!/usr/bin/env bash
# Despliega la aplicación de un tenant a partir de su values.yaml (Fase 2).
#
# Uso: deploy.sh <tenant>
#   Cliente:        sudo -u <administrador> /opt/paas/scripts/deploy.sh <su-tenant>
#   Administrador:  scripts/deploy.sh <tenant>          (desde el repositorio)
#
# Valida el archivo del cliente, descarga la imagen (docker pull), la carga en el nodo de
# Minikube y ejecuta Helm. El plan y el dominio base se leen del Namespace del tenant
# (admin/tenancy/tenants/<tenant>/): los fija el administrador y el cliente no puede cambiarlos.
set -euo pipefail

readonly MAX_VALUES_BYTES=65536
readonly HISTORY_MAX=5
readonly HELM_TIMEOUT=3m
readonly RE_TENANT='^[a-z][a-z0-9]{0,20}$'
readonly RE_APP='^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$'
readonly RE_IMAGE='^[a-z0-9][a-z0-9._/:-]{0,200}(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[a-f0-9]{64})$'

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Campo de la metadata del Namespace del tenant. Argumento: ruta bajo .metadata.
namespace_field() {
  kubectl get namespace "$NAMESPACE" --output "jsonpath={.metadata.$1}" 2>/dev/null || true
}

# Campo de texto de primer nivel del archivo del cliente; vacío si falta o no es texto.
values_field() {
  python3 -I -c '
import sys, yaml
value = (yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2], "")
print(value if isinstance(value, str) else "")' "$SNAPSHOT" "$1" 2>/dev/null \
    || die "values.yaml no es un documento YAML válido"
}

TENANT="${1:-}"
[[ "$TENANT" =~ $RE_TENANT ]] || die "uso: $0 <tenant>"
readonly TENANT
readonly NAMESPACE="tenant-$TENANT"

# Raíz de la instalación (/opt/paas) o del repositorio, según desde dónde se ejecute.
PAAS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
readonly PAAS_ROOT
readonly CHART="$PAAS_ROOT/paas-app-chart"
readonly VALUES="$PAAS_ROOT/tenants/$TENANT/values.yaml"

# kubectl, helm y minikube leen su configuración del HOME del usuario efectivo (el
# administrador); algunas configuraciones de sudo conservan el HOME de quien lo invoca.
HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
export HOME

for cmd in kubectl helm docker minikube python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "falta el comando '$cmd'"
done
python3 -I -c 'import yaml' 2>/dev/null || die "falta PyYAML (sudo apt install -y python3-yaml)"

# 1. El tenant debe estar dado de alta; su plan y su dominio base vienen del Namespace.
[ "$(namespace_field 'labels.paas/tenant')" = "$TENANT" ] \
  || die "el tenant '$TENANT' no está dado de alta (scripts/bootstrap.sh tenancy)"
PLAN="$(namespace_field 'labels.paas/plan')"
BASE_DOMAIN="$(namespace_field 'annotations.paas/domain')"
[ -n "$PLAN" ] && [ -n "$BASE_DOMAIN" ] \
  || die "el Namespace $NAMESPACE no tiene la etiqueta paas/plan o la anotación paas/domain"

# 2. El archivo del cliente debe ser regular (nunca un enlace) y de tamaño acotado.
[ -f "$VALUES" ] && [ ! -L "$VALUES" ] || die "$VALUES no es un archivo regular"
[ "$(stat --format %s "$VALUES")" -le "$MAX_VALUES_BYTES" ] || die "values.yaml excede $MAX_VALUES_BYTES bytes"

# 3. Copia única: lo que se valida es exactamente lo que se despliega.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
readonly SNAPSHOT="$WORKDIR/values.yaml"
cat "$VALUES" > "$SNAPSHOT"

# 4. Validaciones de política. El resto las hacen values.schema.json y _helpers.tpl dentro de Helm.
APP="$(values_field appName)"
IMAGE="$(values_field image)"
DOMAIN="$(values_field domain)"
[[ "$APP" =~ $RE_APP ]] || die "appName inválido: minúsculas, dígitos y guiones; debe empezar por letra ('$APP')"
[[ "$IMAGE" =~ $RE_IMAGE ]] || die "image inválida: se exige tag explícito o digest ('$IMAGE')"
[[ "$DOMAIN" == "$BASE_DOMAIN" || "$DOMAIN" == *".$BASE_DOMAIN" ]] \
  || die "domain debe ser '$BASE_DOMAIN' o un subdominio suyo ('$DOMAIN')"

# 5. La imagen se descarga en la VM y se carga en el nodo: valida que existe antes de tocar
#    el clúster y cubre los registros que requieren credenciales del administrador.
log "docker pull $IMAGE"
docker pull "$IMAGE"
log "minikube image load $IMAGE"
minikube image load "$IMAGE"

# 6. Despliegue. Si falla, Helm restaura la versión anterior (el indicador cambió de nombre en Helm 4).
case "$(helm version --template '{{.Version}}')" in
  v3.*) ROLLBACK_FLAG=--atomic ;;
  *)    ROLLBACK_FLAG=--rollback-on-failure ;;
esac
log "helm upgrade --install $APP -n $NAMESPACE (plan: $PLAN)"
helm upgrade --install "$APP" "$CHART" --namespace "$NAMESPACE" \
  --values "$SNAPSHOT" \
  --set-string "plan=$PLAN" --set-string "tenant=$TENANT" \
  "$ROLLBACK_FLAG" --wait --timeout "$HELM_TIMEOUT" --history-max "$HISTORY_MAX"

kubectl -n "$NAMESPACE" get deployment,service,ingress,hpa,pvc \
  --selector "app.kubernetes.io/instance=$APP"
