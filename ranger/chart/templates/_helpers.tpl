{{- define "ranger.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "ranger.fullname" -}}
{{- .Release.Name }}
{{- end }}

{{- define "ranger.labels" -}}
app.kubernetes.io/name: {{ include "ranger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{- define "ranger.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ranger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
