# server/native-php.sh - server part "native-php-<version>": PHP-FPM <version> from Ubuntu or the
# ondrej/php PPA, with the pinned mongodb extension, plus Composer and the build tools (once per server).
# One part per PHP version, so adding a version only runs this file. Skipped when up to date
# (steps/server-parts.sh).

mongodb_version=1.20.1; [[ $php_version != 8.0 ]] || mongodb_version=1.16.2
composer_version=2.7.7
composer_sha256=aab940cd53d285a54c50465820a2080fcb7182a4ba1e5f795abfb10414a4b4be

# build tools for the mongodb extension below
task "Install the build tools (build-essential, pkg-config, libssl-dev)"
apt_install build-essential pkg-config libssl-dev

task "Install Composer $composer_version"
if [[ ! -e /usr/local/bin/composer ]]; then
  changed
  if dry; then note "would download composer.phar $composer_version"; else
    curl -fsSL -o /usr/local/bin/composer.part "https://getcomposer.org/download/$composer_version/composer.phar"
    echo "$composer_sha256  /usr/local/bin/composer.part" | sha256sum -c --quiet \
      || { rm -f /usr/local/bin/composer.part; fail "composer.phar $composer_version does not match its checksum"; }
    chmod 0755 /usr/local/bin/composer.part && mv -f /usr/local/bin/composer.part /usr/local/bin/composer
  fi
else
  skip "installed"
fi

task "Add the ondrej/php repository when php$php_version-fpm is not in apt"
if apt-cache show "php$php_version-fpm" >/dev/null 2>&1; then
  skip "available"
elif [[ $os_id != ubuntu ]]; then
  skip "not Ubuntu"
else
  changed
  if dry; then note "would add ppa:ondrej/php"; else
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -e /etc/apt/keyrings/ondrej-php.gpg ]]; then
      fp=$(gpg --batch --show-keys --with-colons "$ENGINE_DIR/files/ondrej-php.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
      [[ $fp == 14AA40EC0831756756D7F66C4F4EA0AAE5267A6C ]] || fail "Bad GPG fingerprint for ondrej/php: $fp"
      gpg --batch --yes --dearmor < "$ENGINE_DIR/files/ondrej-php.asc" > /etc/apt/keyrings/ondrej-php.gpg
      chmod 0644 /etc/apt/keyrings/ondrej-php.gpg
    fi
    put_template ondrej-php.list.tpl /etc/apt/sources.list.d/ondrej-ubuntu-php.list 0644 root root
    apt_update_if_old force
  fi
fi

task "Install PHP $php_version and its extensions"
php_pkgs=()
for e in fpm cli mysql mbstring xml curl zip gd bcmath intl redis soap sqlite3 dev; do php_pkgs+=("php$php_version-$e"); done
apt_install "${php_pkgs[@]}"

# Projects on mongodb/mongodb 1.x (e.g. jenssegers/mongodb) need ext-mongodb 1.x, but the
# php<V>-mongodb packages are 2.x. So the pinned version is built from its release tarball
# (pecl's channel downloads are unreliable) with this PHP version's phpize/php-config,
# and the 2.x package is removed so an apt upgrade cannot swap it back.
task "Remove the packaged php$php_version-mongodb (2.x) in favour of the pinned $mongodb_version"
if dpkg-query -W -f='${Status}' "php$php_version-mongodb" 2>/dev/null | grep -q 'install ok installed'; then
  changed
  if dry; then note "would remove php$php_version-mongodb"; else
    apt_get remove "php$php_version-mongodb"
  fi
fi

task "Build mongodb $mongodb_version for PHP $php_version from its release tarball"
mongodb_built=0
if [[ $("/usr/bin/php$php_version" -r 'echo phpversion("mongodb");' 2>/dev/null) == "$mongodb_version" ]]; then
  :
elif dry; then
  changed; note "would build mongodb $mongodb_version"
else
  (
    set -e
    v=$mongodb_version p=$php_version
    mkdir -p /var/cache/deployer && cd /var/cache/deployer
    if [[ ! -s mongodb-$v.tgz ]]; then
      curl -fsSL -o "mongodb-$v.tgz.part" "https://pecl.php.net/get/mongodb-$v.tgz" \
        || curl -fsSL -o "mongodb-$v.tgz.part" "https://github.com/mongodb/mongo-php-driver/releases/download/$v/mongodb-$v.tgz"
      mv "mongodb-$v.tgz.part" "mongodb-$v.tgz"
    fi
    rm -rf "build-mongodb-$p" && mkdir "build-mongodb-$p"
    tar -xzf "mongodb-$v.tgz" -C "build-mongodb-$p" --strip-components=1 "mongodb-$v"
    cd "build-mongodb-$p"
    "phpize$p" >/dev/null
    ./configure --with-php-config="/usr/bin/php-config$p" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install
    cd .. && rm -rf "build-mongodb-$p"
  )
  mongodb_built=1; changed
fi

task "Enable the mongodb extension for PHP $php_version CLI and FPM"
printf 'extension=mongodb.so\n' | put_content "/etc/php/$php_version/mods-available/mongodb.ini" 0644 root root
if ! dry; then
  phpenmod -v "$php_version" mongodb
  got=$("/usr/bin/php$php_version" -r 'echo phpversion("mongodb");' 2>/dev/null || true)
  [[ $got == "$mongodb_version" ]] || fail "PHP $php_version loads mongodb '${got:-none}', expected $mongodb_version"
  if ((mongodb_built)); then systemctl reload "php$php_version-fpm"; fi
fi

# Fail-safe: PHP-FPM is restarted by systemd when it crashes or is killed
task "Restart php$php_version-fpm automatically when it stops unexpectedly"
ensure_dir "/etc/systemd/system/php$php_version-fpm.service.d" 0755 root root
restart_label=PHP-FPM put_template systemd-restart.conf.tpl "/etc/systemd/system/php$php_version-fpm.service.d/deployer-restart.conf" 0644 root root
if ((PUT_CHANGED)) && ! dry; then systemctl daemon-reload; fi

# Zero downtime: on a reload (a site's pool added or changed) PHP-FPM lets running requests finish
# for up to 10 s; the default 0 kills them at once and the visitor gets a 502
task "Let running requests finish when php$php_version-fpm reloads"
if [[ -f /etc/php/$php_version/fpm/php-fpm.conf ]]; then
  line_in_file "/etc/php/$php_version/fpm/php-fpm.conf" '^;?[[:space:]]*process_control_timeout[[:space:]]*=' "process_control_timeout = 10s"
  if ((PUT_CHANGED)) && ! dry; then systemctl reload "php$php_version-fpm"; fi
else
  skip "php-fpm.conf not installed yet"
fi
