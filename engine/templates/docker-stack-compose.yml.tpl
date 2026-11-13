# managed by deployer (engine/templates/docker-stack-compose.yml.tpl) - rewritten on every deploy.
# Same as docker-stack/docker-compose.yml from the stack zip, plus:
#   - redis user = this server's redis uid:gid (detected, not hardcoded 110:113)
#   - /etc/nginx/cert mounted into nginx (certificates installed by deploy.sh)
# Shared infrastructure for EVERY site on this server: one nginx + one redis.
# Kisi site ka apna kuch yahan nahi hai — har site apne project folder mein rehti hai.
#
#   cd /opt/docker-stack
#   docker compose up -d        <- nginx + redis dono chal jate hain
#   docker compose ps
#   docker compose logs -f nginx
#
# Nayi site add karne par is file mein KUCH NAHI badalta. Sirf:
#   1) site ke project mein  ./site-docker.sh  chala kar  docker compose up -d
#   2) uska vhost /etc/nginx/sites-available/ mein rakhein (usi socket ke saath
#      jo script ne banaya), sites-enabled/ mein symlink karein
#   3) docker exec enzipe-nginx nginx -t && docker exec enzipe-nginx nginx -s reload

services:

  # ------------------------------------------------------------------ nginx
  nginx:
    build: ./nginx
    image: enzipe/nginx:stable-alpine
    container_name: enzipe-nginx
    restart: always

    # Host network, soch samajh kar:
    #  - CSF is box par bridge -> host traffic block karta hai (INPUT DROP, DOCKER="0")
    #  - dozzle vhost proxy_pass http://127.0.0.1:8080 karta hai
    #  - /nginx_status par "allow 127.0.0.1" hai
    #  - Cloudflare real_ip aur rate-limit zones bina NAT ke sahi chalte hain
    network_mode: host

    volumes:
      # Saari config host par rehti hai aur host par hi edit hoti hai
      - ./nginx/conf:/etc/nginx:ro               # saari nginx config stack ke andar
      - /etc/letsencrypt:/etc/letsencrypt:ro     # certbot certs (5 sites)
      - /etc/nginx/cert:/etc/nginx/cert:ro       # certificates installed by deploy.sh
      - /etc/ssl/deployer:/etc/ssl/deployer:ro   # sites not deployed since the certificates moved there
      - /var/www/html:/var/www/html:ro           # static files + acme webroot
      - /run/php-docker:/run/php-docker          # har site ka FPM socket
      - /run/php:/run/php                        # native php8.2-fpm socket
      - /var/log/nginx:/var/log/nginx            # logs host par hi likhti hain

    # Host nginx.conf mein worker_rlimit_nofile 65536 hai
    ulimits:
      nofile:
        soft: 65536
        hard: 65536

    # Config theek AND master process zinda. Kisi ek vhost par depend nahi karta.
    healthcheck:
      test: ["CMD-SHELL", "nginx -t >/dev/null 2>&1 && pgrep nginx >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    # Staging (saari sites live) par asal nginx RAM: master + 4 worker = 194 MB.
    # Load par upar isi liye jata hai ke har busy upstream connection ko
    # fastcgi_buffers 16x16k + buffer_size 32k = ~288k milte hain.
    # 1g = measured peak ka ~5x. Yeh cap reserve nahi hota (idle par 0 lagta
    # hai), bas chhat hai — itni oonchi ke normal load mein kabhi na chhue,
    # aur itni neechi ke kuch bhag jaye to 7.9G box ko na kha jaye.
    # Live production nginx ke asal numbers (cgroup = anon + page cache):
    #   webserver4        :  83M current /  295M peak   (cache manager chal raha)
    #   webserver02-fra1  : 345M current /  576M peak   (cache manager NAHI - humari config jesi)
    #   webserver1-fra    : 422M current / 1.2G peak    (cache manager chal raha)
    # Farq cache manager se aata hai: jin par fastcgi_cache/proxy_cache hai,
    # unke cgroup number mein cache files ki page cache bhi ginti hai -> 1.2G.
    # Humari config mein sirf open_file_cache hai (sirf metadata, ~kuch MB),
    # is liye apples-to-apples number 576M hai.
    # 2g rakha hai, 1.5g nahi: agar kal is server par bhi fastcgi_cache on
    # kiya (2 me se 2 production box par hai), to 1.5g par container marta
    # nahi lekin page cache lagataar reclaim hoti rehti -> cache thrash,
    # har hit disk se, aur ye khaamoshi se slow karta hai.
    mem_limit: 2g
    # CPU limit jaan boojh kar NAHI lagai. Nginx server ka darwaza hai — ise
    # throttle karna matlab traffic spike par HAR site slow. Khud se ye CPU
    # khata nahi (event-driven, I/O par yield karta hai); CPU sirf TLS handshake
    # aur gzip par lagti hai, aur wo asal kaam hai jo hona chahiye. Linux ka
    # scheduler phir bhi PHP containers ko fair share deta rehta hai.
    # (PHP containers par cpus: 2 lagi rehni chahiye — wahan ek bhagta hua
    #  site doosri sites ko bhooka kar sakti hai, nginx ke saath aisa nahi.)

    # Server par RAM khatam ho jaye to kernel ka OOM killer sabse pehle "bada"
    # process uthata hai. -1000 ka matlab: is container ko sabse aakhir mein chhuna.
    # Nginx khud ~20-30MB leta hai, is liye yeh apni wajah se cap tak nahi pohnchta.
    oom_score_adj: -1000

    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

  # ------------------------------------------------------------------ redis
  redis:
    # 7.0 par pin — host ke redis 7.0.15 se match, taake rollback par native
    # service wahi dump.rdb padh sake.
    image: redis:7.0-alpine
    container_name: enzipe-redis
    restart: always

    # Host network taake har site ka REDIS_HOST=127.0.0.1 waisa hi chale.
    network_mode: host

    # Host ka redis user (110:113) — data folder aur socket folder likhne ke liye.
    user: "{{ redis_uid }}:{{ redis_gid }}"

    # Host ki apni redis.conf hi use hoti hai (wahi password, wahi databases 200,
    # wahi DB layout). Sirf wo cheezein override ki hain jo container mein zaroori hain.
    command:
      - redis-server
      - /etc/redis/redis.conf
      - --daemonize
      - "no"                      # container ka main process foreground mein rehna chahiye
      - --appendonly
      - "yes"                     # AOF on: crash par 60s ke bajaye ~1s ka data jata hai
      - --appendfsync
      - everysec
      - --logfile
      - ""                       # stdout -> docker logs -> watchdog
      - --pidfile
      - /run/redis/redis-container.pid

    volumes:
      - ./redis/redis.conf:/etc/redis/redis.conf:ro   # redis config stack ke andar
      - /var/lib/redis:/var/lib/redis            # dump.rdb + appendonlydir
      - /run/redis:/run/redis                    # unix socket (12 containers isse jude hain)

    # Password ki zaroorat nahi: zinda redis ya PONG deta hai ya NOAUTH.
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping 2>&1 | grep -qE 'PONG|NOAUTH'"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s

    # Staging (saari sites chal rahi hain) par asal usage: used_memory 37.8M,
    # rss 39.9M, peak 40.3M. maxmemory 256mb + TTL + allkeys-lru ka matlab
    # Redis khud 512m cap tak nahi pohnch sakta — 512m mein ~12x headroom hai.
    # Size live production servers ke asal numbers se li hai (millions/day):
    #   webserver4           :  26M current / 40M peak
    #   webserver1-fra       : 187M current / 267M peak
    #   webserver02-fra1     : 348M current / 507M peak   <- sabse bada
    # Yeh systemd/cgroup numbers hain, yani anon + page cache. Page cache
    # reclaimable hai (cap par reclaim hoti hai, OOM kill nahi karti), to asal
    # khatre wala hissa anon hai ~ 300-400M.
    # Ek aur baat: un servers par appendonly OFF hai, yahan ON kiya hai. AOF
    # rewrite fork karta hai aur copy-on-write se anon aarzi taur par double ho
    # sakti hai -> worst case ~700-800M. 1g us ke bohat qareeb tha, is liye 2g.
    mem_limit: 1536m
    # cpus: 1 risky tha. Redis commands single-threaded hain, lekin AOF rewrite
    # ke waqt wo fork karta hai aur bachcha process poora dataset serialize
    # karta hai — ek hi core par wo aur main thread aapas mein ladte, aur us
    # dauran SAB sites ko Redis slow milti. 2 cores: ek main thread, ek fork +
    # background fsync/lazy-free threads ke liye.
    cpus: 2

    # Sessions aur cache yahan hain — yeh mara to sab sites par log-out.
    # OOM killer ki list mein sabse aakhir par.
    oom_score_adj: -1000

    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
