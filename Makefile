.PHONY: test-offline deb

test-offline:
	bash tests/integration/offline_dry_run.sh

deb:
	./packaging/build_deb.sh
