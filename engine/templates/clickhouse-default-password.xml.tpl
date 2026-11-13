<!-- managed by deployer: password of the "default" user (plain text in /etc/deployer/clickhouse_password) -->
<clickhouse>
    <users>
        <default>
            <password remove="1"/>
            <password_sha256_hex>{{ clickhouse_password_sha256 }}</password_sha256_hex>
        </default>
    </users>
</clickhouse>
