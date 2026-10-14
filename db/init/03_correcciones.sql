-- Correcciones de calidad de datos en la base (incidentes 5 y 7).
--
-- Se ejecuta solo al crear la base, después de 01_schema.sql y 02_load.sql. Es idempotente:
-- scripts/corregir_base.sh lo vuelve a aplicar sobre una base existente sin cambiar el resultado.
--
-- Se corrige lo que tiene una única respuesta correcta y cada cambio queda en la tabla
-- correcciones. Lo irreparable (código de estado inválido, afiliado sin empresa, beneficiario
-- huérfano y fecha imposible) no se inventa: queda en la vista pendientes_calidad y el cierre
-- lo reporta en output/excepciones.csv.

-- Bases creadas con el esquema anterior no tienen id_carga (en las nuevas no hace nada).
ALTER TABLE afi_mae ADD COLUMN IF NOT EXISTS id_carga BIGINT GENERATED ALWAYS AS IDENTITY;

CREATE TABLE IF NOT EXISTS correcciones (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tabla          TEXT NOT NULL,
    documento      TEXT,
    tipo           TEXT NOT NULL,
    valor_anterior TEXT,
    valor_nuevo    TEXT,
    aplicada_en    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- FEC_AFI como fecha si es real en un formato conocido (YYYY-MM-DD, DD/MM/YYYY o YYYYMMDD);
-- NULL si no se puede interpretar (30 de febrero, mes 13, 00000000, 'SIN FECHA'...).
CREATE OR REPLACE FUNCTION normaliza_fecha(valor TEXT) RETURNS DATE
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v TEXT := btrim(coalesce(valor, ''));
BEGIN
    IF v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RETURN make_date(substr(v, 1, 4)::int, substr(v, 6, 2)::int, substr(v, 9, 2)::int);
    ELSIF v ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN
        RETURN make_date(substr(v, 7, 4)::int, substr(v, 4, 2)::int, substr(v, 1, 2)::int);
    ELSIF v ~ '^[0-9]{8}$' THEN
        RETURN make_date(substr(v, 1, 4)::int, substr(v, 5, 2)::int, substr(v, 7, 2)::int);
    END IF;
    RETURN NULL;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- 1) Documentos repetidos: se conserva la primera aparición (menor id_carga).
WITH repetidos AS (
    SELECT id_carga,
           row_number() OVER (PARTITION BY nro_doc ORDER BY id_carga) AS aparicion
    FROM afi_mae
    WHERE nro_doc IS NOT NULL
), borrados AS (
    DELETE FROM afi_mae a
    USING repetidos r
    WHERE a.id_carga = r.id_carga AND r.aparicion > 1
    RETURNING a.nro_doc, a.id_carga, a.est_afi, a.cod_emp, a.fec_afi
)
INSERT INTO correcciones (tabla, documento, tipo, valor_anterior, valor_nuevo)
SELECT 'afi_mae', nro_doc, 'DUPLICADO_ELIMINADO',
       format('id_carga=%s est_afi=%s cod_emp=%s fec_afi=%s', id_carga, est_afi, cod_emp, fec_afi),
       'se conserva la primera aparicion'
FROM borrados
ORDER BY id_carga;

-- 2) Fechas en DD/MM/YYYY o YYYYMMDD que son reales: se guardan como YYYY-MM-DD.
WITH previas AS (
    SELECT id_carga, nro_doc, fec_afi AS anterior,
           to_char(normaliza_fecha(fec_afi), 'YYYY-MM-DD') AS nueva
    FROM afi_mae
    WHERE normaliza_fecha(fec_afi) IS NOT NULL
), actualizadas AS (
    UPDATE afi_mae a
    SET fec_afi = p.nueva
    FROM previas p
    WHERE a.id_carga = p.id_carga AND a.fec_afi IS DISTINCT FROM p.nueva
    RETURNING p.nro_doc, p.id_carga, p.anterior, p.nueva
)
INSERT INTO correcciones (tabla, documento, tipo, valor_anterior, valor_nuevo)
SELECT 'afi_mae', nro_doc, 'FECHA_NORMALIZADA', anterior, nueva
FROM actualizadas
ORDER BY id_carga;

-- 3) Lo que no se puede reparar en la base: se consulta con
--    SELECT tipo, count(*) FROM pendientes_calidad GROUP BY tipo;
CREATE OR REPLACE VIEW pendientes_calidad AS
SELECT a.nro_doc AS documento, 'CODIGO_INVALIDO' AS tipo,
       'EST_AFI=' || coalesce(a.est_afi, '(vacio)') AS detalle
FROM afi_mae a
WHERE a.est_afi IS NULL OR a.est_afi NOT IN ('A', 'I')
UNION ALL
SELECT a.nro_doc, 'SIN_EMPRESA', 'COD_EMP=' || coalesce(a.cod_emp, '(vacio)')
FROM afi_mae a
LEFT JOIN empresa e ON e.cod_emp = a.cod_emp
WHERE a.est_afi = 'A' AND e.cod_emp IS NULL
UNION ALL
SELECT b.nro_doc_ben, 'BENEFICIARIO_HUERFANO', 'NRO_DOC_AFI=' || coalesce(b.nro_doc_afi, '(vacio)')
FROM afi_ben b
WHERE NOT EXISTS (SELECT 1 FROM afi_mae a WHERE a.nro_doc = b.nro_doc_afi)
UNION ALL
SELECT a.nro_doc, 'FECHA_INVALIDA', 'FEC_AFI=' || coalesce(a.fec_afi, '(vacia)')
FROM afi_mae a
WHERE normaliza_fecha(a.fec_afi) IS NULL;
