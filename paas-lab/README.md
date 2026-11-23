# PaaS multi-tenant sobre Kubernetes (`paas-lab`)

Plataforma como servicio de laboratorio para la materia Informática en la Nube. Dos clientes (`alpha` y `beta`) comparten un clúster Minikube; cada uno despliega su aplicación editando un solo archivo, dentro de los límites de su plan.

| Fase | Qué aporta | Dónde está |
|---|---|---|
| 1. Aislamiento | Namespace, ResourceQuota, LimitRange y NetworkPolicy por tenant | `admin/tenancy/` |
| 2. Abstracción | Chart de Helm; el cliente solo edita `tenants/<tenant>/values.yaml` | `paas-app-chart/`, `scripts/deploy.sh` |
| 3. Elasticidad | HPA por CPU y por peticiones/s del Ingress | `paas-app-chart/templates/hpa.yaml`, `admin/monitoring/` |
| 4. Telemetría | Prometheus, Grafana (tablero por tenant) y alertas enrutadas a cada cliente | `admin/monitoring/` |
| 5. Eventos | KEDA y un RabbitMQ por tenant; el consumidor escala de 0 a N y vuelve a 0 | `admin/events/` |

La referencia completa (árbol, origen de cada dato, presupuesto de recursos, decisiones y límites) está en [ESTRUCTURA.md](ESTRUCTURA.md). Los argumentos y variables de cada comando, en [COMANDOS.md](COMANDOS.md).

## 1. Máquina virtual

| Parámetro | Valor |
|---|---|
| Hipervisor | VMware |
| Sistema operativo | Ubuntu Server 22.04 LTS (amd64) |
| CPU y memoria | 2 núcleos, 4 GB |
| Disco | 40 GB |

Dos ajustes después de instalar Ubuntu:

```bash
# Con LVM, el instalador suele asignar al volumen raíz solo la mitad del disco. Usar los 40 GB:
df -h /
sudo lvextend --resizefs --extents +100%FREE "$(findmnt --noheadings --output SOURCE /)"

# Debe existir swap (el instalador crea /swap.img). Si la salida está vacía, install-host.sh indica cómo crearla.
swapon --show
```

## 2. Instalación

Desde la cuenta administradora, en la raíz de `paas-lab/`:

```bash
sudo scripts/install-host.sh       # Docker, Minikube, kubectl, Helm y parámetros del kernel
# Cerrar la sesión y volver a entrar (grupo docker).

scripts/bootstrap.sh all           # clúster, Fase 1, monitoreo y /etc/hosts (10-15 min la primera vez)
scripts/bootstrap.sh status        # CPU y memoria reservadas en el nodo
```

`bootstrap.sh` acepta etapas sueltas (`cluster`, `tenancy`, `monitoring`, `hosts`, `events`, `status`) y cada una se puede repetir. El clúster se crea con el CNI Calico: el CNI por defecto de Minikube no aplica NetworkPolicy. Si ya existe un clúster sin Calico, hay que recrearlo (`minikube delete`).

## 3. Permisos y despliegue de los clientes

```bash
sudo scripts/set-permissions.sh    # crea cliente-alpha y cliente-beta; instala /opt/paas
```

| Ruta en `/opt/paas` | Propietario y modo | Efecto |
|---|---|---|
| `paas-app-chart/`, `scripts/deploy.sh` | `root:root`, 755/644 | Solo lectura para los clientes |
| `tenants/<t>/` | `root:cliente-<t>`, 0750 | El cliente entra; no crea ni renombra archivos |
| `tenants/<t>/values.yaml` | `cliente-<t>:cliente-<t>`, 0640 | El cliente lo edita; el administrador lo lee por grupo; el otro tenant no accede |
| `/etc/sudoers.d/paas-<t>` | `root`, 0440 | El cliente solo ejecuta `deploy.sh <t>` como el administrador |

Los clientes no pertenecen al grupo `docker` ni tienen kubeconfig. Cada cliente ve su archivo en `~/values.yaml` (enlace simbólico).

```bash
# Como cliente (sesión de cliente-alpha):
nano ~/values.yaml
sudo -u <administrador> /opt/paas/scripts/deploy.sh alpha

# Lo mismo simulado desde la sesión del administrador:
sudo -u cliente-alpha sudo -u "$USER" /opt/paas/scripts/deploy.sh alpha
sudo -u cliente-beta  sudo -u "$USER" /opt/paas/scripts/deploy.sh beta

curl -s -o /dev/null -w '%{http_code}\n' http://alpha.paas.local/
curl -s -o /dev/null -w '%{http_code}\n' http://beta.paas.local/
```

`deploy.sh` rechaza con un mensaje claro: imagen sin tag, dominio de otro tenant, réplicas por encima del plan y valores de `env` sin comillas.

Comprobación de permisos (las tres deben fallar):

```bash
sudo -u cliente-beta cat /opt/paas/tenants/alpha/values.yaml
sudo -u cliente-alpha touch /opt/paas/tenants/alpha/otro.yaml
sudo -u cliente-alpha docker ps
```

## 4. Pruebas de las Fases 1 a 4

```bash
tests/isolation.sh                    # red: alpha y beta no se alcanzan (ICMP y TCP)
tests/quota.sh alpha                  # la cuota rechaza el exceso de CPU y de PVC
tests/quota.sh beta
tests/ratelimit.sh alpha.paas.local   # mezcla de 200 y 503 por el límite del plan
tests/hpa.sh alpha                    # el HPA escala por peticiones del Ingress
tests/hpa.sh beta
```

Alertas automáticas al cliente:

```bash
KEEP=1 tests/quota.sh alpha                               # deja la cuota al límite
kubectl logs -n monitoring deploy/alert-sink --tail=20    # tras 2-3 minutos
kubectl -n tenant-alpha delete deployment,pvc --selector paas/test=quota
```

Salida esperada: `[/alpha] firing TenantQuotaNearLimit ns=tenant-alpha resource=requests.cpu ...` y `[/alpha] firing TenantQuotaExhausted ns=tenant-alpha resource=persistentvolumeclaims ...`.

## 5. Fase 5: escalado por eventos

```bash
scripts/bootstrap.sh events           # KEDA, credenciales y RabbitMQ + worker por tenant
tests/keda.sh beta                    # 50 mensajes: 0 -> N workers -> cola vacía -> 0
tests/keda.sh alpha
kubectl -n tenant-beta logs --selector app.kubernetes.io/name=worker --tail=20   # mientras haya workers
```

| Tenant | SLA de eventos | Máximo de workers | Mensajes por réplica |
|---|---|---|---|
| alpha | Estándar | 5 | 5 |
| beta | Alta capacidad | 15 | 2 |

En otra terminal, `kubectl get pods -n tenant-beta -w` muestra el ciclo completo. Mientras `tests/keda.sh beta` corre, `tenant-alpha` permanece en 0 workers.

Con 2 núcleos no caben a la vez el máximo de workers de beta y el máximo del HPA de las dos aplicaciones: ejecutar `tests/hpa.sh` y `tests/keda.sh beta` por separado.

### Modo prioridad (carga de prioridad alta frente a baja)

Agrega a beta una cola prioritaria `pedidos-vip` con su propio consumidor `worker-vip` (1 réplica por mensaje, sondeo cada 5 s) y vuelve más tolerante a la espera la cola estándar (15 mensajes por réplica, sondeo cada 15 s).

```bash
kubectl apply -k admin/events/tenants/beta-priority   # el broker se reinicia
kubectl -n tenant-beta rollout status deployment/rabbitmq
tests/priority.sh beta                                # 30 mensajes de prioridad 1 y 10 de prioridad 10
```

En otras terminales: `kubectl get pods -n tenant-beta -w` y `kubectl get hpa -n tenant-beta -w`. La prueba termina con una tabla comparativa: primer worker, pico de workers y tiempo hasta vaciar cada cola.

Retirar el modo prioridad:

```bash
kubectl -n tenant-beta delete scaledobject,deployment,configmap --selector paas/priority=vip
kubectl apply -k admin/events/tenants/beta
```

## 6. Acceso desde el equipo anfitrión

La IP de Minikube solo es alcanzable dentro de la VM. Para abrir las consolas desde el navegador del equipo físico (`<IP-VM>` es la dirección de la VM en VMware):

```bash
kubectl -n monitoring port-forward --address 0.0.0.0 svc/prometheus-grafana 3000:80 &
kubectl -n monitoring port-forward --address 0.0.0.0 svc/prometheus-kube-prometheus-prometheus 9090:9090 &
kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 8080:80 &
```

- Grafana: `http://<IP-VM>:3000` (usuario `admin`; clave `admin` o la de `GRAFANA_ADMIN_PASSWORD`). Tablero: carpeta **PaaS**, "PaaS - Consumo por tenant", variable **Tenant**.
- Prometheus: `http://<IP-VM>:9090`.
- Aplicaciones: agregar `<IP-VM> alpha.paas.local beta.paas.local` al archivo `hosts` del equipo físico y abrir `http://alpha.paas.local:8080`.

## 7. Operación

**Alta de un tenant** (`gamma`, por ejemplo):

1. `admin/tenancy/tenants/gamma/kustomization.yaml`: copiar el de `beta`; cambiar tenant, plan y dominio.
2. `tenants/gamma/values.yaml`: archivo inicial del cliente.
3. `admin/monitoring/alertmanager-values.yaml`: agregar su ruta y su receptor.
4. Opcional (Fase 5): `admin/events/tenants/gamma/kustomization.yaml` con su SLA.
5. Aplicar: `scripts/bootstrap.sh tenancy monitoring hosts` (y `events`), y después `sudo scripts/set-permissions.sh`.

**Cambiar el plan de un tenant:** editar `components:` en su `kustomization.yaml` de `admin/tenancy/tenants/`, ejecutar `scripts/bootstrap.sh tenancy` y volver a desplegar su aplicación.

**Limpieza:**

```bash
helm uninstall <appName> -n tenant-<t>            # aplicación de un cliente
kubectl delete -k admin/events/tenants/<t>        # Fase 5 de un tenant
helm uninstall keda -n keda                       # KEDA
minikube stop                                     # conserva el clúster
minikube delete                                   # borra el clúster completo
```

## 8. Estado de verificación

Este repositorio no se ha ejecutado todavía en un clúster real. Se validó sin clúster:

- Render de las plantillas con Helm 3.19 y Helm 4.3, y de los overlays con Kustomize 5.8 (kubectl 1.37).
- `kubeconform -strict` sobre los 46 recursos generados, incluidos los CRD de KEDA y de Prometheus Operator.
- Los archivos `*-values.yaml` contra los charts kube-prometheus-stack 93.3.1, prometheus-adapter 5.4.2 y keda 2.21.1 (las versiones que fija `bootstrap.sh`).
- `shellcheck` en todos los scripts; `deploy.sh`, `tests/hpa.sh` y `tests/keda.sh` con herramientas simuladas; `worker.sh` contra una API de RabbitMQ simulada.

Lo que solo se comprueba en la VM: Calico y las NetworkPolicy, el límite de tasa del Ingress, las métricas del HPA, el arranque de RabbitMQ y de KEDA, `install-host.sh` y `set-permissions.sh`.
