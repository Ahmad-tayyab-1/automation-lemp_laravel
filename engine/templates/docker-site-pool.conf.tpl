; managed by deployer (same layout as docker-stack/site-docker.sh) - rewritten on every deploy.
; PHP-FPM pool for {{ site_domain }} (traffic: {{ traffic_level }}). Reload after a manual change:
;   docker compose kill -s SIGUSR2 php
[{{ site_id }}]
user = {{ linux_user }}
group = {{ linux_user }}

listen = {{ stack_socket_dir }}/{{ site_id }}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

{% include php-pool-pm.tpl %}

catch_workers_output = yes
clear_env = no

; Used by the container healthcheck in docker-compose.yml
ping.path = /ping
ping.response = pong

; Requests slower than 3s are logged with a full stack trace.
; storage/logs is inside the project, so the file is readable on the host.
slowlog = {{ project_dir }}/storage/logs/php-fpm-slow.log
request_slowlog_timeout = 3s
