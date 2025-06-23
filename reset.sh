#!/bin/bash
#
# This script performs a complete reset of the local development environment.
# WARNING: This is a destructive operation. It will:
#   1. Stop all running services.
#   2. Remove all containers.
#   3. Delete all volumes, including the PostgreSQL database.
#   4. Remove locally built Docker images.
#

echo "WARNING: This will permanently delete all local data, including the database."
read -p "Are you sure you want to continue? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Performing full environment teardown..."
    sudo docker-compose down -v --rmi local
    echo "Environment has been reset."
fi