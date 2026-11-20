<#
.SYNOPSIS
  Etapa 1 - Valida as imagens Docker do SIMUL localmente (sem Kubernetes).

.DESCRIPTION
  Constroi as imagens do backend e do frontend, sobe PostgreSQL + backend +
  frontend em uma rede Docker descartavel e executa verificacoes reais:
    - Flyway aplicou as migrations existentes
    - Nginx serve o React e faz fallback de rotas do SPA
    - /api chega ao backend (mesma origem)
    - /actuator nao e exposto pelo front-end
    - o front-end continua de pe quando o backend cai

  Todos os segredos (senha do banco, JWT, chaves VAPID) sao GERADOS agora,
  existem apenas em memoria/containers descartaveis e nunca sao gravados em
  arquivo. SMTP e ficticio: so permite o backend iniciar.

.PARAMETER Port
  Porta local para acessar o front-end (padrao 8081).

.PARAMETER SkipBuild
  Reutiliza as imagens simul-backend:etapa1 e simul-frontend:etapa1 ja existentes.

.PARAMETER Keep
  Nao remove containers e rede ao final (para inspecionar manualmente).

.EXAMPLE
  .\scripts\validation\etapa1-docker-local.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8081,
    [switch]$SkipBuild,
    [switch]$Keep
)

# Comandos nativos (docker) nao interrompem o script por conta propria:
# o codigo de saida e verificado explicitamente em Assert-Docker.
$ErrorActionPreference = 'Continue'

$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Net         = 'simul-etapa1'
$ImgBackend  = 'simul-backend:etapa1'
$ImgFrontend = 'simul-frontend:etapa1'
$Containers  = @('simul-frontend', 'simul-backend', 'simul-pg')
$Results     = New-Object System.Collections.Generic.List[object]

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Assert-Docker([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        throw "Falha: $What (codigo de saida $LASTEXITCODE)"
    }
}

function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
    $Results.Add([pscustomobject]@{ Teste = $Name; Ok = $Ok; Detalhe = $Detail })
    if ($Ok) { $tag = '[ OK ]'; $color = 'Green' } else { $tag = '[FALHA]'; $color = 'Red' }
    Write-Host ("{0} {1} - {2}" -f $tag, $Name, $Detail) -ForegroundColor $color
}

function Invoke-Http([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Headers = $r.Headers; Body = [string]$r.Content }
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            return [pscustomobject]@{ Status = [int]$resp.StatusCode; Headers = @{}; Body = '' }
        }
        return [pscustomobject]@{ Status = 0; Headers = @{}; Body = $_.Exception.Message }
    }
}

function New-RandomBase64([int]$Bytes) {
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buffer)
    $rng.Dispose()
    return [Convert]::ToBase64String($buffer)
}

function Remove-TestEnvironment {
    foreach ($c in $Containers) { docker rm -f $c 2>&1 | Out-Null }
    docker network rm $Net 2>&1 | Out-Null
}

try {
    Write-Step 'Verificando o Docker'
    docker version --format '{{.Server.Version}}' | Out-Null
    Assert-Docker 'Docker Desktop precisa estar em execucao'

    if (-not $SkipBuild) {
        Write-Step 'Construindo a imagem do backend (a primeira vez demora: baixa dependencias Maven)'
        docker build -t $ImgBackend (Join-Path $RepoRoot 'backend')
        Assert-Docker 'docker build do backend'

        Write-Step 'Construindo a imagem do frontend'
        docker build -t $ImgFrontend (Join-Path $RepoRoot 'frontend')
        Assert-Docker 'docker build do frontend'
    }

    Write-Step 'Gerando segredos descartaveis (nada e gravado em arquivo)'
    $pgPassword = (New-RandomBase64 18) -replace '[^A-Za-z0-9]', 'x'
    $jwtSecret  = New-RandomBase64 32
    $vapidRaw   = docker run --rm node:22-alpine npx --yes web-push@3.6.7 generate-vapid-keys --json 2>$null
    Assert-Docker 'geracao das chaves VAPID'
    $vapid = ($vapidRaw -join "`n") | ConvertFrom-Json
    if (-not $vapid.publicKey -or -not $vapid.privateKey) {
        throw 'Nao foi possivel ler as chaves VAPID geradas.'
    }

    Write-Step 'Limpando resultados de execucoes anteriores'
    Remove-TestEnvironment
    docker network create $Net | Out-Null
    Assert-Docker 'criacao da rede Docker'

    Write-Step 'Subindo o PostgreSQL'
    docker run -d --name simul-pg --network $Net `
        -e POSTGRES_DB=simul -e POSTGRES_USER=simul -e "POSTGRES_PASSWORD=$pgPassword" `
        postgres:17-alpine | Out-Null
    Assert-Docker 'start do PostgreSQL'

    $pgReady = $false
    for ($i = 0; $i -lt 60; $i++) {
        # -h 127.0.0.1 (TCP): o servidor temporario de inicializacao so escuta no socket Unix.
        docker exec simul-pg pg_isready -h 127.0.0.1 -U simul -d simul 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $pgReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $pgReady) { throw 'PostgreSQL nao ficou pronto a tempo.' }

    Write-Step 'Subindo o backend (SMTP ficticio; scheduler desligado)'
    docker run -d --name simul-backend --network $Net --network-alias backend `
        -e 'DB_URL=jdbc:postgresql://simul-pg:5432/simul' `
        -e DB_USERNAME=simul -e "DB_PASSWORD=$pgPassword" `
        -e "JWT_SECRET=$jwtSecret" `
        -e SMTP_HOST=smtp.invalid -e SMTP_PORT=587 `
        -e SMTP_USERNAME=ficticio -e SMTP_PASSWORD=ficticio `
        -e SMTP_FROM=simul-lab@example.com `
        -e "WEB_PUSH_VAPID_PUBLIC_KEY=$($vapid.publicKey)" `
        -e "WEB_PUSH_VAPID_PRIVATE_KEY=$($vapid.privateKey)" `
        -e WEB_PUSH_VAPID_SUBJECT=mailto:simul-lab@example.com `
        -e NOTIFICACAO_SCHEDULER_ENABLED=false `
        -e "SIMUL_FRONTEND_URL=http://localhost:$Port" `
        $ImgBackend | Out-Null
    Assert-Docker 'start do backend'

    $backendUp = $false
    for ($i = 0; $i -lt 120; $i++) {
        $running = (docker inspect -f '{{.State.Running}}' simul-backend 2>&1) -join ''
        if ($running -ne 'true') { break }
        $log = (docker logs simul-backend 2>&1) -join "`n"
        if ($log -match 'Started BackendApplication') { $backendUp = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $backendUp) {
        Write-Host '--- ultimas linhas do log do backend ---' -ForegroundColor Yellow
        docker logs --tail 60 simul-backend
        throw 'O backend nao iniciou.'
    }
    Add-Result 'Backend iniciou' $true 'log contem "Started BackendApplication"'

    $flyway = ((docker exec simul-pg psql -U simul -d simul -tA -c 'select count(*) || chr(124) || max(version::int) from flyway_schema_history where success' 2>&1) -join '').Trim()
    Add-Result 'Flyway aplicou as migrations' ($flyway -eq '16|16') "migrations com sucesso | maior versao = $flyway (esperado 16|16)"

    Write-Step 'Subindo o frontend (Nginx)'
    docker run -d --name simul-frontend --network $Net -p "${Port}:80" $ImgFrontend | Out-Null
    Assert-Docker 'start do frontend'

    $base = "http://localhost:$Port"
    $frontUp = $false
    for ($i = 0; $i -lt 30; $i++) {
        if ((Invoke-Http "$base/healthz").Status -eq 200) { $frontUp = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $frontUp) { throw 'O frontend nao respondeu em /healthz.' }

    Write-Step 'Executando as verificacoes'

    $r = Invoke-Http "$base/"
    Add-Result 'GET / serve o React' (($r.Status -eq 200) -and ($r.Body -match 'id="root"')) "status $($r.Status)"
    $podHeader = "$($r.Headers['X-Frontend-Pod'])"
    Add-Result 'Cabecalho X-Frontend-Pod presente' ($podHeader.Length -gt 0) "valor: $podHeader"

    $r = Invoke-Http "$base/cadastro"
    Add-Result 'Rota do SPA (/cadastro) cai no index.html' (($r.Status -eq 200) -and ($r.Body -match 'id="root"')) "status $($r.Status)"

    $r = Invoke-Http "$base/sw.js"
    $cc = "$($r.Headers['Cache-Control'])"
    Add-Result 'sw.js sem cache' (($r.Status -eq 200) -and ($cc -match 'no-cache')) "status $($r.Status), Cache-Control: $cc"

    $r = Invoke-Http "$base/api/rotas/areas"
    $areas = $null
    $count = 0
    if ($r.Status -eq 200) {
        $areas = $r.Body | ConvertFrom-Json
        $count = @($areas).Count
    }
    Add-Result 'GET /api/rotas/areas via Nginx' (($r.Status -eq 200) -and ($count -gt 0)) "status $($r.Status), $count areas vindas do PostgreSQL"

    $sample = $null
    if ($areas) {
        $sample = @($areas) | Where-Object { $_.bairro -cmatch '^[A-Za-z ]+$' -and $_.cidade -cmatch '^[A-Za-z ]+$' } | Select-Object -First 1
    }
    if ($sample) {
        $url = "$base/api/rotas/consulta?cidade=" + [uri]::EscapeDataString($sample.cidade) + '&bairro=' + [uri]::EscapeDataString($sample.bairro)
        $r = Invoke-Http $url
        Add-Result 'GET /api/rotas/consulta (consulta publica real)' (($r.Status -eq 200) -and ($r.Body.Length -gt 2)) "status $($r.Status), $($sample.bairro) / $($sample.cidade)"
    }
    else {
        Add-Result 'GET /api/rotas/consulta (consulta publica real)' $false 'nenhuma area com nome ASCII encontrada para testar'
    }

    $r = Invoke-Http "$base/api/usuarios/me"
    Add-Result 'Seguranca do backend preservada (sem token = 401)' ($r.Status -eq 401) "status $($r.Status)"

    $r = Invoke-Http "$base/actuator/health"
    Add-Result '/actuator nao e exposto pelo front-end' ($r.Status -eq 404) "status $($r.Status)"

    Write-Step 'Derrubando o backend para testar a resiliencia do Nginx'
    docker stop simul-backend | Out-Null
    $r = Invoke-Http "$base/"
    Add-Result 'Front-end continua servindo com o backend parado' ($r.Status -eq 200) "status $($r.Status)"
    $r = Invoke-Http "$base/api/rotas/areas"
    Add-Result '/api falha de forma controlada (502/503/504)' (@(502, 503, 504) -contains $r.Status) "status $($r.Status)"
}
catch {
    Write-Host ''
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    Add-Result 'Execucao do roteiro' $false $_.Exception.Message
}
finally {
    if (-not $Keep) {
        Write-Step 'Removendo containers e rede de teste'
        Remove-TestEnvironment
    }
    else {
        Write-Host ''
        Write-Host "Ambiente mantido (-Keep). Frontend: http://localhost:$Port" -ForegroundColor Yellow
        Write-Host 'Para remover: docker rm -f simul-frontend simul-backend simul-pg; docker network rm simul-etapa1'
    }
}

Write-Host ''
Write-Host '================ RESUMO ================' -ForegroundColor Cyan
$Results | Format-Table -AutoSize
$failed = @($Results | Where-Object { -not $_.Ok }).Count
if ($failed -gt 0) {
    Write-Host "$failed verificacao(oes) falharam." -ForegroundColor Red
    exit 1
}
Write-Host 'Todas as verificacoes passaram.' -ForegroundColor Green
exit 0
