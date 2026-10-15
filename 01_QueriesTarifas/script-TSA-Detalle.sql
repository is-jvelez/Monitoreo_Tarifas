SET NOCOUNT ON;
USE TyT_APICtrl;
GO

------------------------------------------------------------------------------
-- PARAMETRO: desde que fecha se revisa (hoy 3pm) -----------------------------
------------------------------------------------------------------------------
DECLARE @fechaCreacion DATETIME = '2026-10-14 15:00:00.000';

------------------------------------------------------------------------------
-- 1) FOTO GENERAL: todo lo modificado/creado desde esa hora, sin filtrar -----
--    por ProcesadoEstado -> aqui ves OK / Pendiente / Error de un vistazo ---
------------------------------------------------------------------------------
SELECT
    CASE TSA.ProcesadoEstado
         WHEN 0 THEN 'PENDIENTE'
         WHEN 1 THEN 'PROCESADO OK'
         WHEN 2 THEN 'ERROR'
         ELSE 'DESCONOCIDO'
    END                         AS EstadoReplicacion,
    COUNT(*)                    AS Cantidad
FROM dbo.TarifaServiciosAdicionales TSA
WHERE TSA.Created_Time >= @fechaCreacion OR TSA.Modified_Time >= @fechaCreacion
GROUP BY TSA.ProcesadoEstado
ORDER BY TSA.ProcesadoEstado;

------------------------------------------------------------------------------
-- 2) SNAPSHOT de las que estan en ERROR (ProcesadoEstado=2), igual que ------
--    script-TSA.sql, solo que aqui NO se tocan datos -------------------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;

SELECT
        TSA.Name                                              AS TarifaName,
        CO.Name                                                AS Cotizacion,
        CLI.ID                                                 AS ClienteId,
        CLI.RUC, CLI.Nombre,
        CLI.Anulado                                            AS cli_anulado,
        TH.IdDobraCia                                          AS HonorarioId,
        TSA.Valor                                              AS Precio,
        TR.IdDobraCia                                          AS RutaId,
        TTC.IdDobraCia                                         AS TipoCotizacionId,
        CASE WHEN TSA.Estado = '1-Inactivo' THEN 1 ELSE 0 END  AS TarifaAnulada,
        TSA.Created_Time                                       AS CreatedTime,
        TSA.Modified_Time                                      AS ModifiedTime,
        TSA.ProcesadoEstado                                    AS ProcesadoEstadoActual,
        TSA.ProcesadoMensaje                                   AS ProcesadoMensajeActual,
        TSA.ProcesadoFecha                                     AS ProcesadoFechaActual,
        CASE
            WHEN CLI.ID IS NULL OR TH.IdDobraCia IS NULL OR TSA.Valor IS NULL
              OR TR.IdDobraCia IS NULL OR TTC.IdDobraCia IS NULL
                THEN 1 ELSE 0
        END                                                     AS Incompleta,
        CAST(0 AS BIT)                                         AS EnDobra,
        CASE WHEN DSelf.pkID IS NOT NULL THEN 1 ELSE 0 END      AS ExisteEnDobra,
        DSelf.pkID                                              AS PkIdDobra,
        CAST(1 AS INT)                                         AS GroupCount,
        CAST(0 AS BIT)                                         AS EsPrimeraDelGrupo,
        CAST(0 AS BIT)                                         AS Elegible,
        CAST(NULL AS VARCHAR(60))                              AS Motivo
INTO #Tarifas
FROM        dbo.TarifaServiciosAdicionales TSA
LEFT JOIN   dbo.Cotizacion CO   ON TSA.CabeceraName = CO.Name
LEFT JOIN   dbo.Account_new A   ON CO.ClienteId = A.ZohoId
LEFT JOIN   Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion AND CLI.Anulado = 0
LEFT JOIN   dbo.Homologacion TR  ON (CASE WHEN LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1)) END) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
LEFT JOIN   dbo.Homologacion TH  ON (CASE WHEN LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1)) END) = TH.IdCRM AND TH.Catalogo = 'honorarioCIA'
LEFT JOIN   dbo.Homologacion TTC ON (CASE WHEN LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) NOT LIKE '%[^0-9]%' AND LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) <> '' THEN CONVERT(NUMERIC(25,0), LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1)) END) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
LEFT JOIN   Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES DSelf ON DSelf.ZohoCrmId = TSA.Name
WHERE       TSA.ProcesadoEstado = 2
AND         (TSA.Created_Time >= @fechaCreacion OR TSA.Modified_Time >= @fechaCreacion);

------------------------------------------------------------------------------
-- 3) LOTE AMPLIO + GRUPOS DE DUPLICADOS (igual que script-TSA.sql) ----------
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

IF OBJECT_ID('tempdb..#LoteGrupos') IS NOT NULL DROP TABLE #LoteGrupos;

SELECT
        TarifaName,
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
-- 4) UNIVERSO DOBRA + CLASIFICACION (igual que script-TSA.sql) --------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#DobraTSA') IS NOT NULL DROP TABLE #DobraTSA;

SELECT DISTINCT
        ClienteID, HonorarioID, Precio, TipoCotizacionID, RutaID, Anulado, ZohoCrmId
INTO #DobraTSA
FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES;

UPDATE T
    SET T.EnDobra = CASE WHEN D.ClienteID IS NOT NULL THEN 1 ELSE 0 END
FROM #Tarifas T
LEFT JOIN #DobraTSA D
       ON D.ClienteID            = T.ClienteId
      AND ISNULL(D.HonorarioID,'')      = ISNULL(T.HonorarioId,'')
      AND ISNULL(D.RutaID,'')           = ISNULL(T.RutaId,'')
      AND ISNULL(D.Precio,0)            = ISNULL(T.Precio,0)
      AND ISNULL(D.TipoCotizacionID,'') = ISNULL(T.TipoCotizacionId,'')
      AND D.Anulado                     = T.TarifaAnulada
      AND D.ZohoCrmId                   <> T.TarifaName;

UPDATE T
    SET T.GroupCount = LG.GroupCount,
        T.EsPrimeraDelGrupo = CASE WHEN LG.RowNumEnGrupo = 1 THEN 1 ELSE 0 END
FROM #Tarifas T
INNER JOIN #LoteGrupos LG ON LG.TarifaName = T.TarifaName;

UPDATE #Tarifas
    SET Elegible = CASE
                        WHEN Incompleta = 1 THEN 0
                        WHEN ISNULL(cli_anulado,1) <> 0 THEN 0
                        WHEN EnDobra = 1 THEN 0
                        WHEN GroupCount > 1 AND EsPrimeraDelGrupo = 0 THEN 0
                        ELSE 1
                    END,
        Motivo   = CASE
                        WHEN Incompleta = 1 THEN 'INCOMPLETA'
                        WHEN ISNULL(cli_anulado,1) <> 0 THEN 'CLIENTE_ANULADO'
                        WHEN EnDobra = 1 THEN 'CASO1_YA_EN_DOBRA'
                        WHEN GroupCount > 1 AND EsPrimeraDelGrupo = 0 THEN 'CASO2_3_DUPLICADO_LOTE_NO_PRIMERO'
                        WHEN GroupCount > 1 AND EsPrimeraDelGrupo = 1 THEN 'CASO3_DUPLICADO_LOTE_PRIMERO'
                        ELSE 'SIN_DUPLICADO'
                    END;

------------------------------------------------------------------------------
-- 5) RESULTADOS -- esto es lo que miras en produccion -----------------------
------------------------------------------------------------------------------

-- 5.1 Resumen de errores por motivo
SELECT Motivo, COUNT(*) AS Cantidad
FROM #Tarifas
GROUP BY Motivo
ORDER BY Cantidad DESC;

-- 5.2 Desglose de INCOMPLETAS: que campo(s) faltan y cuantas hay de cada combinacion
SELECT
    CASE WHEN ClienteId        IS NULL THEN 'ClienteId,'        ELSE '' END +
    CASE WHEN HonorarioId      IS NULL THEN 'HonorarioId,'      ELSE '' END +
    CASE WHEN Precio           IS NULL THEN 'Precio,'           ELSE '' END +
    CASE WHEN RutaId           IS NULL THEN 'RutaId,'           ELSE '' END +
    CASE WHEN TipoCotizacionId IS NULL THEN 'TipoCotizacionId,' ELSE '' END AS CamposFaltantes,
    COUNT(*) AS Cantidad
FROM #Tarifas
WHERE Incompleta = 1
GROUP BY
    CASE WHEN ClienteId        IS NULL THEN 'ClienteId,'        ELSE '' END +
    CASE WHEN HonorarioId      IS NULL THEN 'HonorarioId,'      ELSE '' END +
    CASE WHEN Precio           IS NULL THEN 'Precio,'           ELSE '' END +
    CASE WHEN RutaId           IS NULL THEN 'RutaId,'           ELSE '' END +
    CASE WHEN TipoCotizacionId IS NULL THEN 'TipoCotizacionId,' ELSE '' END
ORDER BY Cantidad DESC;

-- 5.3 Detalle fila por fila de TODAS las que estan en error, con su motivo
--     (para revisar una por una en Excel/SSMS)
SELECT
    RUC as Identificacion, Nombre as Cliente,TarifaName as Tarifa,PkIdDobra as CodigoDobra, Cotizacion, ClienteId, HonorarioId, RutaId, TipoCotizacionId,
    Precio, TarifaAnulada, CreatedTime, ModifiedTime,
    ProcesadoEstadoActual, ProcesadoMensajeActual, ProcesadoFechaActual,
    EnDobra, ExisteEnDobra,  GroupCount, EsPrimeraDelGrupo,
    Elegible, Motivo
FROM #Tarifas
ORDER BY Motivo, TarifaName;

-- SELECT COUNT(*) AS Filas, COUNT(DISTINCT TarifaName) AS Distintas FROM #Tarifas;

-- SELECT TarifaName, COUNT(*) AS Veces
-- FROM #Tarifas GROUP BY TarifaName HAVING COUNT(*) > 1;

-- -- Verificar cada join por separado
-- SELECT ZohoCrmId, COUNT(*) FROM Cia.dbo.CLI_CLIENTES_TARIFAS_SERVICIOS_ADICIONALES
-- GROUP BY ZohoCrmId HAVING COUNT(*) > 1;

-- SELECT Ruc, COUNT(*) FROM Cia.dbo.CLI_CLIENTES GROUP BY Ruc HAVING COUNT(*) > 1;

-- SELECT Catalogo, IdCRM, COUNT(*) FROM dbo.Homologacion
-- GROUP BY Catalogo, IdCRM HAVING COUNT(*) > 1;

------------------------------------------------------------------------------
-- 6) LIMPIEZA ------------------------------------------------------------------
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Tarifas') IS NOT NULL DROP TABLE #Tarifas;
IF OBJECT_ID('tempdb..#LoteAmplio') IS NOT NULL DROP TABLE #LoteAmplio;
IF OBJECT_ID('tempdb..#LoteGrupos') IS NOT NULL DROP TABLE #LoteGrupos;
IF OBJECT_ID('tempdb..#DobraTSA') IS NOT NULL DROP TABLE #DobraTSA;
GO
