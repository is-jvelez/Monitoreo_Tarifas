{HEADER}

Use TyT_APICtrl;

SELECT CO.Name AS Cotizacion ,TCO.Name AS ZohoCrmId
    ,CLI.ID AS ClienteId ,CLI.Anulado as cli_anulado
    ,TR.IdDobraCia AS RutaId
    ,TTC.IdDobraCia AS TipoCotizacionId
    ,CASE WHEN(TCO.Estado = '1-Inactivo') THEN 1 ELSE 0 END AS Anulado
    ,TCO.ProcesadoEstado ,TCO.ProcesadoMensaje
    ,TCO.Modified_Time ,TCO.Created_Time

    FROM  dbo.TarifaContenedor TCO
    LEFT JOIN  dbo.Cotizacion CO on TCO.CotizacionCabName = CO.Name
    LEFT JOIN  dbo.Account_new A ON CO.ClienteId = A.ZohoId
    LEFT JOIN Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
    LEFT JOIN  dbo.Homologacion TR ON LEFT(TCO.Ruta, CHARINDEX('-', TCO.Ruta + '-') - 1) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
    LEFT JOIN  dbo.Homologacion TTC ON LEFT(TCO.Tipo_cotizacion, CHARINDEX('-', TCO.Tipo_cotizacion + '-') - 1) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
    WHERE TCO.Name in(
        <lista_tarifas_Contenedor>
    )