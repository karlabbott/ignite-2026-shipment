/* Zava Logistics — schema for SQL Server 2025 on RHEL.
   Idempotent: safe to run repeatedly against rhel-db. */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF DB_ID('shipping') IS NULL
    CREATE DATABASE shipping;
GO

USE shipping;
GO

/* ------------------------------------------------------------------ carriers */
IF OBJECT_ID('dbo.carriers', 'U') IS NULL
CREATE TABLE dbo.carriers (
    carrier_id   INT IDENTITY(1,1) PRIMARY KEY,
    code         VARCHAR(8)   NOT NULL UNIQUE,
    name         NVARCHAR(80) NOT NULL,
    hub_city     NVARCHAR(60) NOT NULL
);
GO

/* ----------------------------------------------------------------- shipments */
IF OBJECT_ID('dbo.shipments', 'U') IS NULL
CREATE TABLE dbo.shipments (
    shipment_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
    tracking_number  VARCHAR(20)   NOT NULL UNIQUE,
    carrier_id       INT           NOT NULL REFERENCES dbo.carriers(carrier_id),
    origin           NVARCHAR(60)  NOT NULL,
    destination      NVARCHAR(60)  NOT NULL,
    description      NVARCHAR(120) NOT NULL DEFAULT N'General freight',
    weight_kg        DECIMAL(6,2)  NOT NULL DEFAULT 1.00,
    status           VARCHAR(20)   NOT NULL DEFAULT 'CREATED',
    created_by       NVARCHAR(60)  NOT NULL DEFAULT N'system',
    created_at       DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_shipments_status')
    CREATE INDEX ix_shipments_status
        ON dbo.shipments (status) INCLUDE (tracking_number, updated_at);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_shipments_updated')
    CREATE INDEX ix_shipments_updated ON dbo.shipments (updated_at DESC);
GO

/* --------------------------------------------------------------- scan_events */
IF OBJECT_ID('dbo.scan_events', 'U') IS NULL
CREATE TABLE dbo.scan_events (
    scan_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
    shipment_id  BIGINT       NOT NULL REFERENCES dbo.shipments(shipment_id),
    scan_type    VARCHAR(24)  NOT NULL,
    location     NVARCHAR(60) NOT NULL,
    notes        NVARCHAR(160) NULL,
    /* Which VM produced this scan. This is the audit trail that proves the
       worker tier moved from Hyper-V to Azure mid-demo. */
    worker_host  NVARCHAR(64) NOT NULL,
    worker_site  NVARCHAR(48) NOT NULL,
    occurred_at  DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_scan_events_shipment')
    CREATE INDEX ix_scan_events_shipment
        ON dbo.scan_events (shipment_id, occurred_at DESC);
GO

/* ------------------------------------------------------------ status_history */
IF OBJECT_ID('dbo.status_history', 'U') IS NULL
CREATE TABLE dbo.status_history (
    history_id   BIGINT IDENTITY(1,1) PRIMARY KEY,
    shipment_id  BIGINT       NOT NULL REFERENCES dbo.shipments(shipment_id),
    from_status  VARCHAR(20)  NULL,
    to_status    VARCHAR(20)  NOT NULL,
    changed_by   NVARCHAR(64) NOT NULL,
    changed_at   DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_status_history_shipment')
    CREATE INDEX ix_status_history_shipment
        ON dbo.status_history (shipment_id, changed_at DESC);
GO

/* ---------------------------------------------------------------- scan_queue
   The estate has no message broker. This table *is* the queue: the Rocky worker
   claims rows with UPDATE ... WITH (READPAST) OUTPUT, which is atomic, safe for
   multiple consumers, and small enough to explain on a slide. It also means the
   RHEL database VM is a genuine single point of failure -- which is precisely
   what makes its post-migration boot failure worth watching. */
IF OBJECT_ID('dbo.scan_queue', 'U') IS NULL
CREATE TABLE dbo.scan_queue (
    queue_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    shipment_id  BIGINT       NOT NULL REFERENCES dbo.shipments(shipment_id),
    requested_by NVARCHAR(64) NOT NULL,
    enqueued_at  DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    claimed_by   NVARCHAR(64) NULL,
    claimed_at   DATETIME2(0) NULL,
    processed_at DATETIME2(0) NULL,
    attempts     INT          NOT NULL DEFAULT 0,
    last_error   NVARCHAR(400) NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_scan_queue_pending')
    CREATE INDEX ix_scan_queue_pending
        ON dbo.scan_queue (queue_id) WHERE processed_at IS NULL;
GO

/* ----------------------------------------------------------- tier_heartbeats
   Each tier writes its identity here every few seconds. The dashboard renders
   this table directly as the health strip, so a tier that stops reporting goes
   grey on screen within one poll interval. */
IF OBJECT_ID('dbo.tier_heartbeats', 'U') IS NULL
CREATE TABLE dbo.tier_heartbeats (
    tier        VARCHAR(16)  NOT NULL,
    hostname    NVARCHAR(64) NOT NULL,
    distro      NVARCHAR(96) NOT NULL,
    kernel      NVARCHAR(64) NOT NULL,
    platform    NVARCHAR(24) NOT NULL,
    location    NVARCHAR(48) NOT NULL,
    vm_size     NVARCHAR(48) NULL,
    detail      NVARCHAR(200) NULL,
    last_seen   DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_tier_heartbeats PRIMARY KEY (tier, hostname)
);
GO

/* ------------------------------------------------------------------- helpers */
CREATE OR ALTER PROCEDURE dbo.usp_record_heartbeat
    @tier     VARCHAR(16),
    @hostname NVARCHAR(64),
    @distro   NVARCHAR(96),
    @kernel   NVARCHAR(64),
    @platform NVARCHAR(24),
    @location NVARCHAR(48),
    @vm_size  NVARCHAR(48) = NULL,
    @detail   NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dbo.tier_heartbeats AS target
    USING (SELECT @tier AS tier, @hostname AS hostname) AS source
        ON target.tier = source.tier
       AND target.hostname = source.hostname
    WHEN MATCHED THEN UPDATE SET
        hostname = @hostname, distro = @distro, kernel = @kernel,
        platform = @platform, location = @location, vm_size = @vm_size,
        detail = @detail, last_seen = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (tier, hostname, distro, kernel, platform, location, vm_size, detail)
        VALUES (@tier, @hostname, @distro, @kernel, @platform, @location,
                @vm_size, @detail);
END;
GO

/* Claim a single queue item atomically. READPAST lets several workers run
   without blocking each other, which matters if you scale the worker tier live. */
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
     WHERE q.processed_at IS NULL
       AND (q.claimed_at IS NULL OR q.claimed_at < DATEADD(minute, -2, SYSUTCDATETIME()))
       AND q.attempts < 5;
END;
GO

CREATE OR ALTER VIEW dbo.vw_shipment_board AS
SELECT TOP (200)
       s.shipment_id,
       s.tracking_number,
       c.code           AS carrier_code,
       c.name           AS carrier_name,
       s.origin,
       s.destination,
       s.description,
       s.status,
       s.created_by,
       s.created_at,
       s.updated_at,
       (SELECT COUNT(*) FROM dbo.scan_events e
         WHERE e.shipment_id = s.shipment_id) AS scan_count,
       (SELECT TOP 1 e.location FROM dbo.scan_events e
         WHERE e.shipment_id = s.shipment_id
         ORDER BY e.occurred_at DESC, e.scan_id DESC) AS last_location,
       (SELECT TOP 1 e.worker_host FROM dbo.scan_events e
         WHERE e.shipment_id = s.shipment_id
         ORDER BY e.occurred_at DESC, e.scan_id DESC) AS last_scanned_by
  FROM dbo.shipments s
  JOIN dbo.carriers  c ON c.carrier_id = s.carrier_id
 ORDER BY s.updated_at DESC;
GO
