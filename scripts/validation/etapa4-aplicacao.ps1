$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ((& kubectl config current-context).Trim() -ne 'simul') {
    throw "O contexto kubectl precisa ser 'simul'."
}

Write-Host '==> Rollout do backend' -ForegroundColor Cyan
kubectl rollout status deployment/backend -n simul --timeout=600s
if ($LASTEXITCODE -ne 0) { throw 'Backend nao concluiu o rollout.' }

Write-Host '==> Rollout do frontend' -ForegroundColor Cyan
kubectl rollout status deployment/frontend -n simul --timeout=180s
if ($LASTEXITCODE -ne 0) { throw 'Frontend nao concluiu o rollout.' }

Write-Host "`n==> Pods, Services e endpoints" -ForegroundColor Cyan
kubectl get pods,svc,endpoints -n simul -o wide

Write-Host "`n==> Migrations Flyway" -ForegroundColor Cyan
kubectl exec -n simul postgres-0 -- psql -U postgres -d simul -c "SELECT COUNT(*) AS migrations_aplicadas, MAX(version) AS ultima_versao FROM flyway_schema_history WHERE success = true;"
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel consultar flyway_schema_history.' }

Write-Host "`nValidacao estrutural concluida. Teste a URL do frontend e o balanceamento seguindo docs/etapa4-aplicacao.md." -ForegroundColor Green
