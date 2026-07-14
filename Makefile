.PHONY: help build shell build-rootfs

BOARD ?= duos

help:
	@echo "Alpine Linux for Milk-V Duo"
	@echo ""
	@echo "  make build              - Build Docker image"
	@echo "  make build-rootfs       - Build Alpine rootfs and image"  
	@echo "  make shell              - Interactive shell in builder"
	@echo ""
	@echo "  BOARD=duo256m make build-rootfsmake build-rootfs   - Build for Duo 256M"

build:
	docker compose build builder

shell: build
	docker compose run --rm shell

build-rootfs: build
	docker compose run --rm builder ./build.sh $(BOARD)
