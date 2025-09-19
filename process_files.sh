#!/bin/bash

# --- Configurações Iniciais e Variáveis de Ambiente ---
# Assume-se que estas variáveis já foram definidas pelo script de deploy, mas são re-exportadas
# para garantir que o script funcione de forma independente.

export CLOUD_RUN_SERVICE_NAME="gemini-file-api"
export REGION="us-central1" # Ajuste para a região que você usou

# Tenta obter a URL do serviço Cloud Run.
export SERVICE_URL=$(gcloud run services describe ${CLOUD_RUN_SERVICE_NAME} --region ${REGION} --format="value(status.url)" 2>/dev/null)
export TOKEN=$(gcloud auth print-identity-token 2>/dev/null)

# --- Variáveis de Chamada (Ajuste conforme necessário) ---
# Prompt que será enviado ao serviço Gemini
# CUSTOM_PROMPT="Analise este documento e extraia todas as informações-chave (nomes, datas, números de identificação). Formate a resposta apenas em JSON."

# --- Funções ---

## Função principal para processar o diretório
process_directory() {
    # 1. Parâmetro de entrada: o diretório contendo os arquivos a serem processados.
    local INPUT_DIR="$1"
    local API_ENDPOINT="${SERVICE_URL}/analyze"

    echo "## 🚀 Iniciando Processamento de Arquivos"
    echo "--------------------------------------------------------"
    echo "Diretório de Entrada: ${INPUT_DIR}"
    echo "URL do Serviço: ${API_ENDPOINT}"
    # echo "Prompt Personalizado: ${CUSTOM_PROMPT}"
    echo "--------------------------------------------------------"

    # Verifica se as variáveis essenciais estão configuradas
    if [ -z "$SERVICE_URL" ] || [ -z "$TOKEN" ]; then
        echo "❌ ERRO: Variáveis de ambiente SERVICE_URL ou TOKEN não configuradas."
        echo "   Verifique se o Cloud Run está implantado e se você está logado ('gcloud auth login')."
        exit 1
    fi

    if [ ! -d "$INPUT_DIR" ]; then
        echo "❌ ERRO: O diretório de entrada '${INPUT_DIR}' não existe ou não é um diretório."
        exit 1
    fi

    # 2. Loop sobre todos os arquivos no diretório de entrada
    for FILE_PATH in "$INPUT_DIR"/*; do
        # Verifica se o item é um arquivo
        if [ -f "$FILE_PATH" ]; then
            local FILENAME=$(basename "$FILE_PATH")
            
            # Cria o nome do arquivo de saída (substitui a extensão original por .json)
            # Ex: "cnh.jpg" -> "cnh.json"
            local OUTPUT_FILENAME="${FILENAME%.*}.json"
            local OUTPUT_PATH="${INPUT_DIR}/${OUTPUT_FILENAME}"
            
            echo ""
            echo "--- Processando arquivo: ${FILENAME} ---"
            echo "--- Diretório de saída: ${OUTPUT_PATH} ---"
            
            # 3. Realiza a chamada POST para o serviço Cloud Run
            # O resultado (JSON) é salvo diretamente no arquivo de saída
            echo "   Chamando a API e salvando em: ${OUTPUT_FILENAME}"
            
            # O comando curl utiliza multipart/form-data para enviar o arquivo e o prompt
            curl -s -X POST "${API_ENDPOINT}" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: multipart/form-data" \
                -F "file=@${FILE_PATH}" \
                -o "${OUTPUT_PATH}"
                # -F "prompt=${CUSTOM_PROMPT}" \

            if [ $? -eq 0 ]; then
                echo "   ✅ Sucesso! Resposta salva em ${OUTPUT_PATH}"
            else
                echo "   ❌ ERRO na chamada CURL para o arquivo ${FILENAME}. Verifique os logs do Cloud Run."
            fi
        fi
    done

    echo ""
    echo "## 🎉 Processamento de diretório concluído."
    echo "--------------------------------------------------------"
}

# --- Execução Principal ---

# Define o diretório a ser processado (pode ser um argumento)
# Exemplo de uso: ./seu_script.sh /caminho/para/seus/documentos
if [ -z "$1" ]; then
    echo "Uso: $0 <CAMINHO_DO_DIRETÓRIO_DE_ARQUIVOS>"
    echo "Exemplo: $0 ./massa_testes"
    exit 1
fi

process_directory "$1"