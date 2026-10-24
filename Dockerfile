# Dockerfile — base-image: serh/php:8.4.27-deb + Node 24 + Python 3.12 + tmux.
# Build with a single command:
#
#   docker build -t base-image:latest .
#
# (based on demo.limit.com.ua/Dockerfile with OpenCode removed)

FROM python:3.12-slim-bookworm AS py-src

# Base = the prod site image: PHP 8.4.27 + extensions (gd, imagick, intl,
# pdo_mysql, redis, zip, opcache, pcntl, bcmath, pcov) + imagemagick/inkscape/ghostscript with the
# prod PDF/CDR policy+delegate patches already applied — the sandbox runs the
# same image toolchain as prod, so tests exercise identical code paths.
# Python 3.12 lives in /usr/local in the slim image and collides with nothing.
FROM serh/php:8.4.27-deb

USER root

COPY --from=py-src /usr/local /usr/local

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
#   build-essential — gcc/g++/make for npm packages with native builds
#                     (node-gyp); without it `npm ci` fails on any dep
#                     that has no prebuilt binary; also needed to build
#                     the remaining PHP extensions below
#   default-mysql-client — mysql CLI for debugging site DBs from inside
#   jq, zip      — CI/script helpers
# curl, git, vim, unzip, openssh-client already come with the php base image;
# python 3.12 is copied in from py-src above.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
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
        build-essential \
        default-mysql-client \
        jq \
        zip \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && printf 'syntax on\nfiletype plugin indent on\nset background=dark\n' \
        > /etc/vim/vimrc.local

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LANGUAGE=en_US:en

# --- Non-root user ---
# The php base image already provides user "php" with uid/gid 1000 — rename
# it to "node" so bind-mounted files keep the same uid mapping.
ARG USER_ID=1000
ARG USER_GROUP=1000
RUN usermod -l node -d /home/node -m php \
    && groupmod -n node php \
    && echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node
ENV USER=node

# --- Node.js 24 LTS (NodeSource) ---
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- JS test tooling (frontend tests) ---
# Test stack for the Vue 2.7 projects in the workspace:
#   vitest + @vitest/coverage-v8 — runner + `vitest --coverage`
#   jest                         — the legacy `npm test` script target
#   jsdom                        — DOM environment for component tests
#   @vue/test-utils@1 + vue-template-compiler@2 — mounting Vue 2.7 SFCs
#   (major pins keep the Vue 2 line; Vue 3 uses @vue/test-utils@2)
# Installed globally so the CLI runners exist out of the box; a project
# still needs the matching packages in its devDependencies for test
# file imports to resolve from local node_modules.
RUN npm install -g \
        vitest \
        @vitest/coverage-v8 \
        jest \
        jsdom \
        @vue/test-utils@1 \
        vue-template-compiler@2 \
        playwright

# Playwright browsers — shared path instead of $HOME so the `node` user
# (and any CI job) can run them; --with-deps pulls the OS libraries
# (nss, libgbm, fonts). Chromium only — enough for the migration
# regression suite; add firefox/webkit later if cross-browser needed.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
    && playwright install --with-deps chromium \
    && chmod -R 777 "$PLAYWRIGHT_BROWSERS_PATH" \
    && rm -rf /var/lib/apt/lists/*

# --- PHP 8.4.27 (comes with the base image) ---
# Extensions ride in from serh/php:8.4.27-deb: gd, imagick, intl, pdo_mysql,
# redis, zip, opcache + the dev/test additions pcntl, bcmath, pcov.
# The prod opcache settings in the base image's docker-php-ext-opcache.ini
# load after our 99-* file and would win, so it is trimmed to only load the
# zend_extension.
RUN echo 'zend_extension=opcache' \
    > /usr/local/etc/php/conf.d/docker-php-ext-opcache.ini

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
    } > /usr/local/etc/php/conf.d/99-opcache-optimized.ini

RUN echo 'pcov.enabled=1' > /usr/local/etc/php/conf.d/98-pcov.ini

# PyYAML — workflow/lint helpers (yaml.safe_load) usable without pip install.
RUN pip install --no-cache-dir pyyaml

# --- Working directories ---
RUN mkdir -p /workspace \
    && chown -R ${USER_ID}:${USER_GROUP} /workspace

USER node
WORKDIR /workspace

CMD ["bash"]
