import os
import logging
import flask
from flask import Response
import json # Importar json
from google import genai
from google.genai import types

from pydantic import BaseModel, create_model # Importar create_model
from typing import Optional, Type # Importar Type

import vertexai
from vertexai.generative_models import GenerativeModel, Part, HarmCategory, HarmBlockThreshold

from dotenv import load_dotenv
load_dotenv('.env')

# --- Define formato da resposta (agora será dinâmico) ---
# Removeremos a definição estática de ResultadoExtracao aqui.

# --- Configuração ---
logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.environ.get("GCP_PROJECT")
LOCATION = os.environ.get("GCP_REGION")
GCP_API_KEY = os.environ.get("GCP_API_KEY")

client = genai.Client(api_key=GCP_API_KEY)

app = flask.Flask(__name__)

@app.route("/analyze", methods=["POST"])
def analyze_file():
    """
    Endpoint de API que recebe um arquivo e um prompt via multipart/form-data,
    analisa o arquivo com o Gemini e retorna o resultado em JSON.
    """
    try:
        # --- Validação da Requisição ---
        if 'file' not in flask.request.files:
            return flask.jsonify({"error": "Nenhum arquivo enviado. A requisição deve conter uma parte 'file'."}), 400

        file = flask.request.files['file']

        if file.filename == '':
            return flask.jsonify({"error": "O arquivo enviado não tem nome."}), 400
            
        # --- Lógica Principal ---
        logging.info(f"Processando o arquivo recebido: {file.filename} ({file.mimetype})")

        # 1. Ler os dados do arquivo e o prompt da requisição
        file_bytes = file.read()
        mime_type = file.mimetype

        # O prompt pode ser enviado como um campo de formulário.
        # Se não for enviado, usamos um prompt padrão.
        # É CRUCIAL que o prompt instrua o modelo a retornar um JSON bem formado.
        prompt = flask.request.form.get('prompt', 
            """
            Analise o conteúdo do arquivo fornecido e extraia as informações relevantes.
            Responda em formato JSON. Inclua apenas os campos para os quais você pode extrair informações.
            Se houver mais de um documento no arquivo, responda utilizando a estrutura de exemplo, incluindo as informações de cada documentos no mesmo array.
            Para cada campo do exemplo fornecido, caso não encontre informações no arquivo, deixe o campo vazio, não invente informações.
            Para o campo data_processamento, coloque as informações de data hora do momento que gerou a resposta.
            Utilize os exemplos de estrutura JSON fornecidos. Não altere esse formato:
            Para uma carteirinha, use o seguinte formato:
            {
                "documentos": [
                    {
                        "tipo_documento": "Carteirinha",
                        "numero_documento": "898001160400174",
                        "emissor": "Sulamerica",
                        "data_emissao": "2019-02-12",
                        "data_validade": "26-01",
                        "titular": {
                            "nome": "Ana Carolina Souza",
                            "data_nascimento": "1988-07-25",
                        },
                        "dependente": {
                            "nome": "Carlos Alberto",
                            "data_nascimento": "200"-07-25",
                        },
                        "dados_extras": {
                            "plano_saude": "FUNC SP I",
                            "categoria": "APARTAMENTO",
                            "produto": 582
                            "abrangencia": "XPTO"
                        },
                        "metadados": {
                            "confianca_extracao": 0.94,
                            "data_processamento": "2025-09-09T16:30:00Z"
                        }
                    }
                ]
            }

            Para uma carteira de habilitação ou de motorista, use o seguinte formato:
            {
                "documentos": [
                    {
                        "tipo_documento": "CNH",
                        "numero_documento": "123456789",
                        "emissor": "DETRAN-SP",
                        "data_emissao": "2018-05-10", {Para a data_emissao, somente considere o campo data emissão do documento. Senão encontrar, deixe vazio na sua resposta}
                        "data_validade": "2028-05-10",
                        "titular": {
		                    "nome": "Ana Carolina Souza",
		                    "data_nascimento": "1988-07-25",
	                    }
                    }
                ]
            }

            Para um RG, use o seguinte formato:
            {
                "documentos": [
                    {
                        "tipo_documento": "RG",
                        "numero_documento": "123456789",
                        "emissor": "SSP-SP", {O emissor deverá ser a informação do campo data emissão. Senão encontrar, procure o campo doc. identidade. Senão encontrar, deixe o campo vazio}
                        "data_emissao": "2015-08-22",
                        "data_validade": "2025-09-12",
                        "titular": {
		                    "nome": "Ana Carolina Souza",
		                    "data_nascimento": "1988-07-25",
	                    }
                    }
                ]
            }
            
            
            Responda em português.
            """
        )

        logging.info(f"Usando o prompt: '{prompt[:200]}...'") # Aumentei o log do prompt para ver mais

        # 2. Preparar a requisição para a API do Gemini
        file_part = types.Part.from_bytes(data=file_bytes, mime_type=mime_type)

        # 3. Chamar a API do Gemini
        logging.info("Enviando requisição para o Gemini sem schema fixo...")

        # Removemos 'response_schema' para permitir resposta JSON dinâmica.
        # É fundamental que o prompt instrua o modelo a retornar JSON.
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=[file_part, prompt], 
            config={
                "response_mime_type": "application/json",
            }
            # safety_settings={...} (comentado por padrão)
        )

        # 4. Processar a resposta do Gemini e criar um schema Pydantic dinamicamente
        analysis_result_str = response.text
        # logging.info(f"Resposta bruta do Gemini: {analysis_result_str}...") # Log da resposta bruta

        # Tentar carregar o JSON da resposta
        try:
            analysis_data = json.loads(analysis_result_str)
        except json.JSONDecodeError as e:
            logging.error(f"Erro ao decodificar JSON da resposta do Gemini: {e}")
            return flask.jsonify({"error": "O Gemini retornou um JSON inválido.", "raw_response": analysis_result_str}), 500

        # Criar um schema Pydantic dinamicamente a partir das chaves do JSON retornado
        dynamic_fields = {}
        for key, value in analysis_data.items():
            # A heurística para o tipo pode ser aprimorada
            if isinstance(value, str):
                dynamic_fields[key] = (Optional[str], None)
            elif isinstance(value, int):
                dynamic_fields[key] = (Optional[int], None)
            elif isinstance(value, float):
                dynamic_fields[key] = (Optional[float], None)
            elif isinstance(value, bool):
                dynamic_fields[key] = (Optional[bool], None)
            elif isinstance(value, list):
                dynamic_fields[key] = (Optional[list], None)
            else:
                # Caso não seja um tipo básico, trate como string ou ajuste conforme sua necessidade
                dynamic_fields[key] = (Optional[str], None)
        
        # Cria a classe Pydantic dinamicamente
        # O nome da classe é arbitrário, mas bom para depuração
        DynamicSchema: Type[BaseModel] = create_model("DynamicSchema", **dynamic_fields)

        # Tentar validar a resposta do Gemini contra o schema dinâmico
        try:
            validated_data = DynamicSchema(**analysis_data)
            logging.info("Dados do Gemini validados com sucesso usando schema dinâmico.")
            # Podemos retornar validated_data.dict() ou a análise original
            final_response_data = validated_data.model_dump(exclude_unset=True) # Exclui campos que não foram definidos na resposta
        except Exception as e:
            logging.warning(f"A validação do schema dinâmico falhou: {e}. Retornando a análise bruta.")
            final_response_data = analysis_data # Retorna o JSON como veio se a validação falhar

        response_data = {
            "fileName": file.filename,
            "mimeType": mime_type,
            "analysis": final_response_data
        }

        # response = Response(response_data, content_type='application/json; charset=utf-8')

        # print ("Valor de response:", response.json)

        return flask.jsonify(response_data), 200

    except Exception as e:
        logging.error(f"Ocorreu um erro inesperado: {e}", exc_info=True)
        return flask.jsonify({"error": "Ocorreu um erro interno no servidor ao processar o arquivo."}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))