# Deployer, bash edition

This is the same Laravel deploy tool as `../deployer`, with **no Ansible**. The menus, prompts, `sites.json`, `targets.json`, setups, switches and checks are the same. The part that changes servers is plain bash in `engine/`, and every config file it writes comes from a **bash template** in `engine/templates/`.

Everything in `../deployer/README.md` (deploy flow, prompts, commands, switching, docker stack) applies here too. This file covers what is different.

## 1. Quickstart

```bash
./install.sh          # jq, git, openssl, whiptail, python3 (no Ansible)
./deploy.sh           # menu: deploy, set up a server, add a site, status, certificates, register a target
./deploy.sh --check   # dry run: every file the deploy would change is shown as a diff
./deploy.sh server    # set up or change a server: add, stop or swap parts (snapshot first)
./deploy.sh rollback  # return a server to a snapshot
```

In the menu, when a task ends (done, failed or cancelled), deploy.sh asks "Do something else? Back to the menu [y/N]": `y` shows the menu again, Enter or `n` quits.

### Setting up or changing a server (stack change and rollback)

`deploy.sh server` (or "Set up a server" in the menu) sets what a server runs, with or without sites. One checklist builds the stack; tick any mix:

- **Docker stack** (nginx, PHP 8.2 and Redis in containers), or **LEMP** (nginx + PHP + MariaDB + Redis, native; MySQL instead when MySQL is ticked too)
- single services: **nginx**, **PHP**, **MariaDB**, **MySQL**, **Redis**, **certbot**, **ClickHouse**, **Node.js**. For example, nginx + ClickHouse + Node installs only those three.
- **CSF firewall**: its questions come after the server is set up (see Firewall below)

The Docker stack cannot be ticked together with native nginx, PHP, Redis, MySQL or LEMP, because it runs its own. With `-y`, `--install docker` and `--install lemp` do the same as those two items. The checklist starts with what runs now:

- **Tick** a part to install it, or to start it again when it was stopped.
- **Untick** a running part to stop it. It is stopped and disabled; its packages, config and data stay, so starting it again is quick. Node.js has no service, so it is uninstalled.

| Setup | Parts |
|---|---|
| `native_lemp` | `nginx`, `php` (one or more versions, with Composer), `mariadb` or `mysql`, `redis`, `certbot` (needs nginx), `clickhouse` (26.7.5.10, held), `node` (22 LTS + npm) |
| `docker_stack` | the stack (nginx, PHP 8.2 and Redis containers), plus `mariadb`, `certbot`, `clickhouse`, `node` |

**MariaDB ↔ MySQL.** Their packages conflict and both use port 3306, so choosing the other one asks what happens to the current one (`--db-swap`):

| Choice | What happens |
|---|---|
| `stop` | Stop it and start the new one. Its data folder is kept in `/var/lib/deployer/db-data/<name>`; switching back later uses it again. |
| `dump` | Remove it, after dumping every database into the snapshot. |
| `delete` | Remove it and all its data. |
| `both` | Keep both: the current one stays on 3306, the new one runs on 127.0.0.1:3307 in a Docker container (root password in `/etc/deployer/second_db_root_password`). |

The new database server starts empty (unless it ran on this server before), so sites with a local database need a redeploy.

**Setup change.** A server without sites can also change setup (`native_lemp` ↔ `docker_stack`). A server with sites changes setup with a site deploy and `--switch move|stop`.

**Safety.** Stopping a part that a site on the server still uses (nginx, its PHP version, Redis, the database) asks first. With `-y` it needs `--force`.

**Snapshot and rollback.** Every change starts with a snapshot in `/var/lib/deployer/snapshots/<time>/`. It holds:
- which parts ran (`state.json`);
- `server.json` and the setup marker;
- the config folders (`etc.tgz`);
- the dumps of a `dump` swap.

The newest 20 snapshots are kept.

`deploy.sh rollback` lists the snapshots and returns the server to one. It runs the parts that ran then and stops the ones added since. A swapped database is swapped back, with its kept data folder or the snapshot's dumps. A rollback takes a snapshot too, so it can be undone the same way.

```bash
./deploy.sh server                                                      # asked in menus
./deploy.sh server --target db1 --setup native_lemp --install mariadb,redis -y
./deploy.sh server --target this --setup native_lemp --install clickhouse,node -y
./deploy.sh server --target this --setup native_lemp --remove redis,php-8.1 -y
./deploy.sh server --target this --setup native_lemp --install mysql --db-swap stop -y   # MariaDB -> MySQL
./deploy.sh server --target this --setup native_lemp --install mysql --db-swap both -y   # MySQL on 3307 too
./deploy.sh server --target this --setup native_lemp --install clickhouse --remove nginx,php,mariadb,redis -y
./deploy.sh rollback --target this                                      # pick a snapshot
./deploy.sh rollback --target this --snapshot 20261022-091500 -y
```

MariaDB, MySQL, Redis and ClickHouse listen on 127.0.0.1 only. When ClickHouse is installed, deploy.sh asks for the `default` user's password: type your own, or let it make a random one. With `-y`, set it with `DEPLOY_CLICKHOUSE_PASSWORD`. A later run can change it. The password is kept in `/etc/deployer/clickhouse_password`. Redis works the same way: when it is installed (LEMP, or the Docker stack), deploy.sh asks for your own password or makes a random one (`-y`: `DEPLOY_REDIS_PASSWORD`). `deploy.sh server` on a server that has Redis asks to keep it or set a new one; a new one is written to every site's `.env` right away (and a cached config is built again), so the sites keep working. It is kept in `/etc/deployer/redis_password` (Docker stack: `requirepass` in `/opt/docker-stack/redis/redis.conf`). Only letters, digits and `. _ @ % + = : , ! ^ * ~ -` are allowed, 8 or more. You can also choose **no password** (`DEPLOY_REDIS_PASSWORD=none`): Redis still listens on 127.0.0.1 only, but any program on the server can use it; the sites get `REDIS_PASSWORD=null`. The server is recorded in `/etc/deployer/server.json`, so a site deployed to it later only installs what is still missing.

### Firewall (CSF)

`deploy.sh firewall` (or `csf`, or "Firewall (CSF)" in the menu) installs CSF and LFD on a target, changes their settings, or turns them off, on again, or uninstalls them. The questions start from what the server has now:

| Question | Choices |
|---|---|
| Who may use SSH | everyone (LFD blocks brute force), or only the allowed IPs |
| Ports open to everyone | only SSH; SSH + 80/443; SSH + 80/443 from Cloudflare's ranges only; CSF's default list; your own TCP and UDP lists |
| Always allowed (`csf.allow`) | IPs that reach every port; your own IP is suggested |
| Never blocked by LFD (`csf.ignore`) | default: the allowed IPs |
| Always blocked (`csf.deny`) | IPs |
| Ports for some IPs only | `3306:1.2.3.4 53/udp:5.6.7.8` |
| Outgoing | all (recommended), or CSF's common ports + the sites' database ports |
| Ping, LFD | answer ping; failed SSH logins before a block (default 5); block for 1 hour, 1 day or for good; alert email |
| Start | test first (recommended), or stay in TESTING mode |

How a change goes live:

1. It is applied in CSF's TESTING mode, where CSF clears its rules every 5 minutes.
2. deploy.sh opens a **new** SSH connection to the server.
3. If that works, TESTING is switched off and LFD starts. If it fails, CSF stays in TESTING mode and you can connect again within 5 minutes.

When deploy.sh runs on the server itself, it asks you to open a **new** SSH session in another terminal and type `yes`. With no answer within 4 minutes, or with `-y`, CSF stays in TESTING mode. Every IP connected over SSH at that moment is always added to `csf.allow` and can never be blocked: your own session (also through sudo or `multipass shell`, which connects from the host's bridge IP) and anyone else logged in. The SSH port is always kept open.

Other things it does:

- ufw and firewalld are turned off.
- The lists it writes sit between `# BEGIN deployer` and `# END deployer` in `csf.allow`, `csf.ignore` and `csf.deny`. Lines you add by hand, or with `csf -a` and `csf -d`, are kept.
- Before every change, `/etc/csf` is copied to `/var/lib/deployer/csf-backups/`; the newest 20 copies are kept.
- On a server with Docker, a csf reload removes Docker's iptables rules. A `csfpost.sh` hook restarts Docker after each reload, and `live-restore` in `/etc/docker/daemon.json` keeps the containers running meanwhile. The hook resets systemd's start limit first (several reloads in a row used to leave Docker stopped), and deploy.sh checks that Docker runs after every reload. Ports that a container publishes stay open whatever CSF's port lists say.
- CSF comes from `download.configserver.com`. That site has been gone since ConfigServer shut down in 2025, so the engine falls back to the maintained fork at `download.configserver.dev`.

```
./deploy.sh firewall                                                    # questions
./deploy.sh firewall --target web1 --fw-ports web -y                     # SSH + 80/443, your IP allowed
./deploy.sh firewall --target web1 --fw-ssh allowed --fw-allow 1.2.3.4,5.6.7.8 --fw-ports cloudflare -y
./deploy.sh firewall --target web1 --fw-port-ip 3306:10.0.0.5 --fw-deny 203.0.113.9 -y
./deploy.sh firewall --target web1 --fw-action off -y                    # also: on, uninstall
```

The options are the same as the Ansible version. The `-- ARGS` for ansible-playbook is gone, and there are two new options:

| Option | What it does |
|---|---|
| `--verbose` | shows the output of every step while it runs (normally it goes to a log and is shown only when a step fails) |
| `--timings` | lists the slowest steps at the end |

### What a site gets on the server

- **User:** a real account, `/home/<user>` with bash (`su - jpgtoword_net`). It has no password or SSH login until you give it one. It owns the project folder.
- **One user or many:** each deploy asks: 1 user for all sites (test server, you name it) or 1 user per site (production, the default). `--site-user NAME` or `--site-user per-site` with `-y`. The choice is saved in `/etc/deployer/site_user`; other sites change on their next deploy. With 1 user for all sites, there is one `~/.ssh/id_rsa`, so that key must have access to all the repositories. Sockets, containers, databases and Redis prefixes stay per site either way.
- **Git key:** only the site user has it, in `~/.ssh/id_rsa` and `id_rsa.pub`, and git runs as that user. `add-site` asks for the private key and then the public key, and checks they are a pair (or generates a new pair). The key waits in `~/.ssh/<domain>_deploy` on the deploy machine until the first successful deploy, which removes that copy. Later deploys use the key on the server.
- **PHP-FPM:** `pool.d/<site>.conf`, pool `[<site>]` (for example `textoinvisible_info`), `user` and `group` = the site user, socket `/run/php/php<version>-fpm-<site>.sock` with `listen.owner = www-data` so nginx can reach it. pm values come from the traffic level.
- **Permissions:** the project is `<user>:www-data`, folders 755, files 655, `.env` 0640, and the folders in `storage`, `bootstrap/cache` and `config` always 775. Set on every deploy. artisan and the scheduler run as the site user too.
- **nginx:** ports 80 and 443 both serve the site. `/admin` is limited by `/etc/nginx/snippets/allowed_admin_ips.conf`, and `$block_ip` reads `/etc/nginx/snippets/blockips.conf`.
- **Certificate:** `/etc/nginx/cert/<domain>/certificate.crt` and `privatekey.key`. On Docker the same folder is mounted into the nginx container. A site deployed before this moves from `/etc/ssl/deployer/` on its next deploy.
- **Upgrade:** a site deployed before this gets all of the above on its next deploy (its `nologin` user becomes a real one).

## 2. Layout

```
deploy.sh             menus, prompts, sites.json; builds vars.sh and runs the engine
engine/
  run.sh              the order of the steps (what ansible/site.yml was)
  lib/core.sh         the task runner: step output, ok/changed/skipped, dry run, errors, recap
  lib/template.sh     the template renderer
  lib/files.sh        writing files (diff in a dry run, backups, owner/mode), packages
  steps/*.sh          one file per step, same names as ansible/steps/*.yml
  steps/firewall.sh   deploy.sh firewall (CSF), run on its own
  server/*.sh         server parts: native-base (tools), native-nginx, native-redis, native-php
                      (per PHP version, with Composer), native-mariadb, certbot, docker-stack.
                      The Ansible version has nginx and Redis inside native-base.
  templates/*.tpl     every config file the deployer writes
  files/              files copied as they are (the docker stack, the PHP PPA key, docker.conf)
lib/status.py         deploy.sh status (same as the Ansible version)
bench/                the speed test against the Ansible version
```

## 3. Changing a config file

Edit the template in `engine/templates/`. The next deploy writes the new version, checks it (`nginx -t`, `php-fpm -t`), and puts the old one back if it is rejected.

| To change | Edit |
|---|---|
| A site's nginx vhost (native and Docker) | `site-vhost.conf.tpl` (the port 80 and 443 server blocks, both serving the site; the `/.well-known/acme-challenge/` location only for a certbot certificate, issued now or renewed by certbot) and `site-vhost-body.tpl` (the locations) |
| Native: `$block_ip` and the IP lists | `native-block-ip.conf.tpl`, `native-blockips.conf.tpl`, `native-admin-ips.conf.tpl` (the two lists in `/etc/nginx/snippets/` are written only when missing, so your edits stay) |
| PHP-FPM pool, native | `native-pool.conf.tpl` |
| PHP-FPM pool, Docker site | `docker-site-pool.conf.tpl` |
| Process manager settings (both pools) | `php-pool-pm.tpl`, with values from `traffic.json` |
| Docker site container | `docker-site-compose.yml.tpl` |
| The keys written into every site's `.env` | `app-env.tpl` |
| Native Redis, Cloudflare real IP | `native-redis.conf.tpl`, `native-realip.conf.tpl` |
| systemd restart-on-crash drop-in (nginx, PHP-FPM) | `systemd-restart.conf.tpl` |
| certbot renewal hook | `certbot-deploy-hook.sh.tpl` |
| Docker stack: nginx.conf, redis.conf, watchdog.conf, compose files, IP lists | `docker-stack-*.tpl` |
| The site record in `/etc/deployer/sites/` | `site-record.json.tpl` |
| A Docker site's `php/docker.conf` | `files/docker-site-fpm-global.conf` (copied, no variables) |

As with Ansible, the Docker stack's `nginx.conf`, `redis.conf` and `watchdog.conf` are written only when missing, so edits made on the server stay.

### Template syntax

A template is the config file itself plus a few tags, the same idea as Jinja2:

```nginx
server {
    listen 80;
{% if [[ $docker == yes ]] %}
    listen [::]:80;
{% endif %}
    server_name {{ site_names }};
{% for line in traffic_extra_nginx %}
    {{ line }}
{% endfor %}
{% include site-vhost-body.tpl %}
}
```

| Tag | Meaning |
|---|---|
| `{{ var }}` | the value of a bash variable. An unset variable stops the deploy, so a typo can never write an empty value |
| `{% if BASH-CONDITION %}` … `{% elif … %}` … `{% else %}` … `{% endif %}` | lines kept only when the condition is true; the condition is ordinary bash, e.g. `[[ $tls_mode != none ]]` |
| `{% for x in ARRAY %}` … `{% endfor %}` | lines repeated for each element of a bash array |
| `{% include NAME %}` | another template inserted here |
| `{# … #}` | a comment, never written (may span several lines) |

A line holding only a tag disappears completely. Everything else is copied exactly, so nginx's `$uri` and `$host` or PHP-FPM's `;` comments need no escaping. The renderer is `engine/lib/template.sh` (about 120 lines of bash, no subshell per line: a vhost renders in about 20 ms).

The variables a template can use are set in `engine/run.sh` (fixed paths and names), in `vars.sh` from deploy.sh (the site, its traffic level, the setup and so on), and by the steps before it (e.g. `site_uid`, `redis_password`).

### The same output as Ansible

On both test servers, the bash templates produce byte-for-byte the same vhosts, pools, compose files, IP lists, real-IP file and drop-ins as the Ansible templates. The only difference is the two docker-stack compose files, whose first comment line now names the `.tpl` file. A dry run of the four existing sites showed no other change to any file, including `.env`.

## 4. How a deploy runs

1. `deploy.sh` asks its questions (or reads the options) as before and writes `vars.sh`: plain bash assignments for this one deploy, mode 0600, removed afterwards.
2. **This machine:** `sudo bash engine/run.sh vars.sh`. **Remote target:** `engine/` and `vars.sh` (plus a certificate or database dump from this machine, if the deploy needs one) are sent with `tar` over ssh into a private temp folder there. Then `sudo bash engine/run.sh` runs over the same ssh connection, and the folder is removed. Git runs as the site user, with its own key. The target needs bash, tar and sudo, nothing else. `jq` is installed by the first server part.
3. `run.sh` runs the steps in the same order as `ansible/site.yml`. Each step prints one line, `ok`, `changed`, `skipped` or `FAILED`, with its time. A failure shows the reason and the step's last output lines, except for steps that handle passwords.

Output looks like this:

```
== Site on native nginx and PHP-FPM
   Check server_name conflicts and the site's current vhost link ... ok 0.00s
   PHP-FPM pool (put back when PHP-FPM rejects it) ... changed 0.30s
   Nginx vhost: enable, validate and reload (put back when nginx rejects it) ... changed 0.09s

RECAP  ok=26  changed=12  skipped=4  failed=0  time=41.88s
```

## 5. Differences from the Ansible version

- **Faster:** in the 3-round benchmark, a new project took 50.1 s instead of 60.1 s and a redeploy 25.6 s instead of 33.1 s. The tool's own time is about 2.7 s per deploy instead of about 11 s; composer and git take nearly all the rest. See `bench/` and `../report.md`.
- **Docker site pool changes now take effect.** `php/pool.conf` is bind-mounted into the site's container as a single file. Ansible replaces the file with a new one, so the running container kept the old pool, even after a restart; a traffic-level change never reached PHP-FPM. The bash engine rewrites the file in place, so the reload that follows picks it up (tested: max_children 10 → 20 inside the container).
- **Restart policy after a switch back to Docker.** A setup switch sets `restart=no` on every container so the closed setup stays down. When the server later switches back, `docker compose up -d` starts the unchanged containers again but leaves them on `restart=no`, so the sites would not come back after a reboot. The bash engine sets them back to `restart: always` after each `compose up`. The Ansible version still has this gap.
- **Redis restart:** after the Redis config changes, Redis is restarted right after the server parts. Ansible waited until the end of the deploy.
- **Server parts:** the parts are the same, but the bash version records them under `"applied_bash"` in `/etc/deployer/server.json` (Ansible uses `"applied"`), so both tools can be used on one server without each re-running every part. On a server set up by the Ansible version, the first bash deploy runs each part once ("changed"). That finds everything installed and takes about a second.
- **Still uses python3:** `deploy.sh`'s checks of sites.json, the setup-switch prompt, and `deploy.sh status` use python3, as in the Ansible version. Ubuntu and Debian servers have it.

## 6. Tested

On the two test VMs (native-lemp and docker-lemp):

- **Dry runs:** of all four real sites; nothing to change except the comment line above.
- **New and re-deployed test sites:** native and Docker, with the database seeded, imported from a dump, or left alone.
- **TLS:** certificate files from the deploy machine, an existing certificate on the target, and certbot's failure path (no public DNS on the VMs). The site keeps its certificate.
- **Remote deploy:** over ssh from docker-lemp to native-lemp, with a certificate and a database dump sent along.
- **Fail-safes:**
  - A broken nginx file elsewhere on the server stops the deploy before any change.
  - A vhost that nginx rejects is put back exactly as it was, with no backup file left behind.
  - Tested on native and on Docker.
- **Docker:** a traffic-level change reaches PHP-FPM inside the container.
- **Real redeploys:** jpgtoword.net (native, HTTPS) and jpgapdf.net (Docker).
- **Uptime:** the other sites were polled every half second during the deploys, and every answer was normal.

Added on 2026-10-19:

- **Real setup switch on docker-lemp, both directions, moving both real sites:**
  - Docker → native took 6 min, mostly installing nginx, PHP and MariaDB for the first time.
  - Native → Docker took 72 s.
  - Every time, each database was dumped before the old setup stopped and imported with the same table count (43 and 39). Both sites answered afterwards, one of them over HTTPS with its kept certificate.
  - A reboot afterwards brought every container back.
- **Brand-new empty server (a temporary VM), deployed remotely over ssh from docker-lemp:**
  - native: 5 min from empty to HTTP 200, with 43 tables imported and all services enabled. The redeploy took 28 s, with every server part skipped.
  - Docker: 13 min, 11 of them building the PHP and nginx images. The site answered 200, the redeploy took 22 s, and the site came back after a reboot.
- These tests found and fixed two bugs:
  - The restart policy after a switch back to Docker (section 5).
  - A `.sql.gz` dump sent to a remote server lost its file extension, so the import treated it as plain SQL and failed.

Added on 2026-10-22 (two temporary VMs; deploy.sh ran from the workstation over ssh, and on the VM itself):

- **CSF:**
  - Install, then each kind of port setting: SSH only, web, Cloudflare (22 ranges), CSF defaults, custom TCP and UDP lists.
  - SSH only from the allowed IPs: closed to another VM, open to the allowed one.
  - Ports for some IPs only: open to that IP and closed to the others. Blocked IPs added and removed.
  - LFD blocked an IP after 3 failed logins, for 1 hour. An IP in `csf.ignore` was never blocked.
  - Off, on, uninstall and reinstall. A reboot kept the rules.
  - Lockout test: a change that closed SSH to this machine stayed in TESTING mode, and SSH answered again 4 minutes later.
  - On a Docker host: containers stayed up, a published port and container internet access still worked, also after a reboot.
  - Plain prompts, whiptail menus, and the `-y` flags with every refusal.
- **Docker-stack server changes:** stop the stack's MariaDB and Node, then roll back. Switch a Docker-stack server without sites to native_lemp; ClickHouse and Node carry over.
- **Sites:** a real Laravel 13 site, deployed fresh and redeployed. Stopping Redis was refused without `--force`, and stopping ClickHouse was not. A delete-mode MariaDB → MySQL swap was refused without `--force`; with it, the site redeployed on MySQL. Rolling back to MySQL brought the site's database back.
- Bugs found and fixed:
  - `storage:link` failed on a new site: artisan ran as www-data, which cannot write in `public/`. artisan now runs as the site user.
  - A redeploy turned the next page into a 500 error. The compiled Blade views belonged to the site user, and PHP-FPM cannot set their time, so the views are now cleared on every deploy.
  - `systemctl restart csf` loads the previous rules again (FASTSTART), so the engine uses `csf -r`.
  - The "stack's containers" list was always empty.
  - With `-y`, `deploy.sh server` needed `--setup` even on a server that already has one.
  - A typed IP list was lost: two prompt helpers used the same variable name.
  - The rollback summary said "data restored" when the data had been deleted.
  - A Docker site's PHP container never became ready after its folder was deleted and made again: it still had the old folder mounted. It is now recreated once when it is not ready after 30 s.
- **Docker site:** the same Laravel site moved to the Docker stack (Laravel 12, since the stack is PHP 8.2), deployed and redeployed with HTTP 200.
