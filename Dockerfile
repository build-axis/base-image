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
#   build-essential — gcc/g++/make for npm packages with native builds
#                     (node-gyp); without it `npm ci` fails on any dep
#                     that has no prebuilt binary
#   default-mysql-client — mysql CLI for debugging site DBs from inside
#   jq, zip      — CI/script helpers
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
ARG USER_ID=1000
ARG USER_GROUP=1000
RUN groupadd -g ${USER_GROUP} node 2>/dev/null || true \
    && useradd -u ${USER_ID} -g ${USER_GROUP} -m -s /bin/bash node 2>/dev/null || true \
    && echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node

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

# --- PHP 8.4.27 (deb.sury.org, pinned) ---
# Runtime for PHP projects in the workspace: pdo_mysql, pdo_sqlite, opcache, redis.
# imagick — needed by the laravel-file-upload tests (image info/preview);
# without it those tests skip instead of exercising real code.
# pcntl is already built into php8.4-cli on Debian.
RUN curl -fsSL https://packages.sury.org/php/apt.gpg \
        -o /usr/share/keyrings/deb.sury.org-php.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        php8.4-cli=8.4.27-* \
        php8.4-mysql=8.4.27-* \
        php8.4-sqlite3=8.4.27-* \
        php8.4-opcache=8.4.27-* \
        php8.4-redis \
        php8.4-mbstring=8.4.27-* \
        php8.4-xml=8.4.27-* \
        php8.4-curl=8.4.27-* \
        php8.4-zip=8.4.27-* \
        php8.4-intl=8.4.27-* \
        php8.4-bcmath=8.4.27-* \
        php8.4-gd=8.4.27-* \
        php8.4-imagick \
        php8.4-pcov \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# --- Image toolchain (mirrors the prod php image) ---
# The file-upload code inspects real assets: imagemagick delegates to
# ghostscript for PDF/EPS and to inkscape for CDR; liblcms2 keeps ICC
# colour handling identical to prod. The policy/delegate edits are the
# same as in the prod Dockerfile — stock Debian IM refuses PDF and has
# no working CDR delegate. (libpng/libjpeg/freetype/zip/icu -dev
# packages are skipped: prod needs them to compile extensions via
# docker-php-ext-*, our extensions come prebuilt from sury.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ghostscript \
        imagemagick \
        inkscape \
        liblcms2-2 \
    && sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/g' /etc/ImageMagick-6/policy.xml \
    && sed -i 's/rights="none" pattern="CDR"/rights="read|write" pattern="CDR"/g' /etc/ImageMagick-6/delegates.xml \
    && sed -i '/delegate.*decode="cdr"/d' /etc/ImageMagick-6/delegates.xml \
    && sed -i '/<delegatemap>/a \  <delegate decode="cdr" command="cp &quot;%i&quot; &quot;%i.cdr&quot;; inkscape &quot;%i.cdr&quot; --export-filename=&quot;%o.svg&quot;; mv &quot;%o.svg&quot; &quot;%o&quot;; rm -f &quot;%i.cdr&quot;"/>' /etc/ImageMagick-6/delegates.xml \
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

# pcov — coverage driver so `php artisan test --coverage` works out of the
# box (negligible overhead when coverage is not being collected).
RUN echo 'pcov.enabled=1' > /etc/php/8.4/cli/conf.d/98-pcov.ini

# PyYAML — workflow/lint helpers (yaml.safe_load) usable without pip install.
RUN pip install --no-cache-dir pyyaml

# --- Working directories ---
RUN mkdir -p /workspace \
    && chown -R ${USER_ID}:${USER_GROUP} /workspace

USER node
WORKDIR /workspace

CMD ["bash"]
