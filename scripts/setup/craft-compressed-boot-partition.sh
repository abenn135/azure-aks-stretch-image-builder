#!/bin/bash

set -euo pipefail

# Must specify AZURE_SUBSCRIPTION_ID out of band
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  echo "Error: AZURE_SUBSCRIPTION_ID is not set. Please set it before running this script."
  exit 1
fi
GROUP=${GROUP:-alexbenn-test}
LOCATION=${LOCATION:-eastus2}
BUILDER_VM_NAME=${BUILDER_VM_NAME:-disk-thrower}
BUILDER_VM_ARCH=${BUILDER_VM_ARCH:-x86_64}
BUILDER_VM_SKU=${BUILDER_VM_SKU:-Standard_D4s_v7}
BASE_IMAGE_REFERENCE=${BASE_IMAGE_REFERENCE:-Canonical:ubuntu-24_04-lts:server:latest}
DISK_NAME=${DISK_NAME:-throwndisk2}
DISK_SIZE_GB=${DISK_SIZE_GB:-30}
STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME:-alexbennteststorage}
STORAGE_CONTAINER_NAME=${STORAGE_CONTAINER_NAME:-alexbenntestcontainer}
DELETE_DISK=${DELETE_DISK:-true}

az account set --subscription $AZURE_SUBSCRIPTION_ID

if ! az group show -n $GROUP &>/dev/null; then
  echo "Creating resource group $GROUP in $LOCATION..."
  az group create -l $LOCATION -n $GROUP
fi

if ! az vm show -g $GROUP -n $BUILDER_VM_NAME &>/dev/null; then
    echo "Creating VM $BUILDER_VM_NAME in resource group $GROUP..."
    if [ -z $BUILDER_VM_SKU ]; then
        if [ "$BUILDER_VM_ARCH" = "x86_64" ]; then
            BUILDER_VM_SKU=Standard_D4s_v7
        elif [ "$BUILDER_VM_ARCH" = "arm64" ]; then
            BUILDER_VM_SKU=Standard_D4ps_v6
        else
            echo "Error: Unsupported architecture $BUILDER_VM_ARCH. Supported values are x86_64 and arm64."
            exit 1
        fi
    fi

    az vm create -g $GROUP -l $LOCATION -n $BUILDER_VM_NAME \
        --size $BUILDER_VM_SKU \
        --image Ubuntu2404 \
        --assign-identity \
        --role contributor \
        --scope /Subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$GROUP
else
    echo "VM $BUILDER_VM_NAME already exists in resource group $GROUP. Skipping VM creation."
fi

if ! az disk show -g $GROUP -n $DISK_NAME &>/dev/null; then
    echo "Creating disk $DISK_NAME in resource group $GROUP..."
    az disk create --resource-group $GROUP \
        --name $DISK_NAME \
        --sku Premium_LRS \
        --location $LOCATION \
        --size-gb $DISK_SIZE_GB \
        --image-reference $BASE_IMAGE_REFERENCE
    az vm disk attach -g $GROUP --vm-name $BUILDER_VM_NAME --name $DISK_NAME
else
    echo "Disk $DISK_NAME already exists in resource group $GROUP. Skipping disk creation."
fi

. scripts/setup/init-storage-account.sh

CHOSEN_BUILD_VERSION=$(date '+%s')

jq -n \
    --arg storageAccountName "$STORAGE_ACCOUNT_NAME" \
    --arg storageContainerName "$STORAGE_CONTAINER_NAME" \
    --arg buildVersion "$CHOSEN_BUILD_VERSION" \
    --arg arch "$BUILDER_VM_ARCH" \
    -f scripts/setup/config.json.tmpl \
    > config.json

VM_IP=$(az vm show -g $GROUP -n $BUILDER_VM_NAME -d --query 'publicIps' -o tsv)
echo "VM IP: $VM_IP"
echo "Waiting for VM to be ready for SSH..."
while ! nc -z "$VM_IP" 22; do
  sleep 5
done
echo "VM is ready for SSH."
ssh -o StrictHostKeyChecking=no $VM_IP exit

scp scripts/build-time/build-compress-image.sh $VM_IP:~/
scp scripts/build-time/chroot-run.sh $VM_IP:~/
scp config.json $VM_IP:~/

# Run the build-compress-partition-image script on the VM via SSH as root
echo "Running build-compress-image.sh on VM..."
if ! ssh $VM_IP "sudo bash ~/build-compress-image.sh"; then
    echo "ERROR: build-compress-image.sh failed on VM"
    exit 1
fi

# az vm deallocate -g $GROUP -n $BUILDER_VM_NAME

# cleanup
echo "Cleaning up resources..."
az vm delete -g $GROUP -n $BUILDER_VM_NAME --yes
echo "vm deleted."
