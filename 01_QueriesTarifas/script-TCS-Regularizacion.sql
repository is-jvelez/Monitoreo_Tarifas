/* =====================================================================================
   Script:      script-TCS-Regularizacion.sql   (SOLO LECTURA)
   Objetivo:    Identificar las tarifas de CARGA SUELTA (dbo.TarifaCargaSuelta) que
                quedaron con ProcesadoEstado = 2 porque a la fecha de proceso les
                faltaba Cotizacion, ClienteId, RutaId o TipoCotizacionId, y que HOY ya
                tienen esa informacion completa y el cliente NO esta anulado.

   Basado en:   script-TCS.sql (misma consulta / mismos JOIN, sin modificar la logica
                de negocio de los homologados). Analogo a
                script-TCO-Regularizacion.sql pero sobre dbo.TarifaCargaSuelta
                (join por CabeceraName, no hay homologacion de Tipo_de_Honorario en la
                consulta original).

   Validaciones (NO deben ser NULL):
                - Cotizacion        (CO.Name)
                - ClienteId         (CLI.ID)
                - RutaId            (TR.IdDobraCia)
                - TipoCotizacionId  (TTC.IdDobraCia)
   Condiciones adicionales para ser ELEGIBLE:
                - cli_anulado = 0            (CLI.Anulado = 0)
                - TCS.ProcesadoEstado = 2
                NOTA: el Estado de la tarifa (Anulado/'1-Inactivo') NO excluye;
                se informa solo como dato de contexto en el listado de elegibles
                (mismo criterio confirmado para TarifaContenedor).

   SOLO LECTURA:
                Este script NO modifica ninguna tabla: no tiene UPDATE, INSERT,
                DELETE ni transacciones. Solo consulta, usa tablas temporales (#) e
                imprime en la pestana Messages el detalle y la linea "Resumen ->".
                Se puede ejecutar en produccion sin riesgo.

                La regularizacion (ProcesadoEstado 2 -> 0) se hace despues con los
                .sql que genera generar_reporte_tarifas.py a partir de esta salida
                (carpetas Update/ o update_lite/).

   Parametro:   @fechaCreacion -> se revisan las tarifas creadas o modificadas desde
                esa fecha. preparar_queries.py la fija igual en las 4 queries.
   ===================================================================================== */

SET NOCOUNT ON;

USE TyT_APICtrl;
GO

------------------------------------------------------------------------------
-- 0) PARAMETROS DE EJECUCION -------------------------------------------------
------------------------------------------------------------------------------
DECLARE @fechaCreacion   DATETIME          = '2026-09-30 00:00:00.000';

DECLARE @FechaInicio      DATETIME         = GETDATE();
DECLARE @msg              NVARCHAR(4000);

-- SET LOCK_TIMEOUT exige una constante literal (no acepta variable): 30000 ms = 30s
SET LOCK_TIMEOUT 30000;

SET @msg = CONCAT('=== INICIO script-TCS-Regularizacion (SOLO LECTURA) === fechaCreacion>=',
                   CONVERT(VARCHAR(23), @fechaCreacion, 121));
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 1) SNAPSHOT: misma consulta base de script-TCS.sql, con flags calculados --
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;

SELECT
        TCS.Name                                              AS TarifaName,
        CO.Name                                               AS Cotizacion,
        CLI.ID                                                AS ClienteId,
        CLI.Anulado                                           AS cli_anulado,
        TR.IdDobraCia                                         AS RutaId,
        TTC.IdDobraCia                                        AS TipoCotizacionId,
        CASE WHEN TCS.Estado = '1-Inactivo' THEN 1 ELSE 0 END AS TarifaAnulada,
        TCS.ProcesadoEstado                                   AS ProcesadoEstadoActual,
        CASE
            WHEN CO.Name IS NULL OR CLI.ID IS NULL OR TR.IdDobraCia IS NULL OR TTC.IdDobraCia IS NULL
                THEN 1 ELSE 0
        END                                                    AS Incompleta,
        CASE
            WHEN CO.Name IS NOT NULL AND CLI.ID IS NOT NULL AND TR.IdDobraCia IS NOT NULL AND TTC.IdDobraCia IS NOT NULL
             AND ISNULL(CLI.Anulado, 1) = 0
                THEN 1 ELSE 0
        END                                                    AS Elegible
INTO #Tarifas
FROM        dbo.TarifaCargaSuelta TCS
LEFT JOIN   dbo.Cotizacion CO   ON TCS.CabeceraName = CO.Name
LEFT JOIN   dbo.Account_new A   ON CO.ClienteId = A.ZohoId
LEFT JOIN   Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
LEFT JOIN   dbo.Homologacion TR  ON (CASE WHEN LEFT(TCS.Ruta, CHARINDEX('-', TCS.Ruta + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TCS.Ruta, CHARINDEX('-', TCS.Ruta + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TCS.Ruta, CHARINDEX('-', TCS.Ruta + '-') - 1)) END) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
LEFT JOIN   dbo.Homologacion TTC ON (CASE WHEN LEFT(TCS.Tipo_cotizacion, CHARINDEX('-', TCS.Tipo_cotizacion + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TCS.Tipo_cotizacion, CHARINDEX('-', TCS.Tipo_cotizacion + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TCS.Tipo_cotizacion, CHARINDEX('-', TCS.Tipo_cotizacion + '-') - 1)) END) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
WHERE       TCS.ProcesadoEstado = 2
AND         (TCS.Created_Time >= @fechaCreacion OR TCS.Modified_Time >= @fechaCreacion);

DECLARE @TotalEvaluadas       INT = (SELECT COUNT(*) FROM #Tarifas);
DECLARE @TotalIncompletas     INT = (SELECT COUNT(*) FROM #Tarifas WHERE Incompleta = 1);
DECLARE @TotalClienteAnulado  INT = (SELECT COUNT(*) FROM #Tarifas WHERE Incompleta = 0 AND ISNULL(cli_anulado,1) <> 0);
DECLARE @TotalElegibles       INT = (SELECT COUNT(*) FROM #Tarifas WHERE Elegible = 1);
DECLARE @TotalElegiblesTarifaAnulada INT = (SELECT COUNT(*) FROM #Tarifas WHERE Elegible = 1 AND TarifaAnulada = 1);

SET @msg = CONCAT('Filas evaluadas (ProcesadoEstado=2, filtro de fecha): ', @TotalEvaluadas);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 2) DETALLE: tarifas con datos incompletos (siguen en ProcesadoEstado=2) ---
------------------------------------------------------------------------------
RAISERROR('--- Tarifas INCOMPLETAS (no se actualizan, quedan en ProcesadoEstado=2) ---', 0, 1) WITH NOWAIT;

IF @TotalIncompletas = 0
BEGIN
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE cur_incompletas CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName,
               CASE WHEN Cotizacion IS NULL THEN 'Cotizacion ' ELSE '' END +
               CASE WHEN ClienteId IS NULL THEN 'ClienteId ' ELSE '' END +
               CASE WHEN RutaId IS NULL THEN 'RutaId ' ELSE '' END +
               CASE WHEN TipoCotizacionId IS NULL THEN 'TipoCotizacionId ' ELSE '' END AS CamposFaltantes
        FROM #Tarifas
        WHERE Incompleta = 1
        ORDER BY TarifaName;

    DECLARE @TarifaName NVARCHAR(200), @CamposFaltantes NVARCHAR(200);
    OPEN cur_incompletas;
    FETCH NEXT FROM cur_incompletas INTO @TarifaName, @CamposFaltantes;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [INCOMPLETA] ', @TarifaName, ' -> campo(s) vacio(s): ', @CamposFaltantes);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur_incompletas INTO @TarifaName, @CamposFaltantes;
    END
    CLOSE cur_incompletas;
    DEALLOCATE cur_incompletas;
END

------------------------------------------------------------------------------
-- 3) DETALLE: completas pero excluidas por cliente anulado ------------------
------------------------------------------------------------------------------
RAISERROR('--- Tarifas COMPLETAS pero con cliente ANULADO (no se actualizan) ---', 0, 1) WITH NOWAIT;
IF @TotalClienteAnulado = 0
BEGIN
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE cur_cliAnulado CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName FROM #Tarifas
        WHERE Incompleta = 0 AND ISNULL(cli_anulado,1) <> 0
        ORDER BY TarifaName;
    DECLARE @TarifaName2 NVARCHAR(200);
    OPEN cur_cliAnulado;
    FETCH NEXT FROM cur_cliAnulado INTO @TarifaName2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [CLIENTE ANULADO] ', @TarifaName2);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur_cliAnulado INTO @TarifaName2;
    END
    CLOSE cur_cliAnulado;
    DEALLOCATE cur_cliAnulado;
END

------------------------------------------------------------------------------
-- 4) DETALLE: tarifas ELEGIBLES para regularizar ----------------------------
--    (incluye tarifas con Estado='1-Inactivo'; se marcan solo como dato
--     informativo, NO se excluyen)
------------------------------------------------------------------------------
RAISERROR('--- Tarifas ELEGIBLES para regularizar (ProcesadoEstado 2 -> 0) ---', 0, 1) WITH NOWAIT;
IF @TotalElegibles = 0
BEGIN
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE cur_elegibles CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName, TarifaAnulada FROM #Tarifas WHERE Elegible = 1 ORDER BY TarifaName;
    DECLARE @TarifaName4 NVARCHAR(200), @TarifaAnulada4 BIT;
    OPEN cur_elegibles;
    FETCH NEXT FROM cur_elegibles INTO @TarifaName4, @TarifaAnulada4;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [ELEGIBLE] ', @TarifaName4,
                           CASE WHEN @TarifaAnulada4 = 1 THEN ' (tarifa Estado=1-Inactivo, de todas formas se actualiza)' ELSE '' END);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur_elegibles INTO @TarifaName4, @TarifaAnulada4;
    END
    CLOSE cur_elegibles;
    DEALLOCATE cur_elegibles;
END

SET @msg = CONCAT('Resumen -> Evaluadas: ', @TotalEvaluadas,
                   ' | Incompletas: ', @TotalIncompletas,
                   ' | Cliente anulado (excluidas): ', @TotalClienteAnulado,
                   ' | Elegibles para UPDATE: ', @TotalElegibles,
                   ' (de las cuales con tarifa Estado=1-Inactivo: ', @TotalElegiblesTarifaAnulada, ')');
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 5) LIMPIEZA -----------------------------------------------------------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;

SET @msg = CONCAT('=== FIN script-TCS-Regularizacion (SOLO LECTURA, no se modifico nada) === Duracion: ',
                   DATEDIFF(SECOND, @FechaInicio, GETDATE()), ' segundo(s)');
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
GO
