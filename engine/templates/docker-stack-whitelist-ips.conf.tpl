# managed by deployer - change with: ./deploy.sh --stack-config
# Entries of "geo $whitelist" in nginx.conf: these IPs skip the rate-limit zones.
{% for ip in stack_whitelist_ips %}
{{ ip }} 1;
{% endfor %}
