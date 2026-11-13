# managed by deployer
bind 127.0.0.1 -::1
port 6379
protected-mode yes
{% if [[ -n $redis_password ]] %}
requirepass {{ redis_password }}
{% else %}
# no password (deploy.sh server: "No password"); Redis listens on 127.0.0.1 only
{% endif %}

dir /var/lib/redis
pidfile /run/redis/redis-server.pid
logfile /var/log/redis/redis-server.log

maxmemory 256mb
maxmemory-policy volatile-lru

appendonly yes
appendfsync everysec

databases 256

# FLUSHALL/DEBUG are renamed in redis.conf itself (once): a rename that runs twice stops redis.

