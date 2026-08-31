{HEADER}

Use TyT_APICtrl;

SELECT CO.Name AS Cotizacion ,TCS.Name AS ZohoCrmId
    ,CLI.ID AS ClienteId ,CLI.Anulado as cli_anulado
    ,TR.IdDobraCia      AS RutaId
    ,TTC.IdDobraCia     AS TipoCotizacionId
    ,TTO.IdDobraCia     AS TipoOperacionId
    ,TS.IdDobraCia      AS TipoServicioId
    ,TCA.IdDobraCia     AS TipoCamionId
    ,TTE.IdDobraCia     AS TipoEquipoId
    ,TTHO.IdDobraCia    AS TipoHorarioId
    ,TTH.IdDobraCia     AS TipoHonorarioId
    ,TTCO.IdDobraCia    AS TipoContenedorId
    ,CASE WHEN(TCS.Estado = '1-Inactivo') THEN 1 ELSE 0 END AS Anulado
    ,TCS.ProcesadoEstado ,TCS.ProcesadoMensaje
    ,TCS.Modified_Time ,TCS.Created_Time

    FROM  dbo.TarifaCargaSuelta TCS
    LEFT JOIN dbo.Cotizacion CO     on TCS.CabeceraName = CO.Name
    LEFT JOIN dbo.Account_new A     ON CO.ClienteId = A.ZohoId
    LEFT JOIN Cia.dbo.CLI_CLIENTES CLI ON CLI.Ruc = A.Nro_identificacion
    LEFT JOIN dbo.Homologacion TR   ON LEFT(TCS.Ruta, CHARINDEX('-', TCS.Ruta + '-') - 1) = TR.IdCRM AND TR.Catalogo = 'TarifaRutaID'
    LEFT JOIN dbo.Homologacion TTC  ON LEFT(TCS.Tipo_cotizacion, CHARINDEX('-', TCS.Tipo_cotizacion + '-') - 1) = TTC.IdCRM AND TTC.Catalogo = 'tipoCotizacionID'
    LEFT JOIN dbo.Homologacion TC   ON LEFT(TCS.Contenedor, CHARINDEX('-', TCS.Contenedor + '-') - 1) = TC.IdCRM AND TC.Catalogo = 'CargaID'
    LEFT JOIN dbo.Homologacion TTO  ON LEFT(TCS.Tipo_Operacion, CHARINDEX('-', TCS.Tipo_Operacion + '-') - 1) = TTO.IdCRM AND TTO.Catalogo = 'TipoOperacionID'
    LEFT JOIN dbo.Homologacion TS   ON LEFT(TCS.Tipo_de_Servicio, CHARINDEX('-', TCS.Tipo_de_Servicio + '-') - 1) = TS.IdCRM AND TS.Catalogo = 'tipoSrvCIACargSuelt'
    LEFT JOIN dbo.Homologacion TCA  ON LEFT(TCS.Tipo_Camion, CHARINDEX('-', TCS.Tipo_Camion + '-') - 1) = TCA.IdCRM AND TCA.Catalogo = 'tipoCamionID'
    LEFT JOIN dbo.Homologacion TTE  ON LEFT(TCS.Tipo_de_Equipo, CHARINDEX('-', TCS.Tipo_de_Equipo + '-') - 1) = TTE.IdCRM AND TTE.Catalogo = 'tipoEquipoID'
    LEFT JOIN dbo.Homologacion TTHO ON LEFT(TCS.Horario, CHARINDEX('-', TCS.Horario + '-') - 1) = TTHO.IdCRM AND TTHO.Catalogo = 'tipoHorarioID'
    LEFT JOIN dbo.Homologacion TTH  ON LEFT(TCS.Tipo_de_Honorario, CHARINDEX('-', TCS.Tipo_de_Honorario + '-') - 1) = TTH.IdCRM AND TTH.Catalogo = 'TipoHonorarioID'
    LEFT JOIN dbo.Homologacion TTCO ON LEFT(TCS.Tipo_Contenedor, CHARINDEX('-', TCS.Tipo_Contenedor + '-') - 1) = TTCO.IdCRM AND TTCO.Catalogo = 'TipoContenedor'

    WHERE TCS.Name in(
        <lista_tarifas_CargaSuelta>
    );