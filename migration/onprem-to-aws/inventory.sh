#!/usr/bin/env bash
# What is on this server? Read-only. Prints JSON-free plain sections so a person can read it too.
# Run as root on the source server.
set -u

section() { printf '\n=== %s\n' "$1"; }

section host
hostnamectl 2>/dev/null | grep -E 'Static hostname|Operating System|Kernel'
free -m | sed -n 2p
df -h / | tail -1

section listening
ss -ltnpH | awk '{print $4, $6}'

section services
systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' \
  | grep -vE '^(systemd-|dbus|getty|serial-getty|ssh|snapd|unattended|polkit|networkd-dispatcher|rsyslog|multipathd|cron\.service|user@|ModemManager|udisks|qemu-guest|hv-|irqbalance|packagekit|fwupd)'

section unit-files
for u in $(systemctl list-unit-files --type=service --no-legend | awk '{print $1}'); do
  f=/etc/systemd/system/$u
  [ -f "$f" ] && { echo "--- $f"; grep -E '^(User|EnvironmentFile|WorkingDirectory|ExecStart)=' "$f"; }
done

section cron
ls /etc/cron.d 2>/dev/null | grep -v -E '^(e2scrub_all|sysstat|\.placeholder)$' | while read -r f; do
  echo "--- /etc/cron.d/$f"; grep -vE '^\s*(#|$)' "/etc/cron.d/$f" | cut -c1-140 | sed -E 's/PGPASSWORD=[^ ]+/PGPASSWORD=***/'
done
for u in $(cut -d: -f1 /etc/passwd); do
  c=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*(#|$)')
  [ -n "$c" ] && { echo "--- crontab of $u"; echo "$c"; }
done

section config-names-a-host
grep -rIlE '127\.0\.0\.1|localhost|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/shop /opt/shop/*.py /etc/nginx/sites-enabled /etc/cron.d 2>/dev/null

section app-data-on-disk
for d in /var/lib/shop/*; do printf '%s  ' "$d"; du -sh "$d" | cut -f1 | tr '\n' ' '; find "$d" -type f | wc -l; done

section postgres
sudo -u postgres psql -Atc "select version()"
sudo -u postgres psql -Atc "select name || '=' || setting from pg_settings where name in ('wal_level','max_replication_slots','max_wal_senders','listen_addresses','server_encoding','TimeZone')"
sudo -u postgres psql -Atc "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate"
sudo -u postgres psql -Atc "select extname || ' ' || extversion from pg_extension where extname <> 'plpgsql'" shop
sudo -u postgres psql -Atc "select 'role ' || rolname from pg_roles where rolname !~ '^pg_' and rolname <> 'postgres'"
echo '--- tables (estimated rows, primary key?)'
sudo -u postgres psql -At -F ' ' shop -c "
  select c.relname, c.reltuples::bigint, case when exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary) then 'pk' else 'NO-PK' end
  from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' and n.nspname = 'public' order by 1"
echo '--- sequences'
sudo -u postgres psql -At -F ' ' shop -c "select sequencename, last_value from pg_sequences where schemaname = 'public'"
echo '--- triggers, functions, large objects'
sudo -u postgres psql -At -F ' ' shop -c "select count(*) from pg_trigger where not tgisinternal" -c "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'" -c "select count(*) from pg_largeobject_metadata"
echo '--- connections by client'
sudo -u postgres psql -At -F ' ' -c "select coalesce(host(client_addr), 'local'), usename, count(*) from pg_stat_activity where datname = 'shop' group by 1, 2"
