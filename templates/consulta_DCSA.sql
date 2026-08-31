{HEADER}

Use TyT_APICtrl;

SELECT CO.Name AS Cotizacion ,TSA.Name AS ZohoCrmId
    ,CLI.ID AS ClienteId ,CLI.Anulado as cli_anulado
    ,TR.IdDobraCia AS RutaId
    ,TH.IdDobraCia AS HonorarioId
    ,TSA.Valor AS Precio
    ,TTC.IdDobraCia AS TipoCotizacionId
    ,CASE WHEN(TSA.Estado = '1-Inactivo') THEN 1 ELSE 0 END AS Anulado
    ,TSA.ProcesadoEstado ,TSA.ProcesadoMensaje
    ,TSA.Modified_Time ,TSA.Created_Time

    FROM  dbo.TarifaServiciosAdicionales TSA
    LEFT JOIN dbo.Cotizacion CO on TSA.CabeceraName = CO.Name
    LEFT JOIN dbo.Account_new A ON CO.ClienteId = A.ZohoId
    LEFT JOIN Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
    LEFT JOIN dbo.Homologacion TR ON LEFT(TSA.Ruta, CHARINDEX('-', TSA.Ruta + '-') - 1) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
    LEFT JOIN dbo.Homologacion TH ON LEFT(TSA.Honorario, CHARINDEX('-', TSA.Honorario + '-') - 1) = TH.IdCRM AND TH.Catalogo = 'honorarioCIA'
    LEFT JOIN  dbo.Homologacion TTC ON LEFT(TSA.Tipo_cotizacion, CHARINDEX('-', TSA.Tipo_cotizacion + '-') - 1) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
    WHERE TSA.Name in (
        <lista_tarifas_ServiciosAdicionales>
    )