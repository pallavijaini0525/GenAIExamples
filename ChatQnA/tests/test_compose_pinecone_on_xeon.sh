#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -e
IMAGE_REPO=${IMAGE_REPO:-"opea"}
IMAGE_TAG=${IMAGE_TAG:-"latest"}
echo "REGISTRY=IMAGE_REPO=${IMAGE_REPO}"
echo "TAG=IMAGE_TAG=${IMAGE_TAG}"
export REGISTRY=${IMAGE_REPO}
export TAG=${IMAGE_TAG}

WORKPATH=$(dirname "$PWD")
LOG_PATH="$WORKPATH/tests"
ip_address=$(hostname -I | awk '{print $1}')

function build_docker_images() {
    cd $WORKPATH/docker_image_build
    git clone https://github.com/opea-project/GenAIComps.git

    echo "Build all the images with --no-cache, check docker_image_build.log for details..."
    service_list="chatqna chatqna-ui chatqna-conversation-ui dataprep-pinecone embedding-tei retriever-pinecone reranking-tei llm-tgi"
    docker compose -f build.yaml build ${service_list} --no-cache > ${LOG_PATH}/docker_image_build.log

    docker pull ghcr.io/huggingface/tgi-gaudi:2.0.1
    docker pull ghcr.io/huggingface/text-embeddings-inference:cpu-1.5

    docker images && sleep 1s
}

function start_services() {
    cd $WORKPATH/docker_compose/intel/cpu/xeon/

    export no_proxy=${no_proxy},${ip_address}
    export EMBEDDING_MODEL_ID="BAAI/bge-base-en-v1.5"
    export RERANK_MODEL_ID="BAAI/bge-reranker-base"
    export LLM_MODEL_ID="Intel/neural-chat-7b-v3-3"
    export TEI_EMBEDDING_ENDPOINT="http://${ip_address}:6006"
    export TEI_RERANKING_ENDPOINT="http://${ip_address}:8808"
    export TGI_LLM_ENDPOINT="http://${ip_address}:9009"
    export PINECONE_API_KEY=${PINECONE_KEY_LANGCHAIN_TEST}
    export PINECONE_INDEX_NAME="langchain-test"
    export INDEX_NAME="langchain-test"
    export HUGGINGFACEHUB_API_TOKEN=${HUGGINGFACEHUB_API_TOKEN}
    export MEGA_SERVICE_HOST_IP=${ip_address}
    export EMBEDDING_SERVICE_HOST_IP=${ip_address}
    export RETRIEVER_SERVICE_HOST_IP=${ip_address}
    export RERANK_SERVICE_HOST_IP=${ip_address}
    export LLM_SERVICE_HOST_IP=${ip_address}
    export BACKEND_SERVICE_ENDPOINT="http://${ip_address}:8888/v1/chatqna"
    export DATAPREP_SERVICE_ENDPOINT="http://${ip_address}:6007/v1/dataprep"
    export DATAPREP_GET_FILE_ENDPOINT="http://${ip_address}:6008/v1/dataprep/get_file"
    export DATAPREP_DELETE_FILE_ENDPOINT="http://${ip_address}:6009/v1/dataprep/delete_file"

    sed -i "s/backend_address/$ip_address/g" $WORKPATH/ui/svelte/.env

    # Start Docker Containers
    docker compose -f compose_pinecone.yaml up -d > ${LOG_PATH}/start_services_with_compose.log

    n=0
    until [[ "$n" -ge 200 ]]; do
        docker logs tgi-service > tgi_service_start.log
        if grep -q Connected tgi_service_start.log; then
            break
        fi
        sleep 1s
        n=$((n+1))
    done
}

function validate_services() {
    local URL="$1"
    local EXPECTED_RESULT="$2"
    local SERVICE_NAME="$3"
    local DOCKER_NAME="$4"
    local INPUT_DATA="$5"

    if [[ $SERVICE_NAME == *"dataprep_upload_file"* ]]; then
        cd $LOG_PATH
        HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F 'files=@./dataprep_file.txt' -H 'Content-Type: multipart/form-data' "$URL")
    elif [[ $SERVICE_NAME == *"dataprep_del"* ]]; then
        HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -d '{"file_path": "all"}' -H 'Content-Type: application/json' "$URL")
    else
        HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -d "$INPUT_DATA" -H 'Content-Type: application/json' "$URL")
    fi
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')

    docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log

    # check response status
    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    echo "Response"
    echo $RESPONSE_BODY
    echo "Expected Result"
    echo $EXPECTED_RESULT
    # check response body
    if [[ "$RESPONSE_BODY" != *"$EXPECTED_RESULT"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    sleep 1s
}

function validate_microservices() {
    # Check if the microservices are running correctly.

    # tei for embedding service
    validate_services \
        "${ip_address}:6006/embed" \
        "[[" \
        "tei-embedding" \
        "tei-embedding-server" \
        '{"inputs":"What is Deep Learning?"}'

    # embedding microservice
    validate_services \
        "${ip_address}:6000/v1/embeddings" \
        '"text":"What is Deep Learning?","embedding":[' \
        "embedding" \
        "embedding-tei-server" \
        '{"text":"What is Deep Learning?"}'

    sleep 1m # retrieval can't curl as expected, try to wait for more time

    # test /v1/dataprep/delete_file
    validate_services \
       "http://${ip_address}:6009/v1/dataprep/delete_file" \
       '{"status":true}' \
        "dataprep_del" \
        "dataprep-pinecone-server"


    # test /v1/dataprep upload file
    echo "Deep learning is a subset of machine learning that utilizes neural networks with multiple layers to analyze various levels of abstract data representations. It enables computers to identify patterns and make decisions with minimal human intervention by learning from large amounts of data." > $LOG_PATH/dataprep_file.txt
    validate_services \
       "http://${ip_address}:6007/v1/dataprep" \
        "Data preparation succeeded" \
        "dataprep_upload_file" \
        "dataprep-pinecone-server"


    # retrieval microservice
    test_embedding=$(python3 -c "import random; embedding = [random.uniform(-1, 1) for _ in range(768)]; print(embedding)")
    validate_services \
        "${ip_address}:7000/v1/retrieval" \
        " " \
        "retrieval" \
        "retriever-pinecone-server" \
        "{\"text\":\"What is the revenue of Nike in 2023?\",\"embedding\":${test_embedding}}"

    # tei for rerank microservice
    echo "Validating reranking service"
    validate_services \
        "${ip_address}:8808/rerank" \
        '{"index":1,"score":' \
        "tei-rerank" \
        "tei-reranking-server" \
        '{"query":"What is Deep Learning?", "texts": ["Deep Learning is not...", "Deep learning is..."]}'

    # rerank microservice
    echo "Validating reranking micro service"
    validate_services \
        "${ip_address}:8000/v1/reranking" \
        "Deep learning is..." \
        "rerank" \
        "reranking-tei-xeon-server" \
        '{"initial_query":"What is Deep Learning?", "retrieved_docs": [{"text":"Deep Learning is not..."}, {"text":"Deep learning is..."}]}'

    # tgi for llm service
    echo "Validating llm service"
    validate_services \
        "${ip_address}:9009/generate" \
        "generated_text" \
        "tgi-llm" \
        "tgi-service" \
        '{"inputs":"What is Deep Learning?","parameters":{"max_new_tokens":17, "do_sample": true}}'

    # llm microservice
    echo "Validating llm microservice"
    validate_services \
        "${ip_address}:9000/v1/chat/completions" \
        "data: " \
        "llm" \
        "llm-tgi-server" \
        '{"query":"What is Deep Learning?"}'

}

function validate_megaservice() {
    # Curl the Mega Service
    validate_services \
        "${ip_address}:8888/v1/chatqna" \
        "billion" \
        "mega-chatqna" \
        "chatqna-xeon-backend-server" \
        '{"messages": "What is the revenue of Nike in 2023?"}'

}

function validate_frontend() {
    echo "[ TEST INFO ]: --------- frontend test started ---------"
    cd $WORKPATH/ui/svelte
    local conda_env_name="OPEA_e2e"
    export PATH=${HOME}/miniforge3/bin/:$PATH
    if conda info --envs | grep -q "$conda_env_name"; then
        echo "$conda_env_name exist!"
    else
        conda create -n ${conda_env_name} python=3.12 -y
    fi
    source activate ${conda_env_name}
    echo "[ TEST INFO ]: --------- conda env activated ---------"

    sed -i "s/localhost/$ip_address/g" playwright.config.ts

    conda install -c conda-forge nodejs -y
    npm install && npm ci && npx playwright install --with-deps
    node -v && npm -v && pip list

    exit_status=0
    npx playwright test || exit_status=$?

    if [ $exit_status -ne 0 ]; then
        echo "[TEST INFO]: ---------frontend test failed---------"
        exit $exit_status
    else
        echo "[TEST INFO]: ---------frontend test passed---------"
    fi
}

function stop_docker() {
    echo "In stop docker"
    echo $WORKPATH
    cd $WORKPATH/docker_compose/intel/cpu/xeon/
    docker compose -f compose_pinecone.yaml down
}

function main() {

    stop_docker
    if [[ "$IMAGE_REPO" == "opea" ]]; then build_docker_images; fi
    start_time=$(date +%s)
    start_services
    end_time=$(date +%s)
    duration=$((end_time-start_time))
    echo "Mega service start duration is $duration s" && sleep 1s

    if [ "${mode}" == "perf" ]; then
        python3 $WORKPATH/tests/chatqna_benchmark.py
    elif [ "${mode}" == "" ]; then
        validate_microservices
        echo "==== microservices validated ===="
        validate_megaservice
        echo "==== megaservice validated ===="
    fi

    stop_docker
    echo y | docker system prune

}

main