# PLAN - PaaS multi-tenant sobre Kubernetes (Fases 1 y 2)

Proyecto Parcial1Cloud (Computación en la Nube). Entregable: `paas-lab.zip`, carpeta `paas-lab/` (27 archivos).

## 1. Qué se hizo

**Alcance.** Lo tratado en la reunión sobre el PDF: Fase 1 (aislamiento) y Fase 2 (abstracción con Helm) para `tenant-alpha` y `tenant-beta`. De las Fases 3 y 4 solo se incluyó el HPA, porque el chart del PDF lo lista (`hpa.yaml`).

**Secuencia**
1. Análisis del PDF, de la guía HTML (IaaS con servicio medido) y de la transcripción. Se detectaron errores y brechas (sección 7) y tres ambigüedades.
2. Aclaraciones del usuario: (a) "número de peticiones" es la tasa de solicitudes HTTP; (b) el aviso al cliente es una alerta automática; (c) basta un camino de entrada de la aplicación.
3. Diseño e implementación de manifiestos, chart, scripts y pruebas.
4. Validación estática y simulada (sección 5). Nada se ejecutó en un clúster real.
5. Empaquetado y este plan.

### Decisiones

| Tema | Decisión |
|---|---|
| Límite de peticiones | Tasa HTTP en el Ingress (`limit-rps`, `limit-connections`, `limit-burst-multiplier`), definida por el plan y no por el cliente. No va en el LimitRange. |
| Aviso al cliente | `PrometheusRule` (3 alertas) y Alertmanager enrutando por `namespace` al receptor de cada cliente. |
| Entrada de la aplicación | Solo imagen con tag explícito o digest. `deploy.sh` hace `docker pull` y `minikube image load`. El camino Dockerfile no se implementó. |
| Plan y tenant | Los fija el administrador (`admin/tenants.env` y `--set-string`); prevalecen sobre el archivo del cliente. |
| Archivo del cliente | `tenants/<tenant>/values.yaml`, separado del `values.yaml` del chart para poder aplicar permisos distintos por tenant. |
| Aplicación de beta | httpbin (Python/Flask) con un PVC, para cumplir "otra tecnología" y ejercitar la cuota de storage. |
| Cuotas | Valores del diagrama del PDF: alpha 2 CPU / 4 Gi, beta 1 CPU / 2 Gi (sobre `requests`), más `limits`, storage, PVC y pods. |

### Trazabilidad con la reunión

| Requisito del docente | Dónde se cubre |
|---|---|
| Duplicar Deployment y Service en el otro namespace, con otra tecnología [00:00:24-00:01:23] | `tenants/beta/values.yaml` (httpbin) desplegado con el mismo chart |
| ResourceQuota de CPU, RAM y storage [00:02:05] | `ResourceQuota paas-quota` en `admin/tenant-*.yaml` |
| Avisar al cliente cuando se excede [00:03:05] | `admin/monitoring/alerts.yaml`, `alertmanager-values.yaml`, `alert-sink.yaml` |
| LimitRange sobre requests [00:03:27] | `LimitRange paas-defaults` (`defaultRequest`, `min`, `max`, PVC) |
| Límite de peticiones recibidas [00:04:26] | Annotations de `templates/ingress.yaml` tomadas de `plans.yaml` |
| NetworkPolicy, probada con ICMP [00:04:36] | 4 NetworkPolicy por tenant y `tests/isolation.sh` |
| Repetir para el otro cliente con valores propios [00:06:08] | `admin/tenant-beta.yaml` y plan `basic` |
| El cliente no toca la capa IaaS; Helm [00:06:54-00:08:10] | Chart, `values.schema.json` y `deploy.sh` |
| Permisos Linux segmentados [00:08:58] | `scripts/set-permissions.sh` |
| Imagen, réplicas (opcional), variables de entorno, dominio [00:12:07-00:19:32] | `image`, `replicaCount`, `env` / `secretEnv`, `domain` en el `values.yaml` del cliente |
| Evaluación: Deployment, Service e Ingress [00:21:47] | `templates/deployment.yaml`, `service.yaml`, `ingress.yaml` |

## 2. Contenido del zip

```
paas-lab/
├── PLAN.md                         este documento
├── README.md                       resumen, prerrequisitos y comandos
├── admin/                          Fase 1 (root:root)
│   ├── tenant-alpha.yaml           Namespace, ResourceQuota, LimitRange, 4 NetworkPolicy
│   ├── tenant-beta.yaml            igual, con valores propios de beta
│   ├── tenants.env                 plan y dominio base por tenant
│   └── monitoring/
│       ├── alerts.yaml             PrometheusRule: cuota >= 80 %, cuota agotada, HPA en su máximo
│       ├── alertmanager-values.yaml  enrutamiento por namespace (helm upgrade --reuse-values)
│       └── alert-sink.yaml         receptor de prueba que imprime las alertas
├── paas-app-chart/                 Fase 2 (root:root)
│   ├── Chart.yaml
│   ├── values.yaml                 valores por defecto del chart
│   ├── plans.yaml                  planes basic y standard (réplicas, recursos, rate limit)
│   ├── values.schema.json          validación de lo que el cliente puede escribir
│   └── templates/
│       ├── _helpers.tpl            lectura del plan, validaciones y etiquetas
│       ├── deployment.yaml  service.yaml  ingress.yaml  hpa.yaml
│       └── configmap.yaml  secret.yaml  pvc.yaml
├── tenants/
│   ├── alpha/values.yaml           único archivo editable por cliente-alpha (nginx)
│   └── beta/values.yaml            único archivo editable por cliente-beta (httpbin + PVC)
├── scripts/
│   ├── deploy.sh                   valida, docker pull, minikube image load, helm upgrade --install
│   └── set-permissions.sh          instala en /opt/paas con usuarios, grupos y sudoers por tenant
└── tests/
    ├── isolation.sh                ICMP y TCP dentro del tenant y entre tenants
    ├── quota.sh                    cuota de CPU y de PVC (KEEP=1 conserva la carga para las alertas)
    └── ratelimit.sh                ráfaga HTTP contra el Ingress, espera mezcla de 200 y 503
```

### Planes y cuotas

Regla: `maxReplicas x request + surge (25 %) x request <= requests.cpu de la cuota`.

| Tenant | Plan | Réplicas máx. | Request / limit por pod | Rate limit | Pico con surge | Cuota CPU |
|---|---|---|---|---|---|---|
| alpha | standard | 8 | 150m / 300m | 50 rps, 100 conexiones | 10 x 150m = 1.5 | 2 |
| beta | basic | 5 | 100m / 250m | 10 rps, 20 conexiones | 7 x 100m = 0.7 | 1 |

En alpha sobran 0.5 CPU; el Deployment manual `app-cliente-alpha` (2 x 100m) usa 0.2.

### Modelo de permisos (`/opt/paas`)

| Ruta | Propietario y modo | Efecto |
|---|---|---|
| `paas-app-chart/`, `admin/`, `scripts/` | `root:root`, 755 / 644 | Solo lectura para los clientes |
| `tenants/<t>/` | `root:cliente-<t>`, 0750 | El cliente entra, no crea ni renombra archivos |
| `tenants/<t>/values.yaml` | `cliente-<t>:cliente-<t>`, 0640 | El cliente lo edita; el administrador lo lee por grupo; el otro tenant no accede |
| `/etc/sudoers.d/paas-<t>` | `root`, 0440 | El cliente solo ejecuta `deploy.sh <t>` como administrador |

Los clientes no pertenecen al grupo `docker` ni tienen kubeconfig. El enlace simbólico `~cliente-<t>/values.yaml` es solo comodidad.

### NetworkPolicy por tenant

`default-deny-ingress`, `allow-same-namespace`, `allow-ingress-controller` (namespace `ingress-nginx`) y `restrict-egress` (propio namespace, `kube-dns:53` e Internet salvo rangos privados y link-local).

## 3. Flujo de despliegue

1. El cliente edita su `values.yaml`.
2. Ejecuta `deploy.sh <tenant>` vía sudo (solo el de su tenant).
3. El script exige archivo regular, no enlace y menor de 64 KiB; lo copia a un temporal; valida `image` (tag o digest) y `domain` (debe ser el dominio base del tenant o un subdominio).
4. `docker pull` y `minikube image load`.
5. `helm upgrade --install --atomic --wait` con `plan` y `tenant` impuestos. El esquema JSON y `_helpers.tpl` rechazan réplicas por encima del máximo del plan.

### Variables de entorno

**Cómo se piden.** El `values.yaml` del cliente es el formulario: `env` para valores no sensibles y `secretEnv` para credenciales o tokens.

```yaml
env:
  APP_ENV: "production"
  DB_HOST: "db.ejemplo.com"
secretEnv:
  DB_PASSWORD: "cambiar-esto"
```

**Validación.** `values.schema.json` exige nombres con el patrón `^[A-Za-z_][A-Za-z0-9_]*$` y valores de tipo texto. `PORT: 3000` sin comillas se rechaza (`3000 is not of type 'string'`); debe ser `PORT: "3000"`. Igual con `true` y `false`.

**Cómo se aplican**
1. `configmap.yaml` genera `<appName>-env` con `env`; `secret.yaml` genera `<appName>-secret` con `secretEnv`.
2. `deployment.yaml` los inyecta con `envFrom` (`configMapRef` y `secretRef`). Si una clave está en ambos, gana `secretEnv` por declararse después.
3. Las anotaciones `checksum/env` y `checksum/secret` del pod cambian con el contenido. Editar el `values.yaml` y repetir `deploy.sh` reinicia los pods con los valores nuevos; sin ellas, los pods conservarían los anteriores, porque las variables se leen solo al arrancar el contenedor.

**Límites**
- `secretEnv` queda en texto plano en el `values.yaml` (0640, legible por el administrador) y en el historial del release de Helm (Secret `sh.helm.release.v1.*` del namespace del tenant). Mejora posible: que el administrador cree el Secret y el cliente solo indique su nombre.
- El chart no inyecta variables de plataforma como `PORT` (Render y Heroku sí); la aplicación debe escuchar en el `port` que declara el cliente.
- Comprobado con jsonschema y con el simulador de render: ConfigMap, Secret, `envFrom`, cambio de checksum al editar un valor y rechazo de valores sin comillas y de nombres inválidos. No probado en un clúster real.

## 4. Pasos a seguir

Ejecutar desde la raíz de `paas-lab/`, en el nodo Ubuntu de la guía HTML.

**Paso 1. Preparar el clúster.** NetworkPolicy exige un CNI que la aplique. Si el clúster no tiene Calico (`kubectl get pods -A | grep calico`), hay que recrearlo, lo que borra el stack de monitoreo.

```bash
minikube delete
minikube start --driver=docker --cpus=4 --memory=8192mb --cni=calico
minikube addons enable ingress
minikube addons enable metrics-server
# reinstalar kube-prometheus-stack con release "prometheus" (pasos 4 y 5 de la guía HTML)
echo "$(minikube ip) alpha.paas.local beta.paas.local" | sudo tee -a /etc/hosts
sudo apt install -y python3-yaml
```
Esperado: pods de Calico e `ingress-nginx` en `Running`; `kubectl top nodes` responde tras un minuto.

**Paso 2. Fase 1.**
```bash
kubectl apply -f admin/tenant-alpha.yaml -f admin/tenant-beta.yaml
kubectl get resourcequota,limitrange,networkpolicy -n tenant-alpha
kubectl get resourcequota,limitrange,networkpolicy -n tenant-beta
```
Esperado: en cada namespace 1 ResourceQuota, 1 LimitRange y 4 NetworkPolicy. El aviso de `last-applied-configuration` en namespaces ya existentes es normal.

**Paso 3. Alertas.**
```bash
kubectl apply -f admin/monitoring/alerts.yaml -f admin/monitoring/alert-sink.yaml
helm upgrade prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --reuse-values -f admin/monitoring/alertmanager-values.yaml
```
Esperado: el grupo `paas.tenant.quota` con 3 reglas en Prometheus (`:9090/rules`); `alert-sink` en `Running`.

**Paso 4. Permisos.**
```bash
sudo scripts/set-permissions.sh
ls -l /opt/paas/tenants/alpha
sudo -u cliente-beta cat /opt/paas/tenants/alpha/values.yaml     # debe fallar
sudo -u cliente-alpha touch /opt/paas/tenants/alpha/x            # debe fallar
sudo -u cliente-alpha docker ps                                  # debe fallar
```
Esperado: el cliente de otro tenant no lee el archivo, ningún cliente crea archivos en su directorio ni usa Docker.

**Paso 5. Despliegue.**
```bash
sudo -u cliente-alpha sudo -u "$USER" /opt/paas/scripts/deploy.sh alpha
sudo -u cliente-beta  sudo -u "$USER" /opt/paas/scripts/deploy.sh beta
kubectl get deploy,svc,ingress,hpa -n tenant-alpha
kubectl get deploy,svc,ingress,hpa,pvc -n tenant-beta
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: alpha.paas.local" http://$(minikube ip)/
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: beta.paas.local"  http://$(minikube ip)/
kubectl exec -n tenant-alpha deploy/mi-web-service -- env | grep APP_ENV
kubectl exec -n tenant-beta deploy/api-httpbin -- env | grep GUNICORN_CMD_ARGS
```
Esperado: Deployment, Service, Ingress y HPA en ambos tenants (más PVC en beta), `200` en los dos `curl` y las variables declaradas dentro de cada pod (`APP_ENV=production`). Pruebas de rechazo: `replicaCount: 20`, imagen sin tag, un dominio de otro tenant o un valor de `env` sin comillas (`PORT: 3000`) deben fallar con mensaje claro.

**Paso 6. Pruebas.**
```bash
tests/isolation.sh                     # 7 PASS
tests/quota.sh alpha; tests/quota.sh beta   # 2 PASS cada uno
tests/ratelimit.sh alpha.paas.local    # mezcla de 200 y 503
```
Si `ratelimit.sh` no obtiene 503, subir el segundo argumento (total de solicitudes) o probar contra `beta.paas.local` (10 rps).

Alertas:
```bash
KEEP=1 tests/quota.sh alpha
kubectl logs -n monitoring deploy/alert-sink --tail=20     # tras 2-3 minutos
kubectl -n tenant-alpha delete deploy quota-probe
kubectl -n tenant-alpha delete pvc -l paas/test=quota
```
Esperado: líneas `[/alpha] firing TenantQuotaExhausted ns=tenant-alpha resource=requests.cpu ...`.

**Paso 7. Evidencias para la entrega.** Salida de `kubectl describe resourcequota paas-quota -n tenant-<t>`, de `tests/*.sh`, los logs de `alert-sink` y el dashboard de Grafana `Kubernetes / Compute Resources / Namespace (Pods)` filtrado por `$namespace`.

**Paso 8. Cierre.** Integrar lo anterior en el PDF (sección 7) y limpiar con `helm uninstall <appName> -n tenant-<t>`.

## 5. Verificación

**Realizada**
- `kubeconform -strict`: 17 recursos válidos en `admin/` (la `PrometheusRule` se omitió por no tener esquema) y 5 + 6 recursos válidos en el render del chart para alpha y beta.
- `values.schema.json` es JSON Schema Draft 7 válido; acepta los values de ambos tenants y rechaza imagen sin tag y el plan `premium`.
- Render del chart con un simulador propio de `helm template` (Go, solo biblioteca estándar): `fail` esperado con `replicaCount: 9` y `autoscaling.maxReplicas: 6` en `basic` (máximo 5) y con un plan inexistente; `secretEnv` genera el Secret; sin HPA aparece `replicas`.
- `deploy.sh` con `docker`, `helm`, `kubectl` y `minikube` simulados: el caso válido pasa; tenant inválido, imagen sin tag, dominio ajeno, `values.yaml` como enlace simbólico e inyección en `image` se rechazan.
- `bash -n` en los 5 scripts.

**No realizada**
- Helm real: `get.helm.sh` y `proxy.golang.org` están bloqueados desde el entorno de trabajo. El simulador difiere de Helm en detalles como el formato de `toYaml`.
- Cualquier prueba en un clúster: Calico, rate limit del Ingress, HPA, PVC, alertas y los tres `tests/*.sh`.
- `scripts/set-permissions.sh`: crea usuarios y sudoers, nunca se ejecutó.
- `docker pull` y `minikube image load` reales; la existencia del tag `kennethreitz/httpbin:latest`.
- `shellcheck` no está disponible.

## 6. Riesgos y puntos a verificar

1. **Contexto de sudo.** `deploy.sh` corre como administrador vía `sudo -u`. Si `kubectl`, `helm` o `minikube` no encuentran el clúster, exportar `KUBECONFIG` y `MINIKUBE_HOME` del administrador al inicio del script.
2. **Nombres en alpha.** Si el Service o el Deployment manual de la reunión se llama igual que `appName`, `helm install` falla; borrarlo o cambiar `appName`.
3. **Rate limit.** `limit-rps` es por IP de origen, no por tenant, y responde 503. Solo aplica al tráfico que entra por el Ingress; el `wget` al Service de la Fase 3 del PDF lo evita.
4. **Capacidad.** Las cuotas suman 3 CPU de requests y no reservan capacidad; con el stack de monitoreo, un nodo de 4 CPU queda justo.
5. **Imagen de beta.** Sustituirla si el tag no existe o si el equipo prefiere otra aplicación (Node, Python propia).
6. **Pendiente con el docente.** Confirmar que el límite por IP en el Ingress satisface "número de peticiones" y que basta el camino por imagen.

## 7. Correcciones pendientes en la guía PDF

1. El Paso 1 empieza en "# 3. Definir LimitRanges": faltan el Namespace, la ResourceQuota y la NetworkPolicy.
2. `load-generator` usa `-n cliente-alpha`; debe ser `tenant-alpha`.
3. La query de cuota de CPU suma las series `hard` y `used` de `kube_resourcequota`; filtrar `type="hard"`.
4. El diagrama muestra 2 a 10 réplicas en alpha y el `values.yaml` usa `maxReplicas: 8`; unificar con los planes.
5. El HPA estándar solo escala por CPU o memoria vía Metrics Server; habilitar `metrics-server` y retirar la mención a "Ingress".
6. La guía HTML usa el dashboard 315 (etiquetas obsoletas); usar los dashboards incluidos en `kube-prometheus-stack`.
7. La rúbrica muestra porcentajes en la columna "Puntos" y hay una errata ("dinómicamente").
