# Security policy

Security fixes target the current release series. To report a vulnerability, use **Security → Report a vulnerability** in the repository if private vulnerability reporting is enabled. If it is unavailable, contact a maintainer privately through their GitHub profile.

Include the affected version, macOS version, impact, and enough information for a maintainer to investigate. Redact real credentials and any local data that the report does not require. Coordinate disclosure with the maintainers while a fix is being prepared.

## Local process and Docker permissions

Port-close actions require confirmation and use the current account’s ordinary permissions. GlassStats checks process ownership, start time, executable path, and matching endpoints before sending SIGTERM. The action excludes system executables, app bundles, the GlassStats process and its ancestors. Stopping a process can affect its other listeners and work in progress.

Docker monitoring uses a fixed read-only request over a standard local Unix socket. Access is governed by the socket’s operating-system permissions.
