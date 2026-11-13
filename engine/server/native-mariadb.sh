# server/native-mariadb.sh - server part "native-mariadb": MariaDB server and client (mariadb-server,
# mariadb-client), installed on the first local-environment deploy or by "deploy.sh server". MySQL is the
# other choice (native-mysql.sh). Skipped when up to date (steps/server-parts.sh).

task "Install MariaDB server and client"
if [[ -x /usr/sbin/mysqld && ! -x /usr/sbin/mariadbd ]]; then
  fail "MySQL is installed on this server. MySQL and MariaDB cannot run side by side (port 3306, conflicting packages): keep MySQL, or remove it first."
fi
apt_install mariadb-server mariadb-client

task "Ensure the MariaDB service is started and enabled"
if dry; then skip "dry run"; else
  systemctl is-enabled --quiet mariadb || { systemctl enable --quiet mariadb; changed; }
  systemctl is-active --quiet mariadb || { systemctl start mariadb; changed; }
fi
