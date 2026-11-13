server {
    listen 80;
{% if [[ $ipv6_ok == yes ]] %}
    listen [::]:80;
{% endif %}
    server_name  {{ site_names }};
    if ($block_ip) {
        return 444;
    }
{% if [[ $acme_in_vhost == yes ]] %}

    location ^~ /.well-known/acme-challenge/ {
        allow all;
        root {{ acme_webroot }};
        default_type text/plain;
    }
{% endif %}

    root {{ sites_root }}/{{ site_domain }}/public;
    index index.php index.html index.htm;

    deny 45.153.34.177;
    deny 185.177.72.52;
{% include site-vhost-body.tpl %}
}
{% if [[ $tls_mode != none ]] %}

server {
{% if [[ $docker == yes ]] %}
    listen 443 ssl;
{% if [[ $ipv6_ok == yes ]] %}
    listen [::]:443 ssl;
{% endif %}
    http2 on;
{% else %}
    listen 443 ssl http2;
{% if [[ $ipv6_ok == yes ]] %}
    listen [::]:443 ssl http2;
{% endif %}
{% endif %}
    server_name  {{ site_names }};
    if ($block_ip) {
        return 444;
    }

    root {{ sites_root }}/{{ site_domain }}/public;
    index index.php index.html index.htm;
    deny 185.177.72.52;
    ssl_certificate {{ tls_dir }}/{{ site_domain }}/certificate.crt;
    ssl_certificate_key {{ tls_dir }}/{{ site_domain }}/privatekey.key;
    ssl_prefer_server_ciphers on;

    deny 45.153.34.177;
{% include site-vhost-body.tpl %}
}
{% endif %}
