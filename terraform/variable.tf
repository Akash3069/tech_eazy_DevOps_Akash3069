
variable "region" {
  type    = string
  default = ""
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = ""
}

variable "mykey" {
  type        = string
  description = "AWS Key Pair name"
  default = ""
 
}
variable "ami_id" {
    type = string
     default = "" 
  
}