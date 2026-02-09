# azure-aks-stretch-image-builder
Image builder for creating AKS Stretch images

## Components of the Stretch ecosystem (proposed)

1. The base image
    * This image starts with a standard published image (Ubuntu, RHEL, etc.) and modifies it to have two available equal-sized partitions.
    * We also add necessary components to join an AKS cluster: containerd, runc, etc.
    * Finally, this image includes the *part-runner*, which is used below.
    * This image can be directly copied onto a local disk via a netboot OS.
1. The image server
    * This hosts metadata about available images: within a given image SKU, a list of available image versions including the "current/latest" one available in the current region, and a reference to where it can be retrieved.
1. A part-image
    * This is effectively the above image without the partition structure.
1. The part-runner
    * The *part-runner* fetches part-images in the background, mounts them, and copies them onto the inactive partition (i.e. "the other one" from whichever one is currently booted). It then updates GRUB to set the other partition as the default boot partition and reports to Kubernetes that the current node is eligible for reboot/upgrade, so that the customer can choose to move work off the current node in order to permit upgrade to proceed.
    * If an upgrade is pending and no pods are running, then the part-runner reboots the current node.
