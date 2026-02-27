#!/bin/bash

set -euo pipefail

if [ -z "${GROUP:-}" ]; then
  echo "Error: GROUP is not set. Please set it before running this script."
  exit 1
fi
if [ -z "${LOCATION:-}" ]; then
  echo "Error: LOCATION is not set. Please set it before running this script."
  exit 1
fi

if ! az storage account show -n $STORAGE_ACCOUNT_NAME -g $GROUP &>/dev/null; then
    echo "Creating storage account $STORAGE_ACCOUNT_NAME in resource group $GROUP..."
    az storage account create \
        -n $STORAGE_ACCOUNT_NAME \
        -g $GROUP \
        -l $LOCATION \
        --sku Standard_LRS
else
    echo "Storage account $STORAGE_ACCOUNT_NAME already exists in resource group $GROUP. Skipping storage account creation."
fi

if ! az storage container show -n $STORAGE_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME &>/dev/null; then
    echo "Creating storage container $STORAGE_CONTAINER_NAME in storage account $STORAGE_ACCOUNT_NAME..."
    az storage container create \
        -n $STORAGE_CONTAINER_NAME \
        --account-name $STORAGE_ACCOUNT_NAME
else
    echo "Storage container $STORAGE_CONTAINER_NAME already exists in storage account $STORAGE_ACCOUNT_NAME. Skipping storage container creation."
fi
