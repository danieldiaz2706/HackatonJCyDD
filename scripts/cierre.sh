#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cierre mensual de afiliados activos (script heredado de Operaciones, reparado).
#
# Cambios frente al script de 2019:
#   - Lee la entrada de data/ del repositorio (antes /opt/cierre/entrada, que no existe).
#   - Ya no mueve AFI_MAE.csv a procesados/: la entrada no se destruye y el cierre es repetible.
#   - output/ se crea con mkdir -p y cada archivo se reescribe completo (antes se agregaba con >>).
#   - Las reglas del cierre (empresa, beneficiarios, aportes, excepciones, fechas y cruce con
#     Caja Oriente) estan en scripts/cierre.py; aqui se calcula ademas output/top_error.txt.
#
# Variables opcionales: CIERRE_ENTRADA, CIERRE_SALIDA, CIERRE_LOGS, CIERRE_CONTROL, PYTHON.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

ENTRADA="${CIERRE_ENTRADA:-data}"
SALIDA="${CIERRE_SALIDA:-output}"
LOGS="${CIERRE_LOGS:-logs}"
CONTROL="${CIERRE_CONTROL:-control/hoja_control.csv}"

# python3 en Linux; en Git Bash (Windows) a veces solo existe "python".
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for candidato in python3 python; do
        if command -v "$candidato" >/dev/null 2>&1 \
            && "$candidato" -c 'import sys; sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1; then
            PYTHON="$candidato"
            break
        fi
    done
fi
if [ -z "$PYTHON" ]; then
    echo "ERROR: se necesita Python 3.6 o superior (python3)" >&2
    exit 1
fi

for archivo in AFI_MAE.csv AFI_BEN.csv APORTES.csv EMPRESA.csv extracto_caja_oriente.csv; do
    if [ ! -r "$ENTRADA/$archivo" ]; then
        echo "ERROR: no se puede leer $ENTRADA/$archivo (revise la ruta y los permisos)" >&2
        exit 1
    fi
done
mkdir -p "$SALIDA"

echo ">> Cierre de afiliados desde $ENTRADA/"
"$PYTHON" scripts/cierre.py --entrada "$ENTRADA" --salida "$SALIDA" --control "$CONTROL"

echo ">> Error mas frecuente en $LOGS/"
# Solo cuentan las lineas de nivel ERROR con codigo CIE-####; los avisos W-### no son errores.
# Si hubiera empate gana el codigo menor, para que el resultado sea siempre el mismo.
TOP=$(grep -hE '(^|[^A-Za-z])ERROR([^A-Za-z]|$)' "$LOGS"/*.log 2>/dev/null \
    | grep -oE 'CIE-[0-9]{4}' \
    | LC_ALL=C sort | uniq -c \
    | LC_ALL=C sort -k1,1nr -k2,2 \
    | awk 'NR == 1 { print $2, $1 }') || TOP=""
if [ -z "$TOP" ]; then
    echo "AVISO: no se encontraron errores CIE-#### en $LOGS/" >&2
    TOP="NINGUNO 0"
fi
read -r CODIGO OCURRENCIAS <<< "$TOP"
printf 'codigo_error=%s\nocurrencias=%s\n' "$CODIGO" "$OCURRENCIAS" > "$SALIDA/.top_error.tmp"
mv -f "$SALIDA/.top_error.tmp" "$SALIDA/top_error.txt"
echo "codigo_error=$CODIGO ocurrencias=$OCURRENCIAS"

echo ">> Archivos generados en $SALIDA/"
wc -l "$SALIDA/afiliados_activos.csv" "$SALIDA/excepciones.csv" "$SALIDA/totales.txt" "$SALIDA/top_error.txt"
echo "Cierre terminado"
