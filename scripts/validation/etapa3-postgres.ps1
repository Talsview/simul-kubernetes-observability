$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$namespace = 'simul'
$podName = 'postgres-0'
$pvcName = 'postgres-data'

function Assert-KubectlSuccess([string]$message) {
    if ($LASTEXITCODE -ne 0) {
        throw $message
    }
}

$context = (& kubectl config current-context 2>$null)
Assert-KubectlSuccess 'Nao foi possivel ler o contexto do kubectl.'
if ($context.Trim() -ne 'simul') {
    throw "Contexto atual '$($context.Trim())'. O teste exige o contexto simul."
}

Write-Host '1/5 - Aguardando PostgreSQL ficar Ready...' -ForegroundColor Cyan
& kubectl wait --for=condition=Ready "pod/$podName" -n $namespace --timeout=300s
Assert-KubectlSuccess 'O Pod postgres-0 nao ficou Ready.'

Write-Host '2/5 - Conferindo PVC Bound...' -ForegroundColor Cyan
$pvcPhase = (& kubectl get pvc $pvcName -n $namespace -o jsonpath='{.status.phase}').Trim()
Assert-KubectlSuccess 'Nao foi possivel consultar o PVC.'
if ($pvcPhase -ne 'Bound') {
    throw "PVC '$pvcName' esta '$pvcPhase', esperado Bound."
}

Write-Host '3/5 - Verificando versao e gravando marcador temporario...' -ForegroundColor Cyan
$version = (& kubectl exec -n $namespace $podName -- psql -U postgres -d simul -Atc 'SHOW server_version;').Trim()
Assert-KubectlSuccess 'Falha ao consultar a versao do PostgreSQL.'
Write-Host "PostgreSQL: $version"
if ($version -notmatch '^18\.7') {
    throw "Versao inesperada do PostgreSQL: $version (esperado 18.7)."
}

$marker = 'simul-persistence-' + [guid]::NewGuid().ToString('N')
$sql = "CREATE TABLE IF NOT EXISTS public.k8s_persistence_validation (id integer PRIMARY KEY, marker text NOT NULL); INSERT INTO public.k8s_persistence_validation (id, marker) VALUES (1, '$marker') ON CONFLICT (id) DO UPDATE SET marker = EXCLUDED.marker;"
& kubectl exec -n $namespace $podName -- psql -U postgres -d simul -v ON_ERROR_STOP=1 -c $sql
Assert-KubectlSuccess 'Falha ao gravar o marcador de persistencia.'

Write-Host '4/5 - Excluindo somente o Pod para testar a recriacao...' -ForegroundColor Cyan
& kubectl delete pod $podName -n $namespace --wait=true --timeout=120s
Assert-KubectlSuccess 'Falha ao excluir o Pod para o teste.'

$deadline = (Get-Date).AddMinutes(5)
$found = $false
do {
    $podResult = (& kubectl get pod $podName -n $namespace --ignore-not-found -o name 2>$null)
    if (-not [string]::IsNullOrWhiteSpace(($podResult -join ''))) {
        $found = $true
        break
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
if (-not $found) {
    throw 'O StatefulSet nao recriou o Pod postgres-0 em 5 minutos.'
}

& kubectl wait --for=condition=Ready "pod/$podName" -n $namespace --timeout=300s
Assert-KubectlSuccess 'O Pod recriado nao ficou Ready.'

Write-Host '5/5 - Conferindo se o marcador sobreviveu...' -ForegroundColor Cyan
$persistedMarker = (& kubectl exec -n $namespace $podName -- psql -U postgres -d simul -Atc 'SELECT marker FROM public.k8s_persistence_validation WHERE id = 1;').Trim()
Assert-KubectlSuccess 'Falha ao consultar o marcador depois da recriacao.'
if ($persistedMarker -ne $marker) {
    throw 'O marcador nao corresponde. A persistencia nao foi comprovada.'
}

& kubectl exec -n $namespace $podName -- psql -U postgres -d simul -v ON_ERROR_STOP=1 -c 'DROP TABLE public.k8s_persistence_validation;'
Assert-KubectlSuccess 'Persistencia comprovada, mas nao foi possivel remover a tabela temporaria de teste.'

Write-Host ''
Write-Host 'ETAPA 3 - TESTE DO POSTGRESQL APROVADO' -ForegroundColor Green
Write-Host "PVC: $pvcName ($pvcPhase) | PostgreSQL: $version | Pod recriado e dados preservados."
