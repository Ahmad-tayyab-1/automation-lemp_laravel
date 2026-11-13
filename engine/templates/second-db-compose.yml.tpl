# managed by deployer: the second database server, next to the native {{ second_db_native }} on 3306.
# {{ second_db_label }} on 127.0.0.1:{{ second_db_port }}, data in {{ second_db_data }}.
#   root password: /etc/deployer/second_db_root_password
#   client:        mysql -h 127.0.0.1 -P {{ second_db_port }} -u root -p
services:
  db:
    image: {{ second_db_image }}
    container_name: {{ second_db_container }}
    restart: always
    ports:
      - "127.0.0.1:{{ second_db_port }}:3306"
    environment:
{% if [[ $second_db_kind == mariadb ]] %}
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/root_password
{% else %}
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/root_password
{% endif %}
    volumes:
      - {{ second_db_data }}:/var/lib/mysql
      - /etc/deployer/second_db_root_password:/run/secrets/root_password:ro
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
