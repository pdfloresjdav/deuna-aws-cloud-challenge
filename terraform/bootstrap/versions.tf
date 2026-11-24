terraform {
  # >= 1.11 is required for native S3 state locking (use_lockfile) used by the
  # dev/prod backends this bootstrap provisions.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }

  # The bootstrap uses LOCAL state by design: it creates the very bucket that
  # would host remote state, so no remote backend exists yet. After apply, its
  # state may optionally be migrated into the new bucket (see docs).
}
