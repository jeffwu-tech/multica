#Requires -Version 7.3
<#
.SYNOPSIS
    Export Multica projects, agents, skills and autopilots to a JSON spec, or create
    them from that spec on this machine.

.DESCRIPTION
    Export mode (-Export) reads every project and autopilot in the workspace, every
    active, user-authored agent (or those matching -Name) and the skills assigned to
    them, and writes:
        <Path>                  project + agent + skill + autopilot definitions
        <name>.secrets.json     custom_env and mcp_config per agent (only with -IncludeSecrets;
                                keep this file private and out of source control)

    Projects keep their title, description, icon, status, dates, lead (by name) and
    resources. local_directory resources are re-bound to THIS machine's daemon on
    create; use -PathMap when checkouts live somewhere else on the new machine.

    Autopilots keep their title, prompt (description), assignee agent (by name),
    mode, project (by title), issue title template, status, subscribers (by email)
    and triggers (schedule cron/timezone/label/enabled; webhook triggers get a NEW
    URL and token on create).

    Workspace IDs in instructions, descriptions, conversation starters and skill
    content are exported as name-based placeholders, because every ID differs in
    the target workspace:
        {{agent:<name>}}  {{project:<title>}}  {{skill:<name>}}
        {{user:<email>}}  (user ID)   {{member:<email>}}  (membership ID)
        {{workspace}}
    UUIDs that are not a known agent/project/skill/member/workspace are left as-is
    and reported.

    Create mode (default) reads the spec and, in the target workspace:
        1. creates each project that does not exist yet (matched by title) and its resources,
        2. creates each agent that does not exist yet (matched by name, archived included),
           bound to THIS machine's runtime for the agent's provider (claude, codex, ...),
        3. creates each skill that does not exist yet (matched by name),
        4. assigns skills, uploads avatars, sets project leads, and replaces placeholders
           with the target IDs - including agents created by an earlier run whose
           placeholders could not be resolved then (e.g. a project created later),
        5. creates each autopilot that does not exist yet (matched by title) with its
           triggers. Use -PauseAutopilots while the old machine is still running them,
           so both do not act on the same schedule.
    Existing projects, agents, skills and autopilots are otherwise left alone, so the
    script is safe to re-run. Placeholders that cannot be resolved stay in the text and
    are reported.

    Before running Create on the new machine:
        - install the agent CLIs (claude, codex, ...) and sign in to them,
        - `multica login` (or `multica setup self-host`) against the target server,
        - `multica daemon start` and confirm the target workspace shows this machine's runtimes,
        - clone the repositories that project local_directory resources point to.

    Not migrated: project priority and workflow, issues, member/team invocation
    targets, Composio toolkit allow-lists, disabled runtime skills, run history
    (agents and autopilots), webhook trigger URLs/secrets, chat sessions, and local
    work directories.

.PARAMETER Export
    Export from the workspace instead of creating.

.PARAMETER Path
    Spec file to write (Export) or read (Create).

.PARAMETER IncludeSecrets
    Export: also write custom_env and mcp_config to <Path-without-extension>.secrets.json.
    Requires that you own the agents (or are a workspace owner/admin).

.PARAMETER Name
    Export: only export agents whose name matches one of these wildcard patterns.

.PARAMETER RuntimeMap
    Create: override runtime selection per provider, e.g. @{ claude = '<runtime-id>' }.

.PARAMETER RuntimeId
    Create: bind every agent to this runtime ID, ignoring providers.

.PARAMETER PathMap
    Create: rewrite local_directory path prefixes, e.g. @{ 'C:\git\GitHub' = 'D:\src' }.

.PARAMETER PauseAutopilots
    Create: create autopilots paused regardless of their exported status. Resume them
    in the UI (or `multica autopilot update <id> --status active`) once the old
    machine's copies are paused.

.PARAMETER MulticaProfile
    Passed to the CLI as --profile.

.PARAMETER WorkspaceId
    Passed to the CLI as --workspace-id.

.PARAMETER ServerUrl
    Passed to the CLI as --server-url.

.EXAMPLE
    # Any machine that can see the source workspace:
    ./multica-agents.ps1 -Export -Path .\agents.json -IncludeSecrets

.EXAMPLE
    # New machine, against the target workspace. Preview first, then apply:
    ./multica-agents.ps1 -Path .\agents.json -WorkspaceId <target-workspace-id> -WhatIf
    ./multica-agents.ps1 -Path .\agents.json -WorkspaceId <target-workspace-id>

.EXAMPLE
    # Repositories are cloned under D:\src on the new machine:
    ./multica-agents.ps1 -Path .\agents.json -PathMap @{ 'C:\git\GitHub\WiseTechGlobal' = 'D:\src' }
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Export')]
    [switch] $Export,

    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter(ParameterSetName = 'Export')]
    [switch] $IncludeSecrets,

    [Parameter(ParameterSetName = 'Export')]
    [string[]] $Name,

    [Parameter(ParameterSetName = 'Create')]
    [hashtable] $RuntimeMap = @{},

    [Parameter(ParameterSetName = 'Create')]
    [string] $RuntimeId,

    [Parameter(ParameterSetName = 'Create')]
    [hashtable] $PathMap = @{},

    [Parameter(ParameterSetName = 'Create')]
    [switch] $PauseAutopilots,

    [string] $MulticaProfile,
    [string] $WorkspaceId,
    [string] $ServerUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Pass JSON / multi-line arguments to multica.exe verbatim.
$PSNativeCommandArgumentPassing = 'Standard'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# Windows caps a process command line at 32767 characters.
$MaxCommandLineLength = 30000

$script:GlobalArgs = @()
if ($MulticaProfile) { $script:GlobalArgs += @('--profile', $MulticaProfile) }
if ($WorkspaceId)    { $script:GlobalArgs += @('--workspace-id', $WorkspaceId) }
if ($ServerUrl)      { $script:GlobalArgs += @('--server-url', $ServerUrl) }

if (-not (Get-Command multica -ErrorAction SilentlyContinue)) {
    throw "The 'multica' CLI is not on PATH. Install it first: https://multica.ai"
}

function Invoke-Multica {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $all = @($Arguments) + $script:GlobalArgs
    $out = & multica @all
    if ($LASTEXITCODE -ne 0) {
        throw "multica $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') failed (exit code $LASTEXITCODE)."
    }
    $text = ($out -join "`n").Trim()
    if (-not $text) { return $null }
    return ConvertFrom-Json -InputObject $text -Depth 100
}

# Emits nothing (rather than $null) for missing values so callers can pipe the
# result straight into ForEach-Object without iterating a null.
function Get-Prop {
    param($Object, [string] $PropertyName)
    if ($null -eq $Object) { return }
    $p = $Object.PSObject.Properties[$PropertyName]
    if ($p -and $null -ne $p.Value) { return $p.Value }
}

function Test-HasContent {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $Value.Length -gt 0 }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    if ($Value -is [psobject]) { return @($Value.PSObject.Properties).Count -gt 0 }
    return $true
}

function ConvertTo-CompactJson {
    param($Value)
    return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

function Write-Utf8File {
    param([string] $FilePath, [string] $Text)
    [IO.File]::WriteAllText($FilePath, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-SecretsPath {
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    return Join-Path $dir "$base.secrets.json"
}

# The daemon names runtimes "<display name> (<device name>)"; dropping the machine
# part keeps the spec portable and comparable across machines.
function Get-RuntimeBaseName {
    param([string] $Name)
    if (-not $Name) { return $null }
    return $Name -replace '\s+\([^()]*\)$', ''
}

# ---------------------------------------------------------- Placeholders ----

$UuidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
$TokenPattern = '\{\{(agent|project|skill|user|member|workspace)(?::([^{}]+))?\}\}'

# Export: maps every known source ID (lower-case) to its placeholder.
function Get-SourceIdTokens {
    param([object[]] $AllAgents, [object[]] $Projects, [object[]] $Members)

    $map = @{}
    foreach ($a in $AllAgents) { $map[$a.id.ToLowerInvariant()] = "{{agent:$($a.name)}}" }
    foreach ($p in $Projects) { $map[$p.id.ToLowerInvariant()] = "{{project:$($p.title)}}" }
    foreach ($s in @(Invoke-Multica @('skill', 'list', '--output', 'json'))) {
        $map[$s.id.ToLowerInvariant()] = "{{skill:$($s.name)}}"
    }
    foreach ($m in $Members) {
        $map[$m.workspace_id.ToLowerInvariant()] = '{{workspace}}'
        if (-not (Get-Prop $m 'email')) { continue }
        $map[$m.user_id.ToLowerInvariant()] = "{{user:$($m.email)}}"
        $map[$m.id.ToLowerInvariant()] = "{{member:$($m.email)}}"
    }
    return $map
}

function ConvertTo-Placeholders {
    param([string] $Text, [string] $Where)

    if (-not $Text) { return $Text }
    return [regex]::Replace($Text, $UuidPattern, [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $token = $script:IdTokens[$m.Value.ToLowerInvariant()]
        if ($token) { return $token }
        $script:UnknownIds.Add("${Where}: $($m.Value)")
        return $m.Value
    })
}

# Create: replaces placeholders with IDs from $script:Target; unknown ones stay as-is.
function Resolve-Placeholders {
    param([string] $Text)

    if (-not $Text) { return $Text }
    return [regex]::Replace($Text, $TokenPattern, [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $key = $m.Groups[2].Value
        $id = switch ($m.Groups[1].Value) {
            'agent'     { $script:Target.agents[$key] }
            'project'   { $script:Target.projects[$key] }
            'skill'     { $script:Target.skills[$key] }
            'user'      { $script:Target.users[$key] }
            'member'    { $script:Target.members[$key] }
            'workspace' { $script:Target.workspace }
        }
        if ($id) { return [string] $id }
        return $m.Value
    })
}

function Get-Placeholders {
    param([string[]] $Texts)
    return @($Texts | Where-Object { $_ } | ForEach-Object { foreach ($m in [regex]::Matches($_, $TokenPattern)) { $m.Value } } | Sort-Object -Unique)
}

# ---------------------------------------------------------------- Export ----

function Get-ServerUrl {
    if ($ServerUrl) { return $ServerUrl.TrimEnd('/') }
    if ($env:MULTICA_SERVER_URL) { return $env:MULTICA_SERVER_URL.TrimEnd('/') }
    $cfgArgs = @('config', 'show')
    if ($MulticaProfile) { $cfgArgs += @('--profile', $MulticaProfile) }
    foreach ($line in @(& multica @cfgArgs 2>$null)) {
        if ($line -match '^\s*server_url:\s*(https?://\S+)') { return $Matches[1].TrimEnd('/') }
    }
}

# Avatars are usually server-relative (/uploads/...) and unreachable from the new
# machine, so they are embedded in the spec.
function Get-AvatarData {
    param([string] $Url, [string] $AgentName)

    if (-not $Url) { return }
    if (-not [Uri]::IsWellFormedUriString($Url, [UriKind]::Absolute)) {
        $base = Get-ServerUrl
        if (-not $base) {
            Write-Warning "${AgentName}: cannot resolve avatar '$Url' without a server URL; upload it manually."
            return
        }
        $Url = "$base/$($Url.TrimStart('/'))"
    }
    $uri = [Uri] $Url
    $file = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N'))
    try {
        $request = @{ Uri = $uri; OutFile = $file }
        # Corporate proxies commonly reject loopback requests.
        if ($uri.IsLoopback) { $request.NoProxy = $true }
        Invoke-WebRequest @request | Out-Null
        return [ordered]@{
            file_name = [IO.Path]::GetFileName($uri.AbsolutePath)
            base64    = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
        }
    } catch {
        Write-Warning "${AgentName}: could not download avatar ($($_.Exception.Message)); upload it manually."
    }
}

function ConvertTo-Day {
    param($Value)
    if ($null -eq $Value -or '' -eq $Value) { return }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd') }
    return ([string] $Value).Substring(0, 10)
}

function Export-Projects {
    param([object[]] $Projects, [object[]] $AllAgents, [object[]] $Members)

    foreach ($p in $Projects) {
        Write-Host "Exporting project '$($p.title)'"

        $lead = $null
        $leadId = Get-Prop $p 'lead_id'
        if ($leadId) {
            $leadName = if ((Get-Prop $p 'lead_type') -eq 'agent') {
                @($AllAgents | Where-Object { $_.id -eq $leadId } | ForEach-Object { $_.name })[0]
            } else {
                @($Members | Where-Object { $_.user_id -eq $leadId -or $_.id -eq $leadId } | ForEach-Object { $_.name })[0]
            }
            if ($leadName) { $lead = $leadName }
            else { Write-Warning "Project '$($p.title)': lead $leadId not found; set the lead manually." }
        }
        if ((Get-Prop $p 'priority') -and $p.priority -ne 'none') {
            Write-Warning "Project '$($p.title)': priority '$($p.priority)' cannot be set from the CLI; set it in the UI."
        }
        if (Get-Prop $p 'workflow_id') {
            Write-Warning "Project '$($p.title)': its workflow is workspace-specific and is not exported."
        }

        $resources = foreach ($r in @(Invoke-Multica @('project', 'resource', 'list', $p.id, '--output', 'json'))) {
            $ref = $r.resource_ref
            if ($r.resource_type -eq 'local_directory') {
                [ordered]@{
                    type           = 'local_directory'
                    label          = Get-Prop $r 'label'
                    local_path     = $ref.local_path
                    execution_mode = Get-Prop $ref 'execution_mode'
                    ref_label      = Get-Prop $ref 'label'
                }
            } else {
                [ordered]@{ type = $r.resource_type; label = Get-Prop $r 'label'; ref = $ref }
            }
        }

        [ordered]@{
            title       = $p.title
            description = ConvertTo-Placeholders (Get-Prop $p 'description') "project $($p.title) description"
            icon        = Get-Prop $p 'icon'
            status      = Get-Prop $p 'status'
            start_date  = ConvertTo-Day (Get-Prop $p 'start_date')
            due_date    = ConvertTo-Day (Get-Prop $p 'due_date')
            lead        = $lead
            resources   = @($resources)
        }
    }
}

function Export-Autopilots {
    param([object[]] $AllAgents, [object[]] $Projects, [object[]] $Members)

    $list = Invoke-Multica @('autopilot', 'list', '--output', 'json')
    foreach ($ap in @(Get-Prop $list 'autopilots')) {
        $title = $ap.title
        Write-Host "Exporting autopilot '$title'"

        $assignee = $null
        if ((Get-Prop $ap 'assignee_type') -eq 'agent') {
            $assignee = @($AllAgents | Where-Object { $_.id -eq $ap.assignee_id } | ForEach-Object { $_.name })[0]
        }
        if (-not $assignee) {
            Write-Warning "Autopilot '$title': assignee $($ap.assignee_type) $($ap.assignee_id) not found; it will be skipped on create."
        }

        $projectTitle = $null
        $projectId = Get-Prop $ap 'project_id'
        if ($projectId) {
            $projectTitle = @($Projects | Where-Object { $_.id -eq $projectId } | ForEach-Object { $_.title })[0]
            if (-not $projectTitle) { Write-Warning "Autopilot '$title': project $projectId not found; it is exported without a project." }
        }

        $subscribers = foreach ($s in @(Get-Prop $ap 'subscribers')) {
            $email = @($Members | Where-Object { $_.user_id -eq $s.user_id } | ForEach-Object { Get-Prop $_ 'email' })[0]
            if ($email) { $email } else { Write-Warning "Autopilot '$title': subscriber $($s.user_id) has no email; not exported." }
        }

        $triggerList = Invoke-Multica @('autopilot', 'trigger-list', $ap.id, '--output', 'json')
        $triggers = foreach ($t in @(Get-Prop $triggerList 'triggers')) {
            if ($t.kind -eq 'webhook') {
                Write-Warning "Autopilot '$title': its webhook trigger gets a NEW URL and token on create; update whatever calls it."
            }
            [ordered]@{
                kind     = $t.kind
                cron     = Get-Prop $t 'cron_expression'
                timezone = Get-Prop $t 'timezone'
                label    = Get-Prop $t 'label'
                enabled  = [bool] $t.enabled
            }
        }

        [ordered]@{
            title                = $title
            description          = ConvertTo-Placeholders (Get-Prop $ap 'description') "autopilot $title description"
            assignee             = $assignee
            mode                 = $ap.execution_mode
            project              = $projectTitle
            issue_title_template = Get-Prop $ap 'issue_title_template'
            status               = Get-Prop $ap 'status'
            subscribers          = @($subscribers)
            triggers             = @($triggers)
        }
    }
}

function Export-Agents {
    $runtimeById = @{}
    foreach ($r in @(Invoke-Multica @('runtime', 'list', '--output', 'json'))) { $runtimeById[$r.id] = $r }

    $allAgents = @(Invoke-Multica @('agent', 'list', '--include-archived', '--output', 'json'))
    $projects = @(Invoke-Multica @('project', 'list', '--output', 'json'))
    $members = @(Invoke-Multica @('workspace', 'member', 'list', '--output', 'json'))
    $script:IdTokens = Get-SourceIdTokens $allAgents $projects $members
    $script:UnknownIds = [System.Collections.Generic.List[string]]::new()

    $specProjects = @(Export-Projects $projects $allAgents $members)

    $agents = @($allAgents | Where-Object { -not (Get-Prop $_ 'system_key') -and -not (Get-Prop $_ 'archived_at') })
    if ($Name) {
        $agents = @($agents | Where-Object { $agentName = $_.name; @($Name | Where-Object { $agentName -like $_ }).Count -gt 0 })
    }
    if (@($agents).Count -eq 0) { throw 'No matching agents found in the workspace.' }

    $specAgents = [System.Collections.Generic.List[object]]::new()
    $secrets = [ordered]@{}
    $skillIds = [ordered]@{}

    foreach ($summary in $agents) {
        $a = Invoke-Multica @('agent', 'get', $summary.id, '--output', 'json')
        Write-Host "Exporting agent '$($a.name)'"

        $rt = if ($a.runtime_id) { $runtimeById[$a.runtime_id] } else { $null }
        if (-not $rt) {
            Write-Warning "$($a.name): its runtime is not visible to you, so its provider is unknown. Create will need -RuntimeId or -RuntimeMap."
        }

        $targets = @(Get-Prop $a 'invocation_targets')
        $publicToWorkspace = $a.permission_mode -eq 'public_to' -and
            @($targets | Where-Object { $_.target_type -eq 'workspace' }).Count -gt 0
        if (@($targets | Where-Object { $_.target_type -ne 'workspace' }).Count -gt 0) {
            Write-Warning "$($a.name): member/team invocation targets are workspace-specific and are not exported; re-add them in the target workspace."
        }
        if (Test-HasContent (Get-Prop $a 'composio_toolkit_allowlist')) {
            Write-Warning "$($a.name): Composio toolkit allow-list is not exported; re-enable it in the agent's Integrations tab."
        }

        $runtimeConfig = Get-Prop $a 'runtime_config'
        if (-not (Test-HasContent $runtimeConfig)) { $runtimeConfig = $null }
        elseif ((ConvertTo-CompactJson $runtimeConfig) -match '"\*{4}"') {
            Write-Warning "$($a.name): runtime_config contains a masked secret (****); set it again after creation."
        }

        foreach ($s in @(Get-Prop $a 'skills')) { $skillIds[$s.id] = $true }

        $specAgents.Add([ordered]@{
            name                  = $a.name
            description           = ConvertTo-Placeholders $a.description "$($a.name) description"
            instructions          = ConvertTo-Placeholders $a.instructions "$($a.name) instructions"
            conversation_starters = @(Get-Prop $a 'conversation_starters' | ForEach-Object {
                [ordered]@{ label = $_.label; prompt = ConvertTo-Placeholders $_.prompt "$($a.name) conversation starter" }
            })
            provider              = if ($rt) { $rt.provider } else { $null }
            runtime_name          = if ($rt) { Get-RuntimeBaseName $rt.name } else { $null }
            model                 = Get-Prop $a 'model'
            thinking_level        = Get-Prop $a 'thinking_level'
            service_tier          = Get-Prop $a 'service_tier'
            custom_args           = @(Get-Prop $a 'custom_args')
            runtime_config        = $runtimeConfig
            max_concurrent_tasks  = $a.max_concurrent_tasks
            public_to_workspace   = [bool] $publicToWorkspace
            skills                = @(Get-Prop $a 'skills' | ForEach-Object { $_.name })
            avatar                = Get-AvatarData (Get-Prop $a 'avatar_url') $a.name
        })

        $hasEnv = [bool] (Get-Prop $a 'has_custom_env')
        $mcp = Get-Prop $a 'mcp_config'
        if ($IncludeSecrets) {
            $entry = [ordered]@{}
            if ($hasEnv) {
                try {
                    $entry.custom_env = (Invoke-Multica @('agent', 'env', 'get', $a.id, '--output', 'json')).custom_env
                } catch {
                    Write-Warning "$($a.name): could not read custom_env ($($_.Exception.Message)). Only the agent owner or a workspace owner/admin can read it."
                }
            }
            if (Get-Prop $a 'mcp_config_redacted') {
                Write-Warning "$($a.name): mcp_config is redacted for you (not the owner) and is not exported."
            } elseif (Test-HasContent $mcp) {
                $entry.mcp_config = $mcp
            }
            if ($entry.Count -gt 0) { $secrets[$a.name] = $entry }
        } elseif ($hasEnv -or (Test-HasContent $mcp)) {
            Write-Warning "$($a.name): has custom env / MCP config that is not exported. Re-run with -IncludeSecrets to include it."
        }
    }

    $specSkills = foreach ($id in $skillIds.Keys) {
        $s = Invoke-Multica @('skill', 'get', $id, '--with-content', '--output', 'json')
        Write-Host "Exporting skill '$($s.name)'"
        [ordered]@{
            name        = $s.name
            description = $s.description
            content     = ConvertTo-Placeholders $s.content "skill $($s.name)"
            config      = if (Test-HasContent (Get-Prop $s 'config')) { $s.config } else { $null }
            files       = @(Get-Prop $s 'files' | ForEach-Object {
                [ordered]@{ path = $_.path; content = ConvertTo-Placeholders $_.content "skill $($s.name)/$($_.path)" }
            })
        }
    }

    $specAutopilots = @(Export-Autopilots $allAgents $projects $members)

    foreach ($u in $script:UnknownIds) {
        Write-Warning "Unrecognised ID left as-is in $u"
    }

    $spec = [ordered]@{
        version     = 1
        exported_at = (Get-Date).ToUniversalTime().ToString('o')
        projects    = $specProjects
        skills      = @($specSkills)
        agents      = $specAgents
        autopilots  = $specAutopilots
    }

    $summary = "$($specProjects.Count) project(s), $($specAgents.Count) agent(s), $(@($specSkills).Count) skill(s) and $($specAutopilots.Count) autopilot(s)"
    if ($PSCmdlet.ShouldProcess($Path, "Write spec with $summary")) {
        Write-Utf8File $Path (ConvertTo-Json -InputObject $spec -Depth 100)
        Write-Host "Wrote $summary to $Path" -ForegroundColor Green
    }

    if ($IncludeSecrets -and $secrets.Count -gt 0) {
        $secretsPath = Get-SecretsPath
        if ($PSCmdlet.ShouldProcess($secretsPath, "Write secrets for $($secrets.Count) agent(s)")) {
            Write-Utf8File $secretsPath (ConvertTo-Json -InputObject ([ordered]@{ agents = $secrets }) -Depth 100)
            Write-Warning "Secrets written to $secretsPath. Keep it private and delete it after the migration."
        }
    }
}

# ---------------------------------------------------------------- Create ----

function Get-LocalRuntimes {
    $status = Invoke-Multica @('daemon', 'status', '--output', 'json')
    if ((Get-Prop $status 'status') -ne 'running') {
        throw "The local Multica daemon is not running. Start it with 'multica daemon start' and retry."
    }
    $daemonId = Get-Prop $status 'daemon_id'
    $script:LocalDaemonId = $daemonId
    $local = @(Invoke-Multica @('runtime', 'list', '--output', 'json') | Where-Object { (Get-Prop $_ 'daemon_id') -eq $daemonId })
    if ($local.Count -eq 0 -and -not $RuntimeId -and $RuntimeMap.Count -eq 0) {
        throw "This machine's daemon ($daemonId) has no runtimes in the target workspace. Check 'multica daemon status' and the workspace."
    }
    foreach ($r in $local) {
        $color = if ($r.status -eq 'online') { 'Gray' } else { 'Yellow' }
        Write-Host ("  runtime {0,-10} {1}  {2} ({3})" -f $r.provider, $r.id, $r.name, $r.status) -ForegroundColor $color
    }
    return $local
}

function Select-RuntimeId {
    param($Agent, $LocalRuntimes)

    if ($RuntimeId) { return $RuntimeId }
    $provider = Get-Prop $Agent 'provider'
    if (-not $provider) { return $null }
    if ($RuntimeMap.ContainsKey($provider)) { return [string] $RuntimeMap[$provider] }

    $candidates = @($LocalRuntimes | Where-Object { $_.provider -eq $provider })
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0].id }

    $wanted = Get-Prop $Agent 'runtime_name'
    $byName = $candidates | Where-Object { $wanted -and (Get-RuntimeBaseName $_.name) -eq $wanted } | Select-Object -First 1
    if ($byName) { return $byName.id }
    $plain = $candidates | Where-Object { -not (Get-Prop $_ 'profile_id') } | Select-Object -First 1
    if ($plain) { return $plain.id }
    return $candidates[0].id
}

function New-TempFile {
    param([string] $Text, [string] $Extension = '.txt')
    $file = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N') + $Extension)
    Write-Utf8File $file $Text
    return $file
}

function Get-TargetIndex {
    $t = @{
        agents    = [hashtable]::new([StringComparer]::Ordinal)
        projects  = @{}
        skills    = @{}
        users     = @{}
        members   = @{}
        workspace = $null
    }
    foreach ($a in @(Invoke-Multica @('agent', 'list', '--include-archived', '--output', 'json'))) { $t.agents[$a.name] = $a.id }
    foreach ($p in @(Invoke-Multica @('project', 'list', '--output', 'json'))) { $t.projects[$p.title] = $p.id }
    foreach ($s in @(Invoke-Multica @('skill', 'list', '--output', 'json'))) { $t.skills[$s.name] = $s.id }
    foreach ($m in @(Invoke-Multica @('workspace', 'member', 'list', '--output', 'json'))) {
        $t.workspace = $m.workspace_id
        if (-not (Get-Prop $m 'email')) { continue }
        $t.users[$m.email] = $m.user_id
        $t.members[$m.email] = $m.id
    }
    return $t
}

function Sync-Skills {
    param($Skills)

    foreach ($skill in @($Skills | Where-Object { $_ })) {
        if ($script:Target.skills.ContainsKey($skill.name)) {
            Write-Host "Skill '$($skill.name)' already exists - reusing it."
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("skill '$($skill.name)'", 'Create')) { continue }

        $content = Resolve-Placeholders $skill.content
        $cliArgs = @('skill', 'create', '--name', $skill.name, '--output', 'json')
        if ($skill.description) { $cliArgs += @('--description', $skill.description) }
        if ($content) { $cliArgs += @('--content-file', (New-TempFile $content '.md')) }
        if (Test-HasContent (Get-Prop $skill 'config')) { $cliArgs += @('--config', (ConvertTo-CompactJson $skill.config)) }
        $created = Invoke-Multica $cliArgs

        $texts = @($content)
        foreach ($f in @(Get-Prop $skill 'files')) {
            if (-not $f.content) {
                Write-Warning "Skill '$($skill.name)': skipping empty file '$($f.path)'."
                continue
            }
            $fileContent = Resolve-Placeholders $f.content
            $texts += $fileContent
            $null = Invoke-Multica @('skill', 'files', 'upsert', $created.id, '--path', $f.path,
                '--content-file', (New-TempFile $fileContent), '--output', 'json')
        }
        $script:Target.skills[$skill.name] = $created.id
        Write-Host "Created skill '$($skill.name)'" -ForegroundColor Green

        $left = @(Get-Placeholders $texts)
        if ($left.Count -gt 0) {
            Write-Warning "Skill '$($skill.name)': unresolved placeholders $($left -join ', '). Edit the skill to fix them."
        }
    }
}

function Set-AgentAvatar {
    param([string] $AgentId, [string] $AgentName, $Avatar)

    if (-not (Get-Prop $Avatar 'base64')) { return }
    try {
        $ext = [IO.Path]::GetExtension([string] (Get-Prop $Avatar 'file_name'))
        if (-not $ext) { $ext = '.png' }
        $file = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N') + $ext)
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($Avatar.base64))
        $null = Invoke-Multica @('agent', 'avatar', $AgentId, '--file', $file, '--output', 'json')
    } catch {
        Write-Warning "${AgentName}: could not upload the avatar ($($_.Exception.Message)); upload it manually."
    }
}


function New-AgentCreateArgs {
    param($Agent, [string] $RuntimeId, $Secrets)

    $cliArgs = @('agent', 'create', '--name', $Agent.name, '--runtime-id', $RuntimeId, '--output', 'json')
    $description = Resolve-Placeholders $Agent.description
    $instructions = Resolve-Placeholders $Agent.instructions
    if ($description)  { $cliArgs += @('--description', $description) }
    if ($instructions) { $cliArgs += @('--instructions', $instructions) }
    if (Test-HasContent (Get-Prop $Agent 'conversation_starters')) {
        $cliArgs += @('--conversation-starters', (ConvertTo-StartersJson $Agent.conversation_starters))
    }
    if (Get-Prop $Agent 'model')          { $cliArgs += @('--model', $Agent.model) }
    if (Get-Prop $Agent 'thinking_level') { $cliArgs += @('--thinking-level', $Agent.thinking_level) }
    if (Get-Prop $Agent 'service_tier')   { $cliArgs += @('--service-tier', $Agent.service_tier) }
    if (Test-HasContent (Get-Prop $Agent 'custom_args')) {
        $cliArgs += @('--custom-args', (ConvertTo-CompactJson @($Agent.custom_args)))
    }
    if (Test-HasContent (Get-Prop $Agent 'runtime_config')) {
        $cliArgs += @('--runtime-config', (ConvertTo-CompactJson $Agent.runtime_config))
    }
    if (Get-Prop $Agent 'max_concurrent_tasks') {
        $cliArgs += @('--max-concurrent-tasks', [string] $Agent.max_concurrent_tasks)
    }
    if ($Agent.public_to_workspace) {
        $cliArgs += @('--permission-mode', 'public_to', '--public-to-workspace')
    } else {
        $cliArgs += @('--permission-mode', 'private')
    }
    if (Test-HasContent (Get-Prop $Secrets 'custom_env')) {
        $cliArgs += @('--custom-env-file', (New-TempFile (ConvertTo-CompactJson $Secrets.custom_env) '.json'))
    }
    if (Test-HasContent (Get-Prop $Secrets 'mcp_config')) {
        $cliArgs += @('--mcp-config-file', (New-TempFile (ConvertTo-CompactJson $Secrets.mcp_config) '.json'))
    }
    return $cliArgs
}

function ConvertTo-StartersJson {
    param($Starters)
    $resolved = @($Starters | ForEach-Object { [ordered]@{ label = $_.label; prompt = Resolve-Placeholders $_.prompt } })
    return ConvertTo-CompactJson $resolved
}

function Test-CommandLength {
    param([string[]] $CliArgs, [string] $AgentName)
    $length = ($CliArgs | Measure-Object -Property Length -Sum).Sum
    if ($length -le $MaxCommandLineLength) { return $true }
    Write-Warning "${AgentName}: definition is too long for one command line ($length chars, mostly instructions). Set it in the UI instead."
    return $false
}

# Replaces placeholders that could not be resolved when the agent was created
# (agents created later in the same run, or projects/skills/members added since).
function Update-AgentPlaceholders {
    param([string] $AgentId, [string] $AgentName, $Current)

    $texts = @($Current.description, $Current.instructions) + @($Current.conversation_starters | ForEach-Object { $_.prompt })
    if (@(Get-Placeholders $texts).Count -eq 0) { return }

    $cliArgs = @('agent', 'update', $AgentId, '--output', 'json')
    $resolvedTexts = @()
    foreach ($field in 'description', 'instructions') {
        $before = [string] (Get-Prop $Current $field)
        $after = Resolve-Placeholders $before
        $resolvedTexts += $after
        if ($after -ne $before) { $cliArgs += @("--$field", $after) }
    }
    $starters = @(Get-Prop $Current 'conversation_starters')
    if ($starters.Count -gt 0) {
        $before = ConvertTo-CompactJson @($starters | ForEach-Object { [ordered]@{ label = $_.label; prompt = $_.prompt } })
        $after = ConvertTo-StartersJson $starters
        $resolvedTexts += @($starters | ForEach-Object { Resolve-Placeholders $_.prompt })
        if ($after -ne $before) { $cliArgs += @('--conversation-starters', $after) }
    }

    if ($cliArgs.Count -gt 5 -and (Test-CommandLength $cliArgs $AgentName) -and
        $PSCmdlet.ShouldProcess("agent '$AgentName'", 'Replace placeholders with target IDs')) {
        try {
            $null = Invoke-Multica $cliArgs
            Write-Host "Resolved placeholders in '$AgentName'" -ForegroundColor Green
        } catch {
            Write-Warning "${AgentName}: could not update placeholders ($($_.Exception.Message))."
            return
        }
    }

    $left = @(Get-Placeholders $resolvedTexts)
    if ($left.Count -gt 0) {
        Write-Warning "${AgentName}: unresolved placeholders $($left -join ', '). Create the missing items in the target workspace and re-run, or edit the agent."
    }
}

function Convert-LocalPath {
    param([string] $LocalPath)

    foreach ($from in @($PathMap.Keys | Sort-Object { ([string] $_).Length } -Descending)) {
        $prefix = ([string] $from).TrimEnd('\', '/')
        if ($LocalPath.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $LocalPath.StartsWith("$prefix\", [StringComparison]::OrdinalIgnoreCase) -or
            $LocalPath.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)) {
            return ([string] $PathMap[$from]).TrimEnd('\', '/') + $LocalPath.Substring($prefix.Length)
        }
    }
    return $LocalPath
}

function Add-ProjectResource {
    param([string] $ProjectId, [string] $ProjectTitle, $Resource)

    $cliArgs = @('project', 'resource', 'add', $ProjectId, '--type', $Resource.type, '--output', 'json')
    if (Get-Prop $Resource 'label') { $cliArgs += @('--label', $Resource.label) }
    $what = $Resource.type
    if ($Resource.type -eq 'local_directory') {
        $localPath = Convert-LocalPath $Resource.local_path
        if (-not (Test-Path -LiteralPath $localPath)) {
            Write-Warning "Project '$ProjectTitle': $localPath does not exist on this machine yet. Clone it there, or re-map it with -PathMap."
        }
        $cliArgs += @('--local-path', $localPath, '--daemon-id', $script:LocalDaemonId)
        if (Get-Prop $Resource 'execution_mode') { $cliArgs += @('--execution-mode', $Resource.execution_mode) }
        if (Get-Prop $Resource 'ref_label')      { $cliArgs += @('--ref-label', $Resource.ref_label) }
        $what = "local directory $localPath"
    } else {
        $cliArgs += @('--ref', (ConvertTo-CompactJson $Resource.ref))
    }
    try {
        $null = Invoke-Multica $cliArgs
        Write-Host "  + $what"
    } catch {
        Write-Warning "Project '$ProjectTitle': could not add $what ($($_.Exception.Message))."
        $script:Failed++
    }
}

# Projects come first so {{project:...}} placeholders in agents resolve on creation.
function Sync-Projects {
    param($Projects)

    $createdNow = @{}
    foreach ($proj in @($Projects | Where-Object { $_ })) {
        $title = $proj.title
        if ($script:Target.projects.ContainsKey($title)) {
            Write-Host "Project '$title' already exists - reusing it."
            continue
        }
        $resources = @(Get-Prop $proj 'resources')
        if (-not $PSCmdlet.ShouldProcess("project '$title' with $($resources.Count) resource(s)", 'Create')) { continue }

        $description = Resolve-Placeholders (Get-Prop $proj 'description')
        $cliArgs = @('project', 'create', '--title', $title, '--output', 'json')
        if ($description)               { $cliArgs += @('--description', $description) }
        if (Get-Prop $proj 'status')    { $cliArgs += @('--status', $proj.status) }
        if (Get-Prop $proj 'icon')      { $cliArgs += @('--icon', $proj.icon) }
        $startDate = ConvertTo-Day (Get-Prop $proj 'start_date')
        $dueDate = ConvertTo-Day (Get-Prop $proj 'due_date')
        if ($startDate) { $cliArgs += @('--start-date', $startDate) }
        if ($dueDate)   { $cliArgs += @('--due-date', $dueDate) }

        try {
            $new = Invoke-Multica $cliArgs
        } catch {
            Write-Warning "Project '$title': $($_.Exception.Message)"
            $script:Failed++
            continue
        }
        $script:Target.projects[$title] = $new.id
        $createdNow[$title] = @{ id = $new.id; description = $description }
        $script:ProjectsCreated++
        Write-Host "Created project '$title' ($($new.id))" -ForegroundColor Green

        foreach ($res in $resources) { Add-ProjectResource $new.id $title $res }
    }
    return $createdNow
}

# Leads and description placeholders may reference agents that only exist after pass 2.
function Complete-Projects {
    param($Projects, [hashtable] $CreatedNow)

    foreach ($proj in @($Projects | Where-Object { $_ })) {
        $title = $proj.title
        if (-not $CreatedNow.ContainsKey($title)) { continue }
        $state = $CreatedNow[$title]

        $cliArgs = @('project', 'update', $state.id, '--output', 'json')
        if (Get-Prop $proj 'lead') { $cliArgs += @('--lead', $proj.lead) }
        $description = Resolve-Placeholders $state.description
        if ($description -ne $state.description) { $cliArgs += @('--description', $description) }

        if ($cliArgs.Count -gt 5 -and $PSCmdlet.ShouldProcess("project '$title'", 'Set lead / resolve placeholders')) {
            try {
                $null = Invoke-Multica $cliArgs
            } catch {
                Write-Warning "Project '$title': could not set lead/description ($($_.Exception.Message))."
            }
        }
        $left = @(Get-Placeholders @($description))
        if ($left.Count -gt 0) {
            Write-Warning "Project '$title': unresolved placeholders $($left -join ', ') in its description."
        }
    }
}

function Sync-Autopilots {
    param($Autopilots)

    $existing = @{}
    foreach ($ap in @(Get-Prop (Invoke-Multica @('autopilot', 'list', '--output', 'json')) 'autopilots')) { $existing[$ap.title] = $ap.id }

    foreach ($ap in @($Autopilots | Where-Object { $_ })) {
        $title = $ap.title
        if ($existing.ContainsKey($title)) {
            Write-Host "Autopilot '$title' already exists - skipped."
            continue
        }
        $assignee = Get-Prop $ap 'assignee'
        $triggers = @(Get-Prop $ap 'triggers')
        $paused = $PauseAutopilots -or (Get-Prop $ap 'status') -eq 'paused'
        $what = "autopilot '$title' -> $assignee with $($triggers.Count) trigger(s)" + $(if ($paused) { ' (paused)' } else { '' })
        if (-not $PSCmdlet.ShouldProcess($what, 'Create')) { continue }

        if (-not $assignee -or -not $script:Target.agents.ContainsKey($assignee)) {
            Write-Warning "Autopilot '$title': assignee agent '$assignee' does not exist in the target workspace; skipped."
            $script:Failed++
            continue
        }

        $description = Resolve-Placeholders (Get-Prop $ap 'description')
        $cliArgs = @('autopilot', 'create', '--title', $title, '--agent', $script:Target.agents[$assignee],
            '--mode', $ap.mode, '--output', 'json')
        if ($description) { $cliArgs += @('--description', $description) }
        $project = Get-Prop $ap 'project'
        if ($project) {
            if ($script:Target.projects.ContainsKey($project)) { $cliArgs += @('--project', $script:Target.projects[$project]) }
            else { Write-Warning "Autopilot '$title': project '$project' not found; created without a project." }
        }
        if (Get-Prop $ap 'issue_title_template') { $cliArgs += @('--issue-title-template', $ap.issue_title_template) }
        foreach ($email in @(Get-Prop $ap 'subscribers')) {
            $userId = $script:Target.users[$email]
            if ($userId) { $cliArgs += @('--subscriber', $userId) }
            else { Write-Warning "Autopilot '$title': subscriber $email is not a member of the target workspace; skipped." }
        }
        if (-not (Test-CommandLength $cliArgs "Autopilot '$title'")) { $script:Failed++; continue }

        try {
            $new = Invoke-Multica $cliArgs
        } catch {
            Write-Warning "Autopilot '$title': $($_.Exception.Message)"
            $script:Failed++
            continue
        }
        $script:AutopilotsCreated++
        Write-Host "Created autopilot '$title' ($($new.id))" -ForegroundColor Green

        try {
            # Pause before adding triggers so a schedule cannot fire in between.
            if ($paused) { $null = Invoke-Multica @('autopilot', 'update', $new.id, '--status', 'paused', '--output', 'json') }

            foreach ($t in $triggers) {
                $triggerArgs = @('autopilot', 'trigger-add', $new.id, '--kind', $t.kind, '--output', 'json')
                if ($t.kind -eq 'schedule') {
                    $triggerArgs += @('--cron', $t.cron)
                    if (Get-Prop $t 'timezone') { $triggerArgs += @('--timezone', $t.timezone) }
                } elseif ($t.kind -ne 'webhook') {
                    Write-Warning "Autopilot '$title': unsupported trigger kind '$($t.kind)'; skipped."
                    continue
                }
                if (Get-Prop $t 'label') { $triggerArgs += @('--label', $t.label) }
                $trigger = Invoke-Multica $triggerArgs
                if (-not $t.enabled) {
                    $null = Invoke-Multica @('autopilot', 'trigger-update', $new.id, $trigger.id, '--enabled=false', '--output', 'json')
                }
                $state = if ($t.enabled) { 'enabled' } else { 'disabled' }
                Write-Host "  + $($t.kind) trigger $(if ($t.kind -eq 'schedule') { "'$($t.cron)' $($t.timezone) " })($state)"
                if ($t.kind -eq 'webhook') {
                    Write-Warning "Autopilot '$title': new webhook URL/token - copy it from the autopilot's trigger settings to its callers."
                }
            }
        } catch {
            Write-Warning "Autopilot '$title': could not finish status/triggers ($($_.Exception.Message)). Fix it in the UI."
            $script:Failed++
        }

        $left = @(Get-Placeholders @($description))
        if ($left.Count -gt 0) {
            Write-Warning "Autopilot '$title': unresolved placeholders $($left -join ', ') in its prompt."
        }
    }
}

function New-Agents {
    if (-not (Test-Path $Path)) { throw "Spec file not found: $Path" }
    $spec = Get-Content -Raw -Encoding utf8 $Path | ConvertFrom-Json -Depth 100

    $secrets = $null
    $secretsPath = Get-SecretsPath
    if (Test-Path $secretsPath) {
        $secrets = Get-Content -Raw -Encoding utf8 $secretsPath | ConvertFrom-Json -Depth 100
        Write-Host "Using secrets from $secretsPath"
    }

    Write-Host 'Runtimes on this machine:'
    $localRuntimes = @(Get-LocalRuntimes)
    $script:Target = Get-TargetIndex
    $script:Failed = 0
    $script:ProjectsCreated = 0
    $script:AutopilotsCreated = 0

    # Pass 1: projects.
    $projectsCreatedNow = Sync-Projects (Get-Prop $spec 'projects')

    # Pass 2: agents. Placeholders for agents created later in this pass are fixed in pass 4.
    $createdNow = @{}
    $created = 0; $skipped = 0
    foreach ($agent in @(Get-Prop $spec 'agents')) {
        $agentName = $agent.name
        if ($script:Target.agents.ContainsKey($agentName)) {
            Write-Host "Agent '$agentName' already exists - skipped."
            $skipped++
            continue
        }

        $rtId = Select-RuntimeId $agent $localRuntimes
        if (-not $rtId) {
            Write-Warning "${agentName}: no runtime for provider '$(Get-Prop $agent 'provider')' on this machine. Install/sign in to that CLI, restart the daemon, or pass -RuntimeMap / -RuntimeId."
            $script:Failed++
            continue
        }

        $agentSecrets = if ($secrets) { Get-Prop (Get-Prop $secrets 'agents') $agentName } else { $null }
        $cliArgs = New-AgentCreateArgs $agent $rtId $agentSecrets
        if (-not (Test-CommandLength $cliArgs $agentName)) { $script:Failed++; continue }

        $provider = Get-Prop $agent 'provider'
        if (-not $PSCmdlet.ShouldProcess("agent '$agentName' on runtime $rtId ($provider)", 'Create')) { continue }

        try {
            $new = Invoke-Multica $cliArgs
        } catch {
            Write-Warning "${agentName}: $($_.Exception.Message)"
            $script:Failed++
            continue
        }
        $script:Target.agents[$agentName] = $new.id
        $createdNow[$agentName] = $new
        $created++
        Write-Host "Created agent '$agentName' ($($new.id))" -ForegroundColor Green
    }

    # Pass 3: skills, now that every agent ID is known.
    Sync-Skills (Get-Prop $spec 'skills')

    # Pass 4: skills, avatars, project leads, and placeholders that earlier passes could not resolve.
    foreach ($agent in @(Get-Prop $spec 'agents')) {
        $agentName = $agent.name
        $agentId = $script:Target.agents[$agentName]
        if (-not $agentId) { continue }

        if ($createdNow.ContainsKey($agentName)) {
            $wanted = @(Get-Prop $agent 'skills')
            $skillIds = @($wanted | Where-Object { $script:Target.skills.ContainsKey($_) } | ForEach-Object { $script:Target.skills[$_] })
            foreach ($missing in @($wanted | Where-Object { -not $script:Target.skills.ContainsKey($_) })) {
                Write-Warning "${agentName}: skill '$missing' not found in the target workspace."
            }
            if ($skillIds.Count -gt 0) {
                try {
                    $null = Invoke-Multica @('agent', 'skills', 'set', $agentId, '--skill-ids', ($skillIds -join ','), '--output', 'json')
                } catch {
                    Write-Warning "${agentName}: could not assign skills ($($_.Exception.Message))."
                }
            }
            Set-AgentAvatar $agentId $agentName (Get-Prop $agent 'avatar')
            Update-AgentPlaceholders $agentId $agentName $createdNow[$agentName]
        } else {
            $specTexts = @($agent.description, $agent.instructions) + @(Get-Prop $agent 'conversation_starters' | ForEach-Object { $_.prompt })
            if (@(Get-Placeholders $specTexts).Count -eq 0) { continue }
            Update-AgentPlaceholders $agentId $agentName (Invoke-Multica @('agent', 'get', $agentId, '--output', 'json'))
        }
    }
    Complete-Projects (Get-Prop $spec 'projects') $projectsCreatedNow

    # Pass 5: autopilots, now that their agents, projects and placeholders resolve.
    Sync-Autopilots (Get-Prop $spec 'autopilots')

    Write-Host ''
    Write-Host "Done. Projects created: $script:ProjectsCreated  Agents created: $created  Agents skipped (already exist): $skipped  Autopilots created: $script:AutopilotsCreated  Failures: $script:Failed"
    if ($script:Failed -gt 0) { exit 1 }
}


# ------------------------------------------------------------------ Main ----

$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ('multica-agents-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:TempDir -WhatIf:$false
try {
    if ($Export) { Export-Agents } else { New-Agents }
} finally {
    Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
}
