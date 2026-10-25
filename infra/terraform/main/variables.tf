variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "admin_cidr" {
  description = "IP của bạn dạng x.x.x.x/32"
  type        = string
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/retail-store.pub"
}

variable "server_instance_type" {
  type    = string
  default = "t3.large"
}

variable "agent_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "agent_count" {
  type    = number
  default = 2
}

variable "root_volume_size" {
  type    = number
  default = 40
}
