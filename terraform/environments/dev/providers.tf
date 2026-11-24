provider "aws" {
  region = var.aws_region

  # Credentials are provided by the environment (profile, SSO, OIDC role).
  # They are never stored in this configuration.
}
