output "ec2_public_ip" {
  description = "Public IP of the EC2 instance"
  value = "http://${aws_instance.my_ec2.public_ip}:8080/hello"
}
