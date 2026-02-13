#!/bin/bash

set -euo pipefail

# Must specify AZURE_SUBSCRIPTION_ID out of band
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  echo "Error: AZURE_SUBSCRIPTION_ID is not set. Please set it before running this script."
  exit 1
fi
AZURE_IDENTITY_NAME=${AZURE_IDENTITY_NAME:-aks-stretch-image-builder-identity}
RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME:-alexbenn-test}

az identity create --name $AZURE_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP_NAME
SP_ID=$(az identity show --name $AZURE_IDENTITY_NAME --resource-group $RESOURCE_GROUP_NAME --query 'clientId' -o tsv)
az role assignment create --assignee $SP_ID --role "Contributor" --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME"
FIC_ID="github-azure-aks-stretch-image-builder-fic"
# This grants access to operations run on the main branch, which seems reasonable.
az identity federated-credential create --name $FIC_ID --identity-name $AZURE_IDENTITY_NAME --resource-group $RESOURCE_GROUP_NAME --issuer 'https://token.actions.githubusercontent.com' --subject 'repo:abenn135/azure-aks-stretch-image-builder:ref:refs/heads/main' --audiences 'api://AzureADTokenExchange'
