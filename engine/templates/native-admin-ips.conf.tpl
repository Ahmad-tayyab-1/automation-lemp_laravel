# Who can open /admin. Edit, then: nginx -t && systemctl reload nginx
allow 93.115.200.159;
allow 93.115.200.158;
allow 93.115.200.157;
allow 93.115.200.156;
allow 93.115.200.155;
allow 127.0.0.1;
allow ::1;
deny all;
