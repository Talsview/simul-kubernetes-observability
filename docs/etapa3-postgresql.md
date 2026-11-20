# Etapa 3 — PostgreSQL no Kubernetes

## Contexto do SIMUL

O backend usa PostgreSQL, banco `simul`, usuário documentado `postgres` e URL JDBC no formato `jdbc:postgresql://<host>:5432/simul`. O `application.properties` exige `DB_URL`, `DB_USERNAME` e `DB_PASSWORD`. O Hibernate usa `ddl-auto=validate` e o Flyway está habilitado.

As migrations V1–V16 estão em `backend/src/main/resources/db/migration`. Elas serão executadas pelo backend quando ele for implantado. O Pod PostgreSQL não executa migrations nem importa SQL manualmente.

A migration V9 cria `geometria_geojson` como `TEXT`; não há dependência de PostGIS nas migrations analisadas.

## Recursos criados

- Namespace `simul`.
- PVC `postgres-data` (2 GiB, StorageClass `standard`).
- Headless Service `postgres-headless` para a identidade de rede do StatefulSet.
- ClusterIP Service `postgres-service` para os clientes internos.
- StatefulSet `postgres`, uma réplica.
- Secret `postgres-secret`, criado localmente sem salvar a senha em arquivo.

Imagem: `postgres:18.7-alpine3.24`.

No PostgreSQL 18, o diretório de dados padrão é `/var/lib/postgresql/18/docker`. A imagem oficial alterou também o volume para `/var/lib/postgresql`; por isso o PVC é montado nesse diretório pai.

## Aplicação no PowerShell

Execute os comandos na raiz do repositório e confirme que o contexto é `simul`:

```powershell
kubectl config current-context
kubectl apply -f k8s/namespace.yaml
.\scripts\deploy\criar-secret-postgres.ps1
kubectl apply -f k8s/database/postgres-pvc.yaml
kubectl apply -f k8s/database/postgres-headless-service.yaml
kubectl apply -f k8s/database/postgres-service.yaml
kubectl apply -f k8s/database/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n simul --timeout=300s
```

O script solicita uma senha forte (mínimo de 24 caracteres) e cria/atualiza `postgres-secret` no cluster. A senha não é exibida nem gravada em arquivo. O script recusa operar se o contexto atual não for `simul`.

`k8s/secrets/postgres.env.example` é somente um modelo ilustrativo. **Não aplique esse arquivo como Secret e não substitua a senha real por seu placeholder.**

## Conferência inicial

```powershell
kubectl get pods,pvc,svc -n simul
kubectl describe pvc postgres-data -n simul
kubectl logs statefulset/postgres -n simul --tail=80
kubectl exec -n simul postgres-0 -- psql -U postgres -d simul -c "SELECT version();"
```

O esperado é Pod `postgres-0` Ready, PVC `postgres-data` em `Bound` e os dois Services presentes.

## Teste de persistência

Depois que o Pod estiver Ready, execute:

```powershell
.\scripts\validation\etapa3-postgres.ps1
```

O script cria uma tabela temporária de validação, grava um marcador, exclui somente o Pod `postgres-0`, espera o StatefulSet recriá-lo e verifica se o marcador continua no banco. Ao passar, a tabela de teste é removida.

## Segurança e retenção

- PostgreSQL fica exposto somente por `ClusterIP`, sem NodePort ou LoadBalancer.
- Credenciais são guardadas no Secret `postgres-secret`.
- Não versionar Secrets, arquivos de senha ou YAMLs gerados com credenciais.
- O StorageClass `standard` do Minikube usa política de reclaim `Delete`. Excluir o PVC pode excluir o volume e os dados; não execute `kubectl delete pvc postgres-data` nem `minikube delete` durante os testes de persistência.
- Excluir o Pod é seguro para este teste: o StatefulSet o recria usando o mesmo PVC.

## Limite desta etapa

Esta etapa termina após comprovar Pod Ready, PVC Bound, conexão local via `psql` e persistência após recriação do Pod. A implantação do backend e a execução das migrations ocorrerão somente na etapa seguinte.
