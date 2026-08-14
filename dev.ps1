#Requires -Version 5.1
<#
.SYNOPSIS
    Run the whole brain stack locally in Docker: web + mcp + worker +
    postgres + redis.

.DESCRIPTION
    Wraps `docker compose -f docker-compose.yml -f docker-compose.local.yml`;
    docker-compose.local.yml documents what the local override changes.

    The repo is bind-mounted into every app container, so a source edit is
    live immediately: the web container reloads itself (runserver), while
    mcp and worker need `dev.ps1 reload`. Only a dependency or Dockerfile
    change needs `dev.ps1 rebuild`.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'up',

    # Service names (reload/rebuild/logs/shell) or manage.py arguments.
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),

    # rebuild: ignore the layer cache.
    [switch]$NoCache,

    # down: also remove named volumes (pgdata - the local database).
    [switch]$Volumes,

    # css: rebuild on every template/app.css save instead of once.
    [switch]$Watch
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# App containers, in dependency order. postgres/redis are deliberately
# excluded - restarting a database is not "reload".
$AppServices = @('web', 'mcp', 'worker')

$Usage = @'
dev.ps1 - the brain stack (web + mcp + worker + postgres + redis) on Docker

  .\dev.ps1 [up]              build if needed, start everything, wait for health
  .\dev.ps1 reload [svc...]   restart app containers - picks up code, no rebuild
  .\dev.ps1 rebuild [-NoCache]  rebuild images and recreate containers
  .\dev.ps1 down [-Volumes]   stop and remove containers (-Volumes drops the DB)
  .\dev.ps1 logs [svc...]     follow logs
  .\dev.ps1 ps                container + health status
  .\dev.ps1 status            status plus a /readyz probe
  .\dev.ps1 shell [svc]       bash inside a container (default: web)
  .\dev.ps1 manage <args>     run manage.py in the web container
  .\dev.ps1 superuser         create a Django superuser
  .\dev.ps1 css [-Watch]      rebuild static/css/tw.css from app.css
  .\dev.ps1 help              this text

Code edits are live: web reloads itself, `reload` covers mcp + worker.
TEMPLATE edits also need `reload web`. Adding a Tailwind class to a
template needs `css` too - tw.css is a committed build artifact, not
something the container generates.

  .\dev.ps1 reload worker
  .\dev.ps1 manage rebuild_index
  .\dev.ps1 logs web mcp
  .\dev.ps1 css -Watch
'@

# ---------------------------------------------------------------- helpers ---

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Warn { param([string]$Text) Write-Host "!!  $Text" -ForegroundColor Yellow }
function Write-Fail { param([string]$Text) Write-Host "!!  $Text" -ForegroundColor Red }

function Get-DotEnvValue {
    param([string]$Key, [string]$Default = '')
    $value = $Default
    foreach ($name in @('.env', '.env.local')) {
        $envPath = Join-Path $Root $name
        if (-not (Test-Path $envPath)) { continue }
        foreach ($line in (Get-Content $envPath)) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('#')) { continue }
            if ($trimmed.StartsWith("$Key=")) {
                $value = $trimmed.Substring($Key.Length + 1).Trim().Trim('"').Trim("'")
            }
        }
    }
    return $value
}

function Initialize-Compose {
    # `docker compose` (v2 plugin) with a fallback to the standalone binary.
    $ErrorActionPreference = 'Continue'
    $null = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker isn't responding. Is Docker Desktop installed and running?"
    }

    $null = & docker compose version 2>$null
    if ($LASTEXITCODE -eq 0) {
        $script:ComposeExe = 'docker'
        $pre = @('compose')
    }
    else {
        $null = & docker-compose version 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Neither 'docker compose' nor 'docker-compose' works." }
        $script:ComposeExe = 'docker-compose'
        $pre = @()
    }

    $script:ComposeBase = $pre + @(
        '--project-name', 'brain-local',
        '--project-directory', $Root,
        '-f', (Join-Path $Root 'docker-compose.yml'),
        '-f', (Join-Path $Root 'docker-compose.local.yml')
    )
}

function Invoke-Compose {
    # Runs compose with its output going straight to the console.
    param([string[]]$Arguments, [switch]$AllowFailure)
    $exe = $script:ComposeExe
    $base = $script:ComposeBase
    & $exe @base @Arguments
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        throw "docker compose $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
}

function Get-ComposeOutput {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $exe = $script:ComposeExe
    $base = $script:ComposeBase
    return (& $exe @base @Arguments 2>$null)
}

function Initialize-InterpolationVars {
    # docker-compose.yml interpolates ${POSTGRES_PASSWORD:?...}; unset, compose
    # refuses to PARSE the file - so every command needs this, not just `up`.
    # A fixed local default keeps `up` a one-liner; export your own beforehand
    # to override it.
    if (-not $env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD = 'brain-local-dev' }
}

function Initialize-Environment {
    if (-not (Test-Path (Join-Path $Root '.env'))) {
        Write-Warn ".env is missing - containers fall back to built-in defaults."
    }

    # The clone, the materialized views and the generated-secrets state dir are
    # bind-mounted; when the host dir doesn't exist Docker creates it root-owned
    # and the app can't write to it.
    foreach ($dir in @('data\brain-repo', 'data\brain-views', 'data\state')) {
        $full = Join-Path $Root $dir
        if (-not (Test-Path $full)) { $null = New-Item -ItemType Directory -Force -Path $full }
    }
    $repoDir = Join-Path $Root 'data\brain-repo'
    if (-not (Get-ChildItem -Force -Path $repoDir | Select-Object -First 1)) {
        Write-Warn "data\brain-repo is empty - web will try to clone BRAIN_REPO_URL on boot."
    }

    # docker-compose.yml mounts the read-only deploy key as a FILE. When it's
    # missing Docker silently creates a directory there and git fails in a
    # confusing way. The local stack reads the bind-mounted clone and never
    # needs the key, so an empty placeholder is enough.
    $keyPath = Join-Path $Root 'secrets\brain_deploy_key'
    if (-not (Test-Path $keyPath)) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $keyPath)
        $null = New-Item -ItemType File -Force -Path $keyPath
        Write-Warn "secrets\brain_deploy_key was missing - created an empty placeholder."
    }

    # Same trap for the write PAT (approval pushes, M2.5): it mounts into
    # the worker as a FILE. Empty placeholder = pushes disabled, cleanly.
    $patPath = Join-Path $Root 'secrets\brain_write_pat'
    if (-not (Test-Path $patPath)) {
        $null = New-Item -ItemType File -Force -Path $patPath
        Write-Warn "secrets\brain_write_pat was missing - created an empty placeholder (paste the fine-grained write PAT into it to enable approval pushes)."
    }
}

function Wait-Healthy {
    param([int]$TimeoutSeconds = 300)
    $ErrorActionPreference = 'Continue'

    $containerId = (Get-ComposeOutput @('ps', '-q', 'web') | Select-Object -First 1)
    if (-not $containerId) { Write-Warn "web container not found - skipping health wait."; return $false }

    Write-Host -NoNewline "==> waiting for web to pass its healthcheck "
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = (& docker inspect --format '{{.State.Health.Status}}' $containerId 2>$null)
        if ($state -eq 'healthy') { Write-Host " healthy" -ForegroundColor Green; return $true }

        $running = (& docker inspect --format '{{.State.Running}}' $containerId 2>$null)
        if ($state -eq 'unhealthy' -or $running -eq 'false') {
            Write-Host ""
            Write-Fail "web is $state / running=$running. Last 40 log lines:"
            Invoke-Compose @('logs', '--tail', '40', 'web') -AllowFailure
            return $false
        }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    Write-Warn "web didn't report healthy within ${TimeoutSeconds}s - check .\dev.ps1 logs web"
    return $false
}

function Show-Readiness {
    # /readyz is the honest check: DB reachable AND the brain clone valid with
    # its contract files present. Probed from inside the container so no host
    # proxy quirk can muddy the answer.
    $raw = Get-ComposeOutput @('exec', '-T', 'web', 'curl', '-sS', '-m', '20', 'http://127.0.0.1:8000/readyz')
    $text = ($raw -join '').Trim()
    if (-not $text) { Write-Warn "/readyz returned nothing."; return }

    $ready = $null
    try { $ready = $text | ConvertFrom-Json } catch { Write-Warn "/readyz: $text"; return }

    if ($ready.status -eq 'ok') {
        Write-Host "==> /readyz ok - db reachable, brain clone valid (HEAD $($ready.brain.head))" -ForegroundColor Green
    }
    else {
        Write-Warn "/readyz reports NOT ready: $text"
        Write-Warn "Usually the brain clone - check data\brain-repo, then .\dev.ps1 manage brain_bootstrap"
    }
}

function Resolve-Services {
    param([string[]]$Requested)
    if ($Requested -and $Requested.Count -gt 0) { return $Requested }
    return $AppServices
}

function Show-Endpoints {
    $ops = (Get-DotEnvValue -Key 'ADMIN_PANEL_URL_PATH' -Default 'ops/').Trim('/')
    $adm = (Get-DotEnvValue -Key 'DJANGO_ADMIN_URL_PATH' -Default 'django-admin/').Trim('/')

    Write-Host ""
    Write-Host "  App        http://localhost:8000"
    Write-Host "  Ops UI     http://localhost:8000/$ops/"
    Write-Host "  Django     http://localhost:8000/$adm/"
    Write-Host "  Docs       http://localhost:8000/docs/"
    Write-Host "  MCP        http://localhost:8000/mcp   (container direct on :9002)"
    Write-Host "  Health     http://localhost:8000/healthz     Readiness /readyz"
    Write-Host "  Postgres   localhost:5433  db=brain user=brain password=$env:POSTGRES_PASSWORD"
    Write-Host "  Redis      localhost:6380"
    Write-Host ""
    Write-Host "  Code edits are live; web reloads itself." -ForegroundColor DarkGray
    Write-Host "  .\dev.ps1 reload   restart mcp + worker after a code change" -ForegroundColor DarkGray
    Write-Host "  .\dev.ps1 logs     follow logs         .\dev.ps1 down   stop" -ForegroundColor DarkGray
    Write-Host "  No login yet?  .\dev.ps1 superuser" -ForegroundColor DarkGray
}

# --------------------------------------------------------------- commands ---

Initialize-Compose
Initialize-InterpolationVars

switch ($Command.ToLowerInvariant()) {

    'up' {
        Initialize-Environment
        Write-Step "starting the stack (first run builds the image - a few minutes)"
        Invoke-Compose @('up', '-d', '--build', '--remove-orphans')
        if (Wait-Healthy) { Show-Readiness }
        Invoke-Compose @('ps') -AllowFailure
        Show-Endpoints
    }

    'reload' {
        $services = Resolve-Services $Rest
        Write-Step "restarting: $($services -join ', ')"
        Invoke-Compose (@('restart') + $services)
        if ($services -contains 'web') { $null = Wait-Healthy }
        Write-Host "==> reloaded" -ForegroundColor Green
    }

    'rebuild' {
        Initialize-Environment
        $buildArgs = @('build', '--pull')
        if ($NoCache) { $buildArgs += '--no-cache' }
        if ($Rest.Count -gt 0) { $buildArgs += $Rest }
        Write-Step "rebuilding images"
        Invoke-Compose $buildArgs
        Write-Step "recreating containers"
        Invoke-Compose @('up', '-d', '--force-recreate', '--remove-orphans')
        if (Wait-Healthy) { Show-Readiness }
        Show-Endpoints
    }

    'down' {
        $downArgs = @('down', '--remove-orphans')
        if ($Volumes) {
            Write-Warn "removing named volumes - the local Postgres database will be DELETED."
            $downArgs += '--volumes'
        }
        Write-Step "stopping the stack"
        Invoke-Compose $downArgs
        Write-Host "==> down" -ForegroundColor Green
    }

    'logs' {
        $logArgs = @('logs', '-f', '--tail', '100')
        if ($Rest.Count -gt 0) { $logArgs += $Rest }
        Invoke-Compose $logArgs -AllowFailure
    }

    'ps' {
        Invoke-Compose @('ps') -AllowFailure
    }

    'status' {
        Invoke-Compose @('ps') -AllowFailure
        Show-Readiness
    }

    'shell' {
        $svc = 'web'
        if ($Rest.Count -gt 0) { $svc = $Rest[0] }
        Invoke-Compose @('exec', $svc, 'bash') -AllowFailure
    }

    'manage' {
        if ($Rest.Count -eq 0) { Write-Fail "usage: .\dev.ps1 manage <command> [args]"; exit 1 }
        Invoke-Compose (@('exec', 'web', 'python', 'manage.py') + $Rest) -AllowFailure
    }

    'superuser' {
        Invoke-Compose @('exec', 'web', 'python', 'manage.py', 'createsuperuser') -AllowFailure
    }

    'css' {
        # Rebuild static/css/tw.css from assets/css/app.css with the
        # Tailwind v4 standalone binary. No Node, no node_modules: the
        # binary is cached in .cache/ (gitignored) and the OUTPUT is
        # committed, so Docker and self-hosters never need a toolchain.
        $twVersion = (Get-Content (Join-Path $Root 'scripts\tailwind-version.txt') -Raw).Trim()
        $asset = if ([Environment]::Is64BitOperatingSystem -and
                     [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
            'tailwindcss-windows-arm64.exe'
        } else {
            'tailwindcss-windows-x64.exe'
        }
        $cacheDir = Join-Path $Root '.cache'
        $bin = Join-Path $cacheDir "tailwindcss-$twVersion-$asset"

        if (-not (Test-Path $bin)) {
            New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            Write-Step "downloading tailwindcss $twVersion ($asset)"
            $url = "https://github.com/tailwindlabs/tailwindcss/releases/download/$twVersion/$asset"
            $prev = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # the progress bar makes this ~10x slower
            try {
                Invoke-WebRequest -Uri $url -OutFile $bin -UseBasicParsing
            } finally {
                $ProgressPreference = $prev
            }
        }

        $inFile = Join-Path $Root 'assets\css\app.css'
        $outFile = Join-Path $Root 'static\css\tw.css'
        $twArgs = @('-i', $inFile, '-o', $outFile, '--minify')
        if ($Rest -contains '-Watch' -or $Rest -contains '--watch' -or $Watch) {
            Write-Step "watching templates -> static/css/tw.css (Ctrl+C to stop)"
            $twArgs += '--watch'
        } else {
            Write-Step "building static/css/tw.css"
        }

        & $bin @twArgs
        if ($LASTEXITCODE -ne 0) { Write-Fail "tailwind build failed"; exit $LASTEXITCODE }

        if (-not ($twArgs -contains '--watch')) {
            $size = (Get-Item $outFile).Length
            Write-Host "    static/css/tw.css - $size bytes" -ForegroundColor Green
            Write-Warn "commit tw.css: the image ships the artifact, it is not built at deploy time."
        }
    }

    'help' { Write-Host $Usage }

    default {
        Write-Fail "unknown command '$Command'"
        Write-Host $Usage
        exit 1
    }
}
