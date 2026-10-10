output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.hermes.id
}

output "private_ip" {
  description = "Private IP within the VPC."
  value       = aws_instance.hermes.private_ip
}

output "ami_id" {
  description = "Ubuntu AMI the instance was launched from."
  value       = aws_instance.hermes.ami
}

output "ssm_connect_command" {
  description = "Open a shell on the instance via SSM Session Manager."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.hermes.id}"
}

output "tailscale_ssh_command" {
  description = "SSH via Tailscale once the node has joined the tailnet."
  value       = "tailscale ssh hermes@${var.tailscale_hostname}"
}
