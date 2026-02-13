#!/bin/bash

set -euo pipefail

AZURE_IDENTITY_NAME=${AZURE_IDENTITY_NAME:-aks-stretch-image-builder-identity}
RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME:-alexbenn-test}

az identity create --name $AZURE_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP_NAME

