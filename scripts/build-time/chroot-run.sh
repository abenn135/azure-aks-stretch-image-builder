#!/bin/bash

# This script will be run in the chroot. Install any packages and/or make any configuration changes needed to the base image here.

set -euo pipefail

apt-get update
# TODO: Do actual work. This is just a proof of concept for now.
apt-get install -y containerd
echo "hello world from inside the chroot. Containerd installed."
