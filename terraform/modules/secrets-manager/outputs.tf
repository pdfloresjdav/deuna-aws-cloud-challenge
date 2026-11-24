output "secret_arn" {
  description = "ARN of the RDS-managed secret (passthrough reference, never the value)."
  value       = var.secret_arn
}

output "resource_policy_managed" {
  description = "Whether a resource policy is applied to the managed secret (always true; the policy is always created)."
  value       = true
}
