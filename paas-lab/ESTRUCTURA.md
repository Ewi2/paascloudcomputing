# ESTRUCTURA - PaaS multi-tenant sobre Kubernetes (`paas-lab`)

Documento de referencia. Describe cómo está organizado el repositorio, dónde vive cada dato, cuánto consume cada parte en la VM y qué reglas no se deben romper al modificarlo. La guía de ejecución es [README.md](README.md).

La fuente de verdad son los archivos del repositorio. Si un archivo y este documento discrepan, prevalece el archivo.

**Versión:** chart `paas-app-chart` 0.3.0. La sección 9 resume los cambios respecto a la 0.2.0.

## 1. Resumen

| Aspecto | Descripción |
|---|---|
| Qué es | PaaS multi-tenant de laboratorio (Informática en la Nube), alineado con NIST SP 800-145: autoservicio bajo demanda, agrupación de recursos con aislamiento, elasticidad y servicio medido |
| Dónde corre | Clúster Kubernetes de un nodo (Minikube, driver Docker, CNI Calico) en una VM Ubuntu Server 22.04 sobre VMware: 2 vCPU, 4 GB de RAM, 40 GB de disco |
| Tenants | `alpha` (plan `standard`) y `beta` (plan `basic`), cada uno en el namespace `tenant-<tenant>` |
| Administrador | Opera el clúster. Es dueño de todo el repositorio salvo un archivo por tenant |
| Cliente | Usuario Linux `cliente-<tenant>`. Edita solo `tenants/<tenant>/values.yaml` y ejecuta `deploy.sh <tenant>` mediante sudo. No tiene kubeconfig ni acceso a Docker |
| Entrada de aplicaciones | Imagen de contenedor con tag explícito o digest. No se construye desde Dockerfile |

## 2. Árbol del repositorio

```
paas-lab/
├── README.md                          Guía de ejecución
├── ESTRUCTURA.md                      Este documento
├── admin/                             Lo que solo toca el administrador
│   ├── tenancy/                       Fase 1 (Kustomize)
│   │   ├── base/                      Común a todo tenant
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml         Namespace con Pod Security "baseline"
│   │   │   └── networkpolicies.yaml   default-deny-ingress, allow-same-namespace,
│   │   │                              allow-ingress-controller, restrict-egress
│   │   ├── plans/                     Parte de namespace de cada plan (Components)
│   │   │   ├── basic/                 kustomization.yaml, resourcequota.yaml, limitrange.yaml
│   │   │   └── standard/              ídem
│   │   └── tenants/                   REGISTRO DE TENANTS: un directorio por tenant
│   │       ├── alpha/kustomization.yaml   tenant-alpha, plan standard, alpha.paas.local
│   │       └── beta/kustomization.yaml    tenant-beta,  plan basic,    beta.paas.local
│   ├── monitoring/                    Fases 3-4
│   │   ├── kustomization.yaml         Recursos propios: kubectl apply -k admin/monitoring
│   │   ├── alerts.yaml                PrometheusRule: cuota >= 80 %, cuota agotada, HPA en su máximo
│   │   ├── alert-sink.yaml            Receptor de alertas del laboratorio (Deployment y Service)
│   │   ├── alert-sink.py              Código del receptor (ConfigMap generado)
│   │   ├── ingress-metrics.yaml       Service y ServiceMonitor de las métricas del Ingress
│   │   ├── tenants-dashboard.json     Tablero "PaaS - Consumo por tenant" (ConfigMap generado)
│   │   ├── kube-prometheus-stack-values.yaml   Perfil de recursos para la VM
│   │   ├── alertmanager-values.yaml            Ruta y receptor de alertas por tenant
│   │   └── prometheus-adapter-values.yaml      Métrica ingress_requests_per_second
│   └── events/                        Fase 5 (Kustomize)
│       ├── keda-values.yaml           Recursos de KEDA para la VM
│       ├── base/                      Común a todo tenant
│       │   ├── kustomization.yaml
│       │   ├── rabbitmq.yaml          Broker (Deployment y Service, puertos 5672 y 15672)
│       │   ├── worker.yaml            Consumidor (Deployment, 0 réplicas iniciales)
│       │   ├── worker.sh              Lógica del consumidor (ConfigMap generado)
│       │   ├── scaler.yaml            TriggerAuthentication y ScaledObject
│       │   └── networkpolicy.yaml     Permite a KEDA consultar el broker
│       └── tenants/                   SLA de eventos por tenant
│           ├── alpha/kustomization.yaml   hasta 5 workers, 1 cada 5 mensajes
│           └── beta/kustomization.yaml    hasta 15 workers, 1 cada 2 mensajes
├── paas-app-chart/                    Fases 2-3 (Helm): la plantilla de toda aplicación
│   ├── Chart.yaml
│   ├── values.yaml                    Valores por defecto (del administrador)
│   ├── values.schema.json             Qué puede escribir el cliente
│   ├── plans.yaml                     Parte de aplicación de cada plan
│   └── templates/                     deployment, service, ingress, hpa, configmap, secret, pvc, _helpers
├── tenants/                           ÚNICO contenido editable por los clientes
│   ├── alpha/values.yaml              nginx
│   └── beta/values.yaml               httpbin (Python/Flask) con volumen
├── scripts/
│   ├── install-host.sh                Prepara la VM (una vez, con sudo)
│   ├── bootstrap.sh                   Levanta la plataforma por etapas
│   ├── set-permissions.sh             Instala /opt/paas, usuarios y reglas de sudo (con sudo)
│   └── deploy.sh                      Despliegue de la aplicación de un tenant
└── tests/
    ├── lib.sh                         Funciones comunes
    ├── isolation.sh  quota.sh         Fase 1
    ├── ratelimit.sh                   Fase 2
    ├── hpa.sh                         Fase 3
    └── keda.sh                        Fase 5
```

Convenciones:

- Los archivos `*-values.yaml` son valores de Helm. El resto de los YAML de `admin/` son manifiestos de Kubernetes o de Kustomize.
- Lo que varía por tenant vive en un overlay (`tenants/<tenant>/kustomization.yaml`); lo común, en `base/`. Ningún manifiesto de `base/` nombra un tenant.
- El código que corre dentro de un pod (`worker.sh`, `alert-sink.py`) y el tablero (`tenants-dashboard.json`) son archivos propios, no texto incrustado en un YAML. Kustomize genera el ConfigMap y, salvo en el tablero, agrega al nombre un hash del contenido: un cambio de código reinicia los pods.
- Los scripts de Bash usan `set -euo pipefail`, constantes `readonly` al inicio y una función por responsabilidad. Las pruebas omiten `-e` a propósito: cuentan las fallas y continúan.

## 3. Origen de cada dato

Cada dato se define en un solo lugar. Quien lo necesita lo lee de ahí.

| Dato | Se define en | Lo consumen |
|---|---|---|
| Tenants existentes | Directorios de `admin/tenancy/tenants/` | `bootstrap.sh`, `set-permissions.sh` |
| Plan del tenant | `components:` del overlay del tenant; queda como etiqueta `paas/plan` del Namespace | `deploy.sh` lo lee del Namespace |
| Dominio base del tenant | Parche del overlay; queda como anotación `paas/domain` del Namespace | `deploy.sh`, `bootstrap.sh hosts` |
| Cuota y límites por contenedor | `admin/tenancy/plans/<plan>/` | Kubernetes (admisión) |
| Réplicas máximas, recursos por pod, tasa HTTP, objetivo del HPA por Ingress | `paas-app-chart/plans.yaml` | Plantillas del chart |
| Imagen, réplicas, variables de entorno, dominio, volumen, objetivo de CPU | `tenants/<tenant>/values.yaml` (cliente) | `deploy.sh`, chart |
| SLA de eventos (workers máximos, mensajes por réplica) | `admin/events/tenants/<tenant>/kustomization.yaml` | KEDA |
| Credenciales del broker | Secret `rabbitmq-credentials`, generado por `bootstrap.sh events` | Broker, worker, KEDA |
| Destinatario de las alertas | `admin/monitoring/alertmanager-values.yaml` | Alertmanager |
| Versiones de los charts | Constantes de `scripts/bootstrap.sh` | Helm |

El plan y el dominio viajan en el Namespace porque solo el administrador puede modificarlo: el cliente no puede cambiarse de plan ni publicar en el dominio de otro tenant.

El nombre de la cola (`pedidos`) es la única repetición deliberada: aparece en `rabbitmq.yaml`, `worker.yaml` y `scaler.yaml`, porque un ScaledObject no puede leerlo de un ConfigMap. Cada aparición lleva un comentario que remite a las otras dos.

## 4. Entorno y presupuesto de recursos

### 4.1 VM y clúster

| Capa | Configuración |
|---|---|
| VM | VMware, 2 vCPU, 4096 MB, 40 GB, Ubuntu Server 22.04 LTS; swap con `vm.swappiness=10` |
| Minikube | `--driver=docker --cpus=2 --memory=<RAM total - 1024 MB> --cni=calico` (unos 2.9 GB para el nodo). Lo calcula `bootstrap.sh cluster` |
| Addons | `ingress` (NGINX Ingress Controller) y `metrics-server` |
| Charts (versiones que fija `bootstrap.sh`) | kube-prometheus-stack 93.3.1, prometheus-adapter 5.4.2, KEDA 2.21.1; Helm 3 o 4 |

Por qué Calico: el CNI por defecto de Minikube no aplica NetworkPolicy; sin él la Fase 1 no aísla la red.

Por qué reservar 1024 MB: Ubuntu, dockerd y containerd corren fuera del nodo. Con menos margen la VM puede paginar y el API server responder con timeouts. Se ajusta con la variable `HOST_RESERVED_MB`.

### 4.2 CPU (requests sobre un nodo de 2000m)

El scheduler reparte la CPU por `requests`, no por uso real. Un pod que no cabe queda en `Pending`.

| Componente | Requests |
|---|---|
| Plano de control (API server 250m, controller-manager 200m, scheduler 100m, etcd 100m, CoreDNS 100m) | 750m |
| Calico (`calico-node`) | 250m |
| NGINX Ingress Controller | 100m |
| Metrics Server | 100m |
| Monitoreo (Prometheus 105m, Grafana 60m, Alertmanager 15m, operador 20m, kube-state-metrics 10m, node-exporter 10m, Adapter 20m, alert-sink 10m) | 250m |
| **Plataforma (fijo)** | **1450m** |
| **Libre para los tenants** | **550m** |

| Carga de los tenants | Mínimo | Máximo |
|---|---|---|
| Aplicación de alpha (`standard`: 75m por pod, 1 a 3 réplicas) | 75m | 225m |
| Aplicación de beta (`basic`: 50m por pod, 1 a 2 réplicas) | 50m | 100m |
| Fase 5, KEDA (operador 20m, servidor de métricas 20m, webhooks 10m) | 50m | 50m |
| Fase 5, brokers (50m por tenant) | 100m | 100m |
| Fase 5, workers de alpha (10m por pod, 0 a 5) | 0 | 50m |
| Fase 5, workers de beta (10m por pod, 0 a 15) | 0 | 150m |
| **Total** | **275m** | **675m** |

Consecuencias:

- Fases 1 a 4 con las dos aplicaciones en su máximo: 1775m. Cabe.
- Con la Fase 5 instalada y en reposo, las aplicaciones aún pueden llegar a su máximo: 1925m.
- El máximo de workers de beta y el máximo de las dos aplicaciones a la vez suman 2075m: no cabe. `tests/hpa.sh` y `tests/keda.sh beta` se ejecutan por separado.

### 4.3 Memoria y disco

Estimación de uso real; se comprueba con `scripts/bootstrap.sh status`.

| Bloque | Memoria estimada |
|---|---|
| Plano de control, kubelet y runtime del nodo | 0.9 - 1.0 GB |
| Calico, Ingress y Metrics Server | 0.3 GB |
| Monitoreo | 0.8 - 1.0 GB |
| Aplicaciones de los tenants | 0.1 - 0.2 GB |
| Fase 5 (KEDA 0.15 GB, dos brokers 0.3 GB, workers 0.05 GB) | 0.5 GB |

Las Fases 1 a 4 ocupan entre 2.1 y 2.5 GB de los 2.9 GB del nodo. Con la Fase 5 el nodo queda cerca de su límite: por eso `bootstrap.sh all` no la incluye y se instala con `bootstrap.sh events` cuando se va a demostrar. El perfil de monitoreo reduce memoria desactivando las métricas del API server y la recolección de componentes que Minikube no expone, y limita la retención de Prometheus a 6 horas.

Disco: las imágenes de todas las fases ocupan unos 5 GB. Con el volumen raíz extendido a los 40 GB sobra espacio.

## 5. Fases

### Fase 1 - Aislamiento (`admin/tenancy/`)

`kubectl apply -k admin/tenancy/tenants/<tenant>` genera, para ese tenant: Namespace, ResourceQuota `paas-quota`, LimitRange `paas-defaults` y cuatro NetworkPolicy.

| Plan | requests.cpu / memory | limits.cpu / memory | Storage | Por contenedor (defecto) | Por contenedor (máximo) |
|---|---|---|---|---|---|
| `standard` | 2 / 4Gi | 4 / 8Gi | 10Gi, 2 PVC | 200m-500m, 256Mi-512Mi | 1 CPU, 1Gi |
| `basic` | 1 / 2Gi | 2 / 4Gi | 5Gi, 2 PVC | 100m-250m, 128Mi-256Mi | 500m, 512Mi |

Los valores de `requests` de la cuota son los de la guía del laboratorio. La cuota además prohíbe Services `NodePort` y `LoadBalancer`, y limita a 30 pods y 2 Ingress.

Red: se niega toda entrada salvo la del propio namespace y la del Ingress Controller. La salida se limita al propio namespace, al DNS del clúster y a Internet; los rangos privados quedan bloqueados, y con ellos los demás tenants.

### Fase 2 - Abstracción (`paas-app-chart/`, `scripts/deploy.sh`)

El cliente escribe `appName`, `image`, `domain` y, si quiere, `port`, `replicaCount`, `env`, `secretEnv`, `persistence` y `autoscaling`. El chart genera Deployment, Service, Ingress, HPA, ConfigMap, Secret y PVC.

Tres capas de validación, de fuera hacia dentro:

1. `deploy.sh`: archivo regular de 64 KiB como máximo, `appName` e `image` bien formados, dominio dentro del dominio base del tenant.
2. `values.schema.json`: tipos, patrones y claves permitidas. Rechaza claves desconocidas.
3. `_helpers.tpl`: réplicas dentro del máximo del plan.

`deploy.sh` impone `plan` y `tenant` con `--set-string`: prevalecen sobre lo que escriba el cliente.

| Plan | Réplicas máx. | Recursos por pod (request / limit) | Tasa HTTP por IP | Objetivo del HPA por Ingress |
|---|---|---|---|---|
| `standard` | 3 | 75m, 96Mi / 300m, 256Mi | 50 rps, 100 conexiones | 20 rps por pod |
| `basic` | 2 | 50m, 64Mi / 200m, 192Mi | 10 rps, 20 conexiones | 5 rps por pod |

### Fase 3 - Elasticidad

HPA v2 con dos métricas; escala con la que pida más réplicas.

- **CPU** (Metrics Server): el cliente fija el objetivo (`autoscaling.targetCPU`, 10 a 95 %).
- **Peticiones por segundo del Ingress** (Prometheus Adapter): el plan fija el objetivo. La métrica `ingress_requests_per_second` es `rate(nginx_ingress_controller_requests[1m])` sin respuestas 5xx, de modo que los 503 del límite de tasa no provocan escalado.

Subida: hasta 100 % cada 30 s. Bajada: 50 % cada 60 s con ventana de estabilización de 120 s.

### Fase 4 - Telemetría (`admin/monitoring/`)

- **Tablero** "PaaS - Consumo por tenant" (carpeta PaaS), filtrado por la variable `$namespace`: consumo frente a la cuota, réplicas de los autoescaladores, peticiones HTTP por código, CPU, memoria, red, almacenamiento y pods por fase.
- **Alertas** `TenantQuotaNearLimit` (cuota al 80 % o más), `TenantQuotaExhausted` y `TenantHpaAtMaxReplicas`. Alertmanager las enruta por namespace al receptor de cada cliente; en el laboratorio el receptor es `alert-sink`, que las imprime.

### Fase 5 - Escalado por eventos (`admin/events/`)

Cada tenant tiene su broker RabbitMQ, un consumidor `worker` y un ScaledObject de KEDA.

1. El broker declara la cola `pedidos` al arrancar (`postStart`).
2. KEDA consulta la longitud de la cola por AMQP cada 10 s. Con mensajes pendientes activa el worker (0 → 1).
3. El HPA que crea KEDA (`keda-hpa-worker`) calcula `ceil(mensajes / mensajes por réplica)` y escala hasta el máximo del SLA.
4. Cada worker extrae un mensaje por la API HTTP del broker (puerto 15672), lo confirma y simula un segundo de procesamiento.
5. Con la cola vacía durante `cooldownPeriod` (20 s), KEDA devuelve el worker a 0 réplicas.

El SLA de eventos es un contrato distinto del plan de cómputo: beta tiene el plan `basic` y el SLA de eventos de alta capacidad, como en la guía.

## 6. Flujo de despliegue

1. El cliente edita `~/values.yaml` y ejecuta `sudo -u <administrador> /opt/paas/scripts/deploy.sh <tenant>`. La regla de sudoers solo le permite ese comando con su tenant.
2. `deploy.sh` lee el plan y el dominio base del Namespace.
3. Copia el archivo del cliente a un temporal: lo que se valida es exactamente lo que se despliega.
4. `docker pull` y `minikube image load`: la imagen se comprueba antes de tocar el clúster.
5. `helm upgrade --install` con restauración automática si el despliegue falla, e historial de 5 versiones.

Las variables de entorno van a un ConfigMap (`env`) o a un Secret (`secretEnv`). Una anotación con el hash de ambos reinicia los pods cuando cambian.

## 7. Reglas que no se deben romper

1. **Coherencia plan - cuota:** `(maxReplicas + maxSurge) × requests.cpu ≤ requests.cpu` de la cuota del plan.
2. **Coherencia plan - nodo:** la suma de `maxReplicas × requests.cpu` de todos los tenants no supera la CPU libre del nodo (sección 4.2).
3. **Coherencia plan - HPA:** `ceil(rateLimit.rps / ingressRpsPerPod) ≤ maxReplicas`.
4. **Todo pod declara requests y limits.** La cuota incluye `limits.cpu`: un pod sin límites solo entra gracias a los valores por defecto del LimitRange.
5. **El mínimo del LimitRange (10m, 16Mi) no sube** sin revisar los workers de la Fase 5 y los pods de `tests/`.
6. **Nada de un tenant en `base/`.** Lo que distingue a un tenant va en su overlay.
7. **Ningún secreto en el repositorio.** Las credenciales del broker se generan en el clúster.
8. **Las etiquetas `release: prometheus`** de `alerts.yaml` e `ingress-metrics.yaml` dependen de que kube-prometheus-stack se instale con el nombre de release `prometheus`.
9. **`honorLabels: true`** en el ServiceMonitor del Ingress: sin él, el HPA por peticiones y el panel HTTP del tablero quedan sin datos.
10. **La excepción de red de KEDA** (`allow-keda-to-rabbitmq`) solo admite al operador de KEDA y solo el puerto 5672.

## 8. Trazabilidad con las guías

### Guía "PaaS Multi-Tenant sobre Kubernetes" y reunión

| Requisito | Dónde se cubre |
|---|---|
| Otra tecnología en el segundo namespace | `tenants/beta/values.yaml` (httpbin), mismo chart |
| ResourceQuota de CPU, RAM y storage | `admin/tenancy/plans/<plan>/resourcequota.yaml` |
| Avisar al cliente cuando se excede | `alerts.yaml`, `alertmanager-values.yaml`, `alert-sink.*` |
| LimitRange | `admin/tenancy/plans/<plan>/limitrange.yaml` |
| Límite de peticiones que recibe el cliente | Anotaciones `limit-*` de `templates/ingress.yaml`, valores en `plans.yaml` |
| NetworkPolicy, probada con ICMP | `admin/tenancy/base/networkpolicies.yaml`, `tests/isolation.sh` |
| Repetir para el otro cliente con otros valores | Overlay de `beta` y plan `basic` |
| El cliente no toca la capa IaaS | Chart, `values.schema.json`, `deploy.sh` |
| Permisos de Linux y enlaces simbólicos | `scripts/set-permissions.sh` |
| Imagen, réplicas, variables de entorno y dominio | `tenants/<tenant>/values.yaml` |
| Deployment, Service e Ingress | `paas-app-chart/templates/` |
| HPA y prueba de carga | `templates/hpa.yaml`, `tests/hpa.sh` |
| Tablero filtrado por `$namespace` | `tenants-dashboard.json` |

### Guías de KEDA (semanas 15 y 17)

| En la guía | En este repositorio |
|---|---|
| Paso 1: instalar KEDA | `bootstrap.sh events` con `keda-values.yaml` |
| Pod `rabbitmq-<tenant>` creado con `kubectl run` | Deployment `rabbitmq` |
| Service `rabbitmq-service` (5672) y parche posterior para 15672 | Service `rabbitmq` con los dos puertos |
| Deployment `worker-app` con `alpine` y `sleep 3600` | Sustituido por el consumidor real de la semana 17 |
| Worker con `curlimages/curl:latest` y script en `args` | Deployment `worker`, imagen `curlimages/curl:8.12.1`, script en `worker.sh` |
| ScaledObject `keda-rabbitmq-scaler` con `amqp://guest:guest@...` en el manifiesto | ScaledObject `worker` y TriggerAuthentication `rabbitmq`, con la URI en un Secret |
| Colas `pedidos-alpha` y `pedidos-beta`, declaradas a mano | Cola `pedidos` en el broker de cada tenant, declarada al arrancar |
| 50 ejecuciones de `kubectl exec ... rabbitmqadmin publish` | `tests/keda.sh <tenant> [mensajes]` |
| alpha: máximo 5, `value: "5"`; beta: máximo 15, `value: "2"`; `cooldownPeriod: 20` | Iguales |

Diferencias deliberadas:

- **Sin credenciales `guest`.** Usuario `paas` con clave aleatoria por tenant.
- **`pollingInterval: 10`** en lugar de 30 (valor por defecto): KEDA detecta los mensajes en 10 s como mucho; a eso se suma el arranque del primer pod.
- **Subida sin tope de velocidad.** Por defecto el HPA agrega 4 pods o el 100 % cada 15 s. Con un consumidor real la cola se vacía antes de que el HPA llegue al máximo; la política `scaleUp` de `scaler.yaml` permite ir de 1 a las réplicas deseadas en un ciclo.
- **Publicación en ráfaga.** `tests/keda.sh` publica todos los mensajes en pocos segundos, dentro del pod del broker. Con 50 `kubectl exec` sucesivos, los workers consumen al ritmo de llegada y el pico de réplicas es menor.
- **NetworkPolicy adicional**, necesaria porque la Fase 1 niega la entrada desde otros namespaces.
- **El worker termina al recibir SIGTERM.** Sin el `trap` de `worker.sh`, cada pod agotaría su periodo de gracia antes de desaparecer al reducir réplicas.

El pico de réplicas depende de cuántos mensajes queden en cola cuando el HPA evalúa. Para ver el máximo de beta (15) hacen falta al menos 29 mensajes pendientes en ese momento; si 50 no bastan, usar `tests/keda.sh beta 100`.

## 9. Cambios respecto a la versión 0.2.0

**Estructura**

- Fase 1 con Kustomize: una base, un Component por plan y un overlay por tenant. Sustituye a `admin/tenant-alpha.yaml` y `admin/tenant-beta.yaml`, que eran el mismo archivo con otros valores.
- Se elimina `admin/tenants.env`: el plan y el dominio viven en el Namespace.
- `admin/monitoring/` pasa a aplicarse con un `kustomization.yaml`. El tablero y el receptor de alertas dejan de estar incrustados en YAML.
- `scripts/install-host.sh` y `scripts/bootstrap.sh` reemplazan los comandos manuales del README.
- `tests/lib.sh` reúne lo común de las pruebas. Se agregan `tests/hpa.sh` (el README lo citaba y no existía) y `tests/keda.sh`.
- `PLAN.md` se retira; su contenido vigente está en este documento.

**Fase 5 (nueva):** `admin/events/`, según las guías de las semanas 15 y 17.

**Ajustes para la VM de 2 vCPU y 4 GB**

- Planes: `standard` baja de 8 a 3 réplicas y `basic` de 5 a 2, con menos CPU por pod. Las cuotas no cambian.
- Perfil de recursos de kube-prometheus-stack (`kube-prometheus-stack-values.yaml`) y de KEDA.
- Mínimo del LimitRange de 50m/32Mi a 10m/16Mi; cuota de pods a 30 (los 15 workers de beta no cabían en 10).

**Correcciones**

- Métricas del Ingress: el PodMonitor apuntaba a un puerto que el addon de Minikube no declara, y la etiqueta `namespace` del tenant se perdía. Ahora hay un Service, un ServiceMonitor y `honorLabels`.
- Los scripts no tenían permiso de ejecución en Git.
- `set-permissions.sh` valida la regla de sudo antes de instalarla. Ya no copia `admin/` a `/opt/paas`: el cliente no necesita verlo.
- `deploy.sh` acepta cualquier tenant dado de alta, valida `appName`, funciona con Helm 3 y Helm 4, y localiza la plataforma por su propia ruta en lugar de una variable de entorno.
- `.gitignore` ignoraba `README.md` y `PLAN.md`.

## 10. Límites conocidos y pendientes

- **Sin ejecutar en un clúster real.** El detalle de lo validado está en el README, sección 8.
- El límite de tasa es por IP de origen, no por tenant, y solo aplica al tráfico que entra por el Ingress.
- Si el cliente cambia `appName`, Helm crea otra release y la anterior sigue activa: el administrador debe desinstalarla.
- `secretEnv` queda en texto plano en el archivo del cliente y en el historial de la release de Helm.
- El worker confirma el mensaje antes de procesarlo y usa la API HTTP de administración: es un atajo de laboratorio, no un consumidor AMQP de producción.
- El broker no tiene persistencia: si su pod se recrea, los mensajes pendientes se pierden. La cola se vuelve a declarar sola.
- Grafana solo es accesible para el administrador. Dar a cada cliente la vista de su namespace exige organizaciones o equipos de Grafana.
- La baja de un tenant es manual: borrar su namespace, su directorio, su usuario y su regla en `/etc/sudoers.d/`.
- Pendiente de decisión: panel de costos (showback) con las tarifas de la guía de servicio medido.

Correcciones propuestas a la guía PDF: el Paso 1 empieza en el LimitRange (faltan Namespace, ResourceQuota y NetworkPolicy); el generador de carga usa `-n cliente-alpha` en lugar de `tenant-alpha`; la consulta de cuota de CPU debe filtrar `type="hard"`; el diagrama (2 a 10 réplicas) y el `values.yaml` (`maxReplicas: 8`) no coinciden.
