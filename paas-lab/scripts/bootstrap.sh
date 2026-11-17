#!/usr/bin/env bash
# Levanta la plataforma sobre Minikube. Cada etapa se puede repetir sin efectos adversos.
#
# Uso: scripts/bootstrap.sh <etapa>...
#   cluster     Minikube (driver Docker, CNI Calico) con los addons ingress y metrics-server
#   tenancy     Fase 1: Namespace, ResourceQuota, LimitRange y NetworkPolicy de cada tenant
#   monitoring  Fases 3-4: kube-prometheus-stack, alertas, métricas del Ingress, Adapter y tablero
#   hosts       /etc/hosts con la IP de Minikube y el dominio de cada tenant (pide sudo)
#   events      Fase 5: KEDA, credenciales de RabbitMQ y recursos de eventos de cada tenant
#   status      CPU y memoria reservadas en el nodo
#   all         cluster tenancy monitoring hosts (la Fase 5 se instala aparte: events)
#
# Ejecutar como el usuario administrador (miembro del grupo docker), sin sudo.
# Variables opcionales: HOST_RESERVED_MB, GRAFANA_ADMIN_PASSWORD, *_CHART_VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly TENANCY="$ROOT/admin/tenancy"
readonly MONITORING="$ROOT/admin/monitoring"
readonly EVENTS="$ROOT/admin/events"

# Versiones de los charts con las que se validaron los archivos *-values.yaml.
readonly KPS_CHART_VERSION="${KPS_CHART_VERSION:-93.3.1}"
readonly ADAPTER_CHART_VERSION="${ADAPTER_CHART_VERSION:-5.4.2}"
readonly KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.21.1}"

# Memoria que queda para el sistema operativo de la VM, fuera del nodo de Minikube.
readonly HOST_RESERVED_MB="${HOST_RESERVED_MB:-1024}"
readonly MIN_NODE_MB=2600
readonly GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
readonly BROKER_SECRET=rabbitmq-credentials
readonly BROKER_USER=paas
readonly HOSTS_MARK="# paas-lab"

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -/{/^set -/d; s/^# \{0,1\}//; p}' "${BASH_SOURCE[0]}" >&2
  exit 2
}

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "falta el comando '$cmd' (sudo scripts/install-host.sh)"
  done
}

# Tenants dados de alta: un directorio por tenant en admin/tenancy/tenants/.
tenants() {
  local dir
  for dir in "$TENANCY"/tenants/*/; do
    if [ -f "$dir/kustomization.yaml" ]; then basename "$dir"; fi
  done
}

helm_repo() {
  local name="$1" url="$2"
  helm repo add --force-update "$name" "$url" >/dev/null
  helm repo update "$name" >/dev/null
}

stage_cluster() {
  local total_mb node_mb
  if minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
    log "Minikube ya está en ejecución"
  else
    total_mb="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
    node_mb=$((total_mb - HOST_RESERVED_MB))
    [ "$node_mb" -ge "$MIN_NODE_MB" ] \
      || die "la VM tiene ${total_mb} MB de RAM: el nodo necesita ${MIN_NODE_MB} MB más ${HOST_RESERVED_MB} MB para el sistema"
    log "Minikube: $(nproc) CPU, ${node_mb} MB, CNI Calico"
    minikube start --driver=docker --cpus="$(nproc)" --memory="${node_mb}mb" --cni=calico
  fi
  # El CNI por defecto de Minikube no aplica NetworkPolicy; sin Calico la Fase 1 no aísla la red.
  kubectl -n kube-system get daemonset calico-node >/dev/null 2>&1 \
    || die "el clúster no usa Calico. Recrearlo con: minikube delete && $0 cluster"
  minikube addons enable ingress
  minikube addons enable metrics-server
  kubectl -n kube-system rollout status daemonset/calico-node --timeout=5m
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=5m
}

stage_tenancy() {
  local tenant
  for tenant in $(tenants); do
    log "Fase 1: tenant $tenant"
    kubectl apply -k "$TENANCY/tenants/$tenant"
  done
}

stage_monitoring() {
  helm_repo prometheus-community https://prometheus-community.github.io/helm-charts
  log "kube-prometheus-stack $KPS_CHART_VERSION (la primera instalación descarga ~1 GB de imágenes)"
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace --version "$KPS_CHART_VERSION" \
    --values "$MONITORING/kube-prometheus-stack-values.yaml" \
    --values "$MONITORING/alertmanager-values.yaml" \
    --set-string "grafana.adminPassword=$GRAFANA_ADMIN_PASSWORD" \
    --wait --timeout 15m
  log "Alertas, receptor de alertas, métricas del Ingress y tablero"
  kubectl apply -k "$MONITORING"
  log "prometheus-adapter $ADAPTER_CHART_VERSION"
  helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
    --namespace monitoring --version "$ADAPTER_CHART_VERSION" \
    --values "$MONITORING/prometheus-adapter-values.yaml" \
    --wait --timeout 5m
}

stage_hosts() {
  local ip domains domain
  ip="$(minikube ip)"
  domains="$(kubectl get namespace --selector paas/tenant \
    --output jsonpath='{range .items[*]}{.metadata.annotations.paas/domain}{" "}{end}')"
  [ -n "${domains// /}" ] || die "ningún tenant tiene la anotación paas/domain (etapa tenancy)"
  log "/etc/hosts: $ip $domains"
  for domain in $domains; do     # quita entradas previas de esos dominios, también las manuales
    sudo sed -i "/[[:space:]]${domain//./\\.}\([[:space:]]\|\$\)/d" /etc/hosts
  done
  echo "$ip $domains$HOSTS_MARK" | sudo tee -a /etc/hosts >/dev/null
}

# Crea, si no existe, el Secret con las credenciales del broker de un namespace. La clave es
# aleatoria y viaja en un archivo temporal: no aparece en la línea de comandos ni en el repositorio.
ensure_broker_secret() {
  local namespace="$1" password env_file
  kubectl -n "$namespace" get secret "$BROKER_SECRET" >/dev/null 2>&1 && return 0
  password="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  env_file="$(mktemp)"
  cat > "$env_file" <<SECRET
RABBITMQ_DEFAULT_USER=$BROKER_USER
RABBITMQ_DEFAULT_PASS=$password
AMQP_URI=amqp://$BROKER_USER:$password@rabbitmq.$namespace.svc.cluster.local:5672/
SECRET
  kubectl -n "$namespace" create secret generic "$BROKER_SECRET" --from-env-file="$env_file"
  rm -f "$env_file"
}

stage_events() {
  local tenant
  helm_repo kedacore https://kedacore.github.io/charts
  log "Fase 5: KEDA $KEDA_CHART_VERSION"
  helm upgrade --install keda kedacore/keda \
    --namespace keda --create-namespace --version "$KEDA_CHART_VERSION" \
    --values "$EVENTS/keda-values.yaml" \
    --wait --timeout 5m
  for tenant in $(tenants); do
    [ -d "$EVENTS/tenants/$tenant" ] || continue
    log "Fase 5: tenant $tenant"
    ensure_broker_secret "tenant-$tenant"
    kubectl apply -k "$EVENTS/tenants/$tenant"
    kubectl -n "tenant-$tenant" rollout status deployment/rabbitmq --timeout=5m
  done
}

stage_status() {
  kubectl describe node | sed -n '/^Allocated resources:/,/^Events:/p'
  kubectl top node 2>/dev/null || true
  free -m
}

[ "$(id -u)" -ne 0 ] || die "no ejecutar como root: Minikube con driver Docker corre como el usuario administrador"
[ $# -gt 0 ] || usage
require minikube kubectl helm docker

for stage in "$@"; do
  case "$stage" in
    cluster|tenancy|monitoring|hosts|events|status) "stage_$stage" ;;
    all) stage_cluster; stage_tenancy; stage_monitoring; stage_hosts ;;
    *) usage ;;
  esac
done
