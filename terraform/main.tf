provider "aws" {
  region = var.region
}

# --- Security Group (allow SSH & HTTP) ---
resource "aws_security_group" "ec2_sg2" {
  name        = "ec2_sg2"
  description = "Allow SSH and HTTP"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- S3 Bucket ---
resource "aws_s3_bucket" "logs_bucket" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "logs_bucket_ownership" {
  bucket = aws_s3_bucket.logs_bucket.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs_lifecycle" {
  bucket = aws_s3_bucket.logs_bucket.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {
      prefix = "" # apply rule to everything
    }

    expiration {
      days = 7
    }
  }
}

# --- IAM Role for EC2 ---
resource "aws_iam_role" "s3_readwrite_role" {
  name = "s3-readwrite-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# --- IAM Policies ---
resource "aws_iam_policy" "s3_readonly_policy" {
  name        = "s3-readonly-policy"
  description = "Allow read-only access to S3"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_policy" "s3_writeonly_policy" {
  name        = "s3-writeonly-policy"
  description = "Allow write-only access to S3"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:PutObject"]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

# --- Attach Policies to Role ---
resource "aws_iam_role_policy_attachment" "s3_readonly_attach" {
  role       = aws_iam_role.s3_readwrite_role.name
  policy_arn = aws_iam_policy.s3_readonly_policy.arn
}

resource "aws_iam_role_policy_attachment" "s3_writeonly_attach" {
  role       = aws_iam_role.s3_readwrite_role.name
  policy_arn = aws_iam_policy.s3_writeonly_policy.arn
}

# --- IAM Instance Profile for EC2 ---
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-s3-upload-profile"
  role = aws_iam_role.s3_readwrite_role.name
}

# --- EC2 Instance with User Data ---
resource "aws_instance" "java_app" {
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.mykey
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.ec2_sg2.id]

  user_data = <<-EOF
              #!/bin/bash
              apt update -y
              apt install -y git openjdk-17-jdk maven unzip curl

              # Install AWS CLI v2
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
              unzip /tmp/awscliv2.zip -d /tmp
              /tmp/aws/install
              /usr/local/bin/aws --version

              # Clone and build app
              cd /home/ubuntu
              git clone https://github.com/Trainings-TechEazy/test-repo-for-devops.git
              cd test-repo-for-devops
              mvn clean package

              # Run Spring Boot app
              nohup java -jar target/hellomvc-0.0.1-SNAPSHOT.jar --server.address=0.0.0.0 --server.port=8080 > app.log 2>&1 &

              # Create log upload script
              cat <<EOL > /usr/local/bin/upload_logs_to_s3.sh
              #!/bin/bash
              set -e
              S3_BUCKET="s3://${var.bucket_name}"
              aws s3 cp /var/log/cloud-init.log \$S3_BUCKET/ec2-logs/cloud-init.log
              aws s3 cp /home/ubuntu/test-repo-for-devops/app.log \$S3_BUCKET/app/logs/app.log
              EOL

              chmod +x /usr/local/bin/upload_logs_to_s3.sh

              # Systemd service for log upload
              cat <<EOL > /etc/systemd/system/upload-logs.service
              [Unit]
              Description=Upload logs to S3 on shutdown
              DefaultDependencies=no
              Before=shutdown.target reboot.target halt.target

              [Service]
              Type=oneshot
              ExecStart=/usr/local/bin/upload_logs_to_s3.sh
              RemainAfterExit=yes

              [Install]
              WantedBy=halt.target reboot.target shutdown.target
              EOL

              systemctl daemon-reload
              systemctl enable upload-logs.service
              EOF

  tags = {
    Name = "JavaAppServer"
  }
}
