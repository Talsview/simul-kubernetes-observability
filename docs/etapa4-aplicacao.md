# Etapa 4 — Aplicação SIMUL replicada no Kubernetes

## O que esta etapa implanta

- Backend Spring Boot em Deployment com 2 réplicas.
- Service ClusterIP `backend-service` na porta 8080.
- Frontend React servido por Nginx em Deployment com 2 réplicas.
- Service NodePort `frontend-service` na porta 30080.
- ConfigMap para configurações não sensíveis.
- Secret `backend-secret` para JWT, SMTP fictício e VAPID.
- Cabeçalho `X-Served-By` nas respostas `/api/*`, ativo somente com o perfil `k8s`.

O PostgreSQL da Etapa 3 é reutilizado pelo DNS interno `postgres-service.simul.svc.cluster.local:5432`.

## Pré-requisitos

Execute na raiz do repositório e confirme:

```powershell
kubectl config current-context
kubectl get pods,pvc,svc -n simul
kubectl get svc kube-dns -n kube-system -o wide
```

O contexto deve ser `simul`, `postgres-0` deve estar `1/1 Running` e o PVC `postgres-data` deve estar `Bound`.

O `frontend-deployment.yaml` recebe `DNS_RESOLVER`. O script de build consulta o IP real do Service `kube-dns` e atualiza esse valor no manifesto caso seja diferente do padrão `10.96.0.10`.

## 1. Criar o Secret do backend

Requer Node.js/npm disponíveis no PATH. O script gera JWT_SECRET com 256 bits e um par VAPID válido usando `npx web-push generate-vapid-keys --json`.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\deploy\criar-secret-backend.ps1
kubectl get secret backend-secret -n simul
```

O Secret contém `JWT_SECRET`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY` e `WEB_PUSH_VAPID_SUBJECT`.

O script não sobrescreve Secret existente para evitar rotação acidental das chaves JWT/VAPID. Guarde o Secret no cluster e não publique valores ou saídas decodificadas.

SMTP está intencionalmente configurado como fictício (`127.0.0.1:1025`, usuário/senha `disabled`). Envio de e-mail e recuperação por e-mail não fazem parte da demonstração. O scheduler de notificações permanece desligado nas duas réplicas.

## 2. Build e carga das imagens

O script valida os Dockerfiles criados na Etapa 1, confirma as variáveis esperadas no template Nginx, detecta o IP do CoreDNS, constrói as duas imagens e carrega-as no Minikube.

```powershell
.\scripts\deploy\build-load-etapa4.ps1
```

Tags usadas:

- `simul-backend:etapa4`
- `simul-frontend:etapa4`

## 3. Aplicar os manifestos

```powershell
kubectl apply -f k8s/backend/backend-configmap.yaml
kubectl apply -f k8s/backend/backend-service.yaml
kubectl apply -f k8s/frontend/frontend-service.yaml
kubectl apply -f k8s/backend/backend-deployment.yaml
kubectl apply -f k8s/frontend/frontend-deployment.yaml
```

As réplicas do backend iniciam com Flyway habilitado. O Flyway aplica as migrations V1–V16 no banco existente. As duas instâncias usam o mesmo JWT_SECRET para que tokens emitidos por uma réplica sejam aceitos pela outra.

## 4. Aguardar e conferir

```powershell
kubectl rollout status deployment/backend -n simul --timeout=600s
kubectl rollout status deployment/frontend -n simul --timeout=180s
kubectl get pods,svc,endpoints -n simul -o wide
kubectl top pods -n simul
```

Esperado:

- 2 Pods `backend` em `2/2` ou `1/1` conforme a tabela de saída (um container por Pod), estado `Running` e `Ready`.
- 2 Pods `frontend` em `1/1 Running`.
- `backend-service` com dois endpoints prontos.
- `frontend-service` como NodePort `30080`.
- PVC `postgres-data` continua `Bound`.

Para conferir a versão máxima do Flyway:

```powershell
kubectl exec -n simul postgres-0 -- psql -U postgres -d simul -c "SELECT COUNT(*) AS migrations_aplicadas, MAX(version) AS ultima_versao FROM flyway_schema_history WHERE success = true;"
```

Esperado: 16 migrations bem-sucedidas e última versão `16`.

## 5. Abrir a aplicação

Em um terminal PowerShell separado, mantenha o túnel ativo:

```powershell
minikube service frontend-service -n simul -p simul --url
```

Abra a URL exibida no navegador. O Nginx serve o React e encaminha `/api/` ao Service interno `backend-service`.

Teste a API pública pelo mesmo endereço, substituindo `<URL>` pela URL apresentada:

```powershell
Invoke-RestMethod -Uri '<URL>/api/rotas/areas'
Invoke-RestMethod -Uri '<URL>/api/rotas/consulta'
```

## 6. Provar o balanceamento do backend

Com a URL do túnel ativa, faça requisições novas e veja o cabeçalho `X-Served-By`:

```powershell
$url = '<URL>'
1..12 | ForEach-Object {
    $response = Invoke-WebRequest -Uri "$url/api/rotas/areas" -Headers @{ Connection = 'close' }
    [pscustomobject]@{
        Requisicao = $_
        BackendPod = $response.Headers['X-Served-By']
        FrontendPod = $response.Headers['X-Frontend-Pod']
    }
}
```

As respostas devem mostrar os nomes dos dois Pods backend ao longo das chamadas. O balanceamento do Service Kubernetes é por conexão; por isso o teste usa requisições independentes.

## 7. Diagnóstico

```powershell
kubectl get pods -n simul -o wide
kubectl describe pods -n simul
kubectl logs deployment/backend -n simul --all-pods=true --tail=100
kubectl logs deployment/frontend -n simul --all-pods=true --tail=80
kubectl get endpoints backend-service frontend-service -n simul
kubectl top pods -n simul
```

Se um backend não iniciar, veja primeiro `kubectl logs` e `kubectl describe pod`. Problemas comuns: Secret ausente, chave VAPID inválida, senha PostgreSQL diferente da usada na Etapa 3 ou Flyway/JPA encontrando schema incompatível.

## Limites desta etapa

Ainda não instala Actuator, Prometheus, Loki, Tempo ou OpenTelemetry. Eles serão adicionados na etapa de observabilidade. As probes de backend nesta fase usam TCP na porta 8080; frontend usa o endpoint Nginx `/healthz`.
