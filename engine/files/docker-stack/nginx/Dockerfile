# Thin layer on the official nginx image for this server.
#
# The ONLY reason this image exists: the official image's nginx user is uid 101,
# but this host runs nginx workers as www-data = 33:33. The PHP-FPM sockets are
# 0660 <siteuser>:33 and the log files are 0640 www-data:adm, so without uid 33
# the container gets "permission denied" on every site.
#
# Build:  cd docker-stack/nginx && docker build -t enzipe/nginx:stable-alpine .

FROM nginx:stable-alpine

RUN deluser www-data 2>/dev/null || true; delgroup www-data 2>/dev/null || true; \
    addgroup -g 33 www-data \
 && adduser -D -H -u 33 -G www-data -s /sbin/nologin www-data \
 && apk add --no-cache curl

# Config, certs, web roots, sockets and logs all come from the host as bind mounts
# (see docker-compose.yml) — nothing is copied into this image.
