{# The keys the deployer sets in the site's .env on every deploy, one KEY=value per line.
   steps/env.sh puts each one in .env: the last "KEY=" line there is replaced, or the key is appended.
   Values are written quoted ("..."), with \ " and $ escaped. Keys from sites.json "env_extra" come after
   these and win. To manage another key for every site, add it here. #}
APP_ENV={{ deploy_env }}
APP_DEBUG={{ app_debug }}
APP_URL={{ app_url }}
{# Laravel 11+ ships DB_CONNECTION=sqlite; the deployer always provides MySQL/MariaDB (env_extra can override) #}
DB_CONNECTION={{ env_db_connection }}
DB_HOST={{ env_db_host }}
DB_PORT={{ env_db_port }}
DB_DATABASE={{ env_db_name }}
DB_USERNAME={{ env_db_user }}
{% if [[ $keep_db_password != true ]] %}
DB_PASSWORD={{ active_db_password }}
{% endif %}
REDIS_HOST={{ redis_host }}
REDIS_PASSWORD={{ redis_env_password }}
REDIS_DB={{ site_redis_db }}
REDIS_CACHE_DB={{ site_redis_cache_db }}
REDIS_PREFIX={{ redis_prefix }}
