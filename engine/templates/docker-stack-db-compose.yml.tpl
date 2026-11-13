# managed by deployer (engine/templates/docker-stack-db-compose.yml.tpl) - rewritten on every deploy.
# Local MariaDB for sites deployed with --env local. Started only by those deploys.
#
#   docker compose -p docker-stack-db -f {{ stack_dir }}/db/docker-compose.yml --env-file {{ stack_dir }}/.env up -d
#
# Host network like the rest of the stack, bound to 127.0.0.1 only, so DB_HOST=127.0.0.1 works
# for every site container and the database is never reachable from outside.

services:
  mariadb:
    image: mariadb:lts
    container_name: {{ stack_db_container }}
    restart: always
    network_mode: host
    command: ["--bind-address=127.0.0.1", "--port=3306"]
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - {{ stack_dir }}/db/data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    oom_score_adj: -500
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
