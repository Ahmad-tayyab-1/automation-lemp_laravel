# Shared PHP 8.2-FPM base image for every site on this server.
#
# Nothing site-specific is baked in. The site's Linux user is created at CONTAINER
# START by entrypoint.sh from the APP_USER / APP_UID / APP_GID env vars, and the
# site's pool settings come from its own bind-mounted php/pool.conf. That is what
# lets one image serve every site while each site keeps its own pool, socket and user.
#
# Build:  cd docker-stack/base-image && docker build -t enzipe/php-fpm:8.2-alpine .

# ---------- Stage 1: builder (compiler + headers, thrown away) ----------
FROM php:8.2-fpm-alpine AS builder

# mongodb pinned to 1.x (deployer addition): Laravel projects on mongodb/mongodb 1.x
# (e.g. jenssegers/mongodb) require ext-mongodb ^1.x; same pin as the native setup.
ARG MONGODB_VERSION=1.20.1

RUN apk add --no-cache $PHPIZE_DEPS \
        libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev \
        libxml2-dev icu-dev openssl-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli zip gd bcmath intl exif pcntl opcache soap \
 && pecl install redis "mongodb-${MONGODB_VERSION}" \
 && docker-php-ext-enable redis mongodb

# ---------- Stage 2: runtime (the image that actually runs) ----------
FROM php:8.2-fpm-alpine

# Runtime libraries for the extensions above, plus the tools used inside the
# container. fcgi provides cgi-fcgi, which the compose healthcheck uses to ping
# PHP-FPM through its unix socket.
RUN apk add --no-cache \
        libzip libpng libjpeg-turbo freetype libxml2 icu-libs \
        git openssh-client unzip bash nano less mariadb-client fcgi tzdata

# Only the built extensions and their .ini files come across from the builder.
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/     /usr/local/etc/php/conf.d/

# Composer pinned to 2.7.1 — newer 2.x refuses to resolve laravel/framework 11
# because of its security-advisory check.
COPY --from=composer:2.7.1 /usr/bin/composer /usr/bin/composer

# Production php.ini defaults, and remove the 3 default pool files the base image
# ships (www.conf, docker.conf, zz-docker.conf). Ours come from the project's php/ folder.
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && rm -f /usr/local/etc/php-fpm.d/www.conf \
          /usr/local/etc/php-fpm.d/docker.conf \
          /usr/local/etc/php-fpm.d/zz-docker.conf

# Alpine's www-data is 82, this host's is 33. Recreate it as 33:33 so the FPM
# socket group matches the nginx container and the host's file permissions.
RUN deluser www-data 2>/dev/null || true; delgroup www-data 2>/dev/null || true; \
    addgroup -g 33 www-data \
 && adduser -D -H -u 33 -G www-data -s /sbin/nologin www-data

# git refuses to work in a directory it does not own. In a shared image the
# project path is not known at build time, so trust every path inside the container.
RUN git config --system --add safe.directory '*'

COPY entrypoint.sh /usr/local/bin/site-entrypoint.sh
RUN chmod +x /usr/local/bin/site-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/site-entrypoint.sh"]
CMD ["php-fpm"]
