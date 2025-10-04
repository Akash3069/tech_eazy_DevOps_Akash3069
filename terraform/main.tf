provider "aws" {
  region = var.region
}

# --- Security Group (allow SSH & HTTP 8080 for app + 80 for ELB) ---
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
    description = "App HTTP"
    from_port   = 80
    to_port     = 80
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

resource "aws_security_group" "elb_sg" {
  name        = "elb_sg"
  description = "Allow HTTP for ELB"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
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

# --- S3 Bucket for ELB Logs ---
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
      prefix = ""
    }
    expiration {
      days = 7
    }
  }
}

# --- Bucket Policy for ELB Logs ---
resource "aws_s3_bucket_policy" "elb_logs_policy" {
  bucket = aws_s3_bucket.logs_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ELBAccessLogsPolicy"
        Effect    = "Allow"
        Principal = {
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs_bucket.arn}/*"
      }
    ]
  })
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

# --- Attach IAM Policies from policy folder ---
resource "aws_iam_policy" "s3_readonly_policy" {
  name        = "s3-readonly-policy"
  description = "Allow read-only access to S3"
  policy      = file("policy/s3-read-policy.json")
}

resource "aws_iam_policy" "s3_writeonly_policy" {
  name        = "s3-writeonly-policy"
  description = "Allow write-only access to S3"
  policy      = file("policy/s3-write-policy.json")
}

resource "aws_iam_role_policy_attachment" "s3_readonly_attach" {
  role       = aws_iam_role.s3_readwrite_role.name
  policy_arn = aws_iam_policy.s3_readonly_policy.arn
}

resource "aws_iam_role_policy_attachment" "s3_writeonly_attach" {
  role       = aws_iam_role.s3_readwrite_role.name
  policy_arn = aws_iam_policy.s3_writeonly_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-s3-upload-profile"
  role = aws_iam_role.s3_readwrite_role.name
}

# --- EC2 Instances (configurable count) ---
resource "aws_instance" "java_app" {
  count                = var.instance_count
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.mykey
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.ec2_sg2.id]

  
  user_data = <<-EOF
   #!/bin/bash
   BUCKET_NAME="${var.bucket_name}"   # S3 bucket for logs
   APP_NAME="hellomvc-0.0.1-SNAPSHOT.jar"
   LOCAL_PATH="/home/ubuntu/$APP_NAME"
   PID_FILE="/home/ubuntu/app.pid"
   LOG_FILE="/home/ubuntu/app.log"

   # Install Java & AWS CLI
   apt-get update -y
   apt-get install -y openjdk-17-jre unzip curl

   # AWS CLI v2 install
   cd /tmp
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip
   sudo ./aws/install
   aws --version

   # Wait until JAR exists in S3
   until aws s3 ls s3://$BUCKET_NAME/$APP_NAME > /dev/null 2>&1; do
    sleep 30
   done

   # Download JAR and start app
   aws s3 cp s3://$BUCKET_NAME/$APP_NAME $LOCAL_PATH
   nohup java -jar $LOCAL_PATH > $LOG_FILE 2>&1 &
   echo $! > $PID_FILE

   # Function to push logs to S3
   push_logs_to_s3() {
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    DESTINATION="s3://$BUCKET_NAME/app-logs/$(hostname)-$TIMESTAMP.log"

    echo "Uploading logs to $DESTINATION ..."
    aws s3 cp "$LOG_FILE" "$DESTINATION"
    }

   # Polling loop: check for JAR update and push logs
   while true; do
    # Check for updated JAR
    aws s3 cp s3://$BUCKET_NAME/$APP_NAME $LOCAL_PATH.new --quiet || true
    if [ -f "$LOCAL_PATH.new" ] && ! cmp -s $LOCAL_PATH.new $LOCAL_PATH; then
        echo "New version detected. Restarting app..."
        kill $(cat $PID_FILE) || true
        mv $LOCAL_PATH.new $LOCAL_PATH
        nohup java -jar $LOCAL_PATH > $LOG_FILE 2>&1 &
        echo $! > $PID_FILE
    else
        rm -f $LOCAL_PATH.new
    fi

    # Push logs to S3 every 60 seconds
    push_logs_to_s3

    sleep 60
   done

  EOF


  tags = {
    Name = "JavaAppServer-${count.index}"
  }
}

# --- Classic ELB (Round Robin) ---
resource "aws_elb" "app_elb" {
  name               = "app-elb"
  availability_zones = ["ap-south-1a", "ap-south-1b"]
  security_groups    = [aws_security_group.elb_sg.id]

  listener {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }

  health_check {
    target              = "HTTP:80/hello"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  instances = aws_instance.java_app[*].id

  access_logs {
    bucket        = aws_s3_bucket.logs_bucket.bucket
    bucket_prefix = "elb-logs"
    enabled       = true
    interval      = 5
  }

  tags = {
    Name = "AppLoadBalancer"
  }
}
