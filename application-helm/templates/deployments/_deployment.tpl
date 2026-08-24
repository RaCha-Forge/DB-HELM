{{- define "fyno.deployment" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceConfig := index .Values.services $serviceName -}}
{{- $serviceNameNormalized := $serviceName | replace "_" "-" -}}
{{- $root := . -}}
{{- $workloadType := $serviceConfig.workloadType | default "Deployment" | lower -}}
{{- $trinoInitCommand := "cp -R /etc/trino/. /mnt/trino-config/ && mkdir -p /mnt/trino-data/var/run" -}}
{{- if eq $serviceName "trino" -}}
{{- $trinoInitCommand = "cp -R /etc/trino/. /mnt/trino-config/ && mkdir -p /mnt/trino-data/var/run /mnt/trino/data/metastore && test -w /mnt/trino/data/metastore && touch /mnt/trino/data/metastore/.trino-write-test && rm -f /mnt/trino/data/metastore/.trino-write-test" -}}
{{- end -}}
{{- if eq ($serviceConfig.enabled | toString | lower) "true" }}
apiVersion: apps/v1
kind: {{ if eq $workloadType "statefulset" }}StatefulSet{{ else }}Deployment{{ end }}
metadata:
  name: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "fyno.labels" . | nindent 4 }}
    app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
spec:
  replicas: {{ $serviceConfig.replicas }}
  {{- if eq $workloadType "statefulset" }}
  serviceName: {{ .Release.Name }}-{{ $serviceNameNormalized }}-svc
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
      service: {{ $serviceName }}
  {{- else }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
      service: {{ $serviceName }}
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  {{- end }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
        service: {{ $serviceName }}
        {{- include "fyno.labels" . | nindent 8 }}
    spec:
      {{- include "fyno.imagePullSecrets" . | nindent 6 }}
      {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      {{- else }}
      {{- include "fyno.podSecurityContext" . | nindent 6 }}
      {{- end }}
      {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
      initContainers:
      - name: prepare-trino-filesystem
        image: {{ $serviceConfig.image }}
        imagePullPolicy: {{ .Values.imagePullPolicy }}
        command:
        - /bin/sh
        - -c
        - {{ $trinoInitCommand | quote }}
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          readOnlyRootFilesystem: false
          capabilities:
            drop:
              - ALL
        volumeMounts:
        - name: trino-config
          mountPath: /mnt/trino-config
        - name: trino-data
          mountPath: /mnt/trino-data
        {{- if eq $serviceName "trino" }}
        - name: persistent-storage
          mountPath: /mnt/trino
        {{- end }}
      {{- end }}
      containers:
      - name: {{ .Release.Name }}-{{ $serviceNameNormalized }}
        image: {{ $serviceConfig.image }}
        imagePullPolicy: {{ .Values.imagePullPolicy }}
        {{- if $serviceConfig.npm_command }}
        command: ["npm", "run", "{{ $serviceConfig.npm_command }}"]
        {{- end }}
        {{- if $serviceConfig.command }}
        command: {{ toJson $serviceConfig.command }}
        {{- end }}
        {{- if $serviceConfig.args }}
        args: {{ toJson $serviceConfig.args }}
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
        {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
        - name: HOME
          value: /tmp
        {{- end }}
        {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
        - name: NODE_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        {{- end }}
        {{- if $serviceConfig.env }}
        {{- range $key, $value := $serviceConfig.env }}
        - name: {{ $key }}
          value: {{ tpl ($value | toString) $root | quote }}
        {{- end }}
        {{- end }}
        envFrom:
        - configMapRef:
            name: {{ include "fyno.configMapName" (dict "serviceName" $serviceName "Release" .Release) }}
        - secretRef:
            name: {{ include "fyno.secretName" (dict "serviceName" $serviceName "Release" .Release) }}
        {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          readOnlyRootFilesystem: false
          capabilities:
            drop:
              - ALL
        {{- else }}
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          readOnlyRootFilesystem: {{ $serviceConfig.readOnlyRootFilesystem | default false }}
          capabilities:
            drop:
              - ALL
        {{- end }}
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
        {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
        - name: trino-config
          mountPath: /etc/trino
        - name: trino-data
          mountPath: /data/trino
        {{- end }}
        {{- if and $serviceConfig.persistence (eq ($serviceConfig.persistence.enabled | toString | lower) "true") }}
        - name: persistent-storage
          mountPath: {{ $serviceConfig.persistence.mountPath | default "/data" }}
        {{- end }}
        {{- if $serviceConfig.tmpfs }}
        {{- range $tmpfs := $serviceConfig.tmpfs }}
        - name: {{ $tmpfs.name }}
          mountPath: {{ $tmpfs.mountPath }}
        {{- end }}
        {{- end }}
        {{- if $serviceConfig.scratch }}
        - name: scratch
          mountPath: /tmp
        {{- end }}
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
        {{- if or (eq $serviceName "trino") (eq $serviceName "trino_worker") }}
        - name: trino-config
          emptyDir: {}
        - name: trino-data
          emptyDir: {}
        {{- end }}
        {{- if and $serviceConfig.persistence (eq ($serviceConfig.persistence.enabled | toString | lower) "true") }}
        - name: persistent-storage
          persistentVolumeClaim:
            claimName: {{ if $serviceConfig.persistence.existingClaim }}{{ $serviceConfig.persistence.existingClaim }}{{ else }}{{ .Release.Name }}-{{ $serviceNameNormalized }}-pvc{{ end }}
        {{- end }}
        {{- if $serviceConfig.scratch }}
        - name: scratch
          emptyDir: {}
        {{- end }}
        {{- if $serviceConfig.tmpfs }}
        {{- range $tmpfs := $serviceConfig.tmpfs }}
        - name: {{ $tmpfs.name }}
          emptyDir:
            medium: Memory
            sizeLimit: {{ $tmpfs.sizeLimit }}
        {{- end }}
        {{- end }}
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

