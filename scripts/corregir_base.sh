#!/usr/bin/env bash
# Vuelve a aplicar db/init/03_correcciones.sql sobre la base que ya está corriendo.
# Es idempotente: si la base ya estaba corregida no cambia nada.
# (Una base nueva, por ejemplo después de ./reset.sh, ya se crea corregida.)
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL='psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

echo ">> Aplicando db/init/03_correcciones.sql"
docker compose exec -T cierre-db sh -c "$PSQL -q -f /docker-entrypoint-initdb.d/03_correcciones.sql"

echo ">> Correcciones registradas"
docker compose exec -T cierre-db sh -c "$PSQL -c \"SELECT tipo, count(*) FROM correcciones GROUP BY tipo ORDER BY tipo\""

echo ">> Pendientes que reporta el cierre en excepciones.csv"
docker compose exec -T cierre-db sh -c "$PSQL -c \"SELECT tipo, count(*) FROM pendientes_calidad GROUP BY tipo ORDER BY tipo\""
