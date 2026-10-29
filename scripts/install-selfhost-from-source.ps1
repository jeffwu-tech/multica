#Requires -Version 5.1
<#
.SYNOPSIS
    Install (or update) a self-hosted Multica stack on Windows, built entirely from a
    git branch: PostgreSQL + backend + web in Docker, and the multica CLI/daemon.

.DESCRIPTION
    Unlike scripts/install.ps1, which pulls the official release images and CLI, this
    script builds every component from source so changes on a branch are included:

        1. clones (or fast-forwards) -RepoUrl @ -Branch into -InstallDir,
        2. creates .env with random secrets on first run (existing .env is kept),
        3. builds the backend and web images and starts the stack
           (docker-compose.selfhost.yml + docker-compose.selfhost.build.yml),
        4. builds multica.exe inside the same golang image the backend Dockerfile uses
           (no local Go toolchain needed) and installs it to %USERPROFILE%\.multica\bin,
        5. runs `multica setup self-host` (login + daemon start), or restarts the daemon
           when the CLI is already signed in to this server,
        6. with -AgentsSpec: picks (or creates) the workspace, waits for this machine's
           runtimes to register in it, and runs scripts\multica-agents.ps1 from the
           checkout to create the exported projects, agents and skills there.

    Re-run the script to update: it pulls the branch, rebuilds and restarts everything.
    Database data lives in the Docker volume and survives updates.

    Requirements: 64-bit Windows, Git, Docker Desktop (with `docker compose` v2) running.

    The official Multica Desktop app runs the multica.exe bundled inside it, so its
    daemon does NOT include branch changes. Use the standalone daemon this script
    installs (`multica daemon start|stop|status`) instead of Desktop's.

.PARAMETER RepoUrl
    Git repository to build from.

.PARAMETER Branch
    Branch to build.

.PARAMETER InstallDir
    Where the source checkout, .env and compose project live. An existing checkout
    (e.g. a dev clone whose origin is upstream) is reused: the script fetches from
    whichever remote points at -RepoUrl, adding a 'fork' remote if none does.

.PARAMETER SkipSetup
    Do not run `multica setup self-host` / restart the daemon at the end
    (also skips -AgentsSpec, which needs a signed-in CLI).

.PARAMETER Force
    Discard local changes or unpushed commits on -Branch in an existing
    -InstallDir checkout, or replace a non-git -InstallDir.

.PARAMETER AgentsSpec
    Spec written by `multica-agents.ps1 -Export` (e.g. .\agents.json). Its
    <name>.secrets.json sibling is picked up automatically. Needs PowerShell 7.3+
    (`pwsh`) installed; the import is skipped with a warning otherwise.

.PARAMETER WorkspaceId
    Workspace (ID or slug) to import -AgentsSpec into. Defaults to the only
    workspace the account belongs to.

.PARAMETER WorkspaceName
    Create a workspace with this name when the account has none yet (fresh server).

.PARAMETER WorkspaceSlug
    Slug for -WorkspaceName. Defaults to the name in lower-case with dashes.

.PARAMETER AgentsPathMap
    Passed to multica-agents.ps1 -PathMap, e.g. @{ 'C:\git\GitHub' = 'D:\src' }.

.EXAMPLE
    # Fresh machine (Windows PowerShell or PowerShell 7):
    $url = 'https://raw.githubusercontent.com/jeffwu-tech/multica/feat/shared-issue-worktree/scripts/install-selfhost-from-source.ps1'
    Invoke-WebRequest $url -OutFile .\install-selfhost-from-source.ps1
    powershell -ExecutionPolicy Bypass -File .\install-selfhost-from-source.ps1

.EXAMPLE
    # Update to the latest commit on the branch:
    .\install-selfhost-from-source.ps1

.EXAMPLE
    # Fresh server: install, create a workspace and recreate exported projects/agents:
    .\install-selfhost-from-source.ps1 -AgentsSpec .\agents.json -WorkspaceName 'WiseTech Global' -WorkspaceSlug cargowise

.EXAMPLE
    # Stop the stack (data is kept):
    docker compose -f "C:\git\GitHub\multica\docker-compose.selfhost.yml" down
#>
[CmdletBinding()]
param(
    [string] $RepoUrl = 'https://github.com/jeffwu-tech/multica.git',
    [string] $Branch = 'feat/shared-issue-worktree',
    [string] $InstallDir = 'C:\git\GitHub\multica',
    [switch] $SkipSetup,
    [switch] $Force,
    [string] $AgentsSpec,
    [string] $WorkspaceId,
    [string] $WorkspaceName,
    [string] $WorkspaceSlug,
    [hashtable] $AgentsPathMap = @{}
)

$ErrorActionPreference = 'Stop'
$ComposeFiles = @('-f', 'docker-compose.selfhost.yml', '-f', 'docker-compose.selfhost.build.yml')
$BinDir = Join-Path $env:USERPROFILE '.multica\bin'
$CliPath = Join-Path $BinDir 'multica.exe'
# Resolve before any Push-Location so a relative path means the caller's directory.
if ($AgentsSpec) { $AgentsSpec = (Resolve-Path -LiteralPath $AgentsSpec).ProviderPath }

# ------------------------------------------------------------------ Helpers ----

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "[OK] $Message" -ForegroundColor Green }

# Runs a native command with output streamed to the console; throws on a non-zero exit.
# ErrorActionPreference is relaxed so Windows PowerShell does not turn stderr
# progress output (git, docker) into terminating errors.
function Invoke-Step {
    param([string] $FilePath, [string[]] $Arguments, [switch] $AllowFailure)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments | Out-Host
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "'$FilePath $($Arguments -join ' ')' failed with exit code $code."
    }
    return $code
}

# Runs a native command and returns its trimmed stdout (stderr discarded unless -ShowErrors).
function Get-Output {
    param([string] $FilePath, [string[]] $Arguments, [switch] $AllowFailure, [switch] $ShowErrors)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($ShowErrors) { $out = & $FilePath @Arguments } else { $out = & $FilePath @Arguments 2>$null }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        throw "'$FilePath $($Arguments -join ' ')' failed with exit code $code."
    }
    return (@($out) -join "`n").Trim()
}

function Test-Command { param([string] $Name) [bool] (Get-Command $Name -ErrorAction SilentlyContinue) }

function New-RandomBytes {
    param([int] $Count)
    $bytes = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return , $bytes
}

function New-RandomHex {
    param([int] $ByteCount)
    return -join ((New-RandomBytes $ByteCount) | ForEach-Object { '{0:x2}' -f $_ })
}

function Write-Utf8Lines {
    param([string] $FilePath, [string[]] $Lines)
    [System.IO.File]::WriteAllLines($FilePath, $Lines, (New-Object System.Text.UTF8Encoding $false))
}

# Bypasses any system/corporate proxy: they commonly reject or intercept localhost.
function Test-Health {
    param([string] $Url)
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Timeout = 3000
        $response = $request.GetResponse()
        $ok = [int] $response.StatusCode -eq 200
        $response.Close()
        return $ok
    } catch {
        return $false
    }
}

function Get-GoArch {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { throw "Unsupported Windows architecture '$arch'. Only x64 and ARM64 are supported." }
    }
}

# Host port Docker Compose actually published (ambient env can move it; see install.ps1).
function Get-PublishedPort {
    param([string] $Service, [int] $ContainerPort)
    $out = Get-Output 'docker' (@('compose') + $ComposeFiles + @('port', $Service, "$ContainerPort")) -AllowFailure
    if (-not $out) { return $null }
    $last = @($out -split "`n")[-1].Trim()
    $port = $last.Substring($last.LastIndexOf(':') + 1)
    if ($port -match '^\d+$') { return [int] $port }
    return $null
}

# ---------------------------------------------------------------- Preflight ----

function Test-Prerequisites {
    Write-Step 'Checking prerequisites'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Multica requires 64-bit Windows.' }
    if (-not (Test-Command 'git')) { throw 'Git is not installed. Install it from https://git-scm.com/download/win and re-run.' }
    if (-not (Test-Command 'docker')) {
        throw 'Docker is not installed. Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/'
    }
    if ($null -eq (Get-Output 'docker' @('info') -AllowFailure)) {
        throw 'Docker is installed but not running. Start Docker Desktop and re-run.'
    }
    $composeVersion = Get-Output 'docker' @('compose', 'version', '--short') -AllowFailure
    if (-not $composeVersion -or $composeVersion -match '^v?1\.') {
        throw "Docker Compose v2 ('docker compose') is required; found '$composeVersion'."
    }
    Write-Ok "Git, Docker and Docker Compose $composeVersion are available"

    # Checked up front so a missing pwsh does not surface only after a long build.
    if ($AgentsSpec -and -not $SkipSetup) { $script:AgentsShell = Get-AgentsShell }
}

# multica-agents.ps1 needs PowerShell 7.3+. Returns $null when this process qualifies,
# otherwise the pwsh executable to run it with.
function Get-AgentsShell {
    $v = $PSVersionTable.PSVersion
    if ($v.Major -gt 7 -or ($v.Major -eq 7 -and $v.Minor -ge 3)) { return $null }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '-AgentsSpec needs PowerShell 7.3+ (pwsh). Install it with: winget install --id Microsoft.PowerShell'
    }
    return $pwsh.Source
}

# Pulls every base image up front so a blocked registry fails fast with guidance,
# instead of midway through a long build.
function Test-BaseImages {
    $images = New-Object System.Collections.Generic.List[string]
    foreach ($file in 'Dockerfile', 'Dockerfile.web') {
        foreach ($m in (Select-String -Path (Join-Path $InstallDir $file) -Pattern '^FROM\s+(\S+)')) {
            $image = $m.Matches[0].Groups[1].Value
            if ($image -match '[:/]' -and -not $images.Contains($image)) { $images.Add($image) }
        }
    }
    foreach ($m in (Select-String -Path (Join-Path $InstallDir 'docker-compose.selfhost.yml') -Pattern '^\s+image:\s+([^$\s]+)$')) {
        $image = $m.Matches[0].Groups[1].Value
        if (-not $images.Contains($image)) { $images.Add($image) }
    }

    Write-Step "Checking base images: $($images -join ', ')"
    foreach ($image in $images) {
        if ($null -ne (Get-Output 'docker' @('image', 'inspect', $image) -AllowFailure)) { continue }
        if ((Invoke-Step 'docker' @('pull', '--quiet', $image) -AllowFailure) -ne 0) {
            throw ("Docker could not pull '$image'. If this network needs a proxy, set it in Docker Desktop " +
                '(Settings > Resources > Proxies), or pre-load the image with `docker load`, then re-run.')
        }
    }
    Write-Ok 'Base images available'
}

# ------------------------------------------------------------------- Source ----

function Get-RepoKey {
    # Compares remotes regardless of https/ssh form, case or a trailing .git.
    param([string] $Url)
    if (-not $Url) { return '' }
    $key = $Url.Trim().ToLowerInvariant() -replace '^[a-z+]+://', '' -replace '^[^@/]+@', '' -replace '\.git/?$', ''
    return ($key -replace '^([^/:]+):', '$1/').TrimEnd('/')
}

# Remote in an existing checkout that points at -RepoUrl; adds one when none does.
# Existing remotes (e.g. origin -> upstream in a dev checkout) are never rewritten.
function Get-SourceRemote {
    $wanted = Get-RepoKey $RepoUrl
    $remotes = @((Get-Output 'git' @('-C', $InstallDir, 'remote')) -split "`n" | Where-Object { $_ })
    foreach ($remote in $remotes) {
        if ((Get-RepoKey (Get-Output 'git' @('-C', $InstallDir, 'remote', 'get-url', $remote))) -eq $wanted) { return $remote }
    }
    $name = @('fork', 'multica-install') | Where-Object { $remotes -notcontains $_ } | Select-Object -First 1
    if (-not $name) { throw "No remote in $InstallDir points at $RepoUrl. Add one with: git remote add <name> $RepoUrl" }
    Write-Step "Adding remote '$name' -> $RepoUrl"
    $null = Invoke-Step 'git' @('-C', $InstallDir, 'remote', 'add', $name, $RepoUrl)
    return $name
}

function Sync-Source {
    if (Test-Path (Join-Path $InstallDir '.git')) {
        Write-Step "Updating $InstallDir to $RepoUrl @ $Branch"
        $dirty = Get-Output 'git' @('-C', $InstallDir, 'status', '--porcelain', '--untracked-files=no')
        if ($dirty -and -not $Force) {
            throw "$InstallDir has local changes. Commit/stash them, or re-run with -Force to discard them."
        }
        $remote = Get-SourceRemote
        # Earlier installs (scripts/install.ps1) clone shallowly; version stamping needs history + tags.
        if ((Get-Output 'git' @('-C', $InstallDir, 'rev-parse', '--is-shallow-repository')) -eq 'true') {
            $null = Invoke-Step 'git' @('-C', $InstallDir, 'fetch', '--quiet', '--unshallow', '--filter=blob:none', $remote)
        }
        $null = Invoke-Step 'git' @('-C', $InstallDir, 'fetch', '--quiet', '--tags', '--force', $remote,
            "+refs/heads/${Branch}:refs/remotes/${remote}/${Branch}")

        $localBranch = Get-Output 'git' @('-C', $InstallDir, 'rev-parse', '--verify', '--quiet', "refs/heads/$Branch") -AllowFailure
        if ($localBranch -and -not $Force) {
            $ahead = [int] (Get-Output 'git' @('-C', $InstallDir, 'rev-list', '--count', "$remote/$Branch..$Branch"))
            if ($ahead -gt 0) {
                throw "Local branch '$Branch' has $ahead commit(s) that are not on $remote. Push them first, or re-run with -Force to reset it to $remote/$Branch."
            }
        }
        $null = Invoke-Step 'git' @('-C', $InstallDir, 'checkout', '--quiet', '--force', '-B', $Branch, "$remote/$Branch")
    } else {
        if ((Test-Path $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
            if (-not $Force) { throw "$InstallDir exists and is not a git checkout. Re-run with -Force to replace it." }
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        }
        Write-Step "Cloning $RepoUrl @ $Branch into $InstallDir"
        $parent = Split-Path -Parent $InstallDir
        if (-not (Test-Path $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $null = Invoke-Step 'git' @('clone', '--quiet', '--filter=blob:none', '--branch', $Branch, $RepoUrl, $InstallDir)
    }

    # Same stamps as the Makefile. A git-describe version (vX.Y.Z-N-gSHA) is what the
    # server's minimum-CLI-version gate recognises as a development build.
    $script:Version = Get-Output 'git' @('-C', $InstallDir, 'describe', '--tags', '--match', 'v[0-9]*', '--always', '--dirty')
    $script:Commit = Get-Output 'git' @('-C', $InstallDir, 'rev-parse', '--short', 'HEAD')
    $script:FullCommit = Get-Output 'git' @('-C', $InstallDir, 'rev-parse', 'HEAD')
    $script:BuildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($script:Version -notmatch '^v?\d+\.\d+\.\d+') {
        Write-Warning "Version '$script:Version' has no release tag; the server may treat this CLI as too old. Make sure $RepoUrl has the v* tags."
    }
    Write-Ok "Source ready: $Branch @ $script:Commit ($script:Version)"
}

# ---------------------------------------------------------------------- Env ----

function Initialize-EnvFile {
    $envPath = Join-Path $InstallDir '.env'
    if (Test-Path $envPath) {
        Write-Ok 'Using existing .env'
        return
    }
    Write-Step 'Creating .env with random secrets'
    $jwt = New-RandomHex 32
    $pgPassword = New-RandomHex 24
    $vcsKey = [Convert]::ToBase64String((New-RandomBytes 32))
    $lines = foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $InstallDir '.env.example'))) {
        if ($line -match '^JWT_SECRET=') { "JWT_SECRET=$jwt" }
        elseif ($line -match '^POSTGRES_PASSWORD=') { "POSTGRES_PASSWORD=$pgPassword" }
        elseif ($line -match '^MULTICA_VCS_SECRET_KEY=') { "MULTICA_VCS_SECRET_KEY=$vcsKey" }
        elseif ($line -match '^(DATABASE_URL=postgres://[^:]+:)[^@]*(@.*)$') { $Matches[1] + $pgPassword + $Matches[2] }
        else { $line }
    }
    Write-Utf8Lines $envPath $lines
    Write-Ok 'Generated JWT_SECRET, POSTGRES_PASSWORD and MULTICA_VCS_SECRET_KEY'
}

# ------------------------------------------------------------------- Server ----

function Start-Server {
    Write-Step 'Building backend + web images from source and starting the stack (first build takes a while)'
    $env:VERSION = $script:Version
    $env:COMMIT = $script:Commit
    $env:DATE = $script:BuildDate
    $null = Invoke-Step 'docker' (@('compose') + $ComposeFiles + @('up', '-d', '--build'))

    $script:BackendPort = Get-PublishedPort 'backend' 8080
    $script:FrontendPort = Get-PublishedPort 'frontend' 3000
    if (-not $script:BackendPort -or -not $script:FrontendPort) {
        throw "Could not read the published ports. Check: docker compose $($ComposeFiles -join ' ') ps"
    }

    Write-Step "Waiting for the backend on port $script:BackendPort"
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Health "http://localhost:$script:BackendPort/health") {
            Write-Ok 'Multica server is running'
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Backend did not become healthy. Check: docker compose $($ComposeFiles -join ' ') logs backend"
}

# ---------------------------------------------------------------------- CLI ----

function Get-GoImage {
    $from = Select-String -Path (Join-Path $InstallDir 'Dockerfile') -Pattern '^FROM\s+(golang:\S+)' | Select-Object -First 1
    if (-not $from) { throw 'Could not find the golang builder image in Dockerfile.' }
    return $from.Matches[0].Groups[1].Value
}

function Build-Cli {
    $goImage = Get-GoImage
    $goArch = Get-GoArch
    Write-Step "Building multica.exe (windows/$goArch) in $goImage"
    $ldflags = "-s -w -X main.version=$script:Version -X main.commit=$script:Commit -X main.buildCommit=$script:FullCommit -X main.date=$script:BuildDate"
    $null = Invoke-Step 'docker' @(
        'run', '--rm',
        '-v', "${InstallDir}:/src",
        '-v', 'multica-go-mod-cache:/go/pkg/mod',
        '-v', 'multica-go-build-cache:/root/.cache/go-build',
        '-w', '/src/server',
        '-e', 'CGO_ENABLED=0', '-e', 'GOOS=windows', '-e', "GOARCH=$goArch",
        $goImage,
        'go', 'build', '-buildvcs=false', '-ldflags', $ldflags, '-o', 'bin/multica.exe', './cmd/multica'
    )
    $script:BuiltCli = Join-Path $InstallDir 'server\bin\multica.exe'
    if (-not (Test-Path $script:BuiltCli)) { throw "Build finished but $script:BuiltCli is missing." }
    Write-Ok 'multica.exe built'
}

function Add-ToUserPath {
    param([string] $Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not ($userPath -and ($userPath.Split(';') -contains $Dir))) {
        $newPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Host "    Added $Dir to your user PATH (new terminals pick it up)."
    }
    if (($env:Path.Split(';')) -notcontains $Dir) { $env:Path = "$Dir;$env:Path" }
}

function Install-Cli {
    if (-not (Test-Path $BinDir)) { $null = New-Item -ItemType Directory -Path $BinDir -Force }

    # Windows locks a running exe, so stop the daemon before replacing the binary.
    $script:DaemonWasRunning = $false
    if (Test-Path $CliPath) {
        $status = Get-Output $CliPath @('daemon', 'status', '--output', 'json') -AllowFailure
        if ($status -and $status -match '"status"\s*:\s*"running"') {
            $script:DaemonWasRunning = $true
            Write-Step 'Stopping the running daemon to replace multica.exe'
            $null = Invoke-Step $CliPath @('daemon', 'stop') -AllowFailure
        }
    }

    $copied = $false
    for ($i = 0; $i -lt 30 -and -not $copied; $i++) {
        try {
            Copy-Item -LiteralPath $script:BuiltCli -Destination $CliPath -Force
            $copied = $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $copied) { throw "Could not replace $CliPath (still in use). Stop any multica process and re-run." }
    Add-ToUserPath $BinDir

    $resolved = (Get-Command multica -ErrorAction SilentlyContinue).Source
    if ($resolved -and $resolved -ne $CliPath) {
        Write-Warning "'multica' on PATH resolves to $resolved, not $CliPath. Remove the other copy so the branch build is used."
    }
    $installedVersion = @((Get-Output $CliPath @('version')) -split "`n")[0]
    Write-Ok "Installed $CliPath ($installedVersion)"
}

# ------------------------------------------------------------------ Connect ----

function Open-LoginCodeWindow {
    # Without RESEND_API_KEY the backend prints login codes to its log instead of emailing them.
    $compose = "docker compose -f '$InstallDir\docker-compose.selfhost.yml' logs -f --since 1m backend"
    $command = "Write-Host 'Waiting for Multica login codes...' -ForegroundColor Cyan; $compose | Select-String 'Verification code'"
    $shell = (Get-Process -Id $PID).Path
    Start-Process -FilePath $shell -ArgumentList @('-NoExit', '-Command', $command) | Out-Null
}

function Connect-Cli {
    if ($SkipSetup) { return }

    $serverUrl = "http://localhost:$script:BackendPort"
    $configured = Get-Output $CliPath @('config', 'show') -AllowFailure
    $signedIn = $configured -and $configured -match [regex]::Escape($serverUrl) -and
        ($null -ne (Get-Output $CliPath @('workspace', 'list') -AllowFailure))

    if ($signedIn) {
        Write-Step 'CLI already signed in to this server; restarting the daemon on the new build'
        $code = Invoke-Step $CliPath @('daemon', 'restart') -AllowFailure
        if ($code -ne 0) { $null = Invoke-Step $CliPath @('daemon', 'start') }
        return
    }

    Write-Step 'Connecting the CLI: a browser opens for sign-in'
    $envText = [System.IO.File]::ReadAllText((Join-Path $InstallDir '.env'))
    if ($envText -notmatch '(?m)^RESEND_API_KEY=\S') {
        Write-Host '    No RESEND_API_KEY is set, so login codes are not emailed.'
        Write-Host '    A second window will show them as they are issued.'
        Open-LoginCodeWindow
    }
    $null = Invoke-Step $CliPath @('setup', 'self-host', '--port', "$script:BackendPort", '--frontend-port', "$script:FrontendPort")
}

# ------------------------------------------------------------------- Agents ----

# Windows PowerShell's ConvertFrom-Json emits a JSON array as one object; assigning
# it first and returning lets callers wrap the elements with @().
function ConvertFrom-JsonList {
    param([string] $Json)
    if (-not $Json) { return }
    $parsed = ConvertFrom-Json $Json
    return $parsed
}

function Resolve-Workspace {
    $workspaces = @(ConvertFrom-JsonList (Get-Output $CliPath @('workspace', 'list', '--output', 'json') -ShowErrors))

    if ($WorkspaceId) {
        $match = @($workspaces | Where-Object { $_.id -eq $WorkspaceId -or $_.slug -eq $WorkspaceId })
        if ($match.Count -eq 0) { throw "Workspace '$WorkspaceId' was not found for this account." }
        return $match[0].id
    }
    if ($workspaces.Count -eq 1) { return $workspaces[0].id }
    if ($workspaces.Count -gt 1) {
        $names = ($workspaces | ForEach-Object { "$($_.name) ($($_.slug))" }) -join ', '
        throw "This account has several workspaces; pass -WorkspaceId <id-or-slug>. Found: $names"
    }
    if (-not $WorkspaceName) {
        throw "This account has no workspace yet. Re-run with -WorkspaceName '<name>', or create one at http://localhost:$script:FrontendPort and re-run."
    }

    $slug = if ($WorkspaceSlug) { $WorkspaceSlug } else { ($WorkspaceName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
    Write-Step "Creating workspace '$WorkspaceName' ($slug)"
    $created = ConvertFrom-Json (Get-Output $CliPath @('workspace', 'create', '--name', $WorkspaceName, '--slug', $slug, '--output', 'json') -ShowErrors)
    Write-Ok "Workspace created ($($created.id))"
    return $created.id
}

# The daemon registers runtimes per workspace; a workspace created a moment ago may
# need a daemon restart before its runtimes show up.
function Wait-LocalRuntimes {
    param([string] $WsId)

    $status = ConvertFrom-Json (Get-Output $CliPath @('daemon', 'status', '--output', 'json'))
    if ($status.status -ne 'running') {
        $null = Invoke-Step $CliPath @('daemon', 'start')
        $status = ConvertFrom-Json (Get-Output $CliPath @('daemon', 'status', '--output', 'json'))
    }

    Write-Step "Waiting for this machine's runtimes to register in the workspace"
    for ($i = 1; $i -le 60; $i++) {
        if ($i -eq 30) { $null = Invoke-Step $CliPath @('daemon', 'restart') -AllowFailure }
        $runtimes = @(ConvertFrom-JsonList (Get-Output $CliPath @('runtime', 'list', '--output', 'json', '--workspace-id', $WsId) -AllowFailure))
        $mine = @($runtimes | Where-Object { $_.daemon_id -eq $status.daemon_id })
        if ($mine.Count -gt 0) {
            Write-Ok "Runtimes on this machine: $(($mine | ForEach-Object { $_.provider }) -join ', ')"
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "No runtimes from this machine registered in the workspace. Install and sign in to the agent CLIs (claude, codex, copilot, ...), check 'multica daemon status', then re-run."
}

function Import-Agents {
    if (-not $AgentsSpec) { return }
    if ($SkipSetup) {
        Write-Warning '-AgentsSpec was ignored because -SkipSetup leaves the CLI signed out.'
        return
    }
    $agentsScript = Join-Path $InstallDir 'scripts\multica-agents.ps1'
    if (-not (Test-Path $agentsScript)) { throw "$agentsScript does not exist on $Branch." }

    $script:AgentsWorkspaceId = Resolve-Workspace
    Wait-LocalRuntimes $script:AgentsWorkspaceId

    Write-Step "Creating projects, agents and skills from $AgentsSpec"
    $params = @{ Path = $AgentsSpec; WorkspaceId = $script:AgentsWorkspaceId }
    if ($AgentsPathMap.Count -gt 0) { $params.PathMap = $AgentsPathMap }
    if ($script:AgentsShell) {
        & $script:AgentsShell -NoProfile -Command {
            param($ScriptPath, $Params)
            & $ScriptPath @Params
            exit $LASTEXITCODE
        } -args $agentsScript, $params
    } else {
        & $agentsScript @params
    }
    if ($LASTEXITCODE -ne 0) { throw "multica-agents.ps1 reported failures (exit code $LASTEXITCODE)." }
    Write-Ok 'Projects, agents and skills are in place'
}

# --------------------------------------------------------------------- Main ----

Test-Prerequisites
Sync-Source
Test-BaseImages
Push-Location $InstallDir
try {
    Initialize-EnvFile
    Start-Server
    Build-Cli
    Install-Cli
    Connect-Cli
    try {
        Import-Agents
    } catch {
        $script:AgentsError = $_.Exception.Message
    }
} finally {
    Pop-Location
}

$composeCmd = "docker compose -f `"$InstallDir\docker-compose.selfhost.yml`" -f `"$InstallDir\docker-compose.selfhost.build.yml`""
Write-Host ''
Write-Host '  ==========================================================' -ForegroundColor Green
Write-Host "  Multica $script:Version ($Branch) is running" -ForegroundColor Green
Write-Host '  ==========================================================' -ForegroundColor Green
Write-Host "  Web:      http://localhost:$script:FrontendPort"
Write-Host "  Backend:  http://localhost:$script:BackendPort"
Write-Host "  Source:   $InstallDir"
Write-Host "  CLI:      $CliPath"
Write-Host ''
Write-Host '  Update:   re-run this script'
Write-Host "  Logs:     $composeCmd logs -f backend"
Write-Host "  Stop:     $composeCmd down   (data is kept)"
Write-Host '  Daemon:   multica daemon status | start | stop'
if ($SkipSetup) {
    Write-Host ''
    Write-Host "  Next:     multica setup self-host --port $script:BackendPort --frontend-port $script:FrontendPort"
}
if ($AgentsSpec -and -not $SkipSetup) {
    Write-Host ''
    if ($script:AgentsError) {
        Write-Host "  Agents import did not finish: $script:AgentsError" -ForegroundColor Yellow
        Write-Host '  Fix the cause and re-run this script (it skips what already exists), or run only the import:'
        $wsArg = if ($script:AgentsWorkspaceId) { " -WorkspaceId $script:AgentsWorkspaceId" } else { '' }
        Write-Host "    pwsh -File `"$InstallDir\scripts\multica-agents.ps1`" -Path `"$AgentsSpec`"$wsArg"
    } else {
        Write-Host "  Agents:   imported from $AgentsSpec into workspace $script:AgentsWorkspaceId"
    }
}
Write-Host ''
Write-Host '  Use this standalone daemon, not the Multica Desktop app''s bundled one: only this' -ForegroundColor Yellow
Write-Host "  build includes the changes on $Branch." -ForegroundColor Yellow
Write-Host ''
if ($script:AgentsError) { exit 1 }
