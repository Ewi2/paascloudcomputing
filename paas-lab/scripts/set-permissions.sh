#!/usr/bin/env bash
# Instala en /opt/paas lo que usa el cliente y segmenta los permisos por tenant (Fase 2).
# Por cada tenant dado de alta en admin/tenancy/tenants/ crea el usuario cliente-<tenant>,
# su único archivo editable y la regla de sudo que le permite desplegar solo su tenant.
#
# Uso (desde la cuenta administradora; repetir tras cambiar el chart o dar de alta un tenant):
#   sudo scripts/set-permissions.sh
#
# Resultado en /opt/paas:
#   paas-app-chart/, scripts/deploy.sh   root:root, solo lectura para los clientes
#   tenants/<t>/                         root:cliente-<t> 0750 (el cliente entra, no crea archivos)
#   tenants/<t>/values.yaml              cliente-<t>:cliente-<t> 0640 (el administrador lee por grupo)
set -euo pipefail

readonly PAAS_ROOT=/opt/paas
readonly SUDOERS_DIR=/etc/sudoers.d

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

install_platform_code() {
  log "Código de la plataforma en $PAAS_ROOT (root:root)"
  install --directory --owner root --group root --mode 0755 \
    "$PAAS_ROOT" "$PAAS_ROOT/scripts" "$PAAS_ROOT/tenants"
  rm -rf "${PAAS_ROOT:?}/paas-app-chart"
  cp --recursive "$SOURCE/paas-app-chart" "$PAAS_ROOT/paas-app-chart"
  chown --recursive root:root "$PAAS_ROOT/paas-app-chart"
  chmod --recursive u=rwX,go=rX "$PAAS_ROOT/paas-app-chart"
  install --owner root --group root --mode 0755 "$SOURCE/scripts/deploy.sh" "$PAAS_ROOT/scripts/deploy.sh"
}

# Regla de sudo: el cliente solo ejecuta deploy.sh de SU tenant, como el administrador (que
# tiene kubeconfig y acceso a Docker). Se valida antes de instalarla: una regla inválida en
# /etc/sudoers.d deja sudo inutilizable en toda la VM.
install_sudo_rule() {
  local tenant="$1" user="$2" candidate
  candidate="$(mktemp)"
  echo "$user ALL=($ADMIN) NOPASSWD: $PAAS_ROOT/scripts/deploy.sh $tenant" > "$candidate"
  if ! visudo --check --quiet --file "$candidate"; then
    rm -f "$candidate"
    die "la regla de sudo generada para $user no es válida"
  fi
  install --owner root --group root --mode 0440 "$candidate" "$SUDOERS_DIR/paas-$tenant"
  rm -f "$candidate"
}

setup_tenant() {
  local tenant="$1" user="cliente-$1"
  local dir="$PAAS_ROOT/tenants/$1"
  local values="$dir/values.yaml" seed="$SOURCE/tenants/$1/values.yaml"

  log "Tenant $tenant (usuario $user)"
  id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$user"
  usermod --append --groups "$user" "$ADMIN"

  install --directory --owner root --group "$user" --mode 0750 "$dir"
  if [ ! -e "$values" ]; then          # nunca se sobrescribe el archivo que el cliente ya editó
    [ -f "$seed" ] || die "falta el archivo inicial $seed"
    install --owner "$user" --group "$user" --mode 0640 "$seed" "$values"
  fi
  chown "$user:$user" "$values"
  chmod 0640 "$values"

  # Comodidad: el cliente ve su archivo en su home. El control de acceso son los permisos, no el enlace.
  ln --symbolic --force --no-dereference "$values" "/home/$user/values.yaml"

  install_sudo_rule "$tenant" "$user"
}

[ "$(id -u)" -eq 0 ] || die "ejecutar con sudo"
ADMIN="${SUDO_USER:-}"
[ -n "$ADMIN" ] && [ "$ADMIN" != root ] || die "ejecutar con sudo desde la cuenta administradora, no como root"
readonly ADMIN
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SOURCE

install_platform_code
for tenant_dir in "$SOURCE"/admin/tenancy/tenants/*/; do
  setup_tenant "$(basename "$tenant_dir")"
done

log "Listo. Cada cliente despliega con: sudo -u $ADMIN $PAAS_ROOT/scripts/deploy.sh <su-tenant>"
log "Los clientes no deben pertenecer al grupo docker ni tener kubeconfig."
