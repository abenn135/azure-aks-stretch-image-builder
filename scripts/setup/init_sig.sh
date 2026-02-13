#!/bin/bash

set -euo pipefail

# Must specify AZURE_SUBSCRIPTION_ID out of band
export RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-alexbenn-aks-stretch-test}"
export SIG_NAME="${SIG_NAME:-aksstretchimagesig}"
export SIG_IMAGE_DEFINITION="${SIG_IMAGE_DEFINITION:-aks-stretch}"
export LOCATION="${LOCATION:-eastus2}"
az account set -s ${AZURE_SUBSCRIPTION_ID} >/dev/null 2>&1

echo "Checking if Resource Group ${RESOURCE_GROUP_NAME} exists..."
if ! az group show --name ${RESOURCE_GROUP_NAME} -o none 2>/dev/null; then
    echo "Creating Resource Group ${RESOURCE_GROUP_NAME} in ${LOCATION}..."
    az group create --name ${RESOURCE_GROUP_NAME} --location ${LOCATION} >/dev/null
fi

echo "Checking if Shared Image Gallery ${SIG_NAME} exists in Resource Group ${RESOURCE_GROUP_NAME}..."
if ! az sig show --gallery-name ${SIG_NAME} --resource-group ${RESOURCE_GROUP_NAME} -o none 2>/dev/null; then
    echo "Creating Shared Image Gallery ${SIG_NAME} in Resource Group ${RESOURCE_GROUP_NAME}..."
    az sig create --resource-group ${RESOURCE_GROUP_NAME} --gallery-name ${SIG_NAME} --location ${LOCATION}
fi

echo "Checking if Image Definition ${SIG_IMAGE_DEFINITION} exists in Gallery ${SIG_NAME}..."
if ! az sig image-definition show --gallery-name ${SIG_NAME} --gallery-image-definition ${SIG_IMAGE_DEFINITION} --resource-group ${RESOURCE_GROUP_NAME} -o none 2>/dev/null; then
    echo "Creating Image Definition ${SIG_IMAGE_DEFINITION} in Gallery ${SIG_NAME}..."
    az sig image-definition create \
        --resource-group ${RESOURCE_GROUP_NAME} \
        --gallery-name ${SIG_NAME} \
        --gallery-image-definition ${SIG_IMAGE_DEFINITION} \
        --publisher ${SIG_PUBLISHER:-capz} \
        --offer ${SIG_OFFER:-capz-demo} \
        --sku '24_04' \
        --hyper-v-generation V2 \
        --os-type Linux \
        --architecture 'x64'
fi
