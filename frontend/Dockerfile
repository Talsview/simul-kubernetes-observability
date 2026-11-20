# =============================================================
# SIMUL - Front-end (React + Vite) servido por Nginx
# Build de producao em duas etapas: Node (build) -> Nginx (runtime)
# =============================================================

# ---------- Etapa 1: build ----------
FROM node:22-alpine AS build

WORKDIR /app

# Copia primeiro so os manifestos: a camada de dependencias fica em cache
# enquanto package.json / package-lock.json nao mudarem.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# VITE_API_URL vazio = "mesma origem": o navegador chama /api no proprio
# host do front-end e o Nginx encaminha ao back-end (ver nginx.conf).
# O valor e incorporado ao JavaScript NO BUILD; para mudar, reconstrua a imagem.
ARG VITE_API_URL=""
ENV VITE_API_URL=$VITE_API_URL

RUN npm run build

# ---------- Etapa 2: runtime ----------
FROM nginx:1.28-alpine

# A imagem oficial do Nginx aplica envsubst nos arquivos de
# /etc/nginx/templates/*.template e grava o resultado em /etc/nginx/conf.d/.
# Somente as variaveis definidas no ambiente sao substituidas
# ($uri, $host etc. permanecem intactos).
#   BACKEND_UPSTREAM : endereco do back-end (no Kubernetes: DNS do Service)
#   DNS_RESOLVER     : DNS usado para resolver o back-end em tempo de execucao
#                      (127.0.0.11 = DNS embutido do Docker; no Kubernetes
#                      sera o kube-dns, definido no Deployment)
ENV BACKEND_UPSTREAM=http://backend:8080 \
    DNS_RESOLVER=127.0.0.11

COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
