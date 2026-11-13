user www-data;
worker_processes auto;
worker_cpu_affinity auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;
worker_rlimit_nofile 65536;


events {
        worker_connections 4096;
        multi_accept on;
	use epoll;
}

http {
	geo $block_ip {
		default 0;
		include /etc/nginx/snippets/blockips.conf;
	}
	geo $whitelist {
		default 0;
		# IPs that skip rate limits. Managed by deployer: ./deploy.sh --stack-config
		include /etc/nginx/snippets/whitelist_ips.conf;
	}
	# Empty key for whitelisted IPs → nginx skips limit_conn entirely
	map $whitelist $conn_limit_key {
		1       "";
		default $binary_remote_addr;
	}
	limit_conn_zone $conn_limit_key zone=conn_per_ip:20m;
	limit_conn_status 429;
	# Fast burst protection for GET — 1 req/sec sustained, burst 50 = matches 50/min daemon limit
	# POST bypasses this since key is empty
	map "$whitelist:$request_method" $get_rate_key {
		"0:GET"  $binary_remote_addr;   # non-whitelisted GET: apply rate limit
		default  "";                      # whitelisted (any) OR non-GET: skip
	}
	limit_req_zone $get_rate_key zone=get_burst:20m rate=1r/s;
	limit_req_status 429;


	map $status $is_error {
		429	1;
		444	1;
		default 0;
	}

	##
	# Basic Settings
	##

	sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout 15;
        types_hash_max_size 2048;
        server_tokens off;
        send_timeout 60s;
	large_client_header_buffers 4 32k;
        client_header_timeout 30s;
        client_body_timeout 60s;
        client_max_body_size 100m;
	client_body_buffer_size     128k;
	client_header_buffer_size   16k;

	server_names_hash_max_size 65536;
        server_names_hash_bucket_size 1024;
	
	open_file_cache             max=10000 inactive=30s;
        open_file_cache_valid       60s;
        open_file_cache_min_uses    2;
        open_file_cache_errors      on;
        include /etc/nginx/snippets/allowed_admin_ips.conf;
	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	##
	# SSL Settings
	##

	ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE
	ssl_prefer_server_ciphers on;
        ssl_ciphers                 ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_session_cache           shared:SSL:10m;
        ssl_session_timeout         1d;
        ssl_session_tickets         off;
        ssl_stapling                off;
        ssl_stapling_verify         off;

	##
	# Logging Settings
	##

#	access_log /var/log/nginx/access.log;

	##
	# Gzip Settings
	##

	gzip on;
        gzip_disable "msie6";

        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level 4;
        gzip_buffers 16 8k;
        gzip_http_version 1.1;
	gzip_min_length     256;
        gzip_types application/atom+xml application/javascript application/json    application/ld+json    application/manifest+json    application/vnd.geo+json    application/vnd.ms-fontobject    application/x-font-opentype    application/x-font-truetype    application/x-font-ttf    application/x-javascript    application/x-web-app-manifest+json    application/xhtml+xml    application/xml    application/xml+rss    image/bmp    font/eot    font/opentype    font/otf    image/svg+xml    image/vnd.microsoft.icon    image/x-win-bitmap    image/x-icon    text/cache-manifest    text/css    text/javascript    text/plain    text/vcard    text/vnd.rim.location.xloc    text/vtt    text/x-component    text/x-cross-domain-policy    text/xml;

#	fastcgi_cache_path /var/cache/nginx/fastcgi
#        levels=1:2
#        keys_zone=FCGI_CACHE:100m
#        inactive=60m
#        max_size=1g;
#        fastcgi_cache_key "$scheme$request_method$host$request_uri";
#        fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
#        fastcgi_cache_lock on;
#        fastcgi_cache_lock_timeout 5s;
#        fastcgi_ignore_headers Cache-Control Expires Set-Cookie;

        ##
        # FastCGI Global Timeouts
        ##
        fastcgi_connect_timeout     10s;
        fastcgi_send_timeout        60s;    # Was unlimited
        fastcgi_read_timeout        60s;    # Was unlimited — this was causing 3min hangs
        fastcgi_buffers             16 16k;
        fastcgi_buffer_size         32k;

	##
	# Virtual Host Configs
	##

#log settings


       log_format rl_debug '$remote_addr wl=$whitelist key=[$get_rate_key] conn=[$conn_limit_key] method=$request_method';
       log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$host" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
		    '$request_time ' '"$sent_http_session_id" "$sent_http_user_key"';

	access_log /var/log/nginx/rl-debug.log rl_debug;
	access_log /var/log/nginx/access.log main buffer=1k flush=100ms;
	access_log /var/log/nginx/ban.log main if=$is_error;


       # Real IP Settings for Cloudflare
	set_real_ip_from 103.21.244.0/22;
	set_real_ip_from 103.22.200.0/22;
	set_real_ip_from 103.31.4.0/22;
	set_real_ip_from 104.16.0.0/13;
	set_real_ip_from 104.24.0.0/14;
	set_real_ip_from 108.162.192.0/18;
	set_real_ip_from 131.0.72.0/22;
	set_real_ip_from 141.101.64.0/18;
	set_real_ip_from 162.158.0.0/15;
	set_real_ip_from 172.64.0.0/13;
	set_real_ip_from 173.245.48.0/20;
	set_real_ip_from 188.114.96.0/20;
	set_real_ip_from 190.93.240.0/20;
	set_real_ip_from 197.234.240.0/22;
	set_real_ip_from 198.41.128.0/17;
	set_real_ip_from 2400:cb00::/32;
	set_real_ip_from 2606:4700::/32;
	set_real_ip_from 2803:f800::/32;
	set_real_ip_from 2405:b500::/32;
	set_real_ip_from 2405:8100::/32;
	set_real_ip_from 2a06:98c0::/29;
	set_real_ip_from 2c0f:f248::/32;
	real_ip_header CF-Connecting-IP;

        include /etc/nginx/conf.d/*.conf;
        include /etc/nginx/sites-enabled/*;

server {

         listen 80 default_server;
          server_name _;
 
        location /nginx_status {
            stub_status;
	    allow 127.0.0.1;
            deny all;         # Deny all other access
	    access_log off;
            log_not_found off;
           }
	 location / {
        return 444;
    }    

    }

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    location /nginx_status {
            stub_status;
            allow 127.0.0.1;
            deny all;         # Deny all other access
            access_log off;
            log_not_found off;
           }
         location / {
        return 444;
    }

}

}
