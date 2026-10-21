# PaaS multi-tenant sobre Kubernetes - Fases 1 y 2

```
admin/                 root:root. Fase 1: Namespace, ResourceQuota, LimitRange, NetworkPolicy por tenant
  monitoring/          alertas (PrometheusRule), enrutamiento (Alertmanager) y receptor de prueba
  tenants.env          plan y dominio base por tenant (los fija el administrador)
paas-app-chart/        root:root. Fase 2: Deployment, Service, Ingress, HPA, ConfigMap/Secret, PVC
  plans.yaml           límites por plan (réplicas, recursos, solicitudes HTTP)
  values.schema.json   validación de lo que el cliente puede escribir
tenants/<t>/values.yaml  ÚNICO archivo del cliente (dueño: cliente-<t>)
scripts/deploy.sh      valida, docker pull, minikube image load, helm upgrade --install
scripts/set-permissions.sh  instala en /opt/paas con usuarios, grupos y sudoers por tenant
tests/                 isolation.sh, quota.sh, ratelimit.sh
```

## Decisiones

- **Solicitudes HTTP:** el límite va en el Ingress (`limit-rps`, `limit-connections`), no en el LimitRange. Lo define el plan, no el cliente. NGINX lo aplica por IP de origen y responde 503.
- **Alerta automática:** `PrometheusRule` (cuota >= 80 %, cuota agotada, HPA en su máximo) y Alertmanager enruta por `namespace` al receptor de cada cliente.
- **Entrada de la aplicación:** solo imagen con tag explícito o digest. `deploy.sh` hace `docker pull` y `minikube image load`. El camino Dockerfile no se implementa.
- **Cliente:** `image`, `replicaCount`, `env`/`secretEnv`, `domain` (más `port`, `persistence`, `autoscaling`). `replicaCount` y `autoscaling.maxReplicas` no pueden superar el máximo del plan.
- **Variables de entorno:** el cliente las declara en su `values.yaml`: `env` (no sensibles, ConfigMap) y `secretEnv` (sensibles, Secret). Los valores van siempre entre comillas. Cambiarlas y repetir `deploy.sh` reinicia los pods.
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

sudo scripts/set-permissions.sh
sudo -u cliente-alpha sudo -u "$USER" /opt/paas/scripts/deploy.sh alpha
sudo -u cliente-beta  sudo -u "$USER" /opt/paas/scripts/deploy.sh beta

tests/isolation.sh
tests/quota.sh alpha            # KEEP=1 para dejar la carga y ver las alertas
tests/ratelimit.sh alpha.paas.local
kubectl logs -n monitoring deploy/alert-sink
```

## Coherencia plan - cuota

`maxReplicas x requests.cpu + surge (25 %) x requests.cpu <= requests.cpu de la cuota`

| Tenant | Plan | Réplicas máx. | Request CPU | Pico con surge | Cuota CPU |
|---|---|---|---|---|---|
| alpha | standard | 8 | 150m | 10 x 150m = 1.5 | 2 |
| beta | basic | 5 | 100m | 7 x 100m = 0.7 | 1 |

En alpha sobran 0.5 CPU; el Deployment manual `app-cliente-alpha` (2 x 100m) usa 0.2.

## Límites conocidos

- Si `alpha` ya tiene un Service o Deployment llamado como `appName`, `helm install` falla: elimínalo o cambia `appName`.
- El rate limit solo aplica al tráfico que entra por el Ingress. La prueba de carga de la guía (`wget` al Service interno) lo evita.
- `limit-rps` es por IP de origen, no por tenant completo.
- ARP es L2 y queda fuera de NetworkPolicy; `tests/isolation.sh` verifica ICMP y TCP.
- Las cuotas suman 3 CPU de requests y no reservan capacidad: con el stack de monitoreo, un nodo de 4 CPU queda justo.
