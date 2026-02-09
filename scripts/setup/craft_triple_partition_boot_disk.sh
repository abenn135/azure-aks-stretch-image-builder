#!/bin/bash

set -euo pipefail

az account set --subscription 8ecadfc9-d1a3-4ea4-b844-0d9f87e4d7c8  # standalone

GROUP=alexbenn-test-3
LOCATION=eastus2
if ! az group show -n $GROUP &>/dev/null; then
  echo "Creating resource group $GROUP in $LOCATION..."
  az group create -l $LOCATION -n $GROUP
fi

VM_NAME=disk-thrower
VM_SKU=Standard_D4s_v7
if ! az vm show -g $GROUP -n $VM_NAME &>/dev/null; then
    echo "Creating VM $VM_NAME in resource group $GROUP..."
    az vm create -g $GROUP -l $LOCATION -n $VM_NAME \
        --size $VM_SKU \
        --image Ubuntu2404 \
else
    echo "VM $VM_NAME already exists in resource group $GROUP. Skipping VM creation."
fi

DISK_NAME=throwndisk1
# Typical Canonical disks are 30GB. We want to create 3 partitions with enough space to hold the entire OS on each, so we need at least 90GB. 128GB is the next available size step in Azure.
DISK_SIZE_GB=128
if ! az disk show -g $GROUP -n $DISK_NAME &>/dev/null; then
    echo "Creating disk $DISK_NAME in resource group $GROUP..."
    az disk create --resource-group $GROUP \
        --name $DISK_NAME \
        --sku Premium_LRS \
        --location $LOCATION \
        --size-gb $DISK_SIZE_GB \
        --image-reference Canonical:ubuntu-24_04-lts:server:latest
    az vm disk attach -g $GROUP --vm-name $VM_NAME --name $DISK_NAME
else
    echo "Disk $DISK_NAME already exists in resource group $GROUP. Skipping disk creation."
fi

VM_IP=$(az vm show -g $GROUP -n $VM_NAME -d --query 'publicIps' -o tsv)
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

az vm stop -g $GROUP -n $VM_NAME

SIG_NAME=alexbenntestsig2
az sig create --gallery-name $SIG_NAME -g $GROUP
DEFINITION_NAME=alexbenntestdef
az sig image-definition create \
    --gallery-image-definition $DEFINITION_NAME \
    --gallery-name $SIG_NAME \
    --features 'SecurityType=TrustedLaunch IsAcceleratedNetworkSupported=true DiskControllerTypes=SCSI,NVMe' \
    --offer partitionedos \
    --os-type Linux \
    --publisher azure-aks \
    --resource-group $GROUP \
    --sku Ubuntu2404PartitionedTLNVMe

DISK_ID=$(az disk show -g $GROUP -n $DISK_NAME --query 'id' -o tsv)
VERSION_NUMBER=1.0.0
az sig image-version create \
    --gallery-image-definition $DEFINITION_NAME \
    --gallery-image-version $VERSION_NUMBER \
    --gallery-name $SIG_NAME \
    --resource-group $GROUP \
    --os-snapshot $DISK_ID
IMAGE_VERSION_ID=$(az sig image-version show --gallery-image-definition $DEFINITION_NAME --gallery-image-version $VERSION_NUMBER --gallery-name $SIG_NAME --resource-group $GROUP --query 'id' -o tsv)
echo "image_version_id=$IMAGE_VERSION_ID"

# cleanup

echo "Cleaning up resources..."
az vm delete -g $GROUP -n $VM_NAME --yes
echo "vm deleted. Deleting disk..."
az disk delete -g $GROUP -n $DISK_NAME --yes
echo "disk deleted. Done"
