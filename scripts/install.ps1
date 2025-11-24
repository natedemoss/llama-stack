<#!
.SYNOPSIS
    Windows PowerShell installer for Llama Stack (Docker-based)
.DESCRIPTION
    Mirrors the functionality of scripts/install.sh for Windows hosts using Docker.
    Starts (optionally) a telemetry stack (Jaeger, OTEL Collector, Prometheus, Grafana),
    an Ollama container, then the Llama Stack distribution container.
.PARAMETER Port
    Port exposed for the Llama Stack API (default 8321)
.PARAMETER OllamaPort
    Port exposed for the Ollama container (default 11434)
.PARAMETER ModelAlias
    Model alias to pull inside the Ollama container (default "llama3.2:3b")
.PARAMETER Image
    Llama Stack distribution container image (default "docker.io/llamastack/distribution-starter:latest")
.PARAMETER Timeout
    Seconds to wait for each service to become healthy (default 30)
.PARAMETER NoTelemetry
    Skip provisioning telemetry stack when specified
.PARAMETER TelemetryServiceName
    Service name reported to OTEL (default "llama-stack")
.PARAMETER TelemetrySinks
    Comma-separated telemetry sinks (default "otel_trace,otel_metric")
.PARAMETER OtelEndpoint
    OTLP endpoint provided to Llama Stack (default "http://otel-collector:4318")
.EXAMPLE
    iwr -useb https://github.com/llamastack/llama-stack/raw/main/scripts/install.ps1 -OutFile install.ps1; powershell -ExecutionPolicy Bypass -File ./install.ps1
.EXAMPLE
    ./install.ps1 -Port 9000 -ModelAlias "llama3.2:11b" -NoTelemetry
.NOTES
    Report issues: https://github.com/llamastack/llama-stack/issues
#>
[CmdletBinding()]
param(
    [int]$Port = 8321,
    [int]$OllamaPort = 11434,
    [string]$ModelAlias = "llama3.2:3b",
    [string]$Image = "docker.io/llamastack/distribution-starter:latest",
    [int]$Timeout = 30,
    [switch]$NoTelemetry,
    [string]$TelemetryServiceName = "llama-stack",
    [string]$TelemetrySinks = "otel_trace,otel_metric",
    [string]$OtelEndpoint = "http://otel-collector:4318"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }
function Fail { param([string]$Message) Write-ErrorMsg $Message; Write-Host "Report an issue @ https://github.com/llamastack/llama-stack/issues if you think it's a bug" -ForegroundColor Red; exit 1 }

function Wait-ForService {
    param(
        [string]$Url,
        [string]$Pattern,
        [int]$TimeoutSeconds,
        [string]$Name
    )
    Write-Info "Waiting for $Name ..."
    $start = Get-Date
    while ($true) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
            if ($resp.Content -match $Pattern) { break }
        } catch { }
        $elapsed = (Get-Date) - $start
        if ($elapsed.TotalSeconds -ge $TimeoutSeconds) { return $false }
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    return $true
}

# Telemetry config materialization
function New-TelemetryConfigs {
    param([string]$Destination)
    if (Test-Path $Destination) { } else { New-Item -ItemType Directory -Path $Destination | Out-Null }

    $otel = @'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
  prometheus:
    endpoint: 0.0.0.0:9464
    namespace: llama_stack
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/jaeger, debug]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus, debug]
'@
    $prom = @'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector:9464']
'@
    $graf_ds = @'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    uid: prometheus
    isDefault: true
    editable: true
  - name: Jaeger
    type: jaeger
    access: proxy
    url: http://jaeger:16686
    editable: true
'@
    $graf_dash_cfg = @'
apiVersion: 1
providers:
  - name: 'Llama Stack'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
'@
    $dashboard = @'
{
  "annotations": {"list": []},
  "editable": true,
  "panels": [
    {"datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}, "id": 1, "targets": [{"expr": "llama_stack_completion_tokens_total", "legendFormat": "{{model_id}} ({{provider_id}})", "refId": "A"}], "title": "Completion Tokens", "type": "timeseries"}
  ],
  "refresh": "5s",
  "schemaVersion": 38,
  "title": "Llama Stack Metrics",
  "uid": "llama-stack-metrics"
}
'@
    Set-Content -Path (Join-Path $Destination 'otel-collector-config.yaml') -Value $otel -NoNewline
    Set-Content -Path (Join-Path $Destination 'prometheus.yml') -Value $prom -NoNewline
    Set-Content -Path (Join-Path $Destination 'grafana-datasources.yaml') -Value $graf_ds -NoNewline
    Set-Content -Path (Join-Path $Destination 'grafana-dashboards.yaml') -Value $graf_dash_cfg -NoNewline
    Set-Content -Path (Join-Path $Destination 'llama-stack-dashboard.json') -Value $dashboard -NoNewline
}

# Verify Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker is required. Install: https://docs.docker.com/get-docker/" }

$hostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$platformOpts = if ($hostArch -eq 'Arm64') { '--platform linux/amd64' } else { '' }

$withTelemetry = -not $NoTelemetry.IsPresent

# Clean existing containers
$containers = @('ollama-server','llama-stack')
if ($withTelemetry) { $containers += @('jaeger','otel-collector','prometheus','grafana') }
foreach ($c in $containers) {
    $ids = docker ps -aq --filter "name=^$c$"
    if ($ids) {
    Write-Info "Removing existing container(s): $c"
        docker rm -f $ids | Out-Null
    }
}

# Network
$netExists = docker network ls --format '{{.Name}}' | Select-String -SimpleMatch 'llama-net'
if (-not $netExists) {
    Write-Info 'Creating network llama-net'
    docker network create llama-net | Out-Null
}

# Telemetry stack
$telemetryTemp = $null
if ($withTelemetry) {
    Write-Info 'Starting telemetry stack'
    $telemetryTemp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("llama-telemetry-" + [System.Guid]::NewGuid().ToString('N'))) -Force
    New-TelemetryConfigs -Destination $telemetryTemp.FullName

    docker run -d $platformOpts --name jaeger --network llama-net -e COLLECTOR_ZIPKIN_HOST_PORT=:9411 -p 16686:16686 -p 14250:14250 -p 9411:9411 docker.io/jaegertracing/all-in-one:latest | Out-Null
    docker run -d $platformOpts --name otel-collector --network llama-net -p 4318:4318 -p 4317:4317 -p 9464:9464 -p 13133:13133 -v "${($telemetryTemp.FullName)}/otel-collector-config.yaml:/etc/otel-collector-config.yaml" docker.io/otel/opentelemetry-collector-contrib:latest --config /etc/otel-collector-config.yaml | Out-Null
    docker run -d $platformOpts --name prometheus --network llama-net -p 9090:9090 -v "${($telemetryTemp.FullName)}/prometheus.yml:/etc/prometheus/prometheus.yml" docker.io/prom/prometheus:latest --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --web.console.libraries=/etc/prometheus/console_libraries --web.console.templates=/etc/prometheus/consoles --storage.tsdb.retention.time=200h --web.enable-lifecycle | Out-Null
    docker run -d $platformOpts --name grafana --network llama-net -p 3000:3000 -e GF_SECURITY_ADMIN_PASSWORD=admin -e GF_USERS_ALLOW_SIGN_UP=false -v "${($telemetryTemp.FullName)}/grafana-datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml" -v "${($telemetryTemp.FullName)}/grafana-dashboards.yaml:/etc/grafana/provisioning/dashboards/dashboards.yaml" -v "${($telemetryTemp.FullName)}/llama-stack-dashboard.json:/etc/grafana/provisioning/dashboards/llama-stack-dashboard.json" docker.io/grafana/grafana:11.0.0 | Out-Null
}

# Ollama
Write-Info 'Starting Ollama'
docker run -d $platformOpts --name ollama-server --network llama-net -p "$OllamaPort:$OllamaPort" docker.io/ollama/ollama | Out-Null
if (-not (Wait-ForService -Url "http://localhost:$OllamaPort/" -Pattern 'Ollama' -TimeoutSeconds $Timeout -Name 'Ollama daemon')) {
    Write-ErrorMsg "Ollama did not become ready in $Timeout seconds"
    docker logs --tail 200 ollama-server
    Fail 'Ollama startup failed'
}
Write-Info "Pulling model $ModelAlias"
try {
    docker exec ollama-server ollama pull $ModelAlias | Out-Null
} catch {
    docker logs --tail 200 ollama-server
    Fail "Failed to pull model $ModelAlias"
}

# Llama Stack
Write-Info 'Starting Llama Stack'
$envArgs = @()
if ($withTelemetry) {
    $envArgs += @('-e',"TELEMETRY_SINKS=$TelemetrySinks",'-e',"OTEL_EXPORTER_OTLP_ENDPOINT=$OtelEndpoint",'-e',"OTEL_SERVICE_NAME=$TelemetryServiceName")
}
$cmd = @('run','-d')
if ($platformOpts) { $cmd += $platformOpts }
$cmd += @('--name','llama-stack','--network','llama-net','-p',"$Port:$Port")
$cmd += $envArgs
$cmd += @('-e',"OLLAMA_URL=http://ollama-server:$OllamaPort/v1",$Image,'--port',"$Port")

docker @cmd | Out-Null
if (-not (Wait-ForService -Url "http://127.0.0.1:$Port/v1/health" -Pattern 'OK' -TimeoutSeconds $Timeout -Name 'Llama Stack API')) {
    Write-ErrorMsg "Llama Stack did not become ready in $Timeout seconds"
    docker logs --tail 200 llama-stack
    Fail 'Llama Stack startup failed'
}

Write-Host ''
Write-Info 'Llama Stack is ready.'
Write-Info "API endpoint: http://localhost:$Port"
Write-Info 'Documentation: https://llamastack.github.io/latest/references/api_reference/index.html'
Write-Info 'Exec into the container: docker exec -ti llama-stack bash'
if ($withTelemetry) {
    Write-Info 'Telemetry dashboards:'
    Write-Info '   Jaeger UI:      http://localhost:16686'
    Write-Info '   Prometheus UI:  http://localhost:9090'
    Write-Info '   Grafana UI:     http://localhost:3000 (admin/admin)'
    Write-Info '   OTEL Collector: http://localhost:4318'
}
Write-Info 'Issues: https://github.com/llamastack/llama-stack/issues'

# Cleanup temp telemetry directory on exit (if created)
if ($telemetryTemp) {
    try { Remove-Item -Recurse -Force $telemetryTemp.FullName } catch { }
}
