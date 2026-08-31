"""
generar_reporte_tarifas.py

Automatiza lo que hoy se hace a mano:
  1. Toma el texto que arrojan las 4 consultas de tarifas (Aduana, Carga Suelta,
     Contenedor, Servicios Adicionales) tal como se pega desde SSMS.
  2. Genera Resumen_tarifas.xlsx: una hoja "Resumen general" (una fila por
     categoria) + una hoja por categoria con la lista de tarifas ELEGIBLES.
  3. Genera los .sql de actualizacion (UPDATE) en <salida>/Update/, uno por
     categoria con tarifas elegibles.
  4. Genera los .sql de consulta/verificacion post-regularizacion en
     <salida>/Queries/, uno por categoria con tarifas elegibles.

USO:
    python generar_reporte_tarifas.py <archivo_entrada.txt> <carpeta_salida>

Ejemplo:
    python generar_reporte_tarifas.py entrada.txt Output

SUPUESTOS DE FORMATO (si el texto de SSMS cambia, esto puede fallar en
silencio o mal-contar -- revisar SIEMPRE el mensaje "ADVERTENCIA" que
imprime el script y el conteo de codigos contra el Resumen antes de usar
el resultado a ciegas):
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
  - Las lineas de tarifa elegible empiezan con "[ELEGIBLE] <PREFIJO>_<...>"
  - Si una categoria tiene 0 tarifas elegibles, no se generan sus .sql (ni
    Update ni Queries) -- solo queda su hoja en el Excel, indicando "sin
    tarifas elegibles en esta corrida".

Las plantillas SQL (Update y Queries) NO estan embebidas en este archivo:
viven como .sql sueltos en la carpeta templates/, junto a este script. Si
clonaste el repo, ya deberian estar ahi. Si copiaste solo este .py a otro
lado, el script va a fallar con un error claro indicando que falta la
carpeta templates/.
"""

import re
import sys
from datetime import date
from pathlib import Path

import pandas as pd
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

ELEGIBLE_RE = re.compile(r"^\s*\[ELEGIBLE\]\s+(\S+)")
RESUMEN_RE = re.compile(r"^\s*Resumen\s*->\s*(.+)$")


def _dividir_en_bloques(texto: str):
    """Un bloque = codigos acumulados hasta la siguiente linea 'Resumen ->'."""
    bloques = []
    codigos_actuales = []

    for linea in texto.splitlines():
        m_eleg = ELEGIBLE_RE.match(linea)
        if m_eleg:
            codigos_actuales.append(m_eleg.group(1))
            continue

        m_res = RESUMEN_RE.match(linea)
        if m_res:
            resumen = {}
            for parte in [p.strip() for p in m_res.group(1).split("|")]:
                if ":" not in parte:
                    continue
                etiqueta, valor = parte.split(":", 1)
                resumen[etiqueta.strip()] = valor.strip()
            bloques.append({"codigos": codigos_actuales, "resumen": resumen})
            codigos_actuales = []

    return bloques


def parsear(texto: str):
    """Devuelve dict categoria -> {codigos: [...], resumen: {etiqueta: valor}}.
    Tambien devuelve la lista de avisos a mostrar al usuario."""
    bloques = _dividir_en_bloques(texto)
    avisos = []

    if len(bloques) != len(CATEGORIAS):
        avisos.append(
            f"Se esperaban {len(CATEGORIAS)} bloques (uno por categoria) y se "
            f"encontraron {len(bloques)}. Revisa el archivo de entrada: puede "
            f"faltar o sobrar una linea 'Resumen ->'."
        )

    resultado = {cat: {"codigos": [], "resumen": {}} for cat in CATEGORIAS}
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
    categorias_asignadas = {c for c in CATEGORIAS if resultado[c]["resumen"]}
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
    """Chequeo cruzado: cantidad de codigos parseados vs 'Elegibles para UPDATE'
    del propio resumen. Si no calzan, algo del formato no se parseo bien."""
    problemas = []
    for cat, data in resultado.items():
        resumen = data["resumen"]
        clave_elegibles = next(
            (k for k in resumen if k.lower().startswith("elegibles para update")), None
        )
        if clave_elegibles is None:
            problemas.append(f"{cat}: no se encontro la linea Resumen -> se omite validacion")
            continue
        m_num = re.match(r"\s*(\d+)", resumen[clave_elegibles])  # solo el numero inicial
        esperado = int(m_num.group(1)) if m_num else None
        obtenido = len(data["codigos"])
        if esperado is not None and esperado != obtenido:
            problemas.append(
                f"{cat}: Resumen dice {esperado} elegibles, se parsearon {obtenido} codigos [ELEGIBLE]"
            )
    return problemas


def construir_tabla_resumen(resultado: dict) -> pd.DataFrame:
    filas = []
    for cat, prefijo in CATEGORIAS.items():
        fila = {"Categoria": cat, "Prefijo": prefijo}
        fila.update(resultado[cat]["resumen"])
        fila["Tarifas parseadas (control)"] = len(resultado[cat]["codigos"])
        filas.append(fila)
    df = pd.DataFrame(filas)
    # Ordena columnas: Categoria/Prefijo primero, control al final, el resto en
    # el orden en que fueron apareciendo (evita perder columnas que solo
    # existen en una categoria, p.ej. Caso1/Caso2/Caso3 de Servicios Adicionales)
    fijas_inicio = ["Categoria", "Prefijo"]
    fijas_fin = ["Tarifas parseadas (control)"]
    resto = [c for c in df.columns if c not in fijas_inicio + fijas_fin]
    return df[fijas_inicio + resto + fijas_fin]


def _escribir_hoja_resumen_general(wb: Workbook, df: pd.DataFrame, fecha_corrida: str):
    ws = wb.active
    ws.title = "Resumen general"

    ws["A1"] = "Resumen de actualizacion de tarifas"
    ws["A1"].font = Font(name="Arial", size=14, bold=True)
    ws["A2"] = f"Corrida: {fecha_corrida}"
    ws["A2"].font = Font(name="Arial", italic=True, size=10)

    fila_header = 4
    for j, col in enumerate(df.columns, start=1):
        c = ws.cell(row=fila_header, column=j, value=col)
        c.font = Font(name="Arial", bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor="305496")
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for i, (_, fila) in enumerate(df.iterrows(), start=1):
        for j, col in enumerate(df.columns, start=1):
            valor = fila[col]
            celda = ws.cell(row=fila_header + i, column=j, value=(None if pd.isna(valor) else valor))
            celda.font = Font(name="Arial", size=10)
            if col not in ("Categoria", "Prefijo"):
                celda.alignment = Alignment(horizontal="center")

    for j, col in enumerate(df.columns, start=1):
        largo = max(len(str(col)), *(len(str(v)) for v in df[col].astype(str)))
        ws.column_dimensions[get_column_letter(j)].width = min(largo + 3, 40)

    ws.freeze_panes = f"A{fila_header + 1}"


_NOMBRE_HOJA_INVALIDO = re.compile(r"[\\/*?:\[\]]")


def _nombre_hoja(cat: str) -> str:
    # Excel: max 31 caracteres, sin \ / * ? : [ ]
    return _NOMBRE_HOJA_INVALIDO.sub("-", cat)[:31]


def _escribir_hoja_categoria(wb: Workbook, cat: str, codigos: list):
    ws = wb.create_sheet(title=_nombre_hoja(cat))

    ws["A1"] = f"Tarifas elegibles - {cat}"
    ws["A1"].font = Font(name="Arial", size=12, bold=True)
    ws["A2"] = f"Total: {len(codigos)}"
    ws["A2"].font = Font(name="Arial", italic=True, size=10)

    fila_header = 4
    c = ws.cell(row=fila_header, column=1, value="Codigo tarifa")
    c.font = Font(name="Arial", bold=True, color="FFFFFF")
    c.fill = PatternFill("solid", fgColor="305496")

    if not codigos:
        ws.cell(row=fila_header + 1, column=1, value="-- sin tarifas elegibles en esta corrida --").font = (
            Font(name="Arial", italic=True, size=10)
        )
    else:
        for i, codigo in enumerate(codigos, start=1):
            ws.cell(row=fila_header + i, column=1, value=codigo).font = Font(name="Arial", size=10)

    largo = max(len("Codigo tarifa"), *(len(c) for c in codigos)) if codigos else len("Codigo tarifa")
    ws.column_dimensions["A"].width = min(largo + 3, 40)
    ws.freeze_panes = f"A{fila_header + 1}"


def escribir_excel(resultado: dict, df: pd.DataFrame, ruta_excel: Path, fecha_corrida: str):
    wb = Workbook()
    _escribir_hoja_resumen_general(wb, df, fecha_corrida)
    for cat in CATEGORIAS:
        _escribir_hoja_categoria(wb, cat, resultado[cat]["codigos"])
    wb.save(ruta_excel)


# ---------------------------------------------------------------------------
# Scripts SQL de actualizacion (UPDATE) y de CONSULTA (verificacion post-
# regularizacion) por categoria.
#
# Las plantillas NO estan embebidas aqui: viven como archivos .sql sueltos
# en templates/ (junto a este script), para poder versionarlas y editarlas
# sin tocar el .py. Cada plantilla trae dos tipos de placeholder:
#   {HEADER}            -> comentario armado en runtime (fecha del sistema +
#                           cantidad de tarifas elegibles). Igual para las 4
#                           categorias en ambos tipos de script.
#   (<lista_tarifas>)   -> en las de UPDATE: bloque ('COD1'), ('COD2'), ...
#   <lista_tarifas_XXX> -> en las de consulta: bloque 'COD1', 'COD2', ...
#                           (sin parentesis extra, porque es un WHERE ... IN,
#                           no un INSERT).
#
# Si una categoria queda con 0 tarifas elegibles, NO se genera su .sql (en
# ninguno de los dos tipos): un UPDATE con @Tarifas vacia no aporta nada, y
# un WHERE ... IN () con lista vacia es directamente SQL invalido.
# ---------------------------------------------------------------------------

ARCHIVOS_TEMPLATE_UPDATE = {
    "Aduana": "update_DTYT.sql",
    "Carga Suelta": "update_DCCS.sql",
    "Contenedor": "update_DCCO.sql",
    "Servicios Adicionales": "update_DCSA.sql",
}

ARCHIVOS_TEMPLATE_CONSULTA = {
    "Aduana": "consulta_DTYT.sql",
    "Carga Suelta": "consulta_DCCS.sql",
    "Contenedor": "consulta_DCCO.sql",
    "Servicios Adicionales": "consulta_DCSA.sql",
}

PLACEHOLDER_UPDATE = {cat: "    (<lista_tarifas>);" for cat in CATEGORIAS}

PLACEHOLDER_CONSULTA = {
    "Aduana": "<lista_tarifas_aduana>",
    "Carga Suelta": "<lista_tarifas_CargaSuelta>",
    "Contenedor": "<lista_tarifas_Contenedor>",
    "Servicios Adicionales": "<lista_tarifas_ServiciosAdicionales>",
}


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


def _generar_scripts_sql(resultado, carpeta_salida, archivos_template, obtener_placeholder,
                          construir_header, construir_bloque_lista, subcarpeta, prefijo_archivo):
    """Motor comun para generar_sql_updates() y generar_sql_consultas(): carga la
    plantilla .sql de cada categoria desde templates/, arma el .sql final (header +
    lista de tarifas en el placeholder correspondiente) y lo escribe en
    <carpeta_salida>/<subcarpeta>/. Si una categoria tiene 0 tarifas elegibles, no
    genera su archivo."""
    carpeta = carpeta_salida / subcarpeta
    generados = []
    omitidos = []

    for cat, prefijo in CATEGORIAS.items():
        codigos = resultado[cat]["codigos"]
        cantidad = len(codigos)
        if cantidad == 0:
            omitidos.append(cat)
            continue

        contenido = _cargar_plantilla(archivos_template[cat])
        contenido = contenido.replace("{HEADER}", construir_header(cat, cantidad))
        contenido = contenido.replace(obtener_placeholder(cat), construir_bloque_lista(codigos))

        carpeta.mkdir(parents=True, exist_ok=True)
        archivo = carpeta / f"{prefijo_archivo}_{prefijo}.sql"
        archivo.write_text(contenido, encoding="utf-8")
        generados.append((cat, prefijo, cantidad))

    return generados, omitidos


def generar_sql_updates(resultado: dict, carpeta_salida: Path, fecha_ejecucion: date):
    fecha_str = fecha_ejecucion.strftime("%d/%m/%Y")
    return _generar_scripts_sql(
        resultado, carpeta_salida,
        archivos_template=ARCHIVOS_TEMPLATE_UPDATE,
        obtener_placeholder=lambda cat: PLACEHOLDER_UPDATE[cat],
        construir_header=lambda cat, cantidad: f"/* Ejecucion: {fecha_str} | Tarifas a regularizar: {cantidad} */",
        construir_bloque_lista=_bloque_lista_tarifas_sql,
        subcarpeta="Update",
        prefijo_archivo="script_Regularizacion",
    )


def generar_sql_consultas(resultado: dict, carpeta_salida: Path, fecha_ejecucion: date):
    fecha_str = fecha_ejecucion.strftime("%d/%m/%Y")

    def construir_header(cat, cantidad):
        return (
            f"/* Consulta post-regularizacion ({fecha_str}) - Tarifas {cat} : {cantidad} */\n"
            f"/* Verifica el estado actual (0, 1 o 2) tras el paso por el Job. Debe quedar ProcesadoEstado = 1 */"
        )

    return _generar_scripts_sql(
        resultado, carpeta_salida,
        archivos_template=ARCHIVOS_TEMPLATE_CONSULTA,
        obtener_placeholder=lambda cat: PLACEHOLDER_CONSULTA[cat],
        construir_header=construir_header,
        construir_bloque_lista=_bloque_lista_in,
        subcarpeta="Queries",
        prefijo_archivo="script_consulta",
    )


def main():
    if len(sys.argv) != 3:
        print("Uso: python generar_reporte_tarifas.py <entrada.txt> <carpeta_salida>")
        sys.exit(1)

    entrada = Path(sys.argv[1])
    salida = Path(sys.argv[2])
    salida.mkdir(parents=True, exist_ok=True)

    texto = entrada.read_text(encoding="utf-8")
    resultado, avisos = parsear(texto)

    problemas = avisos + validar(resultado)
    if problemas:
        print("ADVERTENCIA - revisar antes de usar el resultado:")
        for p in problemas:
            print(f"- {p}")
        print()

    df = construir_tabla_resumen(resultado)
    hoy = date.today()
    escribir_excel(resultado, df, salida / "Resumen_tarifas.xlsx", hoy.isoformat())

    generados_update, omitidos_update = generar_sql_updates(resultado, salida, hoy)
    generados_consulta, omitidos_consulta = generar_sql_consultas(resultado, salida, hoy)

    print(f"Listo. Archivos generados en: {salida.resolve()}")
    for cat, prefijo in CATEGORIAS.items():
        print(f"  ({cat}: {len(resultado[cat]['codigos'])} tarifas elegibles -> hoja '{_nombre_hoja(cat)}' en el Excel)")
    print("  Resumen_tarifas.xlsx (hoja 'Resumen general' + una hoja por categoria)")
    for cat, prefijo, cantidad in generados_update:
        print(f"  Update\\script_Regularizacion_{prefijo}.sql -> {cantidad} tarifas ({cat})")
    if omitidos_update:
        print(f"  (sin script de UPDATE, 0 tarifas elegibles: {', '.join(omitidos_update)})")
    for cat, prefijo, cantidad in generados_consulta:
        print(f"  Queries\\script_consulta_{prefijo}.sql -> {cantidad} tarifas ({cat})")
    if omitidos_consulta:
        print(f"  (sin script de consulta, 0 tarifas elegibles: {', '.join(omitidos_consulta)})")


if __name__ == "__main__":
    main()