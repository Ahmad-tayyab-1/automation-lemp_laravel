{# The locations of both server blocks (site-vhost.conf.tpl) #}

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)$ {
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable" always;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
{% if [[ $docker == yes ]] %}
        fastcgi_pass unix:{{ stack_socket_dir }}/{{ site_id }}.sock;
{% else %}
        fastcgi_pass unix:/run/php/php{{ php_version }}-fpm-{{ site_id }}.sock;
{% endif %}
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        allow 93.115.200.159;
        allow 93.115.200.158;
        allow 93.115.200.157;
        allow 93.115.200.156;
        allow 93.115.200.155;
        deny all;
    }

    location ^~ /admin {
        include /etc/nginx/snippets/allowed_admin_ips.conf;
        try_files $uri $uri/ /index.php?$query_string;
    }
{% for line in traffic_extra_nginx %}
    {{ line }}
{% endfor %}
