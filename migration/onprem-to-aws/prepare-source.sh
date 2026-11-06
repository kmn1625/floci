#!/usr/bin/env bash
# Open the source for replication. wal_level and listen_addresses need a restart, so this is the
# first outage of the migration, and it happens weeks before anyone thinks of cutover.
#   MIGRATOR_PASSWORD=... sudo -E bash prepare-source.sh
set -euo pipefail
: "${MIGRATOR_PASSWORD:?}"
CONF=/etc/postgresql/16/main/conf.d/90-migration.conf
HBA=/etc/postgresql/16/main/pg_hba.conf

cat >"$CONF" <<'PG'
listen_addresses = 'localhost,10.77.0.20'
wal_level = logical
PG

# The link arrives through the host's address on the lab switch. TLS only, one role, one database.
grep -q 'migrator' "$HBA" || cat >>"$HBA" <<'HBA'
hostssl shop migrator 10.77.0.1/32 scram-sha-256
hostssl replication migrator 10.77.0.1/32 scram-sha-256
HBA

sudo -u postgres psql -v ON_ERROR_STOP=1 -q shop <<SQL
do \$\$ begin
  if not exists (select from pg_roles where rolname = 'migrator') then
    create role migrator login replication password '$MIGRATOR_PASSWORD';
  end if;
end \$\$;
grant select on all tables in schema public to migrator;
SQL

start=$(date +%s.%N)
systemctl restart postgresql@16-main
until pg_isready -q -h 127.0.0.1; do sleep 0.1; done
end=$(date +%s.%N)
printf 'postgres restart took %.1f seconds\n' "$(echo "$end - $start" | bc)"
sudo -u postgres psql -Atc "show wal_level" -c "show listen_addresses"
