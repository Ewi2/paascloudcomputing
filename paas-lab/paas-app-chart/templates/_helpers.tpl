{{/* Plan contratado: lee plans.yaml (parte del chart, no del archivo del cliente). */}}
{{- define "paas.plan" -}}
{{- $plans := .Files.Get "plans.yaml" | fromYaml -}}
{{- $p := get $plans .Values.plan -}}
{{- if not $p -}}
{{- fail (printf "plan desconocido: %s" .Values.plan) -}}
{{- end -}}
{{- toYaml $p -}}
{{- end -}}

{{/* Coherencia entre lo que pide el cliente y lo que permite su plan. */}}
{{- define "paas.validate" -}}
{{- $plan := include "paas.plan" . | fromYaml -}}
{{- $max := int $plan.maxReplicas -}}
{{- if gt (int .Values.replicaCount) $max -}}
{{- fail (printf "replicaCount=%d excede el máximo del plan '%s' (%d)" (int .Values.replicaCount) .Values.plan $max) -}}
{{- end -}}
{{- if .Values.autoscaling.enabled -}}
{{- if gt (int .Values.autoscaling.maxReplicas) $max -}}
{{- fail (printf "autoscaling.maxReplicas=%d excede el máximo del plan '%s' (%d)" (int .Values.autoscaling.maxReplicas) .Values.plan $max) -}}
{{- end -}}
{{- if lt (int .Values.autoscaling.maxReplicas) (int .Values.replicaCount) -}}
{{- fail "autoscaling.maxReplicas debe ser >= replicaCount" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "paas.selector" -}}
app.kubernetes.io/name: {{ .Values.appName }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "paas.labels" -}}
{{ include "paas.selector" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
paas/tenant: {{ .Values.tenant | default .Release.Namespace }}
{{- end -}}
