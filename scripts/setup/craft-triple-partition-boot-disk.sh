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
BUILDER_VM_SKU=${BUILDER_VM_SKU:-Standard_D4s_v7}
BASE_IMAGE_REFERENCE=${BASE_IMAGE_REFERENCE:-Canonical:ubuntu-24_04-lts:server:latest}
DISK_NAME=${DISK_NAME:-throwndisk2}
DISK_SIZE_GB=${DISK_SIZE_GB:-30}
CREATE_SIG_VERSION=${CREATE_SIG_VERSION:-true}
SIG_NAME=${SIG_NAME:-alexbenntestsig2}
SIG_DEFINITION_NAME=${SIG_DEFINITION_NAME:-alexbenntestdef}
IMAGE_VERSION_NUMBER=${IMAGE_VERSION_NUMBER:-1.0.0}
DELETE_DISK=${DELETE_DISK:-true}

az account set --subscription $AZURE_SUBSCRIPTION_ID

if ! az group show -n $GROUP &>/dev/null; then
  echo "Creating resource group $GROUP in $LOCATION..."
  az group create -l $LOCATION -n $GROUP
fi

if ! az vm show -g $GROUP -n $BUILDER_VM_NAME &>/dev/null; then
    echo "Creating VM $BUILDER_VM_NAME in resource group $GROUP..."
    az vm create -g $GROUP -l $LOCATION -n $BUILDER_VM_NAME \
        --size $BUILDER_VM_SKU \
        --image Ubuntu2404 \
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

VM_IP=$(az vm show -g $GROUP -n $BUILDER_VM_NAME -d --query 'publicIps' -o tsv)
echo "VM IP: $VM_IP"
echo "Waiting for VM to be ready for SSH..."
while ! nc -z "$VM_IP" 22; do
  sleep 5
done
echo "VM is ready for SSH."
ssh -o StrictHostKeyChecking=no $VM_IP exit

scp scripts/build-time/partition-disk.sh $VM_IP:~/

# Run the partition script on the VM via SSH as root
echo "Running partition-disk.sh on VM..."
if ! ssh $VM_IP "sudo bash ~/partition-disk.sh"; then
    echo "ERROR: partition-disk.sh failed on VM"
    exit 1
fi

az vm deallocate -g $GROUP -n $BUILDER_VM_NAME

if [ "$CREATE_SIG_VERSION" = "true" ]; then
    echo "Creating SIG image version..."
    if az sig show -g $GROUP -n $SIG_NAME &>/dev/null; then
        echo "Shared Image Gallery $SIG_NAME already exists in resource group $GROUP. Skipping SIG creation."
    else
        echo "Creating Shared Image Gallery $SIG_NAME in resource group $GROUP..."
        az sig create --gallery-name $SIG_NAME -g $GROUP
    fi

    if az sig image-definition show -g $GROUP --gallery-name $SIG_NAME -n $SIG_DEFINITION_NAME &>/dev/null; then
        echo "Image definition $SIG_DEFINITION_NAME already exists in SIG $SIG_NAME. Skipping image definition creation."
    else
        echo "Creating image definition $SIG_DEFINITION_NAME in SIG $SIG_NAME..."
        az sig image-definition create \
            --gallery-image-definition $SIG_DEFINITION_NAME \
            --gallery-name $SIG_NAME \
            --features 'SecurityType=TrustedLaunch IsAcceleratedNetworkSupported=true DiskControllerTypes=SCSI,NVMe' \
            --offer partitionedos \
            --os-type Linux \
            --publisher azure-aks \
            --resource-group $GROUP \
            --sku Ubuntu2404PartitionedTLNVMe
    fi

    DISK_ID=$(az disk show -g $GROUP -n $DISK_NAME --query 'id' -o tsv)
    az sig image-version create \
        --gallery-image-definition $SIG_DEFINITION_NAME \
        --gallery-image-version $IMAGE_VERSION_NUMBER \
        --gallery-name $SIG_NAME \
        --resource-group $GROUP \
        --os-snapshot $DISK_ID
    IMAGE_VERSION_ID=$(az sig image-version show --gallery-image-definition $SIG_DEFINITION_NAME --gallery-image-version $IMAGE_VERSION_NUMBER --gallery-name $SIG_NAME --resource-group $GROUP --query 'id' -o tsv)
    echo "image_version_id=$IMAGE_VERSION_ID"
else
    echo "Skipping SIG image version creation as CREATE_SIG_VERSION is set to false."
fi

# cleanup

echo "Cleaning up resources..."
az vm delete -g $GROUP -n $BUILDER_VM_NAME --yes
echo "vm deleted."
if [ "$DELETE_DISK" = "true" ]; then
    echo "Deleting disk $DISK_NAME in resource group $GROUP..."
    az disk delete -g $GROUP -n $DISK_NAME --yes
    echo "disk deleted. Done"
else
    echo "Skipping disk deletion as DELETE_DISK is set to false."
fi