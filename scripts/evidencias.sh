#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Genera evidence/NN-*.txt con la salida REAL de la terminal, incidente por incidente.
#
#   ./scripts/evidencias.sh           ANTES (kit original) y DESPUES (repositorio corregido)
#   ./scripts/evidencias.sh despues   solo el estado corregido
#
# ANTES levanta el kit tal como llego (el primer commit del repositorio, o el commit que se
# indique en KIT_REF) en una copia aparte, .kit-original/ (ignorada por git), para mostrar
# cada falla. DESPUES usa este repositorio desde cero con ./reset.sh.
# Necesita docker compose, git, curl y python3 (Linux, por ejemplo GitHub Codespaces).
# Tarda unos 5 minutos. Ningun comando imprime contrasenas.
# ---------------------------------------------------------------------------
set -uo pipefail   # sin -e: varios comandos fallan a proposito para mostrar el sintoma
cd "$(dirname "$0")/.."

RAIZ=$(pwd)
EVID="$RAIZ/evidence"
KIT_DIR="$RAIZ/.kit-original"
API="http://localhost:${API_PORT:-8081}"
MUESTRA="3756530718 88121168 6015866271"
MODO="${1:-todo}"
PSQL="psql -U cierre -d cierre"

ARCHIVOS=("" 01-worker.txt 02-api-base.txt 03-entrada-cierre.txt 04-top-error.txt 05-calidad-datos.txt
          06-consulta-afiliado.txt 07-fechas.txt 08-cruce-oriente.txt 09-totales.txt 10-repetibilidad.txt)
TITULOS=("" "cierre-worker en Exited (1)" "La API no conecta a la base" "El script de cierre no lee su archivo de entrada"
         "Miles de lineas de log: error mas frecuente" "Duplicados, sin empresa, huerfanos y codigos invalidos"
         "La consulta del afiliado responde 500" "Fechas en formatos que el cierre no entiende"
         "Extracto de Caja Oriente con otras columnas" "Totales que no cuadran" "El cierre solo funciona una vez")

# ev N "comando": agrega al archivo del incidente N el comando, su salida y su codigo de salida.
ev() {
    local n="$1"; shift
    {
        printf '$ %s\n' "$*"
        bash -c "$*" 2>&1
        printf '[codigo de salida: %s]\n\n' "$?"
    } >> "$EVID/${ARCHIVOS[$n]}"
}

seccion() {
    local n="$1"; shift
    printf '==== %s ====\n\n' "$*" >> "$EVID/${ARCHIVOS[$n]}"
}

nota() {
    local n="$1"; shift
    printf '# %s\n\n' "$*" >> "$EVID/${ARCHIVOS[$n]}"
}

esperar_base() {   # esperar_base [argumentos de docker compose]
    local id
    for _ in $(seq 1 60); do
        id=$(docker compose "$@" ps -q cierre-db 2>/dev/null)
        if [ -n "$id" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null)" = healthy ]; then
            return 0
        fi
        sleep 2
    done
    echo "AVISO: la base no quedo healthy a tiempo" >&2
    return 1
}

esperar_api() {
    for _ in $(seq 1 45); do
        curl -fsS -o /dev/null "$API/health" 2>/dev/null && return 0
        sleep 2
    done
    echo "AVISO: la API no respondio /health a tiempo" >&2
    return 1
}

iniciar_archivos() {
    mkdir -p "$EVID"
    local n
    for n in $(seq 1 10); do
        {
            printf 'Incidente %s - %s\n' "$n" "${TITULOS[$n]}"
            printf 'Salida real de terminal generada por scripts/evidencias.sh\n'
            printf 'Fecha: %s | %s | %s | %s\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$(uname -sr)" \
                "$(docker --version 2>/dev/null)" "$(docker compose version 2>/dev/null)"
        } > "$EVID/${ARCHIVOS[$n]}"
    done
}

# --------------------------------------------------------------------------- ANTES

fase_antes() {
    # Un clon superficial no trae el primer commit (el kit original): se completa el historial.
    if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        git fetch --unshallow --quiet || true
    fi
    local ref="${KIT_REF:-$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -n 1)}"
    if [ -z "$ref" ] || ! git show "$ref:.env.example" 2>/dev/null | grep -q 'cierre-database'; then
        echo "AVISO: no encuentro el kit original en el historial (use KIT_REF=<commit>); se omite ANTES" >&2
        local n
        for n in $(seq 1 10); do nota "$n" "ANTES: no se pudo reproducir el kit original (falta el commit de importacion)"; done
        return 0
    fi
    echo ">> ANTES: kit original (commit ${ref:0:8}) en .kit-original/"
    docker compose down -v --remove-orphans >/dev/null 2>&1   # libera el puerto de la API
    rm -rf "$KIT_DIR"
    git worktree prune
    git worktree add --detach "$KIT_DIR" "$ref" >/dev/null 2>&1 || { echo "ERROR: git worktree add fallo" >&2; return 1; }

    cd "$KIT_DIR" || return 1
    cp .env.example .env
    local DC="docker compose -p kit-original"
    $DC up -d --build > /tmp/kit-original-build.log 2>&1
    esperar_base -p kit-original
    sleep 10   # tiempo para que el worker intente arrancar y la API quede escuchando

    local n
    for n in 1 2 3 4 5 7 8; do seccion "$n" "ANTES: kit original (commit ${ref:0:8}), cp .env.example .env y docker compose up -d"; done

    ev 1 "$DC ps -a"
    ev 1 "$DC logs cierre-worker | tail -n 5"
    ev 1 "grep -n WORKER_INTERVAL_SECONDS .env.example"
    ev 1 "grep -c 'CIE-1107' logs/worker.log"

    ev 2 "curl -s -w '\nHTTP %{http_code}\n' $API/afiliados/1098765432"
    ev 2 "$DC logs cierre-api | grep 'CIE-2210' | tail -n 2"
    ev 2 "grep -n DATABASE_HOST .env.example"
    ev 2 "$DC config --services"

    ev 3 "git ls-files -s run.sh scripts/cierre.sh"
    ev 3 "ls -l run.sh scripts/cierre.sh"
    ev 3 "./run.sh"
    ev 3 "grep -n '^ENTRADA=' scripts/cierre.sh"
    rm -rf output
    ev 3 "bash scripts/cierre.sh"
    ev 3 "find . -name 'AFI_MAE.csv' -not -path './.git/*'"

    ev 4 "wc -l logs/*.log"
    ev 4 "grep -c ERROR logs/api.log logs/worker.log logs/database.log"
    ev 4 "ls output/top_error.txt"

    ev 5 "$DC exec -T cierre-db $PSQL -c \"SELECT count(*) AS registros, count(DISTINCT nro_doc) AS documentos FROM afi_mae\""
    ev 5 "$DC exec -T cierre-db $PSQL -c \"SELECT nro_doc, count(*) FROM afi_mae GROUP BY nro_doc HAVING count(*) > 1 ORDER BY nro_doc LIMIT 5\""
    ev 5 "$DC exec -T cierre-db $PSQL -c \"SELECT est_afi, count(*) FROM afi_mae GROUP BY est_afi ORDER BY est_afi\""
    ev 5 "$DC exec -T cierre-db $PSQL -c \"SELECT count(*) AS activos_sin_empresa FROM afi_mae a LEFT JOIN empresa e ON e.cod_emp = a.cod_emp WHERE a.est_afi = 'A' AND e.cod_emp IS NULL\""
    ev 5 "$DC exec -T cierre-db $PSQL -c \"SELECT count(*) AS beneficiarios_huerfanos FROM afi_ben b WHERE NOT EXISTS (SELECT 1 FROM afi_mae a WHERE a.nro_doc = b.nro_doc_afi)\""

    ev 7 "grep -c 'CIE-3301' logs/worker.log"
    ev 7 "awk -F, 'NR > 1 && \$9 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\$/ { print \$9 }' data/AFI_MAE.csv | sed -E 's/[0-9]/9/g' | sort | uniq -c | sort -rn"
    ev 7 "awk -F, 'NR > 1 && \$9 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\$/ { print \$1 \",\" \$9 }' data/AFI_MAE.csv | head -n 8"

    ev 8 "head -n 3 data/extracto_caja_oriente.csv"
    ev 8 "head -n 3 data/AFI_MAE.csv"
    ev 8 "grep -n 'TODO' scripts/cierre.sh"

    seccion 6 "ANTES: kit original (commit ${ref:0:8}) con DATABASE_HOST ya corregido en .env (solo el arreglo del incidente 2)"
    ev 6 "sed -i 's/^DATABASE_HOST=.*/DATABASE_HOST=cierre-db/' .env && grep -n '^DATABASE_HOST=' .env"
    $DC up -d --no-deps --force-recreate cierre-api >> /tmp/kit-original-build.log 2>&1
    esperar_api
    local d
    for d in $MUESTRA; do
        ev 6 "curl -s -w '\nHTTP %{http_code}\n' $API/afiliados/$d"
    done
    ev 6 "$DC logs cierre-api | grep -A 14 'CIE-5003' | tail -n 16"
    ev 6 "$DC exec -T cierre-db $PSQL -c \"SELECT nro_doc, nom1, nom2, nom2 IS NULL AS nom2_es_null, ape1, ape2 FROM afi_mae WHERE nro_doc IN ('3756530718', '88121168', '6015866271')\""

    seccion 10 "ANTES: script heredado del kit (commit ${ref:0:8}) con ENTRADA=data (solo el arreglo de ruta del incidente 3), ejecutado dos veces"
    rm -rf output
    ev 10 "sed -i 's#^ENTRADA=.*#ENTRADA=data#' scripts/cierre.sh && grep -n '^ENTRADA=' scripts/cierre.sh"
    ev 10 "bash scripts/cierre.sh"
    ev 10 "ls data/ data/procesados/"
    ev 10 "bash scripts/cierre.sh"
    ev 10 "git status --short data/"

    seccion 9 "ANTES: totales que dejo la primera ejecucion del script heredado"
    ev 9 "cat output/totales.txt"
    ev 9 "cat control/hoja_control.csv"

    $DC down -v --remove-orphans >> /tmp/kit-original-build.log 2>&1
    cd "$RAIZ" || exit 1
    git worktree remove --force "$KIT_DIR" >/dev/null 2>&1 || rm -rf "$KIT_DIR"
    git worktree prune
}

# --------------------------------------------------------------------------- DESPUES

fase_despues() {
    cd "$RAIZ" || exit 1
    echo ">> DESPUES: repositorio corregido desde cero (./reset.sh)"
    if [ -f .env ] && grep -qE '^DATABASE_HOST=cierre-database|^WORKER_INTERVAL_SECONDS=.*s$' .env; then
        echo "   .env tenia los valores rotos del kit; se reemplaza por .env.example"
        cp .env.example .env
    fi
    ./reset.sh > /tmp/reset-despues.log 2>&1
    esperar_base
    esperar_api
    sleep 5

    local n
    for n in $(seq 1 10); do seccion "$n" "DESPUES: repositorio corregido, ./reset.sh (docker compose down -v + up -d --build)"; done

    ev 1 "grep -n WORKER_INTERVAL_SECONDS .env.example docker-compose.yml"
    ev 1 "docker compose ps"
    ev 1 "docker compose logs cierre-worker | tail -n 3"
    nota 1 "35 segundos despues (mas de un intervalo del worker):"
    sleep 35
    ev 1 "docker compose ps"
    ev 1 "docker inspect -f '{{.Name}} estado={{.State.Status}} reinicios={{.RestartCount}}' \$(docker compose ps -q)"

    ev 2 "grep -n DATABASE_HOST .env.example docker-compose.yml"
    ev 2 "docker compose exec -T cierre-api python -c \"import os; print('DATABASE_HOST =', os.environ['DATABASE_HOST'])\""
    ev 2 "curl -s -w '\nHTTP %{http_code}\n' $API/afiliados/1098765432"
    ev 2 "docker compose logs cierre-api | tail -n 3"

    ev 3 "chmod +x run.sh reset.sh validator scripts/*.sh && ls -l run.sh reset.sh validator scripts/"
    ev 3 "git ls-files -s run.sh reset.sh validator scripts/"
    ev 3 "grep -n 'ENTRADA=' scripts/cierre.sh"
    ev 3 "./run.sh"
    ev 3 "ls -l output/"

    ev 4 "grep -hE '(^|[^A-Za-z])ERROR([^A-Za-z]|\$)' logs/*.log | grep -oE 'CIE-[0-9]{4}' | sort | uniq -c | sort -k1,1nr"
    ev 4 "grep -c 'CIE-4012' logs/api.log logs/worker.log logs/database.log"
    ev 4 "grep -ohE 'W-[0-9]+' logs/*.log | sort | uniq -c"
    ev 4 "cat output/top_error.txt"

    ev 5 "docker compose exec -T cierre-db $PSQL -c \"SELECT count(*) AS registros, count(DISTINCT nro_doc) AS documentos FROM afi_mae\""
    ev 5 "docker compose exec -T cierre-db $PSQL -c \"SELECT tipo, count(*) FROM correcciones GROUP BY tipo ORDER BY tipo\""
    ev 5 "docker compose exec -T cierre-db $PSQL -c \"SELECT tipo, count(*) FROM pendientes_calidad GROUP BY tipo ORDER BY tipo\""
    ev 5 "awk -F, 'NR > 1 { visto[\$1]++ } END { for (d in visto) if (visto[d] > 1) n++; print n \" documentos repetidos en data/AFI_MAE.csv\" }' data/AFI_MAE.csv"
    ev 5 "cut -d, -f2 output/excepciones.csv | sort | uniq -c"
    ev 5 "grep -E ',(DUPLICADO|SIN_EMPRESA|BENEFICIARIO_HUERFANO|CODIGO_INVALIDO),' output/excepciones.csv | head -n 8"
    ev 5 "./scripts/corregir_base.sh"

    local d
    for d in 1098765432 $MUESTRA 0000000001; do
        ev 6 "curl -s -w '\nHTTP %{http_code}\n' $API/afiliados/$d"
    done
    ev 6 "docker compose logs cierre-api | grep 'CIE-5003' | wc -l"
    ev 6 "docker compose exec -T cierre-db $PSQL -c \"SELECT nro_doc, nom1, nom2 IS NULL AS nom2_es_null, ape1, ape2, est_afi FROM afi_mae WHERE nro_doc IN ('3756530718', '88121168', '6015866271')\""

    ev 7 "grep FECHA_INVALIDA output/excepciones.csv"
    ev 7 "docker compose exec -T cierre-db $PSQL -c \"SELECT documento, valor_anterior, valor_nuevo FROM correcciones WHERE tipo = 'FECHA_NORMALIZADA' ORDER BY id\""
    ev 7 "./run.sh | grep -i 'fechas'"
    ev 7 "awk -F, 'NR == FNR { if (\$2 == \"FECHA_INVALIDA\") f[\$1] = 1; next } FNR > 1 && (\$1 in f) && !(\$1 in visto) { visto[\$1] = 1; e[\$7]++ } END { for (k in e) print \"EST_AFI=\" k \": \" e[k] \" afiliados con FECHA_INVALIDA (siguen contados en los totales)\" }' output/excepciones.csv data/AFI_MAE.csv"
    ev 7 "grep -c 'FECHA_INVALIDA' output/excepciones.csv && grep total_afiliados output/totales.txt"

    ev 8 "head -n 3 data/extracto_caja_oriente.csv"
    ev 8 "sed -n '2,4p' data/extracto_caja_oriente.csv | awk -F';' '{ d = \$1; sub(/^0+/, \"\", d); print \$1 \" -> \" d \" (\" \$3 \")\" }'"
    ev 8 "grep -c 'CRUCE_NO_COINCIDE' output/excepciones.csv"
    ev 8 "grep 'CRUCE_NO_COINCIDE' output/excepciones.csv | head -n 8"
    ev 8 "head -n 1 output/afiliados_activos.csv"
    ev 8 "sed -n '2,4p' output/afiliados_activos.csv"

    ev 9 "cat output/totales.txt"
    ev 9 "cat control/hoja_control.csv"
    ev 9 "for k in total_afiliados activos inactivos; do printf '%-16s cierre=%-6s control=%s\n' \$k \$(grep \"^\$k=\" output/totales.txt | cut -d= -f2) \$(grep \"^\$k,\" control/hoja_control.csv | cut -d, -f2); done"
    ev 9 "tail -n +2 output/excepciones.csv | wc -l"

    ev 10 "./run.sh > /dev/null && sha256sum output/* | tee /tmp/ejecucion1.sha"
    ev 10 "./run.sh > /dev/null && sha256sum output/* | tee /tmp/ejecucion2.sha"
    ev 10 "diff /tmp/ejecucion1.sha /tmp/ejecucion2.sha && echo 'IDENTICAS: dos ejecuciones seguidas'"
    ev 10 "./reset.sh 2>&1 | tail -n 6"
    esperar_base
    ev 10 "./run.sh > /dev/null && sha256sum output/* | tee /tmp/ejecucion3.sha"
    ev 10 "diff /tmp/ejecucion1.sha /tmp/ejecucion3.sha && echo 'IDENTICAS: tambien despues de ./reset.sh'"
    ev 10 "git status --short data/ && echo 'data/ sin cambios'"
}

# --------------------------------------------------------------------------- principal

for herramienta in docker git curl python3; do
    command -v "$herramienta" >/dev/null 2>&1 || { echo "ERROR: falta $herramienta" >&2; exit 1; }
done

iniciar_archivos
if [ "$MODO" != "despues" ]; then
    fase_antes
fi
fase_despues

echo ">> Validador oficial del kit (pruebas publicas)"
esperar_api
./validator check > "$EVID/00-validator-check.txt" 2>&1
cat "$EVID/00-validator-check.txt"

echo
echo "Evidencias generadas:"
ls -l "$EVID"
