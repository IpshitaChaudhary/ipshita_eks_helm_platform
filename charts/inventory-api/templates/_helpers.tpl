{{/*
Chart name, truncated to the 63-char DNS label limit.
*/}}
{{- define "inventory-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart name, it is not repeated.
*/}}
{{- define "inventory-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "inventory-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Never change these after the first install: Deployment selectors are immutable.
*/}}
{{- define "inventory-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "inventory-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "inventory-api.labels" -}}
helm.sh/chart: {{ include "inventory-api.chart" . }}
{{ include "inventory-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "inventory-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "inventory-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Refuses "latest" so every rollout is traceable and rollback-able.
*/}}
{{- define "inventory-api.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString }}
{{- if eq $tag "latest" }}
{{- fail "image.tag must be an immutable tag (e.g. the commit SHA), not \"latest\"" }}
{{- end }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
