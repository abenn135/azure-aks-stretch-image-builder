packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}
source "azure-arm" "base-image" {
  os_type = "Linux"
  image_publisher = "Canonical"
  image_offer = "ubuntu-24_04-lts"
  image_sku = "server"
  managed_image_name = "aksstretchimagesig"
  managed_image_resource_group_name = "alexbenn-aks-stretch-test"

  location = "eastus2"
  vm_size = "Standard_A2_v2_Gen2"

  temp_resource_group_name = "alexbenn-aks-stretch-tmp-packer"
  use_azure_cli_auth = true
}
build {
  sources = ["sources.azure-arm.base-image"]
  
  provisioner "ansible" {
    playbook_file = "./ansible/init.yml"
  }
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
            "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"
    ]
    inline_shebang = "/bin/sh -x"
  }
}
