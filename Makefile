.PHONY: build

build:
	@echo "Running init and Packer image build..."
	./scripts/setup/init_sig.sh
	packer build packer/azure-ubuntu.pkr.hcl
