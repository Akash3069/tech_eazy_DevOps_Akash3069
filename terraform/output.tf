output "ec2_public_ip" {
  description = "Public IP of the EC2 instance"
  value = "http://${aws_instance.java_app.public_ip}:8080/hello"
}
