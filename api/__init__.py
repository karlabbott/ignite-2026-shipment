"""NinetyNine Freight API tier — runs on sles-api (SUSE Linux Enterprise Server).

All business logic lives here. The web tier renders what this returns and the
worker tier drives shipments through the pipeline; neither of them talks to the
database for anything except their own heartbeat.
"""
