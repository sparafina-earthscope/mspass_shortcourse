# Inherit from a common base image
FROM buildpack-deps:noble-scm

ENV CONDA_DIR /opt/conda

# Setup Timezone to where our users mostly are
ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Set up common 
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV NB_USER jovyan
ENV NB_UID 1000

RUN adduser --disabled-password --gecos "Default Jupyter user" ${NB_USER}

RUN apt-get -qq update --yes && \
    apt-get -qq install --yes \
            tar \
            vim \
            micro \
            mc \
            tini \
            build-essential \
            locales > /dev/null

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

# for nbconvert
# texlive-plain-generic is new name of texlive-generic-recommended
RUN apt-get update > /dev/null && \
    apt-get -qq install --yes \
            pandoc \
            texlive-xetex \
            texlive-fonts-recommended \
            texlive-plain-generic > /dev/null

RUN mkdir -p /srv && \
    git clone https://github.com/mspass-team/mspass.git /srv/mspass

USER ${NB_USER}
WORKDIR /home/${NB_USER}

ENV PATH ${CONDA_DIR}/bin:$PATH

USER root

## INSTALL MONGODB SERVER - Lifted from MSPASS Dockerfile
# grab "js-yaml" for parsing mongod's YAML config files (https://github.com/nodeca/js-yaml/releases)
ENV JSYAML_VERSION 3.13.1

RUN set -ex; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		wget \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpgconf --kill all; \
	\
	wget -O /js-yaml.js "https://github.com/nodeca/js-yaml/raw/${JSYAML_VERSION}/dist/js-yaml.js"; \
# TODO some sort of download verification here
	\
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false 

RUN mkdir /docker-entrypoint-initdb.d

# MongoDB 8.3 uses the MongoDB 8.0 release signing key
RUN set -ex; \
	apt-get update; \
	apt-get install -y --no-install-recommends gnupg ca-certificates; \
	mkdir -p /etc/apt/keyrings; \
	wget -O - https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /etc/apt/keyrings/mongodb.gpg; \
	rm -rf /var/lib/apt/lists/* 

# Allow build-time overrides (eg. to build image with MongoDB Enterprise version)
# Options for MONGO_PACKAGE: mongodb-org OR mongodb-enterprise
# Options for MONGO_REPO: repo.mongodb.org OR repo.mongodb.com
# Example: docker build --build-arg MONGO_PACKAGE=mongodb-enterprise --build-arg MONGO_REPO=repo.mongodb.com .
ARG MONGO_PACKAGE=mongodb-org
ARG MONGO_REPO=repo.mongodb.org
ENV MONGO_PACKAGE=${MONGO_PACKAGE} MONGO_REPO=${MONGO_REPO}

ENV MONGO_MAJOR 8.3
RUN echo "deb [ signed-by=/etc/apt/keyrings/mongodb.gpg ] http://$MONGO_REPO/apt/ubuntu noble/${MONGO_PACKAGE%-unstable}/$MONGO_MAJOR multiverse" | tee "/etc/apt/sources.list.d/${MONGO_PACKAGE%-unstable}.list"

# https://www.mongodb.com/docs/manual/release-notes/8.3/
ENV MONGO_VERSION 8.3.1

RUN set -x \
# installing "mongodb-enterprise" pulls in "tzdata" which prompts for input
	&& export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y \
		${MONGO_PACKAGE}=$MONGO_VERSION \
		${MONGO_PACKAGE}-server=$MONGO_VERSION \
		${MONGO_PACKAGE}-mongos=$MONGO_VERSION \
		${MONGO_PACKAGE}-tools=$MONGO_VERSION \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mongodb \
	&& mv /etc/mongod.conf /etc/mongod.conf.orig 
	# && docker-clean

VOLUME /data/db /data/configdb

# Install mambaforge as root into a fresh ${CONDA_DIR}. Letting the
# installer create the directory itself ensures the extracted binaries
# (conda.exe, etc.) get the correct executable permissions.
COPY install-mambaforge.bash /tmp/install-mambaforge.bash
RUN chmod +x /tmp/install-mambaforge.bash && \
    /tmp/install-mambaforge.bash

COPY environment.yml /tmp/environment.yml

RUN mamba env update -p ${CONDA_DIR} -f /tmp/environment.yml && \
    mamba clean --all --yes

# Transfer ownership of the whole environment to NB_USER and make it
# group-writable, so the user can `conda install` / `pip install`
# additional packages into the environment at runtime.
RUN chown -R ${NB_UID}:${NB_UID} ${CONDA_DIR} && \
    chmod -R g+w ${CONDA_DIR}

USER ${NB_USER}
WORKDIR /home/${NB_USER}

EXPOSE 8888

ENTRYPOINT ["tini", "--"]