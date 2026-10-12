# Local Jenkins with Terraform tooling, for the lab.
FROM jenkins/jenkins:lts-jdk17

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip gnupg lsb-release python3 python3-pip git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Terraform (HashiCorp apt repo)
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/hashicorp.list \
 && apt-get update && apt-get install -y terraform && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (detects x86_64 vs arm64, e.g. Apple Silicon)
RUN ARCH=$(uname -m) && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscli.zip \
 && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip

# tflint
RUN curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# Conftest (OPA)
ARG CONFTEST_VERSION=0.56.0
RUN ARCH=$(uname -m) && [ "$ARCH" = "aarch64" ] && ARCH=arm64; \
    curl -fsSL "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin conftest

# Checkov
RUN pip3 install --no-cache-dir --break-system-packages --ignore-installed checkov

USER jenkins

# Plugins needed by the Jenkinsfile
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
