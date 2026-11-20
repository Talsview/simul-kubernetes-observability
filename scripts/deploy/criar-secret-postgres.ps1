$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$namespace = 'simul'
$secretName = 'postgres-secret'
$dbUser = 'postgres'
$dbName = 'simul'

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl nao foi encontrado no PATH.'
}

$context = (& kubectl config current-context 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($context)) {
    throw 'Nao foi possivel identificar o contexto atual do kubectl.'
}
if ($context.Trim() -ne 'simul') {
    throw "Contexto atual '$($context.Trim())'. Selecione o contexto simul antes de criar o Secret."
}

$namespaceResult = (& kubectl get namespace $namespace -o name 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($namespaceResult -join ''))) {
    throw "Namespace '$namespace' nao existe. Execute primeiro: kubectl apply -f k8s/namespace.yaml"
}

Write-Host "Criando/atualizando o Secret '$secretName' no namespace '$namespace'." -ForegroundColor Cyan
Write-Host 'Use uma senha forte com pelo menos 24 caracteres: letras, numeros e _ @ # % + = . -.'
$securePassword = Read-Host 'Senha do PostgreSQL' -AsSecureString
if ($securePassword.Length -lt 24) {
    throw 'A senha deve ter pelo menos 24 caracteres.'
}

$bstr = [IntPtr]::Zero
$plainPassword = $null
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    if ($plainPassword -notmatch '^[A-Za-z0-9_@#%+=.-]{24,}$') {
        throw 'Use somente letras ASCII, numeros e os caracteres _ @ # % + = . -.'
    }

    $kubectlArgs = @(
        'create', 'secret', 'generic', $secretName,
        '--namespace', $namespace,
        "--from-literal=POSTGRES_USER=$dbUser",
        "--from-literal=POSTGRES_DB=$dbName",
        "--from-literal=POSTGRES_PASSWORD=$plainPassword",
        '--dry-run=client', '-o', 'yaml'
    )

    $secretYaml = & kubectl @kubectlArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'kubectl nao conseguiu gerar o manifesto do Secret.'
    }

    $secretYaml | & kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw 'Falha ao aplicar o Secret no cluster.'
    }

    Write-Host "Secret '$secretName' criado/atualizado. A senha nao foi gravada em arquivo." -ForegroundColor Green
}
finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $plainPassword = $null
    $securePassword = $null
}
