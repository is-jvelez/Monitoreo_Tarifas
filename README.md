# generar_reporte_tarifas.py

Automatiza el proceso mensual de regularización de tarifas (Aduana, Carga
Suelta, Contenedor, Servicios Adicionales):

1. Parsea el texto que arrojan las 4 consultas de tarifas, tal como se pega
   desde SSMS (no depende de encabezados de categoría ni de un orden fijo).
2. Genera `Resumen_tarifas.xlsx` con una hoja de resumen general (una fila
   por categoría) y una hoja por categoría con la lista de tarifas elegibles.
3. Genera los `.sql` de **actualización** (`Update/script_Regularizacion_<PREFIJO>.sql`)
   para dejar en `ProcesadoEstado = 0` las tarifas elegibles.
4. Genera los `.sql` de **consulta/verificación post-regularización**
   (`Queries/script_consulta_<PREFIJO>.sql`) para revisar el estado después
   de que corra el Job.

Si una categoría queda con 0 tarifas elegibles en la corrida, no se genera
ni su `.sql` de actualización ni el de consulta para esa categoría (un
`UPDATE`/`IN (...)` con lista vacía no tiene sentido o directamente no es
SQL válido).

## Estructura del repositorio

```
generar_reporte_tarifas.py
templates/
  update_DTYT.sql            <- plantilla del UPDATE de Aduana
  update_DCCS.sql            <- Carga Suelta
  update_DCCO.sql            <- Contenedor
  update_DCSA.sql            <- Servicios Adicionales
  consulta_DTYT.sql          <- plantilla de la consulta de Aduana
  consulta_DCCS.sql
  consulta_DCCO.sql
  consulta_DCSA.sql
README.md
```

**Importante:** el script NO trae el SQL embebido — lee cada plantilla desde
`templates/` en tiempo de ejecución, resolviendo la ruta relativa a la
ubicación del propio `.py` (no a tu carpeta de trabajo). Si clonas el repo
completo, la carpeta `templates/` ya viene incluida y no tienes que hacer
nada especial. Si por algún motivo copias solo `generar_reporte_tarifas.py`
suelto a otro lado (sin la carpeta `templates/`), el script se detiene con
un error claro indicando qué plantilla falta y dónde la buscó — no falla en
silencio ni genera un `.sql` a medias.

Si necesitas editar el SQL de una categoría (por ejemplo, agregar una
columna a la consulta de Contenedor), edita el `.sql` correspondiente en
`templates/` directamente — no hace falta tocar el `.py`.

---

## 1. Requisitos

- Python 3.9 o superior instalado (`python --version` para confirmar).
- Acceso de escritura a la carpeta donde vas a correr el script.

No necesitas SQL Server ni conexión a base de datos para correr el script:
solo trabaja sobre el `.txt` de entrada que tú generas pegando el resultado
de las 4 consultas en SSMS.

## 2. Instalación (una sola vez por máquina/carpeta)

Clona el repositorio (o `git pull` si ya lo tienes) para asegurarte de
tener `generar_reporte_tarifas.py` **junto con** la carpeta `templates/` —
ambos vienen versionados juntos.

Luego, desde PowerShell, parado en la carpeta del repo:

```powershell
# 1. Crear un entorno virtual (aisla las librerías de este proyecto del resto de tu PC)
python -m venv venv

# 2. Activarlo
.\venv\Scripts\Activate.ps1

# Deberias ver "(venv)" al inicio de la linea del prompt despues de esto.

# 3. Instalar las librerias necesarias
pip install pandas openpyxl
```

Si prefieres dejar las versiones fijadas para poder reinstalar exactamente
lo mismo en otra máquina:

```powershell
pip freeze > requirements.txt
```

Y en la otra máquina, con su propio venv activado:

```powershell
pip install -r requirements.txt
```

**Cada vez que vuelvas a trabajar en este proyecto** (otro día, otra sesión
de PowerShell), solo necesitas activar el venv de nuevo — no reinstalar:

```powershell
.\venv\Scripts\Activate.ps1
```

## 3. Preparar el archivo de entrada

1. Corre en SSMS las 4 consultas de tarifas (Aduana, Carga Suelta,
   Contenedor, Servicios Adicionales) como ya lo haces.
2. Pega el resultado completo de las 4 (los bloques `[ELEGIBLE] ...` y sus
   respectivas líneas `Resumen -> ...`) en un único archivo de texto, por
   ejemplo `entrada.txt`. El orden entre categorías no importa.

## 4. Uso

```powershell
python .\generar_reporte_tarifas.py <archivo_entrada.txt> <carpeta_salida>
```

Ejemplo real:

```powershell
python .\generar_reporte_tarifas.py entrada.txt Output
```

Esto crea (o reutiliza si ya existe) la carpeta `Output` con:

```
Output/
  Resumen_tarifas.xlsx        <- hoja "Resumen general" + 1 hoja por categoria
  Update/
    script_Regularizacion_DTYT.sql   (Aduana, si tiene elegibles)
    script_Regularizacion_DCCO.sql   (Contenedor, si tiene elegibles)
    script_Regularizacion_DCCS.sql   (Carga Suelta, si tiene elegibles)
    script_Regularizacion_DCSA.sql   (Servicios Adicionales, si tiene elegibles)
  Queries/
    script_consulta_DTYT.sql         (mismos criterios que Update/)
    script_consulta_DCCO.sql
    script_consulta_DCCS.sql
    script_consulta_DCSA.sql
```

### Salida por consola

Al terminar, el script imprime un resumen de lo que generó, por ejemplo:

```
Listo. Archivos generados en: C:\...\Output
  (Aduana: 51 tarifas elegibles -> hoja 'Aduana' en el Excel)
  (Carga Suelta: 0 tarifas elegibles -> hoja 'Carga Suelta' en el Excel)
  (Contenedor: 20 tarifas elegibles -> hoja 'Contenedor' en el Excel)
  (Servicios Adicionales: 262 tarifas elegibles -> hoja 'Servicios Adicionales' en el Excel)
  Resumen_tarifas.xlsx (hoja 'Resumen general' + una hoja por categoria)
  Update\script_Regularizacion_DTYT.sql -> 51 tarifas (Aduana)
  Update\script_Regularizacion_DCCO.sql -> 20 tarifas (Contenedor)
  Update\script_Regularizacion_DCSA.sql -> 262 tarifas (Servicios Adicionales)
  (sin script de UPDATE, 0 tarifas elegibles: Carga Suelta)
  Queries\script_consulta_DTYT.sql -> 51 tarifas (Aduana)
  Queries\script_consulta_DCCO.sql -> 20 tarifas (Contenedor)
  Queries\script_consulta_DCSA.sql -> 262 tarifas (Servicios Adicionales)
  (sin script de consulta, 0 tarifas elegibles: Carga Suelta)
```

Si el archivo de entrada no tiene el formato esperado (bloques o líneas
`Resumen ->` incompletas, prefijo de tarifa desconocido, dos bloques que
parecen ser de la misma categoría, etc.), el script imprime primero un
bloque `ADVERTENCIA - revisar antes de usar el resultado:` con el detalle.
**No ignores esas advertencias** — el script prefiere avisar y seguir con
lo que sí pudo parsear, en vez de adivinar en silencio.

## 5. Cómo probarlo (checklist)

Antes de confiar en una corrida nueva (por ejemplo, después de editar el
script), verifica lo siguiente:

1. **Corre sin errores de Python.**
   ```powershell
   python .\generar_reporte_tarifas.py entrada.txt Output
   ```
   Si sale `ModuleNotFoundError`, no tienes el venv activado o falta
   `pip install pandas openpyxl` (ver sección 2). Si sale
   `FileNotFoundError` mencionando una plantilla, te falta la carpeta
   `templates/` junto al script (ver "Estructura del repositorio" arriba).

2. **No debe imprimir ningún bloque `ADVERTENCIA`.** Si aparece, léelo:
   te dice exactamente qué categoría o bloque no pudo asignar con
   confianza.

3. **Los conteos deben calzar.** El script ya valida internamente que la
   cantidad de códigos `[ELEGIBLE]` parseados coincida con el número que
   dice "Elegibles para UPDATE" en el propio `Resumen ->` de la consulta
   SQL original — si no calzan, sale como advertencia. Aun así, es buena
   práctica que tú mismo compares una vez el número de filas de una hoja
   del Excel (por categoría) contra el total que muestra SSMS.

4. **Abre `Resumen_tarifas.xlsx`** y confirma:
   - La hoja "Resumen general" tiene una fila por categoría con las
     estadísticas correctas (Evaluadas, Incompletas, Elegibles, etc.).
   - Cada hoja de categoría (Aduana, Carga Suelta, Contenedor, Servicios
     Adicionales) lista los códigos esperados, o el mensaje de "sin
     tarifas elegibles" si esa categoría dio 0.

5. **Revisa al menos un `.sql` de cada carpeta a ojo** (`Update\` y
   `Queries\`):
   - Que el comentario del encabezado tenga la fecha de hoy y el número
     correcto de tarifas.
   - Que la lista de tarifas no tenga el placeholder sin reemplazar
     (no debe aparecer el texto `<lista_tarifas...>` en ningún `.sql`
     generado — si aparece, es un bug).
   - Que el script cierre bien (`COMMIT TRANSACTION; GO` en los de
     Update; el `)` o `);` final del `WHERE ... IN (...)` en los de
     consulta).

6. **El script no ejecuta nada contra la base de datos.** Solo genera
   archivos de texto. Revisa y corre los `.sql` resultantes tú mismo en
   SSMS, como cualquier otro script — el script de Python no tiene
   conexión a SQL Server.

## 6. Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| `ModuleNotFoundError: No module named 'pandas'` | Venv no activado o librerías no instaladas | `.\venv\Scripts\Activate.ps1` y luego `pip install pandas openpyxl` |
| `FileNotFoundError: No se encontro la plantilla '...' en ...\templates` | Copiaste/moviste `generar_reporte_tarifas.py` sin la carpeta `templates/` | Cerciórate de tener el repo completo (`git pull`); ambos deben estar en la misma carpeta |
| Sale el mensaje de uso y termina | Faltó pasar `<entrada.txt>` y/o `<carpeta_salida>` como argumentos | `python .\generar_reporte_tarifas.py entrada.txt Output` (los 2 argumentos son obligatorios) |
| Los `.txt`/`Tarifas_<PREFIJO>.txt` de versiones anteriores no aparecen | Se eliminó esa generación a pedido explícito; ahora esas listas viven en las hojas del Excel | No es un error — es el comportamiento actual |
| Una categoría no tiene su `.sql` en `Update\` o `Queries\` | Esa categoría dio 0 tarifas elegibles en la corrida | Comportamiento esperado — revisa la hoja de esa categoría en el Excel para confirmar que en efecto es 0 |
| Aparece `ADVERTENCIA` mencionando "prefijo desconocido" o "no se pudo asignar categoria por eliminacion" | El texto de SSMS que pegaste no tiene el formato esperado (ver sección 3) | Revisa el `.txt` de entrada; puede faltar una línea `Resumen ->`, o el bloque `[ELEGIBLE]` viene con un prefijo distinto a DTYT/DCCS/DCCO/DCSA |

---

**Nota:** este README documenta el comportamiento actual del script
(incluye Excel multi-hoja y los `.sql` de Update + Queries). El
docstring dentro del propio `.py` quedó desactualizado en la parte
que menciona la generación de `.txt` — no afecta el funcionamiento,
pero si lo editas de nuevo conviene actualizarlo también para que no
confunda a quien lo lea después.