{HEADER}

Use TyT_APICtrl;

SELECT CO.Name          AS Cotizacion , TA.Name AS ZohoCrmId
,TA.Honorario
    ,CLI.ID         AS ClienteTyTID ,CLI.Anulado as AnuladoTyT--*
    ,TH.IdDobraTyT  AS TipoHonorarioTyT --*
    ,TS.IdDobraTyT  AS TipoTarifaTyT

    ,CLIE.ID        AS ClienteEchoID
    ,CASE WHEN (CLIE.deleted_at is null) THEN 0 ELSE 1 END AS AnuladoEcho
    ,TH.IdEcho      AS TipoHonorarioEcho
    ,TS.IdEcho      AS TipoTarifaEcho

    ,TA.Valor       AS Precio
    ,CASE WHEN( TA.Estado = '1-Inactivo') THEN 1 ELSE 0 END AS Anulado
    ,TA.ProcesadoEstadoTyT ,TA.ProcesadoMensajeTyT
    ,TA.ProcesadoEstadoEcho ,TA.ProcesadoMensajeEcho
    ,TA.Modified_Time ,TA.Created_Time

    ,CLI.CreadoDate, CLI.EditadoDate

    FROM  dbo.TarifaAduana TA
    LEFT JOIN  dbo.Cotizacion CO                ON TA.CabeceraName = CO.Name
    LEFT JOIN dbo.Account_new A                 ON CO.ClienteId = A.ZohoId
    LEFT JOIN TyT.dbo.CLI_CLIENTES CLI          ON CLI.Ruc = A.Nro_identificacion
    LEFT JOIN OperativoTyT.dbo.clientes CLIE    ON CLIE.identificacion = A.Nro_identificacion
    LEFT JOIN dbo.Homologacion TS               ON LEFT(TA.Tipo_Servicio, CHARINDEX('-', TA.Tipo_Servicio + '-') - 1) = TS.IdCRM AND TS.Catalogo = 'tipoSrvTorres'
    LEFT JOIN dbo.Homologacion TC               ON LEFT(TA.Tipo_Cotizacion, CHARINDEX('-', TA.Tipo_Cotizacion + '-') - 1) = TC.IdCRM AND TC.Catalogo = 'tipoCotizacionID'
    LEFT JOIN dbo.Homologacion TH               ON LEFT(TA.Honorario, CHARINDEX('-', TA.Honorario + '-') - 1) = TH.IdCRM AND TH.Catalogo = 'honorariotyt'

    WHERE TA.NAME in (
        <lista_tarifas_aduana>
    );

SELECT * FROM dbo.TarifaAduana_Cliente_Honorario TH WHERE TH.Name in (
        <lista_tarifas_aduana>
    );