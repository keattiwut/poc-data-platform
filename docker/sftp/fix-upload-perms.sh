#!/bin/sh
# atmoz/sftp's create-sftp-user only chowns a "dir1,dir2" argument to the
# SFTP user if the directory did NOT already exist - but a Docker volume
# mount always pre-creates its mountpoint as root:root before the container
# starts, so the auto-chown never fires for a volume-backed upload/ dir
# (Issue 04 discovery: this left upload/ root-owned, so the mock generator's
# SFTP writes failed with Permission denied). Fix it explicitly here; this
# script runs via atmoz/sftp's supported /etc/sftp.d/ hook mechanism, after
# user creation and before sshd starts.
chown -R "${SFTP_USER}:users" "/home/${SFTP_USER}/upload"
