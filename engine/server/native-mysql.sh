# server/native-mysql.sh - server part "native-mysql": Oracle MySQL server and client from Ubuntu/Debian
# (mysql-server, mysql-client). MariaDB is the other choice (native-mariadb.sh); one server runs one of
# them (both use port 3306 and their packages conflict). Skipped when up to date (steps/server-parts.sh).

task "Install MySQL server and client"
if [[ -x /usr/sbin/mariadbd ]]; then
  fail "MariaDB is installed on this server. MySQL and MariaDB cannot run side by side (port 3306, conflicting packages): keep MariaDB, or remove it first."
fi
apt_install mysql-server mysql-client

task "Ensure the MySQL service is started and enabled"
if dry; then skip "dry run"; else
  systemctl is-enabled --quiet mysql || { systemctl enable --quiet mysql; changed; }
  systemctl is-active --quiet mysql || { systemctl start mysql; changed; }
fi
