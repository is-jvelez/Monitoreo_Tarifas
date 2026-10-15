"""Tests de preparar_queries.py. Correr desde la raiz del repo con:
    python -m unittest discover -s tests -v
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import preparar_queries as p  # noqa: E402

QUERY_EJEMPLO = (
    "/* Solo lectura: no tiene UPDATE ni INSERT */\r\n"
    "USE TyT_APICtrl;\r\n"
    "DECLARE @fechaCreacion   DATETIME          = '2026-08-28 00:00:00.000';\r\n"
    "SELECT T.Name INTO #Tarifas FROM dbo.TarifaContenedor T\r\n"
    "WHERE (T.Created_Time >= @fechaCreacion OR T.Modified_Time >= @fechaCreacion);\r\n"
    "DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Name FROM #Tarifas;\r\n"
    "FETCH NEXT FROM cur INTO @n;\r\n"
    "SET @msg = CONCAT('Resumen -> Elegibles para UPDATE: ', @n); -- texto, no sentencia\r\n"
    "IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;\r\n"
)


def correr(*args):
    salida = io.StringIO()
    with contextlib.redirect_stdout(salida):
        codigo = p.main([str(a) for a in args])
    return codigo, salida.getvalue()


class TestPrepararQuery(unittest.TestCase):
    def test_reemplaza_la_fecha(self):
        nuevo, fecha_ant = p.preparar_query(QUERY_EJEMPLO, datetime(2026, 10, 14, 15, 0), "x.sql")
        self.assertIn("DATETIME          = '2026-10-14 15:00:00.000';\r\n", nuevo)
        self.assertIn("T.Created_Time >= @fechaCreacion", nuevo)  # los usos del parametro no se tocan
        self.assertEqual(fecha_ant, "2026-08-28 00:00:00.000")
        self.assertEqual(nuevo.count("\r\n"), QUERY_EJEMPLO.count("\r\n"))

    def test_falla_si_falta_o_sobra_la_declaracion(self):
        with self.assertRaisesRegex(ValueError, "se encontraron 0"):
            p.preparar_query(QUERY_EJEMPLO.replace("DECLARE @fechaCreacion", "-- "), datetime(2026, 1, 1), "x.sql")
        with self.assertRaisesRegex(ValueError, "se encontraron 2"):
            p.preparar_query(QUERY_EJEMPLO + QUERY_EJEMPLO.splitlines(True)[2], datetime(2026, 1, 1), "x.sql")

    def test_formatos_de_fecha(self):
        self.assertEqual(p.parsear_fecha_inicio("2026-10-14"), datetime(2026, 10, 14))
        self.assertEqual(p.parsear_fecha_inicio("2026-10-14 15:00"), datetime(2026, 10, 14, 15))
        self.assertEqual(p.parsear_fecha_inicio("2026-10-14 15:00:30"), datetime(2026, 10, 14, 15, 0, 30))
        with self.assertRaises(Exception):
            p.parsear_fecha_inicio("14/10/2026")


class TestSoloLectura(unittest.TestCase):
    def test_query_de_ejemplo_es_solo_lectura(self):
        # UPDATE/INSERT en comentarios y textos, SELECT INTO #temp, FETCH INTO @var y
        # DROP TABLE #temp no cuentan como escritura.
        self.assertEqual(p.sentencias_de_escritura(QUERY_EJEMPLO), [])

    def test_detecta_sentencias_de_escritura(self):
        casos = {
            "UPDATE dbo.TarifaContenedor SET ProcesadoEstado = 0;": "UPDATE",
            "update T set x = 1 from #Tarifas T;": "UPDATE",
            "INSERT INTO dbo.Log VALUES (1);": "INSERT",
            "DELETE FROM dbo.TarifaContenedor;": "DELETE",
            "BEGIN TRANSACTION;": "BEGIN TRANSACTION",
            "BEGIN TRAN": "BEGIN TRAN",
            "COMMIT TRANSACTION;": "COMMIT",
            "EXEC dbo.sp_algo;": "EXEC",
            "DROP TABLE dbo.Tarifas;": "DROP TABLE",
            "SELECT * INTO dbo.Copia FROM dbo.T;": "INTO",
            "TRUNCATE TABLE dbo.T;": "TRUNCATE",
        }
        for sql, esperado in casos.items():
            with self.subTest(sql=sql):
                encontrados = p.sentencias_de_escritura(sql)
                self.assertTrue(any(e.startswith(esperado) for e in encontrados), encontrados)

    def test_query_con_update_no_se_prepara(self):
        con_update = QUERY_EJEMPLO + "UPDATE dbo.TarifaContenedor SET ProcesadoEstado = 0;\r\n"
        with self.assertRaisesRegex(ValueError, "no es de solo lectura, contiene: UPDATE"):
            p.preparar_query(con_update, datetime(2026, 10, 14), "x.sql")


class TestMain(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.origen = self.tmp / "origen"
        self.origen.mkdir()
        for nombre in p.QUERIES.values():
            (self.origen / nombre).write_bytes(QUERY_EJEMPLO.encode("utf-8"))
        self._original = p.QUERIES_DIR
        p.QUERIES_DIR = self.origen

    def tearDown(self):
        p.QUERIES_DIR = self._original
        self._tmp.cleanup()

    def test_genera_las_4_copias_sin_tocar_los_originales(self):
        salida = self.tmp / "out"
        codigo, _ = correr("2026-10-14 15:00", "--salida", salida)
        self.assertEqual(codigo, 0)
        self.assertEqual(sorted(f.name for f in salida.iterdir()), sorted(p.QUERIES.values()))
        for nombre in p.QUERIES.values():
            self.assertIn(b"'2026-10-14 15:00:00.000'", (salida / nombre).read_bytes())
            self.assertEqual((self.origen / nombre).read_bytes(), QUERY_EJEMPLO.encode("utf-8"))

    def test_carpeta_de_salida_por_defecto(self):
        cwd = os.getcwd()
        os.chdir(self.tmp)
        try:
            codigo, _ = correr("2026-10-14")
        finally:
            os.chdir(cwd)
        self.assertEqual(codigo, 0)
        diagnostico = self.tmp / f"Output_{date.today():%Y%m%d}" / "Diagnostico"
        self.assertEqual(len(list(diagnostico.glob("*.sql"))), 4)

    def test_conserva_la_codificacion_utf8(self):
        nombre = p.QUERIES["Servicios Adicionales"]
        con_tilde = QUERY_EJEMPLO.replace("Solo lectura", "Solo lectura (tamaño)")
        (self.origen / nombre).write_bytes(con_tilde.encode("utf-8"))
        salida = self.tmp / "out"
        codigo, _ = correr("2026-10-14", "--salida", salida)
        self.assertEqual(codigo, 0)
        self.assertIn("tamaño".encode("utf-8"), (salida / nombre).read_bytes())

    def test_falta_una_query(self):
        (self.origen / p.QUERIES["Aduana"]).unlink()
        salida = self.tmp / "out"
        codigo, texto = correr("2026-10-14", "--salida", salida)
        self.assertEqual(codigo, 1)
        self.assertIn("no se encontro", texto)
        self.assertFalse(salida.exists())

    def test_fecha_invalida_es_error_de_argumentos(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as ctx:
            p.main(["14/10/2026"])
        self.assertEqual(ctx.exception.code, 2)

    def test_si_una_query_escribe_no_genera_ninguna(self):
        ruta = self.origen / p.QUERIES["Contenedor"]
        ruta.write_text(QUERY_EJEMPLO + "COMMIT TRANSACTION;\r\n", encoding="utf-8")
        salida = self.tmp / "out"
        codigo, texto = correr("2026-10-14", "--salida", salida)
        self.assertEqual(codigo, 1)
        self.assertIn("script-TCO-Regularizacion.sql: no es de solo lectura", texto)
        self.assertFalse(salida.exists())


@unittest.skipUnless(all((p.QUERIES_DIR / n).is_file() for n in p.QUERIES.values()),
                     "no esta la carpeta 01_QueriesTarifas")
class TestQueriesReales(unittest.TestCase):
    def test_las_4_queries_reales_son_solo_lectura_y_se_pueden_preparar(self):
        for nombre in p.QUERIES.values():
            with self.subTest(query=nombre):
                texto, _ = p._leer(p.QUERIES_DIR / nombre)
                self.assertEqual(p.sentencias_de_escritura(texto), [])
                p.preparar_query(texto, datetime(2026, 10, 14, 15), nombre)
                # la salida que lee generar_reporte_tarifas.py se mantiene
                self.assertIn("'  [ELEGIBLE] '", texto)
                self.assertIn("'Resumen -> Evaluadas: '", texto)
                self.assertIn("' | Elegibles para UPDATE: '", texto)


if __name__ == "__main__":
    unittest.main()
