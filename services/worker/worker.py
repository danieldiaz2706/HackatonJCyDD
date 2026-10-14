"""cierre-worker: concilia periódicamente el conteo de afiliados del cierre."""

import os
import re
import signal
import sys
import time
from datetime import datetime, timezone

import psycopg2

INTERVALO_POR_DEFECTO = 30


def log(level, message):
    stamp = datetime.now(timezone.utc).strftime("[%Y-%m-%dT%H:%M:%SZ]")
    print("{0} [{1}] {2}".format(stamp, level, message), flush=True)


def load_interval():
    """Segundos entre conciliaciones. Acepta "30" y también "30s".

    Antes un valor como "30s" hacía int() fallar y el worker terminaba con Exited (1).
    Ahora un valor inválido se reporta con CIE-1107 y se usa el intervalo por defecto,
    para que el servicio siga arriba.
    """
    raw = os.environ.get("WORKER_INTERVAL_SECONDS", "")
    match = re.match(r"^\s*(\d+)\s*s?\s*$", raw)
    if match and int(match.group(1)) > 0:
        return int(match.group(1))
    log("ERROR", "codigo=CIE-1107 WORKER_INTERVAL_SECONDS debe ser un entero de segundos; valor recibido: '{0}'; se usa {1}".format(
        raw, INTERVALO_POR_DEFECTO))
    return INTERVALO_POR_DEFECTO


def reconcile():
    conn = psycopg2.connect(
        host=os.environ.get("DATABASE_HOST", "localhost"),
        port=int(os.environ.get("DATABASE_PORT", "5432")),
        dbname=os.environ.get("DATABASE_NAME", "cierre"),
        user=os.environ.get("DATABASE_USER", "cierre"),
        password=os.environ.get("DATABASE_PASSWORD", ""),
        connect_timeout=3,
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*), count(DISTINCT nro_doc) FROM afi_mae")
            total, distinct = cur.fetchone()
    finally:
        conn.close()
    log("INFO", "conciliacion registros={0} documentos_distintos={1}".format(total, distinct))


def stop(signum, frame):
    # Docker envía SIGTERM al detener el contenedor; sin este manejador el proceso 1 lo ignora
    # y docker compose down tiene que esperar 10 segundos para matarlo.
    log("INFO", "cierre-worker detenido (senal {0})".format(signum))
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    interval = load_interval()
    log("INFO", "cierre-worker iniciado; intervalo={0}s".format(interval))
    while True:
        try:
            reconcile()
        except psycopg2.OperationalError as exc:
            log("ERROR", "codigo=CIE-2210 sin conexión a la base: {0}".format(str(exc).strip().splitlines()[0]))
        except Exception as exc:  # un error inesperado no debe tumbar el servicio
            log("ERROR", "codigo=CIE-5003 error inesperado en la conciliacion: {0}".format(exc))
        time.sleep(interval)


if __name__ == "__main__":
    main()
