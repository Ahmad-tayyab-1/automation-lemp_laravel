[{{ site_id }}]
user = {{ linux_user }}
group = {{ site_group }}
listen = /run/php/php{{ php_version }}-fpm-{{ site_id }}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
{% include php-pool-pm.tpl %}
