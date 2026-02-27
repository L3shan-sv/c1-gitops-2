variable "project" { type = string }
variable "tags"    { type = map(string) default = {} }

output "repository_url" { value = aws_ecr_repository.myapp.repository_url }
output "repository_arn" { value = aws_ecr_repository.myapp.arn }
