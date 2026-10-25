resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../../ansible/inventory/hosts.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    server = {
      name       = "server-1"
      public_ip  = aws_eip.server.public_ip
      private_ip = aws_instance.server.private_ip
    }
    agents = [for i, a in aws_instance.agent : {
      name       = "agent-${i + 1}"
      public_ip  = a.public_ip
      private_ip = a.private_ip
    }]
  })
}

output "server_public_ip" {
  value = aws_eip.server.public_ip
}

output "agent_public_ips" {
  value = aws_instance.agent[*].public_ip
}

output "ssh_server" {
  value = "ssh -i ~/.ssh/retail-store ubuntu@${aws_eip.server.public_ip}"
}