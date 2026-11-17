#!/usr/bin/env bash
# Prepara una VM Ubuntu Server 22.04 recién instalada para alojar la plataforma: Docker,
# Minikube, kubectl, Helm y parámetros del kernel. Se puede repetir sin efectos adversos.
#
# Uso (una sola vez, desde la cuenta administradora):
#   sudo scripts/install-host.sh
# Después hay que cerrar la sesión y volver a entrar para que aplique el grupo "docker".
set -euo pipefail

readonly MIN_CPUS=2
readonly MIN_MEMORY_MB=3500
readonly MIN_ROOT_GB=30
readonly SYSCTL_FILE=/etc/sysctl.d/99-paas.conf
readonly BIN_DIR=/usr/local/bin

log()  { echo ">> $*"; }
warn() { echo "AVISO: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
  log "Paquetes del sistema (docker.io, conntrack, curl, python3-yaml)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update --quiet
  apt-get install --yes --quiet docker.io conntrack curl ca-certificates python3-yaml
  systemctl enable --now docker
  usermod --append --groups docker "$ADMIN"
}

# Descarga un binario y lo instala en BIN_DIR. Argumentos: nombre, URL.
install_binary() {
  local name="$1" url="$2" tmp
  log "Instalando $name"
  tmp="$(mktemp)"
  curl --fail --silent --show-error --location --output "$tmp" "$url"
  install --owner root --group root --mode 0755 "$tmp" "$BIN_DIR/$name"
  rm -f "$tmp"
}

install_tools() {
  local kubectl_version
  if have minikube; then
    log "minikube ya está instalado"
  else
    install_binary minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  fi
  if have kubectl; then
    log "kubectl ya está instalado"
  else
    kubectl_version="$(curl --fail --silent --show-error --location https://dl.k8s.io/release/stable.txt)"
    install_binary kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
  fi
  if have helm; then
    log "helm ya está instalado"
  else
    log "Instalando helm"
    curl --fail --silent --show-error --location \
      https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

configure_kernel() {
  log "Parámetros del kernel ($SYSCTL_FILE)"
  cat > "$SYSCTL_FILE" <<'SYSCTL'
# PaaS de laboratorio (paas-lab)
# La VM usa swap solo como último recurso: el plano de control degrada con paginación.
vm.swappiness = 10
# Cada pod consume instancias de inotify; el valor por defecto (128) puede agotarse con decenas de pods.
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
SYSCTL
  sysctl --quiet --load "$SYSCTL_FILE"
}

# Avisa si la VM queda por debajo de lo que la plataforma necesita. No modifica discos ni swap.
check_capacity() {
  local cpus memory_mb root_gb swap_mb root_device
  cpus="$(nproc)"
  memory_mb="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
  swap_mb="$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
  root_gb="$(df --output=size --block-size=1G / | tail -n 1 | tr -dc '0-9')"
  root_device="$(findmnt --noheadings --output SOURCE /)"

  log "Capacidad: ${cpus} CPU, ${memory_mb} MB de RAM, ${swap_mb} MB de swap, ${root_gb} GB en /"
  [ "$cpus" -ge "$MIN_CPUS" ] || warn "Minikube exige al menos $MIN_CPUS CPU."
  [ "$memory_mb" -ge "$MIN_MEMORY_MB" ] || warn "Se recomiendan 4 GB de RAM (hay ${memory_mb} MB)."
  if [ "$root_gb" -lt "$MIN_ROOT_GB" ]; then
    warn "El volumen raíz tiene ${root_gb} GB. El instalador de Ubuntu suele asignar a LVM solo" \
         "la mitad del disco. Para usar el disco completo:"
    warn "  sudo lvextend --resizefs --extents +100%FREE $root_device"
  fi
  if [ "$swap_mb" -eq 0 ]; then
    warn "No hay swap. Con 4 GB conviene crear 2 GB como margen de seguridad:"
    warn "  sudo fallocate -l 2G /swap.img && sudo chmod 600 /swap.img && sudo mkswap /swap.img"
    warn "  sudo swapon /swap.img && echo '/swap.img none swap sw 0 0' | sudo tee -a /etc/fstab"
  fi
}

[ "$(id -u)" -eq 0 ] || die "ejecutar con sudo"
ADMIN="${SUDO_USER:-}"
[ -n "$ADMIN" ] && [ "$ADMIN" != root ] || die "ejecutar con sudo desde la cuenta administradora, no como root"
readonly ADMIN
[ "$(dpkg --print-architecture)" = amd64 ] || die "los binarios que se descargan son para amd64"

install_packages
install_tools
configure_kernel
check_capacity

log "Listo. Cierra la sesión de $ADMIN y vuelve a entrar (grupo docker); después: scripts/bootstrap.sh all"
