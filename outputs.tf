output "vpc_id" {
  value = module.network.vpc_id
}

output "backend_public_ip" {
  value = aws_instance.backend.public_ip
}
