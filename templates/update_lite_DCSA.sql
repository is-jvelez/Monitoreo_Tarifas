{HEADER}

SET LOCK_TIMEOUT 30000;

UPDATE dbo.TarifaServiciosAdicionales
    SET ProcesadoEstado  = 0,
        ProcesadoMensaje = 'Regularizado manualmente - {FECHA_COMPACTA}',
        ProcesadoFecha   = GETDATE(),
        Modified_Time    = GETDATE()
WHERE ProcesadoEstado = 2
  AND Name IN (
<lista_tarifas_in>
  );
