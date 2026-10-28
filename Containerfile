# The build environment: one Ubuntu release with the build dependencies of its own
# emacs package, so the .deb links against exactly that release's libraries.
ARG UBUNTU
FROM docker.io/library/ubuntu:${UBUNTU}

# build-dep needs the source indexes, which the image leaves disabled. postfix comes
# in through mailutils and would otherwise ask how to set up mail.
RUN set -ex; \
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; \
    apt-get update; \
    echo 'postfix postfix/main_mailer_type select No configuration' | debconf-set-selections; \
    DEBIAN_FRONTEND=noninteractive apt-get build-dep -y --no-install-recommends emacs
