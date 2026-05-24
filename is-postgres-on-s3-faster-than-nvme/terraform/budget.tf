# AWS Budgets monthly cost cap, scoped to this project's tagged resources.
# `budget_limit_usd = 0` disables the budget; default is $30.
#
# Note: AWS Budgets is a *global* service in the master account; the budget
# itself isn't AZ/region-specific, but the cost filter restricts it to
# resources tagged Project=postgres-benchmark-s3-nvme (every resource in
# this project gets that tag via the provider's default_tags).

resource "aws_budgets_budget" "bench" {
  count = var.budget_limit_usd > 0 ? 1 : 0

  name              = "${local.name_prefix}-budget"
  budget_type       = "COST"
  limit_amount      = format("%g", var.budget_limit_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = formatdate("YYYY-MM-01_00:00", timestamp())

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$postgres-benchmark-s3-nvme"]
  }

  # 80% threshold (actual spend) — early warning.
  dynamic "notification" {
    for_each = var.budget_alert_email != "" ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }

  # 100% threshold (forecasted) — predicted-overrun warning.
  dynamic "notification" {
    for_each = var.budget_alert_email != "" ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }

  lifecycle {
    # The time_period_start uses timestamp() which would otherwise force a
    # diff every plan; ignore it so the budget is stable.
    ignore_changes = [time_period_start]
  }
}
