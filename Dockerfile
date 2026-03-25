FROM frappe/erpnext:version-16

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    libssl-dev \
    mariadb-client \
    pkg-config \
    redis-tools \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R frappe:frappe /home/frappe/.nvm

USER frappe
WORKDIR /home/frappe/frappe-bench

ARG FRAPPE_VERSION=
ARG ERP_VERSION=

ENV CARGO_HOME=/home/frappe/.cargo \
    RUSTUP_HOME=/home/frappe/.rustup \
    PATH=/home/frappe/.cargo/bin:$PATH

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y

# Replace core apps with pinned versions if requested
RUN if [ -n "$FRAPPE_VERSION" ]; then \
    rm -rf "apps/frappe"; \
    bench get-app --branch "$FRAPPE_VERSION" https://github.com/frappe/frappe; \
    fi \
    && if [ -n "$ERP_VERSION" ]; then \
    rm -rf "apps/erpnext"; \
    bench get-app --branch "$ERP_VERSION" https://github.com/frappe/erpnext; \
    fi

# Copy optional local custom apps into image
COPY --chown=frappe:frappe custom-apps/ /opt/frappe/custom-apps/
COPY --chown=frappe:frappe scripts/install-custom-apps.sh /opt/frappe/install-custom-apps.sh
RUN chmod +x /opt/frappe/install-custom-apps.sh

ARG CUSTOM_APPS=""
ENV CUSTOM_APPS=${CUSTOM_APPS}
RUN /opt/frappe/install-custom-apps.sh

COPY --chown=frappe:frappe scripts/init-site.sh /opt/frappe/init-site.sh
RUN chmod +x /opt/frappe/init-site.sh

EXPOSE 8000 9000

CMD ["/opt/frappe/init-site.sh"]
