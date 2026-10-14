-- Carga inicial desde los CSV del kit (montados en /data).
-- afi_mae lleva la lista de columnas porque id_carga la numera PostgreSQL en el orden del archivo.
\copy empresa FROM '/data/EMPRESA.csv' WITH (FORMAT csv, HEADER true)
\copy afi_mae (nro_doc, tip_doc, nom1, nom2, ape1, ape2, est_afi, cod_emp, fec_afi) FROM '/data/AFI_MAE.csv' WITH (FORMAT csv, HEADER true)
\copy afi_ben FROM '/data/AFI_BEN.csv' WITH (FORMAT csv, HEADER true)
\copy aportes FROM '/data/APORTES.csv' WITH (FORMAT csv, HEADER true)
