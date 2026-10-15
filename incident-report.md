# Informe de incidentes — Terminal Rescue

Equipo: Daniel Fernando Díaz Torres y Juan Camilo Martínez.

Cada evidencia es la salida real de la terminal, generada con `./scripts/evidencias.sh`: primero con el kit tal como llegó (sección ANTES) y luego con este repositorio levantado desde cero con `./reset.sh` (sección DESPUES).

## Incidente 1
- **Síntoma:** `docker compose ps -a` muestra `cierre-worker` en `Exited (1)` segundos después de levantar el entorno, mientras `cierre-db` y `cierre-api` siguen arriba.
- **Diagnóstico:** el log del worker dice `codigo=CIE-1107 WORKER_INTERVAL_SECONDS debe ser un entero de segundos; valor recibido: '30s'`. En `.env.example` el valor era `30s` y `worker.py` hacía `int()` sobre la variable, que no acepta la unidad, y terminaba con `sys.exit(1)`. Con `grep -c` vimos que `logs/worker.log` ya traía 158 líneas con CIE-1107: la falla venía de antes.
- **Comandos:** `docker compose ps -a`, `docker compose logs cierre-worker | tail -n 5`, `grep -n WORKER_INTERVAL_SECONDS .env.example`, `grep -c CIE-1107 logs/worker.log`, `docker inspect -f '{{.RestartCount}}' $(docker compose ps -q)`
- **Solución:** `WORKER_INTERVAL_SECONDS=30` en `.env.example` (y en `.env`). Además `worker.py` acepta `30` o `30s`; si el valor es inválido registra CIE-1107 y usa 30 en lugar de terminar. Un error inesperado en la conciliación ya no tumba el servicio, el worker atiende `SIGTERM` y `docker-compose.yml` le pone `restart: unless-stopped`. Resultado: los tres servicios quedan `running` sin reinicios.
- **Evidencia:** evidence/01-worker.txt

## Incidente 2
- **Síntoma:** `curl http://localhost:8081/afiliados/1098765432` responde `503 {"error": "base de datos no disponible"}`: la API no conecta a la base.
- **Diagnóstico:** `docker compose logs cierre-api | grep CIE-2210` muestra `could not translate host name "cierre-database" to address`. `docker compose config --services` lista el servicio como `cierre-db`: `DATABASE_HOST` apuntaba a un nombre que no existe. Dentro de la red de Compose cada contenedor se alcanza por el nombre de su servicio (localhost tampoco sirve, porque sería el propio contenedor de la API).
- **Comandos:** `curl -s -w '%{http_code}' http://localhost:8081/afiliados/1098765432`, `docker compose logs cierre-api | grep CIE-2210`, `grep -n DATABASE_HOST .env.example`, `docker compose config --services`
- **Solución:** `DATABASE_HOST=cierre-db` en `.env.example`. `docker-compose.yml` ahora pasa las variables con `environment:` y valores por defecto (`${DATABASE_HOST:-cierre-db}`) en lugar de `env_file: .env`, que hacía fallar `docker compose up` en una copia limpia sin `.env`. Verificado con `docker compose exec cierre-api` y con la consulta que responde 200.
- **Evidencia:** evidence/02-api-base.txt

## Incidente 3
- **Síntoma:** `./run.sh` termina con `Permission denied` (código 126) y, al llamar el script con `bash scripts/cierre.sh`, awk no puede abrir `/opt/cierre/entrada/AFI_MAE.csv` (No such file or directory).
- **Diagnóstico:** `ls -l` y `git ls-files -s` muestran `scripts/cierre.sh` con modo `100644`, sin permiso de ejecución. `grep -n '^ENTRADA=' scripts/cierre.sh` muestra la ruta `/opt/cierre/entrada`, que no existe en el servidor; `find . -name AFI_MAE.csv` encuentra la entrada en `./data/`.
- **Comandos:** `ls -l run.sh scripts/cierre.sh`, `git ls-files -s scripts/cierre.sh`, `grep -n '^ENTRADA=' scripts/cierre.sh`, `find . -name 'AFI_MAE.csv'`, `chmod +x scripts/*.sh`, `git update-index --chmod=+x run.sh reset.sh validator scripts/*.sh`, `git ls-files -s run.sh reset.sh validator scripts/`
- **Solución:** `chmod +x` a los scripts y `git update-index --chmod=+x` para que el permiso quede guardado en Git: desde Windows el permiso no viaja solo y un commit normal deja todos los scripts en `100644`. Verificamos con `git ls-files -s` que `run.sh`, `reset.sh`, `validator` y `scripts/*.sh` queden en `100755`, y GitHub Actions falla si alguno lo pierde. `ENTRADA` ahora es `data`, relativa a la raíz del repositorio y configurable con `CIERRE_ENTRADA`. El script valida que cada CSV exista y sea legible antes de empezar, y `run.sh` lo invoca con `bash` para que funcione aunque una copia pierda el permiso.
- **Evidencia:** evidence/03-entrada-cierre.txt

## Incidente 4
- **Síntoma:** los logs tienen 11.515 líneas (`api.log` 4.656, `worker.log` 3.878, `database.log` 2.981) y no se sabía cuál es el error que más se repite.
- **Diagnóstico:** según el diccionario, los errores usan códigos `CIE-####` y los avisos `W-###` (W-120 y W-301) no son errores. Con `grep`, `sort` y `uniq -c` contamos los códigos de las líneas `ERROR` de los tres archivos: CIE-4012 1.424 (356 en api y 1.068 en worker), CIE-5003 700, CIE-2210 460, CIE-3301 298, CIE-1107 158 y CIE-6020 75. Hay que sumar los tres logs: mirando solo `worker.log` el conteo saldría 1.068.
- **Comandos:** `wc -l logs/*.log`, `grep -hE '(^|[^A-Za-z])ERROR([^A-Za-z]|$)' logs/*.log | grep -oE 'CIE-[0-9]{4}' | sort | uniq -c | sort -k1,1nr`, `grep -c CIE-4012 logs/*.log`, `grep -ohE 'W-[0-9]+' logs/*.log | sort | uniq -c`
- **Solución:** `scripts/cierre.sh` calcula `output/top_error.txt` con ese mismo pipeline (`LC_ALL=C sort` y desempate por código para que sea determinista): `codigo_error=CIE-4012` y `ocurrencias=1424`. CIE-4012 es "registro de afiliado sin empresa asociada", el mismo problema de datos del incidente 5.
- **Evidencia:** evidence/04-top-error.txt

## Incidente 5
- **Síntoma:** `afi_mae` tiene 1.520 registros pero 1.500 documentos distintos (`SELECT count(*), count(DISTINCT nro_doc) FROM afi_mae` devuelve 1520 y 1500 en el kit original), hay estados que no son A ni I, afiliados con empresas que no existen y beneficiarios sin afiliado.
- **Diagnóstico:** con `psql` y con `awk`/`sort`/`uniq` sobre los CSV encontramos 20 documentos repetidos, 14 afiliados con `EST_AFI` inválido (Z, P, 9 y X), 18 activos con `COD_EMP` vacío o inexistente (9999, 0000, 1999, 8888) y 15 beneficiarios cuyo `NRO_DOC_AFI` no existe en AFI_MAE. Los totales de la base coinciden con los del cierre.
- **Comandos:** `docker compose exec cierre-db psql -U cierre -d cierre -c "SELECT count(*), count(DISTINCT nro_doc) FROM afi_mae"`, `awk -F, 'NR > 1 { print $7 }' data/AFI_MAE.csv | sort | uniq -c`, `awk -F, 'NR > 1 { visto[$1]++ } END { for (d in visto) if (visto[d] > 1) n++; print n }' data/AFI_MAE.csv`, `cut -d, -f2 output/excepciones.csv | sort | uniq -c`
- **Solución:** en la base, `db/init/03_correcciones.sql` borra las 20 apariciones repetidas conservando la primera (la columna `id_carga` guarda el orden de carga) y registra cada cambio en la tabla `correcciones`; es idempotente y se puede reaplicar con `./scripts/corregir_base.sh`. Lo irreparable queda en la vista `pendientes_calidad` y el cierre lo reporta en `output/excepciones.csv`: 20 `DUPLICADO` (una vez por documento), 14 `CODIGO_INVALIDO`, 18 `SIN_EMPRESA` y 15 `BENEFICIARIO_HUERFANO` (con el documento del beneficiario).
- **Evidencia:** evidence/05-calidad-datos.txt

## Incidente 6
- **Síntoma:** con la base ya conectada, `GET /afiliados/3756530718` (y 88121168, 6015866271) responde `500 {"error": "error interno"}`; en `api.log` hay 700 errores CIE-5003.
- **Diagnóstico:** el traceback de `docker compose logs cierre-api` muestra `TypeError: can only concatenate str (not "NoneType") to str` en `nombre = nom1 + " " + nom2 ...`. Con `psql` vimos `nom2 IS NULL` en esos documentos: 490 registros no tienen segundo nombre y 144 no tienen segundo apellido, y la carga CSV guarda el campo vacío como NULL. Leyendo `app.py` encontramos dos fallas más: `ESTADOS[est_afi]` lanza `KeyError` con los códigos inválidos, y el `JOIN` con empresa respondía 404 para afiliados que sí existen pero no tienen empresa.
- **Comandos:** `curl -s -w '%{http_code}' http://localhost:8081/afiliados/3756530718`, `docker compose logs cierre-api | grep -A 14 CIE-5003`, `docker compose exec cierre-db psql -U cierre -d cierre -c "SELECT nro_doc, nom2 IS NULL FROM afi_mae WHERE nro_doc = '3756530718'"`
- **Solución:** `full_name()` une solo los nombres y apellidos no vacíos; `LEFT JOIN empresa` (empresa `null` si no tiene); un código distinto de A/I responde `"estado": "CODIGO_INVALIDO"` en vez de 500; `ORDER BY id_carga LIMIT 1` devuelve la primera aparición; inexistente → 404. La ruta tolera `/` final y parámetros. Las 4 consultas de prueba responden 200 con los datos correctos y `0000000001` responde 404.
- **Evidencia:** evidence/06-consulta-afiliado.txt

## Incidente 7
- **Síntoma:** `worker.log` tiene 298 errores CIE-3301 "Fecha de afiliación con formato no soportado" y en `FEC_AFI` aparecen valores como `01/07/2017`, `20100915`, `SIN FECHA`, `N/A`, `2023/02/29` y `15-15-2019`.
- **Diagnóstico:** con `awk` y `sed` agrupamos los formatos: 1.493 en `YYYY-MM-DD`, 11 en `DD/MM/YYYY`, 11 en `YYYYMMDD` y 5 en otros formatos. Además hay fechas con formato válido que no existen: `2025-02-30`, `2024-00-10`, `31/13/2024` y `00000000`. El script heredado no miraba las fechas.
- **Comandos:** `grep -c CIE-3301 logs/worker.log`, `awk -F, 'NR > 1 { print $9 }' data/AFI_MAE.csv | sed -E 's/[0-9]/9/g' | sort | uniq -c`, `grep FECHA_INVALIDA output/excepciones.csv`
- **Solución:** `normalizar_fecha()` en `scripts/cierre.py` acepta los tres formatos del diccionario y valida que la fecha sea real: 18 se normalizan a `YYYY-MM-DD` y 12 se reportan como `FECHA_INVALIDA`. Ningún afiliado sale de los totales por su fecha. En la base, `03_correcciones.sql` guarda las 18 fechas normalizadas (función `normaliza_fecha`) y deja el valor anterior en `correcciones`.
- **Evidencia:** evidence/07-fechas.txt

## Incidente 8
- **Síntoma:** `extracto_caja_oriente.csv` llega con otro formato (separador `;`, columnas `id_afiliado;nombres_apellidos;situacion;fecha_reporte`, documentos de 12 dígitos y fechas `DD/MM/YYYY`) y el script heredado no hacía el cruce (era un TODO).
- **Diagnóstico:** con `head` y `awk -F';'` vimos que `000013022985` es nuestro `13022985` al quitar los ceros a la izquierda, y que `situacion` es VIGENTE (nuestro A) o RETIRADO (nuestro I). De los 325 registros del extracto, 10 no existen en AFI_MAE, 7 vienen RETIRADO y aquí están activos, y 8 vienen VIGENTE y aquí están inactivos.
- **Comandos:** `head -n 3 data/extracto_caja_oriente.csv`, `awk -F';' '{ d = $1; sub(/^0+/, "", d); print $1 " -> " d }' data/extracto_caja_oriente.csv`, `grep -c CRUCE_NO_COINCIDE output/excepciones.csv`, `head -n 1 output/afiliados_activos.csv`
- **Solución:** `scripts/cierre.py` detecta el separador, quita los ceros a la izquierda y compara VIGENTE con A y RETIRADO con I. Reporta 25 `CRUCE_NO_COINCIDE` con el documento en nuestro formato y el motivo en `detalle`. El archivo de activos conserva su formato: el mismo encabezado de 7 columnas del contrato.
- **Evidencia:** evidence/08-cruce-oriente.txt

## Incidente 9
- **Síntoma:** el script heredado escribía `total_afiliados=1520` y `activos=1225`, mientras la hoja de control dice 1500, 1194 y 274 inactivos; tampoco calculaba `inactivos` ni `excepciones`.
- **Diagnóstico:** el script contaba líneas con `wc -l` (incluía los 20 duplicados) y contaba todos los `A` (incluía los 13 duplicados activos y los 18 activos sin empresa). Según el diccionario, total = documentos distintos, activo = A con empresa válida, y los códigos inválidos y los activos sin empresa no cuentan ni como activos ni como inactivos.
- **Comandos:** `cat output/totales.txt`, `cat control/hoja_control.csv`, `grep -c ',A,' data/AFI_MAE.csv`, `tail -n +2 output/excepciones.csv | wc -l`
- **Solución:** `scripts/cierre.py` aplica las reglas 1 a 3 y 8 del diccionario: `total_afiliados=1500`, `activos=1194` (1.225 filas A − 13 duplicadas − 18 sin empresa), `inactivos=274` y `excepciones=104`. Cuadra: 1.194 + 274 + 14 códigos inválidos + 18 sin empresa = 1.500. `./run.sh` muestra la comparación con la hoja de control en cada ejecución.
- **Evidencia:** evidence/09-totales.txt

## Incidente 10
- **Síntoma:** la segunda ejecución del cierre falla con `mkdir: cannot create directory 'output': File exists`, y la primera mueve `data/AFI_MAE.csv` a `data/procesados/`, así que ya no queda entrada para volver a correrlo.
- **Diagnóstico:** el script usaba `set -e` con `mkdir` sin `-p`, hacía `mv` del archivo de entrada y escribía `totales.txt` con `>>`, que agrega líneas en cada ejecución. `git status --short data/` mostró ` D data/AFI_MAE.csv` después de la primera corrida.
- **Comandos:** `bash scripts/cierre.sh` (dos veces), `ls data/ data/procesados/`, `git status --short data/`, `sha256sum output/*`, `diff /tmp/ejecucion1.sha /tmp/ejecucion2.sha`, `./reset.sh`
- **Solución:** `mkdir -p`; la entrada ya no se mueve ni se modifica; cada archivo de `output/` se escribe completo en un temporal y se renombra; el orden de las filas es determinista y la salida no lleva fechas de ejecución. `./run.sh` dos veces seguidas y después de `./reset.sh` produce los mismos `sha256sum`, y GitHub Actions lo vuelve a probar en cada push.
- **Evidencia:** evidence/10-repetibilidad.txt
