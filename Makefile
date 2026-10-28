# GNU Emacs from its signed release tarball, built into a .deb for one Ubuntu release
# inside a container, so the host needs only make, curl, gpg and podman or docker.
#
#   make                  fetch and verify the tarball, build the .deb into out/
#   make test             install the .deb in a clean container and check it works
#   make install          install the .deb on this machine
#   make UBUNTU=24.04     for another Ubuntu release; VERSION=30.2 for another Emacs
#   make TOOLKIT=lucid    the Lucid flavor, emacs-upstream-lucid

VERSION ?= 31.1
REVISION ?= 1
UBUNTU ?= 26.04
TOOLKIT ?= gtk3
MAINTAINER ?= $(shell git config user.name) <$(shell git config user.email)>
ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

# The suffix keeps the .debs of two Ubuntu releases apart and makes the newer
# release's build the newer version. It is joined with a dot rather than the usual
# tilde because GitHub turns a tilde in a release file's name into a dot.
DEBVERSION = $(VERSION)-$(REVISION).ubuntu$(UBUNTU)
PACKAGE = $(if $(filter gtk3,$(TOOLKIT)),emacs-upstream,emacs-upstream-$(TOOLKIT))
export VERSION DEBVERSION TOOLKIT PACKAGE MAINTAINER

ARCH := $(shell dpkg --print-architecture)
IMAGE = emacs-upstream-build:$(UBUNTU)
TARBALL = out/emacs-$(VERSION).tar.xz
DEB = out/$(PACKAGE)_$(DEBVERSION)_$(ARCH).deb
LOG = out/build-$(PACKAGE)-$(DEBVERSION).log
GNU = https://ftp.gnu.org/gnu/emacs

# A recipe that fails part way must not leave a file that looks finished, such as the
# empty keyring a failed gpg leaves behind.
.DELETE_ON_ERROR:

all: $(DEB)

fetch: $(TARBALL)

# keys/ holds the Emacs project's release keyring as Savannah publishes it, and a
# tarball counts only when signed by one of its keys. gpgv reads the binary form only.
out/keyring.gpg: keys/emacs-release-keyring.asc
	mkdir -p out
	gpg --dearmor <$< >$@

$(TARBALL): | out/keyring.gpg
	curl -fL -o $@.sig $(GNU)/$(notdir $@).sig
	curl -fL -o $@.part $(GNU)/$(notdir $@)
	gpgv --keyring ./out/keyring.gpg $@.sig $@.part
	mv $@.part $@

# The image comes from the engine's cache unless the Containerfile changed. --init
# gives the container a PID 1 that passes Ctrl-C on; build.sh as PID 1 would ignore
# it and keep building after make has stopped.
$(DEB): $(TARBALL) build.sh Containerfile
	@case "$$MAINTAINER" in ?*' <'?*@?*'>') ;; \
	  *) echo 'MAINTAINER must look like "Name <email>"' >&2; exit 1 ;; esac
	$(ENGINE) build -f Containerfile --build-arg UBUNTU=$(UBUNTU) -t $(IMAGE) .
	$(ENGINE) run --rm --init -v $(CURDIR)/build.sh:/build.sh:ro -v $(CURDIR)/out:/out \
	  -e VERSION -e DEBVERSION -e TOOLKIT -e PACKAGE -e MAINTAINER $(IMAGE) /build.sh \
	  >$(LOG) 2>&1 || { tail -40 $(LOG); exit 1; }

test: $(DEB)
	$(ENGINE) run --rm --init -v $(CURDIR)/test.sh:/test.sh:ro -v $(CURDIR)/out:/out:ro \
	  -e TOOLKIT docker.io/library/ubuntu:$(UBUNTU) /test.sh /out/$(notdir $(DEB))

install: $(DEB)
	sudo apt install ./$(DEB)

# A release tag is v followed by this, so the tagged commit says what it built.
print-version:
	@echo $(VERSION)-$(REVISION)

clean:
	rm -rf out

.PHONY: all fetch test install print-version clean
