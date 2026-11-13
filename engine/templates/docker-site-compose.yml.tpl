# managed by deployer (same layout as docker-stack/site-docker.sh) - rewritten on every deploy.
# PHP-FPM container for {{ site_domain }}. Run docker compose commands from this folder.
services:
  php:
    # Shared base image, built once for all sites. No per-site build here.
    image: {{ stack_php_image }}
    container_name: {{ site_container }}
    restart: always

    # Host network: 127.0.0.1 inside the container is the host, so the site's
    # REDIS_HOST / DB_HOST settings work unchanged.
    network_mode: host

    working_dir: {{ project_dir }}

    # The base image creates this user at start-up, so one image fits every site.
    environment:
      APP_USER: {{ linux_user }}
      APP_UID: "{{ site_uid }}"
      APP_GID: "{{ site_gid }}"

    volumes:
      # Project code and .env — same path inside and outside
      - {{ project_dir }}:{{ project_dir }}
      # FPM socket folder shared with the nginx container
      - {{ stack_socket_dir }}:{{ stack_socket_dir }}
      # Redis unix socket (sites that connect over the socket instead of TCP)
      - /run/redis:/run/redis
      # Site PHP settings on top of the image's php.ini-production (conf.d, loaded last);
      # edit on the host, then reload with: docker compose kill -s SIGUSR2 php
      - ./php/php.ini:/usr/local/etc/php/conf.d/zz-site.ini:ro
      - ./php/pool.conf:/usr/local/etc/php-fpm.d/zz-app.conf:ro
      - ./php/docker.conf:/usr/local/etc/php-fpm.d/docker.conf:ro

    # Asks PHP-FPM itself over its socket — catches "container up but FPM wedged".
    healthcheck:
      test: ["CMD-SHELL", "SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect {{ stack_socket_dir }}/{{ site_id }}.sock 2>/dev/null | grep -q pong"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

    mem_limit: {{ traffic_mem_limit }}
    cpus: {{ traffic_cpus }}

    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

# One-off commands (run manually when needed):
#   docker compose exec -u {{ linux_user }} php composer install --no-dev -o
#   docker compose exec -u {{ linux_user }} php php artisan migrate --force
#   docker compose exec -u {{ linux_user }} php php artisan optimize:clear
