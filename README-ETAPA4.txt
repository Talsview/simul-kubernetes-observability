SIMUL — Etapa 4

Aplique o conteúdo deste ZIP na raiz do repositório simul-system, preservando os arquivos existentes.

1) Confira o diff:
   git status
   git diff --check

2) Leia docs/etapa4-aplicacao.md.

3) Crie o Secret:
   .\scripts\deploy\criar-secret-backend.ps1

4) Construa e carregue as imagens:
   .\scripts\deploy\build-load-etapa4.ps1

5) Aplique os manifestos conforme a documentação.

Não avance para observabilidade até que os dois Deployments estejam prontos, o frontend esteja acessível e o cabeçalho X-Served-By comprove respostas dos dois Pods backend.
