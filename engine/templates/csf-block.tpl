# BEGIN deployer (managed by deployer: deploy.sh firewall rewrites the lines up to END deployer)
# {{ fw_block_title }}
{% for l in fw_block_lines %}
{{ l }}
{% endfor %}
# END deployer
