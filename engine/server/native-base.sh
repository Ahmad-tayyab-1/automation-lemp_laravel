# server/native-base.sh - server part "native-base": the tools every native server needs (the deploy
# steps use curl, git, unzip and jq). nginx, Redis, PHP and MariaDB are separate parts
# (native-nginx.sh, native-redis.sh, native-php.sh, native-mariadb.sh), so a server can get only some
# of them. Skipped when up to date (steps/server-parts.sh).

task "Install the base tools (curl, git, unzip, jq, openssl)"
apt_install ca-certificates curl git unzip jq openssl
