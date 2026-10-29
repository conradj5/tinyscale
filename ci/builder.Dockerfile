# Local builder image mirroring the CI build job environment.
ARG GO_IMAGE=golang:1.27.3-alpine3.24
FROM ${GO_IMAGE}
# Emulators for local smoke tests; CI installs only the one each job needs.
ARG QEMU="qemu-aarch64 qemu-x86_64 qemu-arm qemu-riscv64 qemu-i386 qemu-mips qemu-mipsel qemu-ppc64le"
COPY scripts/ci/install-deps.sh /usr/local/bin/tt-install-deps
RUN tt-install-deps build ${QEMU}
