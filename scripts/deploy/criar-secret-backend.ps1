$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$namespace = 'simul'
$secretName = 'backend-secret'

foreach ($command in @('kubectl', 'npx')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command nao foi encontrado no PATH. Instale/ative Node.js e kubectl antes de continuar."
    }
}

$context = (& kubectl config current-context 2>$null)
if ($LASTEXITCODE -ne 0 -or $context.Trim() -ne 'simul') {
    throw "Contexto atual '$context'. Selecione 'simul' antes de criar o Secret."
}

& kubectl get namespace $namespace *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Namespace '$namespace' nao existe."
}

$existingSecret = & kubectl get secret $secretName -n $namespace --ignore-not-found -o name

if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar o Secret '$secretName'."
}

if ($existingSecret) {
    throw "O Secret '$secretName' ja existe. Nao vou sobrescrever JWT/VAPID automaticamente."
}

Write-Host 'Gerando JWT_SECRET aleatorio (256 bits)...' -ForegroundColor Cyan
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($bytes)
    $jwtSecret = [Convert]::ToBase64String($bytes)
}
finally {
    $rng.Dispose()
}

Write-Host 'Gerando um par VAPID valido com o utilitario web-push...' -ForegroundColor Cyan
$vapidOutput = & npx --yes web-push generate-vapid-keys --json 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Falha ao gerar as chaves VAPID via npx. Verifique Node.js, npm e acesso ao registry.npmjs.org.'
}
$vapidText = ($vapidOutput | Out-String).Trim()
try {
    $vapid = $vapidText | ConvertFrom-Json
}
catch {
    throw 'A saida do gerador VAPID nao era JSON valido. Nenhum Secret foi criado.'
}
if ([string]::IsNullOrWhiteSpace($vapid.publicKey) -or [string]::IsNullOrWhiteSpace($vapid.privateKey)) {
    throw 'O gerador VAPID nao retornou as duas chaves esperadas.'
}

$subject = Read-Host 'Subject VAPID (Enter usa mailto:simul-k8s@example.invalid)'
if ([string]::IsNullOrWhiteSpace($subject)) {
    $subject = 'mailto:simul-k8s@example.invalid'
}
if ($subject -notmatch '^(mailto:.+|https://.+)$') {
    throw 'O subject VAPID deve comecar com mailto: ou https://.'
}

# SMTP intencionalmente ficticio: e-mail nao faz parte da demonstracao.
# O backend inicializa, mas tentativas de envio nao serao entregues.
$secretArgs = @(
    'create', 'secret', 'generic', $secretName,
    '--namespace', $namespace,
    "--from-literal=JWT_SECRET=$jwtSecret",
    '--from-literal=SMTP_USERNAME=disabled',
    '--from-literal=SMTP_PASSWORD=disabled',
    "--from-literal=WEB_PUSH_VAPID_PUBLIC_KEY=$($vapid.publicKey)",
    "--from-literal=WEB_PUSH_VAPID_PRIVATE_KEY=$($vapid.privateKey)",
    "--from-literal=WEB_PUSH_VAPID_SUBJECT=$subject",
    '--dry-run=client', '-o', 'yaml'
)

$secretYaml = & kubectl @secretArgs
if ($LASTEXITCODE -ne 0) {
    throw 'kubectl nao conseguiu gerar o manifesto do Secret.'
}
$secretYaml | & kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    throw 'Falha ao aplicar backend-secret.'
}

$jwtSecret = $null
$vapidText = $null
$vapid = $null
$secretYaml = $null
Write-Host "Secret '$secretName' criado. JWT e chave privada VAPID nao foram exibidos nem gravados em arquivo." -ForegroundColor Green
