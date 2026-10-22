# PaaS multi-tenant sobre Kubernetes - Fases 1 a 4

```
admin/                 root:root. Fase 1: Namespace, ResourceQuota, LimitRange, NetworkPolicy por tenant
  monitoring/          Fases 3-4: alertas, enrutamiento, métricas del Ingress, Prometheus Adapter y tablero
  tenants.env          plan y dominio base por tenant (los fija el administrador)
paas-app-chart/        root:root. Fases 2-3: Deployment, Service, Ingress, HPA, ConfigMap/Secret, PVC
  plans.yaml           límites por plan (réplicas, recursos, solicitudes HTTP, objetivo del HPA)
  values.schema.json   validación de lo que el cliente puede escribir
tenants/<t>/values.yaml  ÚNICO archivo del cliente (dueño: cliente-<t>)
scripts/deploy.sh      valida, docker pull, minikube image load, helm upgrade --install
scripts/set-permissions.sh  instala en /opt/paas con usuarios, grupos y sudoers por tenant
tests/                 isolation.sh, quota.sh, ratelimit.sh, hpa.sh
```

## Decisiones

- **Solicitudes HTTP:** el límite va en el Ingress (`limit-rps`, `limit-connections`), no en el LimitRange. Lo define el plan, no el cliente. NGINX lo aplica por IP de origen y responde 503.
- **Autoescalado (Fase 3):** HPA v2 con dos métricas. CPU por Metrics Server (objetivo elegido por el cliente, 10-95 %) y peticiones/s del Ingress por Prometheus Adapter (objetivo fijado por el plan).
- **Observabilidad (Fase 4):** un tablero de Grafana con la variable `$namespace`, provisionado como ConfigMap con la etiqueta `grafana_dashboard=1`.
- **Alerta automática:** `PrometheusRule` (cuota >= 80 %, cuota agotada, HPA en su máximo). Alertmanager enruta por `namespace` al receptor de cada cliente.
- **Entrada de la aplicación:** solo imagen con tag explícito o digest. `deploy.sh` hace `docker pull` y `minikube image load`. El camino Dockerfile no se implementa.
- **Cliente:** `image`, `replicaCount`, `env`/`secretEnv`, `domain` (más `port`, `persistence`, `autoscaling`). `replicaCount` y `autoscaling.maxReplicas` no pueden superar el máximo del plan.
- **Plan y tenant:** los impone `deploy.sh` con `--set-string`; prevalecen sobre el archivo del cliente.

## Prerrequisitos

Con la guía HTML ya ejecutada (Minikube + `kube-prometheus-stack` con release `prometheus`):

```bash
# NetworkPolicy exige un CNI que la aplique. Si el clúster se creó sin --cni hay que recrearlo:
minikube delete
minikube start --driver=docker --cpus=4 --memory=8192mb --cni=calico
minikube addons enable ingress
minikube addons enable metrics-server
# (reinstalar kube-prometheus-stack tras recrear el clúster, pasos 4-5 de la guía HTML)
echo "$(minikube ip) alpha.paas.local beta.paas.local" | sudo tee -a /etc/hosts
sudo apt install -y python3-yaml
```

## Ejecución

```bash
kubectl apply -f admin/tenant-alpha.yaml -f admin/tenant-beta.yaml
kubectl apply -f admin/monitoring/alerts.yaml -f admin/monitoring/alert-sink.yaml
helm upgrade prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --reuse-values -f admin/monitoring/alertmanager-values.yaml

kubectl apply -f admin/monitoring/ingress-metrics.yaml
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter -n monitoring \
  -f admin/monitoring/prometheus-adapter-values.yaml --wait
kubectl apply -f admin/monitoring/tenants-dashboard.yaml

sudo scripts/set-permissions.sh     # copia el código a /opt/paas; repetir tras cada cambio
sudo -u cliente-alpha sudo -u "$USER" /opt/paas/scripts/deploy.sh alpha
sudo -u cliente-beta  sudo -u "$USER" /opt/paas/scripts/deploy.sh beta

tests/isolation.sh
tests/quota.sh alpha            # KEEP=1 para dejar la carga y ver las alertas
tests/quota.sh beta
tests/hpa.sh alpha              # autoescalado por peticiones del Ingress
tests/hpa.sh beta
tests/ratelimit.sh alpha.paas.local
kubectl logs -n monitoring deploy/alert-sink
```

## Verificación de las Fases 3 y 4

```bash
# Métrica personalizada disponible (AVAILABLE = True)
kubectl get apiservice v1beta1.custom.metrics.k8s.io

# El controlador expone métricas (port-forward en segundo plano)
kubectl -n ingress-nginx port-forward deploy/ingress-nginx-controller 10254:10254 &
curl -s localhost:10254/metrics | grep -m1 nginx_ingress_controller_requests

# HPA con las dos métricas (CPU y ingress_requests_per_second)
kubectl -n tenant-alpha get hpa
```

## Coherencia plan - cuota

`maxReplicas x requests.cpu + surge (25 %) x requests.cpu <= requests.cpu de la cuota`

| Tenant | Plan | Réplicas máx. | Request CPU | Pico con surge | Cuota CPU | Objetivo HPA (req/s por pod) |
|---|---|---|---|---|---|---|
| alpha | standard | 8 | 150m | 10 x 150m = 1.5 | 2 | 20 |
| beta | basic | 5 | 100m | 7 x 100m = 0.7 | 1 | 5 |

## Límites conocidos

- Si `alpha` ya tiene un Service o Deployment llamado como `appName`, `helm install` falla: elimínalo o cambia `appName`.
- El rate limit solo aplica al tráfico que entra por el Ingress. La prueba de carga de la guía (`wget` al Service interno) lo evita.
- `limit-rps` es por IP de origen, no por tenant completo.
- ARP es L2 y queda fuera de NetworkPolicy; `tests/isolation.sh` verifica ICMP y TCP.
- El nodo de Minikube (4 CPU) no cubre cuotas de 3 CPU más el stack de monitoreo sin margen; las cuotas no reservan capacidad.
- El HPA por Ingress ve solo el tráfico que cada origen puede enviar dentro de `limit-rps`. Desde una máquina llega a `ceil(rps / objetivo)` réplicas.
- La métrica excluye 5xx, así que los 503 del límite por IP no provocan escalado.
- Sin Prometheus Adapter, el HPA mantiene el escalado por CPU y muestra `<unknown>` en la métrica del Ingress.
- El tablero de Grafana es solo para el administrador. Los clientes no tienen acceso a él.

---

## Preguntas antes de cerrar

1. **Objetivos del HPA:** 5 req/s por pod en `basic` y 20 en `standard` son valores de laboratorio que elegí. ¿Los mantenemos o prefieres otros?
2. **Acceso de los clientes al tablero:** hoy solo lo ve el administrador. Si cada cliente debe ver su namespace, Grafana necesita organizaciones o equipos con permisos distintos. Lo dejaría para un bloque aparte.
3. **Métrica del HPA:** excluí los 5xx, incluidos los 503 del límite. ¿Lo confirmas o prefieres contar todas las respuestas?
4. **Desafío A (costos):** la guía HTML cobra $0.05 por CPU-hora y $0.01 por GB-hora de RAM. ¿Lo agrego como panel de Showback en este tablero? No estaba en la descripción de la Fase 4, así que no lo incluí.