output "elb_url" {
  description = "Public HTTP URL of the Load Balancer"
  value       = "http://${aws_elb.app_elb.dns_name}/hello"
}

