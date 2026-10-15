/* =====================================================================================
   Script:      script-TSA-Regularizacion.sql   (SOLO LECTURA)
   Objetivo:    Identificar las tarifas de SERVICIOS ADICIONALES
                (dbo.TarifaServiciosAdicionales) que quedaron con ProcesadoEstado = 2
                porque a la fecha de proceso les faltaba ClienteID, HonorarioID, Precio,
                RutaId o TipoCotizacionId, o porque el SP
                sp_insert_tarifa_servicio_adicional_zoho_dobra las marco como "claves
                compuestas identicas" (duplicadas), y clasificar cuales son ELEGIBLES
                para regularizar.

   Basado en:   script-TSA.sql (misma consulta / mismos JOIN) +
                sp_insert_tarifa_servicio_adicional_zoho_dobra.sql (logica de deteccion
                de duplicados, reutilizada para clasificar el motivo del duplicado).

   ------------------------------------------------------------------------------------
   VALIDACION DE CAMPOS OBLIGATORIOS (NO deben ser NULL):
                - ClienteId          (CLI.ID)
                - HonorarioId        (TH.IdDobraCia)
                - Precio              (TSA.Valor)
                - TipoCotizacionId   (TTC.IdDobraCia)
                - RutaId             (TR.IdDobraCia)
                (Cotizacion NO se valida para TSA; el usuario no la incluyo en la lista)

   ------------------------------------------------------------------------------------
   LOGICA DE DUPLICADOS (clave de negocio = ClienteId + HonorarioId + RutaId + Precio +
   TipoCotizacionId), tomada del SP y confirmada con el usuario.

   Ajuste (Jose Velez - 21/08/2026): el SP sp_insert_tarifa_servicio_adicional_zoho_dobra
   cambio el 19/08/2026 su "VALIDACION 2" (ganador entre duplicados del mismo lote). Este
   script se actualizo para reflejar exactamente esa nueva logica, en vez de la anterior
   ("gana la de menor Created_Time").

   CASO 1 - Ya existe en Dobra (NO elegible):
        La clave de negocio de la tarifa YA existe en cia.dbo.CLI_CLIENTES_TARIFAS_
        SERVICIOS_ADICIONALES bajo OTRO ZohoCrmId, exigiendo ademas que el campo
        Anulado coincida (igual criterio que usa el SP en su primer JOIN). Esto
        significa que cuando la tarifa se creo no estaba duplicada, pero al
        actualizarla se genero el duplicado contra Dobra. Se identifica y se lista,
        pero NO es elegible.

   CASO 2 y 3 - Duplicado dentro del mismo lote (no existe en Dobra bajo otro ZohoCrmId):
        Si la clave de negocio no cae en Caso 1, se compara contra el "lote": TODAS
        las filas de dbo.TarifaServiciosAdicionales que cumplen el mismo filtro de
        fecha del script (Created_Time >= @fechaCreacion OR Modified_Time >= @fechaCreacion),
        SIN filtrar por ProcesadoEstado (confirmado por el usuario), y que tengan los
        5 campos de la clave completos. La clave de agrupacion incluye ademas Anulado
        (ClienteId + HonorarioId + RutaId + Precio + TipoCotizacionId + Anulado), igual
        que el PARTITION BY de la VALIDACION 2 del SP.
            - Si dentro de ese grupo hay 2 o mas filas, la GANADORA (ELEGIBLE) se elige
              con el mismo criterio de desempate que usa hoy el SP, en este orden:
                1) Prioridad a la fila cuyo propio ZohoCrmId YA existe en Dobra
                   (ExisteEnDobra = 1, es decir ya fue sincronizada antes; equivale al
                   EXISTS por ZohoCrmId de la VALIDACION 2 del SP).
                2) Entre las restantes, gana la de Modified_Time (o Created_Time si
                   Modified_Time es NULL) MAS RECIENTE (DESC) - ya NO gana la mas antigua.
                3) Desempate final por ZohoCrmId ascendente.
            - El resto de filas del mismo grupo son NO elegibles (esto cubre tanto
              "duplicada con otra tarifa del lote que ya esta en Dobra" como "duplicada
              con otra tarifa nueva del lote").

   Si una tarifa no cae en Caso 1 ni tiene ningun duplicado en el lote, es ELEGIBLE
   directamente (sin relacion con Dobra ni con otras filas).

   La clasificacion se recalcula en cada corrida contra el estado actual de Dobra y
   del lote, por lo que si una tarifa "no elegible" se corrige/depura despues, puede
   volverse elegible en una corrida futura sin intervencion manual.

   ------------------------------------------------------------------------------------
   SOLO LECTURA:
                Este script NO modifica ninguna tabla: no tiene UPDATE, INSERT,
                DELETE ni transacciones. Solo consulta, usa tablas temporales (#) e
                imprime en la pestana Messages el detalle y la linea "Resumen ->".
                Se puede ejecutar en produccion sin riesgo.

                La regularizacion (ProcesadoEstado 2 -> 0 en
                dbo.TarifaServiciosAdicionales) se hace despues con los .sql que genera
                generar_reporte_tarifas.py a partir de esta salida (carpetas Update/ o
                update_lite/).

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

SET @msg = CONCAT('=== INICIO script-TSA-Regularizacion (SOLO LECTURA) === fechaCreacion>=',
                   CONVERT(VARCHAR(23), @fechaCreacion, 121));
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 1) SNAPSHOT PRINCIPAL: misma consulta base de script-TSA.sql (ProcesadoEstado=2) --
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;

SELECT
        TSA.Name                                              AS TarifaName,
        CO.Name                                                AS Cotizacion,
        CLI.ID                                                 AS ClienteId,
        CLI.Anulado                                            AS cli_anulado,
        TH.IdDobraCia                                          AS HonorarioId,
        TSA.Valor                                              AS Precio,
        TR.IdDobraCia                                          AS RutaId,
        TTC.IdDobraCia                                         AS TipoCotizacionId,
        CASE WHEN TSA.Estado = '1-Inactivo' THEN 1 ELSE 0 END  AS TarifaAnulada,
        TSA.Created_Time                                       AS CreatedTime,
        TSA.Modified_Time                                      AS ModifiedTime,
        TSA.ProcesadoEstado                                    AS ProcesadoEstadoActual,
        CASE
            WHEN CLI.ID IS NULL OR TH.IdDobraCia IS NULL OR TSA.Valor IS NULL
              OR TR.IdDobraCia IS NULL OR TTC.IdDobraCia IS NULL
                THEN 1 ELSE 0
        END                                                     AS Incompleta,
        CASE WHEN EXISTS (
            SELECT 1 FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES D0
            WHERE D0.ZohoCrmId = TSA.Name
        ) THEN 1 ELSE 0 END                                     AS ExisteEnDobra
INTO #Base
FROM        dbo.TarifaServiciosAdicionales TSA
LEFT JOIN   dbo.Cotizacion CO   ON TSA.CabeceraName = CO.Name
LEFT JOIN   dbo.Account_new A   ON CO.ClienteId = A.ZohoId
LEFT JOIN   Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
LEFT JOIN   dbo.Homologacion TR  ON (CASE WHEN LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1)) END) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
LEFT JOIN   dbo.Homologacion TH  ON (CASE WHEN LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1)) END) = TH.IdCRM AND TH.Catalogo = 'honorarioCIA'
LEFT JOIN   dbo.Homologacion TTC ON (CASE WHEN LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1)) END) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
WHERE       TSA.ProcesadoEstado = 2
AND         (TSA.Created_Time >= @fechaCreacion OR TSA.Modified_Time >= @fechaCreacion);

DECLARE @TotalEvaluadas INT = (SELECT COUNT(*) FROM #Base);
SET @msg = CONCAT('Filas evaluadas (ProcesadoEstado=2, filtro de fecha): ', @TotalEvaluadas);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 2) SNAPSHOT AMPLIO DEL LOTE: TODA la tabla (cualquier ProcesadoEstado) con el --
--    mismo filtro de fecha, solo filas con la clave de negocio completa --------
--    (se usa para detectar duplicados dentro del lote, Casos 2 y 3) ------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#LoteAmplio') IS NOT NULL DROP TABLE #LoteAmplio;

SELECT
        TSA.Name        AS TarifaName,
        CLI.ID          AS ClienteId,
        TH.IdDobraCia   AS HonorarioId,
        TSA.Valor       AS Precio,
        TR.IdDobraCia   AS RutaId,
        TTC.IdDobraCia  AS TipoCotizacionId,
        CASE WHEN TSA.Estado = '1-Inactivo' THEN 1 ELSE 0 END AS TarifaAnulada,
        TSA.Created_Time  AS CreatedTime,
        TSA.Modified_Time AS ModifiedTime,
        CASE WHEN EXISTS (
            SELECT 1 FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES D0
            WHERE D0.ZohoCrmId = TSA.Name
        ) THEN 1 ELSE 0 END AS ExisteEnDobra
INTO #LoteAmplio
FROM        dbo.TarifaServiciosAdicionales TSA
LEFT JOIN   dbo.Cotizacion CO   ON TSA.CabeceraName = CO.Name
LEFT JOIN   dbo.Account_new A   ON CO.ClienteId = A.ZohoId
LEFT JOIN   Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
LEFT JOIN   dbo.Homologacion TR  ON (CASE WHEN LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1)) END) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
LEFT JOIN   dbo.Homologacion TH  ON (CASE WHEN LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1)) END) = TH.IdCRM AND TH.Catalogo = 'honorarioCIA'
LEFT JOIN   dbo.Homologacion TTC ON (CASE WHEN LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1)) END) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
WHERE       (TSA.Created_Time >= @fechaCreacion OR TSA.Modified_Time >= @fechaCreacion)
AND         CLI.ID IS NOT NULL AND TH.IdDobraCia IS NOT NULL AND TSA.Valor IS NOT NULL
AND         TR.IdDobraCia IS NOT NULL AND TTC.IdDobraCia IS NOT NULL;

-- Grupo de duplicados dentro del lote (clave de negocio + Anulado, igual al PARTITION BY
-- de la VALIDACION 2 del SP) + orden por el mismo criterio de desempate que usa hoy el SP:
-- 1) ExisteEnDobra (ya sincronizada antes) gana primero
-- 2) Modified_Time/Created_Time mas reciente (DESC) gana despues
-- 3) ZohoCrmId ASC como desempate final
IF OBJECT_ID('tempdb..#LoteGrupos') IS NOT NULL DROP TABLE #LoteGrupos;

SELECT
        TarifaName,
        CreatedTime,
        ModifiedTime,
        ExisteEnDobra,
        COUNT(*) OVER (PARTITION BY ClienteId, HonorarioId, RutaId, Precio, TipoCotizacionId, TarifaAnulada) AS GroupCount,
        ROW_NUMBER() OVER (
            PARTITION BY ClienteId, HonorarioId, RutaId, Precio, TipoCotizacionId, TarifaAnulada
            ORDER BY
                CASE WHEN ExisteEnDobra = 1 THEN 0 ELSE 1 END ASC,
                ISNULL(ModifiedTime, CreatedTime) DESC,
                TarifaName ASC
        ) AS RowNumEnGrupo
INTO #LoteGrupos
FROM #LoteAmplio;

------------------------------------------------------------------------------
-- 3) UNIVERSO DOBRA: clave de negocio + Anulado, distinct, excluyendo self-match --
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#DobraTSA') IS NOT NULL DROP TABLE #DobraTSA;

SELECT DISTINCT
        ClienteID, HonorarioID, Precio, TipoCotizacionID, RutaID, Anulado, ZohoCrmId
INTO #DobraTSA
FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES;

------------------------------------------------------------------------------
-- 4) CLASIFICACION FINAL (solo SELECT, sin UPDATE) ----------------------------
--    EnDobra           -> la clave (+ Anulado) existe en Dobra con OTRO ZohoCrmId
--    GroupCount        -> tamano del grupo duplicado en el lote (1 si no esta en el lote)
--    EsPrimeraDelGrupo -> es la ganadora del grupo segun el desempate del SP
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;

SELECT
        B.*,
        K.EnDobra,
        K.GroupCount,
        K.EsPrimeraDelGrupo,
        CAST(CASE
                WHEN B.Incompleta = 1 THEN 0
                WHEN ISNULL(B.cli_anulado,1) <> 0 THEN 0
                WHEN K.EnDobra = 1 THEN 0
                WHEN K.GroupCount > 1 AND K.EsPrimeraDelGrupo = 0 THEN 0
                ELSE 1
             END AS BIT)                                       AS Elegible,
        CAST(CASE
                WHEN B.Incompleta = 1 THEN 'INCOMPLETA'
                WHEN ISNULL(B.cli_anulado,1) <> 0 THEN 'CLIENTE_ANULADO'
                WHEN K.EnDobra = 1 THEN 'CASO1_YA_EN_DOBRA'
                WHEN K.GroupCount > 1 AND K.EsPrimeraDelGrupo = 0 THEN 'CASO2_3_DUPLICADO_LOTE_NO_PRIMERO'
                WHEN K.GroupCount > 1 AND K.EsPrimeraDelGrupo = 1 THEN 'CASO3_DUPLICADO_LOTE_PRIMERO'
                ELSE 'SIN_DUPLICADO'
             END AS VARCHAR(60))                               AS Motivo
INTO #Tarifas
FROM #Base B
OUTER APPLY (
        SELECT TOP 1 LG.GroupCount, LG.RowNumEnGrupo
        FROM #LoteGrupos LG
        WHERE LG.TarifaName = B.TarifaName
) G
CROSS APPLY (
        SELECT
            CAST(CASE WHEN EXISTS (
                SELECT 1 FROM #DobraTSA D
                WHERE D.ClienteID                 = B.ClienteId
                  AND ISNULL(D.HonorarioID,'')      = ISNULL(B.HonorarioId,'')
                  AND ISNULL(D.RutaID,'')           = ISNULL(B.RutaId,'')
                  AND ISNULL(D.Precio,0)            = ISNULL(B.Precio,0)
                  AND ISNULL(D.TipoCotizacionID,'') = ISNULL(B.TipoCotizacionId,'')
                  AND D.Anulado                     = B.TarifaAnulada
                  AND D.ZohoCrmId                   <> B.TarifaName
            ) THEN 1 ELSE 0 END AS BIT)                              AS EnDobra,
            ISNULL(G.GroupCount, 1)                                  AS GroupCount,
            CAST(CASE WHEN G.RowNumEnGrupo = 1 THEN 1 ELSE 0 END AS BIT) AS EsPrimeraDelGrupo
) K;

DECLARE @TotalIncompletas    INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'INCOMPLETA');
DECLARE @TotalClienteAnulado INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'CLIENTE_ANULADO');
DECLARE @TotalCaso1          INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'CASO1_YA_EN_DOBRA');
DECLARE @TotalCaso23         INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'CASO2_3_DUPLICADO_LOTE_NO_PRIMERO');
DECLARE @TotalCaso3Primera   INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'CASO3_DUPLICADO_LOTE_PRIMERO');
DECLARE @TotalSinDuplicado   INT = (SELECT COUNT(*) FROM #Tarifas WHERE Motivo = 'SIN_DUPLICADO');
DECLARE @TotalElegibles      INT = (SELECT COUNT(*) FROM #Tarifas WHERE Elegible = 1);

------------------------------------------------------------------------------
-- 5) DETALLE PASO A PASO por cada bucket --------------------------------------
------------------------------------------------------------------------------
RAISERROR('--- Tarifas INCOMPLETAS (no se actualizan, quedan en ProcesadoEstado=2) ---', 0, 1) WITH NOWAIT;
IF @TotalIncompletas = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur1 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName,
               CASE WHEN ClienteId IS NULL THEN 'ClienteId ' ELSE '' END +
               CASE WHEN HonorarioId IS NULL THEN 'HonorarioId ' ELSE '' END +
               CASE WHEN Precio IS NULL THEN 'Precio ' ELSE '' END +
               CASE WHEN RutaId IS NULL THEN 'RutaId ' ELSE '' END +
               CASE WHEN TipoCotizacionId IS NULL THEN 'TipoCotizacionId ' ELSE '' END
        FROM #Tarifas WHERE Motivo = 'INCOMPLETA' ORDER BY TarifaName;
    DECLARE @n1 NVARCHAR(200), @c1 NVARCHAR(200);
    OPEN cur1; FETCH NEXT FROM cur1 INTO @n1, @c1;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [INCOMPLETA] ', @n1, ' -> campo(s) vacio(s): ', @c1);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur1 INTO @n1, @c1;
    END
    CLOSE cur1; DEALLOCATE cur1;
END

RAISERROR('--- Tarifas COMPLETAS pero con cliente ANULADO (no se actualizan) ---', 0, 1) WITH NOWAIT;
IF @TotalClienteAnulado = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur2 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName FROM #Tarifas WHERE Motivo = 'CLIENTE_ANULADO' ORDER BY TarifaName;
    DECLARE @n2 NVARCHAR(200);
    OPEN cur2; FETCH NEXT FROM cur2 INTO @n2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [CLIENTE ANULADO] ', @n2);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur2 INTO @n2;
    END
    CLOSE cur2; DEALLOCATE cur2;
END

RAISERROR('--- CASO 1: ya existe en Dobra con otro ZohoCrmId (no se actualizan) ---', 0, 1) WITH NOWAIT;
IF @TotalCaso1 = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur3 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName FROM #Tarifas WHERE Motivo = 'CASO1_YA_EN_DOBRA' ORDER BY TarifaName;
    DECLARE @n3 NVARCHAR(200);
    OPEN cur3; FETCH NEXT FROM cur3 INTO @n3;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [CASO1 - YA EN DOBRA] ', @n3);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur3 INTO @n3;
    END
    CLOSE cur3; DEALLOCATE cur3;
END

RAISERROR('--- CASO 2/3: duplicado dentro del lote, NO es la ganadora del grupo (no se actualizan) ---', 0, 1) WITH NOWAIT;
IF @TotalCaso23 = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur4 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName, CreatedTime, ModifiedTime, ExisteEnDobra, GroupCount FROM #Tarifas WHERE Motivo = 'CASO2_3_DUPLICADO_LOTE_NO_PRIMERO' ORDER BY TarifaName;
    DECLARE @n4 NVARCHAR(200), @ct4 DATETIME, @mt4 DATETIME, @ed4 BIT, @gc4 INT;
    OPEN cur4; FETCH NEXT FROM cur4 INTO @n4, @ct4, @mt4, @ed4, @gc4;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [CASO2/3 - NO GANADORA] ', @n4,
                           ' (Created_Time=', CONVERT(VARCHAR(23), @ct4, 121),
                           ', Modified_Time=', ISNULL(CONVERT(VARCHAR(23), @mt4, 121), 'NULL'),
                           ', ExisteEnDobra=', @ed4,
                           ', tamano del grupo duplicado=', @gc4, ')');
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur4 INTO @n4, @ct4, @mt4, @ed4, @gc4;
    END
    CLOSE cur4; DEALLOCATE cur4;
END

RAISERROR('--- Tarifas ELEGIBLES para regularizar (ProcesadoEstado 2 -> 0) ---', 0, 1) WITH NOWAIT;
IF @TotalElegibles = 0
    RAISERROR('  (ninguna)', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE cur5 CURSOR LOCAL FAST_FORWARD FOR
        SELECT TarifaName, Motivo, GroupCount, ExisteEnDobra FROM #Tarifas WHERE Elegible = 1 ORDER BY TarifaName;
    DECLARE @n5 NVARCHAR(200), @m5 VARCHAR(60), @gc5 INT, @ed5 BIT;
    OPEN cur5; FETCH NEXT FROM cur5 INTO @n5, @m5, @gc5, @ed5;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = CONCAT('  [ELEGIBLE] ', @n5,
                           CASE WHEN @m5 = 'CASO3_DUPLICADO_LOTE_PRIMERO'
                                THEN CONCAT(' (ganadora de un grupo duplicado de ', @gc5, ' en el lote -> ExisteEnDobra=', @ed5, ', sin relacion con Caso1 en Dobra)')
                                ELSE '' END);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
        FETCH NEXT FROM cur5 INTO @n5, @m5, @gc5, @ed5;
    END
    CLOSE cur5; DEALLOCATE cur5;
END

SET @msg = CONCAT('Resumen -> Evaluadas: ', @TotalEvaluadas,
                   ' | Incompletas: ', @TotalIncompletas,
                   ' | Cliente anulado: ', @TotalClienteAnulado,
                   ' | Caso1 (ya en Dobra): ', @TotalCaso1,
                   ' | Caso2/3 (duplicado lote, no ganadora): ', @TotalCaso23,
                   ' | Caso3 (duplicado lote, ganadora): ', @TotalCaso3Primera,
                   ' | Sin duplicado: ', @TotalSinDuplicado,
                   ' | Elegibles para UPDATE: ', @TotalElegibles);
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

------------------------------------------------------------------------------
-- 6) LIMPIEZA -----------------------------------------------------------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;
IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;
IF OBJECT_ID('tempdb..#LoteAmplio') IS NOT NULL DROP TABLE #LoteAmplio;
IF OBJECT_ID('tempdb..#LoteGrupos') IS NOT NULL DROP TABLE #LoteGrupos;
IF OBJECT_ID('tempdb..#DobraTSA') IS NOT NULL DROP TABLE #DobraTSA;

SET @msg = CONCAT('=== FIN script-TSA-Regularizacion (SOLO LECTURA, no se modifico nada) === Duracion: ',
                   DATEDIFF(SECOND, @FechaInicio, GETDATE()), ' segundo(s)');
RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
GO
