{{- define "fyno.deployment" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceConfig := index .Values.services $serviceName -}}
{{- $serviceNameNormalized := $serviceName | replace "_" "-" -}}
{{- if eq $serviceConfig.enabled "true" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "fyno.labels" . | nindent 4 }}
    app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
spec:
  replicas: {{ $serviceConfig.replicas }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
      service: {{ $serviceName }}
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
        service: {{ $serviceName }}
        {{- include "fyno.labels" . | nindent 8 }}
    spec:
      {{- include "fyno.imagePullSecrets" . | nindent 6 }}
      {{- include "fyno.podSecurityContext" . | nindent 6 }}
      containers:
      - name: {{ .Release.Name }}-{{ $serviceNameNormalized }}
        image: {{ $serviceConfig.image }}
        imagePullPolicy: {{ .Values.imagePullPolicy }}
        {{- if $serviceConfig.npm_command }}
        command: ["npm", "run", "{{ $serviceConfig.npm_command }}"]
        {{- end }}
        {{- if $serviceConfig.normal_command }}
        command: {{ splitList " " $serviceConfig.normal_command | toJson }}
        {{- end }}

        {{- if $serviceConfig.ports }}
        {{- $ports := $serviceConfig.ports }}
        ports:
        {{- range $i, $p := $ports }}
        - name: http{{ if gt (len $ports) 1 }}-{{ $i }}{{ end }}
          containerPort: {{ $p }}
          protocol: TCP
        {{- end }}
        {{- end }}
        env:
        - name: APP_NAME
          value: {{ .Release.Name }}-{{ $serviceName }}-service
        {{- if $serviceConfig.env }}
        {{- range $key, $value := $serviceConfig.env }}
        - name: {{ $key }}
          value: {{ $value | quote }}
        {{- end }}
        {{- end }}
        envFrom:
        - configMapRef:
            name: {{ include "fyno.configMapName" (dict "serviceName" $serviceName "Release" .Release) }}
        - secretRef:
            name: {{ include "fyno.secretName" (dict "serviceName" $serviceName "Release" .Release) }}
        {{- include "fyno.containerSecurityContext" . | nindent 8 }}
        {{- if and $serviceConfig.resources (eq $serviceConfig.resources.enabled "true") }}
        resources:
          limits:
            cpu: {{ $serviceConfig.resources.limits.cpu }}
            memory: {{ $serviceConfig.resources.limits.memory }}
          requests:
            cpu: {{ $serviceConfig.resources.requests.cpu }}
            memory: {{ $serviceConfig.resources.requests.memory }}
        {{- end }}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        {{- if eq .Values.proxy.cert.enabled "true"}}
        - mountPath: /etc/ssl/{{.Values.proxy.cert.path }}
          name: {{.Values.proxy.cert.path }}
          readOnly: true
        {{- end}}
        {{- if eq .Values.TLS_END_TO_END.enabled "true"}}
        - name: enable-tls
          mountPath: /etc/ssl/tls
          readOnly: true
        {{- end}}
        {{- if and $serviceConfig.probe.enabled $serviceConfig.ports }}
        {{- if $serviceConfig.probe.liveness.enabled }}
        livenessProbe:
          tcpSocket:
            port: {{ index $serviceConfig.ports 0 }}
          initialDelaySeconds: {{ $serviceConfig.probe.liveness.initialDelaySeconds }}
          periodSeconds: {{ $serviceConfig.probe.liveness.periodSeconds }}
          timeoutSeconds: {{ $serviceConfig.probe.liveness.timeoutSeconds }}
          failureThreshold: {{ $serviceConfig.probe.liveness.failureThreshold }}
        {{- end }}
        {{- if $serviceConfig.probe.readiness.enabled }}
        readinessProbe:
          tcpSocket:
            port: {{ index $serviceConfig.ports 0 }}
          initialDelaySeconds: {{ $serviceConfig.probe.readiness.initialDelaySeconds }}
          periodSeconds: {{ $serviceConfig.probe.readiness.periodSeconds }}
          timeoutSeconds: {{ $serviceConfig.probe.readiness.timeoutSeconds }}
          failureThreshold: {{ $serviceConfig.probe.readiness.failureThreshold }}
        {{- end }}
        {{- end }}
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      terminationGracePeriodSeconds: 30
      volumes:
        {{- if eq .Values.proxy.cert.enabled "true"}}
        - configMap:
            defaultMode: 420
            name: {{ .Values.proxy.cert.path }}
          name: {{ .Values.proxy.cert.path }}
        {{- end }}
        {{- if eq .Values.TLS_END_TO_END.enabled "true"}}
        - name: enable-tls
          secret:
            secretName: {{ .Values.istio.secret_name }}
        {{- end}}
      {{- if and $serviceConfig.scheduling.nodeSelector.enabled $serviceConfig.scheduling.nodeSelector.labels }}
      nodeSelector:
        {{- toYaml $serviceConfig.scheduling.nodeSelector.labels | nindent 8 }}
      {{- end }}
      {{- if $serviceConfig.scheduling.affinity.enabled }}
      affinity:
        {{- if $serviceConfig.scheduling.affinity.config }}
        {{- toYaml $serviceConfig.scheduling.affinity.config | nindent 8 }}
        {{- else }}
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
              topologyKey: kubernetes.io/hostname
        {{- end }}
      {{- end }}
      {{- if and $serviceConfig.scheduling.tolerations.enabled $serviceConfig.scheduling.tolerations.items }}
      tolerations:
        {{- toYaml $serviceConfig.scheduling.tolerations.items | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}

