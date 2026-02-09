SOURCE_SUB=c4c3550e-a965-4993-a50c-628fd38cd3e1
SOURCE_RG=aksvhdtestbuildrg
SOURCE_GALLERY_NAME=PackerSigGalleryEastUS
SOURCE_IMAGE_DEF=2404gen2arm64gb200containerd
SOURCE_IMAGE_VERSION=1.1.319


IMAGE_VERSION_ID=$(az sig image-version show \
  --subscription "$SOURCE_SUB" \
  --resource-group "$SOURCE_RG" \
  --gallery-name "$SOURCE_GALLERY_NAME" \
  --gallery-image-definition "$SOURCE_IMAGE_DEF" \
  --gallery-image-version "$SOURCE_IMAGE_VERSION" \
  --query "id" --output tsv)

COPY_SUB=8ecadfc9-d1a3-4ea4-b844-0d9f87e4d7c8
COPY_RG=alexbenn-test
# DISK_NAME="disk-from-sig-$(date +%s)"
LOCATION="eastus"

# az disk create \
#   --subscription "$COPY_SUB" \
#   --resource-group "$COPY_RG" \
#   --name "$DISK_NAME" \
#   --location "$LOCATION" \
#   --gallery-image-reference "$IMAGE_VERSION_ID" \
#   --hyper-v-generation V2

# echo "disk_name=$DISK_NAME"
# echo "location=$LOCATION"

DEST_GALLERY_NAME=alexbenntestsig
DEST_IMAGE_DEF=sourceimagedef
DEST_IMAGE_VERSION=1.0.0

az sig image-version create \
  --subscription "$COPY_SUB" \
  --resource-group "$COPY_RG" \
  --gallery-name "$DEST_GALLERY_NAME" \
  --gallery-image-definition "$DEST_IMAGE_DEF" \
  --gallery-image-version "$DEST_IMAGE_VERSION" \
  --location "$LOCATION" \
  --managed-image $IMAGE_VERSION_ID









# Generate SAS URL for download
echo "Generating SAS URL for disk download..."
az disk grant-access \
  --subscription "$COPY_SUB" \
  --resource-group "$COPY_RG" \
  --name "$DISK_NAME" \
  --duration-in-seconds 3600 \
  --access-level Read \
  --query "accessSas" --output tsv > ~/testing/sig_disk_copy/sas_url.txt

CONTAINER_NAME="sigdiskcontainer"

az storage container create \
    --account-name "alexbennstorageaccount" \
    --name "$CONTAINER_NAME" \
    --public-access off


TODO:
==> azure-arm.base-image: fatal: [default]: FAILED! => {"changed": false, "err": "Error: Partition(s) on /dev/sda are being used.\n", "msg": "Error while running parted script: /usr/sbin/parted -s -f -m -a optimal /dev/sda -- unit KiB mklabel msdos mkpart primary 0% 15360MiB resizepart 1 15360MiB", "out": "", "rc": 1}