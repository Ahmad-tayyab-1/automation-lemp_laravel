# managed by deployer - change with: ./deploy.sh --stack-config
# Included at http level in nginx.conf, so it applies to EVERY site on this server.
{% if (( ${#stack_admin_ips[@]} == 0 )) %}
# Public: no IP restriction.
{% else %}
# Staging lock: only these IPs can open the sites.
{% for ip in stack_admin_ips %}
allow {{ ip }};
{% endfor %}

# This server itself (deploy health check, cron, monitoring)
allow 127.0.0.1;
allow ::1;

deny all;
{% endif %}
