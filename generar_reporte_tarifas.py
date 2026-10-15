"""
generar_reporte_tarifas.py

Automatiza lo que hoy se hace a mano:
  1. Toma el texto que arrojan las 4 consultas de tarifas (Aduana, Carga Suelta,
     Contenedor, Servicios Adicionales) tal como se pega desde SSMS.
  2. Genera Resumen_tarifas.xlsx: una hoja "Resumen general" (una fila por
     categoria) + una hoja por categoria con la lista de tarifas ELEGIBLES y la
     observacion que trae cada linea (Estado=1-Inactivo, No_intentos, etc.).
  3. Genera los .sql de actualizacion (UPDATE) en <salida>/Update/, uno por
     categoria con tarifas elegibles.
  4. Genera la version "lite" de esos UPDATE en <salida>/update_lite/ (un solo
     UPDATE ... WHERE Name IN (...), sin transaccion ni tabla variable).
  5. Genera los .sql de consulta/verificacion post-regularizacion en
     <salida>/Queries/, uno por categoria con tarifas elegibles.

USO:
    python generar_reporte_tarifas.py <archivo_entrada.txt> [carpeta_salida]
                                      [--fecha AAAA-MM-DD] [--forzar]

    carpeta_salida  Opcional. Por defecto Output_<AAAAMMDD> (fecha de la corrida).
    --fecha         Fecha a usar en encabezados y mensajes (por defecto hoy). Sirve
                    para regenerar exactamente la salida de una corrida anterior.
    --forzar        Genera los .sql aunque haya ADVERTENCIAS (no recomendado).

Ejemplo:
    python generar_reporte_tarifas.py entrada.txt

Codigos de salida: 0 = OK, 1 = hubo advertencias o errores y NO se generaron
los .sql (el Excel si se genera, para poder revisar), 2 = argumentos invalidos.

SUPUESTOS DE FORMATO (si el texto de SSMS cambia, el script lo detecta y NO
genera los .sql -- revisar SIEMPRE el bloque "ADVERTENCIA" que imprime):
  - NO se depende de encabezados de categoria ("Aduana", "Contenedor", etc.)
    porque la salida real de SSMS no siempre los trae, ni en el mismo orden.
  - Un "bloque" = las lineas [ELEGIBLE]/(ninguna) seguidas de UNA linea
    "Resumen -> etiqueta: valor | etiqueta: valor". Se esperan 4 bloques,
    uno por categoria, en cualquier orden.
  - La categoria de un bloque se deduce del prefijo de sus codigos
    (DTYT/DCCS/DCCO/DCSA). Si el bloque no tiene codigos (ej. "(ninguna)"),
    se asigna por eliminacion contra las categorias que ya se identificaron
    en otros bloques. Si eso tampoco alcanza a resolverlo, el bloque queda
    marcado SIN_IDENTIFICAR y el script avisa para revision manual -- nunca
    adivina en silencio.
  - Las lineas de tarifa elegible empiezan con "[ELEGIBLE] <PREFIJO>_<...>".
    Todo codigo debe cumplir <PREFIJO>_<numero>_<anio>; si alguno no lo cumple
    no se genera ningun .sql, ni siquiera con --forzar.
  - Si una categoria tiene 0 tarifas elegibles, no se generan sus .sql (ni
    Update ni Queries) -- solo queda su hoja en el Excel, indicando "sin
    tarifas elegibles en esta corrida".
  - Antes de escribir, se borran los script_*.sql de una corrida anterior en la
    misma carpeta de salida, para que nunca quede un UPDATE viejo junto al nuevo.

Las plantillas SQL (Update, update_lite y Queries) NO estan embebidas en este
archivo: viven como .sql sueltos en la carpeta templates/, junto a este script.
Si clonaste el repo, ya deberian estar ahi. Si copiaste solo este .py a otro
lado, el script va a fallar con un error claro indicando que falta la
carpeta templates/.
"""

import argparse
import re
import sys
from datetime import date, datetime
from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.utils import get_column_letter

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

CATEGORIAS = {
    "Aduana": "DTYT",
    "Carga Suelta": "DCCS",
    "Contenedor": "DCCO",
    "Servicios Adicionales": "DCSA",
}
PREFIJO_A_CATEGORIA = {v: k for k, v in CATEGORIAS.items()}

ELEGIBLE_RE = re.compile(r"^\s*\[ELEGIBLE\]\s+(\S+)\s*(.*?)\s*$")
RESUMEN_RE = re.compile(r"^\s*Resumen\s*->\s*(.+)$")
CODIGO_VALIDO_RE = re.compile(r"^(%s)_\d+_\d{4}$" % "|".join(CATEGORIAS.values()))

COLUMNA_CONTROL = "Tarifas parseadas (control)"


def leer_entrada(ruta: Path) -> str:
    """Lee el .txt de entrada sin importar como lo guardo SSMS/Notepad: UTF-16
    (con BOM, lo que SSMS llama "Unicode"), UTF-8 con o sin BOM, o ANSI."""
    datos = ruta.read_bytes()
    if datos.startswith((b"\xff\xfe", b"\xfe\xff")):
        return datos.decode("utf-16")
    for encoding in ("utf-8-sig", "cp1252"):
        try:
            return datos.decode(encoding)
        except UnicodeDecodeError:
            continue
    return datos.decode("latin-1")


def _bloque_vacio():
    return {"codigos": [], "observaciones": [], "resumen": {}}


def _dividir_en_bloques(texto: str):
    """Un bloque = codigos acumulados hasta la siguiente linea 'Resumen ->'."""
    bloques = []
    actual = _bloque_vacio()

    for linea in texto.splitlines():
        m_eleg = ELEGIBLE_RE.match(linea)
        if m_eleg:
            actual["codigos"].append(m_eleg.group(1))
            actual["observaciones"].append(m_eleg.group(2))
            continue

        m_res = RESUMEN_RE.match(linea)
        if m_res:
            for parte in [p.strip() for p in m_res.group(1).split("|")]:
                if ":" not in parte:
                    continue
                etiqueta, valor = parte.split(":", 1)
                actual["resumen"][etiqueta.strip()] = valor.strip()
            bloques.append(actual)
            actual = _bloque_vacio()

    if actual["codigos"]:
        bloques.append(actual)  # codigos sin su linea 'Resumen ->': validar() lo reporta

    return bloques


def parsear(texto: str):
    """Devuelve dict categoria -> {codigos, observaciones, resumen}.
    Tambien devuelve la lista de avisos a mostrar al usuario."""
    bloques = _dividir_en_bloques(texto)
    avisos = []

    if len(bloques) != len(CATEGORIAS):
        avisos.append(
            f"Se esperaban {len(CATEGORIAS)} bloques (uno por categoria) y se "
            f"encontraron {len(bloques)}. Revisa el archivo de entrada: puede "
            f"faltar o sobrar una linea 'Resumen ->'."
        )

    resultado = {cat: _bloque_vacio() for cat in CATEGORIAS}
    sin_identificar = []

    # Paso 1: bloques con codigos -> categoria por prefijo (sin ambiguedad).
    bloques_pendientes = []
    for bloque in bloques:
        if bloque["codigos"]:
            prefijo = bloque["codigos"][0].split("_")[0]
            categoria = PREFIJO_A_CATEGORIA.get(prefijo)
            if categoria is None:
                avisos.append(
                    f"Prefijo desconocido '{prefijo}' en un bloque con "
                    f"{len(bloque['codigos'])} codigos -- no se pudo asignar categoria."
                )
                sin_identificar.append(bloque)
                continue
            if resultado[categoria]["codigos"] or resultado[categoria]["resumen"]:
                avisos.append(
                    f"Dos bloques distintos parecen ser de '{categoria}' (prefijo "
                    f"{prefijo}). Se conserva solo el primero -- revisa el archivo."
                )
                continue
            resultado[categoria] = bloque
        else:
            bloques_pendientes.append(bloque)

    # Paso 2: bloques sin codigos -> por eliminacion contra lo ya asignado.
    categorias_asignadas = {c for c in CATEGORIAS if resultado[c]["resumen"] or resultado[c]["codigos"]}
    categorias_libres = [c for c in CATEGORIAS if c not in categorias_asignadas]

    if len(bloques_pendientes) == len(categorias_libres):
        for bloque, categoria in zip(bloques_pendientes, categorias_libres):
            resultado[categoria] = bloque
    else:
        for bloque in bloques_pendientes:
            sin_identificar.append(bloque)
        if bloques_pendientes:
            avisos.append(
                f"No se pudo asignar categoria por eliminacion a "
                f"{len(bloques_pendientes)} bloque(s) sin codigos "
                f"(quedaban {len(categorias_libres)} categoria(s) libres: "
                f"{', '.join(categorias_libres) or 'ninguna'}). Revisa manualmente "
                f"estos resumenes: "
                + " || ".join(str(b["resumen"]) for b in bloques_pendientes)
            )

    return resultado, avisos


def validar(resultado: dict):
    """Chequeos sobre lo parseado:
      - cantidad de codigos vs 'Elegibles para UPDATE' del propio resumen,
      - todos los codigos de una categoria con su prefijo y formato valido,
      - sin codigos repetidos (romperian la PRIMARY KEY de @Tarifas en el UPDATE).
    Cualquier problema impide generar los .sql (salvo --forzar)."""
    problemas = []
    for cat, data in resultado.items():
        prefijo = CATEGORIAS[cat]
        codigos = data["codigos"]

        invalidos = [c for c in codigos if not CODIGO_VALIDO_RE.match(c) or not c.startswith(prefijo + "_")]
        if invalidos:
            problemas.append(
                f"{cat}: {len(invalidos)} codigo(s) con formato invalido o de otra categoria "
                f"(se esperaba {prefijo}_<numero>_<anio>): {', '.join(invalidos[:10])}"
            )

        repetidos = sorted({c for c in codigos if codigos.count(c) > 1})
        if repetidos:
            problemas.append(f"{cat}: codigos repetidos en la entrada: {', '.join(repetidos)}")

        resumen = data["resumen"]
        clave_elegibles = next(
            (k for k in resumen if k.lower().startswith("elegibles para update")), None
        )
        if clave_elegibles is None:
            problemas.append(f"{cat}: no se encontro la linea Resumen -> se omite validacion de conteo")
            continue
        m_num = re.match(r"\s*(\d+)", resumen[clave_elegibles])  # solo el numero inicial
        esperado = int(m_num.group(1)) if m_num else None
        obtenido = len(codigos)
        if esperado is None:
            problemas.append(f"{cat}: 'Elegibles para UPDATE' no trae un numero: {resumen[clave_elegibles]!r}")
        elif esperado != obtenido:
            problemas.append(
                f"{cat}: Resumen dice {esperado} elegibles, se parsearon {obtenido} codigos [ELEGIBLE]"
            )
    return problemas


def _a_numero(valor: str):
    """'75' -> 75 (para que Excel lo trate como numero); el resto queda como texto."""
    return int(valor) if re.fullmatch(r"\d+", valor) else valor


def construir_tabla_resumen(resultado: dict):
    """Devuelve (columnas, filas) para la hoja 'Resumen general'. Columnas:
    Categoria/Prefijo primero, control al final y el resto en el orden en que
    fueron apareciendo (evita perder columnas que solo existen en una categoria,
    p.ej. Caso1/Caso2/Caso3 de Servicios Adicionales)."""
    columnas = ["Categoria", "Prefijo"]
    filas = []
    for cat, prefijo in CATEGORIAS.items():
        fila = {"Categoria": cat, "Prefijo": prefijo}
        for etiqueta, valor in resultado[cat]["resumen"].items():
            fila[etiqueta] = _a_numero(valor)
            if etiqueta not in columnas:
                columnas.append(etiqueta)
        fila[COLUMNA_CONTROL] = len(resultado[cat]["codigos"])
        filas.append(fila)
    columnas.append(COLUMNA_CONTROL)
    return columnas, filas


_FUENTE_HEADER = dict(name="Arial", bold=True, color="FFFFFF")
_RELLENO_HEADER = PatternFill("solid", fgColor="305496")


def _escribir_hoja_resumen_general(wb: Workbook, columnas: list, filas: list, fecha_corrida: str):
    ws = wb.active
    ws.title = "Resumen general"

    ws["A1"] = "Resumen de actualizacion de tarifas"
    ws["A1"].font = Font(name="Arial", size=14, bold=True)
    ws["A2"] = f"Corrida: {fecha_corrida}"
    ws["A2"].font = Font(name="Arial", italic=True, size=10)

    fila_header = 4
    for j, col in enumerate(columnas, start=1):
        c = ws.cell(row=fila_header, column=j, value=col)
        c.font = Font(**_FUENTE_HEADER)
        c.fill = _RELLENO_HEADER
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for i, fila in enumerate(filas, start=1):
        for j, col in enumerate(columnas, start=1):
            celda = ws.cell(row=fila_header + i, column=j, value=fila.get(col))
            celda.font = Font(name="Arial", size=10)
            if col not in ("Categoria", "Prefijo"):
                celda.alignment = Alignment(horizontal="center")

    for j, col in enumerate(columnas, start=1):
        largo = max(len(str(col)), *(len(str(f.get(col, ""))) for f in filas))
        ws.column_dimensions[get_column_letter(j)].width = min(largo + 3, 40)

    ws.freeze_panes = f"A{fila_header + 1}"


_NOMBRE_HOJA_INVALIDO = re.compile(r"[\\/*?:\[\]]")


def _nombre_hoja(cat: str) -> str:
    # Excel: max 31 caracteres, sin \ / * ? : [ ]
    return _NOMBRE_HOJA_INVALIDO.sub("-", cat)[:31]


def _escribir_hoja_categoria(wb: Workbook, cat: str, codigos: list, observaciones: list):
    ws = wb.create_sheet(title=_nombre_hoja(cat))

    ws["A1"] = f"Tarifas elegibles - {cat}"
    ws["A1"].font = Font(name="Arial", size=12, bold=True)
    ws["A2"] = f"Total: {len(codigos)}"
    ws["A2"].font = Font(name="Arial", italic=True, size=10)

    fila_header = 4
    for j, titulo in enumerate(("Codigo tarifa", "Observacion"), start=1):
        c = ws.cell(row=fila_header, column=j, value=titulo)
        c.font = Font(**_FUENTE_HEADER)
        c.fill = _RELLENO_HEADER

    if not codigos:
        ws.cell(row=fila_header + 1, column=1, value="-- sin tarifas elegibles en esta corrida --").font = (
            Font(name="Arial", italic=True, size=10)
        )
    else:
        for i, (codigo, obs) in enumerate(zip(codigos, observaciones), start=1):
            ws.cell(row=fila_header + i, column=1, value=codigo).font = Font(name="Arial", size=10)
            ws.cell(row=fila_header + i, column=2, value=obs or None).font = Font(name="Arial", size=10)

    largo = max(len("Codigo tarifa"), *(len(c) for c in codigos)) if codigos else len("Codigo tarifa")
    ws.column_dimensions["A"].width = min(largo + 3, 40)
    largo_obs = max([len("Observacion"), *(len(o) for o in observaciones)])
    ws.column_dimensions["B"].width = min(largo_obs + 3, 100)
    ws.freeze_panes = f"A{fila_header + 1}"


def escribir_excel(resultado: dict, columnas: list, filas: list, ruta_excel: Path, fecha_corrida: str):
    wb = Workbook()
    _escribir_hoja_resumen_general(wb, columnas, filas, fecha_corrida)
    for cat in CATEGORIAS:
        _escribir_hoja_categoria(wb, cat, resultado[cat]["codigos"], resultado[cat]["observaciones"])
    wb.save(ruta_excel)


# ---------------------------------------------------------------------------
# Scripts SQL por categoria: UPDATE (Update/), UPDATE lite (update_lite/) y
# CONSULTA de verificacion post-regularizacion (Queries/).
#
# Las plantillas NO estan embebidas aqui: viven como archivos .sql sueltos
# en templates/ (junto a este script), para poder versionarlas y editarlas
# sin tocar el .py. Placeholders:
#   {HEADER}            -> comentario armado en runtime (fecha + cantidad de
#                           tarifas elegibles).
#   {FECHA_COMPACTA}    -> solo en update_lite_*: AAAAMMDD para ProcesadoMensaje.
#   (<lista_tarifas>)   -> en update_*: bloque ('COD1'), ('COD2'), ...
#   <lista_tarifas_in>  -> en update_lite_*: bloque 'COD1', 'COD2', ... de un IN.
#   <lista_tarifas_XXX> -> en consulta_*: bloque 'COD1', 'COD2', ... de un IN.
#
# Si una plantilla no trae el placeholder esperado, o si tras reemplazar queda
# alguno sin reemplazar, el script se detiene sin escribir ningun .sql.
#
# Si una categoria queda con 0 tarifas elegibles, NO se genera su .sql (en
# ningun tipo): un UPDATE con @Tarifas vacia no aporta nada, y un
# WHERE ... IN () con lista vacia es directamente SQL invalido.
# ---------------------------------------------------------------------------

SUBCARPETAS_SQL = ("Update", "update_lite", "Queries")

PLACEHOLDER_CONSULTA = {
    "Aduana": "<lista_tarifas_aduana>",
    "Carga Suelta": "<lista_tarifas_CargaSuelta>",
    "Contenedor": "<lista_tarifas_Contenedor>",
    "Servicios Adicionales": "<lista_tarifas_ServiciosAdicionales>",
}

_PLACEHOLDER_PENDIENTE_RE = re.compile(r"<lista_tarifas[^>]*>|\{HEADER\}|\{FECHA_COMPACTA\}")


def _cargar_plantilla(nombre_archivo: str) -> str:
    ruta = TEMPLATES_DIR / nombre_archivo
    try:
        return ruta.read_text(encoding="utf-8")
    except FileNotFoundError as e:
        raise FileNotFoundError(
            f"No se encontro la plantilla '{nombre_archivo}' en {TEMPLATES_DIR}. "
            f"Verifica que la carpeta 'templates/' este junto a este script "
            f"(si clonaste el repo, deberia venir incluida)."
        ) from e


def _reemplazar(contenido: str, placeholder: str, valor: str, nombre_plantilla: str) -> str:
    if placeholder not in contenido:
        raise ValueError(
            f"La plantilla '{nombre_plantilla}' no contiene el placeholder {placeholder!r} "
            f"(revisa que no se haya editado o re-indentado)."
        )
    return contenido.replace(placeholder, valor)


def _bloque_lista_tarifas_sql(codigos: list) -> str:
    lineas = [f"    ('{c}')," for c in codigos[:-1]]
    lineas.append(f"    ('{codigos[-1]}');")
    return "\n".join(lineas)


def _bloque_lista_in(codigos: list) -> str:
    """Lista para un WHERE ... IN (...): 'COD1',\n        'COD2', ... (sin
    parentesis extra por item, a diferencia del INSERT de los .sql de UPDATE)."""
    lineas = [f"'{c}'," for c in codigos[:-1]]
    lineas.append(f"'{codigos[-1]}'")
    return "\n        ".join(lineas)


def _bloque_lista_lite(codigos: list) -> str:
    lineas = [f"    '{c}'," for c in codigos[:-1]]
    lineas.append(f"    '{codigos[-1]}'")
    return "\n".join(lineas)


def _tipos_script(fecha: date):
    fecha_str = fecha.strftime("%d/%m/%Y")

    def header_update(cat, cantidad):
        return f"/* Ejecucion: {fecha_str} | Tarifas a regularizar: {cantidad} */"

    def header_consulta(cat, cantidad):
        return (
            f"/* Consulta post-regularizacion ({fecha_str}) - Tarifas {cat} : {cantidad} */\n"
            f"/* Verifica el estado actual (0, 1 o 2) tras el paso por el Job. Debe quedar ProcesadoEstado = 1 */"
        )

    return [
        {
            "nombre": "UPDATE", "subcarpeta": "Update", "prefijo_archivo": "script_Regularizacion",
            "plantilla": "update_{prefijo}.sql", "header": header_update,
            "placeholder": {cat: "    (<lista_tarifas>);" for cat in CATEGORIAS},
            "bloque": _bloque_lista_tarifas_sql, "extra": {},
        },
        {
            "nombre": "UPDATE lite", "subcarpeta": "update_lite", "prefijo_archivo": "script_Regularizacion",
            "plantilla": "update_lite_{prefijo}.sql", "header": header_update,
            "placeholder": {cat: "<lista_tarifas_in>" for cat in CATEGORIAS},
            "bloque": _bloque_lista_lite, "extra": {"{FECHA_COMPACTA}": fecha.strftime("%Y%m%d")},
        },
        {
            "nombre": "consulta", "subcarpeta": "Queries", "prefijo_archivo": "script_consulta",
            "plantilla": "consulta_{prefijo}.sql", "header": header_consulta,
            "placeholder": PLACEHOLDER_CONSULTA,
            "bloque": _bloque_lista_in, "extra": {},
        },
    ]


def construir_scripts_sql(resultado: dict, fecha: date):
    """Arma en memoria todos los .sql (sin escribir nada). Devuelve una lista de
    dicts {tipo, subcarpeta, archivo, cat, prefijo, cantidad, contenido} y un dict
    tipo -> categorias omitidas por tener 0 elegibles. Lanza ValueError si algun
    codigo no es valido o si una plantilla no calza, para no escribir .sql a medias."""
    scripts = []
    omitidos = {}

    for tipo in _tipos_script(fecha):
        omitidos[tipo["nombre"]] = []
        for cat, prefijo in CATEGORIAS.items():
            codigos = resultado[cat]["codigos"]
            if not codigos:
                omitidos[tipo["nombre"]].append(cat)
                continue

            invalidos = [c for c in codigos if not CODIGO_VALIDO_RE.match(c) or not c.startswith(prefijo + "_")]
            if invalidos:
                raise ValueError(
                    f"{cat}: codigos invalidos, no se generan .sql ni con --forzar: {', '.join(invalidos[:10])}"
                )

            nombre_plantilla = tipo["plantilla"].format(prefijo=prefijo)
            contenido = _cargar_plantilla(nombre_plantilla)
            contenido = _reemplazar(contenido, "{HEADER}", tipo["header"](cat, len(codigos)), nombre_plantilla)
            for placeholder, valor in tipo["extra"].items():
                contenido = _reemplazar(contenido, placeholder, valor, nombre_plantilla)
            contenido = _reemplazar(contenido, tipo["placeholder"][cat], tipo["bloque"](codigos), nombre_plantilla)

            pendiente = _PLACEHOLDER_PENDIENTE_RE.search(contenido)
            if pendiente:
                raise ValueError(
                    f"La plantilla '{nombre_plantilla}' quedo con el placeholder {pendiente.group(0)!r} sin reemplazar."
                )

            scripts.append({
                "tipo": tipo["nombre"], "subcarpeta": tipo["subcarpeta"],
                "archivo": f"{tipo['prefijo_archivo']}_{prefijo}.sql",
                "cat": cat, "prefijo": prefijo, "cantidad": len(codigos), "contenido": contenido,
            })

    return scripts, omitidos


def limpiar_salida_anterior(carpeta_salida: Path):
    """Borra los script_*.sql que haya dejado una corrida anterior en la misma
    carpeta, para que nunca convivan un UPDATE viejo y uno nuevo."""
    borrados = []
    for subcarpeta in SUBCARPETAS_SQL:
        for archivo in sorted((carpeta_salida / subcarpeta).glob("script_*.sql")):
            archivo.unlink()
            borrados.append(archivo.relative_to(carpeta_salida))
    return borrados


def escribir_scripts_sql(scripts: list, carpeta_salida: Path):
    for s in scripts:
        carpeta = carpeta_salida / s["subcarpeta"]
        carpeta.mkdir(parents=True, exist_ok=True)
        (carpeta / s["archivo"]).write_text(s["contenido"], encoding="utf-8")


def _fecha_argumento(valor: str) -> date:
    try:
        return datetime.strptime(valor, "%Y-%m-%d").date()
    except ValueError:
        raise argparse.ArgumentTypeError(f"fecha invalida {valor!r}, usa AAAA-MM-DD")


def _parsear_argumentos(argv):
    parser = argparse.ArgumentParser(
        description="Genera el Excel de resumen y los .sql de regularizacion de tarifas "
                    "a partir de la salida de SSMS."
    )
    parser.add_argument("entrada", help="archivo .txt con la salida de las 4 consultas de SSMS")
    parser.add_argument("salida", nargs="?", help="carpeta de salida (por defecto Output_<AAAAMMDD>)")
    parser.add_argument("--fecha", type=_fecha_argumento, default=None,
                        help="fecha de la corrida AAAA-MM-DD (por defecto hoy)")
    parser.add_argument("--forzar", action="store_true",
                        help="genera los .sql aunque haya advertencias (no recomendado)")
    return parser.parse_args(argv)


def main(argv=None):
    args = _parsear_argumentos(argv)
    fecha = args.fecha or date.today()
    entrada = Path(args.entrada)
    salida = Path(args.salida) if args.salida else Path(f"Output_{fecha:%Y%m%d}")

    if not entrada.is_file():
        print(f"ERROR: no existe el archivo de entrada '{entrada}'.")
        return 1

    texto = leer_entrada(entrada)
    resultado, avisos = parsear(texto)

    problemas = avisos + validar(resultado)
    if problemas:
        print("ADVERTENCIA - revisar antes de usar el resultado:")
        for p in problemas:
            print(f"- {p}")
        print()

    generar_sql = not problemas or args.forzar
    scripts, omitidos = [], {}
    if generar_sql:
        try:
            scripts, omitidos = construir_scripts_sql(resultado, fecha)
        except (ValueError, FileNotFoundError) as e:
            print(f"ERROR: {e}")
            print("No se genero ningun archivo.")
            return 1

    salida.mkdir(parents=True, exist_ok=True)
    borrados = limpiar_salida_anterior(salida)

    columnas, filas = construir_tabla_resumen(resultado)
    ruta_excel = salida / "Resumen_tarifas.xlsx"
    try:
        escribir_excel(resultado, columnas, filas, ruta_excel, fecha.isoformat())
    except PermissionError:
        print(f"ERROR: no se pudo escribir '{ruta_excel}'. Cierralo en Excel y vuelve a correr el script.")
        return 1

    escribir_scripts_sql(scripts, salida)

    print(f"Listo. Archivos generados en: {salida.resolve()}")
    if borrados:
        print(f"  (se borraron {len(borrados)} .sql de una corrida anterior en esa carpeta)")
    for cat in CATEGORIAS:
        print(f"  ({cat}: {len(resultado[cat]['codigos'])} tarifas elegibles -> hoja '{_nombre_hoja(cat)}' en el Excel)")
    print("  Resumen_tarifas.xlsx (hoja 'Resumen general' + una hoja por categoria)")

    if not generar_sql:
        print()
        print("NO se generaron los .sql porque hay ADVERTENCIAS. Corrige el archivo de entrada")
        print("y vuelve a correr el script (o usa --forzar si revisaste y estas seguro).")
        return 1

    for tipo, omitidas in omitidos.items():
        for s in (s for s in scripts if s["tipo"] == tipo):
            print(f"  {s['subcarpeta']}\\{s['archivo']} -> {s['cantidad']} tarifas ({s['cat']})")
        if omitidas:
            print(f"  (sin script de {tipo}, 0 tarifas elegibles: {', '.join(omitidas)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
