# COMANDOS - `paas-lab`

Referencia de los comandos de la plataforma: argumentos, variables de entorno y valores por defecto. Todos se ejecutan desde la raíz de `paas-lab/`, salvo que se indique otra cosa. El orden de uso está en [README.md](README.md); la estructura, en [ESTRUCTURA.md](ESTRUCTURA.md).

Notación: `<x>` es obligatorio, `[x=valor]` es opcional con su valor por defecto. Las variables de entorno se anteponen al comando: `VARIABLE=valor comando`.

## 1. Resumen

| Comando | Quién lo ejecuta | Para qué |
|---|---|---|
| `sudo scripts/install-host.sh` | Administrador, una vez | Prepara la VM |
| `scripts/bootstrap.sh <etapa>...` | Administrador, sin sudo | Levanta la plataforma por etapas |
| `sudo scripts/set-permissions.sh` | Administrador | Instala `/opt/paas`, usuarios y reglas de sudo |
| `deploy.sh <tenant>` | Cliente (por sudo) o administrador | Despliega la aplicación de un tenant |
| `tests/isolation.sh [A] [B]` | Administrador | Prueba el aislamiento de red |
| `tests/quota.sh <tenant>` | Administrador | Prueba la cuota |
| `tests/ratelimit.sh <dominio> [n]` | Administrador | Prueba el límite de tasa HTTP |
| `tests/hpa.sh <tenant> [segundos]` | Administrador | Prueba el autoescalado HTTP |
| `tests/keda.sh <tenant> [mensajes]` | Administrador | Prueba el escalado por eventos |
| `tests/priority.sh [tenant]` | Administrador | Compara la carga de prioridad alta y la de prioridad baja |

Códigos de salida de las pruebas: `0` todas las comprobaciones pasaron, `1` alguna falló, `2` no se pudo ejecutar (tenant inexistente, fase sin instalar).

## 2. Scripts de plataforma

### `scripts/install-host.sh`

```bash
sudo scripts/install-host.sh
```

Sin argumentos ni variables. Instala `docker.io`, `conntrack`, `curl`, `python3-yaml`, Minikube, kubectl y Helm; agrega al administrador al grupo `docker`; escribe `/etc/sysctl.d/99-paas.conf`. Avisa si la VM tiene menos de 2 CPU, 3500 MB de RAM o 30 GB en `/`, o si no hay swap. Después hay que cerrar la sesión y volver a entrar.

| Parámetro del kernel | Valor |
|---|---|
| `vm.swappiness` | 10 |
| `fs.inotify.max_user_instances` | 512 |
| `fs.inotify.max_user_watches` | 524288 |

### `scripts/bootstrap.sh`

```bash
scripts/bootstrap.sh <etapa>...
```

Acepta una o varias etapas; se ejecutan en el orden escrito. No se ejecuta como root.

| Etapa | Qué hace |
|---|---|
| `cluster` | Minikube (driver Docker, CNI Calico) con los addons `ingress` y `metrics-server` |
| `tenancy` | Fase 1: `kubectl apply -k` de cada directorio de `admin/tenancy/tenants/` |
| `monitoring` | Fases 3-4: kube-prometheus-stack, recursos de `admin/monitoring/` y Prometheus Adapter |
| `hosts` | Escribe en `/etc/hosts` la IP de Minikube y el dominio de cada tenant (pide sudo) |
| `events` | Fase 5: KEDA, Secret `rabbitmq-credentials` y recursos de `admin/events/tenants/` |
| `status` | CPU y memoria reservadas en el nodo, `kubectl top node` y `free -m` |
| `all` | `cluster tenancy monitoring hosts` (no incluye `events`) |

| Variable | Por defecto | Efecto |
|---|---|---|
| `HOST_RESERVED_MB` | `1024` | Memoria que queda para Ubuntu fuera del nodo. Memoria del nodo = RAM total - este valor (mínimo admitido para el nodo: 2600 MB) |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | Clave del usuario `admin` de Grafana |
| `KPS_CHART_VERSION` | `93.3.1` | Versión del chart kube-prometheus-stack |
| `ADAPTER_CHART_VERSION` | `5.4.2` | Versión del chart prometheus-adapter |
| `KEDA_CHART_VERSION` | `2.21.1` | Versión del chart keda |

Parámetros fijos de `cluster`: `minikube start --driver=docker --cpus=<núcleos de la VM> --memory=<nodo>mb --cni=calico`.

```bash
scripts/bootstrap.sh all
scripts/bootstrap.sh tenancy hosts
GRAFANA_ADMIN_PASSWORD='otra-clave' scripts/bootstrap.sh monitoring
HOST_RESERVED_MB=900 scripts/bootstrap.sh cluster
```

### `scripts/set-permissions.sh`

```bash
sudo scripts/set-permissions.sh
```

Sin argumentos ni variables. Usa como administrador al usuario que invoca sudo. Repetir después de modificar el chart o `deploy.sh`, o de dar de alta un tenant. No sobrescribe el `values.yaml` que el cliente ya editó.

### `scripts/deploy.sh`

```bash
sudo -u <administrador> /opt/paas/scripts/deploy.sh <tenant>   # cliente
scripts/deploy.sh <tenant>                                     # administrador, desde el repositorio
```

| Argumento | Formato | Descripción |
|---|---|---|
| `<tenant>` | `^[a-z][a-z0-9]{0,20}$` | Tenant dado de alta. El cliente solo puede pasar el suyo (regla de sudoers) |

Sin variables de entorno. Lee `tenants/<tenant>/values.yaml` (64 KiB como máximo). El plan y el dominio base los toma del Namespace. Parámetros fijos de Helm: espera de 3 minutos, restauración automática si falla, historial de 5 versiones.

## 3. Archivo del cliente: `tenants/<tenant>/values.yaml`

| Clave | Obligatoria | Por defecto | Valores admitidos |
|---|---|---|---|
| `appName` | Sí | - | Minúsculas, dígitos y guiones; empieza por letra; hasta 42 caracteres |
| `image` | Sí | - | Imagen con tag explícito (`nginx:alpine`) o digest (`@sha256:...`) |
| `domain` | Sí | - | El dominio base del tenant o un subdominio suyo |
| `port` | No | `80` | Puerto en el que escucha el contenedor |
| `replicaCount` | No | `1` | Réplicas iniciales y mínimo del autoescalado; no supera el máximo del plan |
| `env` | No | `{}` | Variables no sensibles (ConfigMap). Valores siempre entre comillas |
| `secretEnv` | No | `{}` | Variables sensibles (Secret). Valores siempre entre comillas |
| `persistence.enabled` | No | `false` | Crea un volumen para la aplicación |
| `persistence.size` | No | `1Gi` | Tamaño del volumen; cuenta contra la cuota de storage |
| `persistence.mountPath` | No | `/data` | Ruta de montaje |
| `autoscaling.enabled` | No | `false` | Activa el HPA |
| `autoscaling.maxReplicas` | No | `2` | No supera el máximo del plan (`standard` 3, `basic` 2) |
| `autoscaling.targetCPU` | No | `70` | Porcentaje de CPU que dispara el escalado, de 10 a 95 |

Los rangos exactos están en `paas-app-chart/values.schema.json`. Las claves `plan`, `tenant` e `ingressClassName` las impone la plataforma; lo que el cliente escriba en ellas no tiene efecto.

## 4. Pruebas

### `tests/isolation.sh`

```bash
tests/isolation.sh [tenantA=alpha] [tenantB=beta]
```

Sin variables. Comprueba ICMP y TCP dentro de A (permitido) y entre A y B en ambos sentidos (bloqueado). Con la Fase 5 instalada, también que B no alcanza el broker de A.

### `tests/quota.sh`

```bash
tests/quota.sh <tenant>
```

| Variable | Por defecto | Efecto |
|---|---|---|
| `KEEP` | `0` | Con `1` conserva los recursos de prueba, para observar las alertas de cuota |

Limpieza tras `KEEP=1`: `kubectl -n tenant-<tenant> delete deployment,pvc --selector paas/test=quota`.

### `tests/ratelimit.sh`

```bash
tests/ratelimit.sh <dominio> [solicitudes=500]
```

| Variable | Por defecto | Efecto |
|---|---|---|
| `INGRESS_ADDR` | IP de Minikube | Dirección a la que se envían las solicitudes |

Concurrencia fija: 50 solicitudes en paralelo.

### `tests/hpa.sh`

```bash
tests/hpa.sh <tenant> [segundos=240]
```

| Variable | Por defecto | Efecto |
|---|---|---|
| `WAIT_DOWN` | `0` | Con `1` espera además el regreso al mínimo de réplicas (hasta 420 s) |
| `INGRESS_ADDR` | IP de Minikube | Dirección a la que se envía la carga |

La carga es una ráfaga por segundo del doble del límite de tasa del plan. Termina antes si el HPA alcanza su máximo.

### `tests/keda.sh`

```bash
tests/keda.sh <tenant> [mensajes=50]
```

| Variable | Por defecto | Efecto |
|---|---|---|
| `TIMEOUT` | `300` | Segundos máximos de observación del ciclo |

```bash
tests/keda.sh beta
tests/keda.sh beta 100
TIMEOUT=600 tests/keda.sh alpha 200
```

### `tests/priority.sh`

```bash
tests/priority.sh [tenant=beta]
```

Requiere el modo prioridad aplicado (sección 6). Publica primero la carga estándar y después la VIP, observa los dos consumidores y muestra una tabla con el tiempo hasta el primer worker, el pico de workers y el tiempo hasta vaciar cada cola.

| Variable | Por defecto | Efecto |
|---|---|---|
| `LOW_MESSAGES` | `30` | Mensajes de prioridad 1 a la cola estándar (`pedidos`) |
| `HIGH_MESSAGES` | `10` | Mensajes de prioridad 10 a la cola VIP (`pedidos-vip`) |
| `TIMEOUT` | `300` | Segundos máximos de observación |

```bash
tests/priority.sh
LOW_MESSAGES=60 HIGH_MESSAGES=15 tests/priority.sh beta
```

## 5. Parámetros de la Fase 5

| Parámetro | Valor | Dónde se cambia |
|---|---|---|
| Workers máximos (`maxReplicaCount`) | alpha 5, beta 15 | `admin/events/tenants/<tenant>/kustomization.yaml` |
| Mensajes por réplica (`value`) | alpha 5, beta 2 | Mismo archivo |
| `pollingInterval` | 10 s | `admin/events/consumer/scaler.yaml` |
| `cooldownPeriod` | 20 s | `admin/events/consumer/scaler.yaml` |
| Colas que declara el broker (`QUEUES`) | `pedidos` | `admin/events/base/rabbitmq.yaml`. Formato: `<nombre>` o `<nombre>:<prioridad máxima>`, separadas por espacios |
| Cola del consumidor (`QUEUE_NAME`, `queueName`) | `pedidos` | `consumer/worker.yaml` y `consumer/scaler.yaml` (los dos a la vez) |
| `PROCESS_SECONDS` (worker) | 1 | Variable de entorno en `admin/events/consumer/worker.yaml` |
| `IDLE_SECONDS` (worker) | 2 | Variable de entorno en `admin/events/consumer/worker.yaml` |

Después de cambiar cualquiera: `scripts/bootstrap.sh events`.

## 6. Modo prioridad de la Fase 5

Agrega a un tenant una cola prioritaria con su propio consumidor. Hoy existe para beta (`admin/events/tenants/beta-priority/`).

| Cola | Consumidor | Máx. workers | Mensajes por réplica | Sondeo | Cooldown |
|---|---|---|---|---|---|
| `pedidos` (estándar) | `worker` | 15 | 15 | 15 s | 20 s |
| `pedidos-vip` (prioridad 0-10) | `worker-vip` | 15 | 1 | 5 s | 15 s |

```bash
# Aplicar (el broker se reinicia para declarar pedidos-vip)
kubectl apply -k admin/events/tenants/beta-priority
kubectl -n tenant-beta rollout status deployment/rabbitmq

# Observar (en otras terminales)
kubectl get pods -n tenant-beta -w
kubectl get hpa -n tenant-beta -w

# Probar
tests/priority.sh beta

# Retirar y volver al SLA normal de beta
kubectl -n tenant-beta delete scaledobject,deployment,configmap --selector paas/priority=vip
kubectl apply -k admin/events/tenants/beta
```

Valores en `admin/events/priority/kustomization.yaml` (cola estándar y `QUEUES`) y `admin/events/priority/vip/kustomization.yaml` (cola VIP).

## 7. Comandos de operación

```bash
# Estado
kubectl get pods -A
kubectl -n tenant-<t> get deployment,service,ingress,hpa,pvc
kubectl -n tenant-<t> describe resourcequota paas-quota
kubectl -n tenant-<t> get scaledobject,hpa
kubectl -n tenant-<t> get pods -w

# Registros
kubectl -n monitoring logs deploy/alert-sink --tail=20
kubectl -n tenant-<t> logs --selector app.kubernetes.io/name=worker --tail=20

# Fase 1 de un tenant, sin bootstrap
kubectl apply -k admin/tenancy/tenants/<t>

# Acceso desde el equipo anfitrión (http://<IP-VM>:<puerto>)
kubectl -n monitoring port-forward --address 0.0.0.0 svc/prometheus-grafana 3000:80 &
kubectl -n monitoring port-forward --address 0.0.0.0 svc/prometheus-kube-prometheus-prometheus 9090:9090 &
kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 8080:80 &

# Limpieza
helm uninstall <appName> -n tenant-<t>
kubectl delete -k admin/events/tenants/<t>
helm uninstall keda -n keda
minikube stop
minikube delete
```
