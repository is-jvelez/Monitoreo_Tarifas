# Monitoreo y regularización de tarifas (Zoho CRM → Dobra)

Herramienta para **encontrar las tarifas que quedaron trabadas en la
sincronización Zoho CRM → Dobra y generar los scripts que las liberan**,
junto con un reporte en Excel y las consultas para verificar el resultado.

---

## 1. ¿Para qué sirve? (finalidad)

Las tarifas que se crean o modifican en Zoho CRM llegan a la base
`TyT_APICtrl` y un Job las envía a Dobra mediante los SP
`sp_insert_tarifa_*_zoho_dobra`. Si al momento de procesarlas les falta
información (cliente, honorario, ruta, tipo de cotización…), el cliente está
anulado, o el SP las detecta como duplicadas, el SP las marca con
**`ProcesadoEstado = 2` (error)** y **no las vuelve a intentar**.

Con el tiempo esa información se completa en el CRM, pero la tarifa sigue en
estado 2 y nunca llega a Dobra. Hasta ahora, liberarlas era un trabajo
manual: correr consultas, revisar una por una cuáles ya están completas,
armar a mano la lista de códigos y el `UPDATE`, y documentar lo hecho. Era
lento y propenso a errores (códigos de más o de menos, un UPDATE viejo
ejecutado por equivocación, conteos que no cuadraban).

Este proyecto automatiza ese proceso:

1. **Identifica** qué tarifas en estado 2 ya están listas para reprocesarse
   (elegibles) y cuáles no, explicando el motivo.
2. **Genera los `UPDATE`** que devuelven las elegibles a `ProcesadoEstado = 0`
   para que el Job las vuelva a procesar.
3. **Genera un reporte Excel** de la corrida (resumen y detalle por
   categoría) y **consultas de verificación** para confirmar que el Job las
   procesó (`ProcesadoEstado = 1`).

Todo con validaciones que impiden generar un `UPDATE` incorrecto.

### Categorías que cubre

| Categoría | Prefijo de código | Tabla en `TyT_APICtrl` | Query de diagnóstico |
|---|---|---|---|
| Aduana | `DTYT` | `dbo.TarifaAduana` (+ `TarifaAduana_Cliente_Honorario`) | `script-TA-Regularizacion.sql` |
| Carga Suelta | `DCCS` | `dbo.TarifaCargaSuelta` | `script-TCS-Regularizacion.sql` |
| Contenedor | `DCCO` | `dbo.TarifaContenedor` | `script-TCO-Regularizacion.sql` |
| Servicios Adicionales | `DCSA` | `dbo.TarifaServiciosAdicionales` | `script-TSA-Regularizacion.sql` |

### ¿Cuándo una tarifa es elegible?

Siempre debe estar en `ProcesadoEstado = 2` (en Aduana, `ProcesadoEstadoTyT = 2`)
y haber sido creada o modificada desde la **fecha de inicio** que indiques.
Además:

- **Contenedor y Carga Suelta**: tener Cotización, ClienteId, RutaId y
  TipoCotizacionId, y el cliente no anulado.
- **Aduana**: tener ClienteTyTID, TipoHonorarioTyT, ClienteEchoID y
  TipoHonorarioEcho, y ni el cliente TyT ni el Echo anulados. Al
  regularizarla también se reinicia su contador `No_intentos`.
- **Servicios Adicionales**: tener ClienteId, HonorarioId, Precio, RutaId y
  TipoCotizacionId, cliente no anulado, y además pasar la lógica de
  duplicados del SP: no existir ya en Dobra con otro código (Caso 1) y, si
  está duplicada dentro del lote, ser la ganadora del grupo (Casos 2/3).

Que la tarifa esté `1-Inactivo` no la excluye: se informa como observación.
El detalle completo de cada regla está en el encabezado de cada query de
`01_QueriesTarifas/`.

---

## 2. ¿Cómo funciona?

```
 ┌──────────────────────┐   1. fecha de inicio
 │ preparar_queries.py  │ ───────────────────────► Output_<fecha>\Diagnostico\
 └──────────────────────┘                          (4 queries SOLO LECTURA)
                                                          │
                              2. ejecutarlas en SSMS      ▼
                                 y copiar "Messages" ─► Output_<fecha>\entrada.txt
                                                          │
 ┌────────────────────────────┐  3. leer entrada.txt      ▼
 │ generar_reporte_tarifas.py │ ─────────────────► Output_<fecha>\
 └────────────────────────────┘                     ├─ Resumen_tarifas.xlsx
                                                    ├─ Update\   (UPDATE por categoría)
                                                    └─ Queries\  (verificación)
                                                          │
         4. ejecutar Update\ en la base ◄─────────────────┘
         5. esperar al Job y ejecutar Queries\ → deben quedar en ProcesadoEstado = 1
```

| Pieza | Qué hace | ¿Toca la base? |
|---|---|---|
| `01_QueriesTarifas/script-T*-Regularizacion.sql` | Clasifican las tarifas en estado 2 y escriben en la pestaña *Messages* una línea `[ELEGIBLE] <código>` por tarifa y una línea `Resumen -> ...` por categoría. | Solo lectura (usan tablas temporales `#`). |
| `preparar_queries.py` | Copia las 4 queries poniendo la **misma** `@fechaCreacion` en todas, y verifica que sean de solo lectura. | No. |
| `generar_reporte_tarifas.py` | Lee el `.txt` con la salida de SSMS, valida los datos y genera el Excel, los `UPDATE` y las consultas. | No. Solo genera archivos. |
| `templates/` | Plantillas SQL de los `UPDATE` (`update_lite_*.sql`) y de las consultas de verificación (`consulta_*.sql`). | — |

Los scripts de Python **nunca se conectan a la base**. Los únicos que
modifican datos son los `.sql` de `Update\`, y los ejecuta una persona en
SSMS después de revisarlos.

---

## 3. ¿Qué necesita?

- **Windows con PowerShell** y **Python 3.9 o superior** (`python --version`).
- La librería **openpyxl** (se instala con `requirements.txt`).
- **SQL Server Management Studio (SSMS)** con acceso de **lectura** a
  `TyT_APICtrl`, `Cia`, `TyT` y `OperativoTyT` para correr las queries de
  diagnóstico.
- Para el paso de regularización: un usuario con permiso de **UPDATE** en
  `TyT_APICtrl` (o enviar los scripts de `Update\` a quien lo tenga).

---

## 4. Instalación (una sola vez por equipo)

Desde PowerShell, en la carpeta del proyecto:

```powershell
python -m venv venv
.\venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

Cada vez que vuelvas a trabajar en el proyecto solo activa el entorno:
`.\venv\Scripts\Activate.ps1` (verás `(venv)` al inicio de la línea).

> Si copias o mueves el proyecto a otra carpeta, **no copies `venv`**:
> créalo de nuevo con los comandos de arriba. Un `venv` movido da el error
> `Fatal error in launcher: Unable to create process...`.

---

## 5. Uso paso a paso

Ejemplo de una corrida hecha el 15/10/2026 revisando las tarifas desde el
14/10/2026 a las 15:00. Todos los comandos se ejecutan en la carpeta del
proyecto con el `venv` activado.

### Paso 1 — Preparar las queries con la fecha de inicio

```powershell
python .\preparar_queries.py "2026-10-14 15:00"
```

La fecha acepta `AAAA-MM-DD`, `AAAA-MM-DD HH:MM` o `AAAA-MM-DD HH:MM:SS`. Se
crean las 4 queries en `Output_20261015\Diagnostico\` (la carpeta lleva la
fecha de hoy) y se muestra qué fecha tenía antes cada una:

```
Listo. Queries (solo lectura) con @fechaCreacion = '2026-10-14 15:00:00' en: ...\Output_20261015\Diagnostico
  script-TA-Regularizacion.sql     Aduana                 antes: 2026-09-30 00:00:00.000
  script-TCS-Regularizacion.sql    Carga Suelta           antes: 2026-09-30 00:00:00.000
  ...
```

Los originales de `01_QueriesTarifas\` no se modifican.

### Paso 2 — Ejecutar las queries en SSMS y armar el archivo de entrada

1. Abre en SSMS las 4 queries de `Output_20261015\Diagnostico\` y ejecuta
   cada una (F5). Son de solo lectura: se pueden ejecutar en producción.
2. Ve a la pestaña **Messages** de cada una, selecciona todo (Ctrl+A),
   copia (Ctrl+C) y pega en un mismo archivo de texto:
   `Output_20261015\entrada.txt`.
   - Pega las 4 una debajo de la otra, en cualquier orden.
   - Puedes pegar todo el contenido de Messages; el script solo usa las
     líneas `[ELEGIBLE] ...` y `Resumen -> ...`.
   - Cada query debe aportar su línea `Resumen -> ...`.

### Paso 3 — Generar el reporte y los scripts

```powershell
python .\generar_reporte_tarifas.py .\Output_20261015\entrada.txt
```

Salida esperada:

```
Listo. Archivos generados en: ...\Output_20261015
  (Aduana: 75 tarifas elegibles -> hoja 'Aduana' en el Excel)
  (Carga Suelta: 14 tarifas elegibles -> hoja 'Carga Suelta' en el Excel)
  (Contenedor: 4 tarifas elegibles -> hoja 'Contenedor' en el Excel)
  (Servicios Adicionales: 226 tarifas elegibles -> hoja 'Servicios Adicionales' en el Excel)
  Resumen_tarifas.xlsx (hoja 'Resumen general' + una hoja por categoria)
  Update\script_Regularizacion_DTYT.sql -> 75 tarifas (Aduana)
  ...
  Queries\script_consulta_DCSA.sql -> 226 tarifas (Servicios Adicionales)
```

- Si aparece un bloque **`ADVERTENCIA`**, **no se generan los `.sql`** (solo
  el Excel, para revisar). Lee el motivo, corrige `entrada.txt` (casi siempre
  falta o está cortada la salida de alguna query) y vuelve a ejecutar.
- Si `preparar_queries.py` y este paso se hacen en días distintos, indica la
  carpeta para que todo quede junto:
  `python .\generar_reporte_tarifas.py .\Output_20261015\entrada.txt .\Output_20261015`

### Paso 4 — Revisar el resultado

1. Abre `Output_20261015\Resumen_tarifas.xlsx`:
   - **Resumen general**: una fila por categoría con los conteos de la query
     (evaluadas, incompletas, anuladas, casos de duplicado, elegibles) y la
     columna *Tarifas parseadas (control)*, que debe ser igual a *Elegibles
     para UPDATE*.
   - **Una hoja por categoría**: los códigos elegibles con su observación.
2. Abre al menos un `.sql` de `Update\` y revisa la fecha del encabezado y la
   cantidad de tarifas.

### Paso 5 — Regularizar (único paso que modifica datos)

Ejecuta en SSMS los `.sql` de `Output_20261015\Update\`, **con la base
`TyT_APICtrl` seleccionada** (los scripts no traen `USE`). Cada uno hace:

```sql
UPDATE dbo.TarifaContenedor
    SET ProcesadoEstado = 0, ProcesadoMensaje = 'Regularizado manualmente - 20261015', ...
WHERE ProcesadoEstado = 2
  AND Name IN ('DCCO_...', ...);
```

Solo cambia tarifas que **siguen en estado 2** y que están **en la lista**;
si alguna ya fue procesada por otro medio, no se toca. El de Aduana además
reinicia `No_intentos = 0` en `TarifaAduana_Cliente_Honorario`.

### Paso 6 — Verificar

Cuando haya corrido el Job, ejecuta los `.sql` de `Output_20261015\Queries\`.
Muestran el estado actual de cada tarifa regularizada: deben quedar en
**`ProcesadoEstado = 1`**. Si alguna vuelve a 2, revisa su `ProcesadoMensaje`.

### Resultado final de la corrida

```
Output_20261015\
  Diagnostico\           <- las 4 queries con la fecha de inicio (paso 1)
  entrada.txt            <- la salida de SSMS (paso 2)
  Resumen_tarifas.xlsx   <- reporte (paso 3)
  Update\                <- script_Regularizacion_<PREFIJO>.sql (paso 5)
  Queries\               <- script_consulta_<PREFIJO>.sql (paso 6)
```

Si una categoría tiene 0 elegibles, no se genera su `.sql` en `Update\` ni
en `Queries\` (su hoja del Excel lo indica).

---

## 6. Opciones de los comandos

```powershell
python .\preparar_queries.py <fecha_inicio> [--salida CARPETA]
python .\generar_reporte_tarifas.py <entrada.txt> [carpeta_salida] [--fecha AAAA-MM-DD] [--forzar]
```

| Opción | Para qué |
|---|---|
| `--salida` (preparar_queries) | Carpeta donde dejar las queries. Por defecto `Output_<hoy>\Diagnostico`. |
| `carpeta_salida` (generar_reporte) | Carpeta del resultado. Por defecto `Output_<hoy>`. |
| `--fecha` | Fecha a usar en los encabezados y en `ProcesadoMensaje`. Sirve para regenerar exactamente una corrida anterior. |
| `--forzar` | Genera los `.sql` aunque haya advertencias. **No recomendado**: úsalo solo si revisaste la advertencia y sabes por qué aparece. |

Códigos de salida de `generar_reporte_tarifas.py`: `0` = OK, `1` = hubo
advertencias o errores y no se generaron los `.sql`, `2` = argumentos
inválidos.

---

## 7. Medidas de seguridad

- **Queries de solo lectura**: las de `01_QueriesTarifas/` no tienen
  `UPDATE`, `INSERT`, `DELETE` ni transacciones. `preparar_queries.py` lo
  verifica y no genera ninguna copia si encuentra una sentencia de escritura.
- **Misma fecha en las 4 queries**: evita mezclar periodos distintos en una
  misma corrida.
- **Validación cruzada**: la cantidad de códigos `[ELEGIBLE]` debe coincidir
  con el *Elegibles para UPDATE* de cada `Resumen ->`. También se detectan
  bloques faltantes o duplicados, prefijos desconocidos, códigos de otra
  categoría y códigos repetidos. Ante cualquier problema, no se generan `.sql`.
- **Códigos validados**: todo código debe cumplir `<PREFIJO>_<número>_<año>`;
  si no, no se genera ningún `.sql`, ni siquiera con `--forzar`.
- **Sin restos de corridas anteriores**: antes de escribir se borran los
  `script_*.sql` previos de `Update\` y `Queries\` de esa carpeta, para que
  nunca quede un UPDATE viejo junto al nuevo.
- **Plantillas verificadas**: si una plantilla perdió su placeholder o queda
  alguno sin reemplazar, el script se detiene sin escribir nada.
- **UPDATE acotados**: cada `UPDATE` filtra por estado 2 **y** por la lista
  de códigos (lo comprueban los tests).

---

## 8. Estructura del proyecto

```
01_QueriesTarifas/
  script-TA-Regularizacion.sql    <- diagnóstico Aduana (solo lectura)
  script-TCS-Regularizacion.sql   <- diagnóstico Carga Suelta
  script-TCO-Regularizacion.sql   <- diagnóstico Contenedor
  script-TSA-Regularizacion.sql   <- diagnóstico Servicios Adicionales
  script-TSA-Detalle.sql          <- consulta de apoyo (OK/Pendiente/Error de TSA); no forma parte del flujo
preparar_queries.py               <- paso 1
generar_reporte_tarifas.py        <- paso 3
templates/
  update_lite_<PREFIJO>.sql       <- plantilla del UPDATE de cada categoría
  consulta_<PREFIJO>.sql          <- plantilla de la consulta de verificación
tests/                            <- pruebas automáticas
requirements.txt
README.md
```

Las carpetas `Output_*`, los `.txt` y `venv` no se suben a git.

---

## 9. Pruebas automáticas

```powershell
python -m unittest discover -s tests -v
```

No necesitan base de datos ni librerías extra. Cubren:

- **Lectura de la salida de SSMS**: las 4 categorías en cualquier orden,
  asignación de bloques vacíos, observaciones, líneas que se ignoran,
  entradas en UTF-16.
- **Validaciones**: conteos que no cuadran, bloques faltantes o duplicados,
  prefijos desconocidos, códigos de otra categoría, repetidos o con formato
  inválido.
- **Generación**: Excel (hojas, números, columnas, categoría sin elegibles),
  `UPDATE` y consultas, bloqueo ante advertencias, `--forzar`, limpieza de
  corridas anteriores, carpeta por defecto, errores de argumentos.
- **Plantillas reales**: todas tienen sus placeholders, cada `UPDATE` filtra
  por estado 2 y por la lista de códigos, y las consultas son de solo lectura.
- **Queries de diagnóstico**: las 4 reales son de solo lectura, conservan las
  líneas `[ELEGIBLE]`/`Resumen ->` que lee el script, y la fecha se reemplaza
  sin alterar el resto del archivo ni su codificación.

Ejecuta las pruebas después de editar cualquier `.py`, plantilla o query.

---

## 10. Mantenimiento

- **Cambiar un UPDATE o una consulta**: edita el `.sql` en `templates/`, sin
  tocar el `.py`. Mantén los placeholders:

  | Plantilla | Placeholders obligatorios |
  |---|---|
  | `update_lite_*.sql` | `{HEADER}`, `{FECHA_COMPACTA}` y `<lista_tarifas_in>` |
  | `consulta_*.sql` | `{HEADER}` y `<lista_tarifas_aduana>` / `<lista_tarifas_CargaSuelta>` / `<lista_tarifas_Contenedor>` / `<lista_tarifas_ServiciosAdicionales>` |

- **Cambiar una regla de elegibilidad**: edita la query en
  `01_QueriesTarifas/`, sin agregar sentencias de escritura y conservando
  `DECLARE @fechaCreacion DATETIME = '...'` y los mensajes `[ELEGIBLE]` y
  `Resumen -> ... | Elegibles para UPDATE: N`.
- Después de cualquier cambio, corre las pruebas (sección 9).

---

## 11. Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Fatal error in launcher: Unable to create process ...` | El `venv` se creó en otra carpeta y se movió | Usa `python -m pip ...` o recrea el `venv` (sección 4) |
| `ModuleNotFoundError: No module named 'openpyxl'` | `venv` no activado o dependencias sin instalar | `.\venv\Scripts\Activate.ps1` y `python -m pip install -r requirements.txt` |
| `NO se generaron los .sql porque hay ADVERTENCIAS` | Falta o está cortada la salida de alguna query, o los conteos no cuadran | Lee las advertencias, corrige `entrada.txt` y vuelve a ejecutar |
| `ERROR: ... no es de solo lectura` (preparar_queries) | Alguien agregó una sentencia de escritura a una query | Quítala; las queries de diagnóstico no deben modificar datos |
| `ERROR: no se pudo escribir '...Resumen_tarifas.xlsx'` | El Excel está abierto | Ciérralo y vuelve a ejecutar |
| `La plantilla '...' no contiene el placeholder` | Se editó una plantilla y se perdió el placeholder | Restáuralo (sección 10) |
| Una categoría no tiene su `.sql` | Esa categoría tuvo 0 elegibles | Comportamiento esperado |
| El UPDATE da `Invalid object name 'dbo.Tarifa...'` | SSMS no tenía seleccionada `TyT_APICtrl` | Selecciona la base y vuelve a ejecutarlo |
| `FileNotFoundError` con una ruta muy larga | Windows limita las rutas a 260 caracteres | Usa una carpeta de salida con ruta más corta |
