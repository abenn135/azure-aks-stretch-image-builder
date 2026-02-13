# azure-aks-stretch-image-builder

Image builder for creating AKS Stretch images

## Components of the Stretch image ecosystem (draft 2)

1. User managed role -- this grants the GitHub runner write access to a resource group, in order to create VMs and disks there during disk generation. See hack/create-oidc-connection.sh for initial setup of this role.
1. Base image -- this may be a standard off-the-shelf image such as `Canonical:ubuntu-24_04-lts:server:latest`, or a custom SIG image.
1. Image builder -- this repo contains a setup script and a build-time script.
    * The setup script is invoked by the GitHub runner and creates and manipulates the builder VM and resulting disk.
    * The build-time script runs on the VM and manipulates the disk during build time.
    * See `scripts/setup/` and `scripts/build-time/` for those.
1. Imager process -- this consists of a service for serving built images and a daemon that runs on the host machine to fetch new images, install them on a local partition, and update boot configuration. Initially, netboot performs the first imaging of the boot disk, but subsequent updates can be performed dynamically over time. This infrastructure is housed in <https://www.github.com/abenn135/azure-aks-stretch-imager/>.

TODO:

* Finish the script to reliably set up OIDC for GitHub.
* Test the base image build process to build an ARM64 image suitable for Spark nodes in the test lab.
  * Sidebar: make it easy to choose build channels that select between building an ARM64 and AMD64 image.
* Finish the imager (only draft right now) and install it on the built image.
