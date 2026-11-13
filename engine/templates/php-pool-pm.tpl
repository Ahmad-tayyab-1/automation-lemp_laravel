{# Process manager settings from traffic.json (the site's traffic level), shared by both pool files #}
pm = {{ traffic_pm }}
pm.max_children = {{ traffic_max_children }}
{% if [[ $traffic_pm == ondemand ]] %}
{% if [[ -n $traffic_idle_timeout ]] %}
pm.process_idle_timeout = {{ traffic_idle_timeout }}
{% endif %}
{% elif [[ $traffic_pm == dynamic ]] %}
pm.start_servers = {{ traffic_start_servers }}
pm.min_spare_servers = {{ traffic_min_spare }}
pm.max_spare_servers = {{ traffic_max_spare }}
{% endif %}
{% if [[ -n $traffic_max_requests ]] %}
pm.max_requests = {{ traffic_max_requests }}
{% endif %}
