$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root

if ((& kubectl config current-context).Trim() -ne 'simul') {
    throw "O contexto kubectl precisa ser 'simul'."
}
& minikube status -p simul *> $null
if ($LASTEXITCODE -ne 0) {
    throw "O perfil Minikube 'simul' nao esta ativo."
}

$requiredFiles = @(
    'backend\Dockerfile',
    'frontend\Dockerfile',
    'frontend\nginx.conf'
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path (Join-Path $root $file))) {
        throw "Arquivo necessario nao encontrado: $file. Confira se a Etapa 1 foi aplicada."
    }
}

$nginxTemplate = Get-Content (Join-Path $root 'frontend\nginx.conf') -Raw
foreach ($token in @('BACKEND_UPSTREAM', 'DNS_RESOLVER')) {
    if ($nginxTemplate -notmatch [regex]::Escape($token)) {
        throw "O nginx.conf nao contem a variavel esperada '$token'. Revise a configuracao da Etapa 1."
    }
}

$dnsIp = (& kubectl get service kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dnsIp)) {
    throw 'Nao foi possivel descobrir o IP do Service kube-dns.'
}
$frontendYamlPath = Join-Path $root 'k8s\frontend\frontend-deployment.yaml'
$frontendYaml = Get-Content $frontendYamlPath -Raw
if ($frontendYaml -notmatch [regex]::Escape('10.96.0.10')) {
    throw 'O frontend-deployment.yaml nao contem o valor DNS padrao esperado 10.96.0.10; ajuste a verificacao manualmente.'
}
if ($dnsIp -ne '10.96.0.10') {
    $frontendYaml = $frontendYaml.Replace('10.96.0.10', $dnsIp)
    Set-Content -Path $frontendYamlPath -Value $frontendYaml -Encoding UTF8
    Write-Host "DNS_RESOLVER ajustado para $dnsIp em frontend-deployment.yaml" -ForegroundColor Yellow
}
else {
    Write-Host "CoreDNS encontrado em $dnsIp" -ForegroundColor Green
}

Write-Host "`n==> Build do backend" -ForegroundColor Cyan
docker build -t simul-backend:etapa4 .\backend
if ($LASTEXITCODE -ne 0) { throw 'Build do backend falhou.' }

Write-Host "`n==> Build do frontend" -ForegroundColor Cyan
docker build -t simul-frontend:etapa4 .\frontend
if ($LASTEXITCODE -ne 0) { throw 'Build do frontend falhou.' }

Write-Host "`n==> Carregando imagens no Minikube" -ForegroundColor Cyan
minikube image load simul-backend:etapa4 -p simul
if ($LASTEXITCODE -ne 0) { throw 'Falha ao carregar imagem do backend no Minikube.' }
minikube image load simul-frontend:etapa4 -p simul
if ($LASTEXITCODE -ne 0) { throw 'Falha ao carregar imagem do frontend no Minikube.' }

Write-Host "`nImagens construidas e carregadas com sucesso." -ForegroundColor Green
