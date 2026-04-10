{{- define "maas.namespace" -}}
{{ .Values.namespace | default "opendatahub" }}
{{- end }}

{{- define "maas.labels" -}}
app.kubernetes.io/part-of: models-as-a-service
app.kubernetes.io/managed-by: helm
{{- end }}

{{- define "maas.gateway.namespace" -}}
{{ .Values.gateway.namespace | default "istio-system" }}
{{- end }}

{{- define "maas.gateway.name" -}}
{{ .Values.gateway.name | default "maas-default-gateway" }}
{{- end }}

{{- define "maas.keycloak.namespace" -}}
{{ .Values.keycloak.namespace | default "keycloak" }}
{{- end }}

{{- define "maas.keycloak.issuerUrl" -}}
{{- if .Values.keycloak.issuerUrl -}}
{{ .Values.keycloak.issuerUrl }}
{{- else -}}
http://keycloak.{{ include "maas.keycloak.namespace" . }}.svc.cluster.local:8080/realms/{{ .Values.keycloak.realm | default "maas" }}
{{- end -}}
{{- end }}
