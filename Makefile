NAME := $(shell grep 'name =' Cargo.toml | head -n 1 | cut -d'"' -f2)
DBUS_NAME := org.shadowblip.Gamescope
ALL_RS := $(shell find src -name '*.rs')
PREFIX ?= /usr
CACHE_DIR := .cache

# Docker image variables
IMAGE_NAME ?= rust
IMAGE_TAG ?= 1.75

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: install
install: build ## Install gamescope-dbus to the given prefix (default: PREFIX=/usr)
	install -D -m 755 target/release/$(NAME) \
		$(PREFIX)/bin/$(NAME)
	install -D -m 644 rootfs/usr/share/dbus-1/session.d/$(DBUS_NAME).conf \
		$(PREFIX)/share/dbus-1/session.d/$(DBUS_NAME).conf
	install -D -m 644 rootfs/usr/share/dbus-1/services/$(DBUS_NAME).service \
		$(PREFIX)/share/dbus-1/services/$(DBUS_NAME).service
	install -D -m 644 rootfs/usr/lib/systemd/user/$(NAME).service \
		$(PREFIX)/lib/systemd/user/$(NAME).service
	@echo ""
	@echo "Install completed. Enable service with:" 
	@echo "  systemctl --user enable --now gamescope-dbus"

.PHONY: uninstall
uninstall: ## Uninstall gamescope-dbus 
	rm $(PREFIX)/bin/$(NAME)
	rm $(PREFIX)/share/dbus-1/session.d/$(DBUS_NAME).conf
	rm $(PREFIX)/share/dbus-1/services/$(DBUS_NAME).service
	rm $(PREFIX)/lib/systemd/user/$(NAME).service
	@echo ""
	@echo "Uninstall completed. Remove service with:" 
	@echo "  systemctl --user disable --now gamescope-dbus"

##@ Development

.PHONY: debug
debug: target/debug/$(NAME)  ## Build debug build
target/debug/$(NAME): $(ALL_RS) Cargo.lock
	cargo build

.PHONY: build
build: target/release/$(NAME) ## Build release build
target/release/$(NAME): $(ALL_RS) Cargo.lock
	cargo build --release

.PHONY: all
all: build debug ## Build release and debug builds

.PHONY: run
run: debug ## Build and run
	./target/debug/$(NAME)

.PHONY: gamescope
gamescope: ## Run a test gamescope instance
	/usr/bin/gamescope -w 1280 -h 720 --xwayland-count 2 -- glxgears

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf dist target $(CACHE_DIR)

.PHONY: format
format: ## Run rustfmt on all source files
	rustfmt --edition 2021 $(ALL_RS)

.PHONY: test
test: ## Run all tests
	cargo test -- --show-output

.PHONY: setup
setup: /usr/share/dbus-1/session.d/$(DBUS_NAME).conf ## Install dbus policies
/usr/share/dbus-1/session.d/$(DBUS_NAME).conf:
	sudo ln $(PWD)/rootfs/usr/share/dbus-1/session.d/$(DBUS_NAME).conf \
		/usr/share/dbus-1/session.d/$(DBUS_NAME).conf
	systemctl --user reload dbus

##@ Distribution

.PHONY: dist
dist: dist/gamescope-dbus.tar.gz ## Build a redistributable archive of the project
dist/gamescope-dbus.tar.gz: build
	rm -rf $(CACHE_DIR)/gamescope-dbus
	mkdir -p $(CACHE_DIR)/gamescope-dbus
	$(MAKE) install PREFIX=$(CACHE_DIR)/gamescope-dbus/usr NO_RELOAD=true
	mkdir -p dist
	tar cvfz $@ -C $(CACHE_DIR) gamescope-dbus
	cd dist && sha256sum gamescope-dbus.tar.gz > gamescope-dbus.tar.gz.sha256.txt

.PHONY: introspect
introspect: ## Generate DBus XML
	echo "Generating DBus XML spec..."
	mkdir -p bindings/dbus-xml
	busctl --user introspect org.shadowblip.Gamescope \
		/org/shadowblip/Gamescope/Manager --xml-interface > bindings/dbus-xml/org-shadowblip-gamescope-manager.xml
	xmlstarlet ed -L -d '//node[@name]' bindings/dbus-xml/org-shadowblip-gamescope-manager.xml
	busctl --user introspect org.shadowblip.Gamescope \
		/org/shadowblip/Gamescope/XWayland0 --xml-interface > bindings/dbus-xml/org-shadowblip-gamescope-xwayland.xml
	xmlstarlet ed -L -d '//node[@name]' bindings/dbus-xml/org-shadowblip-gamescope-xwayland.xml

XSL_TEMPLATE := ./docs/dbus2markdown.xsl
.PHONY: docs
docs: ## Generate markdown docs for DBus interfaces
	mkdir -p docs
	xsltproc --novalid -o docs/manager.md $(XSL_TEMPLATE) bindings/dbus-xml/org-shadowblip-gamescope-manager.xml
	sed -i 's/DBus Interface API/Manager DBus Interface API/g' ./docs/manager.md
	xsltproc --novalid -o docs/xwayland.md $(XSL_TEMPLATE) bindings/dbus-xml/org-shadowblip-gamescope-xwayland.xml
	sed -i 's/DBus Interface API/XWayland DBus Interface API/g' ./docs/xwayland.md

# Refer to .releaserc.yaml for release configuration
.PHONY: sem-release 
sem-release: ## Publish a release with semantic release 
	npx semantic-release

# E.g. make in-docker TARGET=build
.PHONY: in-docker
in-docker:
	@# Run the given make target inside Docker
	docker run --rm \
		-v $(PWD):/src \
		--workdir /src \
		-e HOME=/home/build \
		--user $(shell id -u):$(shell id -g) \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		make $(TARGET)
