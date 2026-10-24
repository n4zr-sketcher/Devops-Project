###############################################################################
# Dockerfile  -  custom Jenkins controller image
#
# The official `jenkins/jenkins:lts-jdk17` image already contains everything
# Jenkins needs. This image adds the command line tools that our pipeline
# uses to talk to the Azure VM:
#
#   openssh-client  -> scp / ssh  (copy files + run deploy.sh on the VM)
#   curl            -> HTTP verification of the deployed website
#   nodejs          -> `node --check` performs a real JavaScript syntax check
#   rsync / unzip   -> file transfer helpers
#
# Build it with:   docker compose build      (from the jenkins/ folder)
###############################################################################
FROM jenkins/jenkins:lts-jdk17

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-client \
        curl \
        ca-certificates \
        rsync \
        unzip \
        nodejs \
    && rm -rf /var/lib/apt/lists/*

USER jenkins

# Pre-install all required plugins so Jenkins starts with zero plugin prompts
RUN jenkins-plugin-cli --plugins "workflow-aggregator git credentials-binding ansicolor timestamper"

# Copy initialization scripts for automated zero-touch setup
COPY --chown=jenkins:jenkins init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/

# Sanity check at build time - if this fails the image is broken.
RUN git --version && ssh -V 2>&1 && node --version && curl --version | head -n 1
