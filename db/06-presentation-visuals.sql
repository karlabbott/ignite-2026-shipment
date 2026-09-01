/* Geographic endpoints and one durable presentation spotlight.
   Coordinates are city-level values used only for local SVG visualization. */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE shipping;
GO

IF COL_LENGTH('dbo.shipments', 'origin_latitude') IS NULL
    ALTER TABLE dbo.shipments ADD origin_latitude DECIMAL(9,6) NULL;
IF COL_LENGTH('dbo.shipments', 'origin_longitude') IS NULL
    ALTER TABLE dbo.shipments ADD origin_longitude DECIMAL(9,6) NULL;
IF COL_LENGTH('dbo.shipments', 'destination_latitude') IS NULL
    ALTER TABLE dbo.shipments ADD destination_latitude DECIMAL(9,6) NULL;
IF COL_LENGTH('dbo.shipments', 'destination_longitude') IS NULL
    ALTER TABLE dbo.shipments ADD destination_longitude DECIMAL(9,6) NULL;
IF COL_LENGTH('dbo.shipments', 'is_golden') IS NULL
    ALTER TABLE dbo.shipments
        ADD is_golden BIT NOT NULL
            CONSTRAINT df_shipments_is_golden DEFAULT (0);
IF COL_LENGTH('dbo.shipments', 'demo_hold_status') IS NULL
    ALTER TABLE dbo.shipments ADD demo_hold_status VARCHAR(20) NULL;
GO

IF NOT EXISTS (
    SELECT 1
      FROM sys.indexes
     WHERE object_id = OBJECT_ID('dbo.shipments')
       AND name = 'ux_shipments_one_golden'
)
    CREATE UNIQUE INDEX ux_shipments_one_golden
        ON dbo.shipments (is_golden)
        WHERE is_golden = 1;
GO

/* Select a stable existing routed shipment for development. The presenter can
   replace it later with the shipment created immediately before migration. */
IF NOT EXISTS (SELECT 1 FROM dbo.shipments WHERE is_golden = 1)
BEGIN
    DECLARE @initial_golden BIGINT =
        (SELECT TOP (1) s.shipment_id
           FROM dbo.shipments AS s
          WHERE s.origin_latitude IS NOT NULL
            AND s.destination_latitude IS NOT NULL
            AND EXISTS (
                    SELECT 1
                      FROM dbo.shipment_route_stops AS r
                     WHERE r.shipment_id = s.shipment_id
                )
          ORDER BY s.created_at DESC, s.shipment_id DESC);

    IF @initial_golden IS NOT NULL
        UPDATE dbo.shipments
           SET is_golden = 1,
               demo_hold_status = 'OUT_FOR_DELIVERY'
         WHERE shipment_id = @initial_golden;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_set_golden_shipment
    @tracking_number VARCHAR(20),
    @hold_status VARCHAR(20) = 'OUT_FOR_DELIVERY'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (
        SELECT 1
          FROM dbo.shipments
         WHERE tracking_number = @tracking_number
    )
        THROW 51001, 'Cannot spotlight an unknown shipment.', 1;

    IF @hold_status IS NOT NULL
       AND @hold_status NOT IN (
            'CREATED', 'PICKED_UP', 'IN_TRANSIT', 'AT_HUB', 'OUT_FOR_DELIVERY'
       )
        THROW 51002, 'Invalid golden-shipment hold status.', 1;

    BEGIN TRANSACTION;
    UPDATE dbo.shipments SET is_golden = 0 WHERE is_golden = 1;
    UPDATE dbo.shipments
       SET is_golden = 1,
           demo_hold_status = @hold_status
     WHERE tracking_number = @tracking_number;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_assign_golden_if_none
    @shipment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    BEGIN TRANSACTION;

    DECLARE @assigned BIT = 0;
    IF NOT EXISTS (
        SELECT 1
          FROM dbo.shipments WITH (UPDLOCK, HOLDLOCK)
         WHERE is_golden = 1
    )
    BEGIN
        UPDATE dbo.shipments
           SET is_golden = 1,
               demo_hold_status = 'OUT_FOR_DELIVERY'
         WHERE shipment_id = @shipment_id;
        SET @assigned = CASE WHEN @@ROWCOUNT = 1 THEN 1 ELSE 0 END;
    END;

    COMMIT TRANSACTION;
    SELECT @assigned AS assigned;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_release_golden_shipment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @shipment_id BIGINT;
    SELECT @shipment_id = shipment_id
      FROM dbo.shipments
     WHERE is_golden = 1;

    IF @shipment_id IS NULL
        THROW 51003, 'No golden shipment is configured.', 1;

    BEGIN TRANSACTION;
    UPDATE dbo.shipments
       SET demo_hold_status = NULL
     WHERE shipment_id = @shipment_id;

    IF EXISTS (
        SELECT 1 FROM dbo.shipments
         WHERE shipment_id = @shipment_id AND status <> 'DELIVERED'
    )
       AND NOT EXISTS (
        SELECT 1 FROM dbo.scan_queue
         WHERE shipment_id = @shipment_id AND processed_at IS NULL
    )
        INSERT INTO dbo.scan_queue (shipment_id, requested_by)
        VALUES (@shipment_id, N'golden-release');
    COMMIT TRANSACTION;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'shipping_app') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.usp_assign_golden_if_none TO shipping_app;
    GRANT EXECUTE ON dbo.usp_release_golden_shipment TO shipping_app;
END;
GO

/* Held work stays visibly queued but cannot be claimed until the presenter
   releases it. The same queue row can therefore survive the migration. */
CREATE OR ALTER PROCEDURE dbo.usp_claim_scan
    @worker NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE TOP (1) q
       SET q.claimed_by = @worker,
           q.claimed_at = SYSUTCDATETIME(),
           q.attempts   = q.attempts + 1
    OUTPUT inserted.queue_id, inserted.shipment_id, inserted.requested_by,
           inserted.attempts
      FROM dbo.scan_queue AS q WITH (ROWLOCK, READPAST, UPDLOCK)
      JOIN dbo.shipments AS s ON s.shipment_id = q.shipment_id
     WHERE q.processed_at IS NULL
       AND (q.claimed_at IS NULL OR q.claimed_at < DATEADD(minute, -2, SYSUTCDATETIME()))
       AND q.attempts < 5
       AND (s.demo_hold_status IS NULL OR s.status <> s.demo_hold_status);
END;
GO
