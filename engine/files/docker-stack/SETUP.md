# Shared stack — one-time server build

Everything here is done **once per server**. After this, adding a site never
touches this folder again.

One nginx container and one Redis container serve every site. Each site then gets
its own PHP-FPM container from one shared image.

Run everything as `root`.

---

## 1. Create the folders

```bash
mkdir -p /opt/docker-stack
mkdir -p /run/php-docker
mkdir -p /run/redis
mkdir -p /var/lib/redis
mkdir -p /var/log/nginx
```

The nginx config tree lives inside the stack folder, so create these as well:

```bash
mkdir -p /opt/docker-stack/nginx/conf/sites-available
mkdir -p /opt/docker-stack/nginx/conf/sites-enabled
mkdir -p /opt/docker-stack/nginx/conf/snippets
mkdir -p /opt/docker-stack/nginx/conf/conf.d
mkdir -p /opt/docker-stack/nginx/conf/cert
```

`cert/` is for certificates you manage by hand. Certbot certificates stay in
`/etc/letsencrypt`, which is mounted separately.

---

## 2. Set the permissions

### The FPM socket folder

```bash
chown www-data:www-data /run/php-docker
chmod 755 /run/php-docker
```

Every site's PHP-FPM socket is created inside this folder, and the nginx container
reads them. The nginx container runs its workers as uid 33 (`www-data`), which is
why this folder and the sockets must be group 33.

Check it:

```bash
id -u www-data        # must print 33
id -g www-data        # must print 33
```

### The Redis folders

```bash
chown redis:redis /run/redis /var/lib/redis
chmod 750 /var/lib/redis
```

```bash
id redis
# uid=110(redis) gid=113(redis)
```

Those two numbers matter: `docker-compose.yml` runs the Redis container as
`user: "110:113"` so the container can write to the host's data folder.
If `id redis` prints different numbers on a new server, fix the compose file.

### The nginx log folder

```bash
chown root:adm /var/log/nginx
chmod 755 /var/log/nginx
```

---

## 3. Make /run/php-docker survive a reboot

Everything under `/run` is wiped on every boot. Without this file the folder
disappears after a restart and every site returns 502.

```bash
echo 'd /run/php-docker 0755 www-data www-data -' > /etc/tmpfiles.d/php-docker.conf
systemd-tmpfiles --create
```

Check it:

```bash
ls -ld /run/php-docker
# drwxr-xr-x 2 www-data www-data
```

---

## 4. Check before building

```bash
bash /opt/docker-stack/check-docker.sh
```

---

## 5. Build the shared PHP image — once for all sites

```bash
cd /opt/docker-stack/base-image
docker build -t enzipe/php-fpm:8.2-alpine .
```

---

## 6. Build the nginx image — also once

```bash
cd /opt/docker-stack/nginx
docker build -t enzipe/nginx:stable-alpine .
```

This is a thin layer on the official image. The only reason it exists: the official
image's nginx user is uid 101, but this host needs uid 33 (`www-data`), otherwise the
container gets "permission denied" on every socket and log file.

---

## 7. Start the stack

```bash
cd /opt/docker-stack
docker compose up -d
```

---

## 8. Check both containers

```bash
docker compose ps

docker inspect -f '{{.State.Health.Status}}' enzipe-nginx    # must say: healthy
docker inspect -f '{{.State.Health.Status}}' enzipe-redis    # must say: healthy

docker compose logs --tail 30 nginx
docker compose logs --tail 30 redis
```

Make sure Redis still has its data and its socket:

```bash
ls -l /run/redis/
redis-cli -a '<password from redis.conf>' --no-auth-warning INFO keyspace
```

---

## Everyday commands

```bash
cd /opt/docker-stack
docker compose ps
docker compose logs -f nginx
docker exec enzipe-nginx nginx -t
docker exec enzipe-nginx nginx -s reload     # after changing any vhost
docker compose restart redis
```

---

## What comes next

The server is ready. Adding a site never touches this folder — see `SETUP.md`
in a site's project folder for those steps.
