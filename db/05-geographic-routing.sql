/* Persist the geographically plausible route selected when a shipment is made.
   The worker reads these stops after creation, so movement never depends on the
   geocoding service remaining online. */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE shipping;
GO

IF OBJECT_ID('dbo.shipment_route_stops', 'U') IS NULL
CREATE TABLE dbo.shipment_route_stops (
    route_stop_id  BIGINT IDENTITY(1,1) PRIMARY KEY,
    shipment_id    BIGINT        NOT NULL REFERENCES dbo.shipments(shipment_id),
    stop_sequence  TINYINT       NOT NULL,
    location       NVARCHAR(100) NOT NULL,
    stage_location NVARCHAR(120) NULL,
    latitude       DECIMAL(9,6)  NOT NULL,
    longitude      DECIMAL(9,6)  NOT NULL,
    route_source   VARCHAR(24)   NOT NULL,
    CONSTRAINT uq_shipment_route_stop UNIQUE (shipment_id, stop_sequence),
    CONSTRAINT ck_route_stop_sequence CHECK (stop_sequence BETWEEN 1 AND 2)
);
GO

IF COL_LENGTH('dbo.shipment_route_stops', 'stage_location') IS NULL
    ALTER TABLE dbo.shipment_route_stops ADD stage_location NVARCHAR(120) NULL;
GO

UPDATE r
   SET stage_location = r.location
  FROM dbo.shipment_route_stops AS r
  JOIN dbo.shipments AS s ON s.shipment_id = r.shipment_id
 WHERE r.stage_location IS NULL
   AND s.created_by = N'seed';
GO

/* The unique constraint already supplies the required shipment/sequence index.
   Remove the redundant index if an earlier draft of this migration created it. */
IF EXISTS (
    SELECT 1
      FROM sys.indexes
     WHERE object_id = OBJECT_ID('dbo.shipment_route_stops')
       AND name = 'ix_route_stops_shipment'
)
    DROP INDEX ix_route_stops_shipment ON dbo.shipment_route_stops;
GO
