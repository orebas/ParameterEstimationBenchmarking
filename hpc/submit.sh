#!/bin/bash
#
# Wrapper for submitting SLURM jobs with automatic email configuration.
#
# On first run, prompts for your email and saves it to hpc/user_config.sh.
# On subsequent runs, reads the saved config and injects --mail-user into sbatch.
#
# Usage (drop-in replacement for sbatch):
#   ./hpc/submit.sh [sbatch-options] <script.s> [script-args...]
#
# Examples:
#   ./hpc/submit.sh --array=0-99 hpc/array_job_odepe.s data_dir run_dir
#   ./hpc/submit.sh hpc/array_job_pe.s data_dir
#   ./hpc/submit.sh --array=0-49 hpc/local/array_job_sciml_local.s full_benchmark
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/user_config.sh"

# First-time setup: prompt for email
if [ ! -f "$CONFIG_FILE" ]; then
    echo "========================================"
    echo "  First-time SLURM setup"
    echo "========================================"
    echo ""
    echo "SLURM jobs on this cluster require an email address."
    echo "This will be saved to hpc/user_config.sh (git-ignored)."
    echo ""
    read -p "Enter your email address: " SLURM_EMAIL

    if [ -z "$SLURM_EMAIL" ]; then
        echo "Error: No email provided. Aborting."
        exit 1
    fi

    cat > "$CONFIG_FILE" <<EOF
# SLURM user configuration (auto-generated, git-ignored)
# Edit this file to change your email or notification preferences.
SLURM_EMAIL="$SLURM_EMAIL"
SLURM_MAIL_TYPE="ALL"
EOF

    echo ""
    echo "Saved to $CONFIG_FILE"
    echo "You can edit this file at any time to update your settings."
    echo ""
fi

# Load config
source "$CONFIG_FILE"

if [ -z "$SLURM_EMAIL" ]; then
    echo "Error: SLURM_EMAIL is empty in $CONFIG_FILE"
    echo "Please edit $CONFIG_FILE and set your email address."
    exit 1
fi

# Default mail type if not set in config
SLURM_MAIL_TYPE="${SLURM_MAIL_TYPE:-ALL}"

echo "Submitting with --mail-user=$SLURM_EMAIL --mail-type=$SLURM_MAIL_TYPE"
exec sbatch --mail-user="$SLURM_EMAIL" --mail-type="$SLURM_MAIL_TYPE" "$@"
