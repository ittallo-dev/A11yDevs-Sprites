[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

# Bootstrap UTF-8 BOM para Windows PowerShell 5:
# sem BOM, o PS5 interpreta o arquivo como ANSI e corrompe todos os literais acentuados.
# Ao detectar a ausência de BOM em PS5, re-salva o próprio script com BOM e pede para re-executar.
if ($PSVersionTable.PSVersion.Major -lt 6 -and $PSCommandPath) {
    $selfBytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
    $hasBom = ($selfBytes.Length -ge 3 -and $selfBytes[0] -eq 0xEF -and $selfBytes[1] -eq 0xBB -and $selfBytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $withBom = New-Object byte[] ($bom.Length + $selfBytes.Length)
        [Array]::Copy($bom, $withBom, $bom.Length)
        [Array]::Copy($selfBytes, 0, $withBom, $bom.Length, $selfBytes.Length)
        [System.IO.File]::WriteAllBytes($PSCommandPath, $withBom)
        Write-Host '[ea11ctl] Arquivo atualizado para UTF-8. Execute o comando novamente.' -ForegroundColor Yellow
        exit 0
    }
}

# Garante UTF-8 para exibição correta de caracteres acentuados
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$script:IsInteractiveShell = $false
$EA11CTL_FALLBACK_VERSION = '0.1.37'
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
  ea11ctl (abre modo interativo)
  ea11ctl help|-h|--help
  ea11ctl version|--version [-c|--check-update]
  ea11ctl self-update|update [-f|--force]
  ea11ctl uninstall [--purge-state] [--yes] [--force-repo-path]
  
  ea11ctl vm install|-i
  ea11ctl vm list|-l
    ea11ctl vm start|-s [-n|--name VM] [-h|--headless] [--debug]
  ea11ctl vm stop|-S [-n|--name VM] [-f|--force]
  ea11ctl vm close|-c [-n|--name VM]
  ea11ctl vm remove|-r|delete [-n|--name VM] [--data] [--system] [--all] [--force] [--yes]
  ea11ctl vm host-share|-H list
    ea11ctl vm config [show|--raw|list|path|reset|help]
    ea11ctl vm config get CHAVE [--raw]
    ea11ctl vm config set CHAVE VALOR
    ea11ctl vm config set CHAVE=VALOR [CHAVE=VALOR ...]
  ea11ctl vm optimize
  ea11ctl vm diagnose|-d [-n|--name VM] [-L|--lines N]
  ea11ctl vm status|-q [-n|--name VM]
  ea11ctl vm ssh|-x [-u|--user USER] [-p|--port PORT] [-- extra-args]

Nota: Dentro da VM (guest context), execute: ea11ctl share
Debug: use EA11_DEBUG=1 ou passe --debug em vm start
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

        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        foreach ($file in $files) {
            $src = Join-Path $tmpDir $file
            $dst = Join-Path $installDir $file
            if ($file -like '*.ps1') {
                # Garante UTF-8 BOM para Windows PowerShell 5.x (sem BOM, PS5 lê como ANSI)
                $bytes = [System.IO.File]::ReadAllBytes($src)
                $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                if (-not $hasBom) {
                    $withBom = New-Object byte[] ($bom.Length + $bytes.Length)
                    [Array]::Copy($bom, $withBom, $bom.Length)
                    [Array]::Copy($bytes, 0, $withBom, $bom.Length, $bytes.Length)
                    [System.IO.File]::WriteAllBytes($dst, $withBom)
                } else {
                    [System.IO.File]::WriteAllBytes($dst, $bytes)
                }
            } else {
                Copy-Item -Path $src -Destination $dst -Force
            }
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
    return (Join-Path (Get-QemuStateDirectory) 'config.env')
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
        QEMU_ACCEL        = $accel
        QEMU_CPU_MODEL    = $cpuModel
        QEMU_CPUS         = 4
        QEMU_MEMORY_MB    = 4096
        QEMU_NET_DEVICE   = 'virtio-net-pci'
        QEMU_DISK_IF      = 'virtio'
        QEMU_DISK_CACHE   = 'writeback'
        QEMU_DISK_DISCARD = 'unmap'
        QEMU_VIDEO_DEVICE = 'virtio-vga'
        QEMU_FULLSCREEN   = 'on'
    }
}

function Get-QemuRuntimeConfig {
    $defaults = Get-DefaultQemuRuntimeConfig
    $cfgPath = Get-QemuRuntimeConfigPath
    $cfgDir = [System.IO.Path]::GetDirectoryName($cfgPath)
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

    if (-not (Test-Path $cfgPath)) {
        return $defaults
    }

    try {
        $merged = @{}
        foreach ($k in $defaults.Keys) { $merged[$k] = $defaults[$k] }

        foreach ($line in (Get-Content -Path $cfgPath -ErrorAction Stop)) {
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            $eqIdx = $line.IndexOf('=')
            if ($eqIdx -lt 0) { continue }
            $key = $line.Substring(0, $eqIdx).Trim()
            $val = $line.Substring($eqIdx + 1).Trim()
            if ($merged.ContainsKey($key)) { $merged[$key] = $val }
        }
        return $merged
    }
    catch {
        Write-EA11Warn "Falha ao ler config runtime em $cfgPath. Usando defaults."
        return $defaults
    }
}

function Save-QemuRuntimeConfig {
    param([hashtable]$Config)

    $cfgPath = Get-QemuRuntimeConfigPath
    $cfgDir = [System.IO.Path]::GetDirectoryName($cfgPath)
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $lines = @('# Configuracao de runtime do QEMU para ea11ctl', '# Edite com cuidado. Valores invalidos podem impedir o boot.')
    foreach ($key in ($Config.Keys | Sort-Object)) {
        $lines += "$key=$($Config[$key])"
    }
    ($lines -join "`n") + "`n" | Set-Content -Path $cfgPath -Encoding utf8
}

function Show-QemuRuntimeConfig {
    $config = Get-QemuRuntimeConfig
    foreach ($key in ($config.Keys | Sort-Object)) {
        Write-Host "$key=$($config[$key])"
    }
}

################################################################################
# Mapeamento de chaves amigáveis para o schema QEMU_* de config
################################################################################

$Script:ConfigKeyMap = @{
    'accel'         = 'QEMU_ACCEL'
    'cpu-model'     = 'QEMU_CPU_MODEL'
    'cpus'          = 'QEMU_CPUS'
    'memory'        = 'QEMU_MEMORY_MB'
    'net-device'    = 'QEMU_NET_DEVICE'
    'disk-if'       = 'QEMU_DISK_IF'
    'disk-cache'    = 'QEMU_DISK_CACHE'
    'disk-discard'  = 'QEMU_DISK_DISCARD'
    'video'         = 'QEMU_VIDEO_DEVICE'
    'fullscreen'    = 'QEMU_FULLSCREEN'
    # aliases PT-BR
    'memoria'       = 'QEMU_MEMORY_MB'
    'memória'       = 'QEMU_MEMORY_MB'
    'processadores' = 'QEMU_CPUS'
    'tela-cheia'    = 'QEMU_FULLSCREEN'
    'rede'          = 'QEMU_NET_DEVICE'
    'vídeo'         = 'QEMU_VIDEO_DEVICE'
    'video-pt'      = 'QEMU_VIDEO_DEVICE'
}

$Script:ConfigInternalKeys = @(
    'accel', 'cpu-model', 'cpus', 'memory', 'net-device',
    'disk-if', 'disk-cache', 'disk-discard', 'video', 'fullscreen'
)

function Get-ConfigInternalKey {
    param([string]$FriendlyKey)
    $k = $FriendlyKey.ToLowerInvariant()
    if ($Script:ConfigKeyMap.ContainsKey($k)) {
        return $Script:ConfigKeyMap[$k]
    }
    return $null
}

function Get-ConfigFriendlyLabel {
    param([string]$FriendlyKey)
    switch ($FriendlyKey) {
        'accel'       { return 'Aceleração' }
        'cpu-model'   { return 'Modelo de CPU' }
        'cpus'        { return 'CPUs' }
        'memory'      { return 'Memória (MB)' }
        'net-device'  { return 'Dispositivo de rede' }
        'disk-if'     { return 'Interface de disco' }
        'disk-cache'  { return 'Cache de disco' }
        'disk-discard'{ return 'Descarte/TRIM' }
        'video'       { return 'Dispositivo de vídeo' }
        'fullscreen'  { return 'Tela cheia' }
        default       { return $FriendlyKey }
    }
}

function Get-ConfigFriendlyDescription {
    param([string]$FriendlyKey)
    switch ($FriendlyKey) {
        'accel'       { return 'Aceleração de hardware usada pelo QEMU.' }
        'cpu-model'   { return 'Modelo de CPU exposto para a VM.' }
        'cpus'        { return 'Quantidade de CPUs virtuais.' }
        'memory'      { return 'Memória RAM da VM, em MB.' }
        'net-device'  { return 'Dispositivo de rede virtual.' }
        'disk-if'     { return 'Interface do disco principal.' }
        'disk-cache'  { return 'Política de cache do disco.' }
        'disk-discard'{ return 'Política de descarte/TRIM do disco.' }
        'video'       { return 'Dispositivo de vídeo virtual.' }
        'fullscreen'  { return 'Inicia a VM em tela cheia.' }
        default       { return $FriendlyKey }
    }
}

function Format-FullscreenLabel {
    param([string]$Value)
    if ($Value -eq 'on') { return 'ativado' }
    if ($Value -eq 'off') { return 'desativado' }
    return $Value
}

function ConvertTo-FullscreenNormalized {
    param([string]$Value)
    switch ($Value.ToLowerInvariant()) {
        { $_ -in 'on','true','yes','1','ligado' }   { return 'on' }
        { $_ -in 'off','false','no','0','desligado' }{ return 'off' }
        default { return $null }
    }
}

function Get-QemuDesktopDisplayArgs {
    param([string]$FullscreenMode)

    $normalized = ConvertTo-FullscreenNormalized -Value $FullscreenMode
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = 'on'
    }

    if (Test-IsMacOSHost) {
        return @('-display', "cocoa,zoom-to-fit=on,full-screen=$normalized", '-k', 'en-us')
    }

    if (Test-IsWindowsHost) {
        if ($normalized -eq 'on') {
            return @('-display', 'sdl', '-full-screen')
        }
        return @('-display', 'sdl')
    }

    return @()
}

function Assert-ConfigValue {
    # Valida e retorna valor normalizado, ou $null em erro.
    param([string]$FriendlyKey, [string]$Value)
    switch ($FriendlyKey) {
        'cpus' {
            if ($Value -match '^[1-9][0-9]*$') {
                $limit = Get-ConfigHostLimitInfo -FriendlyKey 'cpus'
                if (($null -ne $limit) -and ([int]$Value -gt [int]$limit.Max)) {
                    Write-Host "Erro: valor acima do máximo disponível para 'cpus'." -ForegroundColor Red
                    Write-Host ''
                    Write-Host "Valor recebido: $Value"
                    Write-Host "Máximo disponível: $($limit.Max) ($($limit.Label))"
                    Write-Host ''
                    Write-Host 'Exemplos:'
                    Write-Host '  ea11ctl vm config set cpus 2'
                    Write-Host '  ea11ctl vm config set cpus 4'
                    return $null
                }
                return $Value
            }
            Write-Host "Erro: valor inválido para 'cpus'." -ForegroundColor Red
            Write-Host ''
            Write-Host "Valor recebido: $Value"
            Write-Host 'Formato esperado: número inteiro positivo.'
            $limit = Get-ConfigHostLimitInfo -FriendlyKey 'cpus'
            if ($null -ne $limit) {
                Write-Host "Máximo disponível: $($limit.Max) ($($limit.Label))"
            }
            Write-Host ''
            Write-Host 'Exemplos:'
            Write-Host '  ea11ctl vm config set cpus 2'
            Write-Host '  ea11ctl vm config set cpus 4'
            Write-Host '  ea11ctl vm config set cpus 8'
            return $null
        }
        'memory' {
            if ($Value -match '^[1-9][0-9]*$') {
                $limit = Get-ConfigHostLimitInfo -FriendlyKey 'memory'
                if (($null -ne $limit) -and ([int]$Value -gt [int]$limit.Max)) {
                    Write-Host "Erro: valor acima do máximo disponível para 'memory'." -ForegroundColor Red
                    Write-Host ''
                    Write-Host "Valor recebido: $Value MB"
                    Write-Host "Máximo disponível: $($limit.Max) $($limit.Unit) ($($limit.Label))"
                    Write-Host ''
                    Write-Host 'Exemplos:'
                    Write-Host '  ea11ctl vm config set memory 2048'
                    Write-Host '  ea11ctl vm config set memory 4096'
                    return $null
                }
                return $Value
            }
            Write-Host "Erro: valor inválido para 'memory'." -ForegroundColor Red
            Write-Host ''
            Write-Host "Valor recebido: $Value"
            Write-Host 'Formato esperado: número inteiro positivo em MB.'
            $limit = Get-ConfigHostLimitInfo -FriendlyKey 'memory'
            if ($null -ne $limit) {
                Write-Host "Máximo disponível: $($limit.Max) $($limit.Unit) ($($limit.Label))"
            }
            Write-Host ''
            Write-Host 'Exemplos:'
            Write-Host '  ea11ctl vm config set memory 2048'
            Write-Host '  ea11ctl vm config set memory 4096'
            Write-Host '  ea11ctl vm config set memory 8192'
            return $null
        }
        'fullscreen' {
            $norm = ConvertTo-FullscreenNormalized -Value $Value
            if ($null -ne $norm) { return $norm }
            Write-Host "Erro: valor inválido para 'fullscreen'." -ForegroundColor Red
            Write-Host ''
            Write-Host "Valor recebido: $Value"
            Write-Host 'Valores aceitos: on, off, true, false, yes, no, 1, 0, ligado, desligado'
            Write-Host ''
            Write-Host 'Exemplos:'
            Write-Host '  ea11ctl vm config set fullscreen on'
            Write-Host '  ea11ctl vm config set fullscreen off'
            return $null
        }
        'accel' {
            $valid = @('hvf','kvm','tcg','whpx','none')
            if ($valid -contains $Value.ToLowerInvariant()) { return $Value.ToLowerInvariant() }
            Write-Host "Erro: valor inválido para 'accel'." -ForegroundColor Red
            Write-Host ''
            Write-Host "Valor recebido: $Value"
            Write-Host 'Valores conhecidos: hvf, kvm, tcg, whpx, none'
            Write-Host ''
            Write-Host 'Exemplos:'
            Write-Host '  ea11ctl vm config set accel hvf'
            Write-Host '  ea11ctl vm config set accel kvm'
            Write-Host '  ea11ctl vm config set accel tcg'
            return $null
        }
        default { return $Value }
    }
}

function Show-QemuRuntimeConfigFriendly {
    $cfgPath = Get-QemuRuntimeConfigPath
    $cfgDir = [System.IO.Path]::GetDirectoryName($cfgPath)
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $cfg = Get-QemuRuntimeConfig

    Write-Host 'Configuração da VM'
    Write-Host ''
    Write-Host 'Arquivo:'
    Write-Host "  $cfgPath"
    Write-Host ''
    Write-Host 'Desempenho:'
    Write-Host "  CPUs: $($cfg['QEMU_CPUS'])"
    $cpuLimit = Get-ConfigHostLimitInfo -FriendlyKey 'cpus'
    if ($null -ne $cpuLimit) {
        Write-Host "  Máximo disponível no host: $($cpuLimit.Max)"
    }
    Write-Host "  Memória: $($cfg['QEMU_MEMORY_MB']) MB"
    $memoryLimit = Get-ConfigHostLimitInfo -FriendlyKey 'memory'
    if ($null -ne $memoryLimit) {
        Write-Host "  Máximo disponível no host: $($memoryLimit.Max) MB"
    }
    Write-Host "  Aceleração: $($cfg['QEMU_ACCEL'])"
    Write-Host "  Modelo de CPU: $($cfg['QEMU_CPU_MODEL'])"
    Write-Host ''
    Write-Host 'Vídeo:'
    Write-Host "  Dispositivo: $($cfg['QEMU_VIDEO_DEVICE'])"
    Write-Host "  Tela cheia: $(Format-FullscreenLabel $cfg['QEMU_FULLSCREEN'])"
    Write-Host ''
    Write-Host 'Disco:'
    Write-Host "  Interface: $($cfg['QEMU_DISK_IF'])"
    Write-Host "  Cache: $($cfg['QEMU_DISK_CACHE'])"
    Write-Host "  Descarte/TRIM: $($cfg['QEMU_DISK_DISCARD'])"
    Write-Host ''
    Write-Host 'Rede:'
    Write-Host "  Dispositivo: $($cfg['QEMU_NET_DEVICE'])"
}

function Show-QemuConfigList {
    $cfg = Get-QemuRuntimeConfig
    Write-Host 'Configurações disponíveis:'
    foreach ($fkey in $Script:ConfigInternalKeys) {
        $internalKey = Get-ConfigInternalKey -FriendlyKey $fkey
        $currentVal = $cfg[$internalKey]
        $description = Get-ConfigFriendlyDescription -FriendlyKey $fkey
        Write-Host ''
        Write-Host $fkey
        Write-Host "  Descrição: $description"
        Write-Host "  Chave interna: $internalKey"
        Write-Host "  Valor atual: $currentVal"
        $limit = Get-ConfigHostLimitInfo -FriendlyKey $fkey
        if ($null -ne $limit) {
            $unitSuffix = if ([string]::IsNullOrWhiteSpace($limit.Unit)) { '' } else { " $($limit.Unit)" }
            Write-Host "  Máximo disponível: $($limit.Max)$unitSuffix ($($limit.Label))"
        }
        if ($fkey -in 'fullscreen','accel') {
            switch ($fkey) {
                'fullscreen' { Write-Host '  Valores aceitos: on, off' }
                'accel'      { Write-Host '  Valores aceitos: hvf, kvm, tcg, whpx, none' }
            }
        }
        Write-Host "  Exemplo: ea11ctl vm config set $fkey $currentVal"
    }
}

function Show-QemuConfigGet {
    param([string]$FriendlyKey, [bool]$Raw = $false)
    $internalKey = Get-ConfigInternalKey -FriendlyKey $FriendlyKey
    if ($null -eq $internalKey) {
        Write-Host "Erro: configuração desconhecida: $FriendlyKey" -ForegroundColor Red
        Write-Host ''
        Write-Host 'Use:'
        Write-Host '  ea11ctl vm config list'
        Write-Host ''
        Write-Host 'Exemplos:'
        Write-Host '  ea11ctl vm config get memory'
        Write-Host '  ea11ctl vm config get cpus'
        Write-Host '  ea11ctl vm config get fullscreen'
        return $false
    }
    $cfg = Get-QemuRuntimeConfig
    $currentVal = $cfg[$internalKey]
    if ($Raw) {
        Write-Host "$internalKey=$currentVal"
        return $true
    }
    $label = Get-ConfigFriendlyLabel -FriendlyKey $FriendlyKey
    Write-Host "${label}:"
    Write-Host "  Chave amigável: $FriendlyKey"
    Write-Host "  Chave interna: $internalKey"
    if ($FriendlyKey -eq 'memory') {
        Write-Host "  Valor atual: $currentVal MB"
    } else {
        Write-Host "  Valor atual: $currentVal"
    }
    $limit = Get-ConfigHostLimitInfo -FriendlyKey $FriendlyKey
    if ($null -ne $limit) {
        $unitSuffix = if ([string]::IsNullOrWhiteSpace($limit.Unit)) { '' } else { " $($limit.Unit)" }
        Write-Host "  Máximo disponível: $($limit.Max)$unitSuffix ($($limit.Label))"
    }
    return $true
}

function Invoke-QemuConfigSet {
    param([string[]]$Pairs)
    $cfg = Get-QemuRuntimeConfig
    $changedKeys = [System.Collections.Generic.List[string]]::new()
    $oldValues   = [System.Collections.Generic.List[string]]::new()
    $newValues   = [System.Collections.Generic.List[string]]::new()

    foreach ($pair in $Pairs) {
        $eqIdx = $pair.IndexOf('=')
        if ($eqIdx -lt 0) {
            Write-Host "Erro: argumento inválido: $pair" -ForegroundColor Red
            Write-Host 'No modo key=value, todos os argumentos devem conter "=".'
            Write-Host 'Exemplo: ea11ctl vm config set memory=8192 cpus=4 fullscreen=off'
            return $false
        }
        $fkey  = $pair.Substring(0, $eqIdx).ToLowerInvariant()
        $fval  = $pair.Substring($eqIdx + 1)
        $internalKey = Get-ConfigInternalKey -FriendlyKey $fkey
        if ($null -eq $internalKey) {
            Write-Host "Erro: configuração desconhecida: $fkey" -ForegroundColor Red
            Write-Host ''
            Write-Host 'Use:'
            Write-Host '  ea11ctl vm config list'
            Write-Host ''
            Write-Host 'Exemplos:'
            Write-Host '  ea11ctl vm config set memory 4096'
            Write-Host '  ea11ctl vm config set cpus 4'
            Write-Host '  ea11ctl vm config set fullscreen off'
            return $false
        }
        $normalized = Assert-ConfigValue -FriendlyKey $fkey -Value $fval
        if ($null -eq $normalized) { return $false }

        $changedKeys.Add($fkey)
        $oldValues.Add([string]$cfg[$internalKey])
        $newValues.Add($normalized)
        $cfg[$internalKey] = $normalized
    }

    Save-QemuRuntimeConfig -Config $cfg
    Write-Host 'Configuração atualizada.'

    for ($i = 0; $i -lt $changedKeys.Count; $i++) {
        $fkey  = $changedKeys[$i]
        $label = Get-ConfigFriendlyLabel -FriendlyKey $fkey
        Write-Host ''
        Write-Host "${label}:"
        if ($fkey -eq 'memory') {
            Write-Host "  Valor anterior: $($oldValues[$i]) MB"
            Write-Host "  Novo valor: $($newValues[$i]) MB"
        } elseif ($fkey -eq 'fullscreen') {
            Write-Host "  Valor anterior: $(Format-FullscreenLabel $oldValues[$i])"
            Write-Host "  Novo valor: $(Format-FullscreenLabel $newValues[$i])"
        } else {
            Write-Host "  Valor anterior: $($oldValues[$i])"
            Write-Host "  Novo valor: $($newValues[$i])"
        }
    }
    Write-Host ''
    Write-Host 'A alteração será aplicada na próxima vez que a VM for iniciada.'
    return $true
}

function Show-QemuConfigHelp {
    Write-Host 'ea11ctl vm config - Gerenciar configurações da VM'
    Write-Host ''
    Write-Host 'Uso:'
    Write-Host '  ea11ctl vm config                          Mostra configuração amigável'
    Write-Host '  ea11ctl vm config --raw                    Mostra variáveis técnicas (QEMU_*)'
    Write-Host '  ea11ctl vm config list                     Lista todas as chaves configuráveis'
    Write-Host '  ea11ctl vm config get CHAVE [--raw]        Consulta um valor'
    Write-Host '  ea11ctl vm config set CHAVE VALOR          Define um valor'
    Write-Host '  ea11ctl vm config set CHAVE=VALOR [...]    Define um ou mais valores'
    Write-Host '  ea11ctl vm config path                     Mostra caminho do arquivo de config'
    Write-Host '  ea11ctl vm config reset                    Reseta para valores padrão'
    Write-Host '  ea11ctl vm config help                     Mostra esta ajuda'
    Write-Host ''
    Write-Host 'Chaves disponíveis:'
    Write-Host '  cpus         memory       accel        cpu-model'
    Write-Host '  net-device   disk-if      disk-cache   disk-discard'
    Write-Host '  video        fullscreen'
    $cpuLimit = Get-ConfigHostLimitInfo -FriendlyKey 'cpus'
    if ($null -ne $cpuLimit) {
        Write-Host "  Máximo de cpus no host: $($cpuLimit.Max)"
    }
    $memoryLimit = Get-ConfigHostLimitInfo -FriendlyKey 'memory'
    if ($null -ne $memoryLimit) {
        Write-Host "  Máximo de memory no host: $($memoryLimit.Max) MB"
    }
    Write-Host ''
    Write-Host 'Exemplos:'
    Write-Host '  ea11ctl vm config set memory 4096'
    Write-Host '  ea11ctl vm config set cpus 4'
    Write-Host '  ea11ctl vm config set fullscreen off'
    Write-Host '  ea11ctl vm config set memory=8192 cpus=4 fullscreen=off'
    Write-Host '  ea11ctl vm config get memory'
    Write-Host '  ea11ctl vm config get memory --raw'
}

function Invoke-QemuVMConfig {
    param([string[]]$Tokens)

    $action = 'show'
    if ($Tokens.Length -gt 0 -and -not [string]::IsNullOrWhiteSpace($Tokens[0])) {
        $action = $Tokens[0].ToLowerInvariant()
    }

    switch ($action) {
        'show' { Show-QemuRuntimeConfigFriendly }
        '--raw' { Show-QemuRuntimeConfig }
        'list' { Show-QemuConfigList }
        'get' {
            if ($Tokens.Length -lt 2) {
                Write-Host 'Erro: informe a chave. Exemplo: ea11ctl vm config get memory' -ForegroundColor Red
                return
            }
            $raw = ($Tokens.Length -ge 3 -and $Tokens[2] -eq '--raw')
            $ok = Show-QemuConfigGet -FriendlyKey $Tokens[1].ToLowerInvariant() -Raw $raw
            if (-not $ok) {
                if ($script:IsInteractiveShell) { return }
                exit 1
            }
        }
        'set' {
            if ($Tokens.Length -lt 2) {
                Write-Host 'Erro: use: ea11ctl vm config set CHAVE VALOR' -ForegroundColor Red
                Write-Host 'Ou:   ea11ctl vm config set CHAVE=VALOR [CHAVE=VALOR ...]'
                return
            }
            $rest = $Tokens[1..($Tokens.Length - 1)]
            # Detecta modo key=value ou "CHAVE VALOR"
            if ($rest[0] -match '=') {
                $ok = Invoke-QemuConfigSet -Pairs $rest
            } else {
                if ($rest.Length -lt 2) {
                    Write-Host 'Erro: use: ea11ctl vm config set CHAVE VALOR' -ForegroundColor Red
                    return
                }
                $ok = Invoke-QemuConfigSet -Pairs @("$($rest[0])=$($rest[1])")
            }
            if (-not $ok) {
                if ($script:IsInteractiveShell) { return }
                exit 1
            }
        }
        'path' { Write-Host (Get-QemuRuntimeConfigPath) }
        'reset' {
            Save-QemuRuntimeConfig -Config (Get-DefaultQemuRuntimeConfig)
            Write-EA11Info "Configuracao resetada para defaults em $(Get-QemuRuntimeConfigPath)"
        }
        { $_ -in 'help','-h','--help' } { Show-QemuConfigHelp }
        default {
            throw "Ação de config desconhecida: $action. Use: ea11ctl vm config help"
        }
    }
}

function Invoke-QemuVMOptimize {
    $cfgPath = Get-QemuRuntimeConfigPath
    $cfgDir = [System.IO.Path]::GetDirectoryName($cfgPath)
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
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

    # Start-Process recebe ArgumentList como array. Portanto cada item abaixo ja e
    # passado como um argumento separado para o qemu-system-*.
    # Nao coloque aspas internas em file=..., mesmo quando o caminho tem espacos.
    # Aspas internas podem chegar literalmente ao QEMU e fazer o processo morrer
    # logo no start tentando abrir um caminho como "C:\...\disco.qcow2".
    $args = @(
        '-m', "$Memory",
        '-smp', "$Cpus",
        '-drive', "file=$SystemDisk,format=qcow2,if=$DiskInterface,cache=$DiskCache,discard=$DiskDiscard",
        '-drive', "file=$UserDataDisk,format=qcow2,if=$DiskInterface,cache=$DiskCache,discard=$DiskDiscard",
        '-netdev', $NetdevValue,
        '-device', "$NetDevice,netdev=net0",
        '-serial', 'none',
        '-monitor', 'none'
    )

    if (-not [string]::IsNullOrWhiteSpace($VideoDevice)) {
        $args += @('-device', $VideoDevice)
    }

    if (($HostHomeShareMode -eq '9p') -and $HostHomeShare) {
        # Mesmo motivo dos discos: nao inserir aspas internas. O argumento inteiro
        # ja e uma unica string no array do Start-Process.
        $args += @(
            '-virtfs',
            "local,path=$($HostHomeShare.HostPath),mount_tag=$($HostHomeShare.MountTag),security_model=none,id=$($HostHomeShare.MountTag)"
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

function Get-HostPhysicalMemoryMB {
    try {
        if (Test-IsWindowsHost) {
            if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                $bytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            }
            else {
                $bytes = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            }
            if ($bytes) {
                return [int]([double]$bytes / 1MB)
            }
        }
        elseif (Test-IsMacOSHost) {
            $bytes = & sysctl -n hw.memsize 2>$null
            if ($LASTEXITCODE -eq 0 -and $bytes) {
                return [int]([double]$bytes / 1MB)
            }
        }
        elseif (Test-Path '/proc/meminfo') {
            $line = Get-Content -Path '/proc/meminfo' -ErrorAction Stop | Select-String -Pattern '^MemTotal:\s+(\d+)\s+kB$' | Select-Object -First 1
            if ($line.Matches.Count -gt 0) {
                return [int]([double]$line.Matches[0].Groups[1].Value / 1024)
            }
        }
    }
    catch {
    }

    return $null
}

function Get-HostLogicalCpuCount {
    try {
        if (Test-IsWindowsHost) {
            if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                $cpuCount = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
            }
            else {
                $cpuCount = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
            }
            if ($cpuCount) {
                return [int]$cpuCount
            }
        }
        elseif (Test-IsMacOSHost) {
            $cpuCount = & sysctl -n hw.logicalcpu 2>$null
            if ($LASTEXITCODE -eq 0 -and $cpuCount) {
                return [int]$cpuCount
            }
        }
        else {
            $cpuCount = & getconf _NPROCESSORS_ONLN 2>$null
            if ($LASTEXITCODE -eq 0 -and $cpuCount) {
                return [int]$cpuCount
            }
        }
    }
    catch {
    }

    return $null
}

function Get-ConfigHostLimitInfo {
    param([string]$FriendlyKey)

    switch ($FriendlyKey) {
        'memory' {
            $max = Get-HostPhysicalMemoryMB
            if ($null -ne $max) {
                return @{ Max = $max; Unit = 'MB'; Label = 'RAM física do host' }
            }
        }
        'cpus' {
            $max = Get-HostLogicalCpuCount
            if ($null -ne $max) {
                return @{ Max = $max; Unit = ''; Label = 'CPUs lógicas do host' }
            }
        }
    }

    return $null
}

function Write-QemuArgsLog {
    param(
        [string]$Path,
        [string]$QemuExecutable,
        [string[]]$QemuArgs
    )

    $lines = @('# QEMU arguments for ea11ctl', $QemuExecutable)
    $lines += $QemuArgs
    ($lines -join [Environment]::NewLine) + [Environment]::NewLine | Set-Content -Path $Path -Encoding UTF8
}

function Show-QemuLaunchSummary {
    param(
        [string]$VMName,
        [int]$Memory,
        [int]$Cpus,
        [string]$AccelMode,
        [string]$CpuModel,
        [string]$NetDevice,
        [string]$DiskInterface,
        [string]$DiskCache,
        [string]$DiskDiscard,
        [string]$VideoDevice,
        [string]$FullscreenMode,
        [bool]$Headless,
        [int]$SshPort,
        [string]$QemuExecutable,
        [string]$ArgsLog
    )

    Write-EA11Info 'Parâmetros efetivos da inicialização:'
    Write-Host "  vm=$VMName"
    Write-Host "  memory_mb=$Memory"
    Write-Host "  cpus=$Cpus"
    Write-Host "  accel=$AccelMode"
    Write-Host "  cpu_model=$CpuModel"
    Write-Host "  net_device=$NetDevice"
    Write-Host "  disk_if=$DiskInterface"
    Write-Host "  disk_cache=$DiskCache"
    Write-Host "  disk_discard=$DiskDiscard"
    Write-Host "  video=$VideoDevice"
    Write-Host "  fullscreen=$FullscreenMode"
    Write-Host "  headless=$Headless"
    Write-Host "  ssh_port=$SshPort"
    Write-Host "  qemu=$QemuExecutable"
    Write-Host "  qemu_args_log=$ArgsLog"
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

# Criação de atalho para o start da VM facilitado
# Area de trabalho e Windows/Pesquisar

function Install-EA11VMShortcut {
    param(
        [string]$ShortcutName = 'EA11 VM.lnk',
        [string]$VMName = 'debian-a11y'
    )

    if (-not (Test-IsWindowsHost)) {
        return
    }

    try {
        Write-EA11Info "Criando atalhos da VM na Area de Trabalho e no Menu Iniciar..."

        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            $scriptPath = $MyInvocation.MyCommand.Path
        }
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            $scriptPath = Join-Path $PSScriptRoot 'ea11ctl.ps1'
        }

        if (-not (Test-Path $scriptPath)) {
            Write-EA11Warn "Nao foi possivel localizar o script ea11ctl.ps1 para criar o atalho."
            return
        }

        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $powershellExe)) {
            $powershellExe = 'powershell.exe'
        }

        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $startMenuPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $shortcutPaths = @($desktopPath, $startMenuPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $wshShell = New-Object -ComObject WScript.Shell

        foreach ($path in $shortcutPaths) {
            if (-not (Test-Path $path)) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }

            $shortcutFile = Join-Path $path $ShortcutName
            $shortcut = $wshShell.CreateShortcut($shortcutFile)
            $shortcut.TargetPath = $powershellExe
            $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" vm start --name `"$VMName`""
            $shortcut.WorkingDirectory = Split-Path -Path $scriptPath -Parent
            $shortcut.Description = 'Iniciar a VM EA11 pelo QEMU'
            $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
            $shortcut.Save()
        }

        Write-EA11Info "Atalhos criados: Area de Trabalho e Menu Iniciar/Pesquisa do Windows."
    }
    catch {
        Write-EA11Warn "Nao foi possivel criar os atalhos da VM: $($_.Exception.Message)"
    }
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
        Install-EA11VMShortcut -VMName 'debian-a11y'
        Write-EA11Info "Proximo passo: use o atalho 'EA11 VM' ou execute: ea11ctl vm start"
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
    Install-EA11VMShortcut -VMName 'debian-a11y'
    Write-EA11Info "Proximo passo: use o atalho 'EA11 VM' ou execute: ea11ctl vm start"
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

    # Detecta modo debug: EA11_DEBUG=1 ou --debug
    $debugMode = $false
    if ($env:EA11_DEBUG -eq '1' -or ($Tokens -contains '--debug')) { $debugMode = $true }

    $vmName = Get-VMName -Tokens $Tokens
    $sshPort = Get-IntOptionValue -Tokens $Tokens -Names @('--port', '--ssh-port', '-p') -Default 2222 -OptionName '--ssh-port'
    $memory = Get-IntOptionValue -Tokens $Tokens -Names @('--memory', '-m') -Default ([int]$runtimeCfg['QEMU_MEMORY_MB']) -OptionName '--memory'
    $cpus = Get-IntOptionValue -Tokens $Tokens -Names @('--cpus') -Default ([int]$runtimeCfg['QEMU_CPUS']) -OptionName '--cpus'
    $userDataSize = Get-IntOptionValue -Tokens $Tokens -Names @('--user-data-size') -Default 10 -OptionName '--user-data-size'
    $headless = Has-Flag -Tokens $Tokens -Flags @('--headless', '-h')
    $audioBackend = Get-OptionValue -Tokens $Tokens -Names @('--audio-backend') -Default 'auto'
    $accelMode = Get-OptionValue -Tokens $Tokens -Names @('--accel') -Default ([string]$runtimeCfg['QEMU_ACCEL'])
    $cpuModel = [string]$runtimeCfg['QEMU_CPU_MODEL']
    $netDevice = [string]$runtimeCfg['QEMU_NET_DEVICE']
    $diskInterface = [string]$runtimeCfg['QEMU_DISK_IF']
    $diskCache = [string]$runtimeCfg['QEMU_DISK_CACHE']
    $diskDiscard = [string]$runtimeCfg['QEMU_DISK_DISCARD']
    $videoDevice = [string]$runtimeCfg['QEMU_VIDEO_DEVICE']
    $fullscreenMode = [string]$runtimeCfg['QEMU_FULLSCREEN']
    $disableHostHomeShare = Has-Flag -Tokens $Tokens -Flags @('--no-host-home-share')
    $smbServer = Get-OptionValue -Tokens $Tokens -Names @('--smb-server') -Default $null
    $smbShare = Get-OptionValue -Tokens $Tokens -Names @('--smb-share') -Default $null
    $smbUser = Get-OptionValue -Tokens $Tokens -Names @('--smb-user') -Default $null
    $smbPassword = Get-OptionValue -Tokens $Tokens -Names @('--smb-password') -Default $null
    $qemuExecutable = Resolve-QemuSystemExecutable -Headless:$headless
    $supportedAudioDrivers = Get-QemuAvailableAudioDrivers -QemuExecutable $qemuExecutable
    $effectiveAccelMode = $accelMode
    $effectiveCpuModel = $cpuModel

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
    $argsLog = Join-Path $logsDir "$vmName-qemu-args.log"
    $debugCmdFile = Join-Path $logsDir 'last-qemu-cmd.txt'
    $debugLogFile = Join-Path $logsDir 'qemu.log'

    $hostMemoryMb = Get-HostPhysicalMemoryMB
    if (($null -ne $hostMemoryMb) -and ($memory -gt $hostMemoryMb)) {
        Write-EA11Warn "Memória configurada ($memory MB) excede a RAM física detectada do host ($hostMemoryMb MB). O QEMU ainda pode iniciar por overcommit, mas o host pode ficar instável."
    }

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
                # Mantem o comportamento resiliente no ea11ctl: quando 9p nao
                # existe, tenta SMB usernet antes de desistir do compartilhamento.
                # Se SMB quebrar em runtime, o bloco de retry abaixo ja reinicia sem share.
                $hostHomeShareMode = 'smb'
                $netdevValue = "user,id=net0,hostfwd=tcp::$sshPort-:22,smb=$($hostHomeShare.HostPath)"
                $qemuSmbShare = @{
                    Server = '10.0.2.4'
                    Share = 'qemu'
                    GuestMountPoint = $hostHomeShare.GuestMountPoint
                }
                if ($smbSupportInfo.Reason -eq 'missing-host-smb-helper') {
                    Write-EA11Warn 'virtfs/9p indisponivel. SMB usernet sera tentado, mas o helper SMB do host aparenta ausente, caso falhe, o start seguira sem share automaticamente.'
                }
                else {
                    Write-EA11Warn "virtfs/9p indisponivel neste QEMU. Usando fallback SMB (//10.0.2.4/qemu -> $($qemuSmbShare.GuestMountPoint))."
                }
            }
            elseif ($hostHomeShareMode -ne '9p') {
                if ($smbSupportInfo -and ($smbSupportInfo.Reason -eq 'missing-host-smb-helper')) {
                    Write-EA11Warn 'QEMU ate possui parametro SMB usernet, mas o helper SMB do host nao esta disponivel. VM iniciada sem compartilhamento automatico da home do host.'
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
        $qemuArgs += Get-QemuDesktopDisplayArgs -FullscreenMode $fullscreenMode

        $qemuArgs += Get-QemuAudioArgs -Backend $audioBackend -SupportedDrivers $supportedAudioDrivers
    }

    Write-EA11Info "Iniciando VM QEMU '$vmName'..."
    Write-QemuArgsLog -Path $argsLog -QemuExecutable $qemuExecutable -QemuArgs $qemuArgs
    if ($debugMode) {
        # Salva comando e log detalhado
        Set-Content -Path $debugCmdFile -Value ("$qemuExecutable " + ($qemuArgs -join ' '))
        $startParams = @{
            FilePath = $qemuExecutable
            ArgumentList = $qemuArgs
            PassThru = $true
            RedirectStandardOutput = $debugLogFile
            RedirectStandardError = $debugLogFile
        }
    } else {
        $startParams = @{
            FilePath = $qemuExecutable
            ArgumentList = $qemuArgs
            PassThru = $true
            RedirectStandardOutput = $stdoutLog
            RedirectStandardError = $stderrLog
        }
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
                $qemuArgs += Get-QemuDesktopDisplayArgs -FullscreenMode $fullscreenMode

                $qemuArgs += Get-QemuAudioArgs -Backend $audioBackend -SupportedDrivers $supportedAudioDrivers
            }

            Write-QemuArgsLog -Path $argsLog -QemuExecutable $qemuExecutable -QemuArgs $qemuArgs
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
            $effectiveAccelMode = 'tcg'

            $qemuArgs = New-QemuBaseArgs -Memory $memory -Cpus $cpus -SystemDisk $systemDisk -UserDataDisk $userDataDisk -NetdevValue $netdevValue -NetDevice $netDevice -DiskInterface $diskInterface -DiskCache $diskCache -DiskDiscard $diskDiscard -VideoDevice $videoDevice -HostHomeShare $hostHomeShare -HostHomeShareMode $hostHomeShareMode -HostUser $hostUserForGuest

            $qemuArgs += Get-QemuAccelerationArgs -Mode 'tcg' -CpuModel $cpuModel

            if ($headless) {
                $qemuArgs += @('-nographic', '-serial', 'stdio')
            }
            else {
                $qemuArgs += Get-QemuDesktopDisplayArgs -FullscreenMode $fullscreenMode

                $qemuArgs += Get-QemuAudioArgs
            }

            Write-QemuArgsLog -Path $argsLog -QemuExecutable $qemuExecutable -QemuArgs $qemuArgs
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
                $qemuArgs += Get-QemuDesktopDisplayArgs -FullscreenMode $fullscreenMode

                $qemuArgs += Get-QemuAudioArgs -Backend $fallbackAudio -SupportedDrivers $supportedAudioDrivers
            }

            Write-QemuArgsLog -Path $argsLog -QemuExecutable $qemuExecutable -QemuArgs $qemuArgs
            $startParams.ArgumentList = $qemuArgs
            $proc = Start-Process @startParams
            Start-Sleep -Seconds 2
            $alive = Get-ProcessByIdSafe -ProcessId $proc.Id
        }
    }

    if (-not $alive) {
        $lastError = ''
        if ($debugMode -and (Test-Path $debugLogFile)) {
            $lastError = (Get-Content -Path $debugLogFile -Tail 40 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
            Write-EA11Error "Falha ao iniciar QEMU para '$vmName'."
            Write-EA11Error "Veja o comando usado em: $debugCmdFile"
            Write-EA11Error "Veja o log detalhado em: $debugLogFile"
            Write-Host $lastError
            throw "Falha ao iniciar QEMU para '$vmName'. Veja logs em $debugLogFile e comando em $debugCmdFile."
        } elseif (Test-Path $stderrLog) {
            $lastError = (Get-Content -Path $stderrLog -Tail 20 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
            throw "Falha ao iniciar QEMU para '$vmName'. Log: $stderrLog`n$lastError"
        } else {
            throw "Falha ao iniciar QEMU para '$vmName'."
        }
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
        qemuArgsLog = $argsLog
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
    Show-QemuLaunchSummary -VMName $vmName -Memory $memory -Cpus $cpus -AccelMode $effectiveAccelMode -CpuModel $effectiveCpuModel -NetDevice $netDevice -DiskInterface $diskInterface -DiskCache $diskCache -DiskDiscard $diskDiscard -VideoDevice $videoDevice -FullscreenMode $fullscreenMode -Headless:$headless -SshPort $sshPort -QemuExecutable $qemuExecutable -ArgsLog $argsLog
    Write-Host "SSH: localhost:$sshPort"
    Write-Host "Sistema: $systemDisk"
    Write-Host "Dados (/home): $userDataDisk"
    if (($hostHomeShareMode -eq '9p') -and $hostHomeShare) {
        Write-Host "Host home (9p): $($hostHomeShare.HostPath) -> $($hostHomeShare.GuestMountPoint)"
    }
    elseif (($hostHomeShareMode -eq 'smb') -and $hostHomeShare -and $qemuSmbShare) {
        $guestMount = if ($hostHomeGuestMountPoint) { [string]$hostHomeGuestMountPoint } else { '/home/hosthome' }
        Write-Host "Host home (SMB): $($hostHomeShare.HostPath) -> //$($qemuSmbShare.Server)/$($qemuSmbShare.Share) -> $guestMount"
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

    # Evita conflito com chaves antigas gravadas para [localhost]:2222.
    # Cada VM/porta passa a ter uma identidade SSH propria.
    $hostKeyAlias = "ea11ctl-$vmName-$port"

    $homeDir = Get-HomeDirectoryPath
    $sshDir = Join-Path $homeDir '.ssh'
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    $knownHostsFile = Join-Path $sshDir 'known_hosts_ea11ctl'

    Write-EA11Info "Abrindo SSH para $user@localhost:$port"

    & ssh `
        -p $port `
        -o "HostKeyAlias=$hostKeyAlias" `
        -o "UserKnownHostsFile=$knownHostsFile" `
        -o "CheckHostIP=no" `
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

        # Fechamento gracioso: evita corromper estado interno do Qemu.
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

function Invoke-VMHostShare {
    param([string[]]$Tokens)

    if ($null -eq $Tokens -or $Tokens.Length -eq 0) {
        $Tokens = @('list')
    }

    $action = $Tokens[0]
    switch ($action) {
        'list' {
            $rest = @()
            if ($Tokens.Length -gt 1) {
                $rest = $Tokens[1..($Tokens.Length - 1)]
            }
            Invoke-VMShareFolder -Tokens (@('list') + $rest)
        }
        default {
            throw "Acao desconhecida de host-share: $action. Use: ea11ctl vm host-share list"
        }
    }
}

function Invoke-HostInstall {
    param([string[]]$InstallArgs)
    
    # Host install é apenas disponível em sistemas Linux/macOS nativo
    # Windows deve usar VM, pois não há pacotes Debian/Ubuntu nativos
    throw @"
Erro: 'host install' nao e suportado no Windows.

No Windows, use apenas:
  ea11ctl vm install (baixa a imagem VM Debian pre-configurada)
  ea11ctl vm start    (inicia a VM com Emacs + espeakup)

A instalacao nativa (host install) e suportada apenas em:
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
        { $_ -in @('share-folder', '-F') } {
            Invoke-VMShareFolder -Tokens $rest
        }
        { $_ -in @('host-share', '-H') } {
            Invoke-VMHostShare -Tokens $rest
        }
        default { throw "Subcomando vm desconhecido: $sub" }
    }
}

function Invoke-RootCommand {
    param([string[]]$Tokens)

    if ($null -eq $Tokens -or $Tokens.Length -eq 0) {
        Show-Help
        return
    }

    $root = $Tokens[0]
    $rest = @()
    if ($Tokens.Length -gt 1) {
        $rest = $Tokens[1..($Tokens.Length - 1)]
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

function Get-InteractivePrompt {
    param([string]$Context)

    switch ($Context) {
        'vm' { return 'ea11ctl vm> ' }
        'vm_config' { return 'ea11ctl vm config> ' }
        'vm_host_share' { return 'ea11ctl vm host-share> ' }
        'host' { return 'ea11ctl host> ' }
        default { return 'ea11ctl> ' }
    }
}

function Show-InteractiveContextHelp {
    param([string]$Context)

    switch ($Context) {
        'vm' {
            @"
Comandos de VM:

install        instala a VM
list           lista VMs
start          inicia a VM
stop           para a VM
close          fecha a VM
remove         remove a VM
delete         remove a VM (alias)
diagnose       diagnostica a VM
status         mostra status da VM
ssh            conecta via SSH
host-share     entra em compartilhamento do host
config         entra em configuração da VM
optimize       otimiza a VM
debug          ativa/desativa debug da sessão (on|off|status)
back           volta
exit           sai

Exemplos:

status
start --headless
start --debug
diagnose -T -L 80
ssh
"@ | Write-Host
        }
        'vm_config' {
            @"
Configuração da VM:

show     mostra configuração amigável
--raw    mostra configuração técnica (QEMU_*)
list     lista chaves configuráveis
get      consulta um valor (ex.: get memory)
set      altera um valor (ex.: set memory 4096)
path     mostra caminho da configuração
reset    redefine configuração da VM
help     mostra ajuda do vm config
back     volta
exit     sai

Exemplos:

show
--raw
list
get memory
set memory 8192
set memory=8192 cpus=4 fullscreen=off
path
reset
"@ | Write-Host
        }
        'vm_host_share' {
            @"
Compartilhamento do host:

list     lista compartilhamentos
back     volta
exit     sai

Exemplo:

list
"@ | Write-Host
        }
        'host' {
            @"
Instalação nativa no host:

install  inicia a instalação nativa
back     volta
exit     sai

Exemplo:

install
"@ | Write-Host
        }
        default {
            @"
Comandos disponíveis:

version       mostra a versão do ea11ctl
self-update   atualiza o ea11ctl
update        alias de self-update
uninstall     desinstala a CLI local
vm            entra no contexto de VM
host          entra no contexto de instalação nativa
status        mostra o status da VM padrão
debug         ativa/desativa debug da sessão (on|off|status)
clear         limpa a tela
exit          sai

Exemplos:

vm
vm status
vm start --headless
debug on
self-update -f
"@ | Write-Host
        }
    }
}

function Get-ContextCommandList {
    param([string]$Context)

    switch ($Context) {
        'vm' { return @('help','?','install','list','start','stop','close','remove','delete','diagnose','status','ssh','host-share','config','optimize','debug','back','exit','quit','clear') }
        'vm_config' { return @('help','?','show','--raw','list','get','set','path','reset','debug','back','exit','quit','clear') }
        'vm_host_share' { return @('help','?','list','debug','back','exit','quit','clear') }
        'host' { return @('help','?','install','debug','back','exit','quit','clear') }
        default { return @('help','?','version','self-update','update','uninstall','vm','host','status','debug','clear','exit','quit') }
    }
}

function Set-InteractiveDebugMode {
    param([string]$Mode = 'status')

    switch ($Mode.ToLowerInvariant()) {
        { $_ -in @('on','1','true') } {
            $env:EA11_DEBUG = '1'
            Write-Host 'DEBUG ativado para esta sessão interativa.'
        }
        { $_ -in @('off','0','false') } {
            Remove-Item Env:EA11_DEBUG -ErrorAction SilentlyContinue
            Write-Host 'DEBUG desativado para esta sessão interativa.'
        }
        'status' {
            if ($env:EA11_DEBUG -eq '1') {
                Write-Host 'DEBUG está ativado.'
            }
            else {
                Write-Host 'DEBUG está desativado.'
            }
        }
        default {
            Write-Host "Valor inválido para debug: $Mode"
            Write-Host 'Use: debug on | debug off | debug status'
        }
    }
}

function Show-CommandSuggestion {
    param(
        [string]$Context,
        [string]$Typed
    )

    if ([string]::IsNullOrWhiteSpace($Typed)) {
        return
    }

    $suggestions = New-Object System.Collections.Generic.List[string]

    foreach ($cmd in (Get-ContextCommandList -Context $Context)) {
        if ($cmd.StartsWith($Typed, [System.StringComparison]::OrdinalIgnoreCase) -or
            ($cmd.IndexOf($Typed, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            $suggestions.Add($cmd)
        }
    }

    if ($suggestions.Count -gt 0) {
        Write-Host ''
        Write-Host 'Talvez você quis dizer:'
        foreach ($s in $suggestions) {
            Write-Host $s
        }
    }
}

function Test-ContextHasCommand {
    param(
        [string]$Context,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $false
    }

    foreach ($cmd in (Get-ContextCommandList -Context $Context)) {
        if ($cmd.Equals($Token, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Is-RootToken {
    param([string]$Token)

    return $Token -in @('help','?','version','--version','self-update','update','uninstall','vm','host','status','debug','clear','exit','quit')
}

function Normalize-InteractiveAliases {
    param(
        [string]$Context,
        [string[]]$Tokens
    )

    if ($null -eq $Tokens -or $Tokens.Length -eq 0) {
        return @()
    }

    $normalized = @($Tokens)

    if ($normalized[0] -eq 'update') {
        $normalized[0] = 'self-update'
    }

    if ($Context -eq 'vm' -and $normalized[0] -eq 'delete') {
        $normalized[0] = 'remove'
    }

    return $normalized
}

function Resolve-ContextCommand {
    param(
        [string]$Context,
        [string[]]$Tokens
    )

    $result = @{
        Action = 'dispatch'
        NextContext = $Context
        Command = @()
    }

    if ($null -eq $Tokens -or $Tokens.Length -eq 0) {
        $result.Action = 'noop'
        return $result
    }

    $first = $Tokens[0]
    switch ($first) {
        'help' { $result.Action = 'help'; return $result }
        '?' { $result.Action = 'help'; return $result }
        'debug' { $result.Action = 'debug_toggle'; $result.Command = @($Tokens); return $result }
        'exit' { $result.Action = 'exit'; return $result }
        'quit' { $result.Action = 'exit'; return $result }
        'clear' { $result.Action = 'clear'; return $result }
        'back' {
            $result.Action = 'back'
            switch ($Context) {
                'vm' { $result.NextContext = 'root' }
                'host' { $result.NextContext = 'root' }
                'vm_config' { $result.NextContext = 'vm' }
                'vm_host_share' { $result.NextContext = 'vm' }
                default { $result.NextContext = 'root' }
            }
            return $result
        }
        'status' {
            if ($Context -in @('root','vm')) {
                $result.Action = 'dispatch'
                $result.Command = @('vm','status')
            }
            else {
                $result.Action = 'status_unavailable'
            }
            return $result
        }
    }

    switch ($Context) {
        'root' {
            if ($first -eq 'vm' -and $Tokens.Length -eq 1) {
                $result.Action = 'enter_context'
                $result.NextContext = 'vm'
                return $result
            }
            if ($first -eq 'host' -and $Tokens.Length -eq 1) {
                $result.Action = 'enter_context'
                $result.NextContext = 'host'
                return $result
            }
            $result.Command = @($Tokens)
        }
        'vm' {
            if ($first -eq 'config' -and $Tokens.Length -eq 1) {
                $result.Action = 'enter_context'
                $result.NextContext = 'vm_config'
                return $result
            }
            if ($first -eq 'host-share' -and $Tokens.Length -eq 1) {
                $result.Action = 'enter_context'
                $result.NextContext = 'vm_host_share'
                return $result
            }

            if (Is-RootToken -Token $first) {
                $result.Command = @($Tokens)
            }
            else {
                $result.Command = @('vm') + @($Tokens)
            }
        }
        'vm_config' {
            if (Is-RootToken -Token $first -or $first -in @('vm','host')) {
                $result.Command = @($Tokens)
            }
            else {
                $result.Command = @('vm','config') + @($Tokens)
            }
        }
        'vm_host_share' {
            if (Is-RootToken -Token $first -or $first -in @('vm','host')) {
                $result.Command = @($Tokens)
            }
            else {
                if ($first -eq 'list') {
                    # No Windows atual, mapeia para share-folder list.
                    $tail = @()
                    if ($Tokens.Length -gt 1) {
                        $tail = @($Tokens[1..($Tokens.Length - 1)])
                    }
                    $result.Command = @('vm','share-folder','list') + $tail
                }
                else {
                    $result.Command = @('vm','host-share') + @($Tokens)
                }
            }
        }
        'host' {
            if (Is-RootToken -Token $first -or $first -in @('vm','host')) {
                $result.Command = @($Tokens)
            }
            else {
                $result.Command = @('host') + @($Tokens)
            }
        }
        default {
            $result.Command = @($Tokens)
        }
    }

    return $result
}

function Is-SensitiveCommand {
    param([string[]]$Command)

    if ($null -eq $Command -or $Command.Length -eq 0) {
        return $false
    }

    switch ($Command[0]) {
        'uninstall' { return $true }
        'host' {
            if ($Command.Length -ge 2 -and $Command[1] -in @('install','-i')) { return $true }
        }
        'vm' {
            if ($Command.Length -ge 2 -and $Command[1] -in @('remove','-r','delete')) { return $true }
            if ($Command.Length -ge 3 -and $Command[1] -eq 'config' -and $Command[2] -eq 'reset') { return $true }
        }
        'self-update' {
            if (-not (Has-Flag -Tokens $Command -Flags @('--force','-f'))) { return $true }
        }
    }

    return $false
}

function Show-SensitiveNotice {
    param([string[]]$Command)

    if ($Command.Length -ge 3 -and $Command[0] -eq 'vm' -and $Command[1] -eq 'config' -and $Command[2] -eq 'reset') {
        Write-Host 'Esta ação pode redefinir configurações da VM.'
        Write-Host 'Nenhuma configuração pessoal deve ser apagada sem confirmação explícita.'
        return
    }

    if ($Command.Length -ge 2 -and $Command[0] -eq 'host' -in @('install','-i')) {
        Write-Host 'Esta ação iniciará a instalação nativa no host.'
        Write-Host 'Ela pode instalar pacotes e alterar arquivos do sistema.'
        return
    }

    if ($Command.Length -ge 2 -and $Command[0] -eq 'vm' -in @('remove','-r','delete')) {
        Write-Host 'Esta ação pode remover arquivos da VM.'
        return
    }

    if ($Command[0] -eq 'uninstall') {
        Write-Host 'Esta ação pode desinstalar a CLI local.'
        return
    }

    if ($Command[0] -eq 'self-update') {
        Write-Host 'Esta ação atualiza a CLI e altera arquivos locais da instalação.'
        return
    }

    Write-Host 'Esta ação altera estado persistente.'
}

function Confirm-SensitiveCommand {
    param([string[]]$Command)

    Write-Host ''
    Write-Host 'Comando equivalente:'
    Write-Host ('ea11ctl ' + ($Command -join ' '))
    Write-Host ''
    Show-SensitiveNotice -Command $Command

    $reply = Read-Host 'Continuar? [s/N]'
    if ([string]::IsNullOrWhiteSpace($reply)) {
        Write-Host 'Ação cancelada.'
        return $false
    }

    switch ($reply.Trim().ToLowerInvariant()) {
        's' { return $true }
        'sim' { return $true }
        'y' { return $true }
        'yes' { return $true }
        default {
            Write-Host 'Ação cancelada.'
            return $false
        }
    }
}

function Start-InteractiveShell {
    Write-Host 'ea11ctl - modo interativo'
    Write-Host ''
    Write-Host 'Digite help para ver comandos.'
    Write-Host 'Digite exit para sair.'
    Write-Host ''

    $script:IsInteractiveShell = $true
    try {
        $context = 'root'
        while ($true) {
            $promptText = Get-InteractivePrompt -Context $context
            $line = Read-Host -Prompt ($promptText -replace '>\s$','')
            if ($null -eq $line) {
                break
            }

            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            # Saida imediata para comandos globais de encerramento.
            if ($trimmed -match '^(?i)\s*(exit|quit)\s*$') {
                break
            }

            # Parser simples: separa por espacos.
            $tokens = $trimmed -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $tokens = Normalize-InteractiveAliases -Context $context -Tokens $tokens
            $resolved = Resolve-ContextCommand -Context $context -Tokens $tokens

            switch ($resolved.Action) {
                'noop' { continue }
                'help' { Show-InteractiveContextHelp -Context $context; continue }
                'clear' { Clear-Host; continue }
                'exit' { break }
                'back' {
                    if ($context -eq 'root') {
                        Write-Host 'Você já está no contexto raiz.'
                    }
                    else {
                        $context = [string]$resolved.NextContext
                    }
                    continue
                }
                'enter_context' {
                    $context = [string]$resolved.NextContext
                    continue
                }
                'status_unavailable' {
                    Write-Host 'Não há status específico neste contexto.'
                    continue
                }
                'debug_toggle' {
                    $mode = 'status'
                    if ($tokens.Length -ge 2) {
                        $mode = [string]$tokens[1]
                    }
                    Set-InteractiveDebugMode -Mode $mode
                    continue
                }
            }

            $cmd = @($resolved.Command)
            if ($cmd.Length -eq 0) {
                continue
            }

            if (Is-SensitiveCommand -Command $cmd) {
                if (-not (Confirm-SensitiveCommand -Command $cmd)) {
                    continue
                }
            }

            try {
                Invoke-RootCommand -Tokens $cmd
            }
            catch {
                if (-not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                    Write-EA11Error $_.Exception.Message
                }
                if (-not (Test-ContextHasCommand -Context $context -Token $tokens[0])) {
                    Write-Host ''
                    Write-Host "Comando desconhecido: $($tokens[0])"
                    Show-CommandSuggestion -Context $context -Typed $tokens[0]
                }
                Write-Host ''
                Write-Host 'Digite help para ver os comandos disponíveis.'
            }
        }
    }
    finally {
        $script:IsInteractiveShell = $false
    }
}


if ($Args.Length -eq 0) {
    # Modo interativo: nunca sair com erro por comando inválido
    try {
        Start-InteractiveShell
    } catch {
        Write-EA11Error $_.Exception.Message
    }
    exit 0
} else {
    try {
        Invoke-RootCommand -Tokens $Args
    } catch {
        Write-EA11Error $_.Exception.Message
        Write-Host ''
        Show-Help
        exit 1
    }
}
