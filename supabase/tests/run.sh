#!/usr/bin/env bash
#
# Run the database tests against a throwaway local Postgres.
#
# This never touches your real Supabase project. It builds an empty
# database, fakes the few pieces Supabase normally provides, runs the
# real migration against it, and then checks that the privacy rules
# actually hold — that a stranger cannot read your home address, see
# your friends, or read a meetup they were not invited to.
#
# Usage:  ./supabase/tests/run.sh
#
set -euo pipefail

# macOS ships a locale that makes the postmaster go multithreaded during
# startup, which Postgres refuses to run under. Pinning C avoids it.
export LC_ALL=C
export LANG=C

PGBIN="/opt/homebrew/opt/postgresql@16/bin"
[ -d "$PGBIN" ] || { echo "Postgres 16 not found. brew install postgresql@16"; exit 1; }
export PATH="$PGBIN:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/wrv-pgtest"
PORT=55432

cleanup() {
  pg_ctl -D "$WORK/pgdata" stop -m immediate >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> starting a temporary Postgres on port $PORT"
initdb -D "$WORK/pgdata" -U postgres --locale=C -E UTF8 >/dev/null
pg_ctl -D "$WORK/pgdata" \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$WORK/pg.log" start >/dev/null
sleep 2

createdb -h 127.0.0.1 -p $PORT -U postgres wrv

echo "==> faking the Supabase-provided schemas"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -v ON_ERROR_STOP=1 \
  -f "$HERE/00_supabase_stub.sql" >/dev/null

echo "==> applying migrations"
for m in "$ROOT"/supabase/migrations/*.sql; do
  echo "    $(basename "$m")"
  psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -v ON_ERROR_STOP=1 -f "$m" 2>&1 \
    | grep -viE "NOTICE|skipping" || true
done

echo "==> loading fixtures"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -v ON_ERROR_STOP=1 \
  -f "$HERE/01_fixtures.sql" 2>&1 | grep -iE "PASS|FAIL" || true

echo "==> checking row level security"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -f "$HERE/02_rls.sql"

echo "==> checking friends"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -f "$HERE/03_friends.sql"

echo "==> checking ads"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -f "$HERE/04_ads.sql"

echo "==> checking rate limits and the geocode cache"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -f "$HERE/05_limits.sql"

echo "==> checking ad counting"
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -f "$HERE/06_ad_counting.sql"

echo
echo "==> re-applying migrations to prove they are safe to run twice"
for m in "$ROOT"/supabase/migrations/*.sql; do
  psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -q -v ON_ERROR_STOP=1 -f "$m" >/dev/null 2>&1
done
psql -h 127.0.0.1 -p $PORT -U postgres -d wrv -tAc \
  "select 'survived: '||(select count(*) from public.profiles)||' profiles, '
        ||(select count(*) from public.meetups)||' meetups, '
        ||(select count(*) from public.ads)||' ads';"

echo
echo "All done. The temporary database is thrown away now."
