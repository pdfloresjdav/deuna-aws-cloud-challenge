# syntax=docker/dockerfile:1
#
# Reproducible development & validation image for the Deuna! AWS challenge.
# Multi-arch: builds natively for linux/amd64 and linux/arm64 (Apple Silicon)
# using BuildKit's TARGETARCH - no emulation is forced.
#
# Contains: Terraform, TFLint, Checkov, AWS CLI v2, Git, Bash, Make, jq.
# No AWS credentials, tokens or secrets are embedded. No Docker-in-Docker.

FROM debian:12-slim

# Pinned, stable tool versions.
ARG TERRAFORM_VERSION=1.16.7
ARG TFLINT_VERSION=0.66.0
ARG CHECKOV_VERSION=3.4.6
ARG AWSCLI_VERSION=2.42.2

# Provided automatically by BuildKit (amd64 | arm64).
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    TF_PLUGIN_CACHE_DIR=/home/dev/.terraform.d/plugin-cache \
    PATH=/opt/checkov/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Base runtime dependencies and certificates.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      unzip \
      git \
      make \
      jq \
      bash \
      gnupg \
      less \
      python3 \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Terraform (architecture-aware download + checksum verification).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep "terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" -d /usr/local/bin; \
    rm -f terraform_*; \
    terraform version

# TFLint (architecture-aware download + checksum verification).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${ARCH}.zip"; \
    curl -fsSLO "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt"; \
    grep "tflint_linux_${ARCH}.zip" checksums.txt | sha256sum -c -; \
    unzip -q "tflint_linux_${ARCH}.zip" -d /usr/local/bin; \
    rm -f tflint_* checksums.txt; \
    tflint --version

# Checkov (installed in an isolated virtualenv to avoid PEP 668 conflicts).
RUN python3 -m venv /opt/checkov \
    && /opt/checkov/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/checkov/bin/pip install --no-cache-dir "checkov==${CHECKOV_VERSION}" \
    && /opt/checkov/bin/checkov --version

# AWS CLI v2 (architecture-aware, official pinned installer).
# No checksum file is published for the versioned zip; it is fetched over HTTPS
# from the official distribution endpoint.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) AWS_ARCH=x86_64 ;; \
      arm64) AWS_ARCH=aarch64 ;; \
      *) exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" -o awscliv2.zip; \
    unzip -q awscliv2.zip; \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli; \
    rm -rf awscliv2.zip aws; \
    aws --version

# Non-root user; owns the provider plugin cache directory.
RUN useradd --create-home --uid 1000 --shell /bin/bash dev \
    && mkdir -p "${TF_PLUGIN_CACHE_DIR}" \
    && chown -R dev:dev /home/dev

USER dev
WORKDIR /workspace

CMD ["bash"]
