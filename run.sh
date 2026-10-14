#!/usr/bin/env bash
# Punto de entrada del cierre mensual. El validador ejecuta este archivo.
# Se puede correr todas las veces que se quiera: no modifica data/ y reescribe output/ completo.
set -euo pipefail
cd "$(dirname "$0")"
# Con "bash" el cierre corre aunque una copia del repositorio pierda el permiso de ejecucion.
bash ./scripts/cierre.sh "$@"
