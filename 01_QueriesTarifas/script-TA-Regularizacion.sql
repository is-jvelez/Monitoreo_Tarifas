/* =====================================================================================
   Script:      script-TA-Regularizacion.sql   (SOLO LECTURA)
   Objetivo:    Identificar las tarifas de ADUANA (dbo.TarifaAduana) que quedaron con
                ProcesadoEstadoTyT = 2 porque a la fecha de proceso les faltaba
                ClienteTyTID, TipoHonorarioTyT, ClienteEchoID o TipoHonorarioEcho
                (o porque sp_insert_tarifa_aduana_zoho_dobra agoto sus 4 intentos de
                reintento), y que HOY ya tienen esa informacion completa y ni el
                cliente TyT ni el cliente Echo estan anulados.

   Basado en:   script-TA.sql (misma consulta / mismos JOIN) +
                sp_insert_tarifa_aduana_zoho_dobra.sql (logica de reintentos: se
                informa el No_intentos actual de dbo.TarifaAduana_Cliente_Honorario).

   ------------------------------------------------------------------------------------
   VALIDACION DE CAMPOS OBLIGATORIOS (NO deben ser NULL) - segun lo pedido por el usuario:
                - ClienteTyTID       (CLI.ID, base TyT.dbo.CLI_CLIENTES)
                - TipoHonorarioTyT   (TH.IdDobraTyT)
                - ClienteEchoID      (CLIE.ID, base OperativoTyT.dbo.clientes)
                - TipoHonorarioEcho  (TH.IdEcho)
                NOTA: el SP tambien valida Cotizacion e IdAccount como parte de sus
                "VALIDACIONES PREVIAS" (6 campos), pero el usuario solo pidio validar
                estos 4 para este script. Se respeta la lista tal como la dio.

   Condiciones adicionales para ser ELEGIBLE:
                - AnuladoTyT  = 0   (CLI.Anulado = 0)
                - AnuladoEcho = 0   (CASE WHEN CLIE.deleted_at IS NULL THEN 0 ELSE 1 END,
                  igual que en script-TA.sql; el JOIN a CLIE NO filtra por deleted_at,
                  asi que un cliente Echo eliminado SI hace match y se detecta como
                  anulado en vez de caer como "incompleta")
                - TA.ProcesadoEstadoTyT = 2
                NOTA: el Estado de la propia tarifa (TA.Estado='1-Inactivo') NO excluye;
                se informa solo como dato de contexto (mismo criterio ya usado en
                TarifaContenedor / TarifaCargaSuelta).

   ------------------------------------------------------------------------------------
   LOGICA DE REINTENTOS DEL SP (solo informativa en este script):
        El SP registra cada tarifa incompleta en dbo.TarifaAduana_Cliente_Honorario,
        con un contador No_intentos que va de 0 a 3 (4 intentos en total). Recien en
        el 4to intento marca ProcesadoEstadoTyT = 2 y ProcesadoEstadoEcho = 2 en
        dbo.TarifaAduana. Por eso, al regularizar, el script de UPDATE generado por
        generar_reporte_tarifas.py ademas resetea No_intentos = 0. Aqui solo se
        muestra el valor actual en cada linea [ELEGIBLE].

   SOLO LECTURA:
                Este script NO modifica ninguna tabla: no tiene UPDATE, INSERT,
                DELETE ni transacciones. Solo consulta, usa tablas temporales (#) e
                imprime en la pestana Messages el detalle y la linea "Resumen ->".
                Se puede ejecutar en produccion sin riesgo.

                La regularizacion (ProcesadoEstadoTyT/Echo 2 -> 0 y No_intentos = 0)
                se hace despues con los .sql que genera generar_reporte_tarifas.py a
                partir de esta salida (carpetas Update/ o update_lite/).

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

SET @msg = CONCAT('=== INICIO script-TA-Regularizacion (SOLO LECTURA) === fechaCreacion>=',
                   CONVERT(VARCHAR(23), @fechaCreacion, 121));
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 1) SNAPSHOT: misma consulta base de script-TA.sql, con flags calculados ----
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;

SELECT
        TA.Name                                               AS TarifaName,
        CO.Name                                                AS Cotizacion,
        CLI.ID                                                 AS ClienteTyTID,
        CLI.Anulado                                            AS AnuladoTyT,
        TH.IdDobraTyT                                          AS TipoHonorarioTyT,
        CLIE.ID                                                AS ClienteEchoID,
        CASE WHEN (CLIE.deleted_at IS NULL) THEN 0 ELSE 1 END  AS AnuladoEcho,
        TH.IdEcho                                              AS TipoHonorarioEcho,
        CASE WHEN TA.Estado = '1-Inactivo' THEN 1 ELSE 0 END   AS TarifaAnulada,
        TA.Created_Time                                        AS CreatedTime,
        TA.ProcesadoEstadoTyT                                  AS ProcesadoEstadoTyTActual,
        TA.ProcesadoEstadoEcho                                 AS ProcesadoEstadoEchoActual,
        CASE
            WHEN CLI.ID IS NULL OR TH.IdDobraTyT IS NULL OR CLIE.ID IS NULL OR TH.IdEcho IS NULL
                THEN 1 ELSE 0
        END                                                     AS Incompleta
INTO #Base
FROM        dbo.TarifaAduana TA
LEFT JOIN   dbo.Cotizacion CO              ON TA.CabeceraName = CO.Name
LEFT JOIN   dbo.Account_new A              ON CO.ClienteId = A.ZohoId
LEFT JOIN   TyT.dbo.CLI_CLIENTES CLI       ON CLI.Ruc = A.Nro_identificacion
LEFT JOIN   OperativoTyT.dbo.clientes CLIE ON CLIE.identificacion = A.Nro_identificacion
LEFT JOIN   dbo.Homologacion TS            ON (CASE WHEN LEFT(TA.Tipo_Servicio, CHARINDEX('-', TA.Tipo_Servicio + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TA.Tipo_Servicio, CHARINDEX('-', TA.Tipo_Servicio + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TA.Tipo_Servicio, CHARINDEX('-', TA.Tipo_Servicio + '-') - 1)) END) = TS.IdCRM AND TS.Catalogo = 'tipoSrvTorres'
LEFT JOIN   dbo.Homologacion TC            ON (CASE WHEN LEFT(TA.Tipo_Cotizacion, CHARINDEX('-', TA.Tipo_Cotizacion + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TA.Tipo_Cotizacion, CHARINDEX('-', TA.Tipo_Cotizacion + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TA.Tipo_Cotizacion, CHARINDEX('-', TA.Tipo_Cotizacion + '-') - 1)) END) = TC.IdCRM AND TC.Catalogo = 'tipoCotizacionID'
LEFT JOIN   dbo.Homologacion TH            ON (CASE WHEN LEFT(TA.Honorario, CHARINDEX('-', TA.Honorario + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TA.Honorario, CHARINDEX('-', TA.Honorario + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TA.Honorario, CHARINDEX('-', TA.Honorario + '-') - 1)) END) = TH.IdCRM AND TH.Catalogo = 'honorariotyt'
WHERE       TA.ProcesadoEstadoTyT = 2
AND         (TA.Created_Time >= @fechaCreacion OR TA.Modified_Time >= @fechaCreacion);

DECLARE @TotalEvaluadas INT = (SELECT COUNT(*) FROM #Base);
SET @msg = CONCAT('Filas evaluadas (ProcesadoEstadoTyT=2, filtro de fecha): ', @TotalEvaluadas);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 2) CLASIFICACION (solo SELECT, sin UPDATE) ---------------------------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;

SELECT
        B.*,
        TRK.No_intentos                                        AS NoIntentosActual,
        CAST(CASE
                WHEN B.Incompleta = 1 THEN 0
                WHEN ISNULL(B.AnuladoTyT,1) <> 0 THEN 0
                WHEN ISNULL(B.AnuladoEcho,1) <> 0 THEN 0
                ELSE 1
             END AS BIT)                                       AS Elegible,
        CAST(CASE
                WHEN B.Incompleta = 1 THEN 'INCOMPLETA'
                WHEN ISNULL(B.AnuladoTyT,1) <> 0 AND ISNULL(B.AnuladoEcho,1) <> 0 THEN 'ANULADO_TYT_Y_ECHO'
                WHEN ISNULL(B.AnuladoTyT,1) <> 0 THEN 'ANULADO_TYT'
                WHEN ISNULL(B.AnuladoEcho,1) <> 0 THEN 'ANULADO_ECHO'
                ELSE 'ELEGIBLE'
             END AS VARCHAR(40))                               AS Motivo
INTO #Tarifas
FROM #Base B
OUTER APPLY (
        SELECT TOP 1 TCH.No_intentos
        FROM dbo.TarifaAduana_Cliente_Honorario TCH
        WHERE TCH.Name = B.TarifaName
) TRK;

DECLARE @TotalIncompletas INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'INCOMPLETA');
DECLARE @TotalAnulado     INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo IN ('ANULADO_TYT_Y_ECHO','ANULADO_TYT','ANULADO_ECHO'));
DECLARE @TotalElegibles   INT = (SELECT COUNT(*) FROM #Tarifas WHERE Elegible = 1);

------------------------------------------------------------------------------
-- 3) DETALLE PASO A PASO -------------------------------------------------------
------------------------------------------------------------------------------
RAISERROR('--- Tarifas INCOMPLETAS (no se actualizan, quedan en ProcesadoEstadoTyT=2) ---', 0, 1) WITH NOWAIT;
IF @TotalIncompletas = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur1 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName,
               CASE WHEN ClienteTyTID IS NULL THEN 'ClienteTyTID ' ELSE '' END +
               CASE WHEN TipoHonorarioTyT IS NULL THEN 'TipoHonorarioTyT ' ELSE '' END +
               CASE WHEN ClienteEchoID IS NULL THEN 'ClienteEchoID ' ELSE '' END +
               CASE WHEN TipoHonorarioEcho IS NULL THEN 'TipoHonorarioEcho ' ELSE '' END,
               NoIntentosActual
        FROM #Tarifas WHERE Motivo = 'INCOMPLETA' ORDER BY TarifaName;
    DECLARE @n1 NVARCHAR(200), @c1 NVARCHAR(200), @ni1 INT;
    OPEN cur1; FETCH NEXT FROM cur1 INTO @n1, @c1, @ni1;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [INCOMPLETA] ', @n1, ' -> campo(s) vacio(s): ', @c1,
                           ' (No_intentos actual en tracking: ', ISNULL(CONVERT(VARCHAR(10), @ni1), 'sin registro'), ')');
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur1 INTO @n1, @c1, @ni1;
    END
    CLOSE cur1; DEALLOCATE cur1;
END

RAISERROR('--- Tarifas COMPLETAS pero con cliente TyT y/o Echo ANULADO (no se actualizan) ---', 0, 1) WITH NOWAIT;
IF @TotalAnulado = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur2 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName, Motivo FROM #Tarifas
        WHERE Motivo IN ('ANULADO_TYT_Y_ECHO','ANULADO_TYT','ANULADO_ECHO')
        ORDER BY TarifaName;
    DECLARE @n2 NVARCHAR(200), @m2 VARCHAR(40);
    OPEN cur2; FETCH NEXT FROM cur2 INTO @n2, @m2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [', @m2, '] ', @n2);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur2 INTO @n2, @m2;
    END
    CLOSE cur2; DEALLOCATE cur2;
END

RAISERROR('--- Tarifas ELEGIBLES para regularizar (ProcesadoEstadoTyT/Echo 2 -> 0) ---', 0, 1) WITH NOWAIT;
IF @TotalElegibles = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur3 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName, TarifaAnulada, NoIntentosActual FROM #Tarifas WHERE Elegible = 1 ORDER BY TarifaName;
    DECLARE @n3 NVARCHAR(200), @ta3 BIT, @ni3 INT;
    OPEN cur3; FETCH NEXT FROM cur3 INTO @n3, @ta3, @ni3;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [ELEGIBLE] ', @n3,
                           CASE WHEN @ta3 = 1 THEN ' (tarifa Estado=1-Inactivo, de todas formas se actualiza)' ELSE '' END,
                           CASE WHEN @ni3 IS NOT NULL THEN CONCAT(' [tracking: No_intentos=', @ni3, ' -> se reseteara a 0]') ELSE ' [sin fila en TarifaAduana_Cliente_Honorario]' END);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur3 INTO @n3, @ta3, @ni3;
    END
    CLOSE cur3; DEALLOCATE cur3;
END

SET @msg = CONCAT('Resumen -> Evaluadas: ', @TotalEvaluadas,
                   ' | Incompletas: ', @TotalIncompletas,
                   ' | Cliente TyT/Echo anulado: ', @TotalAnulado,
                   ' | Elegibles para UPDATE: ', @TotalElegibles);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 4) LIMPIEZA -----------------------------------------------------------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;
IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;

SET @msg = CONCAT('=== FIN script-TA-Regularizacion (SOLO LECTURA, no se modifico nada) === Duracion: ',
                   DATEDIFF(SECOND, @FechaInicio, GETDATE()), ' segundo(s)');
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
GO
