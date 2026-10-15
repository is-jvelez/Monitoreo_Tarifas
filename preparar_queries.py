"""
preparar_queries.py

Paso previo a generar_reporte_tarifas.py: deja listas para ejecutar en SSMS
las 4 queries de diagnostico de 01_QueriesTarifas/ (Aduana, Carga Suelta,
Contenedor, Servicios Adicionales) con la MISMA fecha de inicio.

Las queries son SOLO LECTURA: identifican las tarifas elegibles e imprimen el
detalle en Messages, pero no modifican nada. Por cada
script-T*-Regularizacion.sql se genera una copia en la carpeta de salida con
@fechaCreacion = la fecha de inicio indicada (desde cuando se revisan las
tarifas creadas/modificadas). Los originales de 01_QueriesTarifas/ no se tocan.

Como resguardo, antes de copiar se verifica que ninguna query tenga sentencias
de escritura (UPDATE, INSERT, DELETE, MERGE, TRUNCATE, ALTER, CREATE, EXEC,
transacciones, DROP de tablas que no sean temporales #, SELECT INTO de tablas
que no sean temporales). Si alguna las tiene, no se genera ninguna copia.

USO:
    python preparar_queries.py <fecha_inicio> [--salida CARPETA]

    fecha_inicio  "AAAA-MM-DD" o "AAAA-MM-DD HH:MM" o "AAAA-MM-DD HH:MM:SS"
    --salida      Por defecto Output_<AAAAMMDD de hoy>/Diagnostico

Ejemplo:
    python preparar_queries.py "2026-10-14 15:00"
"""

import argparse
import re
import sys
from datetime import date, datetime
from pathlib import Path

QUERIES_DIR = Path(__file__).resolve().parent / "01_QueriesTarifas"

QUERIES = {
    "Aduana": "script-TA-Regularizacion.sql",
    "Carga Suelta": "script-TCS-Regularizacion.sql",
    "Contenedor": "script-TCO-Regularizacion.sql",
    "Servicios Adicionales": "script-TSA-Regularizacion.sql",
}

FECHA_RE = re.compile(r"(^[ \t]*DECLARE[ \t]+@fechaCreacion[ \t]+DATETIME[ \t]*=[ \t]*)'([^']*)'", re.I | re.M)

# Sentencias que escriben en la base. Se buscan en el codigo SIN comentarios ni
# textos entre comillas, para no confundir mensajes como 'Elegibles para UPDATE'.
ESCRITURA_RE = re.compile(
    r"\b(UPDATE|INSERT|DELETE|MERGE|TRUNCATE|ALTER|CREATE|EXEC|EXECUTE|SP_EXECUTESQL"
    r"|COMMIT|GRANT|REVOKE|DENY|BULK)\b"
    r"|\bBEGIN\s+(TRAN|TRANSACTION)\b"
    r"|\bDROP\s+TABLE\s+(?!#)"
    r"|\bINTO\s+(?![#@])",
    re.I,
)
_COMENTARIOS_Y_TEXTOS_RE = re.compile(r"/\*.*?\*/|--[^\n]*|'(?:[^']|'')*'", re.S)

FORMATOS_FECHA = ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d")


def parsear_fecha_inicio(valor: str) -> datetime:
    for formato in FORMATOS_FECHA:
        try:
            return datetime.strptime(valor.strip(), formato)
        except ValueError:
            continue
    raise argparse.ArgumentTypeError(
        f"fecha invalida {valor!r}; usa AAAA-MM-DD, AAAA-MM-DD HH:MM o AAAA-MM-DD HH:MM:SS"
    )


def _leer(ruta: Path):
    """Devuelve (texto, encoding) respetando como esta guardado el .sql."""
    datos = ruta.read_bytes()
    if datos.startswith((b"\xff\xfe", b"\xfe\xff")):
        encoding = "utf-16"
    elif datos.startswith(b"\xef\xbb\xbf"):
        encoding = "utf-8-sig"
    else:
        try:
            datos.decode("utf-8")
            encoding = "utf-8"
        except UnicodeDecodeError:
            encoding = "cp1252"
    with open(ruta, encoding=encoding, newline="") as f:  # newline="" conserva CRLF/LF
        return f.read(), encoding


def sentencias_de_escritura(texto: str) -> list:
    """Devuelve las sentencias de escritura encontradas (vacio = solo lectura)."""
    codigo = _COMENTARIOS_Y_TEXTOS_RE.sub(" ", texto)
    return sorted({" ".join(m.group(0).split()).upper() for m in ESCRITURA_RE.finditer(codigo)})


def preparar_query(texto: str, fecha_inicio: datetime, nombre: str):
    """Devuelve (texto_nuevo, fecha_anterior). Lanza ValueError si el script no tiene
    exactamente una declaracion de @fechaCreacion o si no es de solo lectura."""
    escrituras = sentencias_de_escritura(texto)
    if escrituras:
        raise ValueError(
            f"{nombre}: no es de solo lectura, contiene: {', '.join(escrituras)}."
        )

    fechas = FECHA_RE.findall(texto)
    if len(fechas) != 1:
        raise ValueError(
            f"{nombre}: se esperaba exactamente 1 'DECLARE @fechaCreacion DATETIME = ...', "
            f"se encontraron {len(fechas)}."
        )

    valor_fecha = fecha_inicio.strftime("%Y-%m-%d %H:%M:%S.000")
    texto = FECHA_RE.sub(lambda m: f"{m.group(1)}'{valor_fecha}'", texto)
    return texto, fechas[0][1]


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Copia las 4 queries de diagnostico (solo lectura) con la misma @fechaCreacion."
    )
    parser.add_argument("fecha_inicio", type=parsear_fecha_inicio,
                        help='fecha de inicio, ej. "2026-10-14 15:00"')
    parser.add_argument("--salida", help="carpeta de salida (por defecto Output_<AAAAMMDD>/Diagnostico)")
    args = parser.parse_args(argv)

    salida = Path(args.salida) if args.salida else Path(f"Output_{date.today():%Y%m%d}") / "Diagnostico"

    preparadas = []
    for cat, nombre in QUERIES.items():
        ruta = QUERIES_DIR / nombre
        if not ruta.is_file():
            print(f"ERROR: no se encontro {ruta}. No se genero ninguna query.")
            return 1
        texto, encoding = _leer(ruta)
        try:
            nuevo, fecha_anterior = preparar_query(texto, args.fecha_inicio, nombre)
        except ValueError as e:
            print(f"ERROR: {e} No se genero ninguna query.")
            return 1
        preparadas.append((cat, nombre, nuevo, encoding, fecha_anterior))

    salida.mkdir(parents=True, exist_ok=True)
    for cat, nombre, nuevo, encoding, _ in preparadas:
        with open(salida / nombre, "w", encoding=encoding, newline="") as f:
            f.write(nuevo)

    fecha_str = args.fecha_inicio.strftime("%Y-%m-%d %H:%M:%S")
    print(f"Listo. Queries (solo lectura) con @fechaCreacion = '{fecha_str}' en: {salida.resolve()}")
    for cat, nombre, _, _, fecha_anterior in preparadas:
        print(f"  {nombre:<32} {cat:<22} antes: {fecha_anterior}")
    print()
    print("Siguiente paso: ejecuta las 4 en SSMS, copia la pestana Messages de cada una a un")
    print("mismo .txt y corre: python generar_reporte_tarifas.py <archivo.txt>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
