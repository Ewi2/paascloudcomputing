#!/usr/bin/env bash
# Instala el laboratorio en /opt/paas con permisos segmentados por tenant.
# Ejecutar con sudo desde la cuenta administradora, en la raíz del proyecto:
#   sudo scripts/set-permissions.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta con sudo" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")/.." && pwd)"
PAAS_ROOT="${PAAS_ROOT:-/opt/paas}"
ADMIN="${SUDO_USER:?ejecuta con sudo desde la cuenta administradora}"

# Código del PaaS (chart, manifiestos, scripts): root:root, sin escritura para nadie más
install -d -m 0755 -o root -g root "$PAAS_ROOT"
for d in paas-app-chart admin scripts; do
  rm -rf "${PAAS_ROOT:?}/$d"
  cp -a "$SRC/$d" "$PAAS_ROOT/$d"
  chown -R root:root "$PAAS_ROOT/$d"
  chmod -R u=rwX,go=rX "$PAAS_ROOT/$d"
done
chmod 0755 "$PAAS_ROOT"/scripts/*.sh

install -d -m 0755 -o root -g root "$PAAS_ROOT/tenants"
for T in alpha beta; do
  U="cliente-$T"
  id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
  usermod -aG "$U" "$ADMIN"            # el administrador lee el archivo del cliente vía grupo

  # Directorio del tenant: el cliente puede entrar, no crear ni renombrar archivos
  install -d -m 0750 -o root -g "$U" "$PAAS_ROOT/tenants/$T"
  # Su único archivo editable: dueño = cliente; el grupo (administrador) solo lee; el resto, nada
  [ -f "$PAAS_ROOT/tenants/$T/values.yaml" ] || \
    install -m 0640 -o "$U" -g "$U" "$SRC/tenants/$T/values.yaml" "$PAAS_ROOT/tenants/$T/values.yaml"
  chown "$U:$U" "$PAAS_ROOT/tenants/$T/values.yaml"; chmod 0640 "$PAAS_ROOT/tenants/$T/values.yaml"

  # Comodidad: el cliente ve 'values.yaml' en su home. El control de acceso son los permisos, no el enlace.
  ln -sfn "$PAAS_ROOT/tenants/$T/values.yaml" "/home/$U/values.yaml"

  # El cliente solo puede disparar el despliegue de SU tenant, como administrador (que tiene kubeconfig y docker)
  RULE="/etc/sudoers.d/paas-$T"
  echo "$U ALL=($ADMIN) NOPASSWD: $PAAS_ROOT/scripts/deploy.sh $T" > "$RULE"
  chmod 0440 "$RULE"
  visudo -cf "$RULE" >/dev/null
done

echo "Listo. El cliente alpha despliega con:"
echo "  sudo -u cliente-alpha sudo -u $ADMIN $PAAS_ROOT/scripts/deploy.sh alpha"
echo "Los clientes NO deben pertenecer al grupo 'docker' ni tener kubeconfig."
