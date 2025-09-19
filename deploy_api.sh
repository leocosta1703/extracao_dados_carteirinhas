#!/bin/bash

# --- Variáveis Globais ---
# Define as variáveis de ambiente baseadas no ambiente gcloud atual
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")
export REGION="us-central1" # Ajuste para a sua região preferida
export SERVICE_ACCOUNT="sa-gemini-api"
export CLOUD_RUN_SERVICE_NAME="gemini-file-api"
export PRINCIPAL=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)")
export SA_FULL_EMAIL="${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"
export COMPUTE_SA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# --- Funções ---

## 1. Configurar Variáveis de Ambiente e Verificar Pré-requisitos
# A maioria das variáveis já é definida no início do script. Esta função é para
# garantir que o ambiente base está configurado corretamente.
setup_environment() {
    echo "## 1. Configurando Variáveis de Ambiente e Verificando Pré-requisitos..."
    echo "--------------------------------------------------------"
    if [ -z "$PROJECT_ID" ]; then
        echo "❌ ERRO: O ID do projeto não foi encontrado. Certifique-se de que está autenticado e o projeto está configurado."
        echo "Use 'gcloud auth login' e 'gcloud config set project [PROJECT_ID]'."
        exit 1
    fi
    echo "✅ Variáveis de ambiente configuradas:"
    echo "   PROJECT_ID: $PROJECT_ID"
    echo "   REGION: $REGION"
    echo "   SERVICE_ACCOUNT: $SERVICE_ACCOUNT"
    echo "   CLOUD_RUN_SERVICE_NAME: $CLOUD_RUN_SERVICE_NAME"
    echo "--------------------------------------------------------"
}

---

## 2. Configurar Serviços GCP e Permissões
configure_gcp_services() {
    echo "## 2. Habilitando APIs e Configurando Service Account/Permissões..."
    echo "--------------------------------------------------------"
    
    # Habilitar APIs
    echo "🚀 Habilitando APIs necessárias..."
    gcloud services enable \
        aiplatform.googleapis.com \
        logging.googleapis.com \
        artifactregistry.googleapis.com \
        cloudfunctions.googleapis.com \
        run.googleapis.com \
        cloudbuild.googleapis.com
    echo "✅ APIs habilitadas."
    
    # Criar Service Account (ignora erro se já existir)
    echo "⚙️ Criando Service Account: ${SERVICE_ACCOUNT}..."
    if gcloud iam service-accounts describe ${SA_FULL_EMAIL} &> /dev/null; then
        echo "   Service Account já existe. Prosseguindo."
    else
        gcloud iam service-accounts create ${SERVICE_ACCOUNT} --display-name="Service Account for Gemini API" --quiet
        echo "   Service Account ${SERVICE_ACCOUNT} criada."
    fi
    
    # Conceder permissão `roles/aiplatform.user` à nova SA
    echo "🔐 Concedendo role 'roles/aiplatform.user' à ${SA_FULL_EMAIL}..."
    gcloud projects add-iam-policy-binding ${PROJECT_ID} \
        --member="serviceAccount:${SA_FULL_EMAIL}" \
        --role="roles/aiplatform.user" --quiet
    echo "   Permissão de Vertex AI concedida."

    # Conceder permissão `roles/run.builder` à Compute SA para Build
    echo "🔐 Concedendo role 'roles/run.builder' à ${COMPUTE_SA_EMAIL} (para builds)..."
    gcloud projects add-iam-policy-binding ${PROJECT_ID} \
        --member="serviceAccount:${COMPUTE_SA_EMAIL}" \
        --role="roles/run.builder" --quiet
    echo "   Permissão de Cloud Run Builder concedida."

    # Conceder permissão de 'Service Account User' ao PRINCIPAL (usuário logado) na Compute SA
    # Isso permite que o usuário execute a implantação usando a SA de Compute, se necessário.
    echo "🔐 Concedendo role 'roles/iam.serviceAccountUser' ao PRINCIPAL (${PRINCIPAL}) na Service Account de Compute..."
    gcloud iam service-accounts add-iam-policy-binding ${COMPUTE_SA_EMAIL} \
        --member="user:${PRINCIPAL}" \
        --role="roles/iam.serviceAccountUser" --quiet
    echo "   Permissão de Service Account User concedida."

    echo "--------------------------------------------------------"
}

---

## 3. Implantar o Cloud Run
deploy_cloud_run() {
    echo "## 3. Implantando o serviço Cloud Run..."
    echo "--------------------------------------------------------"
    echo "🛠️ Iniciando a implantação do serviço ${CLOUD_RUN_SERVICE_NAME} na região ${REGION}..."

    # O comando `gcloud run deploy` com `--source .` irá automaticamente construir uma imagem
    # a partir do código no diretório atual (usando Cloud Build e um Dockerfile ou Buildpack)
    # e, em seguida, implantá-la no Cloud Run.
    gcloud run deploy ${CLOUD_RUN_SERVICE_NAME} \
        --source . \
        --platform managed \
        --region ${REGION} \
        --service-account "${SA_FULL_EMAIL}" \
        --allow-unauthenticated \
        --set-env-vars="GCP_PROJECT=${PROJECT_ID},GCP_REGION=${REGION}" \
        --timeout=300 \
        --quiet

    if [ $? -eq 0 ]; then
        echo "✅ Implantação do Cloud Run concluída com sucesso!"
        export SERVICE_URL=$(gcloud run services describe ${CLOUD_RUN_SERVICE_NAME} --region ${REGION} --format="value(status.url)")
        echo "🔗 URL do Serviço: ${SERVICE_URL}"
    else
        echo "❌ ERRO: Falha na implantação do Cloud Run."
    fi
    echo "--------------------------------------------------------"
}

# --- Execução Principal ---

# Garante que o script pare se qualquer comando falhar
set -e

# 1. Configurar variáveis
setup_environment

# 2. Criar serviços e permissões
# configure_gcp_services

# 3. Implantar o Cloud Run
deploy_cloud_run

echo "🎉 O ambiente Cloud Run foi configurado e o serviço ${CLOUD_RUN_SERVICE_NAME} foi implantado."
echo ""
echo "--- Próximos Passos (Exemplo de Chamada de Teste) ---"
echo "Você pode usar as variáveis abaixo para testar o serviço:"

# Exemplo de chamada (apenas mostra os comandos, não executa o curl)
echo 'export TOKEN=$(gcloud auth print-identity-token)'
echo "export SERVICE_URL=${SERVICE_URL}"
echo 'export FILE_PATH="./caminho/para/seu/arquivo.jpg" # (Substitua pelo caminho real)'
echo 'export CUSTOM_PROMPT="O que você vê neste arquivo?"'
echo 'curl -X POST "${SERVICE_URL}/analyze" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: multipart/form-data" \
      -F "file=@${FILE_PATH}" \
      -F "prompt=${CUSTOM_PROMPT}"'