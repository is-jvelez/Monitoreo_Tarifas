# generar_reporte_tarifas.py

Automatiza el proceso de regularización de tarifas (Aduana, Carga Suelta,
Contenedor, Servicios Adicionales) que quedaron con `ProcesadoEstado = 2`:

1. Parsea el texto que arrojan las 4 consultas de tarifas, tal como se pega
   desde SSMS (no depende de encabezados de categoría ni de un orden fijo).
2. Genera `Resumen_tarifas.xlsx` con una hoja de resumen general (una fila
   por categoría) y una hoja por categoría con la lista de tarifas elegibles
   y su observación (Estado=1-Inactivo, `No_intentos`, ganadora de duplicado…).
3. Genera los `.sql` de **actualización** (`Update/script_Regularizacion_<PREFIJO>.sql`)
   para dejar en `ProcesadoEstado = 0` las tarifas elegibles (con transacción
   y tabla variable).
4. Genera la versión **lite** de esos mismos UPDATE
   (`update_lite/script_Regularizacion_<PREFIJO>.sql`): un único
   `UPDATE ... WHERE Name IN (...)`, sin transacción ni `USE`.
5. Genera los `.sql` de **consulta/verificación post-regularización**
   (`Queries/script_consulta_<PREFIJO>.sql`) para revisar el estado después
   de que corra el Job.

Si una categoría queda con 0 tarifas elegibles en la corrida, no se genera
ninguno de sus `.sql` (un `UPDATE`/`IN (...)` con lista vacía no tiene
sentido o directamente no es SQL válido).

## Medidas de seguridad

- **Si hay cualquier ADVERTENCIA, no se genera ningún `.sql`**: el conteo de
  códigos no coincide con "Elegibles para UPDATE", hay un bloque sin
  identificar, códigos repetidos o de otra categoría, etc. El Excel sí se
  genera para que puedas revisar, y el script termina con código de salida 1.
  Solo con `--forzar` se generan igual (no recomendado).
- **Los códigos se validan** con el formato `<PREFIJO>_<número>_<año>`. Si
  alguno no lo cumple, no se genera ningún `.sql`, ni siquiera con `--forzar`.
- **Se borran los `.sql` de una corrida anterior** (`script_*.sql` dentro de
  `Update/`, `update_lite/` y `Queries/`) antes de escribir. Así no puede
  quedar un UPDATE viejo de una categoría que hoy tiene 0 elegibles.
- **Se verifican las plantillas**: si una plantilla no trae su placeholder
  (por ejemplo, porque alguien la re-indentó) o queda alguno sin reemplazar,
  el script se detiene sin escribir nada.

## Estructura del repositorio

```
preparar_queries.py          <- paso previo: fecha de inicio en las 4 queries
01_QueriesTarifas/           <- queries de diagnostico (script-T*-Regularizacion.sql)
generar_reporte_tarifas.py
templates/
  update_DTYT.sql            <- plantilla del UPDATE de Aduana
  update_DCCS.sql            <- Carga Suelta
  update_DCCO.sql            <- Contenedor
  update_DCSA.sql            <- Servicios Adicionales
  update_lite_DTYT.sql       <- plantilla del UPDATE lite de Aduana
  update_lite_DCCS.sql
  update_lite_DCCO.sql
  update_lite_DCSA.sql
  consulta_DTYT.sql          <- plantilla de la consulta de Aduana
  consulta_DCCS.sql
  consulta_DCCO.sql
  consulta_DCSA.sql
tests/
  test_generar_reporte_tarifas.py
  test_preparar_queries.py
requirements.txt
README.md
```

El script lee cada plantilla desde `templates/` en tiempo de ejecución,
resolviendo la ruta relativa a la ubicación del propio `.py` (no a tu
carpeta de trabajo). Si necesitas editar el SQL de una categoría, edita el
`.sql` correspondiente en `templates/`; no hace falta tocar el `.py`.
Placeholders que deben mantenerse:

| Plantilla | Placeholders |
|---|---|
| `update_*.sql` | `{HEADER}` y la línea `    (<lista_tarifas>);` (con 4 espacios) |
| `update_lite_*.sql` | `{HEADER}`, `{FECHA_COMPACTA}` (AAAAMMDD) y `<lista_tarifas_in>` |
| `consulta_*.sql` | `{HEADER}` y `<lista_tarifas_aduana>` / `_CargaSuelta` / `_Contenedor` / `_ServiciosAdicionales` |

---

## 1. Requisitos

- Python 3.9 o superior (`python --version` para confirmar).
- No necesitas SQL Server ni conexión a base de datos: el script solo
  trabaja sobre el `.txt` de entrada y genera archivos.

## 2. Instalación (una sola vez por máquina/carpeta)

Desde PowerShell, en la carpeta del repo:

```powershell
python -m venv venv
.\venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

La única dependencia es `openpyxl` (ya no se usa `pandas`). Cada vez que
vuelvas a trabajar en el proyecto solo necesitas activar el venv:
`.\venv\Scripts\Activate.ps1`.

## 3. Preparar el archivo de entrada

### 3.1 Poner la misma fecha de inicio en las 4 queries

```powershell
python .\preparar_queries.py "2026-10-14 15:00"
```

Copia los 4 `script-T*-Regularizacion.sql` de `01_QueriesTarifas/` a
`Output_<AAAAMMDD>\Diagnostico\`, con `@fechaCreacion` igual a la fecha
indicada (`AAAA-MM-DD`, `AAAA-MM-DD HH:MM` o `AAAA-MM-DD HH:MM:SS`). Los
originales no se modifican. Muestra la fecha que tenía cada query antes,
para que veas si estaban desalineadas. Con `--salida CARPETA` puedes elegir
otra carpeta.

Las 4 queries son **solo lectura**: identifican las tarifas elegibles e
imprimen el detalle, pero no tienen `UPDATE`, `INSERT`, `DELETE` ni
transacciones (solo usan tablas temporales `#`), así que se pueden ejecutar
en producción sin riesgo. Como resguardo, `preparar_queries.py` revisa cada
query y **no genera ninguna copia** si encuentra una sentencia de escritura
o si falta el `DECLARE @fechaCreacion`. La regularización se hace después,
con los `.sql` de `Update\` o `update_lite\`.

### 3.2 Ejecutarlas y armar el `.txt`

1. Abre en SSMS las 4 queries de `Output_<AAAAMMDD>\Diagnostico\` y ejecútalas.
2. De cada una, copia la pestaña **Messages** completa (Ctrl+A, Ctrl+C) y
   pégala en un único `.txt`, por ejemplo `entrada.txt`. El script solo usa
   las líneas `[ELEGIBLE] ...` y `Resumen -> ...` e ignora el resto. El orden
   entre categorías no importa, y la codificación tampoco (UTF-8, ANSI o
   UTF-16/"Unicode" de SSMS).

## 4. Uso

```powershell
python .\generar_reporte_tarifas.py <archivo_entrada.txt> [carpeta_salida] [--fecha AAAA-MM-DD] [--forzar]
```

- `carpeta_salida` es opcional: por defecto se crea `Output_<AAAAMMDD>` con la
  fecha de la corrida.
- `--fecha` cambia la fecha de los encabezados y de `ProcesadoMensaje` en los
  lite. Sirve para regenerar exactamente una corrida anterior.
- `--forzar` genera los `.sql` aunque haya advertencias.

Ejemplo:

```powershell
python .\generar_reporte_tarifas.py input_full_28_08-06_10_26.txt
```

Resultado:

```
Output_20261015/
  Resumen_tarifas.xlsx
  Update/       script_Regularizacion_<PREFIJO>.sql   (solo categorías con elegibles)
  update_lite/  script_Regularizacion_<PREFIJO>.sql
  Queries/      script_consulta_<PREFIJO>.sql
```

Códigos de salida: `0` = OK, `1` = hubo advertencias/errores y no se
generaron los `.sql`, `2` = argumentos inválidos.

## 5. Tests

```powershell
python -m unittest discover -s tests -v
```

Los tests no necesitan librerías extra (usan `unittest` de Python). Cubren
el parser, la validación, el bloqueo de los `.sql` ante advertencias, la
limpieza de corridas anteriores, la lectura en UTF-16 y la verificación de
plantillas.

## 6. Checklist antes de ejecutar los `.sql` en la base

1. El script terminó sin bloque `ADVERTENCIA`.
2. En `Resumen_tarifas.xlsx`, los conteos de "Resumen general" coinciden con
   lo que mostró SSMS.
3. Revisa a ojo al menos un `.sql` de cada carpeta: el encabezado tiene la
   fecha correcta y el número de tarifas esperado.
4. El script no ejecuta nada en la base: los `.sql` los corres tú en SSMS.

## 7. Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| `ModuleNotFoundError: No module named 'openpyxl'` | Venv no activado o librerías no instaladas | `.\venv\Scripts\Activate.ps1` y `pip install -r requirements.txt` |
| `FileNotFoundError: No se encontro la plantilla '...'` | Moviste el `.py` sin la carpeta `templates/` | Ambos deben estar en la misma carpeta |
| `NO se generaron los .sql porque hay ADVERTENCIAS` | El `.txt` no tiene el formato esperado o los conteos no calzan | Lee las advertencias, corrige el `.txt` y vuelve a correr |
| `ERROR: no se pudo escribir '...Resumen_tarifas.xlsx'` | El Excel está abierto | Ciérralo y vuelve a correr |
| `La plantilla '...' no contiene el placeholder` | Se editó una plantilla y se perdió el placeholder | Restáuralo (ver tabla de placeholders arriba) |
| Una categoría no tiene su `.sql` | Esa categoría dio 0 tarifas elegibles | Comportamiento esperado |
| `FileNotFoundError` al escribir un `.sql` con una ruta muy larga | Windows limita las rutas a 260 caracteres | Usa una carpeta de salida con una ruta más corta |
