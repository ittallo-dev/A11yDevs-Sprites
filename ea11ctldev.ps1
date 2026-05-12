[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'
$EA11CTL_FALLBACK_VERSION = '0.1.35'
$EA11CTL_OWNER = 'A11yDevs'
$EA11CTL_REPO = 'emacs-a11y-vm'
$EA11CTL_BRANCH = 'main'
$EA11CTL_RELEASE_BASE_URL = 'https://argmap.inf.ufg.br/a11ydevs'

function Write-EA11Info {
    param([string]$Message)
    Write-Host "[ea11ctl] $Message" -ForegroundColor Cyan
}

function Write-EA11Warn {
    param([string]$Message)
    Write-Host "[ea11ctl] $Message" -ForegroundColor Yellow
}

function Write-EA11Error {
    param([string]$Message)
    Write-Host "[ea11ctl] $Message" -ForegroundColor Red
}

function Show-Help {
    @"
ea11ctl - CLI do projeto emacs-a11y-vm [HOST - WINDOWS]

Uso:
  ea11ctl help|-h|--help
  ea11ctl version|--version [-c|--check-update]
  ea11ctl self-update|update [-f|--force]
  ea11ctl uninstall [--purge-state] [--yes] [--force-repo-path]
  
  ea11ctl vm install|-i
  ea11ctl vm list|-l
  ea11ctl vm start|-s [-n|--name VM] [-h|--headless]
  ea11ctl vm stop|-S [-n|--name VM] [-f|--force]
  ea11ctl vm close|-c [-n|--name VM]
  ea11ctl vm remove|-r|delete [-n|--name VM] [--data] [--system] [--all] [--force] [--yes]
  ea11ctl vm config [show|path|reset]
  ea11ctl vm optimize
  ea11ctl vm diagnose|-d [-n|--name VM] [-L|--lines N]
  ea11ctl vm status|-q [-n|--name VM]
  ea11ctl vm ssh|-x [-u|--user USER] [-p|--port PORT] [-- extra-args]

Nota: Dentro da VM (guest context), execute: ea11ctl share
"@
}

function Get-LocalCliVersion {
    $versionFile = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path $versionFile) {
        $v = (Get-Content -Path $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            return $v
        }
    }
    return $EA11CTL_FALLBACK_VERSION
}

function Get-RemoteCliVersion {
    $remoteVersionUrl = "https://raw.githubusercontent.com/$EA11CTL_OWNER/$EA11CTL_REPO/$EA11CTL_BRANCH/cli/VERSION"
    $content = Invoke-WebRequest -Uri $remoteVersionUrl -Headers (Get-GitHubRawHeaders) -UseBasicParsing
    return $content.Content.Trim()
}

function Get-GitHubApiHeaders {
    return @{
        'User-Agent' = "ea11ctl/$($EA11CTL_FALLBACK_VERSION)"
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'Cache-Control' = 'no-cache'
    }
}

function Get-GitHubRawHeaders {
    return @{
        'User-Agent' = "ea11ctl/$($EA11CTL_FALLBACK_VERSION)"
        'Cache-Control' = 'no-cache'
    }
}

function Get-TempDirectoryPath {
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        return $env:TEMP
    }

    $tmp = [System.IO.Path]::GetTempPath()
    if (-not [string]::IsNullOrWhiteSpace($tmp)) {
        return $tmp
    }

    throw 'Nao foi possivel determinar diretorio temporario para update.'
}

function Get-CacheBustValue {
    return [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
}

function Invoke-AccessibleDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Label = 'download',
        [int]$PercentStep = 5,
        [switch]$BeepOnProgress
    )

    if ($PercentStep -lt 1) {
        $PercentStep = 1
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    }
    catch {
        # Ignora plataformas onde o ajuste nao e suportado.
    }

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.UserAgent = "ea11ctl/$($EA11CTL_FALLBACK_VERSION)"
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    $response = $null
    $sourceStream = $null
    $targetStream = $null
    $progressId = 11
    $lastBeepPercent = -1

    try {
        $response = $request.GetResponse()
        $sourceStream = $response.GetResponseStream()
        $targetStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $contentLength = [int64]$response.ContentLength
        $buffer = New-Object byte[] (1024 * 1024)
        $downloadedBytes = [int64]0
        $nextPercent = $PercentStep
        $nextUnknownReportBytes = 50MB

        while ($true) {
            $bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) {
                break
            }

            $targetStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($contentLength -gt 0) {
                $percent = [int](($downloadedBytes * 100) / $contentLength)
                if ($percent -gt 100) {
                    $percent = 100
                }

                Write-Progress -Id $progressId -Activity "Baixando $Label..." -Status "$percent% concluido" -PercentComplete $percent

                if ($BeepOnProgress -and (Test-IsWindowsHost) -and $percent -gt $lastBeepPercent) {
                    $freq = 300 + ($percent * 10)
                    if ($freq -gt 2000) { $freq = 2000 }
                    try { [console]::Beep($freq, 40) } catch {}
                    $lastBeepPercent = $percent
                }

                if ($percent -ge $nextPercent) {
                    $doneMb = [math]::Round($downloadedBytes / 1MB, 1)
                    $totalMb = [math]::Round($contentLength / 1MB, 1)
                    Write-Host "[ea11ctl] Progresso ${Label}: $percent% ($doneMb/$totalMb MB)"

                    while ($percent -ge $nextPercent) {
                        $nextPercent += $PercentStep
                    }
                }
            }
            elseif ($downloadedBytes -ge $nextUnknownReportBytes) {
                $doneMb = [math]::Round($downloadedBytes / 1MB, 1)
                Write-Progress -Id $progressId -Activity "Baixando $Label..." -Status "$doneMb MB baixados"
                Write-Host "[ea11ctl] Progresso ${Label}: $doneMb MB baixados"
                if ($BeepOnProgress -and (Test-IsWindowsHost)) {
                    try { [console]::Beep(900, 70) } catch {}
                }
                $nextUnknownReportBytes += 50MB
            }
        }

        if ($contentLength -gt 0) {
            $doneMb = [math]::Round($downloadedBytes / 1MB, 1)
            $totalMb = [math]::Round($contentLength / 1MB, 1)
            Write-Progress -Id $progressId -Activity "Baixando $Label..." -Status '100% concluido' -PercentComplete 100 -Completed
            Write-Host "[ea11ctl] Progresso ${Label}: 100% ($doneMb/$totalMb MB)"
        }
        else {
            $doneMb = [math]::Round($downloadedBytes / 1MB, 1)
            Write-Progress -Id $progressId -Activity "Baixando $Label..." -Status 'Concluido' -Completed
            Write-Host "[ea11ctl] Download concluido ($doneMb MB): $Label"
        }

        if ($BeepOnProgress -and (Test-IsWindowsHost)) {
            try { [console]::Beep(1200, 300) } catch {}
        }
    }
    finally {
        Write-Progress -Id $progressId -Activity "Baixando $Label..." -Status 'Finalizado' -Completed -ErrorAction SilentlyContinue
        if ($targetStream) { $targetStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Download-FileWithFallback {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Ref,
        [string]$File,
        [string]$Destination,
        [int64]$CacheBust
    )

    $attempts = @(
        @{ Uri = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref/cli/$File?cb=$CacheBust"; Headers = (Get-GitHubRawHeaders); Label = 'raw+cb+headers' },
        @{ Uri = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref/cli/$File"; Headers = (Get-GitHubRawHeaders); Label = 'raw+headers' },
        @{ Uri = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref/cli/$File"; Headers = $null; Label = 'raw-sem-headers' },
        @{ Uri = "https://github.com/$Owner/$Repo/raw/$Ref/cli/$File"; Headers = $null; Label = 'github-raw-fallback' }
    )

    $lastErrorMessage = ''
    foreach ($attempt in $attempts) {
        try {
            Write-EA11Info "Download tentativa ($($attempt.Label)): $File"
            if ($null -ne $attempt.Headers) {
                Invoke-WebRequest -Uri $attempt.Uri -Headers $attempt.Headers -OutFile $Destination -UseBasicParsing
            }
            else {
                Invoke-WebRequest -Uri $attempt.Uri -OutFile $Destination -UseBasicParsing
            }

            return
        }
        catch {
            $lastErrorMessage = $_.Exception.Message
        }
    }

    throw "Falha ao baixar '$File' para ref '$Ref'. Ultimo erro: $lastErrorMessage"
}

function Get-RemoteBranchHeadSha {
    $apiUrl = "https://api.github.com/repos/$EA11CTL_OWNER/$EA11CTL_REPO/commits/$EA11CTL_BRANCH"
    $response = Invoke-WebRequest -Uri $apiUrl -Headers (Get-GitHubApiHeaders) -UseBasicParsing
    $json = $response.Content | ConvertFrom-Json

    if (-not $json -or -not $json.sha) {
        throw 'Resposta invalida da API do GitHub ao resolver SHA da branch.'
    }

    return ([string]$json.sha).Trim()
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')
    $maxLen = [Math]::Max($leftParts.Length, $rightParts.Length)

    for ($i = 0; $i -lt $maxLen; $i++) {
        $lv = 0
        $rv = 0
        if ($i -lt $leftParts.Length) {
            [void][int]::TryParse($leftParts[$i], [ref]$lv)
        }
        if ($i -lt $rightParts.Length) {
            [void][int]::TryParse($rightParts[$i], [ref]$rv)
        }

        if ($lv -gt $rv) { return 1 }
        if ($lv -lt $rv) { return -1 }
    }

    return 0
}

function Invoke-VersionCommand {
    param([string[]]$Tokens)

    $localVersion = Get-LocalCliVersion
    Write-Host "ea11ctl v$localVersion"

    if (-not (Has-Flag -Tokens $Tokens -Flags @('--check-update', '-c'))) {
        return
    }

    try {
        $remoteVersion = Get-RemoteCliVersion
        $cmp = Compare-SemVer -Left $remoteVersion -Right $localVersion
        if ($cmp -gt 0) {
            Write-EA11Info "Nova versao disponivel: $remoteVersion (local: $localVersion)"
            Write-Host 'Use: ea11ctl self-update' -ForegroundColor Green
        }
        elseif ($cmp -eq 0) {
            Write-EA11Info "Voce ja esta na versao mais recente ($localVersion)."
        }
        else {
            Write-EA11Info "Sua CLI local ($localVersion) esta a frente da remota ($remoteVersion)."
        }
    }
    catch {
        Write-EA11Warn "Nao foi possivel consultar versao remota: $($_.Exception.Message)"
    }
}

function Invoke-SelfUpdate {
    param([string[]]$Tokens)

    $force = Has-Flag -Tokens $Tokens -Flags @('--force', '-f')

    $localVersion = Get-LocalCliVersion
    if (-not $force) {
        try {
            $remoteVersion = Get-RemoteCliVersion
            $cmp = Compare-SemVer -Left $remoteVersion -Right $localVersion

            if ($cmp -eq 0) {
                Write-EA11Info "ea11ctl ja esta atualizado (v$localVersion)."
                return
            }

            if ($cmp -lt 0) {
                Write-EA11Info "ea11ctl local (v$localVersion) esta a frente do remoto (v$remoteVersion)."
                return
            }

            Write-EA11Info "Atualizando ea11ctl de v$localVersion para v$remoteVersion..."
        }
        catch {
            Write-EA11Warn "Nao foi possivel validar versao remota; prosseguindo com update."
        }
    }

    # Atualiza os arquivos diretamente no diretorio de instalacao,
    # sem depender do install.ps1 (evita quebra por mudanca de assinatura entre versoes).
    # Usa SHA do commit da branch para evitar inconsistencias de cache no raw/main.
    $installDir = $PSScriptRoot
    $resolvedRef = $EA11CTL_BRANCH
    try {
        $resolvedRef = Get-RemoteBranchHeadSha
        Write-EA11Info "Ref remoto resolvido para commit $resolvedRef"
    }
    catch {
        Write-EA11Warn "Nao foi possivel resolver SHA da branch; usando ref '$EA11CTL_BRANCH'."
    }

    $files = @('ea11ctl.ps1', 'ea11ctl.cmd', 'VERSION')

    $cacheBust = Get-CacheBustValue
    $refsToTry = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($resolvedRef)) {
        [void]$refsToTry.Add($resolvedRef)
    }
    if ($resolvedRef -ne $EA11CTL_BRANCH) {
        [void]$refsToTry.Add($EA11CTL_BRANCH)
    }

    $tmpDir = Join-Path (Get-TempDirectoryPath) ("ea11ctl-update-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $downloadOk = $false
    $lastErrorMessage = ''

    try {
        foreach ($ref in $refsToTry) {
            try {
                Write-EA11Info "Tentando download dos arquivos via ref '$ref'..."

                foreach ($file in $files) {
                    $dest = Join-Path $tmpDir $file
                    Write-EA11Info "Baixando $file..."
                    Download-FileWithFallback -Owner $EA11CTL_OWNER -Repo $EA11CTL_REPO -Ref $ref -File $file -Destination $dest -CacheBust $cacheBust
                }

                $downloadedVersion = (Get-Content -Path (Join-Path $tmpDir 'VERSION') -Raw -ErrorAction Stop).Trim()
                if ([string]::IsNullOrWhiteSpace($downloadedVersion)) {
                    throw 'Arquivo VERSION baixado vazio.'
                }

                $downloadOk = $true
                break
            }
            catch {
                $lastErrorMessage = $_.Exception.Message
                Write-EA11Warn "Falha no download via ref '$ref': $lastErrorMessage"
            }
        }

        if (-not $downloadOk) {
            throw "Nao foi possivel baixar arquivos de update. Ultimo erro: $lastErrorMessage"
        }

        foreach ($file in $files) {
            Copy-Item -Path (Join-Path $tmpDir $file) -Destination (Join-Path $installDir $file) -Force
        }
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $newVersion = (Get-Content -Path (Join-Path $installDir 'VERSION') -Raw -ErrorAction SilentlyContinue).Trim()
    Write-Host "ea11ctl atualizado para v$newVersion" -ForegroundColor Green
}

function Assert-Command {
    param([string]$Command)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Comando '$Command' nao encontrado no PATH."
    }
}

function Ensure-CommandWithCandidates {
    param(
        [string]$Command,
        [string[]]$Candidates,
        [string]$Hint
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        return
    }

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (Test-Path $candidate) {
            $dir = Split-Path -Path $candidate -Parent
            if (-not [string]::IsNullOrWhiteSpace($dir)) {
                $env:PATH = "$dir;$env:PATH"
            }

            break
        }
    }

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Comando '$Command' nao encontrado no PATH. $Hint"
    }
}

function Get-OptionValue {
    param(
        [string[]]$Tokens,
        [string[]]$Names,
        [string]$Default
    )

    for ($i = 0; $i -lt $Tokens.Length; $i++) {
        foreach ($name in $Names) {
            if ($Tokens[$i] -eq $name -and ($i + 1) -lt $Tokens.Length) {
                return $Tokens[$i + 1]
            }
        }
    }

    return $Default
}

function Has-Flag {
    param(
        [string[]]$Tokens,
        [string[]]$Flags
    )

    foreach ($token in $Tokens) {
        foreach ($flag in $Flags) {
            if ($token -eq $flag) {
                return $true
            }
        }
    }

    return $false
}

function Has-OptionName {
    param(
        [string[]]$Tokens,
        [string[]]$Names
    )

    foreach ($token in $Tokens) {
        foreach ($name in $Names) {
            if ($token -eq $name) {
                return $true
            }
        }
    }

    return $false
}

function Get-IntOptionValue {
    param(
        [string[]]$Tokens,
        [string[]]$Names,
        [int]$Default,
        [string]$OptionName
    )

    $raw = Get-OptionValue -Tokens $Tokens -Names $Names -Default ([string]$Default)
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value)) {
        throw ("Valor invalido para {0}: {1}" -f $OptionName, $raw)
    }

    return $value
}

function Assert-NoBackendOption {
    param([string[]]$Tokens)

    for ($i = 0; $i -lt $Tokens.Length; $i++) {
        $token = $Tokens[$i]
        if ($token -in @('--backend', '-b', '--qemu', '--virtualbox')) {
            throw 'A opcao de backend foi removida. A CLI agora e QEMU-only.'
        }
    }
}

function Get-HomeDirectoryPath {
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        return $env:HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return $env:USERPROFILE
    }

    throw "Nao foi possivel detectar o diretorio HOME do usuario."
}

function Get-EA11StateDirectory {
    $base = Join-Path (Get-HomeDirectoryPath) '.emacs-a11y-vm'
    if (-not (Test-Path $base)) {
        New-Item -ItemType Directory -Path $base -Force | Out-Null
    }

    return $base
}

function Get-QemuStateDirectory {
    $stateDir = Join-Path (Get-EA11StateDirectory) 'qemu'
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    return $stateDir
}

function Get-QemuStateFilePath {
    param([string]$VMName)

    return (Join-Path (Get-QemuStateDirectory) "$VMName.json")
}

function Get-QemuRuntimeConfigPath {
    return (Join-Path (Get-QemuStateDirectory) 'config.json')
}

function Get-DefaultQemuRuntimeConfig {
    $isWindowsHost = Test-IsWindowsHost
    $isMacHost = Test-IsMacOSHost

    $accel = 'tcg'
    $cpuModel = 'host'

    if ($isMacHost) {
        $accel = 'hvf'
        $cpuModel = 'host'
    }
    elseif ($isWindowsHost) {
        $accel = 'whpx'
        $cpuModel = 'qemu64'
    }
    else {
        if (Test-Path '/dev/kvm') {
            $accel = 'kvm'
            $cpuModel = 'host'
        }
        else {
            $accel = 'tcg'
            $cpuModel = 'qemu64'
        }
    }

    return @{
        accel = $accel
        cpuModel = $cpuModel
        cpus = 4
        memoryMb = 4096
        netDevice = 'virtio-net-pci'
        diskInterface = 'virtio'
        diskCache = 'writeback'
        diskDiscard = 'unmap'
        videoDevice = 'virtio-vga'
    }
}

function Merge-QemuRuntimeConfig {
    param(
        [hashtable]$Base,
        [object]$Override
    )

    if (-not $Override) {
        return $Base
    }

    $merged = @{}
    foreach ($k in $Base.Keys) {
        $merged[$k] = $Base[$k]
    }

    foreach ($prop in $Override.PSObject.Properties) {
        if ($null -ne $prop.Value -and $merged.ContainsKey($prop.Name)) {
            $merged[$prop.Name] = $prop.Value
        }
    }

    return $merged
}

function Get-QemuRuntimeConfig {
    $defaults = Get-DefaultQemuRuntimeConfig
    $cfgPath = Get-QemuRuntimeConfigPath

    if (-not (Test-Path $cfgPath)) {
        return $defaults
    }

    try {
        $raw = Get-Content -Path $cfgPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $defaults
        }

        $parsed = $raw | ConvertFrom-Json
        return (Merge-QemuRuntimeConfig -Base $defaults -Override $parsed)
    }
    catch {
        Write-EA11Warn "Falha ao ler config runtime em $cfgPath. Usando defaults."
        return $defaults
    }
}

function Save-QemuRuntimeConfig {
    param([hashtable]$Config)

    $cfgPath = Get-QemuRuntimeConfigPath
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding utf8
}

function Show-QemuRuntimeConfig {
    $cfgPath = Get-QemuRuntimeConfigPath
    $cfg = Get-QemuRuntimeConfig

    Write-Host "config_file=$cfgPath"
    Write-Host "QEMU_ACCEL=$($cfg.accel)"
    Write-Host "QEMU_CPU_MODEL=$($cfg.cpuModel)"
    Write-Host "QEMU_CPUS=$($cfg.cpus)"
    Write-Host "QEMU_MEMORY_MB=$($cfg.memoryMb)"
    Write-Host "QEMU_NET_DEVICE=$($cfg.netDevice)"
    Write-Host "QEMU_DISK_IF=$($cfg.diskInterface)"
    Write-Host "QEMU_DISK_CACHE=$($cfg.diskCache)"
    Write-Host "QEMU_DISK_DISCARD=$($cfg.diskDiscard)"
    Write-Host "QEMU_VIDEO_DEVICE=$($cfg.videoDevice)"
}

function Invoke-QemuVMConfig {
    param([string[]]$Tokens)

    $action = 'show'
    if ($Tokens.Length -gt 0 -and -not [string]::IsNullOrWhiteSpace($Tokens[0])) {
        $action = $Tokens[0].ToLowerInvariant()
    }

    switch ($action) {
        'show' { Show-QemuRuntimeConfig }
        'list' { Show-QemuRuntimeConfig }
        'path' { Write-Host (Get-QemuRuntimeConfigPath) }
        'reset' {
            Save-QemuRuntimeConfig -Config (Get-DefaultQemuRuntimeConfig)
            Write-EA11Info "Configuracao resetada para defaults em $(Get-QemuRuntimeConfigPath)"
        }
        default {
            throw "Acao de config desconhecida: $action"
        }
    }
}

function Invoke-QemuVMOptimize {
    $cfgPath = Get-QemuRuntimeConfigPath
    if (Test-Path $cfgPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$cfgPath.bak-$stamp"
        Copy-Item -Path $cfgPath -Destination $backupPath -Force
        Write-EA11Info "Backup da configuracao atual: $backupPath"
    }

    Save-QemuRuntimeConfig -Config (Get-DefaultQemuRuntimeConfig)
    Write-EA11Info "Configuracao otimizada aplicada em $cfgPath"
    Write-EA11Info 'Use: ea11ctl vm config show'
    Write-EA11Info 'Se houver regressao, restaure o backup ou execute: ea11ctl vm config reset'
}

function Load-QemuState {
    param([string]$VMName)

    $filePath = Get-QemuStateFilePath -VMName $VMName
    if (-not (Test-Path $filePath)) {
        return $null
    }

    $raw = Get-Content -Path $filePath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Save-QemuState {
    param(
        [string]$VMName,
        [hashtable]$State
    )

    $filePath = Get-QemuStateFilePath -VMName $VMName
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $filePath -Encoding utf8
}

function Get-ProcessByIdSafe {
    param([int]$ProcessId)

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Ensure-QemuSystem {
    $candidates = @(
        "$env:ProgramFiles\qemu\qemu-system-x86_64w.exe",
        "${env:ProgramFiles(x86)}\qemu\qemu-system-x86_64w.exe",
        "$env:ProgramFiles\qemu\qemu-system-x86_64.exe",
        "${env:ProgramFiles(x86)}\qemu\qemu-system-x86_64.exe",
        "$env:ChocolateyInstall\bin\qemu-system-x86_64.exe",
        "$env:USERPROFILE\scoop\apps\qemu\current\qemu-system-x86_64.exe",
        '/opt/homebrew/bin/qemu-system-x86_64',
        '/usr/local/bin/qemu-system-x86_64',
        '/usr/bin/qemu-system-x86_64'
    )

    Ensure-CommandWithCandidates -Command 'qemu-system-x86_64' -Candidates $candidates -Hint "Instale o QEMU e garanta qemu-system-x86_64 no PATH."
}

function Resolve-QemuSystemExecutable {
    param([bool]$Headless)

    if ((Test-IsWindowsHost) -and (-not $Headless)) {
        $guiCandidates = @(
            "$env:ProgramFiles\qemu\qemu-system-x86_64w.exe",
            "${env:ProgramFiles(x86)}\qemu\qemu-system-x86_64w.exe",
            "$env:ChocolateyInstall\bin\qemu-system-x86_64w.exe",
            "$env:USERPROFILE\scoop\apps\qemu\current\qemu-system-x86_64w.exe"
        )

        $cmd = Get-Command 'qemu-system-x86_64w.exe' -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }

        foreach ($candidate in $guiCandidates) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
                return $candidate
            }
        }
    }

    $normalCmd = Get-Command 'qemu-system-x86_64' -ErrorAction SilentlyContinue
    if ($normalCmd) {
        return $normalCmd.Source
    }

    return 'qemu-system-x86_64'
}

function Resolve-HostUserName {
    if (-not [string]::IsNullOrWhiteSpace($env:USER)) {
        return $env:USER
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return $env:USERNAME
    }

    return $null
}

function Get-QemuHostHomeShareConfig {
    $hostUser = Resolve-HostUserName
    if ([string]::IsNullOrWhiteSpace($hostUser)) {
        return $null
    }

    $candidatePaths = @(
        "/Users/$hostUser",
        "/home/$hostUser"
    )

    $hostPath = $null
    foreach ($candidate in $candidatePaths) {
        if (Test-Path $candidate) {
            $hostPath = $candidate
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($hostPath)) {
        return $null
    }

    $safeUser = ($hostUser -replace '[^a-zA-Z0-9_-]', '_')
    return @{
        HostUser = $hostUser
        HostPath = $hostPath
        MountTag = "hosthome_$safeUser"
        GuestMountPoint = "/home/$hostUser"
    }
}

function Get-QemuAvailableAudioDrivers {
    param([string]$QemuExecutable)

    try {
        $output = & $QemuExecutable -audiodev help 2>&1
    }
    catch {
        return @()
    }

    if (-not $output) {
        return @()
    }

    $drivers = New-Object System.Collections.Generic.List[string]
    $capture = $false

    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match 'Available audio drivers') {
            $capture = $true
            continue
        }

        if (-not $capture) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        foreach ($token in ($text -split '\s+')) {
            if ([string]::IsNullOrWhiteSpace($token)) {
                continue
            }

            $normalized = $token.Trim().ToLowerInvariant()
            if (-not $drivers.Contains($normalized)) {
                [void]$drivers.Add($normalized)
            }
        }
    }

    return $drivers.ToArray()
}

function Test-QemuVirtfsSupport {
    param([string]$QemuExecutable)

    try {
        $helpOutput = & $QemuExecutable -help 2>&1
    }
    catch {
        return $false
    }

    if (-not $helpOutput) {
        return $false
    }

    $text = ($helpOutput | Out-String)
    if (-not ($text -match '(?i)\-virtfs|virtfs')) {
        return $false
    }

    # Alguns builds listam -virtfs no help, mas desabilitam o recurso em runtime.
    # Fazemos um probe real com uma execucao minima para confirmar suporte efetivo.
    try {
        $probeOut = & $QemuExecutable -S -machine none -nodefaults -nographic -virtfs 'local,path=.,mount_tag=ea11probe,security_model=none,id=ea11probe' 2>&1
        $probeText = ($probeOut | Out-String)

        if ($probeText -match '(?i)virtfs support is disabled|there is no option group virtfs') {
            return $false
        }

        # Se nao retornou mensagens de desabilitado, consideramos suportado.
        return $true
    }
    catch {
        $errText = $_.Exception.Message
        if ($errText -match '(?i)virtfs support is disabled|there is no option group virtfs') {
            return $false
        }

        # Erros nao relacionados ao virtfs nao invalidam necessariamente o suporte.
        return $true
    }
}

function Get-QemuUserNetSmbSupportInfo {
    param([string]$QemuExecutable)

    $result = @{
        Supported = $false
        Reason = 'unknown'
    }

    try {
        $helpOutput = & $QemuExecutable -help 2>&1
    }
    catch {
        $result.Reason = 'qemu-help-failed'
        return $result
    }

    if (-not $helpOutput) {
        $result.Reason = 'qemu-help-empty'
        return $result
    }

    $text = ($helpOutput | Out-String)
    $helpHintsSmb = ($text -match '(?i)smb=|\-nic\s+user')

    # O help pode nao refletir corretamente alguns builds; validar em runtime.
    try {
        $probeOut = & $QemuExecutable -S -machine none -nodefaults -nographic -netdev 'user,id=ea11probe,smb=.' 2>&1
        $probeText = ($probeOut | Out-String)

        if ($probeText -match '(?i)invalid\s+parameter.*smb|unexpected.*smb|unknown\s+parameter.*smb|there is no option group .*smb') {
            $result.Reason = 'unsupported'
            return $result
        }

        if ($probeText -match '(?i)could not find .*smbd|smbd.*not found|failed to start smb') {
            $result.Reason = 'missing-host-smb-helper'
            return $result
        }

        $result.Supported = $true
        $result.Reason = 'supported'
        return $result
    }
    catch {
        $errText = $_.Exception.Message

        if ($errText -match '(?i)invalid\s+parameter.*smb|unexpected.*smb|unknown\s+parameter.*smb|there is no option group .*smb') {
            $result.Reason = 'unsupported'
            return $result
        }

        if ($errText -match '(?i)could not find .*smbd|smbd.*not found|failed to start smb') {
            $result.Reason = 'missing-host-smb-helper'
            return $result
        }

        if ($helpHintsSmb) {
            $result.Supported = $true
            $result.Reason = 'supported-by-help'
            return $result
        }

        $result.Reason = 'unsupported'
        return $result
    }
}

function New-QemuBaseArgs {
    param(
        [int]$Memory,
        [int]$Cpus,
        [string]$SystemDisk,
        [string]$UserDataDisk,
        [string]$NetdevValue,
        [string]$NetDevice,
        [string]$DiskInterface,
        [string]$DiskCache,
        [string]$DiskDiscard,
        [string]$VideoDevice,
        [hashtable]$HostHomeShare,
        [string]$HostHomeShareMode,
        [string]$HostUser,
        [string]$HostSmbServer,
        [string]$HostSmbShare,
        [string]$HostSmbUser,
        [string]$HostSmbPassword
    )

    $systemDiskArg = $SystemDisk
    $userDataDiskArg = $UserDataDisk
    if (-not [string]::IsNullOrWhiteSpace($systemDiskArg)) {
        $escapedSystemDisk = $systemDiskArg.Replace('"', '\"')
        $systemDiskArg = '"' + $escapedSystemDisk + '"'
    }
    if (-not [string]::IsNullOrWhiteSpace($userDataDiskArg)) {
        $escapedUserDataDisk = $userDataDiskArg.Replace('"', '\"')
        $userDataDiskArg = '"' + $escapedUserDataDisk + '"'
    }

    $args = @(
        '-m', "$Memory",
        '-smp', "$Cpus",
        '-drive', "file=$systemDiskArg,format=qcow2,if=$DiskInterface,cache=$DiskCache,discard=$DiskDiscard",
        '-drive', "file=$userDataDiskArg,format=qcow2,if=$DiskInterface,cache=$DiskCache,discard=$DiskDiscard",
        '-netdev', $NetdevValue,
        '-device', "$NetDevice,netdev=net0",
        '-serial', 'none',
        '-monitor', 'none'
    )

    if (-not [string]::IsNullOrWhiteSpace($VideoDevice)) {
        $args += @('-device', $VideoDevice)
    }

    if (($HostHomeShareMode -eq '9p') -and $HostHomeShare) {
        $hostHomePathArg = [string]$HostHomeShare.HostPath
        if (-not [string]::IsNullOrWhiteSpace($hostHomePathArg)) {
            $escapedHostHomePath = $hostHomePathArg.Replace('"', '\"')
            $hostHomePathArg = '"' + $escapedHostHomePath + '"'
        }
        $args += @(
            '-virtfs',
            "local,path=$hostHomePathArg,mount_tag=$($HostHomeShare.MountTag),security_model=none,id=$($HostHomeShare.MountTag)"
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($HostUser)) {
        $args += @('-fw_cfg', "name=opt/ea11/host_user,string=$HostUser")
    }

    if (-not [string]::IsNullOrWhiteSpace($HostSmbServer)) {
        $args += @('-fw_cfg', "name=opt/ea11/smb_server,string=$HostSmbServer")
    }
    if (-not [string]::IsNullOrWhiteSpace($HostSmbShare)) {
        $args += @('-fw_cfg', "name=opt/ea11/smb_share,string=$HostSmbShare")
    }
    if (-not [string]::IsNullOrWhiteSpace($HostSmbUser)) {
        $args += @('-fw_cfg', "name=opt/ea11/smb_user,string=$HostSmbUser")
    }
    if (-not [string]::IsNullOrWhiteSpace($HostSmbPassword)) {
        $args += @('-fw_cfg', "name=opt/ea11/smb_password,string=$HostSmbPassword")
    }

    return $args
}

function Ensure-QemuImg {
    $candidates = @(
        "$env:ProgramFiles\qemu\qemu-img.exe",
        "${env:ProgramFiles(x86)}\qemu\qemu-img.exe",
        "$env:ChocolateyInstall\bin\qemu-img.exe",
        "$env:USERPROFILE\scoop\apps\qemu\current\qemu-img.exe",
        '/opt/homebrew/bin/qemu-img',
        '/usr/local/bin/qemu-img',
        '/usr/bin/qemu-img'
    )

    Ensure-CommandWithCandidates -Command 'qemu-img' -Candidates $candidates -Hint "Instale o QEMU e garanta qemu-img no PATH."
}

function Test-IsWindowsHost {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [bool]$IsWindows
    }

    return ($env:OS -eq 'Windows_NT')
}

function Test-IsMacOSHost {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [bool]$IsMacOS
    }

    return $false
}

function Get-QemuAccelerationArgs {
    param(
        [string]$Mode = 'auto',
        [string]$CpuModel = 'qemu64'
    )

    $normalizedMode = $Mode.ToLowerInvariant()

    if ($normalizedMode -eq 'kvm') {
        return @('-enable-kvm', '-cpu', $CpuModel)
    }

    if ($normalizedMode -eq 'tcg') {
        return @('-accel', 'tcg,thread=multi', '-cpu', $CpuModel)
    }

    if ($normalizedMode -in @('hvf', 'whpx')) {
        if ((Test-IsMacOSHost) -and ($CpuModel -eq 'host')) {
            return @('-accel', $normalizedMode, '-accel', 'tcg,thread=multi', '-cpu', 'host,-svm')
        }
        return @('-accel', $normalizedMode, '-accel', 'tcg,thread=multi', '-cpu', $CpuModel)
    }

    if (Test-IsMacOSHost) {
        if ($CpuModel -eq 'host') {
            return @('-accel', 'hvf', '-accel', 'tcg,thread=multi', '-cpu', 'host,-svm')
        }
        return @('-accel', 'hvf', '-accel', 'tcg,thread=multi', '-cpu', $CpuModel)
    }

    if (Test-IsWindowsHost) {
        return @('-accel', 'whpx', '-accel', 'tcg,thread=multi', '-cpu', $CpuModel)
    }

    if (Test-Path '/dev/kvm') {
        return @('-enable-kvm', '-cpu', $CpuModel)
    }

    return @('-accel', 'tcg,thread=multi', '-cpu', $CpuModel)
}

function Get-QemuAudioArgs {
    param(
        [string]$Backend = 'auto',
        [string[]]$SupportedDrivers = @()
    )

    $normalizedBackend = $Backend.ToLowerInvariant()

    if (Test-IsMacOSHost) {
        return @(
            '-audiodev', 'coreaudio,id=audio0,out.frequency=44100,out.mixing-engine=on,in.mixing-engine=off',
            '-device', 'intel-hda',
            '-device', 'hda-duplex,audiodev=audio0'
        )
    }

    if (Test-IsWindowsHost) {
        $supported = @($SupportedDrivers | ForEach-Object { ([string]$_).ToLowerInvariant() })

        $driver = 'dsound'
        if ($normalizedBackend -eq 'auto') {
            $preferred = @('wasapi', 'dsound', 'sdl')
            if ($supported.Count -gt 0) {
                foreach ($candidate in $preferred) {
                    if ($supported -contains $candidate) {
                        $driver = $candidate
                        break
                    }
                }
            }
        }
        else {
            $driver = $normalizedBackend
            if (($supported.Count -gt 0) -and (-not ($supported -contains $driver))) {
                throw "Backend de audio '$driver' nao suportado por este QEMU. Disponiveis: $($supported -join ', ')"
            }
        }

        Write-EA11Info "Backend de audio selecionado (Windows): $driver"

        return @(
            '-audiodev', "$driver,id=audio0",
            '-device', 'intel-hda',
            '-device', 'hda-duplex,audiodev=audio0'
        )
    }

    return @(
        '-audiodev', 'pa,id=audio0',
        '-device', 'intel-hda',
        '-device', 'hda-duplex,audiodev=audio0'
    )
}

function Resolve-QemuSystemDiskPath {
    $stateDir = Get-EA11StateDirectory
    $defaultDisk = Join-Path $stateDir 'debian-a11ydevs.qcow2'
    if (Test-Path $defaultDisk) {
        return $defaultDisk
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $repoRoot = Get-RepoRoot
    if ($repoRoot) {
        [void]$candidates.Add((Join-Path (Join-Path $repoRoot 'output') 'debian-a11ydevs.qcow2'))
        [void]$candidates.Add((Join-Path (Join-Path $repoRoot 'output-hvf-build') 'debian-a11ydevs.qcow2'))
    }

    $cwd = (Get-Location).Path
    [void]$candidates.Add((Join-Path (Join-Path $cwd 'output') 'debian-a11ydevs.qcow2'))
    [void]$candidates.Add((Join-Path (Join-Path $cwd 'output-hvf-build') 'debian-a11ydevs.qcow2'))

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            Write-EA11Info "Copiando imagem de sistema para consistencia em $defaultDisk"
            Copy-Item -Path $candidate -Destination $defaultDisk -Force
            return $defaultDisk
        }
    }

    throw "Imagem de sistema QEMU nao encontrada. Coloque debian-a11ydevs.qcow2 em $stateDir"
}

function Ensure-QemuUserDataDisk {
    param(
        [string]$VMName,
        [int]$SizeGB = 10
    )

    $stateDir = Get-EA11StateDirectory
    $diskPath = Join-Path $stateDir "$VMName-home.qcow2"
    if (Test-Path $diskPath) {
        return $diskPath
    }

    Ensure-QemuImg
    Write-EA11Info "Criando disco de dados do usuario (${SizeGB}G): $diskPath"
    & qemu-img create -f qcow2 $diskPath "${SizeGB}G" | Out-Null

    return $diskPath
}

function Get-QemuLogsDirectory {
    $logsDir = Join-Path (Get-QemuStateDirectory) 'logs'
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    return $logsDir
}

function Get-RepoRoot {
    $candidate = Resolve-Path (Join-Path $PSScriptRoot "..")
    if (Test-Path (Join-Path $candidate "scripts/install-release-vm.ps1")) {
        return $candidate.Path
    }
    return $null
}

function Invoke-VMInstall {
    param([string[]]$InstallArgs)

    $owner = Get-OptionValue -Tokens $InstallArgs -Names @('--owner') -Default $EA11CTL_OWNER
    $repo = Get-OptionValue -Tokens $InstallArgs -Names @('--repo') -Default $EA11CTL_REPO
    $tag = Get-OptionValue -Tokens $InstallArgs -Names @('--tag') -Default 'latest'
    $releaseBaseUrl = Get-OptionValue -Tokens $InstallArgs -Names @('--release-base-url') -Default $EA11CTL_RELEASE_BASE_URL
    $forceDownload = Has-Flag -Tokens $InstallArgs -Flags @('--force-download', '--force', '-f')

    $stateDir = Get-EA11StateDirectory
    $targetDisk = Join-Path $stateDir 'debian-a11ydevs.qcow2'

    if ((Test-Path $targetDisk) -and (-not $forceDownload)) {
        Write-EA11Info "Imagem QCOW2 ja existe em: $targetDisk"
        Write-EA11Info "Use --force-download para baixar novamente."
        return
    }

    $assetName = 'debian-a11ydevs.qcow2'
    $releaseBaseUrl = [string]$releaseBaseUrl
    if (-not [string]::IsNullOrWhiteSpace($releaseBaseUrl)) {
        $releaseBaseUrl = $releaseBaseUrl.TrimEnd('/')
    }

    if ($tag -eq 'latest') {
        $mirrorUrl = "$releaseBaseUrl/latest/$assetName"
        $githubUrl = "https://github.com/$owner/$repo/releases/latest/download/$assetName"
    }
    else {
        $mirrorUrl = "$releaseBaseUrl/$tag/$assetName"
        $githubUrl = "https://github.com/$owner/$repo/releases/download/$tag/$assetName"
    }

    $tmpFile = "$targetDisk.download"
    $urls = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($releaseBaseUrl)) {
        [void]$urls.Add($mirrorUrl)
    }
    [void]$urls.Add($githubUrl)

    $downloaded = $false
    $lastError = ''

    foreach ($url in $urls) {
        try {
            if ($url -eq $mirrorUrl) {
                Write-EA11Info "Baixando imagem QCOW2 via mirror: $url"
            }
            else {
                Write-EA11Info "Baixando imagem QCOW2 via GitHub: $url"
            }

            Invoke-AccessibleDownload -Url $url -Destination $tmpFile -Label 'imagem da VM' -PercentStep 5 -BeepOnProgress
            Move-Item -Path $tmpFile -Destination $targetDisk -Force
            $downloaded = $true
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
            if ($url -eq $mirrorUrl) {
                Write-EA11Warn "Falha no mirror; tentando GitHub."
            }
        }
    }

    if (-not $downloaded) {
        throw "Falha ao baixar imagem QCOW2 da release: $lastError"
    }

    Write-EA11Info "Imagem QEMU instalada em: $targetDisk"
    Write-EA11Info "Proximo passo: ea11ctl vm start"
}

function Get-VMName {
    param([string[]]$Tokens)
    return (Get-OptionValue -Tokens $Tokens -Names @('--name', '-n') -Default 'debian-a11y')
}

function Ensure-VBoxManage {
    if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
        return
    }

    $candidates = @(
        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe",
        "$env:ProgramW6432\Oracle\VirtualBox\VBoxManage.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $dir = Split-Path -Path $candidate -Parent
            $env:PATH = "$dir;$env:PATH"
            break
        }
    }

    Assert-Command "VBoxManage"
}

function Invoke-QemuVMList {
    $stateDir = Get-QemuStateDirectory
    $files = Get-ChildItem -Path $stateDir -Filter '*.json' -File -ErrorAction SilentlyContinue

    if (-not $files) {
        Write-EA11Info 'Nenhuma VM QEMU registrada em ~/.emacs-a11y-vm.'
        return
    }

    foreach ($file in $files) {
        $state = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        $vmPid = 0
        if ($state.pid) {
            $vmPid = [int]$state.pid
        }

        $running = $false
        if ($vmPid -gt 0) {
            $running = $null -ne (Get-ProcessByIdSafe -ProcessId $vmPid)
        }

        $status = if ($running) { 'running' } else { 'stopped' }
        Write-Host "$($state.name) (qemu) - $status - ssh:$($state.sshPort)"
    }
}

function Invoke-QemuVMStart {
    param([string[]]$Tokens)

    Ensure-QemuSystem

    $runtimeCfg = Get-QemuRuntimeConfig

    $vmName = Get-VMName -Tokens $Tokens
    $sshPort = Get-IntOptionValue -Tokens $Tokens -Names @('--port', '--ssh-port', '-p') -Default 2222 -OptionName '--ssh-port'
    $memory = Get-IntOptionValue -Tokens $Tokens -Names @('--memory', '-m') -Default ([int]$runtimeCfg.memoryMb) -OptionName '--memory'
    $cpus = Get-IntOptionValue -Tokens $Tokens -Names @('--cpus') -Default ([int]$runtimeCfg.cpus) -OptionName '--cpus'
    $userDataSize = Get-IntOptionValue -Tokens $Tokens -Names @('--user-data-size') -Default 10 -OptionName '--user-data-size'
    $headless = Has-Flag -Tokens $Tokens -Flags @('--headless', '-h')
    $audioBackend = Get-OptionValue -Tokens $Tokens -Names @('--audio-backend') -Default 'auto'
    $accelMode = Get-OptionValue -Tokens $Tokens -Names @('--accel') -Default ([string]$runtimeCfg.accel)
    $cpuModel = [string]$runtimeCfg.cpuModel
    $netDevice = [string]$runtimeCfg.netDevice
    $diskInterface = [string]$runtimeCfg.diskInterface
    $diskCache = [string]$runtimeCfg.diskCache
    $diskDiscard = [string]$runtimeCfg.diskDiscard
    $videoDevice = [string]$runtimeCfg.videoDevice
    $disableHostHomeShare = Has-Flag -Tokens $Tokens -Flags @('--no-host-home-share')
    $smbServer = Get-OptionValue -Tokens $Tokens -Names @('--smb-server') -Default $null
    $smbShare = Get-OptionValue -Tokens $Tokens -Names @('--smb-share') -Default $null
    $smbUser = Get-OptionValue -Tokens $Tokens -Names @('--smb-user') -Default $null
    $smbPassword = Get-OptionValue -Tokens $Tokens -Names @('--smb-password') -Default $null
    $qemuExecutable = Resolve-QemuSystemExecutable -Headless:$headless
    $supportedAudioDrivers = Get-QemuAvailableAudioDrivers -QemuExecutable $qemuExecutable

    $existing = Load-QemuState -VMName $vmName
    if ($existing -and $existing.pid) {
        $existingPid = [int]$existing.pid
        if ($existingPid -gt 0 -and (Get-ProcessByIdSafe -ProcessId $existingPid)) {
            throw "VM QEMU '$vmName' ja esta em execucao (PID $existingPid)."
        }
    }

    $systemDisk = Resolve-QemuSystemDiskPath
    $userDataDisk = Ensure-QemuUserDataDisk -VMName $vmName -SizeGB $userDataSize
    $logsDir = Get-QemuLogsDirectory
    $stdoutLog = Join-Path $logsDir "$vmName-stdout.log"
    $stderrLog = Join-Path $logsDir "$vmName-stderr.log"

    $hostHomeShare = $null
    $hostHomeShareMode = $null
    $qemuSmbShare = $null
    $smbSupportInfo = $null
    $netdevValue = "user,id=net0,hostfwd=tcp::$sshPort-:22"

    if (-not $disableHostHomeShare) {
        $hostHomeShare = Get-QemuHostHomeShareConfig
        if ($hostHomeShare) {
            if (Test-QemuVirtfsSupport -QemuExecutable $qemuExecutable) {
                $hostHomeShareMode = '9p'
                Write-EA11Info "Compartilhando host home via 9p: $($hostHomeShare.HostPath) -> $($hostHomeShare.GuestMountPoint)"
            }
            else {
                $smbSupportInfo = Get-QemuUserNetSmbSupportInfo -QemuExecutable $qemuExecutable
            }

            if (($hostHomeShareMode -ne '9p') -and $smbSupportInfo -and ($smbSupportInfo.Supported -or ($smbSupportInfo.Reason -ne 'unsupported'))) {
                if (Test-IsWindowsHost) {
                    Write-EA11Warn 'virtfs/9p indisponivel no QEMU do Windows. Iniciando VM sem compartilhamento automatico da home do host.'
                    $hostHomeShareMode = $null
                    $hostHomeShare = $null
                }
                else {
                    $hostHomeShareMode = 'smb'
                    $escapedSmbPath = ([string]$hostHomeShare.HostPath).Replace('"', '\"')
                    $netdevValue = ('user,id=net0,hostfwd=tcp::{0}-:22,smb="{1}"' -f $sshPort, $escapedSmbPath)
                    $qemuSmbShare = @{
                        Server = '10.0.2.4'
                        Share = 'qemu'
                        GuestMountPoint = $hostHomeShare.GuestMountPoint
                    }
                    if ($smbSupportInfo.Reason -eq 'missing-host-smb-helper') {
                        Write-EA11Warn 'virtfs/9p indisponivel. SMB usernet sera tentado, mas o helper SMB do host aparenta ausente; se falhar, o start seguira sem share automaticamente.'
                    }
                    else {
                        Write-EA11Warn "virtfs/9p indisponivel neste QEMU. Usando fallback SMB (//10.0.2.4/qemu -> $($qemuSmbShare.GuestMountPoint))."
                    }
                }
            }
            elseif ($hostHomeShareMode -ne '9p') {
                if ($smbSupportInfo -and ($smbSupportInfo.Reason -eq 'missing-host-smb-helper')) {
                    Write-EA11Warn 'QEMU ate possui parametro SMB usernet, mas o helper SMB do host nao esta disponivel (ex.: smbd). VM iniciada sem compartilhamento automatico da home do host.'
                }
                else {
                    Write-EA11Warn 'Este binario QEMU nao suporta virtfs/9p nem SMB usernet em runtime. VM iniciada sem compartilhamento automatico da home do host.'
                }
                $hostHomeShare = $null
            }
        }
        else {
            Write-EA11Warn 'Nao foi possivel resolver pasta home do host para compartilhamento 9p automatico.'
        }
    }

    $hostUserForGuest = $null
    if ($hostHomeShare) {
        $hostUserForGuest = $hostHomeShare.HostUser
    }

    $qemuArgs = New-QemuBaseArgs -Memory $memory -Cpus $cpus -SystemDisk $systemDisk -UserDataDisk $userDataDisk -NetdevValue $netdevValue -NetDevice $netDevice -DiskInterface $diskInterface -DiskCache $diskCache -DiskDiscard $diskDiscard -VideoDevice $videoDevice -HostHomeShare $hostHomeShare -HostHomeShareMode $hostHomeShareMode -HostUser $hostUserForGuest -HostSmbServer $smbServer -HostSmbShare $smbShare -HostSmbUser $smbUser -HostSmbPassword $smbPassword

    $qemuArgs += Get-QemuAccelerationArgs -Mode $accelMode -CpuModel $cpuModel

    if ($headless) {
        $qemuArgs += @('-nographic', '-serial', 'stdio')
    }
    else {
        if (Test-IsMacOSHost) {
            $qemuArgs += @('-display', 'cocoa,zoom-to-fit=on,full-screen=on', '-k', 'en-us')
        }
        elseif (Test-IsWindowsHost) {
            $qemuArgs += @('-display', 'sdl', '-full-screen')
        }

        $qemuArgs += Get-QemuAudioArgs -Backend $audioBackend -SupportedDrivers $supportedAudioDrivers
    }

    Write-EA11Info "Iniciando VM QEMU '$vmName'..."
    $startParams = @{
        FilePath = $qemuExecutable
        ArgumentList = $qemuArgs
        PassThru = $true
        RedirectStandardOutput = $stdoutLog
        RedirectStandardError = $stderrLog
    }

    if ((Test-IsWindowsHost) -and $headless) {
        $startParams.WindowStyle = 'Hidden'
    }

    $proc = Start-Process @startParams

    Start-Sleep -Seconds 2
    $alive = Get-ProcessByIdSafe -ProcessId $proc.Id

    if ((-not $alive) -and ($hostHomeShareMode -eq 'smb')) {
        $lastError = ''
        if (Test-Path $stderrLog) {
            $lastError = (Get-Content -Path $stderrLog -Tail 120 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }

        if ($lastError -match '(?i)\bsmb\b|smbd|could not find .*smbd|failed to start smb|invalid\s+parameter.*smb|unknown\s+parameter.*smb') {
            Write-EA11Warn 'Fallback SMB falhou em runtime neste host/QEMU. Retentando start automaticamente sem compartilhamento de pasta do host.'

            $hostHomeShareMode = $null
            $hostHomeShare = $null
            $qemuSmbShare = $null
            $hostUserForGuest = $null
            $netdevValue = "user,id=net0,hostfwd=tcp::$sshPort-:22"

            $qemuArgs = New-QemuBaseArgs -Memory $memory -Cpus $cpus -SystemDisk $systemDisk -UserDataDisk $userDataDisk -NetdevValue $netdevValue -NetDevice $netDevice -DiskInterface $diskInterface -DiskCache $diskCache -DiskDiscard $diskDiscard -VideoDevice $videoDevice -HostHomeShare $hostHomeShare -HostHomeShareMode $hostHomeShareMode -HostUser $hostUserForGuest
            $qemuArgs += Get-QemuAccelerationArgs -Mode $accelMode -CpuModel $cpuModel

            if ($headless) {
                $qemuArgs += @('-nographic', '-serial', 'stdio')
            }
            else {
                if (Test-IsMacOSHost) {
                    $qemuArgs += @('-display', 'cocoa,zoom-to-fit=on,full-screen=on', '-k', 'en-us')
                }
                elseif (Test-IsWindowsHost) {
                    $qemuArgs += @('-display', 'sdl', '-full-screen')
                }

                $qemuArgs += Get-QemuAudioArgs -Backend $audioBackend -SupportedDrivers $supportedAudioDrivers
            }

            $startParams.ArgumentList = $qemuArgs
            $proc = Start-Process @startParams
            Start-Sleep -Seconds 2
            $alive = Get-ProcessByIdSafe -ProcessId $proc.Id
        }
    }

    if ((-not $alive) -and (Test-IsWindowsHost) -and ($accelMode -eq 'auto')) {
        $lastError = ''
        if (Test-Path $stderrLog) {
            $lastError = (Get-Content -Path $stderrLog -Tail 80 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }

        if ($lastError -match 'WHPX|Unexpected VP exit code|APX|MPX') {
            Write-EA11Warn 'WHPX falhou no host atual. Retentando automaticamente com aceleracao TCG (modo compatibilidade)...'

            $qemuArgs = New-QemuBaseArgs -Memory $memory -Cpus $cpus -SystemDisk $systemDisk -UserDataDisk $userDataDisk -NetdevValue $netdevValue -NetDevice $netDevice -DiskInterface $diskInterface -DiskCache $diskCache -DiskDiscard $diskDiscard -VideoDevice $videoDevice -HostHomeShare $hostHomeShare -HostHomeShareMode $hostHomeShareMode -HostUser $hostUserForGuest

            $qemuArgs += Get-QemuAccelerationArgs -Mode 'tcg' -CpuModel $cpuModel

            if ($headless) {
                $qemuArgs += @('-nographic', '-serial', 'stdio')
            }
            else {
                if (Test-IsMacOSHost) {
                    $qemuArgs += @('-display', 'cocoa,zoom-to-fit=on,full-screen=on', '-k', 'en-us')
                }
                elseif (Test-IsWindowsHost) {
                    $qemuArgs += @('-display', 'sdl', '-full-screen')
                }

                $qemuArgs += Get-QemuAudioArgs
            }

            $startParams.ArgumentList = $qemuArgs
            $proc = Start-Process @startParams
            Start-Sleep -Seconds 2
            $alive = Get-ProcessByIdSafe -ProcessId $proc.Id
        }
    }

    if ((-not $alive) -and (Test-IsWindowsHost) -and ($audioBackend -eq 'auto')) {
        $lastError = ''
        if (Test-Path $stderrLog) {
            $lastError = (Get-Content -Path $stderrLog -Tail 120 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }

        if ($lastError -match 'audiodev|wasapi|dsound|audio') {
            $fallbackAudio = 'dsound'
            if (($supportedAudioDrivers -contains 'sdl') -and (-not ($supportedAudioDrivers -contains 'dsound'))) {
                $fallbackAudio = 'sdl'
            }
            Write-EA11Warn "Backend de audio automatico falhou. Retentando com '$fallbackAudio'..."

            $qemuArgs = New-QemuBaseArgs -Memory $memory -Cpus $cpus -SystemDisk $systemDisk -UserDataDisk $userDataDisk -NetdevValue $netdevValue -NetDevice $netDevice -DiskInterface $diskInterface -DiskCache $diskCache -DiskDiscard $diskDiscard -VideoDevice $videoDevice -HostHomeShare $hostHomeShare -HostHomeShareMode $hostHomeShareMode -HostUser $hostUserForGuest

            $qemuArgs += Get-QemuAccelerationArgs -Mode $accelMode -CpuModel $cpuModel

            if ($headless) {
                $qemuArgs += @('-nographic', '-serial', 'stdio')
            }
            else {
                if (Test-IsMacOSHost) {
                    $qemuArgs += @('-display', 'cocoa,zoom-to-fit=on,full-screen=on', '-k', 'en-us')
                }
                elseif (Test-IsWindowsHost) {
                    $qemuArgs += @('-display', 'sdl', '-full-screen')
                }

                $qemuArgs += Get-QemuAudioArgs -Backend $fallbackAudio -SupportedDrivers $supportedAudioDrivers
            }

            $startParams.ArgumentList = $qemuArgs
            $proc = Start-Process @startParams
            Start-Sleep -Seconds 2
            $alive = Get-ProcessByIdSafe -ProcessId $proc.Id
        }
    }

    if (-not $alive) {
        $lastError = ''
        if (Test-Path $stderrLog) {
            $lastError = (Get-Content -Path $stderrLog -Tail 20 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }
        throw "Falha ao iniciar QEMU para '$vmName'. Log: $stderrLog`n$lastError"
    }

    Save-QemuState -VMName $vmName -State @{
        name = $vmName
        backend = 'qemu'
        pid = $proc.Id
        sshPort = $sshPort
        sshUser = 'a11ydevs'
        systemDisk = $systemDisk
        userDataDisk = $userDataDisk
        homeMount = '/home'
        stdoutLog = $stdoutLog
        stderrLog = $stderrLog
        hostHomeSharePath = if ($hostHomeShare) { $hostHomeShare.HostPath } else { $null }
        hostHomeShareTag = if ($hostHomeShare) { $hostHomeShare.MountTag } else { $null }
        hostHomeShareMode = if ($hostHomeShareMode) { $hostHomeShareMode } else { $null }
        hostHomeSmbServer = if ($qemuSmbShare) { $qemuSmbShare.Server } else { $null }
        hostHomeSmbShare = if ($qemuSmbShare) { $qemuSmbShare.Share } else { $null }
        hostHomeGuestMountPoint = if ($hostHomeShare) { $hostHomeShare.GuestMountPoint } else { $null }
        startedAt = (Get-Date).ToString('o')
        lastStatus = 'running'
    }

    Write-Host "VM: $vmName"
    Write-Host "Backend: qemu"
    Write-Host "PID: $($proc.Id)"
    Write-Host "SSH: localhost:$sshPort"
    Write-Host "Sistema: $systemDisk"
    Write-Host "Dados (/home): $userDataDisk"
    if (($hostHomeShareMode -eq '9p') -and $hostHomeShare) {
        Write-Host "Host home (9p): $($hostHomeShare.HostPath) -> $($hostHomeShare.GuestMountPoint)"
    }
    elseif (($hostHomeShareMode -eq 'smb') -and $hostHomeShare -and $qemuSmbShare) {
        Write-Host "Host home (SMB): $($hostHomeShare.HostPath) -> //$($qemuSmbShare.Server)/$($qemuSmbShare.Share) -> $($qemuSmbShare.GuestMountPoint)"
    }
}

function Invoke-QemuVMStop {
    param([string[]]$Tokens)

    $vmName = Get-VMName -Tokens $Tokens
    $force = Has-Flag -Tokens $Tokens -Flags @('--force', '-f')
    $timeout = Get-IntOptionValue -Tokens $Tokens -Names @('--timeout', '-t') -Default 30 -OptionName '--timeout'

    $state = Load-QemuState -VMName $vmName
    if (-not $state) {
        Write-EA11Warn "VM QEMU '$vmName' nao possui estado registrado em ~/.emacs-a11y-vm."
        return
    }

    $vmPid = 0
    if ($state.pid) {
        $vmPid = [int]$state.pid
    }

    if ($vmPid -le 0) {
        Write-EA11Warn "Estado da VM QEMU '$vmName' nao possui PID ativo."
        return
    }

    $proc = Get-ProcessByIdSafe -ProcessId $vmPid
    if (-not $proc) {
        Write-EA11Warn "Processo da VM QEMU '$vmName' (PID $vmPid) nao esta mais em execucao."
        Save-QemuState -VMName $vmName -State @{
            name = $vmName
            backend = 'qemu'
            pid = $null
            sshPort = $state.sshPort
            sshUser = $state.sshUser
            systemDisk = $state.systemDisk
            userDataDisk = $state.userDataDisk
            homeMount = '/home'
            stdoutLog = $state.stdoutLog
            stderrLog = $state.stderrLog
            startedAt = $state.startedAt
            stoppedAt = (Get-Date).ToString('o')
            lastStatus = 'stopped'
        }
        return
    }

    if ($force) {
        Write-EA11Warn "Forcando encerramento da VM QEMU '$vmName' (PID $vmPid)..."
        Stop-Process -Id $vmPid -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-EA11Info "Encerrando VM QEMU '$vmName' de forma graciosa (PID $vmPid)..."
        Stop-Process -Id $vmPid -ErrorAction SilentlyContinue

        $start = Get-Date
        do {
            Start-Sleep -Seconds 1
            $stillRunning = $null -ne (Get-ProcessByIdSafe -ProcessId $vmPid)
            $elapsed = ((Get-Date) - $start).TotalSeconds
        } while ($stillRunning -and ($elapsed -lt $timeout))

        if ($stillRunning) {
            Write-EA11Warn "VM QEMU '$vmName' nao encerrou em $timeout s. Aplicando force kill."
            Stop-Process -Id $vmPid -Force -ErrorAction SilentlyContinue
        }
    }

    Save-QemuState -VMName $vmName -State @{
        name = $vmName
        backend = 'qemu'
        pid = $null
        sshPort = $state.sshPort
        sshUser = $state.sshUser
        systemDisk = $state.systemDisk
        userDataDisk = $state.userDataDisk
        homeMount = '/home'
        stdoutLog = $state.stdoutLog
        stderrLog = $state.stderrLog
        startedAt = $state.startedAt
        stoppedAt = (Get-Date).ToString('o')
        lastStatus = 'stopped'
    }
}

function Invoke-QemuVMRemove {
    param([string[]]$Tokens)

    $vmName = Get-VMName -Tokens $Tokens
    $removeData = Has-Flag -Tokens $Tokens -Flags @('--data')
    $removeSystem = Has-Flag -Tokens $Tokens -Flags @('--system')
    $removeAll = Has-Flag -Tokens $Tokens -Flags @('--all')
    $force = Has-Flag -Tokens $Tokens -Flags @('--force', '-f')
    $yes = Has-Flag -Tokens $Tokens -Flags @('--yes', '-y')

    if ($removeAll) {
        $removeData = $true
        $removeSystem = $true
    }

    $state = Load-QemuState -VMName $vmName
    $stateDir = Get-EA11StateDirectory
    $stateFile = Get-QemuStateFilePath -VMName $vmName
    $logsDir = Get-QemuLogsDirectory
    $stderrLog = Join-Path $logsDir "$vmName-stderr.log"
    $stdoutLog = Join-Path $logsDir "$vmName-stdout.log"

    $systemDisk = Join-Path $stateDir 'debian-a11ydevs.qcow2'
    $userDataDisk = Join-Path $stateDir "$vmName-home.qcow2"
    if ($state) {
        if ($state.systemDisk) { $systemDisk = [string]$state.systemDisk }
        if ($state.userDataDisk) { $userDataDisk = [string]$state.userDataDisk }
        if ($state.stderrLog) { $stderrLog = [string]$state.stderrLog }
        if ($state.stdoutLog) { $stdoutLog = [string]$state.stdoutLog }
    }

    if ($state -and $state.pid) {
        $vmPid = [int]$state.pid
        if ($vmPid -gt 0 -and (Get-ProcessByIdSafe -ProcessId $vmPid)) {
            if ($force) {
                Stop-Process -Id $vmPid -Force -ErrorAction SilentlyContinue
                Write-EA11Warn "VM '$vmName' estava em execucao e foi encerrada com --force."
            }
            else {
                throw "VM '$vmName' esta em execucao. Use ea11ctl vm stop --name $vmName ou --force."
            }
        }
    }

    if (-not $yes) {
        Write-EA11Warn "Isso removera o registro local da VM '$vmName'."
        if ($removeData) {
            Write-EA11Warn "Tambem removera disco de dados: $userDataDisk"
        }
        if ($removeSystem) {
            Write-EA11Warn "Tambem removera imagem de sistema: $systemDisk"
        }
        $reply = Read-Host 'Digite "yes" para confirmar'
        if ($reply -ne 'yes') {
            Write-EA11Info 'Remocao cancelada.'
            return
        }
    }

    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stdoutLog -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stderrLog -Force -ErrorAction SilentlyContinue

    if ($removeData) {
        Remove-Item -Path $userDataDisk -Force -ErrorAction SilentlyContinue
    }
    if ($removeSystem) {
        Remove-Item -Path $systemDisk -Force -ErrorAction SilentlyContinue
    }

    Write-EA11Info "VM '$vmName' removida (registro/local state)."
    if ($removeData) { Write-EA11Info 'Disco de dados removido.' }
    if ($removeSystem) { Write-EA11Info 'Imagem de sistema removida.' }
}

function Invoke-Uninstall {
    param([string[]]$Tokens)

    $purgeState = Has-Flag -Tokens $Tokens -Flags @('--purge-state')
    $yes = Has-Flag -Tokens $Tokens -Flags @('--yes', '-y')
    $forceRepoPath = Has-Flag -Tokens $Tokens -Flags @('--force-repo-path')

    $repoGitPath = Join-Path (Join-Path $PSScriptRoot '..') '.git'
    if ((Test-Path $repoGitPath) -and (-not $forceRepoPath)) {
        throw 'Desinstalacao bloqueada: esta CLI parece estar sendo executada do checkout do repositorio. Use --force-repo-path para confirmar.'
    }

    if (-not $yes) {
        Write-EA11Warn 'Esta acao desinstala a CLI deste diretorio.'
        if ($purgeState) {
            Write-EA11Warn 'Tambem removera ~/.emacs-a11y-vm (VMs, estado e logs).'
        }
        $reply = Read-Host 'Digite "yes" para confirmar'
        if ($reply -ne 'yes') {
            Write-EA11Info 'Desinstalacao cancelada.'
            return
        }
    }

    $installDir = $PSScriptRoot
    $toRemove = @('ea11ctl.cmd', 'VERSION')
    foreach ($file in $toRemove) {
        Remove-Item -Path (Join-Path $installDir $file) -Force -ErrorAction SilentlyContinue
    }

    # Auto-remocao do proprio script apos o processo atual encerrar.
    $selfPath = $MyInvocation.MyCommand.Path
    $cleanupCmd = "ping 127.0.0.1 -n 3 >nul & del /f /q `"$selfPath`""
    cmd.exe /c $cleanupCmd | Out-Null

    if ($purgeState) {
        Remove-Item -Path (Get-EA11StateDirectory) -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'ea11ctl desinstalado neste diretorio.' -ForegroundColor Green
}

function Invoke-QemuVMStatus {
    param([string[]]$Tokens)

    $vmName = Get-VMName -Tokens $Tokens
    $state = Load-QemuState -VMName $vmName
    if (-not $state) {
        Write-EA11Warn "VM QEMU '$vmName' nao registrada em ~/.emacs-a11y-vm."
        return
    }

    $vmPid = 0
    if ($state.pid) {
        $vmPid = [int]$state.pid
    }

    $running = $false
    if ($vmPid -gt 0) {
        $running = $null -ne (Get-ProcessByIdSafe -ProcessId $vmPid)
    }

    $status = if ($running) { 'running' } else { 'stopped' }
    Write-Host "VM: $vmName"
    Write-Host 'Backend: qemu'
    Write-Host "State: $status"
    Write-Host "PID: $vmPid"
    Write-Host "SSH: localhost:$($state.sshPort)"
    Write-Host "Sistema: $($state.systemDisk)"
    Write-Host "Dados (/home): $($state.userDataDisk)"
    if ($state.hostHomeShareMode -eq '9p' -and $state.hostHomeSharePath -and $state.hostHomeGuestMountPoint) {
        Write-Host "Host home (9p): $($state.hostHomeSharePath) -> $($state.hostHomeGuestMountPoint)"
    }
    elseif ($state.hostHomeShareMode -eq 'smb' -and $state.hostHomeSmbServer -and $state.hostHomeSmbShare) {
        $guestMount = if ($state.hostHomeGuestMountPoint) { [string]$state.hostHomeGuestMountPoint } else { '/home/hosthome' }
        Write-Host "Host home (SMB): $($state.hostHomeSharePath) -> //$($state.hostHomeSmbServer)/$($state.hostHomeSmbShare) -> $guestMount"
    }
    Write-Host "Estado: $(Get-QemuStateFilePath -VMName $vmName)"
}

function Invoke-QemuVMSSH {
    param([string[]]$Tokens)

    Assert-Command 'ssh'

    $vmName = Get-VMName -Tokens $Tokens
    $state = Load-QemuState -VMName $vmName

    $user = Get-OptionValue -Tokens $Tokens -Names @('--user', '-u') -Default 'a11ydevs'
    $portFromState = '2222'
    if ($state -and $state.sshPort) {
        $portFromState = [string]$state.sshPort
    }

    $port = if (Has-OptionName -Tokens $Tokens -Names @('--port', '-p')) {
        Get-OptionValue -Tokens $Tokens -Names @('--port', '-p') -Default $portFromState
    }
    else {
        $portFromState
    }

    $extraStart = [Array]::IndexOf($Tokens, '--')
$extra = @()
if ($extraStart -ge 0 -and ($extraStart + 1) -lt $Tokens.Length) {
    $extra = $Tokens[($extraStart + 1)..($Tokens.Length - 1)]
}

$hostKeyAlias = "ea11ctl-$vmName-$port"

Write-EA11Info "Abrindo SSH para $user@localhost:$port"
& ssh `
  -p $port `
  -o "HostKeyAlias=$hostKeyAlias" `
  -o "UserKnownHostsFile=$env:USERPROFILE\.ssh\known_hosts_ea11ctl" `
  "$user@localhost" @extra
}

function Invoke-QemuVMDiagnose {
    param([string[]]$Tokens)

    $vmName = Get-VMName -Tokens $Tokens
    $state = Load-QemuState -VMName $vmName
    if (-not $state) {
        Write-EA11Warn "VM QEMU '$vmName' nao registrada."
        return
    }

    Invoke-QemuVMStatus -Tokens $Tokens

    $lines = Get-IntOptionValue -Tokens $Tokens -Names @('--lines', '-L') -Default 80 -OptionName '--lines'
    if ($state.stderrLog -and (Test-Path $state.stderrLog)) {
        Write-Host ''
        Write-Host '--- Ultimas linhas do log de erro do QEMU ---' -ForegroundColor Cyan
        Get-Content -Path $state.stderrLog -Tail $lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Write-Host '--- Fim ---' -ForegroundColor Cyan
    }
    else {
        Write-EA11Warn 'Log de erro do QEMU nao encontrado.'
    }
}

function Invoke-VMList {
    Ensure-VBoxManage
    & VBoxManage list vms
}

function Invoke-VMStart {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $type = if (Has-Flag -Tokens $Tokens -Flags @('--headless', '-h')) { 'headless' } else { 'gui' }

    Write-EA11Info "Iniciando VM '$vmName' ($type)..."
    & VBoxManage startvm $vmName --type $type
}

function Invoke-VMStop {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $force = Has-Flag -Tokens $Tokens -Flags @('--force', '-f')

    if ($force) {
        Write-EA11Warn "Forcando desligamento da VM '$vmName'..."
        & VBoxManage controlvm $vmName poweroff
        return
    }

    Write-EA11Info "Solicitando desligamento ACPI da VM '$vmName'..."
    & VBoxManage controlvm $vmName acpipowerbutton
}

function Invoke-VMStatus {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $raw = & VBoxManage showvminfo $vmName --machinereadable
    $line = $raw | Where-Object { $_ -like 'VMState=*' }

    if (-not $line) {
        Write-EA11Warn "Nao foi possivel obter estado da VM '$vmName'."
        return
    }

    $state = $line -replace '^VMState="?', '' -replace '"$', ''
    Write-Host "VM: $vmName"
    Write-Host "State: $state"
}

function Get-VMState {
    param([string]$VMName)

    $raw = & VBoxManage showvminfo $VMName --machinereadable 2>$null
    $line = $raw | Where-Object { $_ -like 'VMState=*' }
    if (-not $line) {
        return $null
    }

    return (($line -replace '^VMState="?', '' -replace '"$', '').ToLowerInvariant())
}

function Get-VMUUID {
    param([string]$VMName)

    $raw = & VBoxManage showvminfo $VMName --machinereadable 2>$null
    $line = $raw | Where-Object { $_ -like 'UUID=*' }
    if (-not $line) {
        return $null
    }

    return ($line -replace '^UUID="?', '' -replace '"$', '')
}

function Get-VMConfigFile {
    param([string]$VMName)

    $raw = & VBoxManage showvminfo $VMName --machinereadable 2>$null
    $line = $raw | Where-Object { $_ -like 'CfgFile=*' }
    if (-not $line) {
        return $null
    }

    return ($line -replace '^CfgFile="?', '' -replace '"$', '')
}

function Get-VMHardeningLogPath {
    param([string]$VMName)

    $cfgFile = Get-VMConfigFile -VMName $VMName
    if (-not [string]::IsNullOrWhiteSpace($cfgFile)) {
        $cfgDir = Split-Path -Path $cfgFile -Parent
        if (-not [string]::IsNullOrWhiteSpace($cfgDir)) {
            return (Join-Path $cfgDir 'Logs\VBoxHardening.log')
        }
    }

    return (Join-Path $env:USERPROFILE "VirtualBox VMs\$VMName\Logs\VBoxHardening.log")
}

function Show-HardeningLogSummary {
    param(
        [string]$LogPath,
        [int]$Lines = 80
    )

    if (-not (Test-Path $LogPath)) {
        Write-EA11Warn "VBoxHardening.log nao encontrado em: $LogPath"
        return
    }

    Write-EA11Info "Lendo log: $LogPath"
    Write-Host ''
    Write-Host '--- Ultimas linhas do VBoxHardening.log ---' -ForegroundColor Cyan
    Get-Content -Path $LogPath -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    Write-Host '--- Fim ---' -ForegroundColor Cyan
    Write-Host ''

    $patterns = 'supR3Hardened', 'Error', 'error', 'rc=', 'dll', 'NtCreateSection', 'Signature', 'denied'
    $hits = Select-String -Path $LogPath -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -Last 30

    if ($hits) {
        Write-Host '--- Linhas suspeitas (hardening) ---' -ForegroundColor Yellow
        foreach ($hit in $hits) {
            Write-Host ("{0}:{1}" -f $hit.LineNumber, $hit.Line)
        }
        Write-Host '--- Fim ---' -ForegroundColor Yellow
    }
    else {
        Write-EA11Info 'Nenhuma linha suspeita encontrada pelos padrões padrão.'
    }
}

function Invoke-VMDiagnose {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $tryStart = Has-Flag -Tokens $Tokens -Flags @('--try-start', '-T')

    $linesRaw = Get-OptionValue -Tokens $Tokens -Names @('--lines', '-L') -Default '80'
    $lines = 80
    if (-not [int]::TryParse($linesRaw, [ref]$lines)) {
        throw "Valor invalido para --lines: $linesRaw"
    }

    Write-EA11Info "Diagnostico da VM '$vmName'"
    $state = Get-VMState -VMName $vmName
    if ($state) {
        Write-Host "Estado atual: $state"
    }
    else {
        Write-EA11Warn "Nao foi possivel obter estado da VM via VBoxManage showvminfo."
    }

    if ($tryStart) {
        Write-EA11Info "Tentando start headless para reproduzir erro..."
        try {
            $startOut = & VBoxManage startvm $vmName --type headless 2>&1
            if ($startOut) {
                $startOut | ForEach-Object { Write-Host $_ }
            }
        }
        catch {
            Write-EA11Warn "Start headless retornou erro: $($_.Exception.Message)"
        }
    }

    $logPath = Get-VMHardeningLogPath -VMName $vmName
    Show-HardeningLogSummary -LogPath $logPath -Lines $lines

    Write-Host ''
    Write-Host 'Dicas rapidas:' -ForegroundColor Green
    Write-Host '1) Desative temporariamente antivirus/overlay que injete DLL no VirtualBox.'
    Write-Host '2) Reinstale VirtualBox + Extension Pack na mesma versao.'
    Write-Host '3) Atualize VC++ Redistributable e reinicie o Windows.'
}

function Close-VMWindowProcess {
    param([string]$VMName)

    $vmUuid = Get-VMUUID -VMName $VMName
    if ([string]::IsNullOrWhiteSpace($vmUuid)) {
        Write-EA11Warn "Nao foi possivel resolver UUID da VM '$VMName' para fechar janela."
        return
    }

    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        Write-EA11Warn "Get-CimInstance indisponivel; nao foi possivel identificar a janela da VM para fechamento automatico."
        return
    }

    $candidates = Get-CimInstance Win32_Process -Filter "Name='VirtualBoxVM.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and (
                $_.CommandLine -match [regex]::Escape($vmUuid) -or
                $_.CommandLine -match [regex]::Escape($VMName)
            )
        }

    if (-not $candidates) {
        Write-EA11Info "Nenhuma janela/processo VirtualBoxVM aberta para '$VMName'."
        return
    }

    foreach ($proc in $candidates) {
        Write-EA11Info "Solicitando fechamento da janela da VM '$VMName' (PID $($proc.ProcessId))"

        # Fechamento gracioso: evita corromper estado interno do VirtualBox.
        Stop-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
    }
}

function Invoke-VMClose {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $timeoutRaw = Get-OptionValue -Tokens $Tokens -Names @('--timeout', '-t') -Default '30'
    $timeout = 30
    if (-not [int]::TryParse($timeoutRaw, [ref]$timeout)) {
        throw "Valor invalido para --timeout: $timeoutRaw"
    }

    $state = Get-VMState -VMName $vmName
    if (-not $state) {
        throw "Nao foi possivel consultar o estado da VM '$vmName'."
    }

    if ($state -in @('running', 'paused', 'stuck')) {
        Write-EA11Info "VM '$vmName' esta '$state'. Solicitando encerramento gracioso (ACPI)..."
        & VBoxManage controlvm $vmName acpipowerbutton | Out-Null

        $start = Get-Date
        do {
            Start-Sleep -Seconds 2
            $state = Get-VMState -VMName $vmName
            if (-not $state) { break }
            $elapsed = ((Get-Date) - $start).TotalSeconds
        } while (($state -in @('running', 'paused', 'stuck')) -and ($elapsed -lt $timeout))

        if ($state -in @('running', 'paused', 'stuck')) {
            Write-EA11Warn "VM '$vmName' nao desligou em $timeout s. Forcando poweroff..."
            & VBoxManage controlvm $vmName poweroff | Out-Null
        }
    }
    else {
        Write-EA11Info "VM '$vmName' ja estava parada (estado: $state)."
    }

    Close-VMWindowProcess -VMName $vmName
}

function Invoke-VMSSH {
    param([string[]]$Tokens)

    Assert-Command "ssh"

    $user = Get-OptionValue -Tokens $Tokens -Names @('--user', '-u') -Default 'a11ydevs'
    $port = Get-OptionValue -Tokens $Tokens -Names @('--port', '-p') -Default '2222'

    $extraStart = [Array]::IndexOf($Tokens, '--')
    $extra = @()
    if ($extraStart -ge 0 -and ($extraStart + 1) -lt $Tokens.Length) {
        $extra = $Tokens[($extraStart + 1)..($Tokens.Length - 1)]
    }

    Write-EA11Info "Abrindo SSH para $user@localhost:$port"
    & ssh -p $port "$user@localhost" @extra
}

function Invoke-ShareFolderAdd {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $path = Get-OptionValue -Tokens $Tokens -Names @('--path', '-p') -Default ''
    $name = Get-OptionValue -Tokens $Tokens -Names @('--name') -Default 'host-home'
    $readonly = Has-Flag -Tokens $Tokens -Flags @('--readonly', '-r')

    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "Use --path para informar a pasta do host."
    }

    $args = @('sharedfolder', 'add', $vmName, '--name', $name, '--hostpath', $path, '--automount')
    if ($readonly) {
        $args += '--readonly'
    }

    Write-EA11Info "Adicionando shared folder '$name' na VM '$vmName'"
    & VBoxManage @args
}

function Invoke-ShareFolderRemove {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    $name = Get-OptionValue -Tokens $Tokens -Names @('--name') -Default ''

    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Use --name para remover uma shared folder."
    }

    Write-EA11Info "Removendo shared folder '$name' da VM '$vmName'"
    & VBoxManage sharedfolder remove $vmName --name $name
}

function Invoke-ShareFolderList {
    param([string[]]$Tokens)
    Ensure-VBoxManage

    $vmName = Get-VMName -Tokens $Tokens
    & VBoxManage showvminfo $vmName | Select-String 'Shared folders:' -Context 0,20
}

function Invoke-VMShareFolder {
    param([string[]]$Tokens)

    if ($Tokens.Length -eq 0) {
        throw "Uso: ea11ctl vm share-folder <add|remove|list> [opcoes]"
    }

    $action = $Tokens[0]
    $rest = @()
    if ($Tokens.Length -gt 1) {
        $rest = $Tokens[1..($Tokens.Length - 1)]
    }

    switch ($action) {
        'add' { Invoke-ShareFolderAdd -Tokens $rest }
        'remove' { Invoke-ShareFolderRemove -Tokens $rest }
        'list' { Invoke-ShareFolderList -Tokens $rest }
        default { throw "Acao desconhecida de share-folder: $action" }
    }
}

function Invoke-HostInstall {
    param([string[]]$InstallArgs)
    
    # Host install é apenas disponível em sistemas Linux/macOS nativo
    # Windows deve usar VM, pois não há pacotes Debian/Ubuntu nativos
    throw @"
Erro: 'host install' nao eh suportado no Windows.

No Windows, use apenas:
  ea11ctl vm install (baixa a imagem VM Debian pre-configurada)
  ea11ctl vm start    (inicia a VM com Emacs + espeakup)

A instalacao nativa (host install) eh suportada apenas em:
  - Linux com Debian 11+/Ubuntu 20.04+
  - macOS (com bash shell nativo)

Se desejar testar host install no Windows, considere usar WSL2:
  1. Instale Windows Subsystem for Linux (WSL2)
  2. Instale Debian ou Ubuntu dentro do WSL
  3. Execute: ea11ctl host install

Mais informacoes: https://learn.microsoft.com/pt-br/windows/wsl/
"@
}

function Invoke-HostCommand {
    param([string[]]$Tokens)
    
    if ($Tokens.Length -eq 0) {
        throw "Uso: ea11ctl host <install>"
    }
    
    $sub = $Tokens[0]
    $rest = @()
    if ($Tokens.Length -gt 1) {
        $rest = $Tokens[1..($Tokens.Length - 1)]
    }
    
    switch ($sub) {
        { $_ -in @('install', '-i') } {
            Invoke-HostInstall -InstallArgs $rest
        }
        default {
            throw "Subcomando host desconhecido: $sub"
        }
    }
}

function Invoke-VMCommand {
    param([string[]]$Tokens)

    Assert-NoBackendOption -Tokens $Tokens
    $cleanTokens = $Tokens

    if ($cleanTokens.Length -eq 0) {
        throw "Uso: ea11ctl vm <install|list|start|stop|close|remove|config|optimize|diagnose|status|ssh>"
    }

    $sub = $cleanTokens[0]
    $rest = @()
    if ($cleanTokens.Length -gt 1) {
        $rest = $cleanTokens[1..($cleanTokens.Length - 1)]
    }

    switch ($sub) {
        { $_ -in @('install', '-i') } {
            Invoke-VMInstall -InstallArgs $rest
        }
        { $_ -in @('list', '-l') } {
            Invoke-QemuVMList
        }
        { $_ -in @('start', '-s') } {
            Invoke-QemuVMStart -Tokens $rest
        }
        { $_ -in @('stop', '-S') } {
            Invoke-QemuVMStop -Tokens $rest
        }
        { $_ -in @('close', '-c') } {
            Invoke-QemuVMStop -Tokens $rest
        }
        { $_ -in @('remove', '-r', 'delete') } {
            Invoke-QemuVMRemove -Tokens $rest
        }
        'config' {
            Invoke-QemuVMConfig -Tokens $rest
        }
        'optimize' {
            Invoke-QemuVMOptimize
        }
        { $_ -in @('diagnose', '-d') } {
            Invoke-QemuVMDiagnose -Tokens $rest
        }
        { $_ -in @('status', '-q') } {
            Invoke-QemuVMStatus -Tokens $rest
        }
        { $_ -in @('ssh', '-x') } {
            Invoke-QemuVMSSH -Tokens $rest
        }
        default { throw "Subcomando vm desconhecido: $sub" }
    }
}

try {
    if ($Args.Length -eq 0) {
        Show-Help
        exit 0
    }

    $root = $Args[0]
    $rest = @()
    if ($Args.Length -gt 1) {
        $rest = $Args[1..($Args.Length - 1)]
    }

    switch ($root) {
        'help' { Show-Help }
        '--help' { Show-Help }
        '-h' { Show-Help }
        'version' { Invoke-VersionCommand -Tokens $rest }
        '--version' { Invoke-VersionCommand -Tokens $rest }
        'self-update' { Invoke-SelfUpdate -Tokens $rest }
        'update' { Invoke-SelfUpdate -Tokens $rest }
        'uninstall' { Invoke-Uninstall -Tokens $rest }
        'vm' { Invoke-VMCommand -Tokens $rest }
        'host' { Invoke-HostCommand -Tokens $rest }
        default {
            throw "Comando desconhecido: $root"
        }
    }
}
catch {
    Write-EA11Error $_.Exception.Message
    Write-Host ''
    Show-Help
    exit 1
}