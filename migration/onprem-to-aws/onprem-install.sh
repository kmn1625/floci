#!/usr/bin/env bash
# Set up onprem1 the way a small business server tends to look: everything on one box, local
# PostgreSQL with default settings, files on disk, config in /etc, a cron job nobody remembers.
# The drill has to find and move all of it, so none of this is tidied up for the migration.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null || true
apt-get update -qq
apt-get install -y -qq postgresql nginx python3-venv >/dev/null

install -d -o www-data -g www-data /opt/shop /var/lib/shop /var/lib/shop/uploads /var/lib/shop/reports
cp /home/ubuntu/shop/app.py /home/ubuntu/shop/requirements.txt /opt/shop/
python3 -m venv /opt/shop/venv
/opt/shop/venv/bin/pip install -q -r /opt/shop/requirements.txt

sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<'SQL'
create role shop login password 'shop';
create database shop owner shop;
SQL
sudo -u postgres psql -v ON_ERROR_STOP=1 -q shop -c 'alter schema public owner to shop'
PGPASSWORD=shop psql -h 127.0.0.1 -U shop -d shop -v ON_ERROR_STOP=1 -q -f /home/ubuntu/shop/schema.sql

install -d -m 750 -o root -g www-data /etc/shop
cat >/etc/shop/shop.env <<'ENV'
DATABASE_URL=postgresql://shop:shop@127.0.0.1:5432/shop
STORAGE=disk
UPLOAD_DIR=/var/lib/shop/uploads
SITE=onprem
ENV
chmod 640 /etc/shop/shop.env

cat >/etc/systemd/system/shop.service <<'UNIT'
[Unit]
Description=shop
After=network.target postgresql.service

[Service]
User=www-data
EnvironmentFile=/etc/shop/shop.env
WorkingDirectory=/opt/shop
ExecStart=/opt/shop/venv/bin/gunicorn -w 3 -b 127.0.0.1:8000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/nginx/sites-available/shop <<'NGINX'
server {
  listen 80 default_server;
  client_max_body_size 3m;
  location / {
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Host $host;
  }
}
NGINX
ln -sf /etc/nginx/sites-available/shop /etc/nginx/sites-enabled/default

# The job nobody remembers: a nightly report on local disk and a purge of old audit rows.
cat >/etc/cron.d/shop-nightly <<'CRON'
15 2 * * * www-data PGPASSWORD=shop psql -h 127.0.0.1 -U shop -d shop -Atc "select current_date, count(*), sum(total_cents) from orders" >> /var/lib/shop/reports/daily.csv
30 2 * * * www-data PGPASSWORD=shop psql -h 127.0.0.1 -U shop -d shop -c "delete from audit_log where at < now() - interval '30 days'"
CRON

systemctl daemon-reload
systemctl enable --now shop
systemctl restart nginx
sleep 3
curl -fsS http://127.0.0.1/ready
echo
for i in $(seq 1 20); do
  head -c $((2000 + i * 7000)) /dev/urandom | curl -fsS -X POST --data-binary @- "http://127.0.0.1/uploads?name=seed-$i.bin" -o /dev/null
done
curl -fsS http://127.0.0.1/verify
echo
