
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "instance_count" {
  description = "Number of EC2 instances"
  type        = number
  default     = 2
}


variable "bucket_name" {
  description = "S3 bucket name"
  type        = string
  default = "myglobuniqbuk69"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "mykey" {
  type        = string
  description = "AWS Key Pair name"
  default = "mykey"
 
}
variable "ami_id" {
    type = string
     default = "ami-02d26659fd82cf299" 
  
}