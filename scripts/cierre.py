#!/usr/bin/env python3
"""Cierre mensual de afiliados activos (Terminal Rescue).

Lee los CSV del sistema origen y genera en la carpeta de salida:

  afiliados_activos.csv  documento,nombre,estado,cod_empresa,empresa,beneficiarios,ultimo_aporte
  excepciones.csv        documento,tipo,detalle
  totales.txt            total_afiliados, activos, inactivos, excepciones

Las reglas son las de docs/diccionario.md ("Reglas del cierre"). Solo usa la biblioteca
estandar de Python 3 y nunca modifica los archivos de entrada, por eso se puede ejecutar
todas las veces que se quiera y siempre produce exactamente la misma salida.
"""

import argparse
import csv
import datetime
import os
import re
import sys
import tempfile
from collections import Counter, OrderedDict, defaultdict

ESTADOS = {"A": "ACTIVO", "I": "INACTIVO"}

# Caja Oriente: VIGENTE equivale a nuestro activo y RETIRADO a nuestro inactivo.
SITUACION_ORIENTE = {"VIGENTE": "A", "RETIRADO": "I"}

# Formatos de FEC_AFI que el cierre sabe convertir a YYYY-MM-DD (regla 5).
FORMATOS_FECHA = [
    (re.compile(r"^\d{4}-\d{2}-\d{2}$"), "%Y-%m-%d"),
    (re.compile(r"^\d{2}/\d{2}/\d{4}$"), "%d/%m/%Y"),
    (re.compile(r"^\d{8}$"), "%Y%m%d"),
]

PERIODO = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")

ENCABEZADO_ACTIVOS = ["documento", "nombre", "estado", "cod_empresa", "empresa", "beneficiarios", "ultimo_aporte"]
ENCABEZADO_EXCEPCIONES = ["documento", "tipo", "detalle"]

# Orden en el que se escriben las excepciones (y en el que se resumen en pantalla).
TIPOS = ["DUPLICADO", "CODIGO_INVALIDO", "SIN_EMPRESA", "FECHA_INVALIDA", "BENEFICIARIO_HUERFANO", "CRUCE_NO_COINCIDE"]


# --------------------------------------------------------------------------- lectura


def leer_csv(ruta):
    """Filas de un CSV como diccionarios con encabezados en mayusculas y celdas sin espacios.

    Detecta el separador (',' o ';') por la primera linea: el extracto de Caja Oriente usa ';'.
    """
    with open(ruta, encoding="utf-8-sig", newline="") as archivo:
        primera = archivo.readline()
        archivo.seek(0)
        separador = ";" if primera.count(";") > primera.count(",") else ","
        lector = csv.reader(archivo, delimiter=separador)
        encabezado = [c.strip().upper() for c in next(lector, [])]
        filas = []
        for numero, celdas in enumerate(lector, start=2):
            if not any(c.strip() for c in celdas):
                continue  # linea en blanco
            celdas = [c.strip() for c in celdas] + [""] * (len(encabezado) - len(celdas))
            fila = dict(zip(encabezado, celdas))
            fila["_LINEA"] = numero
            filas.append(fila)
    return filas


def clave_documento(documento):
    """Documento comparable entre sistemas: sin espacios ni ceros a la izquierda.

    Caja Oriente rellena con ceros hasta 12 digitos ('000013022985' es nuestro '13022985').
    """
    valor = (documento or "").strip()
    return valor.lstrip("0") or valor


def normalizar_fecha(valor):
    """'YYYY-MM-DD' si la fecha es real en alguno de los formatos conocidos; None si no."""
    texto = (valor or "").strip()
    for patron, formato in FORMATOS_FECHA:
        if patron.match(texto):
            try:
                return datetime.datetime.strptime(texto, formato).strftime("%Y-%m-%d")
            except ValueError:
                return None  # el formato se reconoce pero la fecha no existe (30 de febrero, mes 13...)
    return None


def nombre_completo(fila):
    """Nombres y apellidos no vacios separados por un espacio (NOM2 y APE2 pueden venir vacios)."""
    partes = [fila.get(c, "") for c in ("NOM1", "NOM2", "APE1", "APE2")]
    return " ".join(p for p in partes if p)


# --------------------------------------------------------------------------- reglas


class Cierre:
    def __init__(self, entrada):
        self.maestro = leer_csv(os.path.join(entrada, "AFI_MAE.csv"))
        self.beneficiarios = leer_csv(os.path.join(entrada, "AFI_BEN.csv"))
        self.aportes = leer_csv(os.path.join(entrada, "APORTES.csv"))
        self.empresas = OrderedDict((f["COD_EMP"], f["NOM_EMP"]) for f in leer_csv(os.path.join(entrada, "EMPRESA.csv")))
        self.extracto = leer_csv(os.path.join(entrada, "extracto_caja_oriente.csv"))

        self.excepciones = []
        self._reportadas = set()
        self.activos = []
        self.inactivos = 0
        self.fechas_normalizadas = Counter()
        self.periodos_invalidos = 0

    def reportar(self, documento, tipo, detalle):
        """Agrega una excepcion; un documento se reporta una sola vez por tipo."""
        if (documento, tipo) in self._reportadas:
            return
        self._reportadas.add((documento, tipo))
        self.excepciones.append((documento, tipo, detalle))

    def ejecutar(self):
        afiliados = self._universo()
        self._estados_y_empresas(afiliados)
        self._fechas(afiliados)
        self._beneficiarios_huerfanos(afiliados)
        self._cruce_oriente(afiliados)
        self._archivo_activos(afiliados)
        # sort es estable: agrupa por tipo y, dentro de cada tipo, conserva el orden de deteccion.
        self.excepciones.sort(key=lambda excepcion: TIPOS.index(excepcion[1]))
        return afiliados

    def _universo(self):
        """Regla 1: cada documento distinto es un afiliado; se conserva la primera aparicion."""
        afiliados = OrderedDict()
        lineas = defaultdict(list)
        for fila in self.maestro:
            clave = clave_documento(fila["NRO_DOC"])
            if not clave:
                print("AVISO: AFI_MAE linea {0} sin NRO_DOC; no se puede procesar".format(fila["_LINEA"]), file=sys.stderr)
                continue
            lineas[clave].append(fila["_LINEA"])
            afiliados.setdefault(clave, fila)
        for clave, fila in afiliados.items():
            if len(lineas[clave]) > 1:
                self.reportar(fila["NRO_DOC"], "DUPLICADO", "aparece {0} veces en AFI_MAE (lineas {1}); se conserva la primera aparicion".format(
                    len(lineas[clave]), " ".join(str(n) for n in lineas[clave])))
        return afiliados

    def _estados_y_empresas(self, afiliados):
        """Reglas 2 y 3: solo A e I son validos; un activo necesita una empresa existente."""
        for fila in afiliados.values():
            estado, empresa = fila["EST_AFI"], fila["COD_EMP"]
            if estado not in ESTADOS:
                self.reportar(fila["NRO_DOC"], "CODIGO_INVALIDO", "EST_AFI='{0}' no es un codigo valido (A o I); no cuenta como activo ni inactivo".format(estado))
            elif estado == "A" and empresa not in self.empresas:
                motivo = "COD_EMP vacio" if not empresa else "COD_EMP={0} no existe en EMPRESA".format(empresa)
                self.reportar(fila["NRO_DOC"], "SIN_EMPRESA", motivo + "; no entra al archivo de activos")

    def _fechas(self, afiliados):
        """Regla 5: se normaliza lo que se puede y se reporta lo que no; nadie sale de los totales."""
        for fila in afiliados.values():
            original = fila["FEC_AFI"]
            normalizada = normalizar_fecha(original)
            fila["_FEC_AFI"] = normalizada
            if normalizada is None:
                self.reportar(fila["NRO_DOC"], "FECHA_INVALIDA", "FEC_AFI='{0}' no es una fecha real; el afiliado se conserva en los totales".format(original))
            elif normalizada != original:
                self.fechas_normalizadas["DD/MM/YYYY" if "/" in original else "YYYYMMDD"] += 1

    def _beneficiarios_huerfanos(self, afiliados):
        """Regla 4: beneficiario cuyo afiliado no existe (se reporta el documento del beneficiario)."""
        for fila in self.beneficiarios:
            if clave_documento(fila["NRO_DOC_AFI"]) not in afiliados:
                self.reportar(fila["NRO_DOC_BEN"], "BENEFICIARIO_HUERFANO", "su afiliado NRO_DOC_AFI={0} no existe en AFI_MAE".format(fila["NRO_DOC_AFI"] or "(vacio)"))

    def _cruce_oriente(self, afiliados):
        """Regla 6: documento inexistente o situacion distinta a nuestro estado."""
        for fila in self.extracto:
            identificador = fila.get("ID_AFILIADO", "")
            clave = clave_documento(identificador)
            situacion = fila.get("SITUACION", "").upper()
            nuestro = afiliados.get(clave)
            if nuestro is None:
                self.reportar(clave, "CRUCE_NO_COINCIDE", "id_afiliado={0} de Caja Oriente no existe en AFI_MAE".format(identificador))
            elif situacion not in SITUACION_ORIENTE:
                self.reportar(nuestro["NRO_DOC"], "CRUCE_NO_COINCIDE", "situacion '{0}' de Caja Oriente no es VIGENTE ni RETIRADO".format(situacion))
            elif SITUACION_ORIENTE[situacion] != nuestro["EST_AFI"]:
                estado = ESTADOS.get(nuestro["EST_AFI"], "codigo invalido")
                self.reportar(nuestro["NRO_DOC"], "CRUCE_NO_COINCIDE", "Caja Oriente reporta {0} y en AFI_MAE esta {1} (EST_AFI='{2}')".format(
                    situacion, estado, nuestro["EST_AFI"]))

    def _archivo_activos(self, afiliados):
        """Reglas 7 y 8: un registro por afiliado activo con empresa valida."""
        beneficiarios = defaultdict(set)
        for fila in self.beneficiarios:
            beneficiarios[clave_documento(fila["NRO_DOC_AFI"])].add(fila["NRO_DOC_BEN"])
        ultimo_aporte = {}
        for fila in self.aportes:
            periodo = fila["PERIODO"]
            if not PERIODO.match(periodo):
                self.periodos_invalidos += 1
                continue
            clave = clave_documento(fila["NRO_DOC"])
            if periodo > ultimo_aporte.get(clave, ""):
                ultimo_aporte[clave] = periodo
        for clave, fila in afiliados.items():
            if fila["EST_AFI"] == "I":
                self.inactivos += 1
            elif fila["EST_AFI"] == "A" and fila["COD_EMP"] in self.empresas:
                self.activos.append([
                    fila["NRO_DOC"], nombre_completo(fila), ESTADOS["A"], fila["COD_EMP"],
                    self.empresas[fila["COD_EMP"]], str(len(beneficiarios[clave])), ultimo_aporte.get(clave, ""),
                ])


# --------------------------------------------------------------------------- salida


def escribir_atomico(ruta, escribir):
    """Escribe en un temporal y lo renombra: nunca queda un archivo a medias en output/."""
    carpeta = os.path.dirname(ruta) or "."
    descriptor, temporal = tempfile.mkstemp(prefix=".tmp-", dir=carpeta)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as archivo:
            escribir(archivo)
        os.replace(temporal, ruta)
    except BaseException:
        if os.path.exists(temporal):
            os.remove(temporal)
        raise


def escribir_csv(ruta, encabezado, filas):
    def escribir(archivo):
        escritor = csv.writer(archivo, lineterminator="\n")
        escritor.writerow(encabezado)
        escritor.writerows(filas)
    escribir_atomico(ruta, escribir)


def leer_control(ruta):
    control = {}
    if ruta and os.path.exists(ruta):
        for fila in leer_csv(ruta):
            control[fila.get("CLAVE", "").lower()] = fila.get("VALOR", "")
    return control


def main(argv=None):
    parser = argparse.ArgumentParser(description="Cierre mensual de afiliados activos")
    parser.add_argument("--entrada", default="data", help="carpeta con los CSV de origen (por defecto data)")
    parser.add_argument("--salida", default="output", help="carpeta de salida (por defecto output)")
    parser.add_argument("--control", default="control/hoja_control.csv", help="hoja de control de Operaciones")
    args = parser.parse_args(argv)

    os.makedirs(args.salida, exist_ok=True)
    cierre = Cierre(args.entrada)
    afiliados = cierre.ejecutar()

    totales = OrderedDict([
        ("total_afiliados", len(afiliados)),
        ("activos", len(cierre.activos)),
        ("inactivos", cierre.inactivos),
        ("excepciones", len(cierre.excepciones)),
    ])
    escribir_csv(os.path.join(args.salida, "afiliados_activos.csv"), ENCABEZADO_ACTIVOS, cierre.activos)
    escribir_csv(os.path.join(args.salida, "excepciones.csv"), ENCABEZADO_EXCEPCIONES, cierre.excepciones)
    escribir_atomico(os.path.join(args.salida, "totales.txt"),
                     lambda archivo: archivo.write("".join("{0}={1}\n".format(k, v) for k, v in totales.items())))

    por_tipo = Counter(tipo for _, tipo, _ in cierre.excepciones)
    print("Registros leidos: AFI_MAE={0} AFI_BEN={1} APORTES={2} EMPRESA={3} extracto={4}".format(
        len(cierre.maestro), len(cierre.beneficiarios), len(cierre.aportes), len(cierre.empresas), len(cierre.extracto)))
    print("Excepciones: " + " ".join("{0}={1}".format(t, por_tipo.get(t, 0)) for t in TIPOS))
    print("Fechas normalizadas a YYYY-MM-DD: {0} (DD/MM/YYYY={1}, YYYYMMDD={2})".format(
        sum(cierre.fechas_normalizadas.values()), cierre.fechas_normalizadas["DD/MM/YYYY"], cierre.fechas_normalizadas["YYYYMMDD"]))
    if cierre.periodos_invalidos:
        print("AVISO: {0} aportes con PERIODO fuera del formato YYYY-MM no se tuvieron en cuenta".format(cierre.periodos_invalidos), file=sys.stderr)

    control = leer_control(args.control)
    for clave, valor in totales.items():
        esperado = control.get(clave)
        marca = "" if esperado is None else ("  OK (control={0})".format(esperado) if str(valor) == esperado else "  NO CUADRA (control={0})".format(esperado))
        print("{0}={1}{2}".format(clave, valor, marca))
    return 0


if __name__ == "__main__":
    sys.exit(main())
