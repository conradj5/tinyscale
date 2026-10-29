# Convenience targets; all real logic lives in scripts/.
.PHONY: test validate-config integration build clean

test:
	tests/run.sh

validate-config:
	python3 -s tools/platforms.py validate

# Optional end-to-end CI simulation (needs Docker + network).
integration:
	tests/integration.sh $(TARGETS)

# Local Docker build; e.g. make build TARGETS=linux_arm64 VERSION=1.104.4
build:
	scripts/local-build.sh $(if $(VERSION),--version $(VERSION)) $(if $(TARGETS),--targets $(TARGETS))

clean:
	rm -rf dist work
