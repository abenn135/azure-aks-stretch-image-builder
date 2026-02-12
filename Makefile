.PHONY: buildimage

buildimage:
	@echo "creating triple partition image..."
	./scripts/setup/craft_triple_partition_boot_disk.sh
