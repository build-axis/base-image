# Dockerfile — base-image: Debian + Node 24 + Python 3.12 + PHP 8.4 + tmux.
# Build with a single command:
#
#   docker build -t base-image:latest .
#
# (based on demo.limit.com.ua/Dockerfile with OpenCode removed)

FROM python:3.12-slim-bookworm

# Base utilities + sandbox dependencies:
#   openssh-client — ssh for git over SSH
#   bubblewrap (bwrap) — OS-level filesystem isolation (sandbox)
#   socat        — loopback proxy forwarding for network filtering
#   git          — working with git repositories
#   tmux         — persistent terminal sessions
#   locales      — UTF-8 locale support
#   sudo         — allows installing packages (apt, npm -g) when needed
#   procps       — ps/top/kill for process diagnostics
#   vim          — editor with syntax highlighting (vimrc.local: syntax on)
# Python 3.12 is already in the base image (python:3.12-slim).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        openssh-client \
        bubblewrap \
        socat \
        xz-utils \
        tmux \
        locales \
        sudo \
        sqlite3 \
        procps \
        vim \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && printf 'syntax on\nfiletype plugin indent on\nset background=dark\n' \
        > /etc/vim/vimrc.local

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LANGUAGE=en_US:en

# --- Non-root user ---
ARG USER_ID=1000
ARG USER_GROUP=1000
RUN groupadd -g ${USER_GROUP} node 2>/dev/null || true \
    && useradd -u ${USER_ID} -g ${USER_GROUP} -m -s /bin/bash node 2>/dev/null || true \
    && echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node

# --- Node.js 24 LTS (NodeSource) ---
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- PHP 8.4 (deb.sury.org) ---
# Runtime for PHP projects in the workspace: pdo_mysql, pdo_sqlite, opcache, redis.
# pcntl is already built into php8.4-cli on Debian.
RUN curl -fsSL https://packages.sury.org/php/apt.gpg \
        -o /usr/share/keyrings/deb.sury.org-php.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        php8.4-cli \
        php8.4-mysql \
        php8.4-sqlite3 \
        php8.4-opcache \
        php8.4-redis \
        php8.4-mbstring \
        php8.4-xml \
        php8.4-curl \
        php8.4-zip \
        php8.4-intl \
        php8.4-bcmath \
        php8.4-gd \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# --- Composer ---
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# opcache config — DISABLED by default (dev: PHP file changes are
# picked up immediately). Enable via env in compose: PHP_OPCACHE_ENABLE_CLI=1.
RUN { \
    echo 'opcache.enable=0'; \
    echo 'opcache.enable_cli=${PHP_OPCACHE_ENABLE_CLI:-0}'; \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=20000'; \
    echo 'opcache.revalidate_freq=${PHP_OPCACHE_REVALIDATE_FREQ:-0}'; \
    echo 'opcache.validate_timestamps=${PHP_OPCACHE_VALIDATE_TIMESTAMPS:-1}'; \
    echo 'opcache.fast_shutdown=1'; \
    } > /etc/php/8.4/cli/conf.d/99-opcache-optimized.ini

# --- Working directories ---
RUN mkdir -p /workspace \
    && chown -R ${USER_ID}:${USER_GROUP} /workspace

USER node
WORKDIR /workspace

CMD ["bash"]
